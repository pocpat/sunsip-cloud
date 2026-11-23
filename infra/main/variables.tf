variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "sunsip-cloud"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to use (brief requires at least 2)"
  type        = number
  default     = 2
}

variable "service_ports" {
  description = "Container ports of the two microservices"
  type        = map(number)
  default = {
    city-experience = 4001
    user-collection = 4002
  }
}

variable "alert_email" {
  description = "Email that receives SNS alerts (deploy failures, scaling events). Owner confirms the AWS subscription email once."
  type        = string
  default     = "elena@kroupkin.com"
}

variable "openweather_api_key" {
  description = "OpenWeather API key injected into the city-experience task env (server-side only, never in the browser bundle). Value lives in terraform.tfvars (gitignored). Empty = the service serves its designed mock weather."
  type        = string
  default     = ""
}

# Phase 6-open-item fix (27 Oct): the city card IMAGE + LANDMARK chain gates on
# these env vars (imagegen.ts / landmark.ts). MISSING = the designed mock
# serves instead of the real generated image. Values live in terraform.tfvars
# (gitignored), extracted from the live app's .env by redirect — never printed.
variable "imagerouter_api_key" {
  description = "ImageRouter key - primary image generation (3/day free quota). Empty = image mock."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openrouter_api_key" {
  description = "OpenRouter key - landmark/description text chain. Empty = text mock."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openrouter_text_model" {
  description = "OpenRouter text model for landmark.ts. Empty = the code's default model applies."
  type        = string
  default     = ""
}

variable "cloudflare_api_key" {
  description = "Workers AI (flux-1-schnell) FALLBACK for image generation. Empty stays allowed: the .env carried no Cloudflare keys, so the fallback stays off (mock on ImageRouter failure) - documented tradeoff."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account id paired with the fallback key above."
  type        = string
  default     = ""
}