variable "system_name" {
  description = "システム名"
  type        = string
}

# この env スロットは環境ではなく OIDC IdP 名 (例: github / gitlab) を担うため、
# dev/stg/prod の validation は行わない
variable "env" {
  description = "環境スロット。このテンプレートでは連携先 OIDC IdP の識別子 (例: github / gitlab) を指定する。dev/prod は state ではなくロールの sub 条件・権限で作り分ける"
  type        = string
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

variable "oidc_provider_url" {
  description = "外部 OIDC IdP の発行者ホスト (例: token.actions.githubusercontent.com)。スキーム https:// は付けない。信頼条件の変数プレフィックス (<url>:sub / <url>:aud) にもこの値を使う"
  type        = string
}

variable "create_oidc_provider" {
  description = "IAM OIDC プロバイダを作成するか。AWSアカウント×URL につき1つしか作れないため、既存がある場合は false にして参照する"
  type        = bool
  default     = true
}

variable "audiences" {
  description = "OIDC トークンの audience の既定値。OIDCプロバイダの client_id_list と、各ロールの信頼条件 (aud) のピン留めの既定値に使用する"
  type        = list(string)
  default     = ["sts.amazonaws.com"]
}

# 近年の AWS provider (~> 5.x) は well-known IdP の thumbprint を自動取得するため
# 通常は指定不要。provider 挙動が変わった場合の逃げ道として optional にしてある
variable "thumbprint_list" {
  description = "OIDC プロバイダの TLS サーバー証明書の thumbprint リスト。null の場合は指定しない (AWS provider が自動取得する)"
  type        = list(string)
  default     = null
}

variable "roles" {
  description = "外部 OIDC IdP に AssumeRoleWithWebIdentity を許可する IAM ロールの定義。キーはロールの識別子 (create_role = true の場合、ロール名は <system_name>-<env>-<キー> になる)"
  type = map(object({
    subject_conditions = list(object({
      test   = string
      values = list(string)
    }))
    audience = optional(list(string))
    additional_conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
    create_role          = optional(bool, true)
    existing_role_name   = optional(string)
    managed_policy_arns  = optional(list(string), [])
    inline_policy        = optional(any)
    max_session_duration = optional(number, 3600)
  }))
  default = {}

  # IdP 全体を無条件に信頼するロールを防ぐため、sub 条件を必須にする
  validation {
    condition = alltrue([
      for v in var.roles : length(v.subject_conditions) > 0
    ])
    error_message = "roles の各エントリには subject_conditions を1件以上指定してください (sub を絞らないと IdP のあらゆるトークンでロールを Assume できてしまう)。"
  }

  validation {
    condition = alltrue([
      for v in var.roles : (v.create_role || v.existing_role_name != null)
    ])
    error_message = "create_role = false のエントリには existing_role_name を指定してください。"
  }
}
