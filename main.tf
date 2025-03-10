module "calculator" {
  source = "./modules/calculator"
  secret_value = var.secret
}