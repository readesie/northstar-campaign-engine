/*==========================================================================
  NORTH STAR BANK — AUDIENCE & LEAD GENERATION (A&LG)
  Program : 01_data_discovery.sas
  Purpose : Inventory and profile all source systems feeding the
            Business Banking audience/lead universe. Audits SBO
            signal coverage across CRM, core banking, and third-party
            enrichment. Establishes the data foundation before any
            audience selection logic is written.
  Team    : Audience & Lead Generation · Business Banking Marketing
  Author  : A&LG Campaign Analytics
  Campaign: NS_ALG_BIZ_XSELL_2024Q3
  --------------------------------------------------------------------------
  A&LG CONTEXT:
    A&LG manages the full lifecycle: audience definition → lead
    qualification → channel deployment → attribution. Data discovery
    is the foundation — it maps available signals, confirms join key
    integrity across source systems, and validates SBO signal coverage
    before the audience selection waterfall begins.

    In the broader A&LG stack, audience definitions may also arrive
    from Adobe Real-Time CDP or Supernatural AI synthetic audience
    outputs. This program handles the SAS execution layer that
    activates those upstream audience definitions into deployable
    lead files.
  --------------------------------------------------------------------------
  CLOUD MIGRATION NOTE (Azure / Databricks):
    libname odbc → spark.read.format("delta").load("abfss://...")
    %PROFILE_TABLE → reusable PySpark df.describe() + groupBy()
    Macro variables → Databricks widgets or ADF pipeline parameters
    Results → Delta audit table in Azure Data Lake
==========================================================================*/

dm 'log;clear;output;clear;';
options mprint mlogic symbolgen;

/* ── CAMPAIGN PARAMETERS ─────────────────────────────────────────────── */
%let base_path    = /home/u1557222/northstar_campaign_engine;
%let data_path    = &base_path./northstar-bank-alg/data;
%let campaign_id  = NS_ALG_BIZ_XSELL_2024Q3;
%let run_date     = %sysfunc(today(), yymmddn8.);
%let audience_seg = SBO_BIZMISSING_35_60;  /* A&LG audience segment ID */

libname alg "&data_path.";

/*
  IN PRODUCTION — replace with ODBC / cloud connections:
  libname crm    odbc dsn="NSB_CRM_PROD"      schema=mktg;
  libname coredb odbc dsn="NSB_COREBANK_PROD" schema=acct;
  libname aep    odbc dsn="NSB_AEP_EXPORT"    schema=audiences;
  libname enrich odbc dsn="NSB_THIRDPARTY"    schema=sbo;
*/


/* ── STEP 1: GENERATE SYNTHETIC SOURCE DATA ──────────────────────────── */
/* Simulates four source systems A&LG draws from:
   1. CRM customer master
   2. Core banking account flags
   3. Third-party SBO enrichment (D&B / Acxiom-style)
   4. Adobe AEP audience export (propensity / segment membership)  */

/* --- 1a: CRM Customer Master --- */
data alg.crm_customers;
  call streaminit(42);
  length customer_id $12 first_name $20 last_name $25
         state $2 email $60 phone $12 relationship_mgr $30
         preferred_language $10;
  format acct_open_dt date9.;
  array fnames[10] $20 _temporary_ (
    'James' 'Patricia' 'Robert' 'Linda' 'Michael'
    'Barbara' 'William' 'Jennifer' 'David' 'Susan');
  array lnames[10] $25 _temporary_ (
    'Smith' 'Johnson' 'Williams' 'Jones' 'Brown'
    'Davis' 'Miller' 'Wilson' 'Moore' 'Taylor');
  array states[5] $2 _temporary_ ('MN' 'WI' 'ND' 'SD' 'IA');
  array rms[5] $30 _temporary_ (
    'Anderson, T.' 'Nguyen, M.' 'Patel, R.'
    'Garcia, L.'   'Thompson, K.');

  do i = 1 to 55000;
    customer_id        = cats('NSB', put(200000 + i, 6.));
    first_name         = fnames[ceil(rand('uniform') * 10)];
    last_name          = lnames[ceil(rand('uniform') * 10)];
    state              = states[ceil(rand('uniform') * 5)];
    email              = catx('@', lowcase(cats(first_name, last_name,
                             put(floor(rand('uniform')*99)+1, z2.))), 'mail.com');
    phone              = put(6120000000 + floor(rand('uniform')*9999999), 10.);
    birth_year         = 1948 + floor(rand('uniform') * 57);
    acct_open_dt       = '01JAN2008'd + floor(rand('uniform') * 5840);
    relationship_mgr   = rms[ceil(rand('uniform') * 5)];
    /* A&LG: ~18% Spanish-preferred — bilingual campaign capability */
    preferred_language = ifc(rand('uniform') < 0.18, 'ES', 'EN');
    output;
  end;
  drop i;
run;

/* --- 1b: Core Banking — existing business account holders (exclusion set) --- */
data alg.core_biz_accounts;
  call streaminit(99);
  length customer_id $12 biz_acct_type $20;
  format biz_acct_open_dt date9.;
  set alg.crm_customers (keep=customer_id);
  if rand('uniform') < 0.23 then do;
    biz_acct_type    = ifc(rand('uniform') < 0.6, 'BIZ_CHECKING', 'BIZ_SAVINGS');
    biz_acct_open_dt = '01JAN2015'd + floor(rand('uniform') * 3000);
    output;
  end;
run;

/* --- 1c: Third-Party SBO Enrichment — multi-source signal hierarchy --- */
/* A&LG uses a confidence tier system: self-report > loan app > third-party */
data alg.sbo_enrichment;
  call streaminit(77);
  length customer_id $12 sbo_signal_source $25 sbo_confidence $10 naics_code $6;
  set alg.crm_customers (keep=customer_id);
  if rand('uniform') < 0.42 then do;
    if      rand('uniform') < 0.30 then do;
      sbo_signal_source = 'CRM_SELF_REPORT';   sbo_confidence = 'HIGH';
    end;
    else if rand('uniform') < 0.45 then do;
      sbo_signal_source = 'LOAN_APPLICATION';  sbo_confidence = 'HIGH';
    end;
    else if rand('uniform') < 0.60 then do;
      sbo_signal_source = 'DNB_ENRICHMENT';    sbo_confidence = 'MEDIUM';
    end;
    else do;
      sbo_signal_source = 'ACXIOM_APPEND';     sbo_confidence = 'MEDIUM';
    end;
    naics_code = put(440000 + floor(rand('uniform') * 59999), 6.);
    output;
  end;
run;

/* --- 1d: Adobe AEP Audience Export --- */
/* Simulates a segment membership export from Adobe Real-Time CDP.
   In production: exported via AEP Destinations connector or SFTP drop.
   Contains AI-scored propensity and audience segment tags. */
data alg.aep_audience_export;
  call streaminit(314);
  length customer_id $12 aep_segment_id $30 aep_propensity_score 8
         aep_next_best_product $25 aep_last_updated 8;
  format aep_last_updated datetime20.;
  set alg.crm_customers (keep=customer_id);
  /* ~35% of CRM base present in AEP with SBO audience tag */
  if rand('uniform') < 0.35 then do;
    aep_segment_id         = 'SBO_BIZ_ACCT_XSELL_Q3';
    aep_propensity_score   = max(1, min(99, round(rand('normal', 55, 16))));
    aep_next_best_product  = 'BIZ_CHECKING';
    aep_last_updated       = datetime() - floor(rand('uniform') * 604800); /* within 7 days */
    output;
  end;
run;

/* --- 1e: Suppression File — opt-outs, deceased, regulatory holds --- */
data alg.alg_suppressions;
  call streaminit(11);
  length customer_id $12 suppress_type $30 suppress_channel $20;
  format suppress_dt date9.;
  set alg.crm_customers (keep=customer_id);
  if rand('uniform') < 0.09 then do;
    suppress_type    = ifc(rand('uniform') < 0.40, 'OPT_OUT_ALL_MKTG',
                       ifc(rand('uniform') < 0.50, 'OPT_OUT_EMAIL',
                       ifc(rand('uniform') < 0.60, 'DECEASED',
                                                   'REGULATORY_HOLD')));
    suppress_channel = ifc(suppress_type = 'OPT_OUT_EMAIL', 'EMAIL', 'ALL');
    suppress_dt      = '01JAN2023'd + floor(rand('uniform') * 600);
    output;
  end;
run;

/* --- 1f: Recent Contact File --- */
data alg.recent_contacts;
  call streaminit(55);
  length customer_id $12 last_campaign_id $35 last_channel $15;
  format last_contact_dt date9.;
  set alg.crm_customers (keep=customer_id);
  if rand('uniform') < 0.18 then do;
    last_contact_dt  = today() - floor(rand('uniform') * 90);
    last_campaign_id = cats('NS_ALG_PRIOR_Q', put(floor(rand('uniform')*4)+1, 1.));
    last_channel     = ifc(rand('uniform') < 0.4, 'EMAIL',
                       ifc(rand('uniform') < 0.5, 'DIRECT_MAIL', 'CALL'));
    output;
  end;
run;


/* ── STEP 2: PROFILE ALL SOURCE TABLES ───────────────────────────────── */

%macro profile_table(lib=, tbl=, keycol=);
  proc sql noprint;
    select count(*)                 into :n_rows     from &lib..&tbl.;
    select count(&keycol.)          into :n_key      from &lib..&tbl.;
    select count(distinct &keycol.) into :n_distinct from &lib..&tbl.;
  quit;
  %put NOTE: %nrstr([A&LG PROFILE]) &lib..&tbl. | ROWS=%trim(&n_rows.) | KEY_NONMISS=%trim(&n_key.) | DISTINCT=%trim(&n_distinct.);
%mend profile_table;
options nomlogic nosymbolgen nomprint;
%profile_table(lib=alg, tbl=crm_customers,      keycol=customer_id);
%profile_table(lib=alg, tbl=core_biz_accounts,  keycol=customer_id);
%profile_table(lib=alg, tbl=sbo_enrichment,     keycol=customer_id);
%profile_table(lib=alg, tbl=aep_audience_export,keycol=customer_id);
%profile_table(lib=alg, tbl=alg_suppressions,   keycol=customer_id);
%profile_table(lib=alg, tbl=recent_contacts,     keycol=customer_id);
options mlogic symbolgen mprint;

/* ── STEP 3: SBO SIGNAL COVERAGE AUDIT ───────────────────────────────── */

proc freq data=alg.sbo_enrichment;
  tables sbo_signal_source * sbo_confidence / nocum norow nocol;
  title "%nrstr(A&LG): SBO Signal Source x Confidence Tier";
run;

/* AEP propensity score distribution */
proc means data=alg.aep_audience_export n mean std min max;
  var aep_propensity_score;
  title "%nrstr(A&LG): Adobe AEP Propensity Score Distribution (SBO Segment)";
run;

/* Language preference — bilingual campaign planning */
proc freq data=alg.crm_customers;
  tables preferred_language / nocum;
  title "%nrstr(A&LG): Customer Language Preference (EN/ES Split)";
run;

/* Suppression breakdown */
proc freq data=alg.alg_suppressions;
  tables suppress_type suppress_channel / nocum;
  title "%nrstr(A&LG): Suppression File — Type and Channel Breakdown";
run;

/* Age distribution — target band coverage */
data work.age_profile;
  set alg.crm_customers;
  age = year(today()) - birth_year;
  in_target_band = (age >= 35 and age <= 60);
run;

proc means data=work.age_profile n mean std min max;
  var age;
  title "%nrstr(A&LG): CRM Base Age Distribution";
run;

proc freq data=work.age_profile;
  tables in_target_band / nocum;
  title "%nrstr(A&LG): Target Age Band (35-60) Coverage";
run;

title;

%put NOTE: *** 01_data_discovery.sas COMPLETE — %nrstr(A&LG) source systems inventoried ***;
%put NOTE: *** Adobe AEP export present: %sysfunc(attrn(%sysfunc(open(alg.aep_audience_export)),nobs)) records ***;
%put NOTE: *** Proceed to 02_audience_lead_selection.sas ***;
