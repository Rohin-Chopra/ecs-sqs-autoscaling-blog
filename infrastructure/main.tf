terraform {
  required_version = "~> 1.7.0"

  required_providers {
    aws = "~> 5.40.0"
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/24"
}

resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.0.0/26"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.0.64/26"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_subnet_1_association" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_subnet_2_association" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_sqs_queue" "queue" {
  name = "orders-queue"
}

resource "aws_ecr_repository" "ecr" {
  name = "consumer"
}

resource "aws_ecs_cluster" "cluster" {
  name = "orders-cluster"
}

resource "aws_iam_role" "role" {
  name = "ordersEcsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "role_policy" {
  statement {
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:CreateLogGroup"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "role_policy" {
  role   = aws_iam_role.role.id
  policy = data.aws_iam_policy_document.role_policy.json
}

data "aws_iam_policy_document" "assume_task_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "task_role" {
  name = "ordersEcsTaskRole"

  assume_role_policy = data.aws_iam_policy_document.assume_task_role.json
}

data "aws_iam_policy_document" "allow_sqs_access" {
  statement {
    effect = "Allow"

    actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]

    resources = [aws_sqs_queue.queue.arn]
  }
}

resource "aws_iam_role_policy" "allow_sqs_access" {
  name   = "allowSQSAccess"
  policy = data.aws_iam_policy_document.allow_sqs_access.json
  role   = aws_iam_role.task_role.id
}

resource "aws_ecs_task_definition" "orders_task_definition" {
  family = "orders"

  execution_role_arn = aws_iam_role.role.arn
  task_role_arn      = aws_iam_role.task_role.arn

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  container_definitions = jsonencode([
    {
      name      = "consumer"
      image     = "${aws_ecr_repository.ecr.repository_url}:latest"
      cpu       = 256
      memory    = 512
      essential = true

      environment = [
        {
          name  = "QUEUE_URL"
          value = aws_sqs_queue.queue.url
        }
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "orders-consumer",
          "awslogs-region"        = "ap-southeast-2",
          "awslogs-create-group"  = "true",
          "awslogs-stream-prefix" = "orders"
        }
      }
    }
  ])
}

resource "aws_security_group" "orders_service_sg" {
  name   = "orders-service-sg"
  vpc_id = aws_vpc.vpc.id
}

resource "aws_vpc_security_group_egress_rule" "allow_tcp_outbound" {
  security_group_id = aws_security_group.orders_service_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_ecs_service" "service" {
  name            = "orders-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.orders_task_definition.arn

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
    security_groups  = [aws_security_group.orders_service_sg.id]
    assign_public_ip = true
  }
}

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.cluster.name}/${aws_ecs_service.service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy" {
  name               = "scale-backlog-per-task"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 40

    customized_metric_specification {
      metric_name = "BacklogPerTask"
      namespace   = "ECS/CustomMetrics"
      statistic   = "Average"
      unit        = "Count"

      dimensions {
        name  = "ClusterName"
        value = aws_ecs_cluster.cluster.name
      }

      dimensions {
        name  = "ServiceName"
        value = aws_ecs_service.service.name
      }
    }
  }
}

data "aws_iam_policy_document" "backlog_per_task_metric_lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "backlog_per_task_metric_lambda_role" {
  name               = "iam_for_lambda"
  assume_role_policy = data.aws_iam_policy_document.backlog_per_task_metric_lambda_assume_role.json
}

data "aws_iam_policy_document" "backlog_per_task_metric_lambda_role" {
  statement {
    effect    = "Allow"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.queue.arn]
  }


  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "backlog_per_task_metric_lambda_policy" {
  role   = aws_iam_role.backlog_per_task_metric_lambda_role.id
  policy = data.aws_iam_policy_document.backlog_per_task_metric_lambda_role.json
}

resource "aws_iam_role_policy_attachment" "backlog_per_task_metric_lambda_basic_policy" {
  role       = aws_iam_role.backlog_per_task_metric_lambda_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "backlog_per_task_metric_lambda" {
  type        = "zip"
  source_file = "${path.module}/../apps/backlog-per-task-lambda/dist/index.js"
  output_path = "data/backlog_per_task_metric_lambda.zip"
}

resource "aws_lambda_function" "backlog_per_task_metric_lambda" {
  filename      = "data/backlog_per_task_metric_lambda.zip"
  function_name = "backlog-per-task-metric-lambda"
  role          = aws_iam_role.backlog_per_task_metric_lambda_role.arn
  handler       = "index.handler"

  source_code_hash = data.archive_file.backlog_per_task_metric_lambda.output_base64sha256

  runtime = "nodejs20.x"

  environment {
    variables = {
      QUEUE_URL        = aws_sqs_queue.queue.url
      ECS_CLUSTER_NAME = aws_ecs_cluster.cluster.name
      ECS_SERVICE_NAME = aws_ecs_service.service.name
    }
  }
}

resource "aws_lambda_permission" "backlog_per_task_metric_lambda" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backlog_per_task_metric_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backlog_per_task_metric_lambda.arn
}

resource "aws_cloudwatch_event_rule" "backlog_per_task_metric_lambda" {
  name                = "backlog-per-task-metric-lambda"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "backlog_per_task_metric_lambda" {
  arn  = aws_lambda_function.backlog_per_task_metric_lambda.arn
  rule = aws_cloudwatch_event_rule.backlog_per_task_metric_lambda.id
}
