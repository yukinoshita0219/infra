# security/aws-oidc-federation

外部 OIDC IdP（GitHub Actions / GitLab CI / 任意の OIDC プロバイダ）から AWS への
inbound フェデレーションを構成する Terraform テンプレート。長期の IAM アクセスキーを
配布せず、IdP が発行する短命の OIDC トークンで IAM ロールを
`AssumeRoleWithWebIdentity` させる。

## 概要

- IAM OIDC プロバイダ（`aws_iam_openid_connect_provider`）を作成する（既存がある場合は
  `create_oidc_provider = false` で参照）。
- `roles` のエントリごとに信頼ポリシーを組み立てて IAM ロールを作成（または既存ロールへ
  ポリシーをアタッチ）する。信頼条件は必ず `aud`（`<url>:aud`）を `StringEquals` で固定し、
  `sub`（`<url>:sub`）を 1 件以上の条件で絞る。
- `env` スロットは環境ではなく **連携先 IdP 名**（例: `github` / `gitlab`）を担う。
  dev / prod は state を分けず、ロールの `sub` 条件と権限で作り分ける（後述）。

## セキュリティ設計の要点

- **`aud`（audience）のピン留めは必須**: 信頼ポリシーで `<url>:aud` を `StringEquals` で
  固定する（省略不可）。ピン留めしないと、その IdP が他サービス向けに発行したトークンでも
  ロールを Assume できてしまう（confused deputy）。ロール固有の `audience` を指定しない場合は
  `audiences`（既定 `["sts.amazonaws.com"]`）が使われる。
- **`sub` を必ず絞る**: `subject_conditions` は 1 件以上を必須にしている（variable の validation で
  強制）。IdP 全体を無条件に信頼するロールを作らせないため。GitHub Actions なら
  `repo:<owner>/<repo>:ref:refs/heads/main` や `repo:<owner>/<repo>:environment:prod` のように
  リポジトリ・ブランチ・Environment まで絞り込む。
- **fork PR の構造的な安全性**: GitHub Actions では、fork からの PR で起動したワークフローには
  `id-token: write` 権限が付与されない（OIDC トークンを取得できない）。そのため fork PR は
  そもそも高権限ロールを踏めない。信頼するのは自リポジトリのワークフローのみになる。
- **plan / apply ロールの分割**: 読み取り専用の `plan` ロール（`sub` を `pull_request` に限定）と、
  書き込み可能な `apply` ロール（`sub` を `ref:refs/heads/main` や `environment:prod` に限定）を
  分けることで、PR 段階では書き込み権限を渡さない。

## 前提条件

- **IAM OIDC プロバイダは AWS アカウント × URL につき 1 つしか作成できない**。同じ URL の
  プロバイダが既に存在する場合は `create_oidc_provider = false` を指定して既存を参照する
  （既存プロバイダの `client_id_list` に必要な audience が含まれているか確認すること）。
- `oidc_provider_url` には発行者ホスト（例: `token.actions.githubusercontent.com`）を、
  **スキーム `https://` を付けずに**指定する。信頼条件の変数プレフィックスにも同じ値を使う。
- **thumbprint について**: 近年の AWS provider（`~> 5.x`）は well-known IdP の TLS 証明書
  thumbprint を自動取得するため、通常 `thumbprint_list` の指定は不要（既定 `null` で省略）。
  provider の挙動変更等で必要になった場合のみ `thumbprint_list` に明示指定する。

## 既存 AWS ロールにバインドする場合（create_role = false）

AWS の assume role policy（信頼ポリシー）はロール本体と不可分であり、Terraform から既存
ロールへ信頼ステートメントだけを追加することはできない。そのため:

1. このテンプレートは `create_role = false` のエントリについて、必要な信頼ポリシー JSON を
   output `required_trust_policies` で提供する。
2. **ロールの所有側**でこの JSON を信頼ポリシーに設定（マージ）してもらう必要がある。設定される
   まで OIDC からの AssumeRole は失敗する。
3. `managed_policy_arns` / `inline_policy` のアタッチは既存ロールに対しても本テンプレートが
   実施する。

## GitHub Actions 側の組み込み例

ワークフローに `id-token: write` 権限を付与し、`aws-actions/configure-aws-credentials` で
ロールを Assume する。

```yaml
permissions:
  id-token: write # OIDC トークンの取得に必須
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<account-id>:role/app-github-apply # output role_arns の値
          aws-region: ap-northeast-1
      - run: aws sts get-caller-identity
```

`role-to-assume` には output `role_arns` の該当ロール ARN を指定する。ロールの `sub` 条件と
このワークフローのトリガ（ブランチ / Environment）が一致しないと AssumeRole は失敗する。

## 変数一覧

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| env | 環境スロット。このテンプレートでは連携先 OIDC IdP の識別子 (例: github / gitlab) を指定する。dev/prod は state ではなくロールの sub 条件・権限で作り分ける | `string` | n/a | yes |
| oidc\_provider\_url | 外部 OIDC IdP の発行者ホスト (例: token.actions.githubusercontent.com)。スキーム https:// は付けない。信頼条件の変数プレフィックス (<url>:sub / <url>:aud) にもこの値を使う | `string` | n/a | yes |
| system\_name | システム名 | `string` | n/a | yes |
| audiences | OIDC トークンの audience の既定値。OIDCプロバイダの client\_id\_list と、各ロールの信頼条件 (aud) のピン留めの既定値に使用する | `list(string)` | <pre>[<br/>  "sts.amazonaws.com"<br/>]</pre> | no |
| create\_oidc\_provider | IAM OIDC プロバイダを作成するか。AWSアカウント×URL につき1つしか作れないため、既存がある場合は false にして参照する | `bool` | `true` | no |
| default\_tags | 全AWSリソースに付与する追加タグ | `map(string)` | `{}` | no |
| region | AWSリージョン | `string` | `"ap-northeast-1"` | no |
| roles | 外部 OIDC IdP に AssumeRoleWithWebIdentity を許可する IAM ロールの定義。キーはロールの識別子 (create\_role = true の場合、ロール名は <system\_name>-<env>-<キー> になる) | <pre>map(object({<br/>    subject_conditions = list(object({<br/>      test   = string<br/>      values = list(string)<br/>    }))<br/>    audience = optional(list(string))<br/>    additional_conditions = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>    create_role          = optional(bool, true)<br/>    existing_role_name   = optional(string)<br/>    managed_policy_arns  = optional(list(string), [])<br/>    inline_policy        = optional(any)<br/>    max_session_duration = optional(number, 3600)<br/>  }))</pre> | `{}` | no |
| thumbprint\_list | OIDC プロバイダの TLS サーバー証明書の thumbprint リスト。null の場合は指定しない (AWS provider が自動取得する) | `list(string)` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| audiences | OIDC トークンの audience の既定値 |
| oidc\_provider\_arn | IAM OIDC プロバイダのARN (作成した場合はそのARN、既存参照の場合は data で解決したARN) |
| required\_trust\_policies | create\_role = false のエントリで、既存ロール側の信頼ポリシーにマージが必要な JSON |
| role\_arns | AssumeRoleWithWebIdentity できる IAM ロールのARN (作成・既存を合成) |
| role\_names | AssumeRoleWithWebIdentity できる IAM ロール名 (作成・既存を合成) |
<!-- END_TF_DOCS -->

### roles のエントリ

| 属性 | 説明 | デフォルト |
|---|---|---|
| `subject_conditions` | `<url>:sub` に対する条件のリスト（`test` と `values`）。**1 件以上必須** | (必須) |
| `audience` | このロール固有の audience（`<url>:aud` に `StringEquals` で固定）。null なら `audiences` | `null` |
| `additional_conditions` | 追加クレーム条件のエスケープハッチ（`test` / `variable` / `values`） | `[]` |
| `create_role` | ロールを新規作成するか。false なら既存ロールを参照 | `true` |
| `existing_role_name` | 既存ロール名（`create_role = false` のとき必須） | `null` |
| `managed_policy_arns` | アタッチするマネージドポリシー ARN のリスト | `[]` |
| `inline_policy` | アタッチするインラインポリシー（HCL オブジェクトで記述。モジュールが JSON へ変換する） | `null` |
| `max_session_duration` | 最大セッション時間（秒、`create_role = true` のみ有効） | `3600` |

## dev / prod の作り分け方針

- この `env` スロットは **IdP 名**（`github` など）を表す。環境ごとに state を分けない。
- dev / prod のロールは同一 state 内で、`roles` のキーと `sub` 条件・付与権限で作り分ける
  （例: `apply-prod` は `sub` を `environment:prod` に、`apply-dev` は `ref:refs/heads/develop`
  に絞る）。同じ IdP プロバイダ（アカウント × URL に 1 つ）を全ロールで共有する。

## tfvars 運用

- このリポジトリはテンプレート集のため、同梱するのは雛形の `sample.tfvars` のみ。テンプレートを
  実プロジェクトで採用する際に、IdP 別の `<idp>.tfvars`（例: `github.tfvars`）を
  `cp sample.tfvars <idp>.tfvars` で作成し、そのままリポジトリにコミットする。
- IdP 別 tfvars がコミットされていれば Jenkins のクリーンチェックアウトにも含まれるため、
  `Jenkinsfile` の `-var-file="${ENV}.tfvars"` はそのまま動く。
- 機密値は tfvars に書かず、`TF_VAR_xxx` 環境変数や Secrets Manager で注入する。
  `<owner>/<repo>` はプレースホルダのため、採用時に実際の値へ置き換えること。

## state の key 規約

backend は S3。key は Jenkins が生成する `backend.hcl` 経由で
`security/aws-oidc-federation/${ENV}/terraform.tfstate` として渡す（`versions.tf` の backend
ブロックには書かない）。`${ENV}` は IdP スロット名（`github` など）。
