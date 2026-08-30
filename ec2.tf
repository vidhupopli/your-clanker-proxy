data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "this" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  iam_instance_profile = aws_iam_instance_profile.this.name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region             = var.region
    secrets_rev        = local.secrets_rev
    gateway_enabled    = local.gateway_enabled
    ssm_parameter_name = aws_ssm_parameter.proxy_password.name
    ssm_gateway_token  = try(aws_ssm_parameter.gateway_token[0].name, "")
    ssm_xai_api_key    = try(aws_ssm_parameter.xai_api_key[0].name, "")
    ssm_openrouter_key = try(aws_ssm_parameter.openrouter_api_key[0].name, "")
    ssm_haproxy_pem    = try(aws_ssm_parameter.haproxy_pem[0].name, "")
    compose_b64        = base64encode(local.compose_yml)
    cfg_b64 = base64encode(templatefile("${path.module}/config/3proxy.cfg.tftpl", {
      proxy_user          = var.proxy_user
      connect_listen_port = local.connect_listen_port
      allow_rules         = local.proxy_allow_rules
    }))
    haproxy_b64 = local.gateway_enabled ? base64encode(local.haproxy_cfg) : ""
  })
  user_data_replace_on_change = true

  network_interface {
    device_index          = 0
    network_interface_id  = aws_network_interface.this.id
    delete_on_termination = false
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.name}-root"
    }
  }

  credit_specification {
    cpu_credits = "standard"
  }

  monitoring = false

  tags = {
    Name = var.name
  }

  depends_on = [
    aws_eip_association.this,
    aws_iam_role_policy_attachment.ssm_core,
    aws_ssm_parameter.proxy_password,
    aws_ssm_parameter.gateway_token,
    aws_ssm_parameter.xai_api_key,
    aws_ssm_parameter.openrouter_api_key,
    aws_ssm_parameter.haproxy_pem,
  ]

  timeouts {
    create = "8m"
  }

  # Ignore user_data so template drift (e.g. haproxy.cfg.tftpl) cannot
  # accidentally replace the nano. user_data_replace_on_change remains true
  # for intentional recreates via taint/replace.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

check "dest_whitelist_or_escape" {
  assert {
    condition     = var.proxy_allow_all_dests || length(var.proxy_allow_dests) > 0
    error_message = "Set proxy_allow_dests to at least one host pattern, or set proxy_allow_all_dests = true."
  }
}
