# Self-signed server cert for HAProxy TLS termination on the mux port.
# Bootstrap/fallback so HAProxy always has a pem if Let's Encrypt has not issued yet.
# When domain_name is set, lego on the instance prefers a public-CA pem over this one.
# Public cert is an output (empty-domain path); private key is SSM only.

resource "tls_private_key" "gateway" {
  count = local.gateway_enabled ? 1 : 0

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "gateway" {
  count = local.gateway_enabled ? 1 : 0

  private_key_pem = tls_private_key.gateway[0].private_key_pem

  subject {
    common_name  = aws_eip.this.public_ip
    organization = var.name
  }

  validity_period_hours = 43800
  set_subject_key_id    = true
  # Bun/OpenCode NODE_EXTRA_CA_CERTS ignores a self-signed leaf with CA:FALSE.
  is_ca_certificate = true

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "cert_signing",
  ]

  dns_names    = ["localhost"]
  ip_addresses = [aws_eip.this.public_ip, "127.0.0.1"]
}

resource "aws_ssm_parameter" "haproxy_pem" {
  count = local.gateway_enabled ? 1 : 0

  name        = "/${var.name}/gateway/tls_pem"
  description = "HAProxy TLS server certificate + private key PEM (self-signed bootstrap/fallback; Let's Encrypt is issued on the instance)"
  type        = "SecureString"
  value       = "${tls_self_signed_cert.gateway[0].cert_pem}${tls_private_key.gateway[0].private_key_pem}"

  tags = {
    Name = "${var.name}-haproxy-pem"
  }
}
