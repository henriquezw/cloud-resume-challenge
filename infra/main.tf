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
  bucket        = "henriquedz-resume-site"
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
# Resource for AWS OIDC indentity provider that trusts Github, this will tell AWS that GH tokens are ok to be trusted
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com" # GH's OIDC token service URL
  client_id_list  = ["sts.amazonaws.com"]                         # AWS STS service is the intended audience for the tokens
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]  # GitHub's thumbprint from https://awsfundamentals.com/blog/github-actions-to-aws
}
# IAM Role that GH Actions can assume to get temporary credentials, only works for pushes to main branch.
resource "aws_iam_role" "gha_s3_publisher_role" {
  name = "GHA_S3_Publisher"

  # TRUST POLICY: "Allow GitHub Actions to assume this role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
            "token.actions.githubusercontent.com:sub" = "repo:henriquezw/cloud-resume-challenge:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}
# The policy that allows the above role to upload files to S3, and optionally invalidate CloudFront cache when needed. This policy is attached to the role.
resource "aws_iam_role_policy" "s3_publish_policy" {
  name = "s3-publish-policy"
  role = aws_iam_role.gha_s3_publisher_role.id

  # PERMISSIONS POLICY: "Allow uploading files to the specific bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject", # Needed for 'sync --delete'
          "s3:ListBucket"    # Needed to check what files exist
        ]
        Resource = [
          aws_s3_bucket.website_bucket.arn,
          "${aws_s3_bucket.website_bucket.arn}/*"
        ]
      },
      {
        # Allow CloudFront Invalidation, clearlring CF cache
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = aws_cloudfront_distribution.cdn.arn
      }
    ]
  })
}
# --- LAMBDA FUNCTION (Visitor Counter) ---
data "archive_file" "lambda_zip" {
  type = "zip"
  # grab the Python file
  source_file = "${path.module}/../backend/lambda_function.py"
  # and zip it
  output_path = "${path.module}/lambda_function.zip"
}
# --- IAM ROLE FOR LAMBDA ---
# The Trust Policy: Allows the Lambda service to assume this role
resource "aws_iam_role" "lambda_exec_role" {
  name = "visitor_counter_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# --- IAM POLICY (DYNAMODB PERMISSIONS) ---
# The Key Card: Gives the role permission to update your specific DynamoDB table
resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "lambda_dynamodb_policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ]
        # Dynamically grabs the ARN of the table you created earlier!
        Resource = aws_dynamodb_table.visitor_count.arn
      },
      {
        # Basic permissions so Lambda can write error logs to CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- THE LAMBDA FUNCTION ---
resource "aws_lambda_function" "visitor_counter" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "VisitorCounter"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_function.lambda_handler"

  # This hash tells Terraform to re-deploy if it detects changes in python file
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  runtime = "python3.9"

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.visitor_count.name
    }
  }
}
# --- 1. THE HTTP API ---
resource "aws_apigatewayv2_api" "http_api" {
  name          = "visitor_counter_api"
  protocol_type = "HTTP"

  # CORS configuration is CRITICAL for the frontend to talk to the backend
  cors_configuration {
    allow_origins = ["https://henriquezw.click/"] # You can lock this down to "https://henriquezw.click" later
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
    max_age       = 300
  }
}

# --- THE STAGE (AUTO-DEPLOY) ---
resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

# --- THE INTEGRATION (CONNECT API TO LAMBDA) ---
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  
  # Tells the API Gateway exactly which Lambda to trigger
  integration_uri  = aws_lambda_function.visitor_counter.invoke_arn
}

# --- THE ROUTE (THE URL PATH) ---
resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /" # Triggers on any method at the root URL
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# --- LAMBDA PERMISSION (THE BOUNCER FOR THE API) ---
resource "aws_lambda_permission" "api_gw_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter.function_name
  principal     = "apigateway.amazonaws.com"

  # Restricts permission so ONLY this specific API can trigger the Lambda
  source_arn = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# --- OUTPUT THE PUBLIC URL ---
# This prints the final API URL in your terminal so you can copy/paste it into your frontend code
output "api_endpoint" {
  description = "The public URL for your Visitor Counter API"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}