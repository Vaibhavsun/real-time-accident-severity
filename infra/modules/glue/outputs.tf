output "job_names" {
  value       = [for j in aws_glue_job.streaming : j.name]
  description = "Names of all Glue streaming jobs"
}

output "ml_train_job_name" {
  value       = local.ml_enabled ? aws_glue_job.ml_train[0].name : null
  description = "Name of the Glue Python Shell job for ML retraining"
}

output "ml_train_trigger_name" {
  value       = local.ml_enabled ? aws_glue_trigger.ml_train_schedule[0].name : null
  description = "Name of the Glue trigger that fires the ML training job"
}

output "iam_role_arn" {
  value       = aws_iam_role.glue.arn
  description = "Glue job role ARN"
}

output "eh_secret_id" {
  value       = aws_secretsmanager_secret.eh.id
  description = "Secrets Manager id holding the Event Hubs connection string"
}

output "rds_connection_name" {
  value       = aws_glue_connection.rds.name
  description = "Glue VPC connection name (NETWORK type) for RDS access"
}
