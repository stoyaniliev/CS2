---
title: "Reflective Report"
subtitle: "CS2-MA-NCA, Innovatech Solutions"
author: "Stoyan Iliev, Fontys ICT, Network & Cloud Automation"
date: "August 2026"
---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# 1. Why I did this project

I am doing this period again because of one thing. In my previous submission the SOAR system was not really there. The orchestration existed, some automation existed, but the R, the part where the system actually responds, was missing. My assessors asked about it and I could not show them anything that changed state on its own.

The reason I gave at the time was that a full SOAR implementation felt disproportionate for a project of this size. I had convinced myself that good engineering judgement meant not building more than the problem needed. That reasoning is fine in a job. It was the wrong reasoning here, because the assignment defines the scope, and the assignment named SOAR as the central deliverable. I decided the scope was negotiable when it was not.

Writing this down plainly matters more to me than defending the earlier decision. It was a scoping mistake, not a technical one, and it is the mistake I most want to avoid repeating.

So the goal for this period was narrow and specific: build a system where a security event causes the environment to change, with no human in the path, and be able to prove it. Everything else in the project exists to support that.

# 2. How I planned it

I worked alone, so planning was mostly about sequencing rather than coordination.

I split the work into four phases and ordered them by dependency:

1. Discover what the AWS account allows
2. Network and platform
3. SOAR pipeline
4. Observability, testing, documentation

Putting discovery first was a decision I made because of how my previous project went, where I hit permission limits during deployment and had to redesign under pressure. This time I wrote a probe script and ran it before designing anything.

I gave myself two days of build and one day of documentation, with the deadline as buffer. That split turned out to be roughly right, though documentation took longer than I expected and I was still writing on the final day.

# 3. What happened

## 3.1 Discovery paid for itself, then failed me

The probe found things that changed the design before I wrote any Terraform. EKS is denied by a service control policy, so I used k3s. Managed Prometheus is denied, so I self-hosted. Role creation is permitted, which was the useful surprise, because my previous project ran everything as one shared role and I could not demonstrate least privilege at all.

Then the probe failed me in a way I did not see coming. I tested `rds:DescribeDBInstances`, saw it succeed, and concluded RDS was available. The policy actually denies `rds:CreateDBInstance`. Read permission is not write permission, and I had assumed it was.

I found out when the deployment failed part way through. Recovering meant redesigning the data layer while the rest of the environment was already built.

The lesson is specific and I will carry it: probe with the action you intend to use. Where the API supports it, `--dry-run` answers the question exactly. Where it does not, create something small and delete it. I did apply this afterwards, verifying Transit Gateway, VPC and Elastic IP creation with dry runs before relying on any of them, which is why nothing else surprised me.

## 3.2 The constraint made the design better

Losing RDS felt like a setback for about twenty minutes.

I then had to decide where monitoring data and SOAR state should actually live, rather than defaulting to a database because that is what I had planned. Monitoring history went to S3, which is what production observability deployments do anyway, because Loki and Thanos are both built for object storage. SOAR state went to DynamoDB, which suits it better than a relational store, because events are written once and read by key and never joined.

The result is a stronger architecture than the one I designed freely. A small Postgres instance was always the weaker choice and I had chosen it out of habit.

What I take from this is that a constraint is worth interrogating before working around it. I nearly spent an hour looking for a way to get RDS working, which would have produced a worse system than the twenty minutes I spent on the alternative.

## 3.3 The failure that taught me most

The most useful thing that happened was a permissions error on the quarantine action.

The rule engine matched the playbook correctly and dispatched both actions in 152 milliseconds. The notification arrived. The quarantine failed with `UnauthorizedOperation`, saying the role was not authorised on a security group ARN.

I had scoped the policy to the instance, because the API is called `ModifyInstanceAttribute` and it takes an instance ID. What I had not understood is that changing an instance's security groups authorises against the groups as well, since they are also resources being acted on.

Two things came out of it.

The first is a fact about IAM I will not forget, and I only learned it because I wrote a narrow policy in the first place. Had I granted `ec2:*` on `*` it would have worked immediately and I would have learned nothing.

The second is that the fix improved the design. Instead of granting the action all security groups, I granted it exactly one, the quarantine group. The consequence is that the role can move a host into isolation and has no way to move it out. Releasing a host is now necessarily a human action, which is correct, because deciding a compromised machine is safe depends on an investigation rather than a timer. I did not design that property deliberately. It fell out of fixing the error narrowly instead of broadly.

I also watched the architecture behave well under the failure, which was reassuring in a way I did not anticipate. The notification for the same playbook completed normally while the quarantine failed. EventBridge retried three times. The `ActionsFailed` metric fired each time. The failure stayed inside one action instead of taking the response down with it. That is the decoupling working, and I would not have seen it if everything had passed first time.

## 3.4 Things I got wrong along the way

**I worked without version control for too long.** I had a full infrastructure layer and the entire SOAR codebase on disk before I ran `git init`. During that window I overwrote my own fixes more than once by unpacking a newer copy of a file over an edited one, and had to rediscover what had been lost. Once the repository existed, `git diff` after every change made the same problem trivial. I should have started with the repository, not added it when it became painful.

**I let a session expire in the middle of an apply.** Around ninety resources had been created in AWS but Terraform could not write state. It recovered cleanly because I had put state in S3 with versioning and locking before building anything, so `terraform state push` restored the record in one command. That was the right decision made early paying off, and it is the only reason a fifteen-minute problem was not a rebuild. I now re-authenticate immediately before every apply rather than at the start of a session.

**I wrote a bootstrap that races its own network.** The k3s user data does a single `curl` to fetch the installer, and the routes it needs are created in the same Terraform apply. When Transit Gateway attachments were slow, the node came up with no internet, the install failed silently under `set -e`, and I did not notice until I tried to use the cluster. The repair was `terraform taint` and `terraform apply`, which rebuilt the node from code in four minutes and incidentally proved the infrastructure genuinely reproduces rather than just being described. But the weakness is real. A retry loop or a pre-baked image is the correct answer, and I documented it rather than quietly patching it, because it is the kind of fragility that only appears when a system is actually run.

## 3.5 A gap I only saw because a pipeline stopped me

Near the end I pushed an infrastructure change and the pipeline paused, waiting for approval, because the plan would replace both EC2 instances. My own risk-grading rule had caught it.

Looking at what would break, I realised the observability stack would not come back. Prometheus, Grafana, Loki and Alertmanager were installed by a script I had run on the node by hand. Everything else in the project was defined in code and deployed by pipeline; that one part was not, and I had not noticed because it had been working since I set it up.

That is a hole in REQ-NCA-P2-10, which asks for the cloud components and the SOAR system to be defined and configured declaratively. A bash script calling `helm install` is imperative, and it was not in version control in any meaningful sense because the configuration lived inside the script rather than as files of its own.

So I moved the Helm values into the repository as versioned files and wrote a fourth pipeline to apply them. It resolves the environment-specific values from Terraform state at deploy time, so nothing needs editing after a node is replaced, and it verifies afterwards that every pod is running and that Alertmanager can still reach the SOAR ingest endpoint.

Two things I take from this. The gap existed for two days and I could not see it, because working software looks the same whether or not it can be rebuilt. And the thing that exposed it was a safety control I had built for a different reason: I added the approval gate to stop a pipeline deleting infrastructure unattended, and what it actually did first was make me look properly at what a rebuild would cost.

# 4. What I would do differently

**Probe with write actions, not read actions.** The single most expensive mistake of the period, and entirely avoidable.

**Start the repository before the first file.** Every hour without it was an hour where mistakes were invisible.

**Write tests for the component nobody watches.** The forwarder agent was the only part of the system with no unit tests, and it was also the only part that runs unattended on a host nobody logs into. It shipped with a defect that killed it on the first line it processed, and it restarted 371 times before I looked, because every log line it emitted said it was working. The parts most in need of tests are the ones whose failure is quietest, and I tested the parts that were easiest to test instead.

**Design the refusal conditions before the action.** Both destructive actions ended up with explicit guards, but I added them while writing the handlers rather than deciding them first. For a system permitted to change production on its own, what it must never do is the more important half of the specification, and it deserves to be written down before the code.

**Ask what happens if each component is destroyed, before finishing.** The observability gap would have been obvious the moment I asked it, and I only got there because a pipeline forced the question. "Can this be rebuilt without me" is a better test of infrastructure as code than "is it working".

**Budget documentation as work, not as write-up.** I treated it as something that happens after building. It took most of a day, and doing it earlier would have improved the build, because writing down why a choice was made is a good way to notice that it was the wrong choice.

# 5. What I learned about the subject

Beyond the process, three technical ideas landed properly this time rather than remaining things I could define.

**Least privilege is a design tool, not a compliance box.** The rule engine holds no permission to modify anything. It decides and publishes; the actions act. That separation means a bug in rule evaluation cannot damage the environment, which is a stronger guarantee than any amount of careful coding in the engine. I understood the phrase before. I had not used it to make an architectural decision.

**Structure beats configuration.** The data spoke has no default route at all. Not a filtered route, not a deny rule, no route. A service placed there cannot reach the internet regardless of how its security groups are later configured, including by someone who does not know the design. Wherever a property can be guaranteed by the shape of the system, it should be, because configuration drifts and shapes do not.

**Knowing when not to act is part of automation.** PB-004 handles availability alerts and is deliberately notify-only. Automatically isolating a host that is merely unhealthy would turn a partial outage into a total one. Deciding that in advance, and writing down why, felt more like real engineering than any of the actions I did implement.

# 6. Where the project stands

The response capability works and is demonstrable. A correlated brute-force pattern produces a network ACL deny entry in under twenty-five seconds with nobody involved. A compromise indicator isolates a host while leaving it running for forensics. Both are verifiable in the AWS console within seconds of firing, and both are covered by scripted tests that print a pass or fail verdict.

What is not finished, stated honestly: the on-premises virtual machines were never joined to the tailnet, so the hybrid path is implemented and deployed but not exercised end to end from a physical on-premises host. The cloud side of that path is proven and the syslog parser is verified, but the physical link is untested and I have recorded it as such rather than implying otherwise.

The observability node is still a single point of failure, the NAT gateway is still single, and the bootstrap race is still there. All three are documented with named fixes I did not have time to apply, though the stack on that node can now be restored by running one pipeline rather than by hand. The corporate server is simulated on EC2 rather than being physical hardware, which the assignment permits and which I have said plainly wherever it matters. I would rather hand over a system whose limitations are written down than one where they are undiscovered.

# 7. Closing

The thing I most wanted from this period was to be able to point at a screen and say that the system did that by itself. I can do that now, twice, with two structurally different actions.

The part I did not expect is that the most instructive moment was a failure. The quarantine action being denied taught me more about IAM than any amount of it working would have, and the fix produced a security property better than the one I had designed. That has changed how I read errors. I used to want them gone. I am now more inclined to ask what the error is telling me about the boundary I have just found.
