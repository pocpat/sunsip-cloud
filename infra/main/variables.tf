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
  default     = "elena@kroupkin.com" # Elena's own address - shown in submission video/report
}

variable "openweather_api_key" {
  description = "OpenWeather API key injected into the city-experience task env (server-side only, never in the browser bundle). Value lives in terraform.tfvars (gitignored). Empty = the service serves its designed mock weather."
  type        = string
  default     = ""
}