variable "project_id" {
  description = "GCP project ID hosting the test deployment (dedicated test project!)"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "aws_account_id" {
  description = "AWS account ID hosting the test deployment (dedicated test account!)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
}

variable "run_suffix" {
  description = "Short unique suffix for this test run (lowercase hex, e.g. 'a1b2c3'); embeds in every resource name"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{4,8}$", var.run_suffix))
    error_message = "run_suffix must be 4-8 lowercase alphanumeric characters."
  }
}
