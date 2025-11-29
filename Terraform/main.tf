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
	availability_zone = "us-east-1a"
	map_public_ip_on_launch = true
	tags = {
		Name = "public-1b"
	}
}