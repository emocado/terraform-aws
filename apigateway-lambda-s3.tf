# Discover VPC attributes
data "aws_vpc" "this" {
  id = local.vpc_id
}

##########################
# 2. S3 Bucket
##########################
resource "aws_s3_bucket_cors_configuration" "bucket_cors" {
  bucket = aws_s3_bucket.codebuild_repo.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST", "GET"]
    allowed_origins = ["*"] # For testing you can use "*", restrict to your frontend origin for production
    expose_headers  = []
    max_age_seconds = 3000
  }
}

##########################
# 3. Lambda code package
##########################
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda/lambda_function.zip"
}

resource "aws_security_group" "lambda_sg" {
  name        = "lambda_sg"
  description = "Security group for Lambda function"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
    # TODO: allow inbound from api gateway prefix list
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
    # TODO: allow outbound to S3 prefix list
  }
}

resource "aws_lambda_function" "presign" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = filebase64sha256(data.archive_file.lambda_zip.output_path)
  function_name    = "s3-presign-url"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9"
  role             = local.lambda_presign_role_arn
  timeout          = 10

  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
  
  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.codebuild_repo.id
    }
  }
}

# Security group for the Interface VPC Endpoint (controls who can connect to the endpoint)
resource "aws_security_group" "vpce_sg" {
  name        = "vpce-execute-api-sg"
  description = "SG for execute-api VPC endpoint"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    description = "Allow HTTPS from own VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    description = "Allow all egress (to AWS service)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vpce-execute-api-sg"
  }
}

#############################
# API Gateway (REST API) - Private
#############################
resource "aws_api_gateway_rest_api" "api" {
  name = "s3-presign-rest-api"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [aws_vpc_endpoint.execute_api.id]
  }
}

# Create API resource: /get-presigned-url
resource "aws_api_gateway_resource" "presign" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "get-presigned-url"
}

# Method (GET) linked to Cognito Authorizer
resource "aws_api_gateway_method" "get_method" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.presign.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito_authorizer.id
}

# Lambda integration (proxy)
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.presign.id
  http_method             = aws_api_gateway_method.get_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.presign.invoke_arn
}

# Deployment & Stage
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  depends_on = [aws_api_gateway_integration.lambda_integration, aws_api_gateway_rest_api_policy.api_policy]
}

resource "aws_api_gateway_stage" "stage" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
  stage_name    = local.api_gateway_stage
}

# Permission for API Gateway to invoke Lambda
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presign.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

#############################
# Cognito Authorizer (REST API)
#############################
resource "aws_api_gateway_authorizer" "cognito_authorizer" {
  name                             = "cognito-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.api.id
  type                             = "COGNITO_USER_POOLS"
  provider_arns                    = [aws_cognito_user_pool.my_user_pool.arn]
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = 300
}

##########################
# 7. VPC Endpoint for execute-api + Private DNS
##########################
# Endpoint policy allowing access to the specific API (optional tighten)
data "aws_caller_identity" "current" {}

resource "aws_vpc_endpoint" "execute_api" {
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.ap-southeast-1.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = "*",
      Action    = "execute-api:Invoke",
      Resource  = "*"
    }]
  })

  tags = {
    Name = "vpce-execute-api"
  }
}

# Attach an explicit resource policy to the API to only allow invocations via this VPC endpoint
resource "aws_api_gateway_rest_api_policy" "api_policy" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid : "AllowInvokeFromSpecificVpce",
        Effect : "Allow",
        Principal : "*",
        Action : "execute-api:Invoke",
        Resource : "${aws_api_gateway_rest_api.api.execution_arn}/*/*",
        Condition : {
          StringEquals : {
            "aws:SourceVpce" : aws_vpc_endpoint.execute_api.id
          }
        }
      }
    ]
  })
}

# ##########################
# # Cognito User Pool and Client
# ##########################
resource "aws_cognito_user_pool" "my_user_pool" {
  name = "example-pool"
}

# Create an App Client for client_credentials flow and assign custom scopes
resource "aws_cognito_user_pool_client" "my_client" {
  name            = "example-client"
  user_pool_id    = aws_cognito_user_pool.my_user_pool.id
  generate_secret = true

  allowed_oauth_flows = ["client_credentials"]
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.my_resource_server.identifier}/read_access",
    "${aws_cognito_resource_server.my_resource_server.identifier}/write_access"
  ]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]

  # For client_credentials flow, callback URLs are not needed
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = local.cognito_user_pool_domain
  user_pool_id = aws_cognito_user_pool.my_user_pool.id
}

# Define a Resource Server with Custom Scopes
resource "aws_cognito_resource_server" "my_resource_server" {
  user_pool_id = aws_cognito_user_pool.my_user_pool.id
  name         = "My API"
  identifier   = local.cognito_resource_server_identifier

  scope {
    scope_name        = "read_access"
    scope_description = "Read access to My API"
  }

  scope {
    scope_name        = "write_access"
    scope_description = "Write access to My API"
  }
}

# ##########################
# # 5. OUTPUT API ENDPOINT
# ##########################

output "api_gateway_endpoint" {
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${local.aws_region}.amazonaws.com/${aws_api_gateway_stage.stage.stage_name}/get-presigned-url?filename=<your_filename>"
  description = "Invoke this endpoint with a GET request and 'filename' query string."
}

output "user_pool_id" {
  value = aws_cognito_user_pool.my_user_pool.id
}
output "client_id" {
  value = aws_cognito_user_pool_client.my_client.id
}
output "client_secret" {
  value     = aws_cognito_user_pool_client.my_client.client_secret
  sensitive = true
}
output "cognito_domain" {
  value = "${aws_cognito_user_pool_domain.main.domain}.auth.${local.aws_region}.amazoncognito.com"
}
output "cognito_scope" {
  value = "${aws_cognito_resource_server.my_resource_server.identifier}/read_access"
}