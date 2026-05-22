# ECS Deployment Guide — FortiCNAPP AWS Inventory API

Replace all `ACCOUNT_ID` and `REGION` placeholders with your actual values before running any command.

---

## 1. Create the ECR Repository

```bash
aws ecr create-repository \
  --repository-name forticnapp-aws-inventory \
  --region REGION
```

---

## 2. Build and Push the Docker Image

```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region REGION \
  | docker login --username AWS --password-stdin \
    ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com

# Build
docker build -t forticnapp-aws-inventory .

# Tag
docker tag forticnapp-aws-inventory:latest \
  ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/forticnapp-aws-inventory:latest

# Push
docker push \
  ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/forticnapp-aws-inventory:latest
```

---

## 3. Create the IAM Task Role

The task role is assumed by the running container and must have permission to call
the AWS APIs used by the inventory script.

```bash
# Create the role with the ECS tasks trust policy
aws iam create-role \
  --role-name forticnapp-inventory-task-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach the minimum required permissions
aws iam put-role-policy \
  --role-name forticnapp-inventory-task-role \
  --policy-name FortiCNAPPInventoryPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "EC2Read",
        "Effect": "Allow",
        "Action": [
          "ec2:DescribeRegions",
          "ec2:DescribeInstances"
        ],
        "Resource": "*"
      },
      {
        "Sid": "ECSRead",
        "Effect": "Allow",
        "Action": [
          "ecs:ListClusters",
          "ecs:ListTasks",
          "ecs:DescribeTasks"
        ],
        "Resource": "*"
      },
      {
        "Sid": "LambdaRead",
        "Effect": "Allow",
        "Action": [
          "lambda:ListFunctions"
        ],
        "Resource": "*"
      },
      {
        "Sid": "STSRead",
        "Effect": "Allow",
        "Action": [
          "sts:GetCallerIdentity"
        ],
        "Resource": "*"
      },
      {
        "Sid": "OrganizationsRead",
        "Effect": "Allow",
        "Action": [
          "organizations:ListAccounts"
        ],
        "Resource": "*"
      },
      {
        "Sid": "AssumeOrgRole",
        "Effect": "Allow",
        "Action": [
          "sts:AssumeRole"
        ],
        "Resource": "arn:aws:iam::*:role/OrganizationAccountAccessRole",
        "Condition": {
          "StringEquals": {
            "sts:ExternalId": "FortiCNAPP"
          }
        }
      }
    ]
  }'
```

> **Note:** Remove the `AssumeOrgRole` statement if you are not using organization scanning (`-o` flag).

---

## 4. Create the CloudWatch Log Group

```bash
aws logs create-log-group \
  --log-group-name /ecs/forticnapp-aws-inventory \
  --region REGION
```

---

## 5. Register the Task Definition

**Fargate:**
```bash
# Edit ecs/task-definition-fargate.json first — replace ACCOUNT_ID and REGION
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition-fargate.json \
  --region REGION
```

**EC2:**
```bash
# Edit ecs/task-definition-ec2.json first — replace ACCOUNT_ID and REGION
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition-ec2.json \
  --region REGION
```

---

## 6. Create the ECS Service

### Fargate

```bash
# Create or use an existing ECS cluster
aws ecs create-cluster --cluster-name forticnapp --region REGION

aws ecs create-service \
  --cluster forticnapp \
  --service-name forticnapp-aws-inventory \
  --task-definition forticnapp-aws-inventory \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[SUBNET_ID],
    securityGroups=[SG_ID],
    assignPublicIp=ENABLED
  }" \
  --region REGION
```

### EC2

```bash
aws ecs create-service \
  --cluster forticnapp \
  --service-name forticnapp-aws-inventory \
  --task-definition forticnapp-aws-inventory \
  --desired-count 1 \
  --launch-type EC2 \
  --region REGION
```

---

## 7. Invoke the API

Once the service is running, find the public IP or DNS of the task/container:

```bash
# Fargate: get the task ENI public IP
TASK_ARN=$(aws ecs list-tasks --cluster forticnapp \
  --service-name forticnapp-aws-inventory \
  --query 'taskArns[0]' --output text --region REGION)

ENI_ID=$(aws ecs describe-tasks --cluster forticnapp \
  --tasks "$TASK_ARN" --region REGION \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text)

PUBLIC_IP=$(aws ec2 describe-network-interfaces \
  --network-interface-ids "$ENI_ID" \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text --region REGION)

echo "API base URL: http://${PUBLIC_IP}:8080"
```

**Health check:**
```bash
curl http://${PUBLIC_IP}:8080/health
```

**Start a scan (default credentials / IRSA):**
```bash
curl -s -X POST http://${PUBLIC_IP}:8080/scan \
  -H "Content-Type: application/json" \
  -d '{"regions": "us-east-1,us-west-2"}' | jq .
```

**Poll for results:**
```bash
JOB_ID="<job_id from POST response>"
curl -s http://${PUBLIC_IP}:8080/scan/${JOB_ID} | jq .
```
