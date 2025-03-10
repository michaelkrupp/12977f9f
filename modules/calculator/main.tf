resource "random_uuid" "module_id" {}

locals {
  tags = merge(var.default_tags, {
    Name = "calculator-${random_uuid.module_id.result}"
  })
}

data "aws_region" "current" {}

// Create base infrastrucrture

resource "aws_sns_topic" "lamda_function_input" {
  tags = local.tags
}

resource "aws_sqs_queue" "lamda_function_output" {
  fifo_queue                  = true
  content_based_deduplication = true

  tags = local.tags
}

resource "aws_vpc" "lambda_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.tags
}

// Setup VPC networking

resource "aws_subnet" "lambda_subnet" {
  vpc_id     = aws_vpc.lambda_vpc.id
  cidr_block = "10.0.1.0/24"

  tags = local.tags
}

// Setup Lamda

resource "aws_iam_role" "lambda_role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/calculator"
  retention_in_days = 14

  tags = local.tags
}

data "local_file" "lambda_extensions_package_lock" {
  filename = "${path.root}/lib/extension/secretmanager/package-lock.json"
}

resource "null_resource" "lambda_extensions_node_modules" {
  triggers = {
    file_changed = sha256(data.local_file.lambda_extensions_package_lock.content)
  }

  provisioner "local-exec" {
    working_dir = "${path.root}/lib/extension/secretmanager"
    command = "npm install"
  }
}

data "archive_file" "lambda_extensions" {
  type        = "zip"
  source_dir  = "${path.root}/lib/extension"
  output_path = "${path.root}/var/extension.zip"

  depends_on = [ null_resource.lambda_extensions_node_modules ]
}

resource "aws_lambda_layer_version" "lambda_extensions" {
  layer_name          = "extension"
  compatible_runtimes = ["nodejs22.x"]
  filename            = data.archive_file.lambda_extensions.output_path
  source_code_hash    = data.archive_file.lambda_extensions.output_base64sha256

}

data "local_file" "lambda_function_package_lock" {
  filename = "${path.root}/lib/function/package-lock.json"
}

resource "null_resource" "lambda_function_node_modules" {
  triggers = {
    file_changed = sha256(data.local_file.lambda_function_package_lock.content)
  }

  provisioner "local-exec" {
    working_dir = "${path.root}/lib/function"
    command = "npm install"
  }
}

data "archive_file" "lamda_function" {
  type        = "zip"
  source_dir  = "${path.root}/lib/function"
  output_path = "${path.root}/var/function.zip"

    depends_on = [ null_resource.lambda_function_node_modules ]
}

resource "aws_lambda_function" "calculator" {
  filename         = data.archive_file.lamda_function.output_path
  function_name    = "calculator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  source_code_hash = data.archive_file.lamda_function.output_base64sha256
  layers           = [aws_lambda_layer_version.lambda_extensions.arn]

  vpc_config {
    subnet_ids         = [aws_subnet.lambda_subnet.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      SQS_QUEUE_URL = aws_sqs_queue.lamda_function_output.url
      SECRET_NAME   = aws_secretsmanager_secret.lambda_secret.name
      SECRETMANAGER_PORT = 9000
    }
  }

  depends_on = [data.archive_file.lamda_function]

  tags = local.tags
}

resource "aws_security_group" "lambda_sg" {
  description = "Security group for Lambda function"
  vpc_id      = aws_vpc.lambda_vpc.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.lambda_vpc.cidr_block] # Allow to all VPC IPs
  }

  tags = local.tags
}



// Setup VPC access to SQS and Secrets Manager

resource "aws_security_group" "vpce_sg" {
  description = "Security group for SQS VPC endpoint"
  vpc_id      = aws_vpc.lambda_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.lambda_vpc.cidr_block] # Allow from all VPC IPs
  }

  tags = local.tags
}

resource "aws_vpc_endpoint" "sqs" {
  vpc_id             = aws_vpc.lambda_vpc.id
  service_name       = "com.amazonaws.${data.aws_region.current.name}.sqs"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = [aws_subnet.lambda_subnet.id]
  security_group_ids = [aws_security_group.vpce_sg.id]

  private_dns_enabled = true
  tags                = local.tags
}

resource "aws_vpc_endpoint" "secrets_manager" {
  vpc_id             = aws_vpc.lambda_vpc.id
  service_name       = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = [aws_subnet.lambda_subnet.id]
  security_group_ids = [aws_security_group.vpce_sg.id]

  private_dns_enabled = true
  tags                = local.tags
}

// Subscribe Lambda to SNS

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.lamda_function_input.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.calculator.arn
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.calculator.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.lamda_function_input.arn
}

// Setup secret

resource "aws_secretsmanager_secret" "lambda_secret" {
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "lambda_secret_version" {
  secret_id     = aws_secretsmanager_secret.lambda_secret.id
  secret_string = var.secret_value
}

// Setup VPC permissions

resource "aws_iam_role_policy" "lambda_policy" {
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
        ]
        Resource = [
          aws_sqs_queue.lamda_function_output.arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.lambda_secret.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachNetworkInterface"
        ]
        Resource = ["*"]
      },
      # {
      #   Effect = "Allow"
      #   Action = [
      #     "ec2:DescribeSecurityGroups",
      #     "ec2:DescribeSubnets",
      #     "ec2:DescribeVpcs"
      #   ]
      #   Resource = ["*"]
      # }
    ]
  })
}

