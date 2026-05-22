# FortiCNAPP AWS Inventory API — Makefile
# Usage: make <target>
#
# Override ACCOUNT_ID and REGION for ECR targets:
#   make ecr-login ACCOUNT_ID=123456789012 REGION=us-east-1

ACCOUNT_ID ?= ACCOUNT_ID
REGION     ?= us-east-1
IMAGE_NAME  = forticnapp-aws-inventory
ECR_URI     = $(ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com/$(IMAGE_NAME)

.PHONY: build run stop logs test-health test-scan ecr-login ecr-push k8s-deploy k8s-delete

## Build the Docker image
build:
	docker build -t $(IMAGE_NAME) .

## Start the API with Docker Compose
run:
	docker compose up

## Stop and remove the Docker Compose stack
stop:
	docker compose down

## Tail logs from the running container
logs:
	docker compose logs -f

## Hit the health endpoint
test-health:
	curl -s http://localhost:8080/health | python3 -m json.tool

## Submit a test scan request (adjust regions as needed)
test-scan:
	curl -s -X POST http://localhost:8080/scan \
	  -H "Content-Type: application/json" \
	  -d '{"regions":"us-east-1"}' | python3 -m json.tool

## Authenticate Docker to ECR  (requires ACCOUNT_ID and REGION)
ecr-login:
	aws ecr get-login-password --region $(REGION) \
	  | docker login --username AWS --password-stdin $(ECR_URI)

## Tag and push the image to ECR  (requires ACCOUNT_ID and REGION)
ecr-push: build
	docker tag $(IMAGE_NAME):latest $(ECR_URI):latest
	docker push $(ECR_URI):latest

## Apply all Kubernetes manifests
k8s-deploy:
	kubectl apply -f k8s/

## Delete all Kubernetes resources
k8s-delete:
	kubectl delete -f k8s/
