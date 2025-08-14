# General variables for all Terraform files
vpc_id          = "vpc-12345678" # Replace with your actual VPC ID
private_subnets = ["subnet-12345678", "subnet-23456789"] # Replace with your actual private subnet IDs
env             = "dev"

# Variables for alb-s3.tf
domain_name           = "myown-website-3163.app.com"
acm_cert_arn          = null   # Specify your ACM certificate ARN if using HTTPS
alb_listener_protocol = "HTTP" # change to HTTPS if you have a certificate
alb_ssl_policy        = ""     # specify if using HTTPS, e.g., "ELBSecurityPolicy-2016-08"

# Variables for alb-ecs.tf
cluster_name = "my-ecs-cluster"
ecs_configs = {
  "manager1" = {
    container_port = 80
    host_port      = 80
    task_cpu       = "256"
    task_memory    = "512"
    image_tag      = "latest"
    path_pattern   = ["/manager1/*"]
    priority       = 100
  },
  "manager2" = {
    container_port = 80
    host_port      = 80
    task_cpu       = "256"
    task_memory    = "512"
    image_tag      = "latest"
    path_pattern   = ["/manager2/*"]
    priority       = 101
  }
}

# Variables for apigateway-lambda-s3.tf
api_gateway_stage                  = "prod"               # API Gateway stage for the Lambda function
cognito_user_pool_domain           = "hello-world-828-userpool" # Domain for Cognito User Pool. Cannot contain cognito in the name
cognito_resource_server_identifier = "api.dev-hello-world-828.com"

# Variables for codebuild.tf
account_id = "1234567890123" # Replace with your AWS account ID
aws_region = "ap-southeast-1"