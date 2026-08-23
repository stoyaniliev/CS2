# Innovatech Solutions, hybrid cloud with automated security response

CS2-MA-NCA. A hybrid cloud platform on AWS whose centrepiece is a Security
Orchestration, Automation and Response system: security events from an
on-premises server, from Prometheus Alertmanager and from CloudWatch are
normalised into one schema, evaluated against declarative playbooks, and acted
on automatically.

Two response actions change infrastructure state without a human in the path. A
correlated brute force produces a DENY entry in a network ACL. A compromise
indicator isolates a host by replacing its security groups with a group that has
no rules, leaving the machine running so forensics remain possible. Measured end
to end at under twenty-five seconds.

## Layout

| Path | Contents |
|---|---|
| `terraform/` | All cloud infrastructure, and the reusable spoke VPC module |
| `soar/collector/` | Normalises events from every source into one schema |
| `soar/rule-engine/` | Evaluates playbooks, publishes decisions, holds no write permissions |
| `soar/actions/` | `block_ip`, `quarantine_host`, `notify`, and the scheduled block expiry |
| `soar/playbooks/` | The rules, as data rather than code |
| `soar/forwarder/` | Agent that runs on the on-premises server and tails its authentication log |
| `soar/console/` | Containerised read-only operations console, and its Kubernetes manifests |
| `soar/tests/` | 62 unit tests, standard library only |
| `observability/` | Helm values, alert rules, and the Grafana dashboard as versioned JSON |
| `scripts/` | End-to-end test scripts and operational helpers |
| `docs/` | Documentation set and the evidence referenced from it |
| `.github/workflows/` | Four pipelines |

## Running the tests

No dependencies. boto3 is stubbed, so the suite runs anywhere there is a Python
interpreter, which matters on a self-hosted runner.

```
cd soar/tests
python3 -m unittest discover -s . -p "test_*.py" -v
```

## Pipelines

| Workflow | Fires on | Gate |
|---|---|---|
| SOAR CI | changes under `soar/` | None; it is the gate |
| Infrastructure | changes under `terraform/` or `soar/` | Additive plans apply automatically; destructive plans require review |
| SOAR Console | changes under `soar/console/` | None |
| Observability | changes under `observability/` | None |

All four run on a self-hosted runner. A cloud-hosted runner cannot reach the
private state bucket, the k3s API, or the SOAR ingest endpoint.

## Documentation

Written in Markdown and converted to Word with pandoc. The Markdown is the
source and is what to review; the `.docx` files are generated from it and are
committed because they are the submitted deliverable.

Keeping documentation in a diffable format alongside the code is the same
argument as infrastructure as code. A design decision and the Terraform that
implements it can change in one commit, and the diff shows both.

| Document | Covers |
|---|---|
| `docs/01-design-document.md` | Architecture, technology justification, requirements traceability, cost |
| `docs/03-soar-design-and-playbooks.md` | Response logic, all five playbooks, how to extend them |
| `docs/04-operations-manual.md` | Running, troubleshooting, recovery, runner setup |
| `docs/05-test-plan-and-results.md` | Tests, results, and eight documented failures with root causes |
| `docs/06-reflective-report.md` | Process and lessons |

## Before committing

```
powershell -ExecutionPolicy Bypass -File .\CHECK-BEFORE-COMMIT.ps1
```

Verifies the local customisations that were silently reverted more than once
during this project by file overwrites, plus formatting, the test suite, and
that no credential is staged. It exists because being more careful was not
working; a check that fails loudly was.

## Not included in version control

`terraform.tfvars` holds a live Tailscale auth key, `innovatech-key.pem` is a
private key, and state files contain both. All are excluded. The pipelines read
their equivalents from repository secrets.
