---
title: "Operations Manual"
subtitle: "Innovatech Solutions, Hybrid Cloud, Observability and SOAR"
author: "Stoyan Iliev, Fontys ICT, Network & Cloud Automation"
date: "August 2026"
---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# 1. Who this is for

Whoever runs the platform after handover. It assumes familiarity with AWS and Terraform but no prior knowledge of this specific build.

The design document explains why the system is shaped the way it is. This one explains how to keep it running.

# 2. Reference

## 2.1 Resources

| Item | Value |
|---|---|
| AWS account | 182460207849 |
| Region | eu-central-1 |
| Repository | github.com/stoyaniliev/CS2 |
| Terraform state | S3 `innovatech-cs2-tfstate-33aed9c1`, lock table `innovatech-cs2-tflock` |
| Bastion | 63.183.208.221 |
| k3s node | 10.1.10.149 |
| Demo target | i-049e95348a865e18d |
| Platform NACL | acl-068c30bcdb9226b04 |
| Quarantine group | sg-0b4ece4aff6a3eebe |
| Observability bucket | innovatech-observability-9e024ca1 |
| SOAR ingest | https://lb535ebwpi.execute-api.eu-central-1.amazonaws.com/prod/events |
| Event bus | innovatech-soar |

The bastion public address and the k3s private address change if either instance is replaced. Read them from `terraform output` rather than from this table if something looks wrong.

## 2.2 Lambda functions

| Function | Trigger | Purpose |
|---|---|---|
| `innovatech-soar-collector` | API Gateway | Normalise and store incoming events |
| `innovatech-soar-rule-engine` | SQS | Evaluate playbooks, dispatch decisions |
| `innovatech-soar-action-block-ip` | EventBridge | Write NACL deny entries |
| `innovatech-soar-action-quarantine-host` | EventBridge | Isolate an instance |
| `innovatech-soar-action-notify` | EventBridge | Publish to SNS |
| `innovatech-soar-block-expiry` | Schedule, 5 min | Lift expired blocks |

# 3. Access

## 3.1 Authenticating

The account uses IAM Identity Center. Sessions expire, and an expired session part way through a Terraform apply leaves resources created but unrecorded, which is tedious to recover from.

```
aws sso login
aws sts get-caller-identity
```

Run `aws sso login` immediately before any apply, not at the start of a working session. A full apply takes up to fifteen minutes and a session with fifty minutes left is not the same as a fresh one.

## 3.2 Reaching the cluster

The k3s node sits in a private subnet. Two routes in.

**Through the bastion.** The generated key is at the repository root as `innovatech-key.pem`, excluded from git.

```
ssh -i innovatech-key.pem ubuntu@63.183.208.221
ssh -i ~/key.pem ubuntu@10.1.10.149
```

The second hop needs the key present on the bastion. This works but weakens the security position, because it puts a credential for everything behind the bastion onto the bastion itself. Treat it as a stopgap.

**Through Session Manager.** Preferred, and no key material involved. Requires the session manager plugin installed locally.

```
aws ssm start-session --target i-02355e292d9f754a1 --region eu-central-1
```

On the node, kubectl needs the kubeconfig path:

```
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

## 3.3 Reaching Grafana

Tunnel from a workstation:

```
ssh -i innovatech-key.pem -L 3000:10.1.10.149:30030 ubuntu@63.183.208.221 -N
```

Then open `http://localhost:3000`. Credentials are admin and the password set at deployment. Change it before any real use.

Prometheus is on 30090 and Alertmanager on 30093, tunnelled the same way.

# 4. Routine checks

## 4.1 Daily

```
aws sqs get-queue-attributes --queue-url <ingest-dlq-url> \
  --attribute-names ApproximateNumberOfMessages --region eu-central-1
```

Both dead-letter queues should be empty. Anything in the ingest DLQ means events are failing evaluation; anything in the action DLQ means dispatches could not be delivered.

Check the Grafana SOAR panel for `ActionsFailed` above zero and `EventsUnmatched` trending upward. The first means responses are not completing. The second means real events are arriving that no playbook handles, which is a coverage gap rather than a fault.

## 4.2 Weekly

Confirm the block table has no entries stuck in `active` past their expiry:

```
aws dynamodb scan --table-name innovatech-soar-blocks --region eu-central-1 \
  --filter-expression "#s = :s" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"active"}}'
```

Entries older than their stated duration mean the expiry function has stopped running. Check its log group.

Confirm Terraform reports no drift:

```
cd terraform
aws sso login
terraform plan
```

An empty plan is the healthy state. Anything unexpected means something was changed outside code.

## 4.3 Monthly

Review the playbook set against `EventsUnmatched` by event type. The metric shows which real events currently produce no automated response, and it is the best guide to what should be automated next.

Check the S3 lifecycle is expiring objects as intended, and review spend against the estimate in the design document.

# 5. Common tasks

## 5.1 Deploying a playbook change

Playbooks are data. Edit `soar/playbooks/playbooks.json`, commit, and apply. The file is packaged into the rule engine, so Terraform sees the changed hash and redeploys the function.

```
cd terraform
terraform apply
```

Test with `enabled: false` first. A disabled playbook is still evaluated and logged, so you can confirm it matches what you expect before it is allowed to act.

## 5.2 Releasing a quarantined host

Deliberately manual. The SOAR role cannot do this, because it can attach only the quarantine group.

```
cd scripts
powershell -ExecutionPolicy Bypass -File .\restore-quarantined-host.ps1
```

The script reads the original security groups from the DynamoDB record rather than guessing, and marks the record released.

Investigate before releasing. The host was isolated because something indicated compromise.

## 5.3 Lifting a block early

```
aws ec2 delete-network-acl-entry --network-acl-id acl-068c30bcdb9226b04 \
  --rule-number <n> --region eu-central-1
```

Then update the DynamoDB record so the expiry function does not later try to remove a rule that no longer exists. `scripts/clear-soar-blocks.ps1` does both for every active block at once.

## 5.4 Rebuilding the k3s node

The node is defined in code and bootstraps itself, so replacement is the normal repair.

```
cd terraform
terraform taint aws_instance.k3s_server
terraform apply
```

Around four minutes to Ready. The bootstrap installs the ECR credential timer itself, so the node can pull container images without any manual setup. Then run the Observability workflow to restore the monitoring stack:

Actions, Observability, Run workflow.

It reads the new node address from Terraform state, so nothing needs editing after a rebuild. Roughly ten minutes for the four Helm charts.

The SOAR console comes back the same way: Actions, SOAR Console, Run workflow. It is not restored automatically either, because nothing under `soar/console/` changed.

Verify the bootstrap actually completed before deploying anything onto it:

```
ls -la /var/lib/cloud/k3s-bootstrap-complete
```

If that file is absent the install failed. Check `/var/log/user-data.log`. The known cause is the instance booting before Transit Gateway routes are available, which leaves it without egress.

## 5.5 Adding a spoke

The spoke module handles the VPC, subnets, attachment and routing. Add a module block, associate the attachment with the spoke route table, and propagate it into the hub table. Roughly fifteen lines, and it is the reason the Transit Gateway was chosen over peering.

Remember that a spoke needing the private ingest API also needs either its own interface endpoint or the shared private hosted zone described in the design document. Beyond three or four spokes the hosted zone is the better answer.

# 6. The pipelines

## 6.1 What runs when

| Workflow | Fires on | Gate |
|---|---|---|
| SOAR CI | any change under `soar/` | none, it is the gate |
| Infrastructure | changes under `terraform/` or `soar/` | automatic if the plan is additive, approval if it destroys anything |
| SOAR Console | changes under `soar/console/` | none |
| Observability | changes under `observability/` | none |

## 6.2 Why infrastructure apply behaves differently depending on the plan

The plan job counts how many resources would be destroyed or replaced and publishes that as a job output. Two apply jobs then compete on that value: one runs when the count is zero and has no environment attached, the other runs when it is not and targets the `production` environment, which has a required reviewer.

The effect is that routine changes deploy on merge and nothing waits for a person, while anything that would remove a resource pauses until someone looks at it. If a deployment appears stuck, check the Actions tab for a job awaiting review rather than assuming the runner is down.

To force the reviewed path for a change you want to look at first, trigger the workflow manually and it will still grade the plan the same way. To deploy something additive immediately, just merge it.

## 6.3 Adding a reviewer

Settings, Environments, `production`, Required reviewers. Without at least one reviewer configured, the gated job proceeds without pausing, which quietly removes the protection.

## 6.4 Redeploying the observability stack

Actions, Observability, Run workflow. Safe to run at any time: `helm upgrade --install` is idempotent, so an unchanged stack is a no-op.

Run it after rebuilding the k3s node, after changing anything under `observability/`, and as the first thing to try if monitoring is behaving oddly, since a clean redeploy is faster than diagnosing drift.

The values files hold placeholders rather than real values. Everything environment-specific comes from Terraform state at deploy time, so the files never need editing when an address or bucket name changes.

The last step posts a test event to the SOAR ingest endpoint from inside the cluster. If that step fails, Alertmanager cannot reach the ingest API, which means monitoring has stopped feeding the response pipeline even though both halves look healthy on their own.

## 6.5 The console

Deployed by pipeline on any change under `soar/console/`. Reach it by tunnelling to the k3s node:

```
ssh -i innovatech-key.pem -L 8080:10.1.10.149:30080 ubuntu@63.183.208.221 -N
```

It shows active blocks, quarantined hosts and recent events, refreshing every thirty seconds. Running a SOAR test in another window and watching the counters move is a reasonable smoke test of the whole pipeline.

If the page loads but the tables are empty, the pods are healthy and the tables are genuinely empty. If it does not load, check the rollout:

```
kubectl -n soar get pods
kubectl -n soar rollout status deployment/soar-console
```

## 6.6 Running the tests locally

```
cd soar/tests
python3 -m unittest discover -s . -p "test_*.py" -v
```

No dependencies. Run this before pushing; it takes under a second and catches the class of error that would otherwise fail the pipeline three minutes later.

# 7. Troubleshooting

## 7.1 An alert fired and nothing happened

Work forward through the pipeline.

```
aws logs tail /aws/lambda/innovatech-soar-collector --since 15m --region eu-central-1
```

No entries means the event never arrived. Check the Alertmanager configuration and that the ingest URL resolves from inside the cluster.

```
aws logs tail /aws/lambda/innovatech-soar-rule-engine --since 15m --region eu-central-1
```

Every non-match is logged with a reason. `severity mismatch` and `below threshold` are the two usual answers, and both are normal behaviour.

```
aws logs tail /aws/lambda/innovatech-soar-action-block-ip --since 15m --region eu-central-1
```

If the action ran and skipped, the log names the guard that refused.

## 7.2 An action is failing

Almost always permissions. The log will carry the API call and the resource it was denied on. Note that `ModifyInstanceAttribute` authorises against both the instance and the target security group, which is the exact failure encountered during testing.

Failures are visible as `ActionsFailed` in Grafana and retried twice by EventBridge before the message lands in the action DLQ.

## 7.3 Events arrive but are never processed

Check the queue trigger is enabled:

```
aws lambda list-event-source-mappings \
  --function-name innovatech-soar-rule-engine --region eu-central-1
```

`State` should be `Enabled`. If it is disabled, something switched it off, possibly the emergency stop in Section 7.

## 7.4 Blocks are not being created

Most likely the ACL rule range is exhausted. Network ACLs have a default quota of twenty rules, and the block action allocates from 100 to 400 within that limit.

```
aws ec2 describe-network-acls --network-acl-ids acl-068c30bcdb9226b04 \
  --region eu-central-1 --query "NetworkAcls[0].Entries[?RuleAction=='deny']"
```

If the list is long, the expiry function has stopped. Check its logs, then reset with `scripts/clear-soar-blocks.ps1`.

## 7.5 A pod is stuck in ImagePullBackOff

The ECR pull secret has expired. Registry authentication uses a password, and the ECR token behind that password lives twelve hours.

Check the timer first:

```
systemctl list-timers ecr-secret.timer --no-pager
```

If it is not listed, the unit was never installed on this node. Run
`soar/console/ecr/setup-ecr-auth.sh` on the node, which installs it.

If it is listed but the last run failed:

```
sudo journalctl -u ecr-secret.service --no-pager | tail -20
```

Force a refresh and restart the deployment:

```
sudo systemctl start ecr-secret.service
sudo kubectl -n soar rollout restart deployment/soar-console
```

Running pods are unaffected by an expired token, because their images are
already on disk. Only a pod that needs to pull fails, which is why this
surfaces during a rollout rather than at the moment of expiry.

## 7.6 Terraform state is locked

Usually a previous run that was interrupted.

```
terraform force-unlock <lock-id>
```

Only when you are certain no other run is active. If a run failed after creating resources but before writing state, Terraform leaves `errored.tfstate` in the working directory. Push it rather than starting again:

```
terraform state push errored.tfstate
terraform state list
```

## 7.7 Grafana shows no SOAR metrics

The metrics come from cloudwatch-exporter, which reads CloudWatch, which is populated by the Lambdas writing embedded metric format log lines. Check in that order.

```
kubectl -n monitoring logs deploy/cloudwatch-exporter-prometheus-cloudwatch-exporter
```

If the exporter is failing on permissions, the node instance profile is the thing to check.

Note that metrics only exist after the functions have run. On a quiet system the panels are legitimately empty. Run a test to generate data.

# 8. Emergency stop

If the system is responding incorrectly and must stop immediately, disable the queue trigger rather than deleting anything:

```
aws lambda update-event-source-mappings --uuid <mapping-uuid> --no-enabled
```

Events continue to be collected and stored. Nothing is evaluated and nothing acts. Re-enable with `--enabled` when the problem is understood.

This is preferable to removing resources because it is instant, reversible, and preserves the event stream, so nothing is lost while the cause is investigated.

To stop only one action, disable its EventBridge rule:

```
aws events disable-rule --name innovatech-soar-quarantine-host \
  --event-bus-name innovatech-soar --region eu-central-1
```

# 9. Recovery

## 9.1 Rebuilding from nothing

The environment is defined in code and can be rebuilt into an empty account.

```
cd terraform/bootstrap
terraform init && terraform apply
terraform output -raw backend_config | Out-File -Encoding ascii ..\backend.tf

cd ..
Copy-Item terraform.tfvars.example terraform.tfvars   # fill in the values
terraform init
terraform apply
```

Then deploy the observability stack onto the new k3s node.

Two things do not come back automatically. The SNS email subscription needs confirming from the inbox, and Tailscale subnet routes need approving in the Tailscale admin console. Both are manual by design, because both are consent steps.

**Approve the routes on the right machine.** A replaced instance registers as a new tailnet node with a suffixed hostname, `innovatech-aws-gw-1` and so on, while the old entry remains listed and shows as disconnected. Approving routes on the stale entry appears to succeed and has no effect, because that machine no longer exists. Check the connection status column, approve on the connected one, and delete the old entry so the list does not accumulate ghosts.

Around thirty minutes end to end, most of it Transit Gateway attachments and the k3s bootstrap.

## 9.2 What is not backed up

| Data | Situation |
|---|---|
| Terraform state | S3 versioning enabled, recoverable |
| SOAR events | DynamoDB point-in-time recovery enabled |
| Block and quarantine records | Point-in-time recovery enabled |
| Monitoring history | S3, durable, expires at 90 days by lifecycle rule |
| Grafana dashboards | **Not backed up.** Stored in the k3s node's local SQLite. Rebuilding the node loses them. Export any dashboard worth keeping to JSON and commit it. |

That last row is a real gap rather than an oversight to hide. The fix is to commit dashboard JSON into the repository so it is recreated on deployment.

# 10. Cost control

Steady state is roughly €256 per month. Two levers matter.

**Route 53 Resolver inbound endpoint** is the largest single line at about €90. Set `enable_resolver_inbound = false` when hybrid DNS is not needed. VPC-internal name resolution is unaffected.

**The k3s node** is a t3.large at about €60. It can be stopped when the platform is idle, though the observability stack then needs a few minutes to settle after it starts.

Do not destroy and recreate the Transit Gateway to save money. Attachment creation and deletion each take several minutes, and the saving is small relative to the disruption.
