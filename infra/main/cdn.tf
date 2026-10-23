# Phase 4 / Step 8-2 — ONE CloudFront distribution = the app's real public
# URL on AWS (HTTPS, free tier, no domain needed). Report story:
#   - S3 website endpoints have no TLS; the JWT lives in a SameSite=Lax
#     cookie tied to the ORIGIN, so UI + APIs must share one HTTPS origin.
#   - CloudFront is that origin: static site from the private S3 bucket
#     (OAC-signed reads, s3.tf policy allows ONLY this distribution),
#     /api/city/* and /api/user/* routed to the two ALBs.
#   - Viewer side is HTTPS-only (redirect); CloudFront -> ALB leg is plain
#     HTTP *inside* the AWS network (albs.tf listener is http-only; no ACM
#     cert exists in a teardown-able account).
#   - SPA fallback: 403/404 from the bucket return index.html with 200 so
#     React Router renders deep links client-side.

# Managed policies are looked up BY NAME via data sources — never
# hand-typed IDs (first apply failed NoSuchOriginRequestPolicy on a typed
# ID; names are the stable contract, the id format is not).
# AllViewerExceptHostHeader forwards query strings AND cookies except
# Host, which CloudFront replaces with the origin's — exactly what the
# ALBs need to route and what the JWT cookie needs to arrive.

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project_name}-oac"
  description                       = "SigV4-signed reads of the private site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  alb_origin_common = {
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
  }
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.project_name} SPA + API (single-HTTPS-origin principle)"
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    domain_name = aws_lb.city_experience.dns_name
    origin_id   = "alb-city"

    custom_origin_config {
      http_port              = local.alb_origin_common.http_port
      https_port             = local.alb_origin_common.https_port
      origin_protocol_policy = local.alb_origin_common.origin_protocol_policy
      origin_ssl_protocols   = ["TLSv1.2"] # required by provider even for http-only origins
    }
  }

  origin {
    domain_name = aws_lb.user_collection.dns_name
    origin_id   = "alb-user"

    custom_origin_config {
      http_port              = local.alb_origin_common.http_port
      https_port             = local.alb_origin_common.https_port
      origin_protocol_policy = local.alb_origin_common.origin_protocol_policy
      origin_ssl_protocols   = ["TLSv1.2"] # required by provider even for http-only origins
    }
  }

  # ------------------------------------------------- behaviours
  # Managed policy IDs (stable, documented by AWS):
  #   Cache:            658327ea-f89d-4fab-a63d-7e88639e58f6 (CachingOptimized)
  #   Origin request:   b689e96b-d54b-4a71-9320-ee2ff8a5ad1e
  #                     (AllViewerExceptHostHeader — forwards query strings
  #                      AND cookies except Host, which CloudFront replaces
  #                      with the origin's — exactly what the ALBs need to
  #                      route and what the JWT cookie needs to arrive).

  ordered_cache_behavior {
    path_pattern             = "/api/city/*"
    target_origin_id         = "alb-city"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = false
    cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  ordered_cache_behavior {
    path_pattern             = "/api/user/*"
    target_origin_id         = "alb-user"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = false
    cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  default_cache_behavior {
    target_origin_id         = "s3-site"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # SPA fallback: deep links (/saved, /profile ...) reach S3 as literal key
  # misses (403/404); serve index.html with 200 and let React Router take
  # over. Small TTL so a genuinely missing asset isn't stuck as the SPA.

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    cloudfront_default_certificate = true # *.cloudfront.net TLS, free
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-cdn" })
}

# ------------------------------------------------------------------ outputs

output "app_url" {
  description = "The app's public HTTPS URL on AWS - open this to see the real app."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "cloudfront_hosted_zone_id" {
  value = aws_cloudfront_distribution.main.hosted_zone_id
}