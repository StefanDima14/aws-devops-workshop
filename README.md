# AWS DevOps Workshop — from `git push` to a live app

Welcome! This repository is a **complete, working DevOps project**, small enough to
read in one sitting but real enough to teach you how software actually gets shipped
in a company.

The app itself is deliberately boring: a small Python web page that plays a video.
The *interesting* part is everything around it — how the code is tested, packaged,
scanned for security holes, and deployed to the cloud **by a pipeline you start with
one click**, with zero manual clicking in AWS and zero passwords lying around.

> **A note on triggers.** Both pipelines here are **manual** (`workflow_dispatch`): you
> start them from the GitHub **Actions** tab. That's a teaching choice — it lets an
> instructor create and destroy the whole environment live, on demand. In a real
> project you would wire the app pipeline to run on every push to `main`; [section
> 9](#9-the-pipelines-githubworkflows--the-heart-of-cicd) shows you exactly how.

By the end you will have:

- a real AWS environment you created with **code** (not by clicking in the console),
- a **Docker image** of your app stored in a private registry,
- two **CI/CD pipelines** that do all the work for you,
- a public URL where your app is running. 🎬

> **Who is this for?** Someone who has never done DevOps before, or is in their first
> weeks. You should be comfortable in a terminal and know what `git push` does.
> Everything else is explained.

---

## Table of contents

1. [What is DevOps, in one minute](#1-what-is-devops-in-one-minute)
2. [The architecture](#2-the-architecture)
3. [The tools you'll meet](#3-the-tools-youll-meet)
4. [Prerequisites — what to install before you start](#4-prerequisites--what-to-install-before-you-start)
5. [Step-by-step: make it run](#5-step-by-step-make-it-run)
6. [The application (`app/`)](#6-the-application-app)
7. [The Dockerfile — turning the app into a container](#7-the-dockerfile--turning-the-app-into-a-container)
8. [The infrastructure (`terraform/`) — what actually gets created in AWS](#8-the-infrastructure-terraform--what-actually-gets-created-in-aws)
9. [The pipelines (`.github/workflows/`) — the heart of CI/CD](#9-the-pipelines-githubworkflows--the-heart-of-cicd)
10. [The DevOps principles hiding in this repo](#10-the-devops-principles-hiding-in-this-repo)
11. [Running it locally (no AWS needed)](#11-running-it-locally-no-aws-needed)
12. [Clean up — do not skip this](#12-clean-up--do-not-skip-this)
13. [Troubleshooting](#13-troubleshooting)
14. [Exercises — make it your own](#14-exercises--make-it-your-own)
15. [Monitoring & observability — see what your app is doing](#15-monitoring--observability--see-what-your-app-is-doing)
    - [15.1 The same app on Kubernetes — Docker vs a real orchestrator](#151-the-same-app-on-kubernetes--docker-vs-a-real-orchestrator)

---

## 1. What is DevOps, in one minute

Before DevOps, a developer wrote code and "threw it over the wall" to an operations
team, who manually copied it onto a server. It was slow, it was inconsistent, and
when it broke nobody knew whose fault it was.

DevOps says: **the path from a developer's laptop to production should be automated,
repeatable, and owned by the whole team.** Three ideas do most of the work:

| Idea | What it means | Where you'll see it here |
|---|---|---|
| **CI** — Continuous Integration | Every change is automatically built and tested the moment it's pushed. Bugs are caught in minutes, not weeks. | `test` and `build-and-scan` jobs in [cicd.yml](.github/workflows/cicd.yml) |
| **CD** — Continuous Deployment | If the tests pass, the change is automatically released. No human copies files to a server. | `deploy` job in [cicd.yml](.github/workflows/cicd.yml) |
| **IaC** — Infrastructure as Code | Servers, networks and permissions are described in files, kept in git, and created by a tool. You can destroy and recreate the whole environment with one command. | everything in [terraform/](terraform/) |

A CI/CD **pipeline** is just a list of steps that run automatically. If any step
fails, the pipeline stops and nothing is deployed. That's the safety net.

---

## 2. The architecture

![Architecture](assets/image.png)

Read the picture as two flows:

- **Blue arrows (top)** — the *delivery* flow: your code travels from your laptop
  → GitHub → tests → Docker image → security scan → registry → the server → the user.
- **Orange arrows (bottom)** — the *infrastructure*: Terraform creates the AWS
  environment (network, firewall, permissions, server, registry) that the delivery
  flow lands in.

Here's the same thing as a simplified diagram of what runs where:

```mermaid
flowchart TB
    dev["👩‍💻 You<br/>git push"] --> gh["GitHub Actions<br/>(the pipeline)"]

    subgraph AWS["☁️ AWS Cloud — region eu-west-1"]
        subgraph VPC["VPC 10.0.0.0/16 · public subnet"]
            ec2["🖥️ EC2 t3.micro<br/>Docker container<br/>gunicorn :8080 → port 80"]
        end
        ecr["📦 ECR<br/>private Docker registry"]
        s3["🔒 S3 bucket<br/>video.mp4 (private)"]
    end

    gh -- "1. push image" --> ecr
    gh -- "2. 'go deploy' via SSM" --> ec2
    ec2 -- "3. pull image" --> ecr
    ec2 -- "4. presigned URL for the video" --> s3
    user["🌐 Browser"] -- "http://<public-ip>" --> ec2
```

**What each box is:**

- **EC2** is a virtual machine — a rented computer in Amazon's data centre. Ours is a
  `t3.micro` (free tier). It runs Docker, and Docker runs our app.
- **ECR** (Elastic Container Registry) is a private warehouse for Docker images.
  The pipeline puts images in; the server takes them out.
- **S3** is Amazon's file storage. Our video lives there in a bucket that is
  **completely private** — no one on the internet can read it directly.
- **VPC** is our own private network inside AWS, with a firewall (security group)
  that only opens port 80 (web traffic) to the world.

**How the video gets to the viewer without making the bucket public:** the EC2 server
has an AWS *identity* (an IAM role) that is allowed to read that one bucket. When you
open the page, the app asks S3 for a **presigned URL** — a temporary link that works
for one hour and then expires. The browser plays the video from that link. No
passwords are stored in the app, and the bucket is never opened to the public.

---

## 3. The tools you'll meet

| Tool | What it does | Why we use it |
|---|---|---|
| **Python + Flask** | The web app itself | Something to deploy |
| **pytest** | Runs unit tests | Proves the code works before we ship it |
| **Docker** | Packages the app + its dependencies into one portable image | "Works on my machine" → works everywhere |
| **Trivy** | Scans the Docker image for known security vulnerabilities | Catches security problems *before* production |
| **Terraform** | Creates AWS resources from code | Reproducible, reviewable, destroyable infrastructure |
| **GitHub Actions** | Runs the pipelines | The automation engine |
| **AWS** (EC2, ECR, S3, IAM, SSM) | Where everything runs | The cloud |

---

## 4. Prerequisites — what to install before you start

### Accounts you need

1. **A GitHub account** and a repository to push this code to.
2. **An AWS account.** Everything here fits in the **Free Tier**, but a card is
   required at sign-up. (You will destroy everything at the end — see [step 12](#12-clean-up--do-not-skip-this).)

### Software to install on your machine

| Tool | Check it works | Install |
|---|---|---|
| **git** | `git --version` | usually pre-installed |
| **AWS CLI v2** | `aws --version` | [docs](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) · macOS: `brew install awscli` |
| **Terraform ≥ 1.5** | `terraform -version` | [docs](https://developer.hashicorp.com/terraform/install) · macOS: `brew install terraform` |
| **Python 3.12** | `python3 --version` | only needed to run the app/tests locally |
| **Docker** | `docker --version` | *optional* — the pipeline builds images for you |

### Connect the AWS CLI to your account

Your laptop needs AWS credentials **for two one-time setup steps only** (after that,
the pipelines authenticate themselves — see below). Pick one:

**Option A — IAM Identity Center / SSO (recommended, no permanent keys on disk):**
```bash
aws configure sso     # one-time setup
aws sso login         # temporary credentials that expire on their own
```

**Option B — an IAM user with AdministratorAccess (fine for a workshop):**
```bash
aws configure         # paste your Access Key ID + Secret Access Key
```

Verify it worked:
```bash
aws sts get-caller-identity     # should print your account ID
```

> ⚠️ **The golden rule of this workshop:** an AWS *access key* is a password. It never
> goes into git, never into GitHub, never into `terraform.tfvars`. If you used Option B,
> **delete that access key** once the pipelines are running.

### 🔑 How the pipelines log into AWS without any password

This confuses everybody at first, so let's do it now.

The pipeline needs to talk to AWS. The old way was to paste an access key into GitHub
— which means a permanent password sitting in a website, waiting to leak. Instead we
use **OIDC**:

1. GitHub Actions generates a short-lived, cryptographically signed token that says
   *"I am a workflow running in the repo `you/your-repo`."*
2. AWS has been told (by Terraform, in [bootstrap/iam.tf](terraform/bootstrap/iam.tf))
   to **trust tokens from that specific repository**.
3. AWS swaps the token for temporary credentials that expire in about an hour.

So the only things you store in GitHub are **role ARNs** — public identifiers, like a
username with no password. Nothing secret ever leaves AWS. This is exactly how real
companies do it.

---

## 5. Step-by-step: make it run

### Step 1 — Get the code into your own GitHub repo

```bash
git clone <this-repo> aws-devops-workshop
cd aws-devops-workshop
git remote set-url origin git@github.com:<your-user>/<your-repo>.git
git push -u origin main
```

### Step 2 — Create the Terraform "state backend" (once per AWS account)

Terraform remembers what it created in a file called **state**. If that file lives on
your laptop, the pipeline can't see it — and two people applying at once would corrupt
it. So we store the state in **S3**, with a **DynamoDB** table acting as a lock (only
one `apply` at a time). [scripts/bootstrap-backend.sh](scripts/bootstrap-backend.sh)
creates both:

```bash
export AWS_REGION=eu-west-1
export TF_STATE_BUCKET=<your-initials>-devops-workshop-tfstate   # must be globally unique
./scripts/bootstrap-backend.sh
```

### Step 3 — Create the pipeline's AWS identity (the `bootstrap` stack, once)

There are **two** Terraform stacks in this repo, and the difference matters:

| Stack | What's in it | Who runs it | How often |
|---|---|---|---|
| [terraform/bootstrap/](terraform/bootstrap/) | the OIDC provider + the two IAM roles the pipelines log in with | **you, from your laptop** | once |
| [terraform/](terraform/) | VPC, EC2, ECR, S3 — the actual environment | the infra pipeline (or you) | created & destroyed freely |

**Why separate?** The infra pipeline *assumes* the role in the bootstrap stack. If that
role lived in the same state as everything else, `terraform destroy` would delete the
credentials it is using **halfway through its own run** — and no later `apply` could
authenticate to rebuild. Separating them means you can destroy and recreate the
environment as many times as you like. (Chicken and egg: a role cannot create itself,
so you are the chicken, exactly once.)

```bash
cd terraform/bootstrap
cp backend.hcl.example backend.hcl              # ← set your state bucket name
cp terraform.tfvars.example terraform.tfvars    # ← set github_repo = "your-user/your-repo"

terraform init -backend-config=backend.hcl
terraform apply     # read the plan, then type: yes
terraform output    # ← two role ARNs; you need them in step 6
```

| Output | What you do with it |
|---|---|
| `github_actions_role_arn` | → GitHub **secret** `AWS_ROLE_ARN` (app pipeline) |
| `github_terraform_role_arn` | → GitHub **secret** `AWS_TF_ROLE_ARN` (infra pipeline) |

### Step 4 — Configure and create the environment (the `terraform/` stack)

```bash
cd ..                                           # back to terraform/
cp backend.hcl.example backend.hcl              # ← same bucket, different state key
cp terraform.tfvars.example terraform.tfvars
```

In `terraform.tfvars` you **must** set your IP:

```hcl
my_ip_cidr = "203.0.113.5/32"     # your public IP: curl -s https://checkip.amazonaws.com
```

> `github_repo` is **not** here — it belongs to the bootstrap stack, which owns the OIDC
> trust. Both `terraform.tfvars` and `backend.hcl` are **git-ignored** on purpose: your
> real values stay on your machine.

```bash
terraform init -backend-config=backend.hcl
terraform apply     # read the plan, then type: yes
```

You can run this first `apply` from your laptop, or — once the secrets from step 6 are
in place — from the **Actions** tab, which is the more impressive demo. Terraform prints
the outputs you'll need:

| Output | What you do with it |
|---|---|
| `video_bucket_name` | where you upload the video |
| `app_url` | your app's URL (works after the first deploy) |

### Step 5 — The video (nothing to do)

The app streams the video from the private bucket, and **Terraform put it there during
step 4**: [assets/video.mp4](assets/) is committed to the repo, and `aws_s3_object.video`
uploads it on every `apply` — including when the *pipeline* applies, which has no access
to your laptop's files. Swap in your own clip by replacing that file and re-applying.

This is why the bucket is never empty on a fresh environment: destroy it, recreate it,
and the video is uploaded again automatically. **Anything the pipeline needs must exist
in the repo** — a runner is a blank machine.

> Committing a binary is a judgement call. A few MB of demo video: fine, and it makes
> the environment reproducible. A multi-GB asset: no — you'd upload it to S3 out of band
> and leave `video_source_path = ""`, which skips the upload entirely.

To upload by hand instead (or to replace the object without an apply):

```bash
BUCKET=$(terraform output -raw video_bucket_name)
aws s3 cp ../assets/video.mp4 "s3://$BUCKET/video.mp4"
```

### Step 6 — Give the pipelines their AWS access

In GitHub: **Settings → Secrets and variables → Actions**

**Secrets** (paste the two ARNs the *bootstrap* stack printed in step 3):
- `AWS_ROLE_ARN` = `github_actions_role_arn`
- `AWS_TF_ROLE_ARN` = `github_terraform_role_arn`

**Variables** (not secret — these are just names):
- `TF_STATE_BUCKET` = your state bucket
- `TF_LOCK_TABLE` = `devops-workshop-tf-locks`
- `MY_IP_CIDR` = your IP CIDR *(only used if you enable SSH)*

### Step 7 — Run the pipeline, and watch the robot work

Both pipelines are **manual**, so you start this one yourself. In GitHub:

**Actions** → **CI/CD Pipeline** → **Run workflow** → *Run workflow*

You'll see three jobs run in order: `Lint & Test` → `Build, Scan & Push Image` →
`Deploy to EC2`. A failure in any one of them stops the deploy.

> The **Run workflow** button only appears once the workflow file exists on your
> default branch (`main`). If you don't see it, you haven't pushed yet — do step 1.

### Step 8 — Open your app 🎬

```bash
terraform output app_url
```

Open that URL. The page plays the video from your private S3 bucket, and the footer
shows the **git commit SHA** that produced the running container and the container's
hostname. That footer is your proof: *this exact commit is what's live.*

---

## 6. The application (`app/`)

```
app/
├── app.py            # the whole application — ~90 lines
├── requirements.txt  # Flask, gunicorn, boto3
├── templates/
│   └── index.html    # the page
├── static/
│   ├── style.css
│   └── image.png     # video poster
├── Dockerfile        # how to package it
└── .dockerignore     # what to keep OUT of the image
```

[app.py](app/app.py) has exactly two routes:

- **`/`** — renders the page and asks S3 for a fresh presigned video URL.
- **`/health`** — returns `{"status": "healthy"}`. This exists purely for the
  machines: Docker calls it to check the container is alive, and a load balancer
  would too. **Every production service should have a health endpoint.**

Two beginner-relevant details in that file:

**Configuration comes from environment variables**, never hardcoded:

```python
VIDEO_BUCKET = os.environ.get("VIDEO_BUCKET", "")
APP_VERSION  = os.environ.get("APP_VERSION", "dev")
```

This is the *12-factor* principle: **build the image once, configure it per
environment.** The same image can run in dev, staging and prod — only the env vars
change. You never rebuild just to change a setting.

**It degrades gracefully.** If no bucket is configured (local dev, or the tests),
it falls back to a public video URL. If presigning fails, it logs the error and uses
the fallback rather than showing users a 500 error page.

[tests/test_app.py](tests/test_app.py) covers both routes and all three video-URL
paths (no bucket → fallback, bucket → presigned, presign fails → fallback). Notice the
tests use a **fake** S3 client — a unit test must never need real AWS credentials or a
network connection. That's what makes it fast enough to run on every single push.

---

## 7. The Dockerfile — turning the app into a container

A **container** is your app plus everything it needs to run (Python, libraries, files)
sealed into one package called an **image**. Ship the image, and it behaves identically
on your laptop, in CI, and on the server.

[app/Dockerfile](app/Dockerfile) is a recipe read top to bottom. Here's what each part
is doing and *why*:

```dockerfile
FROM python:3.12-slim
```
**Start from a base image.** `slim` is a stripped-down Linux with Python. Smaller image
= faster to pull = fewer installed packages = **fewer security vulnerabilities** for
Trivy to find. Choosing a small base is a security decision, not just a size one.

```dockerfile
ENV PYTHONUNBUFFERED=1 ...
```
Makes Python print logs immediately instead of buffering them, so `docker logs` shows
you what's happening in real time.

```dockerfile
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
```
**Why copy `requirements.txt` before the code?** Docker caches each step as a *layer*
and reuses it if nothing changed. Dependencies change rarely; your code changes
constantly. By installing dependencies first, a code-only change reuses the cached
`pip install` layer and the build takes seconds instead of minutes. **Order your
Dockerfile from least-changing to most-changing.**

```dockerfile
RUN useradd ... appuser
USER appuser
```
**Run as a non-root user.** By default a container runs as root; if someone breaks into
your app they'd have root inside the container. This is a one-line hardening step and
you should do it in every image you ever build.

```dockerfile
HEALTHCHECK ... CMD python -c "...urlopen('http://localhost:8080/health')"
```
Docker calls `/health` every 30 seconds. If it stops answering, Docker marks the
container unhealthy — the machine notices your app is broken before your users do.

```dockerfile
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
```
**The command that starts the app.** Note it's **gunicorn**, not `flask run`. Flask's
built-in server is a development toy — single-threaded and explicitly not for
production. Gunicorn is a real WSGI server that handles multiple requests in parallel
(2 worker processes here — plenty for a t3.micro).

`0.0.0.0` (not `localhost`) means "listen on all network interfaces" — otherwise the
app would only be reachable from *inside* the container and no one could connect.

Finally, [.dockerignore](app/.dockerignore) keeps `tests/`, `.git/`, caches, etc. **out**
of the image: smaller, faster, and no accidental leaking of files into production.

---

## 8. The infrastructure (`terraform/`) — what actually gets created in AWS

### How Terraform works, in three sentences

You *declare* what you want ("I want one server, one bucket") in `.tf` files.
Terraform compares your files to a **state** file (what exists now) and works out the
difference. `terraform plan` shows you that difference; `terraform apply` makes it real.

You never click around in the AWS console. Your infrastructure is code, so it can be
reviewed in a pull request, rolled back with git, and rebuilt from scratch in minutes.

### File by file — what each one creates

| File | Resources it creates | In plain English |
|---|---|---|
| [versions.tf](terraform/versions.tf) | provider config + S3 **remote state backend** | Which AWS region, which provider version, and where the state file lives. Also applies default tags (`Project`, `Environment`, `Owner`) to **every** resource so you can find and bill them later. |
| [variables.tf](terraform/variables.tf) | *(no resources)* | The knobs: region, project name, instance type, your IP, etc. Change a value here instead of editing code in ten places. |
| [network.tf](terraform/network.tf) | **VPC**, **public subnet**, **internet gateway**, **route table** | Your own private network in AWS, plus the door to the internet. The route table says "anything going to the internet, leave through that door." |
| [security.tf](terraform/security.tf) | **security group** | The firewall around the server. Port **80** (web) open to everyone; port **22** (SSH) open **only to your IP**, and only if you asked for an SSH key. Everything else: blocked. |
| [ec2.tf](terraform/ec2.tf) | **EC2 instance**, **Elastic IP** | The virtual machine. On first boot it installs Docker (that's the `user_data` script). The Elastic IP is a **fixed** public address, so your app's URL doesn't change if the machine restarts. The disk is encrypted and IMDSv2 is enforced (a security hardening that blocks a common credential-theft attack). |
| [s3.tf](terraform/s3.tf) | **S3 bucket** (private, versioned, encrypted), optional **video object**, **IAM policy**, 2 **SSM parameters** | Where the video lives. Public access is fully blocked; versioning means an accidental overwrite is recoverable; the IAM policy lets the EC2 server read **only** this bucket's objects. The bucket name gets a random suffix (S3 names are globally unique), so Terraform publishes the name to **SSM Parameter Store** for the pipeline to look up — nothing is hardcoded. |
| [ecr_iam.tf](terraform/ecr_iam.tf) | **ECR repository** + lifecycle policy, **IAM role & instance profile** for EC2 | The private Docker registry (keeping only the last 10 images, to control cost), and the identity the server runs as. That role can: pull from ECR, be managed by SSM, and read the video object. Nothing more — **least privilege**. |
| [outputs.tf](terraform/outputs.tf) | *(no resources)* | The values Terraform prints at the end: your `app_url`, the bucket name. |

The **bootstrap** stack is a separate state with a single file:

| File | Resources it creates | In plain English |
|---|---|---|
| [bootstrap/iam.tf](terraform/bootstrap/iam.tf) | **OIDC provider**, **IAM role** for the app pipeline, **IAM role** for the infra pipeline | The trust relationship that lets GitHub Actions log into AWS with no password, plus the two roles it can assume. Applied once from your laptop; never touched by a pipeline. |

### Two roles, two pipelines — why?

Notice there are **two** OIDC roles. The app pipeline's role can push a Docker image
and restart a container; it *cannot* delete your database or create IAM users. The infra
pipeline's role is the powerful one (`AdministratorAccess`, because it manages
everything) — in a real company you'd narrow it and require human approval before
`apply`. If the app pipeline were ever compromised, the blast radius is tiny.
**Separating permissions by job is what "least privilege" means in practice.**

### Why the bootstrap stack is separate — the lesson worth remembering

**A stack must never own the credentials used to manage it.** Put the CI role in the
same state as the servers, and `terraform destroy` will delete that role part-way
through its own run: the remaining API calls fail, you're left with a half-destroyed
environment, and the pipeline can no longer authenticate to clean up or rebuild. Real
teams hit this and it is genuinely painful. The fix is the one used here — a tiny,
long-lived *bootstrap* state for identity, and a disposable state for everything else.

---

## 9. The pipelines (`.github/workflows/`) — the heart of CI/CD

A GitHub Actions workflow is a YAML file describing **jobs**, each made of **steps**.
Jobs run on a fresh, throwaway Linux machine that GitHub gives you for free.
`needs:` chains them so a job only runs if the previous one **succeeded** — that's the
whole safety mechanism: *a failure anywhere stops the deploy.*

### Pipeline A — the app: [cicd.yml](.github/workflows/cicd.yml)

**Trigger:** manual — **Actions → CI/CD Pipeline → Run workflow**.

```mermaid
flowchart LR
    A["1 · TEST<br/>pytest"] --> B["2 · BUILD<br/>docker build"]
    B --> C["3 · SCAN<br/>Trivy"]
    C --> D["4 · PUSH<br/>image → ECR"]
    D --> E["5 · DEPLOY<br/>SSM → EC2"]
    style A fill:#2b6cb0,color:#fff
    style C fill:#c05621,color:#fff
    style E fill:#276749,color:#fff
```

#### Stage 1 — `test` (Lint & Test)
Checks out the code, installs Python 3.12 and the dependencies, and runs `pytest`.

It's the cheapest, fastest gate: it takes ~20 seconds and it runs *before anything is
built*. **Fail fast** — never spend three minutes building an image for code that
doesn't pass its tests.

#### Stage 2 — `build-and-scan` (Build, Scan & Push Image)
`needs: test`, so it runs only if the tests passed.

1. **Authenticate to AWS via OIDC** — no keys, remember.
2. **Compute the image tag:** `${GITHUB_SHA::7}` — the first 7 characters of the git
   commit hash. So an image is tagged e.g. `a1b2c3d`. This is a big deal:
   **every image traces back to exactly one commit.** Never deploy `latest` and hope.
3. **`docker build`** the image.
4. **Trivy scan** — scans the image for known vulnerabilities (CVEs) in the OS packages
   and Python libraries. Configured with `exit-code: 1` and `severity: HIGH,CRITICAL`,
   which means **the pipeline fails and nothing is deployed if a serious vulnerability
   is found.** This is called **shift-left security**: find problems in CI, in minutes,
   not in production, in the news. (`ignore-unfixed: true` means it won't fail you for
   vulnerabilities that have no patch available yet — otherwise you'd be permanently
   blocked on something you can't fix.)
5. **Push to ECR** — only a scanned, tested image ever reaches the registry.

#### Stage 3 — `deploy` (Deploy to EC2)
1. Finds the EC2 instance **by its `Name` tag**, not a hardcoded ID (IDs change when
   you recreate the box; tags don't).
2. Reads the video bucket name and key from **SSM Parameter Store** — the values
   Terraform published. The pipeline and the infrastructure stay in sync without anyone
   copy-pasting.
3. Sends a command to the server using **SSM Run Command**. Read that again: **there is
   no SSH in this deploy.** No SSH key in GitHub, no port 22 open to CI. AWS delivers
   the command to an agent already running on the box. This is how modern deploys work.

The command it sends is just Docker:
```bash
docker pull <image>                      # get the new version
docker rm -f workshop-app || true        # stop the old container
docker run -d --name workshop-app \
  --restart unless-stopped -p 80:8080 \
  -e VIDEO_BUCKET=... -e APP_VERSION=... <image>   # start the new one
```
`-p 80:8080` maps the container's port 8080 to the machine's port 80, so visitors
reach it on a plain `http://` URL. `--restart unless-stopped` means Docker brings the
app back up if the server reboots.

4. **It waits for the result and checks it.** If the command failed, the job fails
   (`[ "$STATUS" = "Success" ] || exit 1`). A deploy step that doesn't verify its own
   outcome is worse than no deploy step — it lies to you.

> `concurrency:` at the top of the file prevents two deploys of the same branch from
> running at the same time and racing each other.

### Pipeline B — the infrastructure: [infra.yml](.github/workflows/infra.yml)

**Trigger:** manual, with a choice of what to do — **Actions → Infrastructure
(Terraform) → Run workflow**, then pick an **action**:

| Action | What happens | When you'd pick it |
|---|---|---|
| **`plan`** *(default)* | fmt → init → validate → `terraform plan`. **Changes nothing.** | Always, first. Read the plan in the run summary. |
| **`apply`** | The same, then applies **the exact plan file** it just showed you | To create or update the environment |
| **`destroy`** | `terraform plan -destroy`, then applies it — **deletes the environment** | When you're done (see [section 12](#12-clean-up--do-not-skip-this)) |

**Destroy asks you to mean it.** Choosing `destroy` isn't enough: you must also type
the word `destroy` into the **confirm_destroy** box, or the run fails immediately. A
dropdown you can hit by accident should never be able to delete your infrastructure.

| Stage | What it does | Why it matters |
|---|---|---|
| `fmt -check` | Fails if the code isn't formatted | Style is never a code-review argument again |
| `init` | Connects to the shared S3 state | Everyone works from the same source of truth |
| `validate` | Checks the syntax is valid | Catch typos before touching AWS |
| `plan` | **Shows exactly what would change** (or be destroyed), printed into the run summary | 👀 A human reads the plan *before* AWS is touched |
| `apply` | Runs **the exact plan file** that was just shown — only for `apply` / `destroy` | You get what you reviewed, nothing else |

Notice that even a destroy is *planned first, then applied* — the saved plan file
already encodes the direction, so what executes is precisely what you read.

> **Why manual, and what a real team does instead.** Running the pipeline by hand is a
> teaching choice: an instructor can create the environment live, deploy to it, and tear
> it down again in one session. In production you would trigger the app pipeline on every
> push to `main`, and for infrastructure use the pattern this repo's git history shows:
> **`plan` automatically on the pull request** (posted as a PR comment for review), and
> **`apply` on merge**. Nobody runs `terraform apply` against production from their laptop
> while guessing what it will do. To restore that, add back the `push` / `pull_request`
> triggers and gate `apply` on `github.ref == 'refs/heads/main'`.

---

## 10. The DevOps principles hiding in this repo

Once you've read the code, go back and spot each of these — this is the actual
curriculum:

- **Everything as code.** App, infrastructure, and pipelines all live in git. If it's
  not in the repo, it doesn't exist.
- **Automate the path to production.** No human copies a file to a server. Ever.
- **Fail fast, fail cheap.** Tests (seconds) run before builds (minutes) run before
  deploys. The pipeline stops at the first failure.
- **Build once, configure per environment.** One image; behaviour changes via env vars.
- **Immutable, traceable deployments.** Image tag = git SHA. Every running container
  points to exactly one commit — and the app footer shows it.
- **Shift-left security.** Trivy in CI + ECR scan-on-push. Non-root container. A
  vulnerable image cannot be deployed.
- **Least privilege everywhere.** Two separate CI roles. The EC2 role can read exactly
  one bucket. SSH is closed to everyone but you (and unused).
- **No long-lived secrets.** OIDC instead of access keys; presigned URLs instead of
  public buckets; IAM roles instead of credentials baked into the image.
- **Discover config, don't hardcode it.** Bucket name → SSM. Instance → found by tag.
- **Review before you change infrastructure.** Always `plan` and read it before `apply`
  — and in a real team, `plan` on the PR, `apply` on merge.
- **Everything is disposable.** `destroy` and `apply` gets it all back, identically.
- **Never let a stack own its own credentials.** Identity lives in a separate, long-lived
  `bootstrap` state, so destroying the environment can't cut off the hand that rebuilds it.

---

## 11. Running it locally (no AWS needed)

You can run the app with zero AWS involvement — with no bucket configured it plays a
public fallback video:

```bash
cd app
pip install -r requirements.txt
gunicorn --bind 0.0.0.0:8080 app:app
# → http://localhost:8080
```

Run the tests exactly like CI does:

```bash
pip install -r app/requirements.txt -r tests/requirements-dev.txt
pytest tests/ -v
```

Build and run the container, exactly like the pipeline does:

```bash
docker build -t workshop ./app
docker run -p 8080:8080 workshop
```

Scan your image the way the pipeline does, before you push:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --severity HIGH,CRITICAL workshop
```

---

## 12. Clean up — do not skip this

AWS charges for resources that exist, whether or not you use them.

**The easy way — from the pipeline.** Actions → **Infrastructure (Terraform)** → *Run
workflow* → action **`destroy`**, and type `destroy` in the **confirm_destroy** box.
This deletes the whole environment (EC2, EIP, VPC, ECR, S3) and leaves the two IAM
roles alone, so you can bring it all back later with a single `apply` run. Repeat as
often as you like — that's the point of the two-stack split.

**Or locally:**

```bash
cd terraform && terraform destroy
```

The sneaky one is the **Elastic IP**: AWS charges for a reserved public IP that isn't
attached to a *running* instance — so simply stopping the instance is not enough.
Destroy it.

**When you are completely finished** and never coming back, remove the leftovers, which
by design are *not* destroyed above (they cost nothing meaningful, but tidy is tidy):

```bash
cd terraform/bootstrap && terraform destroy   # the OIDC provider + the two CI roles
```

> ⚠️ Do this **last**. Destroying the bootstrap stack removes the roles the pipelines
> log in with, so after this the pipelines can no longer authenticate to AWS at all —
> you'd have to re-apply `bootstrap` from your laptop to get them back.

The state bucket and lock table from step 2 are outside Terraform entirely; delete them
by hand if you're done with the account.

---

## 13. Troubleshooting

| Symptom | Cause & fix |
|---|---|
| Infra pipeline fails at `init` | You skipped the bootstrap script, or the repo variables `TF_STATE_BUCKET` / `TF_LOCK_TABLE` aren't set. |
| Infra pipeline fails at `fmt -check` | Run `terraform fmt -recursive` and commit. |
| No **Run workflow** button in the Actions tab | The workflow file isn't on your default branch yet. GitHub only offers manual runs for workflows present on `main`. Push, then look again. |
| `Error: could not assume role` in Actions | The `AWS_ROLE_ARN` / `AWS_TF_ROLE_ARN` secret is missing or wrong, or `github_repo` in **`terraform/bootstrap/terraform.tfvars`** doesn't match your actual repo. If you destroyed the bootstrap stack, the roles no longer exist — re-apply it from your laptop. |
| Deploy fails: `InvalidInstanceId … Instances not in a valid state` | SSM can't reach the box. Either no instance matches the `Name` tag (has the environment been created?), or the SSM agent hasn't registered yet. Check with `aws ssm describe-instance-information --region eu-west-1` — the instance must appear with `PingStatus: Online`. A freshly created instance takes a minute or two to get there. |
| Trivy fails the build | **That's the feature working.** Update the base image (`python:3.12-slim`) or the dependency it flagged. Don't disable the scan. |
| Deploy can't find the instance | It searches for the `Name` tag `devops-workshop-dev-web`. If you changed `project_name` or `environment`, update `ECR_REPOSITORY`, `INSTANCE_NAME_TAG` and `VIDEO_PARAM_PREFIX` in [cicd.yml](.github/workflows/cicd.yml) to match `<project>-<env>`. |
| Page loads but the video doesn't play | The object isn't in the bucket. Do step 5 (`aws s3 cp`). The app reads the fixed key `video.mp4`. |
| `403` pulling from ECR on the box | The EC2 IAM role isn't attached, or the instance has no outbound internet. |
| Page won't load at all | Give it a minute after the first deploy (the instance installs Docker on first boot). Then check the security group allows port 80. |

**Debugging a running container** — connect with SSM Session Manager (browser shell, no
SSH key needed): EC2 console → select the instance → **Connect** → *Session Manager*.

```bash
sudo docker ps                    # is the container running?
sudo docker logs workshop-app     # what did it say?
curl localhost/health             # does it answer?
```

---

## 14. Exercises — make it your own

1. **Break a test** on purpose, push, run the CI/CD pipeline, and watch it refuse to
   deploy.
2. **Change the page** (edit `templates/index.html`), push, re-run the pipeline, and
   watch the footer version change to your new commit SHA.
3. **Add a `/version` route** returning the app version, plus a test for it.
4. **Downgrade the base image** to an older Python and watch Trivy fail the build.
5. **Change `instance_type`** in `terraform.tfvars`, then run the infra pipeline with
   action **`plan`** and read the output carefully — notice Terraform tells you it will
   *replace* the instance, not modify it. Nothing has happened to AWS yet: that's the
   whole value of a plan.
6. **Destroy and rebuild the whole environment** from the Actions tab (`destroy`, then
   `apply`, then re-run CI/CD). Time it. This is what "infrastructure as code" actually
   buys you — and note the pipelines still authenticate afterwards, because the roles
   live in the separate bootstrap stack.
7. **Put the automation back:** add `on: push: branches: [main]` to
   [cicd.yml](.github/workflows/cicd.yml) so deploys happen on every merge, like a real
   project. Then add `pull_request` to [infra.yml](.github/workflows/infra.yml) so infra
   changes get planned on the PR.
8. **Harder:** put an Application Load Balancer in front of the instance and run two of
   them. This is where the `/health` endpoint stops being decorative.

---

## 15. Monitoring & observability — see what your app is doing

Shipping code is half the job. The other half is **knowing what it does once it's
running** — how much memory it eats, whether it's on fire, what it's logging. That's
*observability*, and it rests on three pillars:

| Pillar | Question it answers | Tool here |
|---|---|---|
| **Metrics** | "How much? How fast? How many?" (numbers over time) | Prometheus |
| **Logs** | "What exactly happened, and when?" (lines of text) | Loki + Promtail |
| **Dashboards** | "Show me all of the above at a glance" | Grafana |

To make this tangible, the app now ships an **Ops Console** with buttons that
*actually* consume resources — nothing faked. You press a button, the app really
allocates the RAM (or burns the CPU, or writes the file, or pushes the bytes), and you
watch the graph climb in Grafana seconds later.

### Run the whole thing with one command

```bash
make docker-up
```

That builds the app and starts seven containers wired together (see
[docker-compose.yml](docker-compose.yml)). When it's done it prints every URL:

| URL | What it is |
|---|---|
| http://localhost:8080 | the app (the video page) |
| http://localhost:8080/panel | the **Ops Console** — the buttons |
| http://localhost:8080/metrics | raw Prometheus metrics (what the app exposes) |
| http://localhost:3000 | **Grafana** — open the *"App Observability — Workshop"* dashboard |
| http://localhost:9090 | Prometheus (query the raw time series) |
| http://localhost:8081 | cAdvisor (per-container resource usage) |

Grafana opens straight to the dashboard — no login, the datasources and the dashboard
are **provisioned from files** ([monitoring/grafana/](monitoring/grafana/)), so there's
nothing to click to set up.

Run `make` on its own to see every target, grouped into **Docker** and **Kubernetes**
sections plus shared `stress-*` helpers.

> **Two runtimes, one app.** This same stack also runs on **Kubernetes** with
> `make k8s-up` — same image, same dashboard, same URLs. That parallel is the whole
> teaching point of [§15.1](#151-the-same-app-on-kubernetes--docker-vs-a-real-orchestrator).
> The steps below use the Docker path; do them once here, then repeat them on
> Kubernetes and watch what changes (and what doesn't).

### The demo loop

1. Open **Grafana** (http://localhost:3000) and the **Ops Console**
   (http://localhost:8080/panel) side by side.
2. On the console, press **🧠 Allocate** a few times. Within a few seconds the
   *"Memory allocated"* panel climbs — and so does the cAdvisor *"Container memory
   usage"* panel next to it. The app's self-reported number and what the OS actually
   sees agree. That's the point.
3. Press **🔥 Add core**. The *"CPU worker processes"* graph steps up, and *"Container
   CPU (cores)"* follows as real hashing work saturates a core.
4. Press **💾 Write file**, watch *"Bytes on disk"* rise, then hit **🗑 Cleanup** and
   watch it drop back to zero.
5. Press **🌐 Add traffic** and watch *"Network throughput generated"* jump.
6. Scroll to the **Logs** panel at the bottom — every button press emitted a log line,
   and it's here (via Loki), as well as in the live viewer on the console page itself.

Prefer the terminal? `make stress-mem`, `make stress-cpu`, `make stress-disk`,
`make stress-net`, `make stress-clean` drive the same API the buttons use.

### How it fits together

```mermaid
flowchart LR
    buttons["Ops Console<br/>buttons"] -->|POST /api/load/...| app["Flask app<br/>(really uses RAM/CPU/disk/net)"]
    app -->|GET /metrics| prom["Prometheus<br/>(scrapes every 5s)"]
    app -->|stdout| promtail["Promtail"] --> loki["Loki"]
    cadvisor["cAdvisor"] --> prom
    node["node-exporter"] --> prom
    prom --> grafana["Grafana dashboard"]
    loki --> grafana
```

- **The app** ([app/loadgen.py](app/loadgen.py)) owns the load and updates a Prometheus
  gauge/counter for each resource. [app/metrics.py](app/metrics.py) also records request
  rate and latency; [app/logbuffer.py](app/logbuffer.py) keeps the last few hundred log
  lines for the in-app viewer.
- **Prometheus** ([monitoring/prometheus/prometheus.yml](monitoring/prometheus/prometheus.yml))
  scrapes the app, cAdvisor and node-exporter every 5 seconds.
- **Grafana** ([monitoring/grafana/](monitoring/grafana/)) renders it all, including a
  Loki-powered logs panel.

> **Why a single Gunicorn worker here?** The compose file runs the app with
> `--workers 1 --threads 8` on purpose: all the load and all the metrics live in **one**
> process, so a button click always lands on the process that owns the load. The
> production image keeps its 2 workers — this override is a teaching convenience, and
> the comment in [docker-compose.yml](docker-compose.yml) says so.

### Clean up

```bash
make docker-down     # stop everything, keep the metric/log history
make docker-clean    # stop AND wipe the volumes for a fresh start
```

---

### 15.1 The same app on Kubernetes — Docker vs a real orchestrator

Docker Compose is one host running containers. **Kubernetes** is an *orchestrator*: a
cluster that decides where containers run, restarts them when they die, load-balances
across copies, and enforces resource limits. The best way to feel the difference is to
run the *exact same app and dashboard* on both and poke at them.

Everything for this lives in [k8s/](k8s/) and deploys to a local cluster. The Makefile
targets **OrbStack's built-in Kubernetes** by default (so every object shows up in the
OrbStack ▸ Kubernetes UI), but you can point them at any cluster with `K8S_CONTEXT=…`.

```bash
# In OrbStack: Settings ▸ Kubernetes ▸ enable. Then:
make k8s-up                              # build + deploy everything
# or target another cluster:
make k8s-up K8S_CONTEXT=docker-desktop
```

`make k8s-up` prints the **same URLs** as the Docker path — OrbStack exposes the
`LoadBalancer` Services on your `localhost`, so http://localhost:3000 is the identical
Grafana dashboard. That's the headline: **your app and your observability don't change;
only the runtime underneath does.** (OrbStack even shares its image store with Kubernetes,
so there's no registry push and no image side-loading — the locally-built image just runs.)

> **Safety:** every `k8s-*` target is pinned to the chosen context
> (`kubectl --context $(K8S_CONTEXT)`), so these commands can never touch another cluster
> in your kubeconfig (like a real EKS).

Now run the teaching targets — each prints a short explanation *before* its `kubectl`
output, so you learn the concept and see it at once:

| Command | What it teaches |
|---|---|
| `make k8s-explain` | a Docker-vs-Kubernetes cheat sheet (start here) |
| `make k8s-status` | Deployments, ReplicaSets, Pods, Services, DaemonSets — the objects Compose never had |
| `make k8s-pods` | a **Pod** wraps your container and gets its own IP + a restart count |
| `make k8s-services` | **Services** + endpoints: stable DNS names that load-balance across Pods |
| `make k8s-heal` | delete the app Pod and watch the Deployment **recreate it** — self-healing |
| `make k8s-scale` | scale to 3 replicas in one command (and why our in-memory console then misbehaves — the statefulness lesson) |
| `make k8s-limits` | the app now has **resource requests/limits**; cross the memory limit with the 🧠 button and Kubernetes **OOM-kills and restarts** it |
| `make k8s-logs` | `kubectl logs` instead of `docker logs` |

The `stress-*` helpers work here too (they hit `localhost:8080` either way).

**A few things that are genuinely different under Kubernetes**, all visible in the repo:

- **Config** is stored as **ConfigMaps** (API objects), not bind-mounted files. The
  Makefile builds them from the very same `monitoring/` files, so there's one source of
  truth. ([k8s/10-app.yaml](k8s/10-app.yaml), and the `configmap` steps in the Makefile.)
- **Networking** changes: Compose published ports with `8080:8080`; here each front-facing
  Service is `type: LoadBalancer`, and the platform (OrbStack) hands it a localhost address.
- **Log collection** runs as a **DaemonSet** (one Promtail Pod per node) that tails
  `/var/log/pods` and ships to Loki. ([k8s/50-promtail.yaml](k8s/50-promtail.yaml) — note
  the header there: on a Docker-runtime cluster those files are *symlinks* into
  `/var/lib/docker/containers`, which the DaemonSet also has to mount.)
- **cAdvisor labels the same container differently** under a Kubernetes runtime than under
  Docker Compose, so the dashboard's container panels carry *two* queries — one per runtime
  — and you can watch which one lights up. A small but honest illustration that portability
  has seams.

Tear it all down with:

```bash
make k8s-down     # removes our namespace + objects; leaves OrbStack's cluster intact
```

### Exercises

9. **Add a metric.** Expose a new gauge (say, a "requests in flight" counter) in
   [app/metrics.py](app/metrics.py) and add a panel for it to the dashboard JSON.
10. **Alert on it.** Add a Prometheus alerting rule that fires when
    `app_memory_allocated_bytes` crosses a threshold, and point it at an alert receiver.
11. **Take it to AWS.** The container-level metrics you see in cAdvisor are exactly the
    kind CloudWatch collects for a real EC2 box. Wire the deployed app's `/metrics` into
    a Prometheus running in AWS, or ship its logs to CloudWatch Logs.
12. **Break a limit.** In [k8s/10-app.yaml](k8s/10-app.yaml) lower the memory `limit` to
    `256Mi`, `make k8s-up` again, then hold down 🧠 Allocate. Watch `make k8s-pods` — the
    `RESTARTS` count climbs as Kubernetes OOM-kills and restarts the pod. Compose would
    have let it eat the whole host.
13. **Roll it out.** Change the app, `make k8s-up` to rebuild + redeploy, then
    `kubectl --context orbstack -n workshop rollout restart deployment/app`. Watch a new
    ReplicaSet take over with zero downtime — then try `rollout undo`.
14. **From local to EKS.** These manifests are vanilla Kubernetes. The real graduation
    exercise: push the image to ECR and `kubectl apply -f k8s/` against an EKS cluster.
    The `LoadBalancer` Services that OrbStack fulfils on localhost become real AWS load
    balancers in the cloud — same files, real infrastructure.

Happy shipping. 🚀
