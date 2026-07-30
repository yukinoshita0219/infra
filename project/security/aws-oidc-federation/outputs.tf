output "oidc_provider_arn" {
  description = "IAM OIDC プロバイダのARN (作成した場合はそのARN、既存参照の場合は data で解決したARN)"
  value       = local.oidc_provider_arn
}

output "audiences" {
  description = "OIDC トークンの audience の既定値"
  value       = var.audiences
}

output "role_arns" {
  description = "AssumeRoleWithWebIdentity できる IAM ロールのARN (作成・既存を合成)"
  value       = local.role_arns
}

output "role_names" {
  description = "AssumeRoleWithWebIdentity できる IAM ロール名 (作成・既存を合成)"
  value       = local.role_names
}

output "required_trust_policies" {
  description = "create_role = false のエントリで、既存ロール側の信頼ポリシーにマージが必要な JSON"
  value = {
    for k, v in var.roles :
    k => data.aws_iam_policy_document.federated_trust[k].json if !v.create_role
  }
}
