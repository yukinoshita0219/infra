variable "system_name" {
  description = "システム名"
  type        = string
}

variable "env" {
  description = "環境名 (dev / stg / prod)"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.env)
    error_message = "env は dev, stg, prod のいずれかを指定してください。"
  }
}

variable "region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "default_tags" {
  description = "全AWSリソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------
# GCP -> AWS
# ---------------------------------------------
variable "google_oidc_audiences" {
  description = "Google OIDC トークンの audience の既定値。OIDCプロバイダの client_id_list と各ロールの信頼条件 (oaud) に使用する"
  type        = list(string)
  default     = ["sts.amazonaws.com"]
}

variable "create_google_oidc_provider" {
  description = "accounts.google.com の IAM OIDC プロバイダを作成するか。AWSアカウントに1つしか作れないため、既存がある場合は false にして参照する"
  type        = bool
  default     = true
}

variable "gcp_to_aws_roles" {
  description = "GCPのサービスアカウントに AssumeRoleWithWebIdentity を許可する IAM ロールの定義。キーはロールの識別子 (create_role = true の場合、ロール名は <system_name>-<env>-<キー> になる)"
  type = map(object({
    gcp_service_account_unique_ids = list(string)
    create_role                    = optional(bool, true)
    existing_role_name             = optional(string)
    managed_policy_arns            = optional(list(string), [])
    inline_policy                  = optional(any)
    max_session_duration           = optional(number, 3600)
    audiences                      = optional(list(string))
  }))
  default = {}

  validation {
    condition = alltrue([
      for v in var.gcp_to_aws_roles : alltrue([
        for id in v.gcp_service_account_unique_ids : can(regex("^[0-9]+$", id))
      ])
    ])
    error_message = "gcp_service_account_unique_ids にはサービスアカウントの数値の一意ID (unique ID) を指定してください。メールアドレスは指定できません。"
  }

  validation {
    condition = alltrue([
      for v in var.gcp_to_aws_roles : (v.create_role || v.existing_role_name != null)
    ])
    error_message = "create_role = false のエントリには existing_role_name を指定してください。"
  }
}

# ---------------------------------------------
# AWS -> GCP
# ---------------------------------------------
variable "gcp_project_id" {
  description = "GCPプロジェクトID。AWS→GCP連携 (aws_to_gcp_service_accounts) を使用する場合は必須"
  type        = string
  default     = null

  validation {
    condition     = length(var.aws_to_gcp_service_accounts) == 0 || var.gcp_project_id != null
    error_message = "aws_to_gcp_service_accounts を指定する場合は gcp_project_id が必須です。"
  }
}

variable "aws_account_id" {
  description = "GCP側の Workload Identity Pool プロバイダに信頼させるAWSアカウントID。未指定の場合は実行中アカウントのIDを使用する"
  type        = string
  default     = null
}

variable "aws_to_gcp_service_accounts" {
  description = "AWSのIAMロールに impersonate を許可するGCPサービスアカウントの定義。キーは識別子 (create = true の場合、SA の account_id として使用する)"
  type = map(object({
    create         = optional(bool, false)
    email          = optional(string)
    display_name   = optional(string)
    aws_role_names = list(string)
    project_roles  = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for v in var.aws_to_gcp_service_accounts : (v.create || v.email != null)
    ])
    error_message = "create = false のエントリには email を指定してください。"
  }

  validation {
    condition = alltrue([
      for k, v in var.aws_to_gcp_service_accounts : (!v.create || can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", k)))
    ])
    error_message = "create = true のエントリのキーは SA の account_id になるため、6〜30文字の英小文字・数字・ハイフン (先頭は英小文字、末尾はハイフン不可) にしてください。"
  }
}
