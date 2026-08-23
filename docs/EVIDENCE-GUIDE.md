# Evidence capture guide

**Status: complete.** Twenty screenshots were captured and are embedded in the
Design Document and the Test Plan and Results as Figures 1 to 21. The files
themselves are in `docs/evidence/`.

This document is retained as the record of what each image shows and why it was
chosen, and as the procedure to follow if the evidence has to be recaptured
against a rebuilt environment.

| Figure | File | Appears in |
|---|---|---|
| 1 | diagrams/network-architecture.png | Design, section 3 |
| 2 | e01-bruteforce-test-output.png | Test, 4.1 |
| 3 | e02-nacl-before.png | Test, 4.1 |
| 4 | e03-nacl-after.png | Test, 4.1 |
| 5 | e09-dynamodb-block.png | Test, 4.1 |
| 6 | e06-quarantine-test-output.png | Test, 4.2 |
| 7 | e04-instance-normal.png | Test, 4.2 |
| 8, 9 | e05-instance-quarantined.png, -pt2 | Test, 4.2 |
| 10 | e10-notification-email.png | Test, 4.2 |
| 11, 12 | o03-onprem-test.png, -pt2 | Test, 4.3 |
| 13 | o01-forwarder-active.png | Test, 4.3 |
| 14 | o02-authlog.png | Test, 4.3 |
| 15 | e07-iam-failure-logs.png | Test, 5.1 |
| 16, 17 | o04-soar-dashboard.png, -pt2 | Design, 4.4 |
| 18 | p06-soar-console.png | Design, 6.2 |
| 19 | p01-workflows-list.png | Design, 6.2 |
| 20 | p02-run-list.png | Design, 6.2 |
| 21 | p03-approval-prompt.png | Design, 6.2 |

The three pairs marked -pt2 are continuations of a screen too tall to capture
in one frame, not alternative takes.

## Before you start

Two of the shots are time-sensitive. An IP block disappears after 60 minutes when the expiry function lifts it, and a quarantined host stays quarantined until you restore it. So capture in this order: run the brute-force test, take shots E-01 through E-03, then run the quarantine test and take E-04 and E-05, then restore.

Log in to the console in a private window so no other account's resources appear in the frame.

---

## Evidence for the test results document

### E-01, brute force test output

**File:** `evidence/e01-bruteforce-test-output.png`
**Goes in:** Test Plan and Results, Section 4.1
**How:** Run `scripts/test-soar-bruteforce.ps1`, screenshot the whole terminal
**Must show:** the BEFORE table with two rules, the five events being accepted, the AFTER table with rule 101, and the green PASS verdict line

This is the single most important image in the submission. If only one screenshot survives, make it this one.

### E-02, network ACL before

**File:** `evidence/e02-nacl-before.png`
**Goes in:** Test Plan and Results, Section 4.1
**How:** VPC console, Network ACLs, `acl-068c30bcdb9226b04`, Inbound rules tab. Capture this *before* running the test.
**Must show:** rule 100 allow, and the `*` default deny. The ACL ID must be legible in the frame.

### E-03, network ACL after

**File:** `evidence/e03-nacl-after.png`
**Goes in:** Test Plan and Results, Section 4.1
**How:** Same screen, refreshed, immediately after the test passes
**Must show:** rule 101 denying `203.0.113.66/32`, sitting above the default

E-02 and E-03 side by side are the proof. Same screen, same ACL, one new rule, and nothing was clicked between them.

### E-04, instance security before quarantine

**File:** `evidence/e04-instance-normal.png`
**Goes in:** Test Plan and Results, Section 4.2
**How:** EC2 console, `i-049e95348a865e18d`, Security tab
**Must show:** security group `sg-0eb7e12fcddcdfed3 (innovatech-workload-normal)`, instance state Running

### E-05, instance security after quarantine

**File:** `evidence/e05-instance-quarantined.png`
**Goes in:** Test Plan and Results, Section 4.2
**How:** Same screen after `test-soar-quarantine.ps1`, with the Inbound rules and Outbound rules sections expanded
**Must show:** `sg-0b4ece4aff6a3eebe (innovatech-quarantine)`, both rule tables empty, instance still Running

The empty rule tables matter. Expand them rather than leaving them collapsed, because an empty table is the isolation and a collapsed section proves nothing.

### E-06, quarantine test output

**File:** `evidence/e06-quarantine-test-output.png`
**Goes in:** Test Plan and Results, Section 4.2
**How:** Terminal output of the quarantine script
**Must show:** BEFORE and AFTER security group IDs, the DynamoDB quarantine record, the PASS verdict

### E-07, the IAM failure

**File:** `evidence/e07-iam-failure-logs.png`
**Goes in:** Test Plan and Results, Section 5.1
**How:** Already saved as text. If you want an image, CloudWatch console, log group `/aws/lambda/innovatech-soar-action-quarantine-host`, the failed invocation
**Must show:** the `UnauthorizedOperation` message naming the security group ARN

Do not leave this one out because it is a failure. A test document with a diagnosed failure and a fix reads as real work; one where everything passed first time invites the question of what was not tested.

### E-08, rule engine log for the same event

**File:** `evidence/e08-rule-engine-success.png`
**Goes in:** Test Plan and Results, Section 5.1
**How:** CloudWatch, log group `/aws/lambda/innovatech-soar-rule-engine`, same timestamp
**Must show:** `matched PB-002`, `Dispatched quarantine_host`, `Dispatched notify`

Paired with E-07 this makes the isolation argument concrete: the engine worked, one action failed, the other succeeded.

### E-09, DynamoDB block record

**File:** `evidence/e09-dynamodb-block.png`
**Goes in:** Test Plan and Results, Section 4.1
**How:** DynamoDB console, `innovatech-soar-blocks`, Explore items
**Must show:** the CIDR, rule number, playbook ID, status active, expiry timestamp

### E-10, SNS notification email

**File:** `evidence/e10-notification-email.png`
**Goes in:** Test Plan and Results, Section 4.2
**How:** Your inbox, the message from the notify action
**Must show:** subject line, playbook ID, event details

Confirm the SNS subscription first if you have not. An unconfirmed subscription means the action succeeds and nothing arrives.

---

## Evidence for the design document

### D-01, Transit Gateway route tables

**File:** `evidence/d01-tgw-route-tables.png`
**Goes in:** Design Document, Section 3.3
**How:** VPC console, Transit gateway route tables, select the spoke table, Associations tab
**Must show:** both spoke attachments associated, and the Routes tab showing the default to hub plus the single platform-to-data exception

This is the segmentation claim made visible. Worth two images if the tabs will not fit in one.

### D-02, data spoke route table

**File:** `evidence/d02-data-spoke-routes.png`
**Goes in:** Design Document, Section 3.4
**How:** VPC console, Route tables, `rtb-0f1f2400c641cac50`, Routes tab
**Must show:** local, the two TGW routes, the S3 prefix list, and no `0.0.0.0/0` entry anywhere

The absence is the point. When presenting, say out loud that there is no default route rather than expecting anyone to notice a missing line.

### D-03, private API endpoint configuration

**File:** `evidence/d03-private-api.png`
**Goes in:** Design Document, Section 3.4
**How:** API Gateway console, `innovatech-soar-ingest`, Settings
**Must show:** endpoint type Private, both VPC endpoint IDs attached

### D-04, k3s cluster and monitoring pods

**File:** `evidence/d04-monitoring-pods.png`
**Goes in:** Design Document, Section 4.2
**How:** On the k3s node, `kubectl get pods -n monitoring`
**Must show:** all ten pods Running

### D-05, S3 objects written by Loki

**File:** `evidence/d05-loki-s3.png`
**Goes in:** Design Document, Section 4.3
**How:** S3 console, `innovatech-observability-9e024ca1`
**Must show:** the `index/` and chunk prefixes with objects and timestamps

This is the cloud-database requirement satisfied. It reads as an ordinary bucket listing, so add a caption saying what it proves.

### D-06, Grafana dashboard

**File:** `evidence/d06-grafana.png`
**Goes in:** Design Document, Section 4.4
**How:** Tunnel to Grafana, take a dashboard with data on it
**Must show:** live metrics, and ideally a SOAR panel

If SOAR panels are empty, run the brute-force test first so there is something to plot, then wait a minute for cloudwatch-exporter to pick it up.

### D-07, Lambda functions

**File:** `evidence/d07-lambda-functions.png`
**Goes in:** Design Document, Section 5.4
**How:** Lambda console, filtered on `innovatech-soar`
**Must show:** all six functions

### D-08, rule engine IAM policy

**File:** `evidence/d08-rule-engine-policy.png`
**Goes in:** Design Document, Section 5.5
**How:** IAM console, role `innovatech-soar-rule-engine`, the inline policy JSON
**Must show:** the whole policy, so it is visible that no write permission exists

The least-privilege claim is the strongest security argument in the project, and this image is the proof. Make sure the JSON is fully expanded and readable.

### D-09, EventBridge rules

**File:** `evidence/d09-eventbridge-rules.png`
**Goes in:** Design Document, Section 5.1
**How:** EventBridge console, custom bus `innovatech-soar`, Rules
**Must show:** the three action rules with their event patterns

---

## Evidence for the on-premises source and the dashboard

### O-01, the forwarder agent running

**File:** `evidence/o01-forwarder-active.png`
**Goes in:** Test Plan and Results, Section 4.3
**How:** SSH to corp-server, `systemctl status soar-forwarder`
**Must show:** active (running), and a few recent log lines showing forwarded events

### O-02, real auth failures on the host

**File:** `evidence/o02-authlog.png`
**Goes in:** Test Plan and Results, Section 4.3
**How:** On corp-server, `sudo tail -20 /var/log/auth.log` after running the test
**Must show:** `Failed password` lines with timestamps and source addresses

This is the shot that proves nothing was fabricated. The events in the pipeline correspond line for line to what sshd wrote here.

### O-03, on-premises test output

**File:** `evidence/o03-onprem-test.png`
**Goes in:** Test Plan and Results, Section 4.3
**How:** Full terminal output of `test-soar-onprem-syslog.ps1`
**Must show:** the forwarder journal, the syslog-sourced events table, the NACL before and after, and the PASS verdict

### O-04, SOAR Operations dashboard

**File:** `evidence/o04-soar-dashboard.png`
**Goes in:** Design Document, Section 4.4, and it is the primary evidence for REQ-NCA-P2-08
**How:** Tunnel to Grafana on port 30030, open the SOAR Operations dashboard
**Must show:** the six headline counters with non-zero values, and at least the response pipeline row

Run a SOAR test first and wait two minutes, so cloudwatch-exporter has scraped the metrics and the panels are populated. An empty dashboard proves it exists but not that it works.

### O-05, the funnel with real data

**File:** `evidence/o05-dashboard-pipeline-row.png`
**Goes in:** SOAR Design, Section 3.4
**How:** The response pipeline row of the dashboard, after a test run
**Must show:** ingested, matched, dispatched and executed as overlaid lines

Dispatched and executed tracking each other exactly is the visual proof that responses are completing rather than merely being ordered.

---

## Evidence for the CI/CD sections

### P-01, all four workflows

**File:** `evidence/p01-workflows-list.png`
**Goes in:** Design Document, Section 6.2
**How:** Actions tab, the left sidebar listing SOAR CI, Infrastructure, SOAR Console, Observability
**Must show:** all four names

One image covering P2-10, P2-11 and P2-12.

### P-02, the run list with mixed outcomes

**File:** `evidence/p02-run-list.png`
**Goes in:** Design Document, Section 6.2
**How:** Actions tab, the run list from a single commit
**Must show:** SOAR CI green, SOAR Console green, Infrastructure waiting

This is the best available image of the risk grading, because it shows two pipelines deploying on their own while a third stops for review, from the same push. Far more convincing than the paragraph describing it.

### P-03, the approval prompt

**File:** `evidence/p03-approval-prompt.png`
**Goes in:** Design Document, Section 6.2
**How:** The pending Infrastructure run, Review deployments
**Must show:** the plan summary with the instance replacements, and the approve or reject buttons

Caption it with why it stopped: the plan replaces two instances, which is what the gate exists for.

### P-04, SOAR CI passing

**File:** `evidence/p04-soar-ci-green.png`
**Goes in:** Test Plan and Results, Section 3.1a
**How:** A successful SOAR CI run, Unit tests job, test output expanded
**Must show:** the tests running and the OK line

### P-05, the observability deployment summary

**File:** `evidence/p05-observability-deploy.png`
**Goes in:** Design Document, Section 6.2
**How:** A successful Observability run, the job summary
**Must show:** the component table and the total duration

### P-06, the SOAR console

**File:** `evidence/p06-soar-console.png`
**Goes in:** Design Document, Section 6.2, and SOAR Design, Section 3.2
**How:** Tunnel to the console and screenshot the page
**Must show:** the three counters, at least one block row, at least one quarantine row, and some events

Run a SOAR test first if the tables are thin. A block showing status `expired` is worth having, because it proves the scheduled expiry function ran, which nothing else demonstrates visually.

### P-07, images in ECR

**File:** `evidence/p07-ecr-images.png`
**Goes in:** Design Document, Section 6.2
**How:** ECR console, the `innovatech/soar` repository
**Must show:** the image tags, which are commit SHAs rather than `latest`

Supports the tagging decision. Each tag traces to a commit.

---

## Inserting them in Word

Both documents are Word files, so the images go in directly. For each one:

1. Place the cursor at the end of the paragraph named in "Goes in"
2. Insert, Pictures, This Device
3. Right click, Insert Caption, position Below, and write a caption in the form: `Figure 3: Network ACL after PB-001 fired. Rule 101 was created automatically.`
4. Keep width to the text margin so nothing spills into the gutter

Caption every figure and refer to it by number in the surrounding text. An uncaptioned screenshot is decoration; a captioned one that the text points at is evidence.

## For the presentation

Four images carry the demonstration if the live run fails:

- E-02 and E-03, the ACL before and after
- E-04 and E-05, the instance before and after quarantine

Put each pair side by side on one slide with a single sentence underneath. That is the story in two slides, and it is the story the whole project exists to tell.

Two more are worth a slide each: P-02, the run list showing two pipelines deploying while a third waits for review, and P-06, the console with real blocks and quarantines on it.
