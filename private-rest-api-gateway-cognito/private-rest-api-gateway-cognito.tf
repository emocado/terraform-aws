terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
  }
  required_version = ">= 1.2"
}

provider "aws" {
  region = "ap-southeast-1"
}

##########################
# Variables
##########################
variable "vpc_id" {
  description = "Existing VPC ID"
  type        = string
  default     = "vpc-c403c2a2"
}

variable "existing_private_subnet_id" {
  description = "Existing private subnet ID in the given VPC"
  type        = string
  default     = "subnet-0ef28a15cb676dd34"
}

variable "api_gateway_stage" {
  type    = string
  default = "prod"
}

# Cognito settings
variable "cognito_user_pool_domain" {
  description = "your-domain.auth.ap-southeast-1.amazoncognito.com <- supply only the left part; we'll build the FQDN"
  type        = string
  default     = "api-gateway-pool"
}

variable "cognito_resource_server_identifier" {
  description = "Cognito Resource Server identifier"
  type        = string
  default     = "api.dev-my-resource.com"
}

##########################
# Data
##########################
data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  private_subnet_id  = var.existing_private_subnet_id
  region             = "ap-southeast-1"
}

##########################
# Security Groups
##########################
# SG for execute-api VPC Endpoint (who can reach endpoint ENI)
resource "aws_security_group" "vpce_execute_api_sg" {
  name        = "vpce-execute-api-sg"
  description = "SG for execute-api VPC endpoint"
  vpc_id      = data.aws_vpc.this.id

  # Allow HTTPS from Lambda tester SG (added below)
  ingress {
    description     = "Allow HTTPS from Lambda tester"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_tester_sg.id]
  }

  egress {
    description = "Allow all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vpce-execute-api-sg" }
}

# SG for SSM interface endpoints (kept in case you later use SSM in VPC)
resource "aws_security_group" "vpce_ssm_sg" {
  name        = "vpce-ssm-sg"
  description = "SG for SSM interface endpoints"
  vpc_id      = data.aws_vpc.this.id

  # Allow HTTPS from Lambda tester SG too (optional)
  ingress {
    description     = "Allow HTTPS from Lambda tester"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_tester_sg.id]
  }

  egress {
    description = "Allow all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vpce-ssm-sg" }
}

# Lambda tester SG: egress to VPC only (API is via VPCe)
resource "aws_security_group" "lambda_tester_sg" {
  name        = "lambda-tester-sg"
  description = "SG for Lambda that tests the Private REST API"
  vpc_id      = data.aws_vpc.this.id

  egress {
    description = "Allow all egress within VPC CIDR"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  tags = { Name = "lambda-tester-sg" }
}

##########################
# VPC Endpoints
##########################
resource "aws_vpc_endpoint" "execute_api" {
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.private_subnet_id]
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_execute_api_sg.id]

  policy = jsonencode({
    Statement = [{
      Effect    = "Allow",
      Principal = "*",
      Action    = "*",
      Resource  = "*"
    }]
  })

  tags = { Name = "vpce-execute-api" }
}

# Optional: keep SSM endpoints if you use SSM in this VPC for other resources
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.private_subnet_id]
  security_group_ids  = [aws_security_group.vpce_ssm_sg.id]
  private_dns_enabled = true
  tags = { Name = "vpce-ssm" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.private_subnet_id]
  security_group_ids  = [aws_security_group.vpce_ssm_sg.id]
  private_dns_enabled = true
  tags = { Name = "vpce-ssmmessages" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.private_subnet_id]
  security_group_ids  = [aws_security_group.vpce_ssm_sg.id]
  private_dns_enabled = true
  tags = { Name = "vpce-ec2messages" }
}

##########################
# Cognito user pool + domain + resource server + client
##########################
resource "aws_cognito_user_pool" "pool" {
  name = "example-pool"
}

resource "aws_cognito_user_pool_domain" "domain" {
  domain       = var.cognito_user_pool_domain
  user_pool_id = aws_cognito_user_pool.pool.id
}

locals {
  cognito_token_url = "https://${aws_cognito_user_pool_domain.domain.domain}.auth.${local.region}.amazoncognito.com/oauth2/token"
}

resource "aws_cognito_resource_server" "my_resource_server" {
  user_pool_id = aws_cognito_user_pool.pool.id
  name         = "My API"
  identifier   = var.cognito_resource_server_identifier

  scope {
    scope_name        = "read_access"
    scope_description = "Read access to My API"
  }

  scope {
    scope_name        = "write_access"
    scope_description = "Write access to My API"
  }
}

resource "aws_cognito_user_pool_client" "my_client" {
  name                                 = "example-client"
  user_pool_id                         = aws_cognito_user_pool.pool.id
  generate_secret                      = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.my_resource_server.identifier}/read_access",
    "${aws_cognito_resource_server.my_resource_server.identifier}/write_access"
  ]
}

##########################
# Private REST API with HTTP proxy to Cognito token endpoint
##########################
resource "aws_api_gateway_rest_api" "private_api" {
  name = "private-rest-proxy-cognito"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [aws_vpc_endpoint.execute_api.id]
  }
}

resource "aws_api_gateway_resource" "oauth2" {
  rest_api_id = aws_api_gateway_rest_api.private_api.id
  parent_id   = aws_api_gateway_rest_api.private_api.root_resource_id
  path_part   = "oauth2"
}

resource "aws_api_gateway_resource" "token" {
  rest_api_id = aws_api_gateway_rest_api.private_api.id
  parent_id   = aws_api_gateway_resource.oauth2.id
  path_part   = "token"
}

resource "aws_api_gateway_method" "post_token" {
  rest_api_id   = aws_api_gateway_rest_api.private_api.id
  resource_id   = aws_api_gateway_resource.token.id
  http_method   = "POST"
  authorization = "NONE"

  request_parameters = {
    "method.request.header.Content-Type" = false
  }
}

resource "aws_api_gateway_integration" "http_proxy_to_cognito" {
  rest_api_id             = aws_api_gateway_rest_api.private_api.id
  resource_id             = aws_api_gateway_resource.token.id
  http_method             = aws_api_gateway_method.post_token.http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = local.cognito_token_url

  passthrough_behavior = "WHEN_NO_MATCH"

  request_parameters = {
    "integration.request.header.Content-Type" = "method.request.header.Content-Type"
  }
}

resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.private_api.id
  depends_on  = [aws_api_gateway_integration.http_proxy_to_cognito]
}

resource "aws_api_gateway_stage" "stage" {
  rest_api_id   = aws_api_gateway_rest_api.private_api.id
  deployment_id = aws_api_gateway_deployment.deploy.id
  stage_name    = var.api_gateway_stage
}

# API resource policy: only allow invoke via our VPC endpoint
resource "aws_api_gateway_rest_api_policy" "policy" {
  rest_api_id = aws_api_gateway_rest_api.private_api.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowInvokeFromSpecificVpce",
      Effect    = "Allow",
      Principal = "*",
      Action    = "execute-api:Invoke",
      Resource  = "${aws_api_gateway_rest_api.private_api.execution_arn}/*/*",
      Condition = {
        StringEquals = {
          "aws:SourceVpce" = aws_vpc_endpoint.execute_api.id
        }
      }
    }]
  })
}

##########################
# Lambda tester (Node.js 20) in the private subnet
##########################
resource "aws_iam_role" "lambda_tester_role" {
  name = "lambda-tester-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_exec" {
  role       = aws_iam_role.lambda_tester_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda_tester_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Optional: VPC access policy is not required; Lambda VPC networking is controlled by vpc_config.
# Add permissions only if you later need to call other AWS services.

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/index.mjs"
  output_path = "${path.module}/index.zip"
}

resource "aws_lambda_function" "tester" {
  function_name    = "private-api-cognito-token-tester"
  role             = aws_iam_role.lambda_tester_role.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = filebase64sha256(data.archive_file.lambda_zip.output_path)
  timeout          = 15
  memory_size      = 256

  # Put Lambda in the same VPC/subnet as the VPC endpoint
  vpc_config {
    subnet_ids         = [local.private_subnet_id]
    security_group_ids = [aws_security_group.lambda_tester_sg.id]
  }

  # IMPORTANT: set API_URL when you know restapi-id (after first apply)
  # For first apply, we set a placeholder; update to VPCe DNS or rely on Private DNS
  environment {
    variables = {
      API_URL       = "https://${aws_api_gateway_rest_api.private_api.id}.execute-api.${local.region}.amazonaws.com/${var.api_gateway_stage}/oauth2/token"
      CLIENT_ID     = aws_cognito_user_pool_client.my_client.id
      CLIENT_SECRET = aws_cognito_user_pool_client.my_client.client_secret
      SCOPE         = "${aws_cognito_resource_server.my_resource_server.identifier}/read_access"
    }
  }

  depends_on = [
    aws_vpc_endpoint.execute_api,
    aws_api_gateway_stage.stage,
    aws_api_gateway_rest_api_policy.policy
  ]
}

##########################
# Outputs
##########################
output "execute_api_vpce_id" {
  value = aws_vpc_endpoint.execute_api.id
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.private_api.id
}

output "rest_api_stage" {
  value = aws_api_gateway_stage.stage.stage_name
}

output "lambda_tester_name" {
  value = aws_lambda_function.tester.function_name
}

output "tester_api_url_env" {
  description = "Lambda ENV API_URL currently set to call the private API path"
  value       = "https://${aws_api_gateway_rest_api.private_api.id}.execute-api.${local.region}.amazonaws.com/${var.api_gateway_stage}/oauth2/token"
}
