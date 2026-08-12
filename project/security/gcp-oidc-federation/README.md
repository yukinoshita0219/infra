# security/gcp-oidc-federation

外部 OIDC IdP（GitHub Actions / GitLab CI / 任意の OIDC プロバイダ）から GCP への inbound フェデレーション（Workload
Identity Federation）を構成する Terraform テンプレート。 サービスアカウントキー（JSON）を配布せず、IdP が発行する短命の OIDC
トークンを STS で交換してサービスアカウントを impersonate（または直接リソースへアクセス）させる。

## 概要

- Workload Identity Pool（`google_iam_workload_identity_pool`）とその OIDC プロバイダ （
  `google_iam_workload_identity_pool_provider`）を作成する（既存がある場合は
  `create_pool = false` で参照）。
- `service_accounts` のエントリごとにサービスアカウントを作成（または既存を参照）し、 IdP の principal / principalSet に
  `roles/iam.workloadIdentityUser` を付与する。 必要ならプロジェクトロールも同時に付与する。
- `direct_access` を使うと、サービスアカウントを介さず principal / principalSet に直接 プロジェクトロールを付与できる（Direct
  Workload Identity Federation）。
- `env` スロットは環境ではなく **連携先 IdP 名**（例: `github` / `gitlab`）を担う。 dev / prod は state を分けず、
  `attribute_condition` と principal の絞り込み・権限で 作り分ける（後述）。

## セキュリティ設計の要点

- **`attribute_condition` は必須**: プロバイダを作成する場合（`create_pool = true`）は variable の validation
  で必須にしている。条件のないプロバイダは、その IdP が発行する **あらゆるトークン**を受け入れてしまう。GitHub Actions なら
  `assertion.repository_owner == '<owner>'` のように、まず組織（できればリポジトリ）まで絞る。
- **principal の絞り込みも必須**: `service_accounts` / `direct_access` の各エントリで
  `subjects` か `attributes` を 1 件以上必須にしている（validation で強制）。プールを信頼する だけの `principalSet://.../*`
  相当のバインドを作らせないため。
- **audience（`aud`）の既定はプロバイダ既定値**: `audiences` を空（既定）にすると、プロバイダの 完全リソース名（
  `//iam.googleapis.com/projects/.../providers/<id>`）そのものが唯一の許可 audience になる。これは **このプロバイダ専用**
  の値であり、他サービス向けに発行された トークンを構造的に受け付けない（confused deputy 対策として最も強い）。カスタム
  audience を 使う場合のみ `audiences` を指定する。
- **`google.subject` は完全一致、`attributes` は属性値の完全一致**: principalSet は 「属性 =
  値」の完全一致でしか絞れない（前方一致やワイルドカードは使えない）。ブランチや イベント種別で絞りたい場合は、
  `attribute_mapping` にその属性を定義してから
  `attributes` で値を指定する（例: `attribute.event = assertion.event_name` →
  `attributes = { event = ["pull_request"] }`）。
- **fork PR の構造的な安全性**: GitHub Actions では、fork からの PR で起動したワークフローには
  `id-token: write` が付与されない（OIDC トークンを取得できない）。そのため fork PR は そもそも高権限の SA を踏めない。
- **plan / apply の分割**: 読み取り専用の SA（`attributes = { event = ["pull_request"] }` などに 限定）と、書き込み可能な
  SA（`subjects` を `repo:<owner>/<repo>:ref:refs/heads/main` や
  `repo:<owner>/<repo>:environment:prod` に限定）を分け、PR 段階では書き込み権限を渡さない。

## 前提条件

- GCP プロジェクトで以下の API を有効化しておくこと:
  `iam.googleapis.com` / `sts.googleapis.com` / `iamcredentials.googleapis.com`
  （`direct_access` のみで運用する場合も STS は必要）。
- Terraform 実行主体には、対象プロジェクトの `roles/iam.workloadIdentityPoolAdmin`、 SA の作成・IAM 設定権限（
  `roles/iam.serviceAccountAdmin`）、プロジェクトロールを付与する 場合は `roles/resourcemanager.projectIamAdmin` 相当が必要。
- 認証はコードに書かず ADC（Application Default Credentials）を前提にしている。 Jenkins から実行する場合は
  `GCP_CREDENTIALS_ID` パラメータで Secret file を注入できる。
- **削除したプールの ID は約 30 日間再利用できない**（soft delete）。`destroy` 後に同じ
  `system_name` / `env` で作り直すと `pool_id` の衝突で失敗するため、その場合は `pool_id` /
  `provider_id` を明示して別 ID にする。
- `oidc_provider_url` には発行者ホスト（例: `token.actions.githubusercontent.com`）を、 **スキーム `https://` を付けずに**
  指定する（モジュール側で `https://` を付けて `issuer_uri` にする）。

## 既存プールにバインドする場合（create_pool = false）

既に組織で共有の Workload Identity Pool がある場合は、`create_pool = false` と
`existing_pool_id` を指定すると、プール・プロバイダを作らずにサービスアカウントの バインドと権限付与だけを行う。

- principalSet URI の組み立てにプロジェクト番号が必要なため、この場合のみ
  `data.google_project` を参照する（Terraform 実行主体にプロジェクト参照権限が必要）。
- `existing_provider_id` は バインドには不要だが、指定すると output
  `workload_identity_pool_provider_name` を解決できる（GitHub Actions に渡す値）。
- 既存プロバイダの `attribute_mapping` / `attribute_condition` は本テンプレートの管理外に なる。`attributes`
  で使う属性が既存プロバイダ側でマッピングされているかは自分で確認すること （`create_pool = false` の場合、attribute_mapping
  との整合チェックはスキップされる）。

## GitHub Actions 側の組み込み例

ワークフローに `id-token: write` 権限を付与し、`google-github-actions/auth` で トークンを交換する。

```yaml
permissions:
  id-token: write # OIDC トークンの取得に必須
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: google-github-actions/auth@v2
        with:
          # output workload_identity_pool_provider_name の値
          workload_identity_provider: projects/123456789/locations/global/workloadIdentityPools/app-github-pool/providers/app-github
          # output service_account_emails の値 (direct_access のみで使う場合は不要)
          service_account: app-github-apply@my-gcp-project.iam.gserviceaccount.com
      - run: gcloud storage ls
```

`service_account` を省略すると Direct Workload Identity Federation（`direct_access` で 付与した権限）で動作する。principal
の絞り込み条件とワークフローのトリガ （ブランチ / Environment / イベント）が一致しないとトークン交換に失敗する。

## 変数一覧

<!-- BEGIN_TF_DOCS -->

### Inputs

| Name                   | Description                                                                                                                                                      | Type                                                                                                                                                                                                                                                                                                                           | Default                                                    | Required |
|------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------|:--------:|
| env                    | 環境スロット。このテンプレートでは連携先 OIDC IdP の識別子 (例: github / gitlab) を指定する。dev/prod は state ではなく attribute 条件・権限で作り分ける         | `string`                                                                                                                                                                                                                                                                                                                       | n/a                                                        |   yes    |
| gcp\_project\_id       | GCPプロジェクトID                                                                                                                                                | `string`                                                                                                                                                                                                                                                                                                                       | n/a                                                        |   yes    |
| oidc\_provider\_url    | 外部 OIDC IdP の発行者ホスト (例: token.actions.githubusercontent.com)。スキーム https:// は付けない                                                             | `string`                                                                                                                                                                                                                                                                                                                       | n/a                                                        |   yes    |
| system\_name           | システム名 (Workload Identity Pool のID に使用するため英小文字・数字・ハイフンのみ)                                                                              | `string`                                                                                                                                                                                                                                                                                                                       | n/a                                                        |   yes    |
| attribute\_condition   | プロバイダが受け入れるトークンを絞る CEL 条件式 (例: assertion.repository\_owner == 'my-org')。create\_pool = true の場合は必須                                  | `string`                                                                                                                                                                                                                                                                                                                       | `null`                                                     |    no    |
| attribute\_mapping     | IdP のクレームから Google の属性へのマッピング。google.subject は必須。attribute.<名前> で定義した属性を attribute\_condition や principalSet の絞り込みに使える | `map(string)`                                                                                                                                                                                                                                                                                                                  | <pre>{<br/>  "google.subject": "assertion.sub"<br/>}</pre> |    no    |
| audiences              | 受け入れる OIDC トークンの audience (aud) のリスト。空リストの場合はプロバイダ既定の audience (プロバイダの完全リソース名) のみを受け入れる                      | `list(string)`                                                                                                                                                                                                                                                                                                                 | `[]`                                                       |    no    |
| create\_pool           | Workload Identity Pool とプロバイダを作成するか。既にあるプールにサービスアカウントのバインドだけ追加する場合は false にする                                     | `bool`                                                                                                                                                                                                                                                                                                                         | `true`                                                     |    no    |
| direct\_access         | サービスアカウントを経由せず、principal / principalSet に直接プロジェクトロールを付与する定義 (Direct Workload Identity Federation)。キーは識別子                | <pre>map(object({<br/>    subjects      = optional(list(string), [])<br/>    attributes    = optional(map(list(string)), {})<br/>    project_roles = list(string)<br/>  }))</pre>                                                                                                                                              | `{}`                                                       |    no    |
| existing\_pool\_id     | 参照する既存 Workload Identity Pool のID。create\_pool = false の場合は必須                                                                                      | `string`                                                                                                                                                                                                                                                                                                                       | `null`                                                     |    no    |
| existing\_provider\_id | 参照する既存 Workload Identity Pool プロバイダのID。バインドには不要だが、指定すると output workload\_identity\_pool\_provider\_name を解決できる                | `string`                                                                                                                                                                                                                                                                                                                       | `null`                                                     |    no    |
| pool\_id               | Workload Identity Pool のID。null の場合は <system\_name>-<env>-pool になる                                                                                      | `string`                                                                                                                                                                                                                                                                                                                       | `null`                                                     |    no    |
| provider\_id           | Workload Identity Pool プロバイダのID。null の場合は <system\_name>-<env> になる                                                                                 | `string`                                                                                                                                                                                                                                                                                                                       | `null`                                                     |    no    |
| service\_accounts      | OIDC IdP からの impersonate を許可するサービスアカウントの定義。キーは SA の account\_id (ロール名のような system\_name/env のプレフィックスは付かない)          | <pre>map(object({<br/>    subjects      = optional(list(string), [])<br/>    attributes    = optional(map(list(string)), {})<br/>    create        = optional(bool, true)<br/>    email         = optional(string)<br/>    display_name  = optional(string)<br/>    project_roles = optional(list(string), [])<br/>  }))</pre> | `{}`                                                       |    no    |

### Outputs

| Name                                     | Description                                                                                                                                                                                |
|------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| audiences                                | 受け入れる audience のリスト。空の場合はプロバイダ既定の audience (プロバイダの完全リソース名) のみを受け入れる                                                                            |
| direct\_access\_members                  | direct\_access のエントリごとにプロジェクトロールを付与した principal / principalSet URI                                                                                                   |
| service\_account\_emails                 | impersonate 対象サービスアカウントのメールアドレス (作成・既存を合成)                                                                                                                      |
| service\_account\_members                | サービスアカウントごとに roles/iam.workloadIdentityUser を付与した principal / principalSet URI                                                                                            |
| workload\_identity\_pool\_id             | Workload Identity Pool のID (作成した場合は生成ID、既存参照の場合は existing\_pool\_id)                                                                                                    |
| workload\_identity\_pool\_name           | Workload Identity Pool の完全リソース名                                                                                                                                                    |
| workload\_identity\_pool\_provider\_id   | Workload Identity Pool プロバイダのID (作成した場合は生成ID、既存参照の場合は existing\_provider\_id)                                                                                      |
| workload\_identity\_pool\_provider\_name | Workload Identity Pool プロバイダの完全リソース名。google-github-actions/auth の workload\_identity\_provider にそのまま指定できる (既存参照で existing\_provider\_id 未指定の場合は null) |

<!-- END_TF_DOCS -->

### service_accounts のエントリ

キーがサービスアカウントの `account_id`（6〜30 文字）。AWS 版のロール名と異なり
`<system_name>-<env>-` のプレフィックスは付かない（`account_id` の 30 文字制限のため）。

| 属性            | 説明                                                                                                             | デフォルト |
|-----------------|------------------------------------------------------------------------------------------------------------------|------------|
| `subjects`      | `google.subject` の完全一致リスト（`principal://.../subject/<値>`）                                              | `[]`       |
| `attributes`    | 属性名 → 値リスト（`principalSet://.../attribute.<属性>/<値>`）。属性は `attribute_mapping` に定義済みであること | `{}`       |
| `create`        | サービスアカウントを新規作成するか。false なら既存を参照                                                         | `true`     |
| `email`         | 既存 SA のメールアドレス（`create = false` のとき必須）                                                          | `null`     |
| `display_name`  | 作成する SA の表示名                                                                                             | `null`     |
| `project_roles` | SA に付与するプロジェクトロール（`roles/` で始まる文字列）                                                       | `[]`       |

`subjects` と `attributes` は **少なくとも一方が 1 件以上必須**。両方指定した場合は それぞれが独立したバインドになる（AND
条件にはならない）。

### direct_access のエントリ

| 属性            | 説明                                                      | デフォルト |
|-----------------|-----------------------------------------------------------|------------|
| `subjects`      | `google.subject` の完全一致リスト                         | `[]`       |
| `attributes`    | 属性名 → 値リスト                                         | `{}`       |
| `project_roles` | principal / principalSet に直接付与するプロジェクトロール | (必須)     |

## dev / prod の作り分け方針

- この `env` スロットは **IdP 名**（`github` など）を表す。環境ごとに state を分けない。
- dev / prod は同一 state 内で、`service_accounts` のキーと principal の絞り込み・付与権限で 作り分ける（例:
  `app-github-apply-prod` は `subjects` を `environment:prod` に、
  `app-github-apply-dev` は `ref:refs/heads/develop` に絞る）。同じプール・プロバイダを 全 SA で共有する。
- 環境ごとに GCP プロジェクトが分かれている場合は、プロジェクトごとに `env` スロットを 分ける（例: `github-dev` /
  `github-prod`）ほうが素直。

## tfvars 運用

- このリポジトリはテンプレート集のため、同梱するのは雛形の `sample.tfvars` のみ。テンプレートを 実プロジェクトで採用する際に、IdP
  別の `<idp>.tfvars`（例: `github.tfvars`）を
  `cp sample.tfvars <idp>.tfvars` で作成し、そのままリポジトリにコミットする。
- IdP 別 tfvars がコミットされていれば Jenkins のクリーンチェックアウトにも含まれるため、
  `Jenkinsfile` の `-var-file="${ENV}.tfvars"` はそのまま動く。
- 機密値は tfvars に書かず、`TF_VAR_xxx` 環境変数や Secret Manager で注入する。
  `<owner>/<repo>` はプレースホルダのため、採用時に実際の値へ置き換えること。

## state の key 規約

backend は S3（このリポジトリ共通）。key は Jenkins が生成する `backend.hcl` 経由で
`security/gcp-oidc-federation/${ENV}/terraform.tfstate` として渡す（`versions.tf` の backend ブロックには書かない）。
`${ENV}` は IdP スロット名（`github` など）。
