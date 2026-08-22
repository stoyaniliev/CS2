# Self-hosted runner setup

REQ-NCA-P2-11 requires the pipelines to be executable from a local runner. This is how to register one and what it needs installed.

A GitHub-hosted runner cannot do this work. The Terraform state is in a private S3 bucket, the k3s API has no public address, and the SOAR ingest endpoint is reachable only from inside the VPC or over the tailnet. The runner has to sit somewhere with a path to those things, which in this project is the same workstation used for development.

## What the machine needs

| Tool | Why | Check |
|---|---|---|
| Terraform >= 1.6 | infrastructure jobs | `terraform version` |
| AWS CLI v2 | credentials and verification steps | `aws --version` |
| Python 3.10+ | tests and playbook validation | `python3 --version` |
| Docker | console image build | `docker version` |
| Git | checkout | `git --version` |
| OpenSSH client | deploying to k3s through the bastion | `ssh -V` |

On Windows, Git Bash provides `bash`, `ssh`, `scp` and `curl`, which the workflows rely on. The workflows set `shell: bash` explicitly for that reason.

## Registering the runner

In the repository: **Settings**, **Actions**, **Runners**, **New self-hosted runner**. Pick the platform and follow the commands shown, which are specific to your repository and carry a one-time token.

On Windows the sequence is roughly:

```powershell
mkdir C:\actions-runner ; cd C:\actions-runner
# download and extract using the URL GitHub shows
./config.cmd --url https://github.com/stoyaniliev/CS2 --token <TOKEN>
```

Accept the defaults for the runner group. Give it a name you will recognise and add the label `self-hosted`, which the workflows target.

Run it in the foreground while testing so you can see what happens:

```powershell
./run.cmd
```

Install it as a service once it works:

```powershell
./svc.sh install
./svc.sh start
```

## Credentials

The runner inherits the environment of the account it runs as, so the AWS session belongs to that account rather than to the workflow.

Before triggering an infrastructure job:

```powershell
aws sso login
```

The plan job checks for a valid session first and fails with a clear message rather than a confusing Terraform error if there is none. That check exists because an expired session partway through an apply is the most disruptive failure mode in this project.

Running the runner as a service complicates this, because the service account has its own profile. For a project of this size, running it interactively in a terminal you have already authenticated is simpler and more predictable.

## Repository secrets

One secret is needed, for the console deployment:

**Settings**, **Secrets and variables**, **Actions**, **New repository secret**

| Name | Value |
|---|---|
| `BASTION_SSH_KEY` | the full contents of `innovatech-key.pem`, including the BEGIN and END lines |

The deploy job writes it to disk, uses it, and removes it in an `always()` step so it does not persist on the runner between jobs.

This is a compromise worth naming. Putting a private key into repository secrets means anyone with write access to the repository can reach the bastion. The better arrangement is an OIDC trust between GitHub and AWS so the runner assumes a role with no long-lived credential at all, combined with Session Manager instead of SSH. That is recorded as a recommendation in the design document rather than implemented, because it needs an identity provider configuration this account does not have.

## Environment protection

The apply job and the console deploy job both target an environment called `production`.

**Settings**, **Environments**, **New environment**, name it `production`, and add yourself as a required reviewer.

With that in place, a deployment pauses and waits for approval instead of proceeding automatically. This is the mechanism behind the decision not to auto-apply: the pipeline proves a change is valid, and a person decides when it lands.

## The three pipelines

| Workflow | Trigger | Does |
|---|---|---|
| `01-soar-ci.yml` | any change under `soar/` | Compiles the handlers, runs 50 unit tests, validates playbook integrity, packages the function archives |
| `02-infrastructure.yml` | changes under `terraform/` or `soar/`, or manual | Formats, validates, plans, and on manual dispatch applies, then verifies every function is active and both dead-letter queues are empty |
| `03-soar-console.yml` | changes under `soar/console/` | Builds the container, smoke tests it on the runner, pushes to ECR, deploys to k3s, and confirms the running image is the one just built |

## Running them

**Automatically.** Push to `main`. CI and the plan run on their own.

**Applying infrastructure.** Actions tab, Infrastructure, Run workflow, choose `apply`. It plans first, then waits for the environment approval.

**Deploying the console.** Runs on any change under `soar/console/`, or manually from the Actions tab.

## When things fail

**Jobs queue and never start.** The runner is offline. Check Settings, Actions, Runners for a green dot, and that `run.cmd` is still going.

**`terraform: command not found`.** The runner service started before the PATH included Terraform. Restart the runner.

**The plan job reports no AWS session.** Run `aws sso login` in the terminal the runner is running in, then re-trigger.

**Docker build fails on Windows.** Docker Desktop needs to be running and set to Linux containers.

**The deploy job cannot reach the k3s node.** The bastion address changes if that instance is replaced. Read the current value from `terraform output bastion_public_ip` and update the `BASTION` variable at the top of the workflow.

## Verifying the console after deployment

```
ssh -i innovatech-key.pem -L 8080:10.1.10.149:30080 ubuntu@63.183.208.221 -N
```

Then open `http://localhost:8080`. The page lists active blocks, quarantined hosts and recent events, and refreshes every thirty seconds. Running a SOAR test in another terminal and watching the numbers change is a good demonstration in its own right.
