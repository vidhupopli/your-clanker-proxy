output "eip_public_ip" {
  description = "Elastic IP clients should use as the HTTP CONNECT host (and HTTP/HTTPS gateway base host when enabled)."
  value       = aws_eip.this.public_ip
}

output "instance_id" {
  description = "EC2 instance ID (SSM Session Manager target)."
  value       = aws_instance.this.id
}

output "region" {
  description = "AWS region of this stack."
  value       = var.region
}

output "http_proxy_url" {
  description = "HTTP CONNECT URL: http://USER:PASS@EIP:443. Marked sensitive because it contains the password."
  value       = "http://${var.proxy_user}:${urlencode(random_password.proxy.result)}@${aws_eip.this.public_ip}:${var.proxy_port}"
  sensitive   = true
}

output "https_proxy_export_snippet" {
  description = "macOS zsh snippet. HTTPS_PROXY still uses the http:// scheme (CONNECT, then origin TLS)."
  sensitive   = true
  value       = <<-EOT
    export HTTP_PROXY='http://${var.proxy_user}:${random_password.proxy.result}@${aws_eip.this.public_ip}:${var.proxy_port}'
    export HTTPS_PROXY="$HTTP_PROXY"
    export NO_PROXY='${local.no_proxy_hosts}'
    export NODE_USE_ENV_PROXY=1
  EOT
}

output "ssm_start_session_command" {
  description = "SSM Session Manager shell on the instance (no SSH key)."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${var.region}"
}

output "gateway_enabled" {
  description = "True when the HTTP reverse gateway is muxed on TCP 443 (at least one vendor key set)."
  value       = local.gateway_enabled
}

output "gateway_xai_enabled" {
  description = "True when /xai/ is served."
  value       = local.gateway_xai_enabled
}

output "gateway_openrouter_enabled" {
  description = "True when /openrouter/ is served."
  value       = local.gateway_openrouter_enabled
}

output "gateway_xai_base_url" {
  description = "Grok/OpenAI-style base_url when xAI gateway is on: http://EIP:443/xai/v1 (cleartext HTTP on the mux port, not :80)"
  value       = local.gateway_xai_enabled ? "http://${aws_eip.this.public_ip}:${var.proxy_port}/xai/v1" : null
}

output "gateway_openrouter_base_url" {
  description = "OpenCode/OpenAI-style baseURL when OpenRouter gateway is on: http://EIP:443/openrouter/api/v1 (cleartext HTTP on the mux port, not :80)"
  value       = local.gateway_openrouter_enabled ? "http://${aws_eip.this.public_ip}:${var.proxy_port}/openrouter/api/v1" : null
}

output "gateway_xai_base_url_https" {
  description = "HTTPS Grok/OpenAI-style base_url. With domain_name: https://DOMAIN/xai/v1 (Let's Encrypt public CA; no custom CA file). Else https://EIP:443/xai/v1 (self-signed; trust gateway_tls_cert_pem)."
  value       = local.gateway_xai_enabled ? "https://${local.https_gateway_host}/xai/v1" : null
}

output "gateway_openrouter_base_url_https" {
  description = "HTTPS OpenCode/OpenAI-style baseURL. With domain_name: https://DOMAIN/openrouter/api/v1 (Let's Encrypt public CA; no custom CA file). Else https://EIP:443/openrouter/api/v1 (self-signed; trust gateway_tls_cert_pem)."
  value       = local.gateway_openrouter_enabled ? "https://${local.https_gateway_host}/openrouter/api/v1" : null
}

output "gateway_tls_cert_pem" {
  description = "Self-signed public server certificate (PEM) for the empty-domain path. Trust with curl --cacert / NODE_EXTRA_CA_CERTS / SSL_CERT_FILE. When domain_name is set, HAProxy serves a Let's Encrypt public CA cert instead — no custom CA file needed. Not the private key."
  value       = local.gateway_enabled ? tls_self_signed_cert.gateway[0].cert_pem : null
}

output "gateway_tls_ca_pem" {
  description = "Same bytes as gateway_tls_cert_pem. Use as a CA file for clients; this is a self-signed server cert, not a real CA, and not the private key."
  value       = local.gateway_enabled ? tls_self_signed_cert.gateway[0].cert_pem : null
}

output "gateway_token" {
  description = "Bearer token clients send to the HTTP gateway. Not the CONNECT password."
  sensitive   = true
  value       = try(random_password.gateway_token[0].result, null)
}

output "ssh_enabled" {
  description = "True when password SSH (local forwarding to 443) is enabled."
  value       = var.ssh_enabled
}

output "ssh_tunnel_command" {
  description = "ssh -N -f local-forward of mux 443 onto loopback. Password prompt; same password as CONNECT. Null when ssh_enabled is false."
  value       = var.ssh_enabled ? "ssh -N -f -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -L 1443:127.0.0.1:443 ${var.proxy_user}@${aws_eip.this.public_ip}" : null
}

output "domain_name" {
  description = "Public DNS name used for Let's Encrypt HTTPS, or empty when using self-signed TLS on the EIP."
  value       = local.acme_enabled ? local.domain_name : ""
}
