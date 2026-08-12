variable "system_name" {
  description = "システム名 (Workload Identity Pool のID に使用するため英小文字・数字・ハイフンのみ)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.system_name))
    error_message = "system_name は英小文字始まりで、英小文字・数字・ハイフンのみ使用できます (Workload Identity Pool のID制約)。"
  }
}

# この env スロットは環境ではなく OIDC IdP 名 (例: github / gitlab) を担うため、
# dev/stg/prod の validation は行わない
variable "env" {
  description = "環境スロット。このテンプレートでは連携先 OIDC IdP の識別子 (例: github / gitlab) を指定する。dev/prod は state ではなく attribute 条件・権限で作り分ける"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.env))
    error_message = "env は英小文字始まりで、英小文字・数字・ハイフンのみ使用できます (Workload Identity Pool のID制約)。"
  }
}

variable "gcp_project_id" {
  description = "GCPプロジェクトID"
  type        = string
}

variable "oidc_provider_url" {
  description = "外部 OIDC IdP の発行者ホスト (例: token.actions.githubusercontent.com)。スキーム https:// は付けない"
  type        = string

  validation {
    condition     = !strcontains(var.oidc_provider_url, "://")
    error_message = "oidc_provider_url にはスキーム (https://) を含めず、発行者ホストのみを指定してください。"
  }
}

variable "audiences" {
  description = "受け入れる OIDC トークンの audience (aud) のリスト。空リストの場合はプロバイダ既定の audience (プロバイダの完全リソース名) のみを受け入れる"
  type        = list(string)
  default     = []
}

variable "attribute_mapping" {
  description = "IdP のクレームから Google の属性へのマッピング。google.subject は必須。attribute.<名前> で定義した属性を attribute_condition や principalSet の絞り込みに使える"
  type        = map(string)
  default = {
    "google.subject" = "assertion.sub"
  }

  validation {
    condition     = contains(keys(var.attribute_mapping), "google.subject")
    error_message = "attribute_mapping には google.subject を必ず含めてください (GCPの必須マッピング)。"
  }
}

# 条件なしのプロバイダは IdP が発行する全トークンを信頼してしまうため、
# プロバイダを作成する場合は必須にする
variable "attribute_condition" {
  description = "プロバイダが受け入れるトークンを絞る CEL 条件式 (例: assertion.repository_owner == 'my-org')。create_pool = true の場合は必須"
  type        = string
  default     = null

  validation {
    condition     = !var.create_pool || try(length(trimspace(var.attribute_condition)) > 0, false)
    error_message = "create_pool = true の場合は attribute_condition が必須です (条件なしでは IdP のあらゆるトークンを信頼してしまいます)。"
  }
}

variable "create_pool" {
  description = "Workload Identity Pool とプロバイダを作成するか。既にあるプールにサービスアカウントのバインドだけ追加する場合は false にする"
  type        = bool
  default     = true
}

variable "pool_id" {
  description = "Workload Identity Pool のID。null の場合は <system_name>-<env>-pool になる"
  type        = string
  default     = null

  validation {
    condition = !var.create_pool || alltrue([
      can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", coalesce(var.pool_id, "${var.system_name}-${var.env}-pool"))),
      !startswith(coalesce(var.pool_id, "${var.system_name}-${var.env}-pool"), "gcp-"),
    ])
    error_message = "Workload Identity Pool のID (未指定時は <system_name>-<env>-pool) は4〜32文字の英小文字・数字・ハイフン (先頭は英小文字、末尾はハイフン不可) で、gcp- で始められません。"
  }
}

variable "provider_id" {
  description = "Workload Identity Pool プロバイダのID。null の場合は <system_name>-<env> になる"
  type        = string
  default     = null

  validation {
    condition = !var.create_pool || alltrue([
      can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", coalesce(var.provider_id, "${var.system_name}-${var.env}"))),
      !startswith(coalesce(var.provider_id, "${var.system_name}-${var.env}"), "gcp-"),
    ])
    error_message = "Workload Identity Pool プロバイダのID (未指定時は <system_name>-<env>) は4〜32文字の英小文字・数字・ハイフン (先頭は英小文字、末尾はハイフン不可) で、gcp- で始められません。"
  }
}

variable "existing_pool_id" {
  description = "参照する既存 Workload Identity Pool のID。create_pool = false の場合は必須"
  type        = string
  default     = null

  validation {
    condition     = var.create_pool || var.existing_pool_id != null
    error_message = "create_pool = false の場合は existing_pool_id が必須です。"
  }
}

variable "existing_provider_id" {
  description = "参照する既存 Workload Identity Pool プロバイダのID。バインドには不要だが、指定すると output workload_identity_pool_provider_name を解決できる"
  type        = string
  default     = null
}

variable "service_accounts" {
  description = "OIDC IdP からの impersonate を許可するサービスアカウントの定義。キーは SA の account_id (ロール名のような system_name/env のプレフィックスは付かない)"
  type = map(object({
    subjects      = optional(list(string), [])
    attributes    = optional(map(list(string)), {})
    create        = optional(bool, true)
    email         = optional(string)
    display_name  = optional(string)
    project_roles = optional(list(string), [])
  }))
  default = {}

  # IdP 全体を無条件に信頼するバインドを防ぐため、絞り込みを必須にする
  validation {
    condition = alltrue([
      for v in var.service_accounts : (length(v.subjects) > 0 || length(v.attributes) > 0)
    ])
    error_message = "service_accounts の各エントリには subjects か attributes を1件以上指定してください (絞り込まないと IdP のあらゆるIDが impersonate できてしまいます)。"
  }

  validation {
    condition = alltrue([
      for v in var.service_accounts : (v.create || v.email != null)
    ])
    error_message = "create = false のエントリには email を指定してください。"
  }

  validation {
    condition = alltrue([
      for k, v in var.service_accounts : (!v.create || can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", k)))
    ])
    error_message = "create = true のエントリのキーは SA の account_id になるため、6〜30文字の英小文字・数字・ハイフン (先頭は英小文字、末尾はハイフン不可) にしてください。"
  }

  validation {
    condition = alltrue([
      for v in var.service_accounts : alltrue([
        for role in v.project_roles : startswith(role, "roles/")
      ])
    ])
    error_message = "project_roles にはロール名 (roles/ で始まる文字列) を指定してください。"
  }

  validation {
    condition = !var.create_pool || alltrue([
      for v in var.service_accounts : alltrue([
        for attr in keys(v.attributes) : contains(keys(var.attribute_mapping), "attribute.${attr}")
      ])
    ])
    error_message = "attributes のキーは attribute_mapping に attribute.<キー> として定義されている必要があります。"
  }
}

variable "direct_access" {
  description = "サービスアカウントを経由せず、principal / principalSet に直接プロジェクトロールを付与する定義 (Direct Workload Identity Federation)。キーは識別子"
  type = map(object({
    subjects      = optional(list(string), [])
    attributes    = optional(map(list(string)), {})
    project_roles = list(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for v in var.direct_access : (length(v.subjects) > 0 || length(v.attributes) > 0)
    ])
    error_message = "direct_access の各エントリには subjects か attributes を1件以上指定してください (絞り込まないと IdP のあらゆるIDに権限が付与されてしまいます)。"
  }

  validation {
    condition = alltrue([
      for v in var.direct_access : alltrue([
        for role in v.project_roles : startswith(role, "roles/")
      ])
    ])
    error_message = "project_roles にはロール名 (roles/ で始まる文字列) を指定してください。"
  }

  validation {
    condition = !var.create_pool || alltrue([
      for v in var.direct_access : alltrue([
        for attr in keys(v.attributes) : contains(keys(var.attribute_mapping), "attribute.${attr}")
      ])
    ])
    error_message = "attributes のキーは attribute_mapping に attribute.<キー> として定義されている必要があります。"
  }
}
