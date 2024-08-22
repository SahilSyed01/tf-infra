provider "aws" {
  region = "us-east-1"
}

# terraform {
#   backend "s3" {
#     bucket = "infra-tf-state-01"
#     key    = "infra-tf/terraform.tfstate"
#     region = "us-east-1"
#   }
# }

# Variable for AWS Resource Name Prefix
variable "aws_resource_name_prefix" {
  description = "Prefix"
  type        = string
  default     = "server"
}

# ECR Repository
resource "aws_ecr_repository" "my_repo" {
  name         = "${var.aws_resource_name_prefix}-repo"
  force_delete = true
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.aws_resource_name_prefix}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json
}

# Policy document for ECS Task Execution Role
data "aws_iam_policy_document" "ecs_task_execution_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Attach necessary policies to the ECS Task Execution Role
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM Role for CircleCI to assume
resource "aws_iam_role" "circleci_role" {
  name               = "${var.aws_resource_name_prefix}-circleci-ecr-role"
  assume_role_policy = data.aws_iam_policy_document.circleci_assume_role.json
}

# IAM Policy with Least Privilege for ECR Access
resource "aws_iam_policy" "circleci_ecr_policy" {
  name        = "${var.aws_resource_name_prefix}-circleci-ecr-policy"
  description = "Policy for CircleCI to push images to ECR"
  policy      = data.aws_iam_policy_document.circleci_ecr_policy.json
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "circleci_policy_attachment" {
  role       = aws_iam_role.circleci_role.name
  policy_arn = aws_iam_policy.circleci_ecr_policy.arn
}

# Policy document for CircleCI assume role
data "aws_iam_policy_document" "circleci_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com", "lambda.amazonaws.com", "ecs-tasks.amazonaws.com"]
    }
  }
}

# Policy document for ECR access 
data "aws_iam_policy_document" "circleci_ecr_policy" {
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = [
      aws_ecr_repository.my_repo.arn,
      "${aws_ecr_repository.my_repo.arn}/*"
    ]
  }
}

# Fetch the Default VPC
data "aws_vpc" "default" {
  default = true
}

# Fetch the Default Subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Fetch the Default Security Group
data "aws_security_group" "default" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "group-name"
    values = ["default"]
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "my_cluster" {
  name = "${var.aws_resource_name_prefix}-cluster"
}

resource "aws_ecs_task_definition" "my_task" {
  family                   = "${var.aws_resource_name_prefix}-task"
  container_definitions    = <<DEFINITION
[
  {
    "name": "my-container",
    "image": "${aws_ecr_repository.my_repo.repository_url}:latest",
    "cpu": 256,
    "memory": 512,
    "essential": true,
    "portMappings": [
      {
        "containerPort": 8080,
        "hostPort": 8080,
        "protocol": "tcp"
      }
    ]
  }
]
DEFINITION
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.circleci_role.arn
}


# ECS Service
resource "aws_ecs_service" "my_service" {
  name            = "${var.aws_resource_name_prefix}-service"
  cluster         = aws_ecs_cluster.my_cluster.id
  task_definition = aws_ecs_task_definition.my_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = data.aws_subnets.default.ids
    security_groups = [data.aws_security_group.default.id]
    assign_public_ip = true
  }

  # Enable Execute Command
  enable_execute_command = true
}

# Output the ECR Repository URL and AWS Resource Name Prefix
output "ecr_repository_url" {
  value = aws_ecr_repository.my_repo.repository_url
}

output "aws_resource_name_prefix" {
  value = var.aws_resource_name_prefix
}
