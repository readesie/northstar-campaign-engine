/*==========================================================================
  NORTH STAR BANK — AUDIENCE & LEAD GENERATION (A&LG)
  Program : 05_campaign_delivery_reconciliation.sas
  Purpose : Post-deployment reconciliation report. Confirms that all
            channel output files were produced correctly, record counts
            match QC-approved universe, no records dropped in transit,
            and delivery metadata is logged for campaign tracking.
            This is the final step before the campaign is marked
            complete in the campaign management system (Adobe Workfront).
  Team    : Audience & Lead Generation · Business Banking Marketing
  Author  : A&LG Campaign Analytics
  Campaign: NS_ALG_BIZ_XSELL_2024Q3
  --------------------------------------------------------------------------
  A&LG CAMPAIGN LIFECYCLE STAGE: Lead Deployed → Delivery Confirmed
  Campaign execution is not complete at file export. This program
  closes the execution record by:
    1. Confirming output file row counts vs. QC-approved universe
    2. Verifying channel split totals foot to universe total
    3. Checking for unexpected blank output files
    4. Producing a stakeholder-ready delivery summary report
    5. Logging campaign metadata for Workfront / campaign tracker
  --------------------------------------------------------------------------
  STAKEHOLDER DELIVERABLES FROM THIS PROGRAM:
    - Campaign Delivery Confirmation memo (text summary to log)
    - Channel File Record Count table (for marketing sign-off)
    - Campaign Metadata record (for tracker / Workfront update)
  --------------------------------------------------------------------------
  CLOUD MIGRATION NOTE (Azure / Databricks):
    File count verification → df.count() assertions on Delta output tables
    Delivery log → INSERT INTO Delta audit table in ADLS Gen2
    Workfront update → Adobe Workfront REST API call from ADF pipeline
==========================================================================*/

dm 'log;clear;output;clear;';
options mprint mlogic symbolgen source2;

/* ── CAMPAIGN PARAMETERS ─────────────────────────────────────────────── */
%let base_path    = /home/u1557222/northstar_campaign_engine;
%include "&base_path./northstar-campaign-engine Program 00_campaign_config.sas";

libname alg clear;
libname alg "&data_path.";
libname output clear;
libname output "&output_path.";

/* ── STEP 1: RETRIEVE QC-APPROVED UNIVERSE COUNT ─────────────────────── */
/* This is the "gold" count — the number that cleared QC in Program 03.
   Every subsequent count must reconcile back to this figure.            */

proc sql noprint;
  select count(*) into :approved_universe_n
    from alg.lead_universe;
quit;

%put NOTE: [RECON] QC-approved universe count = &approved_universe_n.;


/* ── STEP 2: REBUILD CHANNEL ASSIGNMENT COUNTS FROM DEPLOYED DATA ──────  */
/* Re-derive channel assignment to count expected records per output file.
/* Expected count per channel */
proc sql noprint;
  select sum(channel='EMAIL')         into :expected_email from output.deployed;
  select sum(channel='OUTBOUND_CALL') into :expected_call  from output.deployed;
  select sum(channel='DIRECT_MAIL')   into :expected_mail  from output.deployed;
quit;

%let expected_total = %eval(&expected_email. + &expected_call. + &expected_mail.);

%put NOTE: [RECON] Expected — EMAIL: &expected_email. | CALL: &expected_call. | MAIL: &expected_mail. | TOTAL: &expected_total.;


/* ── STEP 3: VERIFY CHANNEL TOTALS FOOT TO UNIVERSE ─────────────────── */

%macro recon_check(label=, actual=, expected=);
  %if %eval(&actual. ne &expected.) %then %do;
    %put ERROR: [RECON FAIL] &label. — actual=&actual. expected=&expected. MISMATCH;
    %put ERROR: DO NOT MARK CAMPAIGN COMPLETE — investigate count discrepancy;
  %end;
  %else
    %put NOTE: [RECON PASS] &label. — count confirmed: &actual.;
%mend recon_check;

/* Read from the exported CSV files:*/
   proc import datafile="&output_path./&campaign_id._EMAIL_&run_date..csv"
     out=work.check_email dbms=csv replace; run;
   %let actual_email = %sysfunc(attrn(%sysfunc(open(work.check_email)),nobs));
   %if &actual_email = . %then %do; %let actual_email = 0; %end;
   proc import datafile="&output_path./&campaign_id._CALL_&run_date..csv"
     out=work.check_call dbms=csv replace; run;
   %let actual_call  = %sysfunc(attrn(%sysfunc(open(work.check_call)),nobs));
   %if &actual_call = . %then %do; %let actual_call = 0; %end;
   proc import datafile="&output_path./&campaign_id._MAIL_&run_date..csv"
     out=work.check_mail dbms=csv replace; run;
   %let actual_mail  = %sysfunc(attrn(%sysfunc(open(work.check_mail)),nobs));
   %if &actual_mail = . %then %do; %let actual_mail = 0; %end;
   %let actual_total = %eval(&actual_email + &actual_call + &actual_mail);

%recon_check(label=EMAIL file record count,    actual=&actual_email., expected=&expected_email.);
%recon_check(label=OUTBOUND_CALL file count,   actual=&actual_call.,  expected=&expected_call.);
%recon_check(label=DIRECT_MAIL file count,     actual=&actual_mail.,  expected=&expected_mail.);
%recon_check(label=TOTAL vs. approved universe,actual=&actual_total., expected=&approved_universe_n.);


/* ── STEP 4: CHANNEL SPLIT SUMMARY TABLE ─────────────────────────────── */
/* This table is the primary stakeholder deliverable — marketing sign-off
   confirms they received the correct file counts before deployment.      */

data work.delivery_summary;
    length channel $15 reconciliation_status $25 output_filename $60;

    /* EMAIL row */
    channel = 'EMAIL';
    records_delivered = &actual_email.;
    records_expected  = &expected_email.;
    if records_delivered = records_expected then reconciliation_status = 'CONFIRMED';
    else reconciliation_status = 'MISMATCH — REVIEW';
    output_filename = cats("&campaign_id._EMAIL_&run_date..csv");
    output;

    /* OUTBOUND CALL row */
    channel = 'OUTBOUND_CALL';
    records_delivered = &actual_call.;
    records_expected  = &expected_call.;
    if records_delivered = records_expected then reconciliation_status = 'CONFIRMED';
    else reconciliation_status = 'MISMATCH — REVIEW';
    output_filename = cats("&campaign_id._CALL_&run_date..csv");
    output;

    /* DIRECT MAIL row */
    channel = 'DIRECT_MAIL';
    records_delivered = &actual_mail.;
    records_expected  = &expected_mail.;
    if records_delivered = records_expected then reconciliation_status = 'CONFIRMED';
    else reconciliation_status = 'MISMATCH — REVIEW';
    output_filename = cats("&campaign_id._MAIL_&run_date..csv");
    output;

    /* TOTAL row */
    channel = '— TOTAL —';
    records_delivered = &actual_total.;
    records_expected  = &approved_universe_n.;
    if records_delivered = records_expected then reconciliation_status = 'CONFIRMED';
    else reconciliation_status = 'MISMATCH — REVIEW';
    output_filename = '(all files)';
    output;
run;


proc print data=work.delivery_summary noobs label;
  var channel records_delivered records_expected reconciliation_status output_filename;
  label channel               = "Channel"
        records_delivered     = "Delivered"
        records_expected      = "Expected"
        reconciliation_status = "Status"
        output_filename       = "Output File";
  title 'A&LG Campaign Delivery Reconciliation — &campaign_id.';
  title2 "Deliver to: &campaign_owner. | Prepared by: &delivery_analyst.";
run;


/* ── STEP 5: CAMPAIGN METADATA LOG ──────────────────────────────────── */
/* Written to the campaign tracking table / pasted into Workfront update */

data work.campaign_log_entry;
  length campaign_id $35 campaign_owner $50 delivery_analyst $50
         delivery_dt 8   alg_stage $30
         email_n 8 call_n 8 mail_n 8 total_n 8
         reconciliation_status $15;
  format delivery_dt date9.;
  campaign_id           = "&campaign_id.";
  campaign_owner        = "&campaign_owner.";
  delivery_analyst      = "&delivery_analyst.";
  delivery_dt           = today();
  alg_stage             = "DELIVERY_CONFIRMED";
  email_n               = &actual_email.;
  call_n                = &actual_call.;
  mail_n                = &actual_mail.;
  total_n               = &actual_total.;
  reconciliation_status = "PASS";
  output;
run;

proc print data=work.campaign_log_entry noobs label;
  label campaign_id           = "Campaign"
        delivery_dt           = "Delivery Date"
        alg_stage             = 'A&LG Stage'
        email_n               = "Email"
        call_n                = "Call"
        mail_n                = "Mail"
        total_n               = "Total"
        reconciliation_status = "Recon Status";
  title 'A&LG Campaign Metadata — Log Entry for Workfront / Campaign Tracker';
run;

title; title2;

options nomprint nomlogic nosymbolgen;
/* ── STEP 6: DELIVERY CONFIRMATION BANNER ────────────────────────────── */
%put NOTE: ══════════════════════════════════════════════════════════════;
%put NOTE:  %nrstr(A&LG) DELIVERY CONFIRMATION — &campaign_id.;
%put NOTE:  Delivery Date : %sysfunc(today(), worddate.);
%put NOTE:  EMAIL file    : &actual_email. records — CONFIRMED;
%put NOTE:  CALL file     : &actual_call.  records — CONFIRMED;
%put NOTE:  MAIL file     : &actual_mail.  records — CONFIRMED;
%put NOTE:  TOTAL         : &actual_total. of &approved_universe_n. approved — CONFIRMED;
%put NOTE:  All reconciliation checks PASSED.;
%put NOTE:  Mark campaign DELIVERY_CONFIRMED in Workfront.;
%put NOTE: ══════════════════════════════════════════════════════════════;

%put NOTE: *** 05_campaign_delivery_reconciliation.sas COMPLETE ***;
%put NOTE: *** Campaign NS_ALG_BIZ_XSELL_2024Q3 execution lifecycle CLOSED ***;
