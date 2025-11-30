terraform {

	required_providers {
		aws = {
			source = "hashicorp/aws"
			version = "~> 5.0"
		}
	}

	required_version = ">= 1.4.0"
}

provider "aws" {
	region = var.region
}

resource "aws_vpc" "default" {
	cidr_block = "10.0.0.0/16"
	enable_dns_support = true # can we access the internet
	enable_dns_hostnames = true # give the aws hostnames

	tags = {
		Name = "default-vpc"
	}

}


resource "aws_internet_gateway" "igw" {
	vpc_id = aws_vpc.default.id
}

resource "aws_route_table" "public" {

	vpc_id = aws_vpc.default.id

	route {
		cidr_block = "0.0.0.0/0"
		gateway_id = aws_internet_gateway.igw.id
	}

}

resource "aws_route_table_association" "public_1a"  {
	subnet_id = aws_subnet.public-1a.id
	route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "public-1a" {
	vpc_id = aws_vpc.default.id # our VPC ID from above (default)
	cidr_block = "10.0.1.0/24"
	availability_zone = "us-east-1a"
	map_public_ip_on_launch = true
	tags = {
		Name = "public-1a"
	}
}

resource "aws_route_table_association" "public_1b" {
	subnet_id = aws_subnet.public-1b.id
	route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "public-1b" {
	vpc_id = aws_vpc.default.id #vpc id
	cidr_block = "10.0.2.0/24"
	availability_zone = "us-east-1b"
	map_public_ip_on_launch = true
	tags = {
		Name = "public-1b"
	}
}

resource "aws_eip" "nat_eip" {
	domain = "vpc"
	tags = {
		Name = "nat-eip"
	}
}

resource "aws_nat_gateway" "nat" {
	allocation_id = aws_eip.nat_eip.id
	subnet_id = aws_subnet.public-1a.id
	tags = {
		Name = "main-natgw"
	}

	depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private_route_table" {
	
	vpc_id = aws_vpc.default.id

	route {
		cidr_block = "0.0.0.0/0"
		nat_gateway_id  = aws_nat_gateway.nat.id
	}
	tags = {
		Name = "private_route_table"
	}
}

resource "aws_route_table_association" "private_1a" {
	subnet_id = aws_subnet.private-1a.id
	route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_1b" {
	subnet_id = aws_subnet.private-1b.id
	route_table_id = aws_route_table.private_route_table.id
}

resource "aws_subnet" "private-1a" {
	vpc_id = aws_vpc.default.id 
	cidr_block = "10.0.3.0/24"
	availability_zone = "us-east-1a"
	map_public_ip_on_launch = false
	tags = {
		Name = "private-1a"
	}
}

resource "aws_subnet" "private-1b" {
	vpc_id = aws_vpc.default.id
	cidr_block = "10.0.4.0/24"
	availability_zone = "us-east-1b"
	map_public_ip_on_launch = false
	tags = {
		Name = "private-1b"
	}
}

resource "aws_lb_target_group" "target-group" {

	name = "target-group"
	port = 80
	protocol = "TCP"
	vpc_id = aws_vpc.default.id

	health_check {
		protocol = "TCP"
		port = "traffic-port"
	}

}

resource "aws_lb" "our-nlb" {

	name = "our-nlb"
	load_balancer_type = "network"

	subnets = [
		aws_subnet.public-1a.id,
		aws_subnet.public-1b.id,
	]
	tags = {
		Name = "our-nlb"
	}
}

resource "aws_lb_listener" "nlb_listener" {
	load_balancer_arn = aws_lb.our-nlb.arn
	port = 80
	protocol = "TCP"

	default_action {
		type = "forward"
		target_group_arn = aws_lb_target_group.target-group.arn
	}

}

output "nlb_dns_name" {
	value = aws_lb.our-nlb.dns_name
}

resource "aws_security_group" "asg_sg" {

	name = "asg-instances-sg"
	description = "allow http to go in and out"
	vpc_id = aws_vpc.default.id

	#inbound rules

	ingress {
		from_port = 80 # defines range not destination/start
		to_port = 80
		protocol = "tcp"
		cidr_blocks = ["0.0.0.0/0"]
	}

	egress {
		from_port = 0
		to_port = 0
		protocol = "-1"
		cidr_blocks = ["0.0.0.0/0"]
	}

	tags = {
		Name = "asg-instances-sg"
	}

}

resource "aws_iam_role" "ec2-role" {
	name = "ec2-role"
	assume_role_policy = jsonencode({
		Version = "2012-10-17"
		Statement = [{
			Effect = "Allow"
			Principal = {Service = "ec2.amazonaws.com"}
			Action = "sts:AssumeRole"
		}]
	})
}

resource "aws_iam_role_policy_attachment" "ssm" {
	role = aws_iam_role.ec2-role.name
	policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cwlogs" {
	role = aws_iam_role.ec2-role.name
	policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2-profile" {
	name = "ec2-instance-profile"
	role = aws_iam_role.ec2-role.name
}

resource "aws_launch_template" "launch-template" {
  name_prefix   = "asg-ec2-"
  image_id      = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

  # stay cheap: keep micro
  instance_type = "t3.micro" 

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2-profile.name
  }

  vpc_security_group_ids = [aws_security_group.asg_sg.id]

  block_device_mappings {
    device_name = "/dev/xvda" # default root device for AL2023

    ebs {
      volume_size = 20      # 20 GB is usually plenty; 16 GB minimum
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = filebase64("${path.module}/user_data.sh")
}


resource "aws_autoscaling_group" "the-asg" {
	name = "the-actual-asg"
	min_size = 2
	max_size = 4
	desired_capacity = 2

	vpc_zone_identifier = [
		aws_subnet.private-1a.id,
		aws_subnet.private-1b.id,
	]

	health_check_type = "EC2"
	health_check_grace_period = 60

	target_group_arns = [aws_lb_target_group.target-group.arn]

	launch_template {
		id = aws_launch_template.launch-template.id
		version = "$Latest"
	}

	tag {
		key = "Name"
		value = "asg-app-instance"
		propagate_at_launch = true
	}

	depends_on = [
		aws_nat_gateway.nat,
		aws_route_table.private_route_table
	]

	lifecycle {
		create_before_destroy = true
	}
}

resource "aws_sns_topic" "security_alerts" {
	name = "security-alerts-topic"
}

resource "aws_sns_topic_subscription" "email_sub" {
	topic_arn = aws_sns_topic.security_alerts.arn
	protocol = "email"
	endpoint = var.email
}

resource "aws_cloudwatch_log_group" "falco_logs" {
  name              = "falco-logs"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "trivy_logs" {
  name              = "trivy-logs"
  retention_in_days = 30
}


resource "aws_cloudwatch_log_metric_filter" "falco_alerts_metric" {
  name           = "falco-detection-count"
  log_group_name = aws_cloudwatch_log_group.falco_logs.name

  pattern = "{ $.priority = \"Alert\" || $.priority = \"Error\" || $.priority = \"Warning\" }"

  metric_transformation {
    name      = "FalcoDetections"
    namespace = "Security"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "falco_alarm" {
  alarm_name          = "falco-detection-alert"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FalcoDetections"
  namespace           = "Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 1

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}


resource "aws_cloudwatch_log_metric_filter" "trivy_alerts_metric" {
  name           = "trivy-vuln-count"
  log_group_name = aws_cloudwatch_log_group.trivy_logs.name

  pattern = "CRITICAL"

  metric_transformation {
    name      = "TrivyVulnerabilities"
    namespace = "Security"
    value     = "1"
  }
}


resource "aws_cloudwatch_metric_alarm" "trivy_alarm" {
  alarm_name          = "trivy-critical-alert"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "TrivyVulnerabilities"
  namespace           = "Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 1

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}
