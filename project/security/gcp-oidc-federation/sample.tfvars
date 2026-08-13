# コピーして <env>.tfvars として利用する。この env スロットは連携先 IdP 名を担う
# (例: github.tfvars / gitlab.tfvars)。dev/prod は state を分けず、attribute 条件・
# 権限で作り分ける。機密値はコミットせず TF_VAR 環境変数や Secret Manager で注入すること。
system_name    = "app"
env            = "github" # 連携先 OIDC IdP 名 (github / gitlab など)
gcp_project_id = "my-gcp-project"

# 発行者ホスト。スキーム https:// は付けない
oidc_provider_url = "token.actions.githubusercontent.com"

# IdP のクレーム → Google 属性のマッピング。google.subject は必須
attribute_mapping = {
  "google.subject"       = "assertion.sub"
  "attribute.repository" = "assertion.repository"
  "attribute.owner"      = "assertion.repository_owner"
  "attribute.event"      = "assertion.event_name"
}

# プロバイダが受け入れるトークンを絞る CEL 条件式 (必須)。
# ここで組織・リポジトリまで絞り、SA 側の principalSet でさらに ref 等を絞る
attribute_condition = "assertion.repository_owner == '<owner>' && assertion.repository == '<owner>/<repo>'"

# ---------------------------------------------
# service_accounts: OIDC IdP からの impersonate を許可するサービスアカウント
# キーが SA の account_id (6〜30文字)
# 空マップ {} にすると SA 関連リソースは作成されない
# ---------------------------------------------
service_accounts = {
  # plan: 読み取り相当。PR からのトリガのみに絞る
  # attributes は属性値の完全一致 (AND 条件にはならず、指定した値ごとに
  # principalSet バインドが作られる) のため、PR 限定には event 属性を使う
  "app-github-plan" = {
    display_name  = "GitHub Actions (plan)"
    attributes    = { event = ["pull_request"] }
    project_roles = ["roles/viewer"]
  }

  # apply: 書き込み相当。main ブランチへの push のみに絞る
  "app-github-apply" = {
    display_name = "GitHub Actions (apply)"
    # google.subject の完全一致。GitHub Actions の sub は
    # repo:<owner>/<repo>:ref:refs/heads/main / repo:<owner>/<repo>:environment:prod など
    subjects      = ["repo:<owner>/<repo>:ref:refs/heads/main"]
    project_roles = ["roles/editor"]
  }

  # 既存 SA にバインドする例 (SA は作成せず、バインドと権限付与のみ行う)
  # "existing" = {
  #   create        = false
  #   email         = "deployer@my-gcp-project.iam.gserviceaccount.com"
  #   subjects      = ["repo:<owner>/<repo>:environment:prod"]
  #   project_roles = []
  # }
}

# ---------------------------------------------
# direct_access: SA を経由せず principal / principalSet に直接ロールを付与する
# (Direct Workload Identity Federation)。空マップ {} なら何も作成されない
# ---------------------------------------------
direct_access = {
  # "artifact-reader" = {
  #   attributes    = { repository = ["<owner>/<repo>"] }
  #   project_roles = ["roles/artifactregistry.reader"]
  # }
}

# 以下は default のままでよければ省略可
# audiences            = []    # 空ならプロバイダ既定の audience のみ受け入れ (推奨)
# create_pool          = true  # 既存プールにバインドだけ追加する場合は false
# pool_id              = null  # 未指定なら <system_name>-<env>-pool
# provider_id          = null  # 未指定なら <system_name>-<env>
# existing_pool_id     = null  # create_pool = false の場合は必須
# existing_provider_id = null
