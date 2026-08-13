# No credentials in code: ADC (Application Default Credentials) is assumed
provider "google" {
  project = var.gcp_project_id
}

data "google_project" "this" {
  count = var.create_pool ? 0 : 1
}

locals {
  pool_id     = coalesce(var.pool_id, "${var.system_name}-${var.env}-pool")
  provider_id = coalesce(var.provider_id, "${var.system_name}-${var.env}")
}

# A deleted pool is soft-deleted and its ID cannot be reused for ~30 days;
# set create_pool = false to bind onto a pool/provider that already exists.
resource "google_iam_workload_identity_pool" "this" {
  count = var.create_pool ? 1 : 0

  workload_identity_pool_id = local.pool_id
}

resource "google_iam_workload_identity_pool_provider" "this" {
  count = var.create_pool ? 1 : 0

  workload_identity_pool_id          = google_iam_workload_identity_pool.this[0].workload_identity_pool_id
  workload_identity_pool_provider_id = local.provider_id
  attribute_mapping                  = var.attribute_mapping

  # Mandatory: a provider without a condition trusts every token the IdP issues
  attribute_condition = var.attribute_condition

  oidc {
    issuer_uri = "https://${var.oidc_provider_url}"

    # null keeps the provider-scoped default audience (the API rejects an empty
    # list); a non-empty list pins the accepted aud claim instead
    allowed_audiences = length(var.audiences) > 0 ? var.audiences : null
  }
}

locals {
  # A referenced pool has no resource to read the canonical name from
  pool_name = var.create_pool ? google_iam_workload_identity_pool.this[0].name : "projects/${data.google_project.this[0].number}/locations/global/workloadIdentityPools/${var.existing_pool_id}"

  provider_name = var.create_pool ? google_iam_workload_identity_pool_provider.this[0].name : (
    var.existing_provider_id != null ? "${local.pool_name}/providers/${var.existing_provider_id}" : null
  )

  # service_accounts and direct_access build principal URIs identically, so only
  # the selectors are lifted out and converted in one place
  principal_selectors = merge(
    { for k, v in var.service_accounts : "sa/${k}" => { subjects = v.subjects, attributes = v.attributes } },
    { for k, v in var.direct_access : "direct/${k}" => { subjects = v.subjects, attributes = v.attributes } },
  )

  # The URIs embed pool_name, which is unknown until apply when the pool is
  # created here; keyed by selector so that for_each keys stay plan-time known
  principal_members = {
    for k, v in local.principal_selectors : k => {
      for e in concat(
        [
          for s in v.subjects : {
            selector = "subject/${s}"
            member   = "principal://iam.googleapis.com/${local.pool_name}/subject/${s}"
          }
        ],
        flatten([
          for attr, values in v.attributes : [
            for value in values : {
              selector = "attribute.${attr}/${value}"
              member   = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.${attr}/${value}"
            }
          ]
        ])
      ) : e.selector => e.member
    }
  }

  # Identical selectors always resolve to the identical URI, so collisions
  # across entries are harmless here
  members_by_selector = merge({}, values(local.principal_members)...)
}

resource "google_service_account" "federated" {
  for_each = { for k, v in var.service_accounts : k => v if v.create }

  account_id   = each.key
  display_name = each.value.display_name
}

locals {
  service_account_emails = {
    for k, v in var.service_accounts :
    k => v.create ? google_service_account.federated[k].email : v.email
  }

  service_account_members = {
    for k, v in var.service_accounts : k => local.principal_members["sa/${k}"]
  }

  workload_identity_user_bindings = {
    for b in flatten([
      for k, members in local.service_account_members : [
        for selector, member in members : { sa_key = k, selector = selector, member = member }
      ]
    ]) : "${b.sa_key}|${b.selector}" => b
  }

  service_account_project_roles = {
    for b in distinct(flatten([
      for k, v in var.service_accounts : [
        for role in v.project_roles : { sa_key = k, role = role }
      ]
    ])) : "${b.sa_key}|${b.role}" => b
  }

  direct_access_members = {
    for k, v in var.direct_access : k => local.principal_members["direct/${k}"]
  }

  # distinct so that two entries granting the same role to the same principal
  # collapse into one binding instead of colliding as duplicate keys
  direct_project_roles = {
    for b in distinct(flatten([
      for k, v in var.direct_access : [
        for role in v.project_roles : [
          for selector in keys(local.direct_access_members[k]) : { role = role, selector = selector }
        ]
      ]
    ])) : "${b.role}|${b.selector}" => b
  }
}

resource "google_service_account_iam_member" "workload_identity_user" {
  for_each = local.workload_identity_user_bindings

  service_account_id = "projects/${var.gcp_project_id}/serviceAccounts/${local.service_account_emails[each.value.sa_key]}"
  role               = "roles/iam.workloadIdentityUser"
  member             = each.value.member
}

# iam_member (not binding/policy) so that grants managed elsewhere survive
resource "google_project_iam_member" "service_account_roles" {
  for_each = local.service_account_project_roles

  project = var.gcp_project_id
  role    = each.value.role
  member  = "serviceAccount:${local.service_account_emails[each.value.sa_key]}"
}

resource "google_project_iam_member" "direct" {
  for_each = local.direct_project_roles

  project = var.gcp_project_id
  role    = each.value.role
  member  = local.members_by_selector[each.value.selector]
}
