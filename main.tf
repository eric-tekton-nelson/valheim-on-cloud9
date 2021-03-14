locals {
  tags = {
    "Purpose"   = "Valheim Server"
    "CreatedBy" = "Terraform"
  }
}

resource "aws_security_group" "ingress" {
  tags = merge(local.tags,
    {
      "Name"        = "Valheim Ingress"
      "Description" = "Security group allowing inbound traffic to the Valheim server"
    }
  )
}

resource "aws_security_group_rule" "valheim_ingress" {
  type      = "ingress"
  from_port = 2456
  to_port   = 2458
  protocol  = "udp"
  cidr_blocks = [
    "0.0.0.0/0"
  ]
  security_group_id = aws_security_group.ingress.id
  description       = "Allows traffic to the Valheim server"
}

resource "aws_security_group_rule" "netdata" {
  type      = "ingress"
  from_port = 19999
  to_port   = 19999
  protocol  = "tcp"
  cidr_blocks = [
    "0.0.0.0/0"
  ]
  security_group_id = aws_security_group.ingress.id
  description       = "Allows traffic to the Netdata dashboard"
}

resource "aws_security_group_rule" "egress" {
  type      = "egress"
  from_port = 0
  to_port   = 0
  protocol  = "-1"
  cidr_blocks = [
    "0.0.0.0/0"
  ]
  security_group_id = aws_security_group.ingress.id
  description       = "Allow all egress rule for the Valheim server"
}

resource "aws_iam_role" "valheim" {
  name = "valheim-server"
  assume_role_policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        Action : "sts:AssumeRole",
        Principal : {
          Service : "ec2.amazonaws.com"
        },
        Effect : "Allow",
        Sid : ""
      }
    ]
  })
}

resource "aws_iam_instance_profile" "valheim" {
  role = aws_iam_role.valheim.name
}

resource "aws_iam_policy" "s3" {
  name        = "valheim-s3"
  description = "Allows the Valheim server to backup world data to S3"
  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        Effect : "Allow",
        Action : [
          "s3:Put*",
          "s3:Get*",
          "s3:List*"
        ],
        Resource : [
          "arn:aws:s3:::wahlfeld-valheim",
          "arn:aws:s3:::wahlfeld-valheim/"
        ]
      }
    ]
  })
}

data "aws_iam_policy" "ssm" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy_attachment" "s3" {
  name       = "valheim-s3"
  roles      = [aws_iam_role.valheim.name]
  policy_arn = aws_iam_policy.s3.arn
}

resource "aws_iam_policy_attachment" "ssm" {
  name       = "valheim-ssm"
  roles      = [aws_iam_role.valheim.name]
  policy_arn = data.aws_iam_policy.ssm.arn
}

resource "aws_s3_bucket_policy" "valheim" {
  bucket = "wahlfeld-valheim"
  policy = jsonencode({
    Version : "2012-10-17",
    Id : "PolicyForValheimBackups",
    Statement : [
      {
        Effect : "Allow",
        Principal : {
          "AWS" : aws_iam_role.valheim.arn
        },
        Action : [
          "s3:Put*",
          "s3:Get*",
          "s3:List*"
        ],
        Resource : "arn:aws:s3:::wahlfeld-valheim/*"
      }
    ]
  })
}

resource "aws_s3_bucket_object" "admin_list" {
  bucket = "wahlfeld-valheim"
  key    = "/adminlist.txt"
  source = templatefile("./local/adminlist.txt", { admins = values(var.admins) })
  etag = filemd5("./local/adminlist.txt")
}

resource "aws_instance" "valheim" {
  # Free tier eligible: Ubuntu Server 20.04 LTS (HVM), SSD Volume Type
  ami                  = "ami-0d767dd04ac152743"
  instance_type        = "t3a.medium"
  user_data            = file("./local/userdata.sh")
  iam_instance_profile = aws_iam_instance_profile.valheim.name
  vpc_security_group_ids = [
    aws_security_group.ingress.id
  ]
  tags = merge(local.tags,
    {
      "Name"        = "Valheim Server"
      "Description" = "Instance running a Valheim server"
    }
  )
}

resource "aws_sns_topic" "valheim" {
  name = "stop_valheim_server"
}

resource "aws_sns_topic_subscription" "valheim" {
  topic_arn = aws_sns_topic.valheim.arn
  protocol  = "email"
  endpoint  = "cschwarzwahlfeld@gmail.com"
}

resource "aws_cloudwatch_metric_alarm" "valheim" {
  alarm_name          = "stop_valheim_server"
  alarm_description   = "Will stop the Valheim server after a period of inactivity"
  comparison_operator = "LessThanThreshold"
  datapoints_to_alarm = "1"
  evaluation_periods  = "1"
  metric_name         = "NetworkIn"
  period              = "600"
  statistic           = "Average"
  namespace           = "AWS/EC2"
  threshold           = "50000"
  alarm_actions = [
    aws_sns_topic.valheim.arn,
    "arn:aws:swf:ap-southeast-2:063286155141:action/actions/AWS_EC2.InstanceId.Stop/1.0",
  ]
  dimensions = {
    "InstanceId" = aws_instance.valheim.id
  }
  tags = merge(local.tags,
    {}
  )
}

resource "aws_iam_group" "valheim_users" {
  name = "valheim-users"
  path = "/users/"
}

resource "aws_iam_group_policy" "valheim_users" {
  name  = "valheim-users"
  group = aws_iam_group.valheim_users.name
  policy = jsonencode({
    Version = "2012-10-17"
    "Statement": [
        {
            Effect: "Allow",
            Action: [
                "ec2:StartInstances"
            ],
            Resource: aws_instance.valheim.arn,
        },
        {
            Effect: "Allow",
            Action: "ec2:DescribeInstances",
            Resource: "*"
        }
    ]
  })
}

resource "aws_iam_user" "valheim_user" {
  for_each = var.admins

  name          = each.key
  path          = "/"
  force_destroy = true
}

resource "aws_iam_user_login_profile" "valheim_user" {
  for_each = aws_iam_user.valheim_user

  user    = aws_iam_user.valheim_user[each.key].name
  pgp_key = "keybase:wahlfeld"
}

output "valheim_user_passwords" {
  value = { for i in aws_iam_user_login_profile.valheim_user : i.user => i.encrypted_password }
}

data "aws_route53_zone" "selected" {
  count = var.use_domain ? 1 : 0
  name  = "cwahlfeld.com."
}

resource "aws_route53_record" "valheim" {
  count   = var.use_domain ? 1 : 0
  zone_id = data.aws_route53_zone.selected[0].zone_id
  name    = "valheim"
  type    = "CNAME"
  ttl     = "300"
  records = [
    aws_instance.valheim.public_dns
  ]
}

output "monitoring_url" {
  value = format("%s%s%s", "http://", try(aws_route53_record.valheim[0].fqdn, aws_instance.valheim.public_dns), ":19999")
}