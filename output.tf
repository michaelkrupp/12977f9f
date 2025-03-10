output "sns_arn" {
  value = module.calculator.sns_arn
}
output "sqs_arn" {
  value = module.calculator.sqs_arn
}
output "secret_arn" {
    value = module.calculator.secret_arn
}