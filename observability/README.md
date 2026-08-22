# Observability stack

Prometheus, Alertmanager, Loki, Alloy, Grafana and cloudwatch-exporter, running
on k3s in the platform spoke.

Deployed by the `Observability` pipeline. The Helm values live here as
versioned files rather than inside a shell script, so a rebuilt k3s node gets
its stack back without anyone running anything by hand.

```
values/       Helm values, one file per chart
manifests/    Kubernetes resources applied directly, currently the alert rules
```

## Placeholders

Values files contain `__TOKENS__` substituted at deploy time, so no
environment-specific value is committed:

| Token | Source |
|---|---|
| `__REGION__` | workflow env |
| `__S3_BUCKET__` | `terraform output observability_bucket` |
| `__SOAR_INGEST_URL__` | `terraform output soar_ingest_url` |
| `__DEMO_TARGET__` | looked up from the instance ID |
| `__DEMO_INSTANCE_ID__` | `terraform output demo_workstation_id` |
| `__GRAFANA_PASSWORD__` | repository secret |

The validate job rejects any token the pipeline does not know how to
substitute, and the render step fails if one survives into the output. A
leftover placeholder would otherwise deploy a broken configuration silently.

## The link to SOAR

Alertmanager has exactly one receiver: a webhook pointing at the private SOAR
ingest endpoint. Every alert Prometheus fires becomes an event in the response
pipeline. That is REQ-NCA-P2-09, and the pipeline verifies it after every
deployment by posting a test event from inside the cluster. If that check ever
fails, the observability stack has stopped being part of the SOAR system
regardless of what the configuration says.

## Deploying manually

Prefer the pipeline. If you need to run it by hand, for example while the
runner is unavailable, render the values yourself and apply them the same way
the pipeline does. The steps are in `.github/workflows/04-observability.yml`
and are deliberately plain `helm upgrade --install` calls so they can be
reproduced by reading them.

## Why not the Terraform Helm provider

More literally infrastructure as code, and worth moving to. It needs to reach
the Kubernetes API at plan time, which from a runner outside the VPC means
carrying a kubeconfig through the bastion, and it introduces an ordering
problem because the cluster itself is defined in the same configuration.

Helm driven by a pipeline against versioned values gives the same
reproducibility with fewer moving parts, so that is what is implemented. The
provider is the production recommendation once the cluster and its workloads
are separated into different state.
