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

resource "aws_iam_role" "exit_node" {
  name               = "${local.hostname}-role"
  description        = "Least-privilege runtime role for ${local.hostname}."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${local.hostname}-role"
    Role = "exit-node"
  }
}

resource "aws_iam_instance_profile" "exit_node" {
  name = "${local.hostname}-profile"
  role = aws_iam_role.exit_node.name

  tags = {
    Name = "${local.hostname}-profile"
    Role = "exit-node"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.exit_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "setup_key" {
  statement {
    sid    = "ReadOnlyOwnSetupKey"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_secretsmanager_secret.setup_key.arn]
  }

  dynamic "statement" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]

    content {
      sid       = "DecryptSetupKey"
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

resource "aws_iam_role_policy" "setup_key" {
  name   = "read-own-setup-key"
  role   = aws_iam_role.exit_node.id
  policy = data.aws_iam_policy_document.setup_key.json
}
