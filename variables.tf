variable "name" {
  description = "Service name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "targets" {
  description = "Targets for SSM association in format KEY:VALUE (one per line)"
  type        = string
}

variable "status" {
  description = "Service status (enabled/disabled)"
  type        = string
}

variable "working_directory" {
  description = "Working directory for artifacts"
  type        = string
}

variable "artifact_path" {
  description = "Path to artifacts in S3"
  type        = string
}

variable "definition_file" {
  description = "Service definition file path"
  type        = string
}

variable "artifacts_path" {
  description = "Local path to artifacts directory"
  type        = string
} 