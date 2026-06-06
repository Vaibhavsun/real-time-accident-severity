output "endpoint" {
  value       = aws_db_instance.this.address
  description = "RDS Postgres endpoint hostname (no port)"
}

output "port" {
  value       = aws_db_instance.this.port
  description = "Postgres port"
}

output "db_name" {
  value       = aws_db_instance.this.db_name
  description = "Initial database name"
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "RDS security group id (for cross-SG ingress rules from Glue)"
}

output "secret_arn" {
  value       = aws_secretsmanager_secret.pg.arn
  description = "Secrets Manager ARN holding {host,port,db,user,password}"
}

output "secret_id" {
  value       = aws_secretsmanager_secret.pg.id
  description = "Secrets Manager id (name) for Glue job arg --PG_SECRET_ID"
}
