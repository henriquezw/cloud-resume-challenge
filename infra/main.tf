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