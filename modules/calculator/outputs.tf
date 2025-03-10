output "sns_arn" {
  value = aws_sns_topic.lamda_function_input.arn
}
output "sqs_arn" {
  value = aws_sqs_queue.lamda_function_output.arn
}
output "secret_arn" {
  value = aws_secretsmanager_secret.lambda_secret.arn
}