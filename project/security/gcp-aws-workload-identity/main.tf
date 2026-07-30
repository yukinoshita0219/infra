provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        TerraformKey = "security/gcp-aws-workload-identity"
        SystemName   = var.system_name
        Environment  = var.env
        ManagedBy    = "Terraform"
      },
      var.default_tags
    )
  }
}

# No credentials in code: ADC (Application Default Credentials) is assumed
provider "google" {
  project = var.gcp_project_id
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  gcp_to_aws_enabled = length(var.gcp_to_aws_roles) > 0
  aws_to_gcp_enabled = length(var.aws_to_gcp_service_accounts) > 0

  aws_account_id = coalesce(var.aws_account_id, data.aws_caller_identity.current.account_id)
}

# ---------------------------------------------
# GCP -> AWS: Google OIDC 連携
# ---------------------------------------------
# AWS allows only one OIDC provider per URL per account; when one already
# exists, set create_google_oidc_provider = false to reference it instead.
resource "aws_iam_openid_connect_provider" "google" {
  count = local.gcp_to_aws_enabled && var.create_google_oidc_provider ? 1 : 0

  url = "https://accounts.google.com"
  client_id_list = distinct(concat(
    var.google_oidc_audiences,
    flatten([for v in var.gcp_to_aws_roles : coalesce(v.audiences, var.google_oidc_audiences)])
  ))
}

data "aws_iam_openid_connect_provider" "google" {
  count = local.gcp_to_aws_enabled && !var.create_google_oidc_provider ? 1 : 0

  url = "https://accounts.google.com"
}

locals {
  google_oidc_provider_arn = local.gcp_to_aws_enabled ? (
    var.create_google_oidc_provider ? aws_iam_openid_connect_provider.google[0].arn : data.aws_iam_openid_connect_provider.google[0].arn
  ) : null
}

data "aws_iam_policy_document" "gcp_federated_trust" {
  for_each = var.gcp_to_aws_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.google_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:sub"
      values   = each.value.gcp_service_account_unique_ids
    }

    # Pinning oaud is mandatory: without it, a Google token minted for any
    # other audience could assume this role (confused deputy).
    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:oaud"
      values   = coalesce(each.value.audiences, var.google_oidc_audiences)
    }
  }
}

resource "aws_iam_role" "gcp_federated" {
  for_each = { for k, v in var.gcp_to_aws_roles : k => v if v.create_role }

  name                 = "${var.system_name}-${var.env}-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.gcp_federated_trust[each.key].json
  max_session_duration = each.value.max_session_duration
}

# The assume role policy of a pre-existing role cannot be managed separately
# from the role itself; the role owner must apply the trust policy JSON from
# the gcp_to_aws_required_trust_policies output.
data "aws_iam_role" "existing" {
  for_each = { for k, v in var.gcp_to_aws_roles : k => v if !v.create_role }

  name = each.value.existing_role_name
}

locals {
  gcp_to_aws_role_names = {
    for k, v in var.gcp_to_aws_roles :
    k => v.create_role ? aws_iam_role.gcp_federated[k].name : data.aws_iam_role.existing[k].name
  }
  gcp_to_aws_role_arns = {
    for k, v in var.gcp_to_aws_roles :
    k => v.create_role ? aws_iam_role.gcp_federated[k].arn : data.aws_iam_role.existing[k].arn
  }

  gcp_to_aws_managed_policies = merge({}, [
    for k, v in var.gcp_to_aws_roles : {
      for arn in v.managed_policy_arns : "${k}/${arn}" => {
        role_key   = k
        policy_arn = arn
      }
    }
  ]...)
}

resource "aws_iam_role_policy_attachment" "gcp_federated" {
  for_each = local.gcp_to_aws_managed_policies

  role       = local.gcp_to_aws_role_names[each.value.role_key]
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "gcp_federated" {
  for_each = { for k, v in var.gcp_to_aws_roles : k => v if v.inline_policy != null }

  name   = "${var.system_name}-${var.env}-${each.key}"
  role   = local.gcp_to_aws_role_names[each.key]
  policy = jsonencode(each.value.inline_policy)
}

# ---------------------------------------------
# AWS -> GCP: Workload Identity 連携
# ---------------------------------------------
resource "google_iam_workload_identity_pool" "aws" {
  count = local.aws_to_gcp_enabled ? 1 : 0

  # Deleted pools are soft-deleted; the same ID cannot be reused for ~30 days
  workload_identity_pool_id = "${var.system_name}-${var.env}-aws-pool"
}

locals {
  allowed_aws_role_names = distinct(flatten([
    for v in var.aws_to_gcp_service_accounts : v.aws_role_names
  ]))
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  count = local.aws_to_gcp_enabled ? 1 : 0

  workload_identity_pool_id          = google_iam_workload_identity_pool.aws[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "${var.system_name}-${var.env}-aws"

  aws {
    account_id = local.aws_account_id
  }

  # google.subject (the full assumed-role ARN) is mapped for audit only.
  # It contains the caller-controlled session name, so authorization is based
  # on attribute.aws_role (role name only) instead.
  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.extract('assumed-role/{role}/')"
  }

  attribute_condition = format(
    "assertion.arn.startsWith('arn:%s:sts::%s:assumed-role/') && attribute.aws_role in [%s]",
    data.aws_partition.current.partition,
    local.aws_account_id,
    join(", ", [for r in local.allowed_aws_role_names : "'${r}'"])
  )
}

resource "google_service_account" "federated" {
  for_each = { for k, v in var.aws_to_gcp_service_accounts : k => v if v.create }

  account_id   = each.key
  display_name = each.value.display_name
}

locals {
  gcp_service_account_emails = {
    for k, v in var.aws_to_gcp_service_accounts :
    k => v.create ? google_service_account.federated[k].email : v.email
  }

  workload_identity_user_bindings = merge({}, [
    for k, v in var.aws_to_gcp_service_accounts : {
      for role_name in v.aws_role_names : "${k}/${role_name}" => {
        sa_key        = k
        aws_role_name = role_name
      }
    }
  ]...)

  sa_project_role_bindings = merge({}, [
    for k, v in var.aws_to_gcp_service_accounts : {
      for project_role in v.project_roles : "${k}/${project_role}" => {
        sa_key       = k
        project_role = project_role
      }
    }
  ]...)
}

resource "google_service_account_iam_member" "workload_identity_user" {
  for_each = local.workload_identity_user_bindings

  service_account_id = "projects/${var.gcp_project_id}/serviceAccounts/${local.gcp_service_account_emails[each.value.sa_key]}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws[0].name}/attribute.aws_role/${each.value.aws_role_name}"
}

# iam_member (not binding/policy) so that bindings managed elsewhere survive
resource "google_project_iam_member" "sa_project_roles" {
  for_each = local.sa_project_role_bindings

  project = var.gcp_project_id
  role    = each.value.project_role
  member  = "serviceAccount:${local.gcp_service_account_emails[each.value.sa_key]}"
}
