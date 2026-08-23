---
title: "Test Plan and Results"
subtitle: "Innovatech Solutions. Hybrid Cloud, Observability and SOAR"
author: "Stoyan Iliev. Fontys ICT, Network & Cloud Automation"
date: "August 2026"
---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# 1. Approach

Testing was executed, not described. Every result in this document came from running the system against the deployed environment, and the failures are recorded alongside the passes because the failures produced the more useful findings.

Tests fall into three groups:

- **Functional.** does each component do what it is supposed to?
- **End-to-end.** does an event travel the whole path and change the environment?
- **Resilience.** what happens when something breaks?

The end-to-end tests are scripted (`scripts/test-soar-bruteforce.ps1`, `scripts/test-soar-quarantine.ps1`) so they can be re-run on demand rather than reproduced by hand. Each prints the relevant system state before and after, and states a pass or fail verdict against a concrete criterion.

# 2. Environment

| | |
|---|---|
| Account | AWS 182460207849, Fontys Innovation Sandbox |
| Region | eu-central-1 |
| Platform NACL | `acl-068c30bcdb9226b04` |
| Quarantine group | `sg-0b4ece4aff6a3eebe` |
| Demo target | `i-049e95348a865e18d` (`SOARable=true`) |
| Ingest endpoint | `https://lb535ebwpi.execute-api.eu-central-1.amazonaws.com/prod/events` |
| Test source address | `203.0.113.66` (TEST-NET-3, reserved for documentation) |

# 3. Functional tests

| # | Test | Method | Expected | Result |
|---|---|---|---|---|
| F-01 | Account capability probe | Enumerate service access before designing | Constraints known in advance | **Pass**, see 3.1 |
| F-02 | Terraform plan is clean | `terraform plan` on a converged environment | No unexpected changes | **Pass** |
| F-03 | Remote state locking | S3 backend with DynamoDB lock | Concurrent runs blocked | **Pass** |
| F-04 | Transit Gateway segmentation | Inspect route table associations | Spokes reach hub only, plus one declared exception | **Pass** |
| F-05 | Data spoke isolation | Inspect route table | No default route present | **Pass** |
| F-06 | Private API rejects public access | Resolve and call the ingest URL from outside the VPC | Denied | **Pass** |
| F-07 | Private API accepts internal calls | POST from the k3s node | HTTP 200 | **Pass**, see 3.2 |
| F-08 | k3s cluster healthy | `kubectl get nodes` | Node `Ready` | **Pass** |
| F-09 | Observability stack running | `kubectl get pods -n monitoring` | All pods `Running` | **Pass**, 10/10 |
| F-10 | Loki writes to S3 | List the bucket after log ingestion | Chunks and index objects present | **Pass**, see 3.3 |
| F-11 | SOAR metrics reach Prometheus | Scrape cloudwatch-exporter | `innovatech_soar` series present | **Pass** |
| F-12 | Event stored before queueing | Inspect DynamoDB after submission | Event present | **Pass** |
| F-13 | SOAR unit suite | `python3 -m unittest discover` | All tests pass | **Pass**, 50 tests, one defect found |
| F-14 | Playbook integrity gate | Pipeline validation job | Malformed playbooks fail the build | **Pass** |
| F-15 | Observability deployed by pipeline | Observability workflow | Stack applied from versioned values, all pods Running | **Pass**, 1m36s |
| F-16 | Monitoring to SOAR path verified per deployment | Post-deploy check in the pipeline | HTTP 200 from inside the cluster | **Pass** |
| F-17 | On-premises forwarder agent running | `systemctl is-active soar-forwarder` on corp-server | active | **Pass** |
| F-18 | SOAR dashboard imported from versioned JSON | ConfigMap labelled `grafana_dashboard` present | Dashboard visible in Grafana | **Pass** |
| F-19 | On-premises host is monitored, not just a source | Prometheus targets | corp-server scraped, appears in the estate view | **Pass** |

## 3.1 F-01. Capability probe

Run before any design work, on the principle that an architecture built against assumed permissions is an architecture that fails at deployment time.

Findings that changed the design:

| Capability | Result | Consequence |
|---|---|---|
| `iam:CreateRole` | Permitted | Per-component least-privilege roles became possible |
| `eks:*` | Denied by SCP | k3s on EC2 instead of managed Kubernetes |
| `aps:*` (Managed Prometheus) | Denied | Self-hosted Prometheus |
| Transit Gateway, VPC, EIP creation | Permitted (dry-run) | Hub-and-spoke as designed |
| `servicequotas:GetServiceQuota` | Denied by SCP | Quota headroom unverifiable; noted as a risk |

**The probe was incomplete, and that mattered.** It tested `rds:DescribeDBInstances`, a read action, and inferred that RDS was available. The SCP denies `rds:CreateDBInstance`, a write action, which was only discovered when the deployment failed. This is recorded as a finding in Section 6.1.

## 3.1a F-13, the unit suite

50 tests covering collector parsing, rule engine matching and correlation, and the refusal conditions on both destructive actions. They use only the standard library with the AWS SDK stubbed, so they run on any machine with a Python interpreter.

The suite found a defect that would not have surfaced in normal operation. The rule engine read the event identifier directly when logging a non-match, so an event without that field would raise a `KeyError`. Because the handler processes an SQS batch, that single bad message would have failed the whole batch rather than only itself. The collector always sets the field, so no live event would have triggered it, but a replayed message would.

Fixed by reading the field with a fallback. The test that exposed it is a batch-handling test asserting that one malformed message is reported for retry while a valid message alongside it succeeds.

The AWS calls are deliberately not unit tested. Mocking a cloud provider proves the mock behaves, not the system. That confidence comes from the end-to-end tests in Section 4, which assert on real state changes in the real account.

## 3.2 F-07. Private ingest reachability

Executed on the k3s node in the platform spoke:

```
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
 https://lb535ebwpi.execute-api.eu-central-1.amazonaws.com/prod/events \
 -H "Content-Type: application/json" \
 -d '{"event_type":"connectivity_test","severity":"low", ... }'
```

Result: **200**.

This confirms the requirement that monitoring can feed the SOAR pipeline. It also validates the second interface endpoint added in the platform spoke. Before that endpoint existed, the same request resolved to a public address and was rejected by the API's resource policy, which was the expected and correct behaviour for a private API.

## 3.3 F-10. Monitoring data in object storage

```
aws s3 ls s3://innovatech-observability-9e024ca1/ --recursive
```

Returned Loki chunk objects and TSDB index objects, confirming that log data is being written to S3 rather than held on local disk. The `fake/` path prefix is Loki's default tenant identifier when multi-tenancy is disabled, not an error.

# 4. End-to-end tests

## 4.1 E-01. PB-001, external SSH brute force

**Objective.** Prove that a correlated attack pattern produces an automatic change to network state with no human involvement.

**Method.** Five `ssh_auth_failure` events from `203.0.113.66`, submitted through the collector. PB-001 requires five occurrences within five minutes from an external address.

**Result. PASS.**

| Stage | Evidence |
|---|---|
| Ingest | 5 events accepted, distinct event IDs returned |
| Store | 5 events in DynamoDB |
| Correlate | Threshold met; PB-001 matched |
| Dispatch | `block_ip` and `notify` published to EventBridge |
| **Respond** | **NACL rule 101 created: DENY `203.0.113.66/32`** |
| Record | Block recorded with playbook ID, event ID, and expiry |

NACL state before and after:

```
BEFORE AFTER
32767 0.0.0.0/0 101 203.0.113.66/32
 32767 0.0.0.0/0
```

Elapsed from first event to network change: under 25 seconds.

**Significance.** This is the demonstration the previous submission lacked. The system detected a pattern that no single event revealed, decided on a response from a declarative rule, and changed the network. Nothing was triggered manually and no operator was involved.

## 4.2 E-02. PB-002, host compromise indicator

**Objective.** Prove the second, structurally different response action. Host-level isolation rather than network filtering.

**Method.** One `privilege_escalation_attempt` event naming instance `i-049e95348a865e18d`.

**Result. PASS on the second attempt.** The first attempt failed on an IAM authorisation boundary; that failure is documented in Section 5.1 because it produced a better outcome than a clean pass would have.

| Stage | Evidence |
|---|---|
| Ingest | Event accepted |
| Match | PB-002 matched in 152 ms |
| Dispatch | `quarantine_host` and `notify` published |
| **Respond** | **Security group changed from `sg-0eb7e12fcddcdfed3` to `sg-0b4ece4aff6a3eebe`** |
| Record | Original groups stored for restoration |
| State | Instance remains `Running`, forensics preserved |

## 4.3 E-03. On-premises syslog event source

**Objective.** Prove that alerts originate from an on-premises server with no part of the event fabricated, and that the internal-address guard holds on real data.

**Method.** Six SSH login attempts against `corp-server` using accounts that do not exist. sshd rejects each and writes `Invalid user <name> from <address>` to `/var/log/auth.log` itself. The forwarder agent reads what sshd wrote. No password is needed, so nothing is simulated at any point in the chain.

**Chain under test.**

```
ssh attempt -> sshd -> auth.log -> forwarder agent -> private API Gateway
-> collector -> DynamoDB + SQS -> rule engine
```

**Result, part one: ingestion.**

| Stage | Evidence |
|---|---|
| Origin | Real `Invalid user` lines in auth.log, written by sshd |
| Forward | Agent journal shows each line posted |
| Ingest | Events stored with source `syslog`, host `corp-server.innovatech.internal` |
| Classify | `ssh_auth_failure`, severity high, source address extracted |

**Result, part two: the guard.** PB-001 did not fire, and no block was created. The attempts originate from the bastion, which holds an internal address, so the playbook's `source_ip_is_external` condition evaluated false and the rule engine declined to act.

That is the correct outcome and it is the more valuable half of this test. E-05 verifies the same guard with a synthetic event; this verifies it against traffic the system genuinely observed. An automated blocker that can be induced to block internal addresses can lock its own operators out of the environment, so the refusal path deserves testing on real input rather than only on input constructed to trigger it.

Blocking of external addresses is covered by E-01.

**Two defects this test exposed.**

*The forwarder crashed on the first line it tried to forward.* The tail loop iterated the file with `for line in fh` and called `fh.tell()` inside it to record its offset. Python disallows that combination, because the iterator reads ahead in blocks and the position `tell()` would report is not the position after the current line. It raises `OSError: telling position disabled by next() call`.

The failure mode was quiet in the worst way. The agent started, logged that it was watching the file and which endpoint it would post to, then died on the first match. systemd restarted it, and it repeated. By the time this test ran the restart counter had reached 371. Every log line said the agent was working; the service status said `activating` rather than `active`, which is the only visible difference and is easy to read past.

Fixed by reading with `readline()` in a while loop, which does not disable `tell()`. The agent had no tests at all, which is why a defect this basic reached deployment. Nine tests were added that exercise the real tail loop against a real file, covering the regression itself, offset persistence across restarts, rotation handling, and partial lines.

*The forwarder and the collector disagreed about what an SSH failure looks like.* The forwarder sends four patterns including `Invalid user`, but the collector only classified `Failed password` and `Failed publickey`. Invalid-user events arrived, fell through to `syslog_generic`, lost their source address, and matched no playbook. Nothing failed loudly: events were ingested and stored, they simply never did anything.

Fixed by adding the missing patterns, and guarded by a test asserting that every pattern the forwarder sends is classified by the collector, so the contract cannot drift again.

**What links them.** Both were failures of the gap between two components rather than of either component alone, and neither produced an error anywhere an operator would look. The forwarder is the only part of this system that runs unattended on a host nobody logs into, and it was the only part with no tests. That correlation is not a coincidence.

Run with `scripts/test-soar-onprem-syslog.ps1`.

## 4.4 E-04. Idempotency

**Method.** Re-run E-01 against an address already blocked.

**Result. Pass.** The action returned `already_blocked` with the existing rule number and emitted `ActionsSkipped` with reason `already_blocked`. No duplicate ACL entry was created. Repeated events from a persistent attacker therefore do not exhaust the ACL rule quota.

## 4.5 E-05. Safety guard, protected address range

**Method.** Submit a brute-force pattern with an RFC1918 source address.

**Result. Pass.** PB-001 did not match, because `source_ip_is_external` evaluated false. Had the event reached the action, a second guard would have refused it. The block was correctly not applied.

**Why this test matters.** An automated blocking system that can be induced to block internal addresses can lock its own operators out of the environment. Verifying the refusal path is as important as verifying the action path.

## 4.6 E-06. Block expiry

**Method.** Observe an active block past its 60-minute duration.

**Result. Pass.** The scheduled function removed the ACL entry and marked the DynamoDB record `expired`. Confirmed by a later console inspection showing the NACL returned to rules 100 and the implicit default only.

**Consequence if absent.** Blocks would accumulate against the ACL's twenty-rule default quota, after which no further blocks would be possible. a silent failure of the entire blocking capability.

# 5. Resilience tests

## 5.1 R-01. Partial action failure

**Not a designed test.** This occurred during E-02 and is the most informative result in this document.

**What happened.** `quarantine_host` failed with `UnauthorizedOperation`. `ModifyInstanceAttribute` with a `Groups` parameter authorises against both the instance *and* the target security group; the IAM policy covered only the instance ARN.

**What the architecture did:**

| Observation | Interpretation |
|---|---|
| `notify` for the same playbook succeeded | Actions are genuinely decoupled, one failure does not cascade |
| EventBridge retried at 17:41, 17:42, 17:44 | Retry policy behaved exactly as configured |
| `ActionsFailed` emitted on each attempt | Failure was observable, not silent |
| Rule engine logs showed a clean match and dispatch | The fault was correctly isolated to one component |

**Root cause.** Incomplete IAM policy. a resource-level authorisation requirement that is not obvious from the API name.

**Fix.** A second policy statement granting `ec2:ModifyInstanceAttribute` on the quarantine security group specifically.

**The fix improved the design.** Granting only the quarantine group. Rather than all security groups. Means the role can move a host *into* isolation and cannot move it out. A broader grant would have worked equally well functionally and been strictly worse. Restoration is now necessarily a human action, which is the correct behaviour for a decision that depends on an investigation.

**Re-test.** E-02 passed.

## 5.2 R-02. Platform node loss and rebuild

**Not a designed test.** The k3s node was found to have booted without k3s installed.

**Root cause.** The user-data script performs a one-shot `curl` to `get.k3s.io`, but the Transit Gateway routes it depends on are created in the same Terraform apply. When attachment creation was slow, the instance booted without egress, the install failed under `set -e`, and the node came up bare with no visible error.

**Recovery.** `terraform taint aws_instance.k3s_server` followed by `terraform apply`. The replacement node built itself from the same definition and reached `Ready` in under four minutes.

**Two findings:**

1. **The IaC genuinely reproduces the platform.** Rebuilding from code rather than patching by hand is the difference between infrastructure-as-code and infrastructure-as-documentation.
2. **The bootstrap has a real design weakness.** A one-shot network call at boot, depending on routes created concurrently, is fragile. The production fix is a retry loop with backoff, or a pre-baked machine image with no boot-time network dependency. This is recorded rather than quietly patched because it only surfaces when a system is actually built and run.

## 5.3 R-03. State recovery after credential expiry

**Not a designed test.** An SSO session expired mid-apply. Roughly 90 resources had been created in AWS but Terraform could not write state to S3.

**Recovery.** Terraform wrote `errored.tfstate` locally. After re-authenticating, `terraform force-unlock` released the stale DynamoDB lock and `terraform state push errored.tfstate` restored the record. A subsequent plan showed the environment converged, with only genuinely incomplete resources marked for replacement.

**Finding.** Remote state with versioning and locking, configured before any infrastructure, turned a potential rebuild-from-scratch into a two-command recovery. This validates the decision to build the state backend first.

**Operational consequence.** Re-authenticate immediately before every apply. A session with fifty minutes remaining is not enough for a fifteen-minute apply if the session started an hour ago.

## 5.4 R-04. Malformed event handling

**Method.** Submit invalid JSON to the ingest endpoint.

**Result. Pass.** HTTP 400 returned, `EventsRejected` emitted with reason `malformed_json`, nothing written to the event store. The partial batch response configuration means a malformed message in a batch does not cause valid messages alongside it to be redelivered.

## 5.5 R-05. Registry credential expiry

**Not a designed test.** A deployment that had worked correctly failed roughly fifteen hours later, during an unrelated rollout.

**Symptom.** A new pod stuck in `ImagePullBackOff` while two older pods of the same deployment kept running normally.

**Root cause.** Container registries authenticate with HTTP Basic auth, a username and a password. There is no place in the registry protocol for an AWS signature, so holding `ecr:BatchGetImage` on the node role does not by itself let containerd pull. ECR instead exchanges an IAM identity for a temporary password through `ecr:GetAuthorizationToken`, valid for twelve hours, which is stored in a Kubernetes secret and handed to containerd by the kubelet.

The secret had been created once, by hand, during the initial deployment. Fifteen hours later the token inside it had expired. The kubelet presented it, ECR refused it, and the pull failed.

**Why the running pods were unaffected.** Their images were already on disk. Only a pod that needs to pull is affected, which is why the failure appeared during a rollout rather than at the moment of expiry. A credential problem that stays invisible until the next deployment is worse than one that fails immediately, because the deployment that surfaces it is not the deployment that caused it.

**Fix.** A systemd timer on the node mints a fresh token and overwrites the secret every six hours, against a twelve-hour lifetime, so a single missed run still leaves a valid credential. `Persistent=true` means a run missed while the node was off fires at next boot. The unit is installed by the k3s bootstrap, so a rebuilt node has it from the start.

**Note on the platform choice.** EKS would not need this: AWS ships an ECR credential provider inside the EKS kubelet that performs the token exchange on every pull. k3s does not include it. This is one of the few concrete costs of the k3s decision recorded in Section 8.1 of the design document, and it is worth stating plainly rather than presenting k3s as equivalent in every respect.

**Generalisation.** A credential whose lifetime is shorter than the system's uptime needs renewal machinery, not a setup step. The same reasoning already applied to the SSO session used by the pipeline runner, which expired twice during this project for the same underlying reason.

## 5.6 R-06. Planned instance replacement and automated recovery

**The only failure test here that was designed rather than encountered**, and the one that answers the question the others could not: can the platform be destroyed and restored without a person rebuilding it by hand?

**Method.** A Terraform change forced replacement of both the hybrid gateway and the k3s server. The plan was routed through the pipeline's approval gate, approved deliberately, and recovery was performed entirely by re-running pipelines.

**What was destroyed.** Both EC2 instances, and with them the entire container platform: k3s itself, Prometheus, Alertmanager, Loki, Alloy, Grafana, cloudwatch-exporter, the SOAR console, the ECR credential timer, and the Tailscale subnet router.

**Result.**

| Stage | Outcome |
|---|---|
| Apply | Both instances replaced, new private and public addresses issued |
| SOAR response path | **Unaffected throughout.** No interruption at any point |
| k3s bootstrap | Completed unattended, including the ECR credential timer |
| Observability pipeline | Restored the full stack, addresses read from Terraform state, nothing edited |
| Console pipeline | Restored the container, pulled from ECR without manual credential setup |
| Verification | `test-soar-bruteforce.ps1` passed, address blocked as NACL rule 101 |

**The result that matters most.** The brute-force test passed immediately after both instances were replaced, with no manual intervention, because the response pipeline runs on Lambda and has no dependency on either machine. Detection through to containment survived a rebuild of the entire platform layer. That is the design-for-failure claim in REQ-NCA-P2-01 demonstrated rather than argued.

**Second most important.** The container pulled its image without anyone touching ECR credentials. When this same rebuild happened accidentally the day before, the pull failed and required manual intervention, because the credential timer had been installed by hand and did not survive. Moving it into the bootstrap fixed a class of problem rather than an instance of one, and this test is what proves it.

**One manual step remained, and it was not the one documented.** The operations manual said to approve the Tailscale subnet routes after a rebuild, which is correct. What it did not say is that a replaced instance registers as a *new* tailnet machine with a suffixed hostname, `innovatech-aws-gw-1`, while the old entry lingers showing as disconnected. Approving routes on the old entry appears to work and silently does nothing. Corrected in the manual.

**Recovery profile.**

| Component | Unavailable during recovery |
|---|---|
| SOAR detection and response | Not at all |
| Event ingest and storage | Not at all |
| Monitoring and dashboards | From destruction until the observability pipeline completed |
| SOAR console | From destruction until the console pipeline completed |
| Hybrid connectivity | Until the new subnet routes were approved |

**Note on how this test came about.** The approval gate stopped an earlier accidental attempt at the same change. Being forced to review the plan prompted the question of what would break, which exposed that the observability stack was not reproducible at the time. The control found a design flaw before it found a destructive change, and this test only became safe to run because of what it found.

# 6. Findings

## 6.1 Read permissions do not imply write permissions

The capability probe tested `Describe*` actions and inferred service availability. The SCP denies `rds:CreateDBInstance` while permitting `rds:DescribeDBInstances`, so RDS appeared available and was not.

Discovered mid-deployment, costing an unplanned redesign of the data layer.

**Lesson.** Probe with the action you intend to use. `--dry-run` where the API supports it; a create-then-delete probe where it does not. This was subsequently applied to Transit Gateway, VPC and Elastic IP creation before relying on any of them.

## 6.2 A constraint produced a better architecture

The RDS denial forced monitoring data onto S3 and SOAR state onto DynamoDB.

The result is better than the original design. Object storage is what production observability deployments actually use for retention. Durability is far higher than a single database instance, capacity planning disappears, and retention becomes a lifecycle rule. DynamoDB suits the SOAR event workload better than a relational store, because events are written once and read by key with no joins.

**Lesson.** A constraint is worth interrogating before it is worked around. The workaround here was better than the plan.

## 6.3 Bootstrap ordering is a real dependency

Covered in 5.2. The general form: user-data that depends on network paths created in the same apply is a race, and it fails silently rather than loudly.

## 6.4 Testing refusal paths matters as much as testing action paths

E-04 verifies that the system declines to act. For a system with destructive capabilities, the guards are the most safety-critical code in it, and untested guards are assumptions.

The `ActionsSkipped` metric with a reason dimension exists so that refusals are visible in operation rather than looking like inaction.

# 7. Coverage

| Requirement | Verified by |
|---|---|
| P2-01 Design-for-failure | R-01, R-02, R-03, R-05 |
| P2-02 Network segmentation | F-04, F-05 |
| P2-03 Private resource access | F-05, F-06, F-07 |
| P2-04 Internal DNS | F-04 (zone associations), design document |
| P2-05 Observability stack | F-09, F-10, F-15, F-19 |
| P2-06 Event-driven SOAR | E-01, E-02, E-03, F-17, R-01 |
| P2-07 Serverless components | F-09, E-01, E-02 |
| P2-08 SOAR self-monitoring | F-11, F-18 |
| P2-09 Observability in SOAR | F-07, F-16 (verified on every deployment) |
| P2-10 Infrastructure as Code | F-02, F-03, F-15, R-02, R-03 |
| P2-11 CI/CD | F-13, F-14, F-15, F-16, and the four pipeline definitions |
| P2-12 DevOps platform | GitHub repository, Actions, self-hosted runner |

# 8. Not tested

Recorded honestly rather than omitted.

| Area | Why | Risk |
|---|---|---|
| On-premises event source end to end | Hyper-V hosts not joined to the tailnet within the project window | Medium, the cloud path is proven and the syslog parser is unit-verified, but the physical hybrid link is unexercised |
| Sustained load | No load generation performed | Low, SQS and Lambda absorb bursts by design, but the throughput ceiling is unmeasured |
| Availability zone failure | Cannot be induced in a sandbox account | Low, managed services are multi-AZ; the k3s single node is a known and documented limitation |
| Route 53 Resolver inbound from on-premises | Depends on the on-premises hosts above | Medium, the endpoint exists and resolves inside the VPCs |
| Full disaster recovery from empty account | Time | Medium, partial evidence exists from R-02 and R-03 |
