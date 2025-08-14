# Assuming role name doesn't change. If the cloudformation template changes (cf-combined), update the role name accordingly.

locals {
  # general variables
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnets
  env             = var.env
  account_id      = var.account_id
  aws_region      = var.aws_region

  # Variables for alb-s3.tf
  domain_name           = var.domain_name
  acm_cert_arn          = var.acm_cert_arn
  alb_listener_protocol = var.alb_listener_protocol
  alb_ssl_policy        = var.alb_ssl_policy
  replication_role_arn  = "arn:aws:iam::${var.account_id}:role/s3-replication-role"

  # Variables for alb-ecs.tf
  ecs_configs                 = var.ecs_configs
  cluster_name                = var.cluster_name
  ecs_task_execution_role_arn = "arn:aws:iam::${var.account_id}:role/ecs-task-execution-role"

  # Variables for apigateway-lambda-s3.tf
  api_gateway_stage                  = var.api_gateway_stage
  cognito_user_pool_domain           = var.cognito_user_pool_domain
  cognito_resource_server_identifier = var.cognito_resource_server_identifier
  lambda_presign_role_arn            = "arn:aws:iam::${var.account_id}:role/lambda_presign_role"

  # Variables for apigateway-lambda-s3.tf
  lambda_basic_execution_role_arn = "arn:aws:iam::${var.account_id}:role/lambda_basic_execution_role"

  # Variables for codebuild.tf
  managers             = keys(var.ecs_configs)
  codebuild_role_arn   = "arn:aws:iam::${var.account_id}:role/codebuild-role"
  eventbridge_role_arn = "arn:aws:iam::${var.account_id}:role/eventbridge-invoke-codebuild"
}