## Overview

This repository provisions a **private, internal application stack on AWS** using Terraform.  
It includes:

1. **Internal Application Load Balancer (ALB)** in private subnets:
   - Proxies traffic to an S3 bucket via a **VPC Interface Endpoint**.
   - Can route additional paths to ECS services using listener rules.
   - Private Route53 zone for internal DNS.

2. **ECS Services behind ALB listener rules**:
   - ECR repositories per service.
   - Fargate task definitions and ECS Services.

3. **Private REST API Gateway + Lambda + Amazon Cognito**:
   - Lambda for issuing S3 presigned URLs.
   - Cognito user pool, client (client_credentials), and resource server with custom scopes.
   - JWT authorizer for private API.

4. **CodeBuild + EventBridge for S3-driven builds**:
   - S3 repo bucket with manager-specific prefixes.
   - EventBridge triggers CodeBuild when S3 objects are uploaded.
   - CodeBuild pushes Docker images to ECR.

Terraform is divided by purpose:
- **alb-s3.tf** – ALB, S3 buckets, S3 VPCE, bucket policy, Route53 zone, replication config.
- **alb-ecs.tf** – ECS cluster, task definitions, target groups, listener rules, ECS services.
- **apigateway-lambda-s3.tf** – Filestore bucket CORS, presign Lambda, API Gateway, Cognito.
- **apigateway-lambda-cognito.tf** – Lambda to proxy Cognito token endpoint, private API Gateway for OAuth2/token.
- **codebuild.tf** – CodeBuild bucket + projects + EventBridge rules.

***

## Access and Execution Model

Due to organizational restrictions, Terraform must be run **from a provisioned EC2 instance inside the MCC environment**:

- **IAM users and keys** aren’t available; the EC2 instance uses an **instance profile role** with **AWS managed policy: PowerUserAccess**.
- **PowerUserAccess** allows provisioning of most AWS resources, but **not general IAM role creation**.
- Therefore, some IAM roles **must** be created beforehand using the provided **CloudFormation stack** in `cf-iam-role-creation-template`.

***

## Prerequisites

1. **Create an MCC EC2 instance** with the `PowerUserAccess` AWS managed policy (instance profile).
2. **Install** on the EC2 instance:
   - Terraform CLI (>= 1.2)
   - AWS CLI (optional)
3. **Pre-create IAM roles** using the CloudFormation template:
   - **ECS task execution role** → `ecs-task-execution-role`
   - **Lambda presign role** → `lambda_presign_role`
   - **Lambda basic execution role** → `lambda_basic_execution_role` (for Cognito proxy Lambda)
   - **S3 replication role** → `s3-replication-role`
   - **CodeBuild role** → `codebuild-role`
   - **EventBridge invoke CodeBuild role** → `eventbridge-invoke-codebuild`
4. **Record ARNs** from CloudFormation and either:
   - Set them in `terraform.tfvars`
   - OR accept the `locals.tf` defaults (these assume standard role names).
5. Confirm:
   - Route53 private hosted zone usage in account
   - ACM certificate if HTTPS is required
   - Region supports all required services

***

## Configuration

Rename **`terraform.local.tfvars`** to **`terraform.tfvars`** and edit accordingly (example provided):

- **Networking**
  ```hcl
  vpc_id          = "vpc-12345678"
  private_subnets = ["subnet-12345678", "subnet-23456789"]
  env             = "dev"
  ```

- **ALB/S3**
  ```hcl
  domain_name           = "myown-website-3163.app.com"
  acm_cert_arn          = null              # or your ACM ARN
  alb_listener_protocol = "HTTP"            # or HTTPS
  alb_ssl_policy        = ""                 # e.g., "ELBSecurityPolicy-2016-08"
  ```

- **ECS**
  ```hcl
  cluster_name = "my-ecs-cluster"
  ecs_configs = {
    manager1 = {
      container_port = 80
      host_port      = 80
      task_cpu       = "256"
      task_memory    = "512"
      image_tag      = "latest"
      path_pattern   = ["/manager1/*"]
      priority       = 100
    }
  }
  ```

- **API/Lambda/Cognito**
  ```hcl
  api_gateway_stage                  = "prod"
  cognito_user_pool_domain           = "example-userpool"
  cognito_resource_server_identifier = "api.example.com"
  ```

***

## Resource Creation Sequence

Because `aws_lb_target_group_attachment` for S3 VPCE needs ENI IPs:

1. **Stage 1** – Create VPC Endpoint first:
   ```sh
   terraform apply -target=aws_vpc_endpoint.s3
   ```

2. **Stage 2** – Apply remaining configurations:
   ```sh
   terraform apply
   ```

***

## Key Points in Implementation

- **S3 VPCE type is Interface** (unusual for S3 data):
  - Allows registering VPCE ENI IPs in ALB target group.
- **Bucket Policy** restricts access to VPCE ID via `aws:SourceVpce`.
- **Internal ALB**:
  - Routes default `/` traffic to S3 VPCE.
  - Listener rules forward ECS service paths (from `ecs_configs`).
- **DNS**:
  - Private Route53 zone with alias to ALB for `domain_name`.
- **CodeBuild**:
  - S3 artifact upload → EventBridge rule → Start CodeBuild → Push to ECR.
- **Private API Gateway**:
  - Integrated with VPC endpoint (`execute-api`).
  - Terraform applies **APIGW resource policy** restricting to VPCE.
  - Cognito JWT Authorizer secures `/get-presigned-url`.

***

## Outputs

Terraform outputs include:

- ALB ARN & DNS Name
- Static site S3 bucket name
- ECS Cluster ID
- API Gateway Endpoint (private DNS)
- Cognito User Pool ID, Client ID, Client Secret, Domain, Scope

***

## Operational Notes

- Verify S3 bucket **name validity**:
  - One bucket uses `domain_name`, another uses `ALB DNS name` → adjust if invalid.
- ECS `desired_count` = 0 by default (avoid cost). Increase to run services.
- If switching ALB to HTTPS:
  - Set `acm_cert_arn`, `alb_ssl_policy`, and `alb_listener_protocol = "HTTPS"`.
- Lambda functions are packaged using Terraform `archive_file`.