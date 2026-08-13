output "instance_id" {
  description = "EC2 instance ID of the exit node."
  value       = aws_instance.exit_node.id
}

output "private_ipv4_address" {
  description = "Private IPv4 address inside the VPC."
  value       = aws_instance.exit_node.private_ip
}

output "public_ipv4_address" {
  description = "Current public egress address (EIP when create_eip is true)."
  value       = var.create_eip ? aws_eip.exit_node[0].public_ip : aws_instance.exit_node.public_ip
}

output "setup_key_secret_arn" {
  description = "Secrets Manager secret that must hold the raw NetBird setup key."
  value       = aws_secretsmanager_secret.setup_key.arn
}

output "populate_setup_key_command" {
  description = "Command skeleton for populating the setup key outside Terraform."
  value       = "aws secretsmanager put-secret-value --secret-id '${aws_secretsmanager_secret.setup_key.arn}' --secret-string '<RAW-NETBIRD-SETUP-KEY>' --region ${var.aws_region}"
}

output "session_manager_command" {
  description = "Command to open an administrative shell without SSH."
  value       = "aws ssm start-session --target ${aws_instance.exit_node.id} --region ${var.aws_region}"
}
