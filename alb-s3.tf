# 1. S3 bucket (name must match your domain_name)
resource "aws_s3_bucket" "static_site" {
  bucket        = local.domain_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.static_site.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "internal_static" {
  bucket        = aws_lb.alb.dns_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "dest" {
  bucket = aws_s3_bucket.internal_static.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Replication configuration: replicate all objects
resource "aws_s3_bucket_replication_configuration" "this" {
  depends_on = [
    aws_s3_bucket_versioning.source,
    aws_s3_bucket_versioning.dest
  ]

  bucket = aws_s3_bucket.static_site.id
  role   = local.replication_role_arn

  rule {
    id       = "replicate-all"
    status   = "Enabled"
    priority = 1

    # Replicate everything
    filter {}

    destination {
      bucket        = aws_s3_bucket.internal_static.arn
      storage_class = "STANDARD"
      # If you use KMS at destination, set replica_kms_key_id and add KMS policy below
      # replica_kms_key_id = aws_kms_key.dest.arn
      # account            = data.aws_caller_identity.dest.account_id (if cross-account)
      # access_control_translation and ownership fields are optional depending on ownership
    }

    # If replicating delete markers, uncomment:
    delete_marker_replication {
      status = "Enabled"
    }

    # If you only want to replicate KMS-encrypted objects or ensure KMS handling:
    # source_selection_criteria {
    #   sse_kms_encrypted_objects { enabled = true }
    # }
  }
}

# 2. VPC S3 Endpoint (Interface)
resource "aws_vpc_endpoint" "s3" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.aws_region}.s3"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  private_dns_enabled = false

  security_group_ids = [aws_security_group.s3_vpce.id]
}

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${local.aws_region}.s3"
}

resource "aws_security_group" "s3_vpce" {
  name        = "s3-vpce"
  vpc_id      = local.vpc_id
  description = "SG for S3 VPC Endpoint"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    description     = "Allow HTTPS to S3 prefix list"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.s3.id]
  }
}

# 3. Update S3 Bucket Policy (restrict to VPCE)
resource "aws_s3_bucket_policy" "vpce_only" {
  bucket = aws_s3_bucket.static_site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource = [
        "arn:aws:s3:::${aws_s3_bucket.static_site.id}",
        "arn:aws:s3:::${aws_s3_bucket.static_site.id}/*"
      ]
      Condition = {
        StringEquals = {
          "aws:SourceVpce" = aws_vpc_endpoint.s3.id
        }
      }
    }]
  })
}

# 4. ALB SG
resource "aws_security_group" "alb" {
  name   = "alb"
  vpc_id = local.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0/0"]
  }
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }
  tags = {
    Name = "alb-sg"
  }
}

# 5. ALB itself (internal)
resource "aws_lb" "alb" {
  name               = "alb-static"
  internal           = true
  load_balancer_type = "application"
  subnets            = local.private_subnets
  security_groups    = [aws_security_group.alb.id]
}

# 6. Target Group (register S3 VPCE IPs as targets)
resource "aws_lb_target_group" "s3_vpce" {
  name        = "s3-static-tg"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = local.vpc_id
  target_type = "ip"
  health_check {
    path     = "/"
    protocol = "HTTP"
    port     = "80"
    matcher  = "307,405" # See ALB health check workaround
  }
}

data "aws_network_interface" "vpce_nis" {
  for_each = aws_vpc_endpoint.s3.network_interface_ids
  id       = each.value
}

resource "aws_lb_target_group_attachment" "vpce_ips" {
  for_each         = data.aws_network_interface.vpce_nis
  target_group_arn = aws_lb_target_group.s3_vpce.arn
  target_id        = each.value.private_ip # each.value represents an element from the set
  port             = 443
}

# 7. HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = local.alb_listener_protocol
  ssl_policy        = local.alb_ssl_policy
  certificate_arn   = local.acm_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.s3_vpce.arn
  }
}

resource "aws_lb_listener_rule" "redirect_trailing_slash" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type = "redirect"

    redirect {
      port        = "#{port}"
      protocol    = "#{protocol}"
      status_code = "HTTP_302"

      # This forms: /<matched path>index.html
      path = "/#{path}index.html"
      # host and query are not set, so defaults are used
    }
  }

  condition {
    path_pattern {
      values = ["*/"]
    }
  }
}

# 8. Route53 private hosted zone
resource "aws_route53_zone" "private" {
  name = local.domain_name
  vpc {
    vpc_id = local.vpc_id
  }
  comment = "Private hosted zone for internal static website"
  tags = {
    Environment = "internal-static"
  }
}

# 9. Route53 private hosted zone alias
resource "aws_route53_record" "internal_dns" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = false
  }
}

# 10. Optionally, IAM/bucket policy tweaks and index.html upload can be added.

output "alb_arn" {
  value = aws_lb.alb.arn
}
output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}
output "s3_bucket_name" {
  value = aws_s3_bucket.static_site.id
}
output "alb_listener_https_arn" {
  value = aws_lb_listener.https.arn
}