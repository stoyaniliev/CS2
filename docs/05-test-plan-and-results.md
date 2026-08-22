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

## 4.3 E-03. Idempotency

**Method.** Re-run E-01 against an address already blocked.

**Result. Pass.** The action returned `already_blocked` with the existing rule number and emitted `ActionsSkipped` with reason `already_blocked`. No duplicate ACL entry was created. Repeated events from a persistent attacker therefore do not exhaust the ACL rule quota.

## 4.4 E-04. Safety guard, protected address range

**Method.** Submit a brute-force pattern with an RFC1918 source address.

**Result. Pass.** PB-001 did not match, because `source_ip_is_external` evaluated false. Had the event reached the action, a second guard would have refused it. The block was correctly not applied.

**Why this test matters.** An automated blocking system that can be induced to block internal addresses can lock its own operators out of the environment. Verifying the refusal path is as important as verifying the action path.

## 4.5 E-05. Block expiry

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
| P2-01 Design-for-failure | R-01, R-02, R-03 |
| P2-02 Network segmentation | F-04, F-05 |
| P2-03 Private resource access | F-05, F-06, F-07 |
| P2-04 Internal DNS | F-04 (zone associations), design document |
| P2-05 Observability stack | F-09, F-10 |
| P2-06 Event-driven SOAR | E-01, E-02, R-01 |
| P2-07 Serverless components | F-09, E-01, E-02 |
| P2-08 SOAR self-monitoring | F-11 |
| P2-09 Observability in SOAR | F-07 (Alertmanager webhook path) |
| P2-10 Infrastructure as Code | F-02, F-03, R-02, R-03 |
| P2-11 CI/CD | Pipeline definitions in repository |
| P2-12 DevOps platform | GitHub repository and Actions |

# 8. Not tested

Recorded honestly rather than omitted.

| Area | Why | Risk |
|---|---|---|
| On-premises event source end to end | Hyper-V hosts not joined to the tailnet within the project window | Medium, the cloud path is proven and the syslog parser is unit-verified, but the physical hybrid link is unexercised |
| Sustained load | No load generation performed | Low, SQS and Lambda absorb bursts by design, but the throughput ceiling is unmeasured |
| Availability zone failure | Cannot be induced in a sandbox account | Low, managed services are multi-AZ; the k3s single node is a known and documented limitation |
| Route 53 Resolver inbound from on-premises | Depends on the on-premises hosts above | Medium, the endpoint exists and resolves inside the VPCs |
| Full disaster recovery from empty account | Time | Medium, partial evidence exists from R-02 and R-03 |
