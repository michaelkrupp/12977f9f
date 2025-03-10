variable "environment" {
  description = "The environment to deploy to"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "The region to deploy to"
  type        = string
  default     = "eu-central-1"
}

variable "secret" {
  description = "The answer to the ultimate question of life, the universe, and everything"
  type        = string
  default     = "42"
}