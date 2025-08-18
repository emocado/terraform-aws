terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
  }

  backend "http" {
    # These will be overridden/filled in from state.config during init
    address         = ""
    lock_address    = ""
    unlock_address  = ""
    username        = ""
    password        = ""
    lock_method     = "POST"
    unlock_method   = "DELETE"
    retry_wait_min  = 5
  }

  required_version = ">= 1.2"
}

provider "aws" {
  region = "ap-southeast-1"
}

resource "aws_s3_bucket" "example" {
  bucket = "my-tf-test-bucket-2725"
}