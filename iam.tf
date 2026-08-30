data "aws_iam_policy_document" "ec2_assume" {
  statement {
    sid     = "EC2AssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${var.name}-instance"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-instance"
  role = aws_iam_role.this.name

  tags = {
    Name = "${var.name}-instance"
  }
}

# Let's Encrypt DNS-01 (lego on the instance). Only when domain_name is set.
# ListHostedZonesByName is what lego calls if AWS_HOSTED_ZONE_ID is unset;
# ListHostedZones is included as specified. Zone writes are scoped to this zone.
data "aws_iam_policy_document" "route53_acme" {
  count = local.acme_enabled ? 1 : 0

  statement {
    sid = "ChangeZoneRecords"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]
    resources = [data.aws_route53_zone.this[0].arn]
  }

  statement {
    sid       = "GetChange"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid       = "ListHostedZones"
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "route53_acme" {
  count = local.acme_enabled ? 1 : 0

  name   = "${var.name}-route53-acme"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.route53_acme[0].json
}
