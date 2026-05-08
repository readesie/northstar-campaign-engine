/*==========================================================================
  NORTH STAR BANK — AUDIENCE & LEAD GENERATION (A&LG)
  Program : 03_data_quality_control.sas
  Purpose : Pre-deployment QC validation on the A&LG lead universe.
            Zero-tolerance policy for suppression leakage and existing
            account holder deployment — both are compliance events.
            Critical failures halt deployment via %ABORT CANCEL.
  Team    : Audience & Lead Generation · Business Banking Marketing
  --------------------------------------------------------------------------
  QC TIER POLICY:
    CRITICAL — %ABORT CANCEL: campaign cannot deploy, full stop
    WARNING  — log alert + flag record, A&LG lead manager reviews
    INFO     — distribution sanity check, no action required
  --------------------------------------------------------------------------
  CLOUD NOTE (Databricks / Azure):
    Maps to a Great Expectations validation suite or custom
    df.filter() + assert blocks in a Databricks QC notebook.
    QC results written to Delta audit table in Azure Data Lake.
    %ABORT CANCEL → raise ValueError() in notebook job step.
==========================================================================*/

options mprint mlogic symbolgen;

%let base_path      = /home/u1557222/northstar_campaign_engine;
%let data_path      = &base_path./northstar-bank-alg/data;
%let campaign_id    = NS_ALG_BIZ_XSELL_2024Q3;
%let expected_min   = 5000;
%let expected_max   = 35000;
%let missing_thresh = 0.05;

libname alg "&data_path.";


/* ── QC MACRO FRAMEWORK ─────────────────────────────────────────────── */

%macro critical_check(name=, condition=, msg=);
  %if &condition. %then %do;
    %put ERROR: ══════════════════════════════════════════════════════;
    %put ERROR:  A&LG CRITICAL QC FAILURE — &name.;
    %put ERROR:  &msg.;
    %put ERROR:  DEPLOYMENT HALTED. DO NOT SEND TO FULFILLMENT.;
    %put ERROR: ══════════════════════════════════════════════════════;
    %abort cancel;
  %end;
  %else %put NOTE: [QC PASS] &name.;
%mend critical_check;

%macro warn_check(name=, condition=, msg=);
  %if &condition. %then
    %put WARNING: [QC WARN] &name.: &msg.;
  %else
    %put NOTE: [QC PASS] &name.;
%mend warn_check;

%macro check_missing(field=);
  proc sql noprint;
    select (count(*) - count(&field.)) / count(*)
      into :miss_rate from alg.lead_universe;
  quit;
  %let miss_pct = %sysfunc(putn(&miss_rate., percent8.2));
  %critical_check(
    name      = Missing_rate_&field.,
    condition = %sysevalf(&miss_rate. > &missing_thresh.),
    msg       = &field. missing rate = &miss_pct. — threshold is %sysevalf(&missing_thresh.*100)%
  );
%mend check_missing;


/* ── CHECK 1: UNIVERSE RECORD COUNT ────────────────────────────────── */
proc sql noprint;
  select count(*) into :universe_n from alg.lead_universe;
quit;
%critical_check(
  name=Universe_below_floor, condition=%eval(&universe_n. < &expected_min.),
  msg=Universe = &universe_n. — below minimum &expected_min.
);
%critical_check(
  name=Universe_above_ceiling, condition=%eval(&universe_n. > &expected_max.),
  msg=Universe = &universe_n. — above maximum &expected_max.
);
%put NOTE: [QC INFO] Universe = &universe_n. (acceptable: &expected_min.–&expected_max.);


/* ── CHECK 2: ZERO DUPLICATE CUSTOMER IDs ───────────────────────────── */
proc sql noprint;
  select count(*) into :dup_n from (
    select customer_id from alg.lead_universe
    group by customer_id having count(*) > 1);
quit;
%critical_check(
  name=No_duplicate_customer_ids, condition=%eval(&dup_n. > 0),
  msg=&dup_n. duplicate customer_id values found in lead universe
);


/* ── CHECK 3: REQUIRED FIELD MISSING RATES ──────────────────────────── */
%check_missing(field=customer_id);
%check_missing(field=first_name);
%check_missing(field=last_name);
%check_missing(field=email);
%check_missing(field=phone);
%check_missing(field=state);
%check_missing(field=alg_stage);
%check_missing(field=campaign_id);


/* ── CHECK 4: EMAIL FORMAT VALIDATION ───────────────────────────────── */
data work.qc_email;
  set alg.lead_universe;
  email_valid = prxmatch(
    '/^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$/',
    strip(email)) > 0;
run;
proc sql noprint;
  select mean(1 - email_valid) into :email_fail from work.qc_email;
quit;
%warn_check(
  name=Email_format_validity,
  condition=%sysevalf(&email_fail. > 0.02),
  msg=%sysfunc(putn(&email_fail.,percent8.2)) of emails fail format check
);


/* ── CHECK 5: AGE RANGE — NO OUT-OF-BAND RECORDS ───────────────────── */
proc sql noprint;
  select count(*) into :age_viol
    from alg.lead_universe where age < 35 or age > 60;
quit;
%critical_check(
  name=Age_range_compliance, condition=%eval(&age_viol. > 0),
  msg=&age_viol. records found outside age 35-60 band
);


/* ── CHECK 6: SUPPRESSION LEAKAGE — ZERO TOLERANCE ─────────────────── */
/* A&LG policy: any suppressed customer in deployment = compliance event.
   This check cross-references directly against the suppression file.   */
proc sql noprint;
  select count(*) into :supp_leak
    from alg.lead_universe u
    inner join alg.alg_suppressions s on u.customer_id = s.customer_id;
quit;
%critical_check(
  name=Suppression_leakage_ZERO_TOLERANCE, condition=%eval(&supp_leak. > 0),
  msg=&supp_leak. suppressed customers found in lead universe — COMPLIANCE RISK
);


/* ── CHECK 7: EXISTING BUSINESS ACCOUNT LEAKAGE ─────────────────────── */
proc sql noprint;
  select count(*) into :biz_leak
    from alg.lead_universe u
    inner join alg.core_biz_accounts b on u.customer_id = b.customer_id;
quit;
%critical_check(
  name=Existing_biz_acct_leakage, condition=%eval(&biz_leak. > 0),
  msg=&biz_leak. existing biz acct holders in lead universe — wasted spend + poor CX
);


/* ── CHECK 8: A&LG STAGE TAG ────────────────────────────────────────── */
proc sql noprint;
  select count(*) into :stage_bad
    from alg.lead_universe where alg_stage ne 'LEAD_QUALIFIED';
quit;
%warn_check(
  name=ALG_stage_tag, condition=%eval(&stage_bad. > 0),
  msg=&stage_bad. records have unexpected alg_stage value
);


/* ── CHECK 9: AEP SCORE COVERAGE SANITY ────────────────────────────── */
proc sql noprint;
  select mean(score_source='AEP') into :aep_cov from alg.lead_universe;
quit;
%warn_check(
  name=AEP_propensity_coverage,
  condition=%sysevalf(&aep_cov. < 0.20),
  msg=AEP score coverage = %sysfunc(putn(&aep_cov.,percent8.1)) — below 20% expected
);
%put NOTE: [QC INFO] AEP score coverage = %sysfunc(putn(&aep_cov., percent8.1));


/* ── INFO DISTRIBUTIONS ─────────────────────────────────────────────── */
proc freq data=alg.lead_universe;
  tables state sbo_confidence preferred_language / nocum;
  title "QC Info: Lead Universe Distribution — State · SBO Confidence · Language";
run;

proc means data=alg.lead_universe n mean std min max;
  var age aep_propensity_score;
  title "QC Info: Age and AEP Propensity Score Statistics";
run;

title;

%put NOTE: ══════════════════════════════════════════════════════;
%put NOTE:  A&LG QC SUMMARY — &campaign_id.;
%put NOTE:  Universe      : &universe_n. records;
%put NOTE:  All CRITICAL checks: PASS;
%put NOTE:  AEP Coverage  : %sysfunc(putn(&aep_cov., percent8.1));
%put NOTE:  Review WARNING lines above — cleared for channel assignment;
%put NOTE: ══════════════════════════════════════════════════════;

%put NOTE: *** 03_data_quality_control.sas COMPLETE ***;
%put NOTE: *** Proceed to 04_channel_assignment.sas ***;
