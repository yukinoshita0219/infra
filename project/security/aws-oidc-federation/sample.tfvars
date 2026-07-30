# コピーして <env>.tfvars として利用する。この env スロットは連携先 IdP 名を担う
# (例: github.tfvars / gitlab.tfvars)。dev/prod は state を分けず、ロールの sub 条件・
# 権限で作り分ける。機密値はコミットせず TF_VAR 環境変数や Secrets Manager で注入すること。
system_name = "app"
env         = "github" # 連携先 OIDC IdP 名 (github / gitlab など)

# 発行者ホスト。スキーム https:// は付けない
oidc_provider_url = "token.actions.githubusercontent.com"

# 以下は default のままでよければ省略可
# region               = "ap-northeast-1"
# default_tags         = {}
# audiences            = ["sts.amazonaws.com"]
# create_oidc_provider = true    # アカウント×URL に OIDC プロバイダが既にある場合は false
# thumbprint_list      = null    # AWS provider が自動取得するため通常は指定不要

# ---------------------------------------------
# roles: 外部 OIDC IdP に AssumeRoleWithWebIdentity を許可する IAM ロール
# キーがロール識別子。ロール名は <system_name>-<env>-<キー> になる
# 空マップ {} にするとロールは作成されない
# ---------------------------------------------
roles = {
  # plan: 読み取り相当。PR (fork でない) からのトリガのみに絞る
  "plan" = {
    subject_conditions = [
      { test = "StringLike", values = ["repo:<owner>/<repo>:pull_request"] }
    ]
    managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    # state 用の追加権限が必要なら inline_policy で S3/DynamoDB を絞って付与する
    # (HCL オブジェクトで記述。モジュールが JSON へ変換する)
    # inline_policy = {
    #   Version = "2012-10-17"
    #   Statement = [
    #     { Effect = "Allow", Action = ["s3:ListBucket"], Resource = "arn:aws:s3:::example-bucket" },
    #     { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::example-bucket/*" }
    #   ]
    # }
  }

  # apply: 書き込み相当。main ブランチへの push のみに絞る
  "apply" = {
    subject_conditions = [
      { test = "StringEquals", values = ["repo:<owner>/<repo>:ref:refs/heads/main"] }
    ]
    managed_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
    # 本番の承認ゲートを使う場合は GitHub Environment に絞る例:
    # subject_conditions = [
    #   { test = "StringEquals", values = ["repo:<owner>/<repo>:environment:prod"] }
    # ]
  }

  # 既存ロールにバインドする例 (信頼ポリシーは output required_trust_policies の JSON を
  # ロール所有側で設定する。managed_policy_arns / inline_policy は本テンプレートが付与)
  # "existing" = {
  #   subject_conditions = [
  #     { test = "StringEquals", values = ["repo:<owner>/<repo>:ref:refs/heads/main"] }
  #   ]
  #   create_role        = false
  #   existing_role_name = "app-github-existing-role"
  # }
}
