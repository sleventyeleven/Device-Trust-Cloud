# mTLS Test Gateway Module (AWS)
# A simple nginx reverse proxy requiring TLS client certificate
# authentication (mTLS/ClientAuth), matching the pattern described at
# https://hackersvanguard.com/creating-a-simple-device-trust-gateway-using-device-certificates/
# and the GCP implementation of this same module - used to verify enrolled
# device certificates actually work for ClientAuth, not just that they were
# issued.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_eip" "mtls_gateway" {
  domain = "vpc"
  tags = {
    Name = var.mtls_gateway_name
  }
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name = var.mtls_gateway_name
  }

  ip_addresses = [aws_eip.mtls_gateway.public_ip]
}

resource "aws_acmpca_certificate" "server" {
  certificate_authority_arn   = var.intermediate_ca_arn
  certificate_signing_request = tls_cert_request.server.cert_request_pem
  signing_algorithm           = var.signing_algorithm

  validity {
    type  = "DAYS"
    value = var.cert_validity_days
  }
}

locals {
  ca_bundle   = "${var.intermediate_ca_certificate_pem}\n${var.root_ca_certificate_pem}"
  server_cert = aws_acmpca_certificate.server.certificate

  nginx_conf = <<-NGINXCONF
    log_format devicelog '$remote_addr - $remote_user [$time_local] '
                         '"$request" $status $body_bytes_sent '
                         'client_cert="$ssl_client_verify" '
                         'cn="$ssl_client_s_dn"';
    access_log /var/log/nginx/device_access.log devicelog;

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;
        ssl_client_certificate /etc/nginx/certs/ca-bundle.crt;
        ssl_verify_client on;

        location / {
            default_type text/plain;
            return 200 "mTLS authentication successful.\nVerify: $ssl_client_verify\nClient DN: $ssl_client_s_dn\n";
        }
    }
  NGINXCONF
}

resource "aws_secretsmanager_secret" "server_key" {
  name                    = "${var.mtls_gateway_name}-server-key"
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "server_key" {
  secret_id     = aws_secretsmanager_secret.server_key.id
  secret_string = tls_private_key.server.private_key_pem
}

resource "aws_iam_role" "mtls_gateway" {
  name = "${var.mtls_gateway_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

# SSM Session Manager for operator access, not a public SSH port - the same
# "no external SSH surface" posture as the GCP module's IAP-tunneled SSH.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.mtls_gateway.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_server_key_secret" {
  name = "${var.mtls_gateway_name}-read-server-key"
  role = aws_iam_role.mtls_gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.server_key.arn
    }]
  })
}

resource "aws_iam_instance_profile" "mtls_gateway" {
  name = "${var.mtls_gateway_name}-profile"
  role = aws_iam_role.mtls_gateway.name
}

resource "aws_security_group" "mtls_gateway" {
  name        = "${var.mtls_gateway_name}-sg"
  description = "Public HTTPS test target - no SSH, operator access is via SSM"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS (mTLS test endpoint)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_instance" "mtls_gateway" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.mtls_gateway.id]
  iam_instance_profile   = aws_iam_instance_profile.mtls_gateway.name

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    ca_bundle            = local.ca_bundle
    server_cert          = local.server_cert
    nginx_conf           = local.nginx_conf
    server_key_secret_id = aws_secretsmanager_secret.server_key.id
    region               = var.region
  })

  tags = merge(var.tags, {
    Name = var.mtls_gateway_name
  })

  depends_on = [
    aws_iam_role_policy.read_server_key_secret,
    aws_secretsmanager_secret_version.server_key,
  ]
}

resource "aws_eip_association" "mtls_gateway" {
  instance_id   = aws_instance.mtls_gateway.id
  allocation_id = aws_eip.mtls_gateway.id
}
