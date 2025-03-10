variable "default_tags" {
  type = map(string)
  default = {
    "App" = "calculator"
  }
}
variable "secret_value" {
  type    = string
}