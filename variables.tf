# Variables for alb-s3.tf
variable "vpc_id" {
  description = "The ID of the VPC where resources will be created."
  type        = string
}
variable "private_subnets" {
  description = "List of private subnet IDs where resources will be created."
  type        = list(string)
}
variable "domain_name" {
  description = "The domain name for the ACM certificate."
  type        = string
}
variable "acm_cert_arn" {
  description = "ARN of the ACM certificate for HTTPS. If not provided, HTTP will be used."
  type        = string
}
variable "alb_listener_protocol" {
  description = "Protocol for the ALB listener. Default is HTTP."
  type        = string
}
variable "alb_ssl_policy" {
  description = "SSL policy for the ALB listener. Required if using HTTPS."
  type        = string
}

# Variables for alb-ecs.tf
variable "ecs_configs" {
  description = "Map of ECS service configs"
  type = map(object({
    container_port = number
    host_port      = number
    task_cpu       = string
    task_memory    = string
    image_tag      = string
    path_pattern   = list(string)
    priority       = number
  }))
}
variable "cluster_name" {
  type        = string
  description = "Name of the ECS Cluster"
}
variable "env" {
  type        = string
  description = "Environment for the deployment (e.g., dev, qa, stg)"
}

# Variables for apigateway-lambda-s3.tf
variable "api_gateway_stage" {
  description = "API Gateway stage name"
  type        = string
}
variable "cognito_user_pool_domain" {
  description = "Cognito User Pool domain. This will be <domain>.auth.<region>.amazoncognito.com"
  type        = string
}
variable "cognito_resource_server_identifier" {
  description = "Cognito Resource Server identifier"
  type        = string
}

# Variables for codebuild.tf
variable "account_id" {
  description = "AWS account ID for CodeBuild"
  type        = string
}
variable "aws_region" {
  description = "AWS region for CodeBuild"
  type        = string
}