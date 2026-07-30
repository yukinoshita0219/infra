provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        TerraformKey = "security/aws-oidc-federation"
        SystemName   = var.system_name
        Environment  = var.env
        ManagedBy    = "Terraform"
      },
      var.default_tags
    )
  }
}

# AWS allows only one OIDC provider per URL per account; when one already
# exists, set create_oidc_provider = false to reference it instead.
resource "aws_iam_openid_connect_provider" "this" {
  count = var.create_oidc_provider ? 1 : 0

  # Variable is scheme-less for the condition prefixes; the OIDC provider URL
  # itself must carry https:// (AWS rejects it otherwise).
  url = "https://${var.oidc_provider_url}"
  client_id_list = distinct(concat(
    var.audiences,
    flatten([for v in var.roles : coalesce(v.audience, var.audiences)])
  ))

  # null means unset: AWS provider (~> 5.x) auto-retrieves the thumbprint for
  # well-known IdPs, so it is only supplied when explicitly overridden.
  thumbprint_list = var.thumbprint_list
}

data "aws_iam_openid_connect_provider" "this" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://${var.oidc_provider_url}"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.this[0].arn : data.aws_iam_openid_connect_provider.this[0].arn
}

data "aws_iam_policy_document" "federated_trust" {
  for_each = var.roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # Pinning aud is mandatory: without it, a token minted for any other
    # audience could assume this role (confused deputy).
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = coalesce(each.value.audience, var.audiences)
    }

    dynamic "condition" {
      for_each = each.value.subject_conditions

      content {
        test     = condition.value.test
        variable = "${var.oidc_provider_url}:sub"
        values   = condition.value.values
      }
    }

    dynamic "condition" {
      for_each = each.value.additional_conditions

      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }
}

resource "aws_iam_role" "federated" {
  for_each = { for k, v in var.roles : k => v if v.create_role }

  name                 = "${var.system_name}-${var.env}-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.federated_trust[each.key].json
  max_session_duration = each.value.max_session_duration
}

# The assume role policy of a pre-existing role cannot be managed separately
# from the role itself; the role owner must apply the trust policy JSON from
# the required_trust_policies output.
data "aws_iam_role" "existing" {
  for_each = { for k, v in var.roles : k => v if !v.create_role }

  name = each.value.existing_role_name
}

locals {
  role_names = {
    for k, v in var.roles :
    k => v.create_role ? aws_iam_role.federated[k].name : data.aws_iam_role.existing[k].name
  }
  role_arns = {
    for k, v in var.roles :
    k => v.create_role ? aws_iam_role.federated[k].arn : data.aws_iam_role.existing[k].arn
  }

  managed_policies = merge({}, [
    for k, v in var.roles : {
      for arn in v.managed_policy_arns : "${k}/${arn}" => {
        role_key   = k
        policy_arn = arn
      }
    }
  ]...)
}

resource "aws_iam_role_policy_attachment" "federated" {
  for_each = local.managed_policies

  role       = local.role_names[each.value.role_key]
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "federated" {
  for_each = { for k, v in var.roles : k => v if v.inline_policy != null }

  name   = "${var.system_name}-${var.env}-${each.key}"
  role   = local.role_names[each.key]
  policy = jsonencode(each.value.inline_policy)
}
