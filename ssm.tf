resource "random_password" "proxy" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "proxy_password" {
  name        = "/${var.name}/proxy/password"
  description = "HTTP CONNECT password for ${var.name} (not stored in AMI or git)"
  type        = "SecureString"
  value       = random_password.proxy.result

  tags = {
    Name = "${var.name}-proxy-password"
  }
}

resource "random_password" "gateway_token" {
  count   = local.gateway_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "gateway_token" {
  count       = local.gateway_enabled ? 1 : 0
  name        = "/${var.name}/gateway/token"
  description = "HTTP gateway Bearer token for ${var.name} (not the CONNECT password)"
  type        = "SecureString"
  value       = random_password.gateway_token[0].result

  tags = {
    Name = "${var.name}-gateway-token"
  }
}

resource "aws_ssm_parameter" "xai_api_key" {
  count       = local.gateway_xai_enabled ? 1 : 0
  name        = "/${var.name}/gateway/xai_api_key"
  description = "xAI API key injected by the gateway (server-side)"
  type        = "SecureString"
  value       = var.xai_api_key

  tags = {
    Name = "${var.name}-xai-api-key"
  }
}

resource "aws_ssm_parameter" "openrouter_api_key" {
  count       = local.gateway_openrouter_enabled ? 1 : 0
  name        = "/${var.name}/gateway/openrouter_api_key"
  description = "OpenRouter API key injected by the gateway (server-side)"
  type        = "SecureString"
  value       = var.openrouter_api_key

  tags = {
    Name = "${var.name}-openrouter-api-key"
  }
}

# Persist password SSH without touching user_data (user_data_replace_on_change
# would rebuild the nano). Association re-runs when the document version, instance
# id, or parameters change — including after an instance replace.
resource "aws_ssm_document" "ssh_password" {
  count = var.ssh_enabled ? 1 : 0

  name            = "${var.name}-ssh-password"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Enable password SSH for the CONNECT proxy user without replacing EC2 user-data."
    parameters = {
      proxyUser = {
        type        = "String"
        description = "Linux user for SSH (same as CONNECT username)."
      }
      ssmPasswordParameter = {
        type        = "String"
        description = "SSM SecureString name holding the CONNECT/SSH password."
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "configurePasswordSsh"
        inputs = {
          timeoutSeconds = 180
          runCommand = [
            file("${path.module}/config/configure-ssh.sh"),
          ]
        }
      },
    ]
  })
}

resource "aws_ssm_association" "ssh_password" {
  count = var.ssh_enabled ? 1 : 0

  name             = aws_ssm_document.ssh_password[0].name
  association_name = "${var.name}-ssh-password"
  document_version = aws_ssm_document.ssh_password[0].latest_version

  parameters = {
    proxyUser            = var.proxy_user
    ssmPasswordParameter = aws_ssm_parameter.proxy_password.name
  }

  targets {
    key    = "InstanceIds"
    values = [aws_instance.this.id]
  }

  wait_for_success_timeout_seconds = 180

  depends_on = [
    aws_instance.this,
    aws_iam_role_policy_attachment.ssm_core,
    aws_ssm_parameter.proxy_password,
  ]
}

# Persist HAProxy TLS cert + mux cfg without touching user_data (would rebuild
# the nano). Association re-runs when the document version, instance id, or
# configRev (cert/cfg/secret fingerprint) change.
resource "aws_ssm_document" "gateway_tls" {
  count = local.gateway_enabled ? 1 : 0

  name            = "${var.name}-gateway-tls"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Push HAProxy TLS cert, mux config, and compose volume mount without replacing EC2 user-data."
    parameters = {
      configRev = {
        type        = "String"
        description = "Fingerprint of cert, haproxy cfg, compose, and gateway secrets (triggers re-run)."
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "configureGatewayTls"
        inputs = {
          # First lego DNS-01 (install + Route53 TXT + LE issue) can take a few minutes.
          timeoutSeconds = 420
          runCommand = [
            templatefile("${path.module}/config/configure-tls.sh.tftpl", {
              ssm_pem_parameter  = aws_ssm_parameter.haproxy_pem[0].name
              ssm_gateway_token  = aws_ssm_parameter.gateway_token[0].name
              ssm_xai_api_key    = try(aws_ssm_parameter.xai_api_key[0].name, "")
              ssm_openrouter_key = try(aws_ssm_parameter.openrouter_api_key[0].name, "")
              compose_b64        = base64encode(local.compose_yml)
              haproxy_b64        = base64encode(local.haproxy_cfg)
              domain_name        = local.domain_name
              acme_email         = var.acme_email
              hosted_zone_id     = local.acme_enabled ? data.aws_route53_zone.this[0].zone_id : ""
              lego_renew_b64 = base64encode(templatefile("${path.module}/config/lego-renew.sh.tftpl", {
                domain_name    = local.domain_name
                acme_email     = var.acme_email
                hosted_zone_id = local.acme_enabled ? data.aws_route53_zone.this[0].zone_id : ""
              }))
            }),
          ]
        }
      },
    ]
  })
}

resource "aws_ssm_association" "gateway_tls" {
  count = local.gateway_enabled ? 1 : 0

  name             = aws_ssm_document.gateway_tls[0].name
  association_name = "${var.name}-gateway-tls"
  document_version = aws_ssm_document.gateway_tls[0].latest_version

  parameters = {
    configRev = local.tls_config_rev
  }

  targets {
    key    = "InstanceIds"
    values = [aws_instance.this.id]
  }

  # Match runCommand timeoutSeconds so first lego DNS-01 can finish.
  wait_for_success_timeout_seconds = 420

  depends_on = [
    aws_instance.this,
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy.route53_acme,
    aws_route53_record.gateway,
    aws_ssm_parameter.haproxy_pem,
    aws_ssm_parameter.gateway_token,
    aws_ssm_parameter.xai_api_key,
    aws_ssm_parameter.openrouter_api_key,
  ]
}

