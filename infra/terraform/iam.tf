data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  for_each = local.nodes

  name               = "${local.nodes[each.key].hostname}-role"
  description        = "Least-privilege runtime role for ${local.nodes[each.key].hostname}."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${local.nodes[each.key].hostname}-role"
    Role = each.value.role
  }
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.nodes

  name = "${local.nodes[each.key].hostname}-profile"
  role = aws_iam_role.node[each.key].name

  tags = {
    Name = "${local.nodes[each.key].hostname}-profile"
    Role = each.value.role
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = local.nodes

  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runtime_secret" {
  for_each = local.nodes

  statement {
    sid    = "ReadOnlyOwnRuntimeSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_secretsmanager_secret.runtime[each.key].arn]
  }

  dynamic "statement" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]

    content {
      sid       = "DecryptRuntimeSecret"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "runtime_secret" {
  for_each = local.nodes

  name   = "read-own-runtime-secret"
  role   = aws_iam_role.node[each.key].id
  policy = data.aws_iam_policy_document.runtime_secret[each.key].json
}
