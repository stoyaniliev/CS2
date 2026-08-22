# Evidence capture guide

Where each screenshot goes, what has to be visible in it, and how to get the system into the right state first.

Save everything into `docs/evidence/` using the filename in the first column. The documents reference these names, so keeping them exact means the captions line up.

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
