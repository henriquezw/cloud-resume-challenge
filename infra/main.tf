terraform {
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 4.0"
        }
    }  
}
provider "aws" {
  region = "us-east-1"
}

# S3 bucket for static website hosting
resource "aws_s3_bucket" "website_bucket" {
    bucket = "henriquedz-resume-site"
    force_destroy = true

}

resource "aws_s3_bucket_public_access_block" "website_bucket_block" {
  bucket = aws_s3_bucket.website_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
# --- DYNAMODB TABLE (Visitor Counter) ---
resource "aws_dynamodb_table" "visitor_count" {
  name         = "visitor-count-table"
  billing_mode = "PAY_PER_REQUEST" # Free Tier friendly (Serverless)
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S" # S = String
  }
}
# --- VARIABLES ---
locals {
  domain_name = "henriquezw.click"
}

# --- SSL CERTIFICATE (HTTPS) ---
# 1. Request the certificate
resource "aws_acm_certificate" "cert" {
  domain_name       = local.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# 2. Get the Hosted Zone (DNS Box) that AWS created when you bought the domain
data "aws_route53_zone" "my_zone" {
  name         = local.domain_name
  private_zone = false
}

# 3. Create the validation record (Prove you own the domain)
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => dvo
  }

  allow_overwrite = true
  name            = each.value.resource_record_name
  records         = [each.value.resource_record_value]
  ttl             = 60
  type            = each.value.resource_record_type
  zone_id         = data.aws_route53_zone.my_zone.zone_id
}

# 4. Wait for validation to complete
resource "aws_acm_certificate_validation" "cert_validate" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# --- CLOUDFRONT (The CDN) ---
# 1. Create access control (OAC) so only CloudFront can read S3
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-oac"
  description                       = "Grant CloudFront access to S3"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 2. The Distribution itself
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name              = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id                = "S3-Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.domain_name]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Origin"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# --- S3 BUCKET POLICY (Permission) ---
# Allow CloudFront to read the bucket
resource "aws_s3_bucket_policy" "allow_cloudfront" {
  bucket = aws_s3_bucket.website_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.website_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# --- ROUTE 53 (DNS) ---
# Point the domain to CloudFront
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.my_zone.zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
resource "aws_iam_role" "GHA_S3_Publisher_Role" {
name = "GHA_S3_Publisher"

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject"
        ],
        "Resource": "arn:aws:s3:::${aws_s3_bucket.website_bucket.id}/*"
      }
    ]
  })
}