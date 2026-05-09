/*==========================================================================
  NORTH STAR BANK — AUDIENCE & LEAD GENERATION (A&LG)
  Program : 02_audience_lead_selection.sas
  Purpose : Build the qualified lead universe for campaign
            NS_ALG_BIZ_XSELL_2024Q3. Applies A&LG eligibility
            criteria, suppression rules, contact lag enforcement,
            AEP audience enrichment, and deduplication.
            Produces a waterfall report for marketing sign-off.
  Team    : Audience & Lead Generation · Business Banking Marketing
  --------------------------------------------------------------------------
  A&LG LEAD LIFECYCLE STAGE: Audience Defined → Lead Qualified
  This program activates the upstream audience definition (SBO segment
  from Adobe Real-Time CDP / AEP) into a SAS-executed lead file,
  enriching with propensity scores and enforcing all suppression
  and eligibility guardrails before QC.
  --------------------------------------------------------------------------
  ELIGIBILITY LOGIC:
    1. In CRM customer master (has personal deposit relationship)
    2. Age 35–60 as of campaign run date
    3. SBO signal present (CRM, loan app, or third-party enrichment)
    4. No existing business checking/savings account (anti-join)
    5. Not suppressed (any reason, any channel)
    6. Not contacted within last &contact_lag. days
    PLUS: Enrich with Adobe AEP propensity score where available
  --------------------------------------------------------------------------
  CLOUD NOTE: Anti-join pattern maps directly to Spark SQL.
  In PySpark: df_leads.join(df_suppress, 'customer_id', 'left_anti')
==========================================================================*/
dm 'log;clear;output;clear;';
options mprint mlogic symbolgen;

%let base_path    = /home/u1557222/northstar_campaign_engine;
%let data_path    = &base_path./northstar-bank-alg/data;
%let campaign_id  = NS_ALG_BIZ_XSELL_2024Q3;
%let audience_seg = SBO_BIZMISSING_35_60;
%let contact_lag  = 30;
%let min_age      = 35;
%let max_age      = 60;

libname alg "&data_path.";


/* ── STAGE 1: BASE — AGE BAND ────────────────────────────────────────── */
proc datasets lib=work nodetails nofs nolist; delete s1_age; quit;
data work.s1_age;
  set alg.crm_customers;
  age = year(today()) - birth_year;
  if &min_age. <= age <= &max_age.;
run;
%let n_s1 = %sysfunc(attrn(%sysfunc(open(work.s1_age)), nobs));
%put NOTE: [WATERFALL S1] Age &min_age.-&max_age. = &n_s1.;


/* ── STAGE 2: REQUIRE SBO SIGNAL ────────────────────────────────────── */
proc datasets lib=work nodetails nofs nolist; delete s2_sbo; quit;
proc sql;
  create table work.s2_sbo as
    select c.*, s.sbo_signal_source, s.sbo_confidence, s.naics_code
      from work.s1_age c
      inner join alg.sbo_enrichment s on c.customer_id = s.customer_id;
quit;
%let n_s2 = %sysfunc(attrn(%sysfunc(open(work.s2_sbo)), nobs));
%put NOTE: [WATERFALL S2] + SBO signal = &n_s2.;


/* ── STAGE 3: EXCLUDE EXISTING BUSINESS ACCOUNT HOLDERS ─────────────── */
/* Anti-join: keep only records with NO match in core banking biz table.
   CLOUD: df_s2.join(df_biz, 'customer_id', 'left_anti') */
proc datasets lib=work nodetails nofs nolist; delete s3_no_biz; quit;
proc sql;
  create table work.s3_no_biz as
    select c.*
      from work.s2_sbo c
      left join alg.core_biz_accounts b on c.customer_id = b.customer_id
      where b.customer_id is null;
quit;
%let n_s3 = %sysfunc(attrn(%sysfunc(open(work.s3_no_biz)), nobs));
%put NOTE: [WATERFALL S3] - Existing biz account = &n_s3.;


/* ── STAGE 4: APPLY SUPPRESSION FILE ────────────────────────────────── */
proc datasets lib=work nodetails nofs nolist; delete s4_clean; quit;
proc sql;
  create table work.s4_clean as
    select c.*
      from work.s3_no_biz c
      left join alg.alg_suppressions s on c.customer_id = s.customer_id
      where s.customer_id is null;
quit;
%let n_s4 = %sysfunc(attrn(%sysfunc(open(work.s4_clean)), nobs));
%put NOTE: [WATERFALL S4] - Suppressed = &n_s4.;


/* ── STAGE 5: CONTACT LAG ENFORCEMENT ───────────────────────────────── */
proc datasets lib=work nodetails nofs nolist; delete s5_lag; quit;
proc sql;
  create table work.s5_lag as
    select c.*
      from work.s4_clean c
      left join alg.recent_contacts r on c.customer_id = r.customer_id
      where r.customer_id is null
         or r.last_contact_dt < (today() - &contact_lag.);
quit;
%let n_s5 = %sysfunc(attrn(%sysfunc(open(work.s5_lag)), nobs));
%put NOTE: [WATERFALL S5] - Contact lag (&contact_lag.d) = &n_s5.;


/* ── STAGE 6: DEDUPLICATION ─────────────────────────────────────────── */
proc datasets lib=work nodetails nofs nolist; delete s6_dedup; quit;
proc sort data=work.s5_lag out=work.s6_dedup nodupkey;
  by customer_id;
run;
%let n_s6 = %sysfunc(attrn(%sysfunc(open(work.s6_dedup)), nobs));
%put NOTE: [WATERFALL S6] Dedup = &n_s6.;


/* ── STAGE 7: ENRICH WITH ADOBE AEP PROPENSITY (LEFT JOIN) ──────────── */
/* AEP scores override internal scores where present — they incorporate
   behavioral signal from real-time CDP that SAS source data lacks.
   CLOUD: This join runs natively in Databricks against a Delta table
   populated by the AEP Destinations connector. */
proc datasets lib=work nodetails nofs nolist; delete s7_enriched; quit;
proc sql;
  create table work.s7_enriched as
    select u.*,
           a.aep_propensity_score,
           a.aep_segment_id,
           case when a.customer_id is not null then 'AEP' else 'INTERNAL'
             end as score_source length=10
      from work.s6_dedup u
      left join alg.aep_audience_export a on u.customer_id = a.customer_id;
quit;
%let n_s7 = %sysfunc(attrn(%sysfunc(open(work.s7_enriched)), nobs));
%put NOTE: [WATERFALL S7] AEP enrichment complete = &n_s7.;

/* Count AEP coverage */
proc sql noprint;
  select sum(score_source='AEP'), sum(score_source='INTERNAL')
    into :n_aep_scored, :n_internal_scored
    from work.s7_enriched;
quit;
%put NOTE: [AEP COVERAGE] AEP-scored: &n_aep_scored. | Internal-only: &n_internal_scored.;


/* ── STAGE 8: TAG AND SAVE LEAD UNIVERSE ─────────────────────────────── */
data alg.lead_universe;
  set work.s7_enriched;
  length campaign_id $35 alg_stage $30 audience_segment_id $35 selection_dt 8;
  format selection_dt date9.;
  campaign_id          = "&campaign_id.";
  alg_stage            = "LEAD_QUALIFIED";
  audience_segment_id  = "&audience_seg.";
  selection_dt         = today();
  label
    alg_stage           = "%nrstr(A&LG) Lifecycle Stage"
    audience_segment_id = "Upstream Audience Segment ID"
    score_source        = "Propensity Score Source (AEP or Internal)";
run;


/* ── STAGE 9: WATERFALL REPORT — MARKETING SIGN-OFF DELIVERABLE ──────── */
proc sql;
  create table work.alg_waterfall as
    select 1 as step_n, 'CRM base: all customers'                   as step length=60,
           count(*) as records, . as pct_prior from alg.crm_customers
    union all select 2, 'S1: Age eligible (35-60)',
      count(*), count(*)/input("&n_s1.", best12.)*100 from work.s1_age
    union all select 3, 'S2: + SBO signal present (any source)',
      count(*), count(*)/input("&n_s1.", best12.)*100 from work.s2_sbo
    union all select 4, 'S3: - Existing business account holders',
      count(*), count(*)/input("&n_s2.", best12.)*100 from work.s3_no_biz
    union all select 5, 'S4: - Suppressed (all channels)',
      count(*), count(*)/input("&n_s3.", best12.)*100 from work.s4_clean
    union all select 6, 'S5: - Contact lag (&contact_lag. days)',
      count(*), count(*)/input("&n_s4.", best12.)*100 from work.s5_lag
    union all select 7, 'S6: Dedup on customer_id',
      count(*), count(*)/input("&n_s5.", best12.)*100 from work.s6_dedup
    union all select 8, 'S7: + AEP propensity enrichment (left join)',
      count(*), count(*)/input("&n_s6.", best12.)*100 from alg.lead_universe
    order by step_n;
quit;

proc print data=work.alg_waterfall noobs label;
  var step records pct_prior;
  format pct_prior 8.1;
  label step      = "%nrstr(A&LG) Selection Stage"
        records   = "Lead Count"
        pct_prior = "% of Prior Stage";
  title "NS_ALG_BIZ_XSELL_2024Q3 — %nrstr(A&LG) Lead Selection Waterfall";
  title2 "Deliver to Business Banking Marketing for sign-off prior to QC";
run;

/* SBO confidence breakdown in final universe */
proc freq data=alg.lead_universe;
  tables sbo_confidence sbo_signal_source / nocum;
  title "Lead Universe: SBO Signal Confidence Distribution";
run;

/* Language split in final universe */
proc freq data=alg.lead_universe;
  tables preferred_language / nocum;
  title "Lead Universe: Language Preference (EN/ES)";
run;

title; title2;

%put NOTE: *** 02_audience_lead_selection.sas COMPLETE ***;
%put NOTE: *** Final %nrstr(A&LG) lead universe: &n_s7. records ***;
%put NOTE: *** Proceed to 03_data_quality_control.sas ***;
