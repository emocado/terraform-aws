# 1. S3 Bucket and the "areamgr" folder (prefix)
resource "aws_s3_bucket" "codebuild_repo" {
  bucket        = "codebuild-backend-managers-${local.env}"
  force_destroy = true
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket      = aws_s3_bucket.codebuild_repo.id
  eventbridge = true
}

resource "aws_s3_object" "manager_folder" {
  for_each = toset(local.managers)
  bucket   = aws_s3_bucket.codebuild_repo.id
  key      = "${each.value}/"
  # S3 folders are just object keys ending with /; content unnecessary
}

# 3. CodeBuild Project

resource "aws_codebuild_project" "manager" {
  for_each      = toset(local.managers)
  name          = "${each.value}-codebuild"
  description   = "Builds Docker image from S3/areamgr and pushes to ECR"
  service_role  = local.codebuild_role_arn
  build_timeout = 30

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0" # supports Docker-in-Docker
    type            = "LINUX_CONTAINER"
    privileged_mode = true # Needed for Docker build
    environment_variable {
      name  = "ECR_ACCOUNT_ID"
      value = local.account_id
    }
    environment_variable {
      name  = "AWS_REGION"
      value = local.aws_region
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = "${local.env}/${each.value}"
    }
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.codebuild_repo.bucket}/${each.value}/"
    buildspec = "buildspec.yml" # Looks for buildspec.yml in the root of extracted S3 archive
  }
}

# EventBridge rule for S3 upload
resource "aws_cloudwatch_event_rule" "s3_object_create" {
  for_each    = toset(local.managers)
  name        = "trigger-codebuild-on-s3-upload-${each.value}"
  description = "Trigger CodeBuild when object is uploaded to S3 ${each.value} folder"
  event_pattern = jsonencode({
    "source" : ["aws.s3"],
    "detail-type" : ["Object Created"],
    "detail" : {
      "bucket" : {
        "name" : [
          aws_s3_bucket.codebuild_repo.bucket
        ]
      },
      "object" : {
        "key" : [
          {
            "prefix" : "${each.value}/"
          }
        ]
      }
    }
  })
}

# Event target: CodeBuild project as EventBridge target
resource "aws_cloudwatch_event_target" "codebuild_target" {
  for_each = toset(local.managers)
  rule     = aws_cloudwatch_event_rule.s3_object_create[each.value].name
  arn      = aws_codebuild_project.manager[each.value].arn
  role_arn = local.eventbridge_role_arn
}
