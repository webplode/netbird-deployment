data "aws_iam_policy_document" "dlm_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name_prefix        = "${var.name_prefix}-${var.environment}-dlm-"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role.json

  tags = {
    Role = "snapshot-lifecycle"
  }
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# Daily crash-consistent snapshots of the management data volume only; the
# root volumes are reproducible from the SSM bootstrap and carry no state.
resource "aws_dlm_lifecycle_policy" "management_data" {
  description        = "${var.name_prefix}-${var.environment} management data volume daily snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Role = "management-data"
    }

    schedule {
      name      = "daily-0200-ict"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["19:00"] # UTC = 02:00 Asia/Ho_Chi_Minh
      }

      retain_rule {
        count = 14
      }

      tags_to_add = {
        SnapshotCreator = "dlm"
      }
    }
  }

  tags = {
    Role = "snapshot-lifecycle"
  }
}
