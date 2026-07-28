output "public_ip" {
  value = aws_eip.mtls_gateway.public_ip
}

output "url" {
  value = "https://${aws_eip.mtls_gateway.public_ip}/"
}

output "instance_id" {
  value = aws_instance.mtls_gateway.id
}
