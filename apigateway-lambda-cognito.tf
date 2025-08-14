##########################
# 3. Lambda code package
##########################
data "archive_file" "lambda_cognito_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_cognito_function.py"
  output_path = "${path.module}/lambda/lambda_cognito_function.zip"
}

resource "aws_lambda_function" "cognito" {
  filename         = data.archive_file.lambda_cognito_zip.output_path
  source_code_hash = filebase64sha256(data.archive_file.lambda_cognito_zip.output_path)
  function_name    = "proxy-cognito-token-endpoint"
  handler          = "lambda_cognito_function.lambda_handler"
  runtime          = "python3.9"
  role             = local.lambda_basic_execution_role_arn
  timeout          = 10
  environment {
    variables = {
      COGNITO_DOMAIN = "${aws_cognito_user_pool_domain.main.domain}.auth.ap-southeast-1.amazoncognito.com",
      COGNITO_SCOPE  = "${aws_cognito_resource_server.my_resource_server.identifier}/read_access"
    }
  }
}

##########################
# 4. API Gateway (REST API) - Private
##########################
resource "aws_api_gateway_rest_api" "proxy-cognito-token-api" {
  name = "proxy-cognito-token-api"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [aws_vpc_endpoint.execute_api.id]
  }
}

resource "aws_api_gateway_resource" "oauth2" {
  rest_api_id = aws_api_gateway_rest_api.proxy-cognito-token-api.id
  parent_id   = aws_api_gateway_rest_api.proxy-cognito-token-api.root_resource_id
  path_part   = "oauth2"
}

resource "aws_api_gateway_resource" "oauth2_token" {
  rest_api_id = aws_api_gateway_rest_api.proxy-cognito-token-api.id
  parent_id   = aws_api_gateway_resource.oauth2.id
  path_part   = "token"
}

# Method (GET) linked to Cognito Authorizer
resource "aws_api_gateway_method" "cognito_get_method" {
  rest_api_id   = aws_api_gateway_rest_api.proxy-cognito-token-api.id
  resource_id   = aws_api_gateway_resource.oauth2_token.id
  http_method   = "GET"
  authorization = "NONE"
}

# Lambda integration (proxy)
resource "aws_api_gateway_integration" "cognito_lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.proxy-cognito-token-api.id
  resource_id             = aws_api_gateway_resource.oauth2_token.id
  http_method             = aws_api_gateway_method.cognito_get_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cognito.invoke_arn
}

# Deployment & Stage
resource "aws_api_gateway_deployment" "cognito_deployment" {
  rest_api_id = aws_api_gateway_rest_api.proxy-cognito-token-api.id

  depends_on = [aws_api_gateway_integration.cognito_lambda_integration, aws_api_gateway_rest_api_policy.cognito_api_policy]
}

resource "aws_api_gateway_stage" "cognito_stage" {
  rest_api_id   = aws_api_gateway_rest_api.proxy-cognito-token-api.id
  deployment_id = aws_api_gateway_deployment.cognito_deployment.id
  stage_name    = local.api_gateway_stage
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cognito.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.proxy-cognito-token-api.execution_arn}/*/*"
}

resource "aws_api_gateway_rest_api_policy" "cognito_api_policy" {
  rest_api_id = aws_api_gateway_rest_api.proxy-cognito-token-api.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid : "AllowInvokeFromSpecificVpce",
        Effect : "Allow",
        Principal : "*",
        Action : "execute-api:Invoke",
        Resource : "${aws_api_gateway_rest_api.proxy-cognito-token-api.execution_arn}/*/*",
        Condition : {
          StringEquals : {
            "aws:SourceVpce" : aws_vpc_endpoint.execute_api.id
          }
        }
      }
    ]
  })
}
