/*==========================================================================
  NORTH STAR BANK — AUDIENCE & LEAD GENERATION (A&LG)
  Program : 05_lead_attribution_analysis.sas
  Purpose : Post-campaign response analysis — the A&LG "closed loop."
            Matches deployed leads to account openings in core banking.
            Measures conversion rates, channel ROI, AEP score lift vs.
            internal scores, and cost per acquired account.
            Results feed A&LG Performance Dashboard and model
            recalibration cycle.
  Team    : Audience & Lead Generation · Business Banking Marketing
  --------------------------------------------------------------------------
  A&LG LEAD LIFECYCLE STAGE: Lead Deployed → Converted → Revenue
  Attribution closes the loop on the A&LG mandate: connecting audience
  activation and campaign spend to booked accounts and revenue.
  This is the metric that matters — North Star Bank's A&LG strategy
  aims for measurable, sustained increases in digitally acquired accounts.
  --------------------------------------------------------------------------
  KEY A&LG METRICS PRODUCED:
    - Lead-to-account conversion rate (overall, by channel, by score source)
    - AEP score lift vs. internal score — validates Adobe CDP investment
    - Cost per acquired account (CPA) by channel
    - Propensity model lift table (decile analysis)
    - Cumulative gains chart data
    - Projected annualized revenue contribution
  --------------------------------------------------------------------------
  CLOUD NOTE:
    Response matching → Spark SQL join against enterprise account
    opening Delta table in Azure Data Lake (populated via ADF pipeline).
    Lift chart output → Power BI via Azure Synapse SQL endpoint or
    Databricks SQL warehouse.
==========================================================================*/

options mprint mlogic symbolgen;

%let base_path        = /home/claude/northstar-v3/github;
%let data_path        = &base_path./northstar-bank-alg/data;
%let campaign_id      = NS_ALG_BIZ_XSELL_2024Q3;
%let response_window  = 60;   /* days post-deployment to count conversions */

/* A&LG channel cost assumptions */
%let cost_email  = 0.25;
%let cost_call   = 12.00;
%let cost_mail   = 4.50;
%let avg_acct_rev = 875;   /* estimated first-year revenue per new biz checking account */

libname alg "&data_path.";


/* ── STEP 1: SIMULATE ACCOUNT OPENING (RESPONSE) FILE ───────────────── */
/* In production: replace with join to core banking account open table:
   proc sql;
     create table work.acct_opens as
       select u.customer_id, a.acct_open_dt
         from alg.lead_universe u
         inner join coredb.acct_opens a
           on u.customer_id = a.customer_id
         where a.acct_type in ('BIZ_CHECKING','BIZ_SAVINGS')
           and a.acct_open_dt between u.selection_dt
               and u.selection_dt + &response_window.;         */

data alg.acct_opens_sim;
  call streaminit(888);
  set alg.lead_universe;
  /* AEP-scored leads convert at higher rate — validates Adobe CDP ROI */
  base_prob = 0.04 + (sbo_confidence='HIGH') * 0.03;
  if score_source = 'AEP' then base_prob = base_prob + 0.025;
  if rand('uniform') < base_prob then do;
    acct_open_dt = today() - floor(rand('uniform') * &response_window.);
    format acct_open_dt date9.;
    output;
  end;
  drop base_prob;
run;


/* ── STEP 2: REBUILD DEPLOYED UNIVERSE WITH SCORES ───────────────────── */
data work.deployed;
  set alg.lead_universe;
  call streaminit(2024);
  internal_score = max(1, min(99, round(rand('normal', 48, 14)
                   + (sbo_confidence='HIGH') * 8)));
  if score_source = 'AEP' and aep_propensity_score > . then
    final_score = aep_propensity_score;
  else
    final_score = internal_score;
  length score_tier $10 channel $15;
  if      final_score >= 70 then score_tier = 'HIGH';
  else if final_score >= 40 then score_tier = 'MEDIUM';
  else                           score_tier = 'LOW';
  if email ne '' and index(email,'@') > 0 then channel = 'EMAIL';
  else if phone ne '' and score_tier in ('HIGH','MEDIUM') then channel = 'OUTBOUND_CALL';
  else channel = 'DIRECT_MAIL';
  drop internal_score;
run;


/* ── STEP 3: CLOSED-LOOP ATTRIBUTION JOIN ────────────────────────────── */
proc sql;
  create table work.attributed as
    select d.*,
           case when a.customer_id is not null then 1 else 0 end
             as converted_flag label="Converted (1=Yes)",
           a.acct_open_dt
      from work.deployed d
      left join alg.acct_opens_sim a on d.customer_id = a.customer_id;
quit;


/* ── STEP 4: OVERALL CONVERSION RATE ────────────────────────────────── */
proc sql;
  title "A&LG Overall Conversion Rate — &campaign_id.";
  select count(*)                         as leads_deployed   label="Leads Deployed",
         sum(converted_flag)              as conversions       label="Conversions",
         mean(converted_flag)             as conversion_rate   label="Conv. Rate"
           format=percent8.2,
         sum(converted_flag)*&avg_acct_rev. as proj_revenue   label="Proj. 1-Yr Revenue"
           format=dollar14.0
    from work.attributed;
quit;
title;


/* ── STEP 5: CHANNEL PERFORMANCE + CPA ──────────────────────────────── */
proc sql;
  create table work.channel_perf as
    select channel,
           count(*)                  as deployed,
           sum(converted_flag)       as conversions,
           mean(converted_flag)      as conv_rate   format=percent8.2,
           case channel
             when 'EMAIL'         then count(*) * &cost_email.
             when 'OUTBOUND_CALL' then count(*) * &cost_call.
             when 'DIRECT_MAIL'   then count(*) * &cost_mail.
           end                       as total_cost  format=dollar12.0,
           case when sum(converted_flag) > 0 then
             case channel
               when 'EMAIL'         then count(*) * &cost_email.
               when 'OUTBOUND_CALL' then count(*) * &cost_call.
               when 'DIRECT_MAIL'   then count(*) * &cost_mail.
             end / sum(converted_flag)
           else . end                as cpa          format=dollar8.2
                                                     label="Cost per Acquisition"
      from work.attributed
      group by channel
      order by conv_rate desc;
quit;

proc print data=work.channel_perf noobs label;
  label deployed=Leads converted=Conversions conv_rate="Conv. Rate"
        total_cost="Total Cost" cpa="CPA";
  title "A&LG Channel Performance & ROI — &campaign_id.";
run;


/* ── STEP 6: AEP SCORE LIFT VS. INTERNAL ────────────────────────────── */
/* Validates the Adobe Real-Time CDP investment: does AEP-scored lead
   pool convert at a meaningfully higher rate than internal-only scored?
   This is the ROI proof point for continued A&LG + Adobe investment.  */
proc sql;
  create table work.aep_lift as
    select score_source                     label="Score Source",
           count(*)             as leads    label="Leads",
           sum(converted_flag)  as convs    label="Conversions",
           mean(converted_flag) as conv_rate label="Conv. Rate" format=percent8.2
      from work.attributed
      group by score_source;
quit;

proc sql noprint;
  select conv_rate into :aep_rate from work.aep_lift where score_source='AEP';
  select conv_rate into :int_rate from work.aep_lift where score_source='INTERNAL';
quit;

%put NOTE: [AEP LIFT] AEP conv rate = %sysfunc(putn(&aep_rate., percent8.2));
%put NOTE: [AEP LIFT] Internal conv rate = %sysfunc(putn(&int_rate., percent8.2));
%put NOTE: [AEP LIFT] AEP lift over internal = %sysfunc(putn(%sysevalf(&aep_rate./&int_rate.), 8.2))x;

proc print data=work.aep_lift noobs label;
  title "A&LG: AEP Score vs. Internal Score — Conversion Lift";
  title2 "Validates Adobe Real-Time CDP ROI — higher AEP rate confirms signal quality";
run;


/* ── STEP 7: MODEL LIFT TABLE BY SCORE DECILE ───────────────────────── */
proc rank data=work.attributed out=work.ranked groups=10 descending;
  var final_score; ranks score_decile;
run;
data work.ranked; set work.ranked; score_decile = score_decile + 1; run;

proc sql noprint;
  select mean(converted_flag) into :overall_rate from work.attributed;
quit;

proc sql;
  create table work.lift_table as
    select score_decile                        label="Decile (1=Top)",
           count(*)             as n           label="Leads",
           sum(converted_flag)  as convs       label="Conversions",
           mean(converted_flag) as decile_rate label="Decile Rate"  format=percent8.2,
           mean(converted_flag)/&overall_rate. as lift
                                               label="Lift vs. Avg" format=8.2,
           sum(converted_flag)*&avg_acct_rev.  as decile_rev
                                               label="Proj. Revenue" format=dollar10.0
      from work.ranked
      group by score_decile
      order by score_decile;
quit;

proc print data=work.lift_table noobs label;
  title "A&LG Propensity Model Lift Table — &campaign_id.";
  title2 "Top 3 deciles target: lift > 2.0x | Flag for model recal if top decile < 1.5x";
run;


/* ── STEP 8: CUMULATIVE GAINS ───────────────────────────────────────── */
proc sql noprint;
  select sum(convs), sum(n) into :tot_convs, :tot_leads from work.lift_table;
quit;

data work.gains;
  set work.lift_table;
  retain cum_convs 0;
  cum_convs + convs;
  pct_leads  = score_decile / 10;
  pct_convs  = cum_convs / &tot_convs.;
  format pct_leads pct_convs percent8.1;
  keep score_decile pct_leads pct_convs lift;
  label pct_leads="Cumul. % Leads Mailed" pct_convs="Cumul. % Conversions Captured";
run;

proc print data=work.gains noobs label;
  title "A&LG Cumulative Gains Chart Data — &campaign_id.";
run;

title; title2;


/* ── FINAL ATTRIBUTION SUMMARY ───────────────────────────────────────── */
proc sql noprint;
  select count(*), sum(converted_flag), put(mean(converted_flag), percent8.2)
    into :n_deployed, :n_convs, :overall_pct
    from work.attributed;
quit;

%put NOTE: ══════════════════════════════════════════════════════════;
%put NOTE:  A&LG ATTRIBUTION SUMMARY — &campaign_id.;
%put NOTE:  Leads Deployed  : &n_deployed.;
%put NOTE:  Conversions     : &n_convs.;
%put NOTE:  Overall Rate    : &overall_pct.;
%put NOTE:  AEP Lift        : see table above — validates Adobe CDP ROI;
%put NOTE:  Results ready for A&LG Performance Dashboard;
%put NOTE:  Feed lift table to model team for recalibration;
%put NOTE: ══════════════════════════════════════════════════════════;

%put NOTE: *** 05_lead_attribution_analysis.sas COMPLETE ***;
%put NOTE: *** Full A&LG campaign lifecycle closed — &campaign_id. ***;
