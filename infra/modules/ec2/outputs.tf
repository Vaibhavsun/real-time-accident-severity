output "instance_id" {
  value       = aws_instance.this.id
  description = "EC2 instance ID"
}

output "public_ip" {
  value       = aws_instance.this.public_ip
  description = "EC2 public IP (if assigned)"
}

output "private_ip" {
  value       = aws_instance.this.private_ip
  description = "EC2 private IP"
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "Security group attached to the instance"
}

output "iam_role_arn" {
  value       = aws_iam_role.this.arn
  description = "IAM role ARN attached to the instance"
}

output "key_name" {
  value       = aws_key_pair.this.key_name
  description = "EC2 key pair name (so other modules like EMR can reuse it)"
}

output "private_key_path" {
  value       = local_sensitive_file.private_key.filename
  description = "Local filesystem path to the generated SSH private key (chmod 0600)"
}
