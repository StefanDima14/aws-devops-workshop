# AWS DevOps Workshop — Flask App on EC2 via CI/CD

A complete, hands-on workshop showing the **full DevOps deployment lifecycle**: a
Python/Flask app that plays a video, containerised with Docker, infrastructure
provisioned with Terraform, and shipped to AWS EC2 through a GitHub Actions
pipeline that **tests → builds → scans → deploys**.

## What students will see

```
 Developer push ──► GitHub Actions
                     │
                     ├─ 1. TEST      (pytest)
                     ├─ 2. BUILD     (docker build)
                     ├─ 3. SCAN      (Trivy — fails on HIGH/CRITICAL CVEs)
                     ├─ 4. PUSH      (image ──► Amazon ECR)
                     └─ 5. DEPLOY    (SSM ──► EC2 pulls & runs container)
                                          │
                              Browser ◄── http://<EC2-public-ip>  🎬 video
```

## Architecture

```
              Internet
                 │
          ┌──────▼──────┐  Security Group: 80 open, 22 = your IP only
          │   EC2 (t3.micro)         │
          │  ┌────────────────────┐  │
          │  │ Docker: workshop-app│ │  ◄── image pulled from ECR
          │  │ gunicorn :8080 ►:80 │  │──┐ presigned GET (EC2 IAM role)
          │  └────────────────────┘  │  │
          └──────────────────────────┘  ▼
   VPC 10.0.0.0/16 · public subnet    Private S3 bucket 🎬 video.mp4
   IGW · Elastic IP                   (no public access)
```

## Repository layout

```
aws-devops-workshop/
├── app/                     # Flask application
│   ├── app.py               #   routes: / (video via presigned S3 URL) and /health
│   ├── templates/index.html
│   ├── static/style.css
│   ├── requirements.txt     #   Flask, gunicorn, boto3
│   ├── Dockerfile           # non-root, healthcheck, gunicorn
│   └── .dockerignore
├── tests/
│   ├── test_app.py          # pytest unit tests (incl. presign fallback)
│   └── requirements-dev.txt
├── assets/                  # put video.mp4 here (git-ignored; lives in S3)
├── scripts/
│   └── bootstrap-backend.sh # creates the S3+DynamoDB remote-state backend
├── terraform/               # Infrastructure as Code
│   ├── versions.tf          # providers + S3 remote state (partial backend)
│   ├── variables.tf
│   ├── network.tf           # VPC, subnet, IGW, routes
│   ├── security.tf          # security group
│   ├── s3.tf                # private video bucket + EC2 read IAM + SSM params
│   ├── ecr_iam.tf           # ECR repo + EC2 IAM role
│   ├── ec2.tf               # EC2 instance + Elastic IP + Docker bootstrap
│   ├── github_oidc.tf       # OIDC provider + app-deploy CI role
│   ├── github_terraform.tf  # OIDC role for the infra pipeline
│   ├── outputs.tf
│   ├── backend.hcl.example
│   └── terraform.tfvars.example
└── .github/workflows/
    ├── cicd.yml             # app pipeline: test → build → scan → push → deploy
    └── infra.yml            # infra pipeline: fmt → validate → plan → apply
```

---

## Prerequisites

- An AWS account + the **AWS CLI** configured (see Authentication below)
- **Terraform** ≥ 1.5
- A **GitHub repository** (push this code to it)
- Docker (only if you want to build locally; the pipeline builds for you)

---

## Authentication — who needs credentials, and where

**The pipelines store no AWS keys.** They authenticate with **GitHub OIDC**:
GitHub presents a short-lived signed token, AWS trusts it *only* for your repo,
and hands back temporary credentials that expire in ~1 hour. The two GitHub
secrets you add are just **role ARNs** (public identifiers), not access keys.

You only need real AWS credentials **on your own machine**, and only for two
one-time steps that must happen before OIDC can take over:

1. `scripts/bootstrap-backend.sh` — creates the state bucket + lock table
2. the **first** `terraform apply` — creates the OIDC provider + the CI roles
   themselves (a role can't create itself)

After that, every push/PR runs through OIDC and needs nothing from you.

### Getting local credentials — best → acceptable

**Best — IAM Identity Center (SSO):** no long-lived keys on disk.
```bash
aws configure sso     # one-time
aws sso login         # temporary creds that auto-expire
```

**Acceptable for a workshop — an IAM user with AdministratorAccess:**
```bash
aws configure         # stores keys in ~/.aws/credentials (chmod 600)
```
If you go this route: **rotate or delete the access key once CI is on OIDC** —
leaked static keys are the #1 AWS incident cause.

### Where each thing lives

| Thing | Where | Long-lived? |
|---|---|---|
| Local creds (bootstrap + first apply) | `~/.aws/` via `aws sso login` or `aws configure` | SSO: no · IAM key: yes → delete after |
| `AWS_ROLE_ARN`, `AWS_TF_ROLE_ARN` | GitHub → Settings → **Secrets** | No — just ARNs |
| `TF_STATE_BUCKET`, `TF_LOCK_TABLE`, `MY_IP_CIDR` | GitHub → Settings → **Variables** | No — not secret |
| **AWS access keys** | **Never** in GitHub / the repo / `terraform.tfvars` / env vars you log | — |

> `terraform.tfvars`, `backend.hcl`, and `*.pem` are git-ignored so real values
> never get committed. Keep it that way.

---

## Step-by-step

### 1. Push this code to your GitHub repo

```bash
git init && git add . && git commit -m "workshop"
git remote add origin git@github.com:<you>/aws-devops-workshop.git
git push -u origin main
```

### 2. Bootstrap the remote state backend (once)

Terraform state is stored remotely (S3 + a DynamoDB lock) so your laptop and the
infra pipeline share one source of truth. Create those two resources once:

```bash
export AWS_REGION=eu-west-1
export TF_STATE_BUCKET=<your-unique-name>-devops-workshop-tfstate
./scripts/bootstrap-backend.sh
```

Then point Terraform at them:

```bash
cd terraform
cp backend.hcl.example backend.hcl      # edit: set your bucket name
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: my_ip_cidr (curl -s https://checkip.amazonaws.com)
# and github_repo = "<you>/aws-devops-workshop"

terraform init -backend-config=backend.hcl
```

### 3. Provision the infrastructure (first apply from your laptop)

The pipeline can't create its own IAM role/OIDC provider, so run the **first**
apply locally with admin credentials. Afterwards the infra pipeline takes over.

```bash
terraform apply     # review the plan, type yes
```

Terraform outputs the values you need:

| Output | Use it for |
|---|---|
| `app_url` | The browser URL (works after first deploy) |
| `github_actions_role_arn` | GitHub **secret** `AWS_ROLE_ARN` (app pipeline) |
| `github_terraform_role_arn` | GitHub **secret** `AWS_TF_ROLE_ARN` (infra pipeline) |
| `video_bucket_name` | Where to upload your `video.mp4` |
| `ecr_repository_url` | (info) where images land |

### 4. Upload the video to S3

The app streams from a **private** bucket via presigned URLs. Give it an object:

```bash
BUCKET=$(cd terraform && terraform output -raw video_bucket_name)
aws s3 cp assets/video.mp4 "s3://$BUCKET/video.mp4"
```

> Prefer Terraform to upload it? Set `video_source_path = "../assets/video.mp4"`
> in `terraform.tfvars` and re-apply. Do this **before** the first deploy — once
> the container runs against the bucket, a missing object just 404s in the
> browser (the public fallback only applies when no bucket is configured at all,
> e.g. local dev).

### 5. Wire the pipelines' AWS access

In your GitHub repo: **Settings → Secrets and variables → Actions**, add:

**Secrets**
- `AWS_ROLE_ARN` = `github_actions_role_arn` output (app pipeline)
- `AWS_TF_ROLE_ARN` = `github_terraform_role_arn` output (infra pipeline)

**Variables**
- `TF_STATE_BUCKET` = your state bucket name
- `TF_LOCK_TABLE` = `devops-workshop-tf-locks`
- `MY_IP_CIDR` = your IP CIDR *(optional; only used if you enable SSH)*

> This uses **OIDC** — no AWS access keys are ever stored in GitHub. The roles
> only trust *your* repository.

### 6. Trigger the pipelines

- **Infra pipeline** runs on any change under `terraform/**`. Open a PR to get a
  `plan` comment; merge to `main` to `apply`.
- **App pipeline** runs on every push to `main`:

```bash
git commit --allow-empty -m "trigger deploy" && git push
```

Watch **Actions** run `test` → `build-and-scan` → `deploy`.

### 7. Open the app 🎬

```bash
cd terraform && terraform output app_url
```

Open that URL — the video (streamed from your private S3 bucket) plays, and the
footer shows the image tag (git SHA) and the container hostname.

---

## Teaching talking points (the "what a DevOps does")

- **Build once, run anywhere:** same image, config via env vars (`VIDEO_BUCKET`, `APP_VERSION`).
- **Private data, no public bucket:** video lives in a locked-down S3 bucket; the app
  mints short-lived **presigned URLs** with the instance's IAM role — no creds in the image.
- **Shift-left security:** Trivy scans in CI *and* ECR scan-on-push; build fails on HIGH/CRITICAL.
- **Least privilege:** EC2 role can pull ECR, read *only* the video object, and be managed by SSM.
- **Keyless auth:** GitHub OIDC removes long-lived secrets — a real-world best practice.
- **No SSH needed to deploy:** Session Manager (SSM) runs the deploy remotely.
- **Config discovery, not hardcoding:** Terraform publishes the bucket/key to SSM Parameter
  Store; the deploy job reads it — the random bucket suffix is never hardcoded in CI.
- **Two pipelines, two roles:** app CI/CD and infrastructure CI/CD are separate workflows
  with separately-scoped OIDC roles and shared, locked remote state.
- **Immutable, traceable deploys:** image tag = git SHA, so every deploy maps to a commit.
- **IaC:** the entire environment is reproducible and destroyable in one command.

## Verify locally (optional demo)

```bash
# Run the app without Docker (no bucket set → uses the public fallback video)
cd app && pip install -r requirements.txt
gunicorn --bind 0.0.0.0:8080 app:app
# visit http://localhost:8080

# Point it at your real S3 bucket (needs AWS creds with s3:GetObject):
VIDEO_BUCKET=<bucket> VIDEO_OBJECT_KEY=video.mp4 AWS_REGION=eu-west-1 \
  gunicorn --bind 0.0.0.0:8080 app:app

# Or with Docker
docker build -t workshop ./app
docker run -p 8080:8080 workshop
```

## Clean up (avoid charges)

```bash
cd terraform && terraform destroy
```

t3.micro + ECR + EIP fit comfortably in the **Free Tier**. The only sneaky cost
is an **Elastic IP that stays allocated while the instance is stopped** — so run
`terraform destroy` when you're done.

## Common gotchas

- **Pipeline can't find the instance:** it locates the box by the `Name` tag
  `devops-workshop-dev-web`. If you changed `project_name`/`environment`, update
  `ECR_REPOSITORY` in `.github/workflows/cicd.yml` to match `<project>-<env>`.
- **Trivy fails the build:** that's the point — bump the base image
  (`python:3.12-slim`) or add a justified `.trivyignore`. Don't disable the scan.
- **403 pulling from ECR on the box:** confirm the EC2 IAM role attached and that
  the instance has outbound internet (it does, via the IGW route).
- **Video won't play (S3 404) after deploy:** the object isn't in the bucket yet —
  run the `aws s3 cp` in step 4 (the container reads a fixed key, `video.mp4`).
- **Infra pipeline fails on `init`:** you skipped the bootstrap. Run
  `scripts/bootstrap-backend.sh` and set repo variables `TF_STATE_BUCKET` / `TF_LOCK_TABLE`.
- **`fmt -check` fails the infra pipeline:** run `terraform fmt -recursive` and commit.

> Changed `project_name`/`environment`? Update the `ECR_REPOSITORY`,
> `INSTANCE_NAME_TAG`, and `VIDEO_PARAM_PREFIX` env values in
> `.github/workflows/cicd.yml` to match `<project>-<env>`.
