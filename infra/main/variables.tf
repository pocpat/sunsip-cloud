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