/*==========================================================================
  NORTH STAR BANK — AUDIENCE & LEAD GENERATION (A&LG)
  Program : 04_channel_assignment.sas
  Purpose : Assign qualified leads to deployment channels using a
            propensity score that blends AEP scores (where present)
            with an internal fallback. Produce vendor-formatted
            output files per channel.
  Team    : Audience & Lead Generation · Business Banking Marketing
  --------------------------------------------------------------------------
  A&LG LEAD LIFECYCLE STAGE: Lead Qualified → Lead Deployed
  Channel assignment is where A&LG transitions from analytics to
  execution. AEP scores — derived from Adobe Real-Time CDP's blend
  of online and offline behavioral data — take priority over internal
  scores, reflecting richer signal from the personalization layer.
  --------------------------------------------------------------------------
  CHANNEL COST HIERARCHY (A&LG standard):
    1. Email       — lowest cost; deploy when valid email present
    2. Outbound Call — medium cost; AEP HIGH or internal HIGH/MEDIUM
    3. Direct Mail  — highest cost; remainder
  Note: EN/ES language flag passed through to each output file
  for bilingual creative versioning downstream.
  --------------------------------------------------------------------------
  CLOUD NOTE:
    AEP scores in production arrive via AEP Destinations connector
    to ADLS Gen2 Delta table — already joined in Program 02.
    PROC EXPORT → df.write.csv() to ADLS delivery container.
    Adobe Journey Optimizer handles the real-time email/push channel;
    this file feeds the batch direct mail and call center channels.
==========================================================================*/

dm 'log;clear;output;clear;';
options mprint mlogic symbolgen;

%let base_path   = /home/u1557222/northstar_campaign_engine;
%let data_path   = &base_path./northstar-bank-alg/data;
%let output_path = &base_path./northstar-bank-alg/output;
%let campaign_id = NS_ALG_BIZ_XSELL_2024Q3;
%let run_date    = %sysfunc(today(), yymmddn8.);

libname alg "&data_path.";


/* ── STEP 1: BUILD FINAL PROPENSITY SCORE ────────────────────────────── */
/* Priority: AEP score (blends online + offline via Adobe CDP) > internal.
   Internal score = simulated here; in production comes from model output. */
data work.scored;
  set alg.lead_universe;
  call streaminit(2024);

  /* Internal fallback propensity */
  internal_score = max(1, min(99, round(rand('normal', 48, 14)
                   + (sbo_confidence = 'HIGH') * 8)));

  /* Final score: AEP wins where present */
  if score_source = 'AEP' and aep_propensity_score > . then
    final_score = aep_propensity_score;
  else
    final_score = internal_score;

  /* Score tier for channel routing */
  length score_tier $10;
  if      final_score >= 70 then score_tier = 'HIGH';
  else if final_score >= 40 then score_tier = 'MEDIUM';
  else                           score_tier = 'LOW';

  drop internal_score;
  label final_score  = "Final Propensity Score (AEP preferred)"
        score_tier   = "Score Tier (HIGH/MEDIUM/LOW)"
        score_source = "Score Source (AEP or INTERNAL)";
run;


/* ── STEP 2: CHANNEL ASSIGNMENT ──────────────────────────────────────── */
data work.deployed;
  set work.scored;
  length channel $15 channel_reason $60;

  if email ne '' and index(email, '@') > 0 then do;
    channel        = 'EMAIL';
    channel_reason = 'Valid email — lowest cost; AJO handles real-time personalization';
  end;
  else if phone ne '' and score_tier in ('HIGH', 'MEDIUM') then do;
    channel        = 'OUTBOUND_CALL';
    channel_reason = 'No email; phone present; propensity qualifies for call center';
  end;
  else do;
    channel        = 'DIRECT_MAIL';
    channel_reason = 'Fallback: no email; ineligible or low-score for call';
  end;

  alg_stage = 'LEAD_DEPLOYED';
  label channel        = "%nrstr(A&LG) Deployment Channel"
        channel_reason = "Channel Assignment Rationale";
run;

proc freq data=work.deployed;
  tables channel / nocum;
  title "%nrstr(A&LG) Channel Assignment Distribution";
run;

/* Score source breakdown by channel */
proc freq data=work.deployed;
  tables channel * score_source / nocum norow nopct;
  title "AEP vs. Internal Score Coverage by Channel";
run;

/* Language split by channel — for bilingual creative routing */
proc freq data=work.deployed;
  tables channel * preferred_language / nocum norow nopct;
  title "EN/ES Language Split by Channel";
run;

title;


/* ── STEP 3: EXPORT CHANNEL FILES ────────────────────────────────────── */

/* EMAIL — to ESP / Adobe Journey Optimizer batch feed */
data work.out_email;
  set work.deployed (where=(channel='EMAIL'));
  keep campaign_id customer_id first_name last_name email
       final_score score_tier score_source preferred_language
       sbo_confidence state selection_dt;
  rename first_name        = FIRST_NM
         last_name         = LAST_NM
         email             = EMAIL_ADDR
         preferred_language= LANG_CD
         final_score       = PROPENSITY_SCORE;
run;
proc export data=work.out_email
  outfile="&output_path./&campaign_id._EMAIL_&run_date..csv"
  dbms=csv replace;
run;
%put NOTE: [OUTPUT] EMAIL — %sysfunc(attrn(%sysfunc(open(work.out_email)),nobs)) records;


/* OUTBOUND CALL — to predictive dialer, formatted phone */
data work.out_call;
  set work.deployed (where=(channel='OUTBOUND_CALL'));
  phone_fmt = cats('(', substr(phone,1,3), ') ',
                    substr(phone,4,3), '-', substr(phone,7,4));
  keep campaign_id customer_id first_name last_name phone_fmt
       score_tier final_score score_source preferred_language
       sbo_confidence relationship_mgr selection_dt;
  rename first_name        = CONTACT_FIRST
         last_name         = CONTACT_LAST
         phone_fmt         = DIALER_NUMBER
         preferred_language= LANG_CD
         relationship_mgr  = ASSIGNED_RM;
run;
proc export data=work.out_call
  outfile="&output_path./&campaign_id._CALL_&run_date..csv"
  dbms=csv replace;
run;
%put NOTE: [OUTPUT] CALL — %sysfunc(attrn(%sysfunc(open(work.out_call)),nobs)) records;


/* DIRECT MAIL — to mail house vendor */
data work.out_mail;
  set work.deployed (where=(channel='DIRECT_MAIL'));
  call streaminit(303);
  length address1 $50 city $20 zip $5;
  address1 = cats(floor(rand('uniform')*8999)+1001, ' Commerce Dr');
  city     = 'Minneapolis';
  zip      = put(55401 + floor(rand('uniform')*98), 5.);
  keep campaign_id customer_id first_name last_name
       address1 city state zip final_score preferred_language selection_dt;
  rename first_name        = FIRST_NM
         last_name         = LAST_NM
         preferred_language= LANG_CD;
run;
proc export data=work.out_mail
  outfile="&output_path./&campaign_id._MAIL_&run_date..csv"
  dbms=csv replace;
run;
%put NOTE: [OUTPUT] MAIL — %sysfunc(attrn(%sysfunc(open(work.out_mail)),nobs)) records;


/* ── STEP 4: A&LG DEPLOYMENT SUMMARY ────────────────────────────────── */
proc sql;
  create table work.deploy_summary as
    select channel,
           count(*)                   as leads         label="Leads Deployed",
           mean(final_score)          as avg_score      label="Avg Score"    format=6.1,
           sum(score_source='AEP')    as aep_scored_n   label="AEP-Scored",
           sum(preferred_language='ES') as spanish_n    label="Spanish (ES)",
           sum(score_tier='HIGH')     as high_n         label="High Tier",
           sum(score_tier='MEDIUM')   as med_n          label="Med Tier",
           sum(score_tier='LOW')      as low_n          label="Low Tier"
      from work.deployed
      group by channel
      order by avg_score desc;
quit;

proc print data=work.deploy_summary noobs label;
  title "%nrstr(A&LG) Deployment Summary — &campaign_id.";
  title2 "Deliver to Business Banking Marketing + %nrstr(A&LG) Lead Manager";
run;

title; title2;

%put NOTE: *** 04_channel_assignment.sas COMPLETE ***;
%put NOTE: *** Output files written to &output_path. ***;
%put NOTE: *** Proceed to 05_lead_attribution_analysis.sas after response window ***;
