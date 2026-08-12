output "workload_identity_pool_id" {
  description = "Workload Identity Pool のID (作成した場合は生成ID、既存参照の場合は existing_pool_id)"
  value       = var.create_pool ? local.pool_id : var.existing_pool_id
}

output "workload_identity_pool_name" {
  description = "Workload Identity Pool の完全リソース名"
  value       = local.pool_name
}

output "workload_identity_pool_provider_id" {
  description = "Workload Identity Pool プロバイダのID (作成した場合は生成ID、既存参照の場合は existing_provider_id)"
  value       = var.create_pool ? local.provider_id : var.existing_provider_id
}

output "workload_identity_pool_provider_name" {
  description = "Workload Identity Pool プロバイダの完全リソース名。google-github-actions/auth の workload_identity_provider にそのまま指定できる (既存参照で existing_provider_id 未指定の場合は null)"
  value       = local.provider_name
}

output "audiences" {
  description = "受け入れる audience のリスト。空の場合はプロバイダ既定の audience (プロバイダの完全リソース名) のみを受け入れる"
  value       = var.audiences
}

output "service_account_emails" {
  description = "impersonate 対象サービスアカウントのメールアドレス (作成・既存を合成)"
  value       = local.service_account_emails
}

output "service_account_members" {
  description = "サービスアカウントごとに roles/iam.workloadIdentityUser を付与した principal / principalSet URI"
  value       = { for k, v in local.service_account_members : k => values(v) }
}

output "direct_access_members" {
  description = "direct_access のエントリごとにプロジェクトロールを付与した principal / principalSet URI"
  value       = { for k, v in local.direct_access_members : k => values(v) }
}
