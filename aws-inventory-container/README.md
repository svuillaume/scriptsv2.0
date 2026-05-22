# FortiCNAPP AWS Inventory API

A containerized FastAPI service that wraps `lw_aws_inventory.sh` and exposes an asynchronous
HTTP API for collecting EC2, ECS Fargate, and Lambda vCPU inventory across one or more AWS
accounts or an entire AWS Organization.

---

## What's inside the container

The Docker image is self-contained. You do **not** need to install anything on the host
(other than Docker itself).

| Included | Version | Purpose |
|----------|---------|---------|
| **Python** | 3.11 | FastAPI runtime |
| **AWS CLI v2** | latest | Required by `lw_aws_inventory.sh` to call AWS APIs |
| **jq** | latest | Required by `lw_aws_inventory.sh` to parse JSON responses |
| **bash** | 3.2+ | Required to execute the inventory script |
| **FastAPI + Uvicorn** | 0.111 / 0.30 | HTTP API layer |

> ✅ No AWS CLI install needed on the host.  
> ✅ No jq install needed on the host.  
> ✅ Just Docker + AWS credentials.

---

## ⚠️ AWS Credentials Required

The container calls live AWS APIs. It **must** be given valid AWS credentials at runtime.
No credentials = every scan will fail.

| Method | When to use |
|--------|------------|
| **Environment variables** | Local development / CI pipelines |
| **Mounted `~/.aws`** | Local development with named profiles |
| **ECS Task IAM Role** | Running on ECS (Fargate or EC2) — no keys needed |
| **IRSA** | Running on Kubernetes / EKS — no keys needed |

### Minimum permissions required

The identity (API key, task role, or IRSA role) must have:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRegions",
        "ec2:DescribeInstances",
        "ecs:ListClusters",
        "ecs:ListTasks",
        "ecs:DescribeTasks",
        "lambda:ListFunctions",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

For **AWS Organization scanning** (the `-o` flag), add:

```json
{
  "Effect": "Allow",
  "Action": [
    "organizations:ListAccounts",
    "sts:AssumeRole"
  ],
  "Resource": "*"
}
```

---

## Architecture

```
HTTP Client
    │
    │  POST /scan  (profile, regions, org_role, account_id)
    ▼
FastAPI  (app/main.py)          ← runs inside the container
    │
    │  asyncio.create_subprocess_exec
    ▼
lw_aws_inventory.sh             ← runs inside the container
    │                              uses AWS CLI v2 + jq (both baked in)
    │  aws API calls (needs credentials passed to the container)
    ▼
AWS APIs  (EC2 / ECS / Lambda / STS / Organizations)
    │
    │  CSV stdout
    ▼
scanner.py  (parse CSV → JSON)
    │
    ▼
GET /scan/{job_id}  →  JobStatus + ScanResult (JSON)
```

---

## Quick Start — Local Docker

```bash
# 1. Enter the project directory
cd aws-inventory-container

# 2. Set your AWS credentials
export AWS_ACCESS_KEY_ID=AKIAxxxxxxxxxxxxxxxx
export AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export AWS_DEFAULT_REGION=us-east-1

# 3. Build the image (AWS CLI v2 + jq baked in — takes ~2 min first time)
make build

# 4. Start the API
make run
```

The API is now available at **http://localhost:8080**  
Interactive docs: **http://localhost:8080/docs**

### Using named AWS profiles instead of keys

```bash
# docker-compose.yml mounts ~/.aws read-only into the container
# Just omit the env vars and set profile in your scan request:
make run

curl -X POST http://localhost:8080/scan \
  -H "Content-Type: application/json" \
  -d '{"profile": "myprofile", "regions": "us-east-1"}'
```

---

## API Reference

### `GET /health`

```bash
curl http://localhost:8080/health
# → {"status":"ok","version":"1.0.0"}
```

---

### `POST /scan`

Starts an async inventory scan. Returns a `job_id` immediately — poll `GET /scan/{job_id}` for results.

**Request body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `profile` | string | No | AWS CLI profile name |
| `regions` | string | No | Comma-separated regions, e.g. `"us-east-1,us-west-2"`. Default: all regions |
| `org_role` | string | No | Cross-account role name for organization scanning |
| `account_id` | string | No | 12-digit account ID (requires `org_role`) |

**Examples:**

```bash
# Default credentials, one region
curl -X POST http://localhost:8080/scan \
  -H "Content-Type: application/json" \
  -d '{"regions": "us-east-1"}'

# Named profile, multiple regions
curl -X POST http://localhost:8080/scan \
  -H "Content-Type: application/json" \
  -d '{"profile": "production", "regions": "us-east-1,us-west-2,eu-west-1"}'

# Entire AWS Organization
curl -X POST http://localhost:8080/scan \
  -H "Content-Type: application/json" \
  -d '{"org_role": "OrganizationAccountAccessRole"}'

# One specific account within an organization
curl -X POST http://localhost:8080/scan \
  -H "Content-Type: application/json" \
  -d '{"org_role": "OrganizationAccountAccessRole", "account_id": "123456789012"}'
```

**Response `202 Accepted`:**

```json
{
  "job_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "status": "pending",
  "message": "Scan job 3fa85f64... queued. Poll GET /scan/3fa85f64... for results."
}
```

---

### `GET /scan/{job_id}`

Poll for job status and results.

```bash
curl http://localhost:8080/scan/3fa85f64-5717-4562-b3fc-2c963f66afa6
```

**Response:**

```json
{
  "job_id": "3fa85f64-...",
  "status": "completed",
  "created_at": "2026-05-22T14:00:00Z",
  "updated_at": "2026-05-22T14:02:35Z",
  "request": { "regions": "us-east-1" },
  "result": {
    "success": true,
    "accounts": [
      {
        "profile": "",
        "account_id": "123456789012",
        "regions": "us-east-1",
        "ec2_instances": 42,
        "ec2_vcpus": 168,
        "ecs_clusters": 3,
        "ecs_running_tasks": 12,
        "ecs_cpu_units": 6144,
        "ecs_license_vcpus": 6,
        "lambda_functions": 25,
        "total_vcpus": 174
      }
    ],
    "total_ec2_vcpus": 168,
    "total_ecs_vcpus": 6,
    "total_vcpus": 174,
    "errors": [],
    "duration_seconds": 155.3
  }
}
```

**Job lifecycle:** `pending` → `running` → `completed` or `failed`

---

### `GET /scans`

List all jobs, newest first (max 50).

```bash
curl http://localhost:8080/scans
```

---

## Deploy to ECS Fargate

> ECS Task IAM Role is used — **no API keys needed** in the container.

```bash
# 1. Build and push to ECR
make ecr-login ACCOUNT_ID=123456789012 REGION=us-east-1
make ecr-push  ACCOUNT_ID=123456789012 REGION=us-east-1

# 2. Create a CloudWatch log group
aws logs create-log-group --log-group-name /ecs/forticnapp-aws-inventory --region us-east-1

# 3. Create the IAM Task Role (see ecs/README.md for the full policy)
#    Attach the minimum permissions policy listed above to:
#    arn:aws:iam::ACCOUNT_ID:role/forticnapp-inventory-task-role

# 4. Edit ecs/task-definition-fargate.json — replace ACCOUNT_ID and REGION

# 5. Register task definition
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition-fargate.json \
  --region us-east-1

# 6. Create cluster and service
aws ecs create-cluster --cluster-name forticnapp --region us-east-1
aws ecs create-service \
  --cluster forticnapp \
  --service-name forticnapp-aws-inventory \
  --task-definition forticnapp-aws-inventory \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration \
    "awsvpcConfiguration={subnets=[SUBNET_ID],securityGroups=[SG_ID],assignPublicIp=ENABLED}" \
  --region us-east-1
```

See [ecs/README.md](ecs/README.md) for the full IAM policy and step-by-step guide.

---

## Deploy to ECS EC2

```bash
# Same ECR push + IAM role steps as Fargate, then:

aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition-ec2.json \
  --region us-east-1

aws ecs create-service \
  --cluster forticnapp \
  --service-name forticnapp-aws-inventory \
  --task-definition forticnapp-aws-inventory \
  --desired-count 1 \
  --launch-type EC2 \
  --region us-east-1
```

---

## Deploy to Kubernetes / EKS

> IRSA (IAM Roles for Service Accounts) is recommended — **no API keys needed** in the pod.

```bash
# 1. Edit k8s/deployment.yaml — replace ACCOUNT_ID and REGION with your ECR image URI
# 2. For static keys: edit k8s/secret.yaml and base64-encode your credentials
#    For IRSA (recommended): follow the comments in k8s/deployment.yaml

make k8s-deploy

# Get the LoadBalancer hostname
kubectl get svc forticnapp-aws-inventory

# Tear down
make k8s-delete
```

---

## Makefile Reference

| Target | Description |
|--------|-------------|
| `make build` | Build Docker image |
| `make run` | Start via docker compose (mounts `~/.aws`) |
| `make stop` | Stop docker compose |
| `make logs` | Tail container logs |
| `make test-health` | `curl /health` |
| `make test-scan` | Quick scan of us-east-1 |
| `make ecr-login ACCOUNT_ID=… REGION=…` | Authenticate Docker to ECR |
| `make ecr-push  ACCOUNT_ID=… REGION=…` | Tag and push image to ECR |
| `make k8s-deploy` | `kubectl apply -f k8s/` |
| `make k8s-delete` | `kubectl delete -f k8s/` |

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Could not resolve account ID` | No AWS credentials in the container | Pass `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` env vars, or use an IAM role |
| `ExpiredToken` | Temporary credentials have expired | Re-export fresh credentials and restart the container |
| `AccessDenied` on assume-role | Cross-account role trust policy missing | Verify the role's trust policy allows your account — see the Permissions section |
| Scan returns 0 for all counts | Credentials valid but wrong region | Specify `-r` with a region where your workloads run |
| `mapfile: command not found` | Older bash (< 4.0) was invoked | The container uses bash from the system — already fixed in the script |
