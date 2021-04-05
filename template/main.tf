module "main" {
  source = "../module"

  aws_region       = var.aws_region
  admins           = var.admins
  domain           = var.domain
  keybase_username = var.keybase_username
  instance_type    = var.instance_type
  sns_email        = var.sns_email
  world_name       = var.world_name
  server_name      = var.server_name
  server_password  = var.server_password
  purpose          = var.purpose
  unique_id        = var.unique_id
}