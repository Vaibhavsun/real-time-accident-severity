output "ssh_key_name" {
  value       = module.ec2.key_name
  description = "EC2 key pair name registered in AWS (Terraform-generated)"
}

output "ssh_private_key_path" {
  value       = module.ec2.private_key_path
  description = "Local path to the Terraform-generated SSH private key (chmod 0600). Use: ssh -i <path> ec2-user@<ec2_public_ip>"
}

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "VPC ID"
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnet_ids
  description = "Public subnet IDs"
}

output "s3_bucket" {
  value       = module.s3.bucket_id
  description = "Data lake bucket name"
}

output "ec2_public_ip" {
  value       = module.ec2.public_ip
  description = "Producer EC2 public IP"
}

output "kafka_ui_url" {
  value       = "http://${module.ec2.public_ip}:8080"
  description = "Provectus Kafka UI on the producer EC2 (allow ~3-5 minutes after apply for Docker to start)"
}

output "ssh_command" {
  value       = "ssh -i ${module.ec2.private_key_path} ec2-user@${module.ec2.public_ip}"
  description = "Ready-to-paste SSH command"
}

output "eventhub_bootstrap_server" {
  value       = module.eventhubs.bootstrap_server
  description = "Azure Event Hubs Kafka bootstrap endpoint (SASL_SSL on :9093). Use as KAFKA_BROKERS in the producer."
}

output "eventhub_namespace" {
  value       = module.eventhubs.namespace_name
  description = "Event Hubs namespace name"
}

output "eventhub_topics" {
  value       = module.eventhubs.topics
  description = "Kafka topics (event hubs) created"
}

output "eventhub_connection_string" {
  value       = module.eventhubs.connection_string
  description = "SASL/PLAIN password for the producer. Username is the literal string '$ConnectionString'. Read via: terraform output -raw eventhub_connection_string"
  sensitive   = true
}

# ----- RDS Postgres -----
output "rds_endpoint" {
  value       = module.rds.endpoint
  description = "Postgres host (no port). Connect from inside the VPC."
}

output "rds_port" {
  value       = module.rds.port
  description = "Postgres port"
}

output "rds_db_name" {
  value       = module.rds.db_name
  description = "Initial database name"
}

output "rds_secret_id" {
  value       = module.rds.secret_id
  description = "Secrets Manager id holding {host,port,db,user,password}"
}

# ----- Glue -----
output "glue_job_names" {
  value       = module.glue.job_names
  description = "All Glue streaming job names"
}


