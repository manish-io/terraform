provider "aws" {
  region = "us-east-1"
}

# Initialize availability zone data from AWS
data "aws_availability_zones" "available" {}

# VPC resource
resource "aws_vpc" "myVpc" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "myVpc"
  }
}

# Internet gateway for the public subnets
resource "aws_internet_gateway" "myInternetGateway" {
  vpc_id = aws_vpc.myVpc.id

  tags = {
    Name = "myInternetGateway"
  }
}

# Public Subnets
resource "aws_subnet" "public_subnet" {
  count                   = length(data.aws_availability_zones.available.names)
  vpc_id                  = aws_vpc.myVpc.id
  cidr_block              = "10.20.${10 + count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet-${count.index}"
  }
}

# Private Subnets
resource "aws_subnet" "private_subnet" {
  count                   = length(data.aws_availability_zones.available.names)
  vpc_id                  = aws_vpc.myVpc.id
  cidr_block              = "10.20.${20 + count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "PrivateSubnet-${count.index}"
  }
}

# Routing table for public subnets
resource "aws_route_table" "rtblPublic" {
  vpc_id = aws_vpc.myVpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.myInternetGateway.id
  }

  tags = {
    Name = "rtblPublic"
  }
}

# Route table association for public subnets
resource "aws_route_table_association" "route" {
  count          = length(data.aws_availability_zones.available.names)
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.rtblPublic.id
}

# Elastic IP for NAT gateway
resource "aws_eip" "nat" {
  vpc = true
}

# NAT Gateway
resource "aws_nat_gateway" "nat-gw" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_subnet[0].id  

  depends_on = [
    aws_internet_gateway.myInternetGateway,
  ]
}

# Routing table for private subnets
resource "aws_route_table" "rtblPrivate" {
  vpc_id = aws_vpc.myVpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat-gw.id
  }

  tags = {
    Name = "rtblPrivate"
  }
}

# Route table association for private subnets
resource "aws_route_table_association" "private_route" {
  count          = length(data.aws_availability_zones.available.names)
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.rtblPrivate.id
}
# Security Group for EC2 instance
resource "aws_security_group" "instance" {
  vpc_id = aws_vpc.myVpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "instance-sg"
  }
}

# EC2 Instance
resource "aws_instance" "web" {
  ami                    = "ami-0ac80df6eff0e70b5"  
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public_subnet[0].id  
  vpc_security_group_ids = [aws_security_group.instance.id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              sudo apt update -y
              sudo apt install -y nginx
              sudo systemctl start nginx
              sudo systemctl enable nginx
              sudo apt install -y ec2-instance-connect
              EOF

  tags = {
    Name = "web-instance"
  }
}
# ALB
resource "aws_lb" "alb" {
  name               = "main-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.instance.id]
  subnets            = [aws_subnet.public_subnet[0].id, aws_subnet.public_subnet[1].id] 

  enable_deletion_protection = false

  tags = {
    Name = "main-alb"
  }
}

# Target Group
resource "aws_lb_target_group" "tg" {
  name     = "main-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.myVpc.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "main-tg"
  }
}

# ALB Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# Target Group Attachment
resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.web.id
  port             = 80
}

output "vpc_id" {
  value = aws_vpc.myVpc.id
}

output "subnet_ids" {
  value = concat(aws_subnet.public_subnet[*].id, aws_subnet.private_subnet[*].id)
}

output "instance_id" {
  value = aws_instance.web.id
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}
