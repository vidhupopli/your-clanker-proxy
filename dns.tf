# Public Route53 A record for Let's Encrypt HTTPS. Created only when domain_name is set.
# DNS-01 does not need this A record; clients do. No ALIAS.

data "aws_route53_zone" "this" {
  count = local.acme_enabled ? 1 : 0

  name         = local.domain_name
  private_zone = false
}

resource "aws_route53_record" "gateway" {
  count = local.acme_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = local.domain_name
  type    = "A"
  ttl     = 60
  records = [aws_eip.this.public_ip]
}
