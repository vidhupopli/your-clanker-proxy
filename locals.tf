locals {
  # Prefer not the first lexical AZ: ap-south-1a is often capacity-constrained.
  instance_type_azs = sort(data.aws_ec2_instance_type_offerings.this.locations)
  availability_zone = var.availability_zone != "" ? var.availability_zone : (
    length(local.instance_type_azs) > 1 ? local.instance_type_azs[1] : local.instance_type_azs[0]
  )

  ingress_cidrs = length(var.allowed_cidrs) > 0 ? var.allowed_cidrs : ["0.0.0.0/0"]

  # Comparisons only — nonsensitive so status/outputs can show on/off without leaking keys.
  gateway_xai_enabled        = nonsensitive(var.xai_api_key != "")
  gateway_openrouter_enabled = nonsensitive(var.openrouter_api_key != "")
  gateway_enabled            = local.gateway_xai_enabled || local.gateway_openrouter_enabled

  # Public mux/CONNECT port stays var.proxy_port (443). When the gateway is on, 3proxy
  # listens only on the compose network at 3128 — never on host 443.
  connect_listen_port = local.gateway_enabled ? 3128 : var.proxy_port

  # 3proxy ACL command HTTPS = HTTP CONNECT. Destination port is origin TLS (443), not the listen port.
  proxy_allow_rules = var.proxy_allow_all_dests ? (
    "allow ${var.proxy_user} * * 443 HTTPS"
    ) : join("\n", [
      for dest in var.proxy_allow_dests :
      "allow ${var.proxy_user} * ${dest} 443 HTTPS"
  ])

  domain_name  = trimsuffix(var.domain_name, ".")
  acme_enabled = local.domain_name != ""

  # HTTPS host in client URLs. Public CA on domain: omit :443 when listen port is 443.
  https_gateway_host = local.acme_enabled ? (
    var.proxy_port == 443 ? local.domain_name : format("%s:%d", local.domain_name, var.proxy_port)
  ) : format("%s:%d", aws_eip.this.public_ip, var.proxy_port)

  no_proxy_hosts = join(",", compact(concat(
    ["localhost", "127.0.0.1", "::1"],
    local.gateway_enabled ? [aws_eip.this.public_ip] : [],
    local.acme_enabled ? [local.domain_name] : [],
  )))

  # Fingerprint only (not the secrets) so user-data_replace_on_change fires on key rotation
  # without baking keys into the EC2 user-data attribute.
  secrets_rev = sha256(join("\n", [
    var.xai_api_key,
    var.openrouter_api_key,
    try(random_password.gateway_token[0].result, ""),
    random_password.proxy.result,
  ]))

  haproxy_cfg = templatefile("${path.module}/config/haproxy.cfg.tftpl", {
    proxy_port                 = var.proxy_port
    gateway_xai_enabled        = local.gateway_xai_enabled
    gateway_openrouter_enabled = local.gateway_openrouter_enabled
  })

  compose_yml = templatefile("${path.module}/docker-compose.yml", {
    proxy_port      = var.proxy_port
    gateway_enabled = local.gateway_enabled
  })

  # Association parameter only (sha256). Changing cert, mux cfg, compose, or gateway
  # secrets re-runs configure-tls without replacing the instance.
  tls_config_rev = local.gateway_enabled ? sha256(join("\n", [
    tls_self_signed_cert.gateway[0].cert_pem,
    local.haproxy_cfg,
    local.compose_yml,
    try(random_password.gateway_token[0].result, ""),
    var.xai_api_key,
    var.openrouter_api_key,
    local.domain_name,
    var.acme_email,
  ])) : ""

  common_tags = {
    Name = var.name
  }
}
