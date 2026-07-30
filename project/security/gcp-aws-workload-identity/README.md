# security/gcp-aws-workload-identity

GCP と AWS の間でキーレス（長期キー不要）の双方向認証連携を構成する Terraform テンプレート。

## 構成

- **GCP → AWS**: GCP のワークロード（GCE / Cloud Run / Cloud Build 等）がサービスアカウント (SA) の OIDC トークンで AWS IAM ロールを `AssumeRoleWithWebIdentity` する。
  - `accounts.google.com` の IAM OIDC プロバイダを作成（既存がある場合は `create_google_oidc_provider = false` で参照）
  - 信頼ポリシーは SA の数値一意 ID（`accounts.google.com:sub`）と audience（`accounts.google.com:oaud`）を `StringEquals` で固定
  - IAM ロールはエントリごとに「新規作成（`create_role = true`、既定）」か「既存ロールへのバインド（`create_role = false`）」を選択可能
- **AWS → GCP**: AWS の IAM ロールが Workload Identity Pool（AWS プロバイダ）経由で GCP の SA を impersonate する。
  - Pool ID は `<system_name>-<env>-aws-pool`、プロバイダ ID は `<system_name>-<env>-aws`
  - SA はエントリごとに「既存 SA へのバインド（`create = false`、既定）」か「新規作成（`create = true`、マップのキーが `account_id` になる）」を選択可能
  - `project_roles` で SA 自身へのプロジェクトロール付与も可能（`google_project_iam_member` を使用するため、他で管理されているバインディングを上書きしない）
- **方向の有効/無効は空マップで制御する**。`gcp_to_aws_roles = {}` / `aws_to_gcp_service_accounts = {}` ならその方向のリソースは一切作成されない（両方空なら作成リソース 0）。

## 前提条件

### GCP 側（AWS→GCP 連携を使う場合）

- 対象プロジェクトで以下の API を有効化しておく:
  - `iam.googleapis.com`
  - `iamcredentials.googleapis.com`
  - `sts.googleapis.com`
- Terraform 実行者（ADC のプリンシパル）に必要な権限:
  - Workload Identity Pool の管理: `roles/iam.workloadIdentityPoolAdmin`
  - 対象 SA への `workloadIdentityUser` バインド: 対象 SA に対する `iam.serviceAccounts.setIamPolicy`（`roles/iam.serviceAccountAdmin` 相当）
  - SA を新規作成する場合（`create = true`）: `roles/iam.serviceAccountAdmin`
  - `project_roles` を使う場合: プロジェクトの IAM を変更できる権限（`roles/resourcemanager.projectIamAdmin` 相当）
- 認証はコードに書かず ADC（Application Default Credentials）を使用する。ローカルでは `gcloud auth application-default login`、Jenkins では後述の Secret file を利用。

### AWS 側

- `accounts.google.com` の OIDC プロバイダは **1 アカウントに 1 つしか作成できない**。既に存在する場合は `create_google_oidc_provider = false` を指定して既存を参照する（`client_id_list` に必要な audience が含まれているかは既存プロバイダ側で確認すること）。

## 既存 AWS ロールにバインドする場合（create_role = false）

AWS の assume role policy（信頼ポリシー）はロール本体と不可分であり、Terraform から既存ロールへ信頼ステートメントだけを追加することはできない。そのため:

1. このテンプレートは `create_role = false` のエントリについて、必要な信頼ポリシー JSON を output `gcp_to_aws_required_trust_policies` で提供する。
2. **ロールの所有側**でこの JSON を信頼ポリシーに設定（マージ）してもらう必要がある。設定されるまで GCP からの AssumeRole は失敗する。
3. `managed_policy_arns` / `inline_policy` のアタッチは既存ロールに対しても本テンプレートが実施する。

## 変数一覧

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| env | 環境名 (dev / stg / prod) | `string` | n/a | yes |
| system\_name | システム名 | `string` | n/a | yes |
| aws\_account\_id | GCP側の Workload Identity Pool プロバイダに信頼させるAWSアカウントID。未指定の場合は実行中アカウントのIDを使用する | `string` | `null` | no |
| aws\_to\_gcp\_service\_accounts | AWSのIAMロールに impersonate を許可するGCPサービスアカウントの定義。キーは識別子 (create = true の場合、SA の account\_id として使用する) | <pre>map(object({<br/>    create         = optional(bool, false)<br/>    email          = optional(string)<br/>    display_name   = optional(string)<br/>    aws_role_names = list(string)<br/>    project_roles  = optional(list(string), [])<br/>  }))</pre> | `{}` | no |
| create\_google\_oidc\_provider | accounts.google.com の IAM OIDC プロバイダを作成するか。AWSアカウントに1つしか作れないため、既存がある場合は false にして参照する | `bool` | `true` | no |
| default\_tags | 全AWSリソースに付与する追加タグ | `map(string)` | `{}` | no |
| gcp\_project\_id | GCPプロジェクトID。AWS→GCP連携 (aws\_to\_gcp\_service\_accounts) を使用する場合は必須 | `string` | `null` | no |
| gcp\_to\_aws\_roles | GCPのサービスアカウントに AssumeRoleWithWebIdentity を許可する IAM ロールの定義。キーはロールの識別子 (create\_role = true の場合、ロール名は <system\_name>-<env>-<キー> になる) | <pre>map(object({<br/>    gcp_service_account_unique_ids = list(string)<br/>    create_role                    = optional(bool, true)<br/>    existing_role_name             = optional(string)<br/>    managed_policy_arns            = optional(list(string), [])<br/>    inline_policy                  = optional(any)<br/>    max_session_duration           = optional(number, 3600)<br/>    audiences                      = optional(list(string))<br/>  }))</pre> | `{}` | no |
| google\_oidc\_audiences | Google OIDC トークンの audience の既定値。OIDCプロバイダの client\_id\_list と各ロールの信頼条件 (oaud) に使用する | `list(string)` | <pre>[<br/>  "sts.amazonaws.com"<br/>]</pre> | no |
| region | AWSリージョン | `string` | `"ap-northeast-1"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| gcloud\_cred\_config\_commands | SAごとの認証構成ファイル生成コマンド例 (gcloud iam workload-identity-pools create-cred-config) |
| gcp\_service\_account\_emails | AWSからの impersonate 対象GCPサービスアカウントのメールアドレス (作成・既存を合成) |
| gcp\_to\_aws\_required\_trust\_policies | create\_role = false のエントリで、既存ロール側に設定が必要な信頼ポリシーJSON |
| gcp\_to\_aws\_role\_arns | GCPから AssumeRoleWithWebIdentity できる IAM ロールのARN (作成・既存を合成) |
| google\_oidc\_audiences | Google OIDC トークンの audience の既定値 |
| google\_oidc\_provider\_arn | Google OIDC プロバイダのARN (GCP→AWS 無効時は null) |
| principal\_set\_uris | AWS IAM ロール名ごとの principalSet URI |
| workload\_identity\_pool\_name | Workload Identity Pool の完全リソース名 (AWS→GCP 無効時は null) |
| workload\_identity\_pool\_provider\_name | Workload Identity Pool プロバイダの完全リソース名。cred-config 生成にそのまま使用できる (AWS→GCP 無効時は null) |
<!-- END_TF_DOCS -->

### gcp_to_aws_roles のエントリ

| 属性 | 説明 | デフォルト |
|---|---|---|
| `gcp_service_account_unique_ids` | AssumeRole を許可する SA の**数値一意 ID** のリスト（メールアドレス不可） | (必須) |
| `create_role` | ロールを新規作成するか。false なら既存ロールを参照 | `true` |
| `existing_role_name` | 既存ロール名（`create_role = false` のとき必須） | `null` |
| `managed_policy_arns` | アタッチするマネージドポリシー ARN のリスト | `[]` |
| `inline_policy` | アタッチするインラインポリシー（HCL オブジェクトで記述。モジュールが JSON へ変換する） | `null` |
| `max_session_duration` | 最大セッション時間（秒、`create_role = true` のみ有効） | `3600` |
| `audiences` | このロール固有の audience（null なら `google_oidc_audiences`） | `null` |

### aws_to_gcp_service_accounts のエントリ

| 属性 | 説明 | デフォルト |
|---|---|---|
| `create` | SA を新規作成するか。true ならマップのキーが `account_id` になる（6〜30 文字 `[a-z0-9-]`） | `false` |
| `email` | 既存 SA のメールアドレス（`create = false` のとき必須） | `null` |
| `display_name` | SA の表示名（`create = true` のとき使用） | `null` |
| `aws_role_names` | impersonate を許可する AWS IAM ロール名のリスト | (必須) |
| `project_roles` | SA 自身に付与するプロジェクトロール（例: `roles/storage.objectViewer`） | `[]` |

## 利用方法

### GCP → AWS（GCP ワークロードから AWS を利用）

1. GCE / Cloud Run 等のメタデータサーバーから ID トークンを取得する:

   ```sh
   curl -s -H "Metadata-Flavor: Google" \
     "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com&format=full" \
     > /tmp/gcp-token
   ```

2. AWS SDK / CLI に環境変数で渡す（SDK が自動で AssumeRoleWithWebIdentity する）:

   ```sh
   export AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/gcp-token
   export AWS_ROLE_ARN=<output gcp_to_aws_role_arns の ARN>
   aws s3 ls
   ```

   トークンは短命（約 1 時間）のため、常駐プロセスでは `credential_process` 等でトークン取得から AssumeRole までを再実行できるようにしておく。

### AWS → GCP（AWS ワークロードから GCP を利用）

1. output `gcloud_cred_config_commands` のコマンドで認証構成ファイルを生成する（IMDSv2 を強制するため `--enable-imdsv2` 付き）:

   ```sh
   gcloud iam workload-identity-pools create-cred-config \
     <output workload_identity_pool_provider_name> \
     --service-account=<SA のメールアドレス> \
     --aws --enable-imdsv2 \
     --output-file=cred-config.json
   ```

2. 生成したファイル（機密情報は含まない）をワークロードに配置し、`GOOGLE_APPLICATION_CREDENTIALS` に指定すると、GCP クライアントライブラリが自動で AWS 認証情報 → GCP トークンの交換を行う:

   ```sh
   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/cred-config.json
   gsutil ls gs://my-bucket
   ```

3. AWS 側のワークロードは `aws_role_names` に列挙した IAM ロールで動作している必要がある（EC2 インスタンスプロファイル / ECS タスクロール等）。

## Jenkins の GCP 認証設定

- AWS→GCP 連携（GCP リソース）を管理する場合、plan / apply 時に GCP の認証が必要になる。
- Jenkins の **Secret file** クレデンシャルとして GCP サービスアカウントキー（JSON）を登録し、ジョブパラメータ `GCP_CREDENTIALS_ID` にそのクレデンシャル ID を指定すると、パイプラインが `GOOGLE_APPLICATION_CREDENTIALS` として注入する（鍵ファイルはワークスペースに書き出されない）。
- `GCP_CREDENTIALS_ID` が空の場合はエージェントの ADC（`gcloud auth application-default login` 済み、または GCE メタデータ等）をそのまま使用する。
- `gcp_to_aws_roles` のみ（GCP→AWS のみ）を使う場合、GCP リソースは作成されないため GCP 認証は不要。

## セキュリティ設計の要点

- **`oaud`（audience）のピン留め**: GCP→AWS の信頼ポリシーでは `sub` に加えて `oaud` も `StringEquals` で固定している。`oaud` を省くと、同じ SA が他サービス向けに発行した ID トークンでもこのロールを Assume できてしまう（confused deputy）ため必須。
- **SA の数値一意 ID を使用**: `sub` にはメールアドレスではなく数値の一意 ID を使う（validation で強制）。トークンの `sub` クレームは一意 ID であることに加え、SA を削除→同名で再作成しても ID は変わるため、名前の再利用による意図しない信頼を防げる。
- **`google.subject` を認可に使わない**: AWS→GCP では `google.subject` にフル ARN（呼び出し側が自由に決められるセッション名を含む）をマッピングするが、これは監査用途のみ。認可は `attribute.aws_role`（ARN から抽出したロール名のみ）に基づく principalSet バインディングと、`attribute_condition`（自アカウントの assumed-role ARN + ロール名 allowlist）で二重に制限している。

## destroy 時の注意

- **Workload Identity Pool はソフト削除**される。削除後およそ 30 日間は同一 ID で再作成できないため、destroy → 即 apply のやり直しはできない（Pool ID を変えるか復元が必要）。
- `accounts.google.com` の OIDC プロバイダはアカウントに 1 つのみで、**他のシステムと共有している可能性がある**。共有が疑われる場合は最初から `create_google_oidc_provider = false` で運用し、このテンプレートの destroy で消さないこと。
- `create_role = false` の既存ロールと `create = false` の既存 SA は data 参照のみのため destroy では削除されない（バインディングとポリシーアタッチのみ削除される）。

## tfvars 運用

- このリポジトリはテンプレート集のため、同梱するのは雛形の `sample.tfvars` のみ。テンプレートを実プロジェクトで採用する際に、環境別の `dev.tfvars` / `stg.tfvars` / `prod.tfvars` を `cp sample.tfvars <env>.tfvars` で作成し、そのままリポジトリにコミットする（`.gitignore` は tfvars を除外していない）。
- 環境別 tfvars がコミットされていれば Jenkins のクリーンチェックアウトにも含まれるため、`Jenkinsfile` の `-var-file="${ENV}.tfvars"` はそのまま動く。Config File Provider 等での外部注入は不要。
- 機密値は tfvars に書かず、`TF_VAR_xxx` 環境変数や Secrets Manager で注入する（GCP サービスアカウントキーは Jenkins の Secret file を使用）。

## state の key 規約

backend は S3。key は Jenkins が生成する `backend.hcl` 経由で
`security/gcp-aws-workload-identity/${ENV}/terraform.tfstate` として渡す（versions.tf の backend ブロックには書かない）。
