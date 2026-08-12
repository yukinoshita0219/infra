英語の後に日本語があります。

---

***English***

# Infrastructure as Code (IaC) by Terraform

## Overview

This repository provides useful Terraform IaC templates along with Jenkins pipelines for CI/CD.

## Directory Structure

```text
infra/
├── config/                              # Auto-generated configurations (e.g., backend.hcl)
└── project/
    ├── database/
    │   ├── aws-aurora-mysql/            # Aurora MySQL cluster
    │   ├── aws-elasticache-memcached/   # ElastiCache (Memcached)
    │   └── aws-elasticache-valkey/      # ElastiCache (Valkey)
    ├── queue/
    │   └── aws-sqs/                     # SQS queues
    ├── security/
    │   ├── aws-oidc-federation/         # External OIDC IdP -> AWS federation
    │   ├── gcp-aws-workload-identity/   # GCP <-> AWS workload identity federation
    │   └── gcp-oidc-federation/         # External OIDC IdP -> GCP federation
    ├── storage/
    │   └── gcp-cloud-storage/           # GCS buckets
    └── terraform-backend/               # Terraform state backend bootstrap (CloudFormation)
        ├── backend.sample.hcl           # Sample backend.hcl config file
        ├── cfn-terraform-backend.yaml   # CloudFormation template
        └── Jenkinsfile
```

Each Terraform template directory contains `Jenkinsfile`, `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md`, and `sample.tfvars`. This repository is a **template collection**, so each template ships only the `sample.tfvars` skeleton — per-environment tfvars files (`dev.tfvars` / `stg.tfvars` / `prod.tfvars`) are not created in this repository. When adopting a template for a real project, create them with `cp sample.tfvars <env>.tfvars` and **commit them as-is** (`.gitignore` does not exclude tfvars).

## Using the Templates

All templates share the same Jenkins pipeline pattern: **plan → manual approval → apply the saved plan file**.

1. **Create a Jenkins job:** Create a Pipeline job pointing at the template's `Jenkinsfile` (e.g., `project/queue/aws-sqs/Jenkinsfile`).
2. **Create `<ENV>.tfvars` (when adopting the template):** When adopting the template for a real project, create per-environment tfvars from the skeleton (`cp sample.tfvars <env>.tfvars` for `dev` / `stg` / `prod`) and **commit them to the repository**. Committed tfvars are included in Jenkins's clean checkout, so the `Jenkinsfile`'s `-var-file="${ENV}.tfvars"` works as-is — no external injection (e.g., Config File Provider) is needed.
3. **Run with parameters:**
   * `ACTION`: `apply` or `destroy`
   * `ENV`: `dev` / `stg` / `prod`
   * `AWS_REGION`: AWS region (default: `ap-northeast-1`)
   * `AWS_PROFILE`: AWS CLI profile name
   * `BACKEND_STACK_NAME`: CloudFormation stack name of the state backend (default: `terraform-backend`)
4. **Backend config generation:** The pipeline resolves the S3 bucket name from the CloudFormation stack and generates `config/backend.hcl`, including the state key following the convention `<category>/<template>/<ENV>/terraform.tfstate`. Then it runs `terraform init`.
5. **Plan:** `terraform plan -var-file=<ENV>.tfvars -out=tfplan` (for `destroy`, `terraform plan -destroy ...`).
6. **Approval:** The pipeline pauses for manual approval. Review the plan output before proceeding.
7. **Apply:** `terraform apply tfplan` — the saved plan file is applied, so exactly what was reviewed is executed.

### Notes on destroy

* `ACTION=destroy` produces a destroy plan and, after approval, deletes **all resources managed by that state**. Double-check `ENV` before approving.
* Some resources may have deletion protection or final snapshot settings; review the destroy plan carefully.

## CI

Pull requests to `main` are checked by GitHub Actions (`.github/workflows/ci.yml`) with four parallel jobs:

| Job | Check |
|---|---|
| `validate` | `terraform fmt -check` and `terraform validate` for every template |
| `tflint` | TFLint with the AWS / Google rulesets (config: `.tflint.hcl`) |
| `trivy` | Misconfiguration scan; HIGH/CRITICAL findings fail (exceptions: `.trivyignore`) |
| `docs` | Freshness check of the terraform-docs-generated tables in each template README |

### Before committing

Install the tools once (`brew install tflint trivy terraform-docs`), then run from the repository root:

```bash
# Formatting (whole repo)
terraform fmt -recursive project/

# For each template you touched
terraform -chdir=project/<category>/<template> init -backend=false
terraform -chdir=project/<category>/<template> validate
tflint --config "$PWD/.tflint.hcl" --chdir project/<category>/<template>

# Required whenever variables.tf / outputs.tf changed: regenerate the README tables
terraform-docs -c .terraform-docs.yml project/<category>/<template>

# Security scan (same as CI)
trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore project/
```

Forgetting the `terraform-docs` regeneration is the most common CI failure: the `docs` job fails whenever a README table is out of sync with `variables.tf` / `outputs.tf`.

## Operational Conventions

* **Environment names:** Unified as `dev` / `stg` / `prod`.
* **tfvars:** This repository is a template collection and ships only the `sample.tfvars` skeleton per template. When adopting a template for a real project, create per-environment tfvars (`dev.tfvars` / `stg.tfvars` / `prod.tfvars`) with `cp sample.tfvars <env>.tfvars` and **commit them to the repository** (`.gitignore` does not exclude tfvars), so Jenkins picks them up from the clean checkout with no extra setup. Never put secrets (passwords, private keys, tokens, etc.) in tfvars; inject them via `TF_VAR_*` environment variables or AWS Secrets Manager.
* **State key:** `<category>/<template>/<ENV>/terraform.tfstate` (appended by Jenkins when generating `backend.hcl`).
* **Provider versions:** AWS is unified as `~> 5.73`; Google as `~> 6.0`.
* **`.terraform.lock.hcl`:** Not generated yet in this repository. Committing it after running `terraform init` locally is recommended to pin provider versions.

## Setup (terraform-backend)

Terraform requires a backend to store state files.

There are many options, and this repository provides a CloudFormation template for AWS S3.

### Prerequisites

* **Terraform:** v1.10.0 or later (Required for S3 Native Locking)
* **AWS CLI:** Installed and configured on the Jenkins agent
* **Jenkins:** With pipeline execution capabilities

### Key Features

* **DynamoDB-Free Locking:** Uses S3 native lock files (`use_lockfile = true`) for state management.
* **Strict Security Guardrails:** The S3 Bucket Policy includes an **Explicit Deny** to block all access except from the
  specific IAM Role/User executing the Jenkins pipeline, and enforces HTTPS connections.
* **Dynamic Configuration:** The Jenkins pipeline dynamically resolves the executor's AWS ARN and generates a reusable
  `backend.hcl` using the `writeFile` step.

### How It Works

1. **Identity Resolution:** Jenkins resolves its current AWS IAM Identity (Role or User) via
   `aws sts get-caller-identity`. Additional principals can be allowed via the
   `ADDITIONAL_ALLOWED_IAM_ARNS` parameter (comma-delimited, wildcards allowed).
2. **Bootstrap Backend:** Creates a CloudFormation **Change Set**, pauses for manual review/approval, then executes
   it to create/update the S3 bucket with a strict bucket policy restricting access to the allowed identities.
3. **Generate Config:** Retrieves the generated bucket name and writes to `config/backend.hcl`.
4. **Terraform Init (per template):** Each template's pipeline appends the state key
   (`<category>/<template>/<ENV>/terraform.tfstate`) and runs `terraform init` with the generated backend configuration.

---

🇯🇵 ***日本語***

# TerraformによるInfrastructure as Code (IaC)

## 概要

便利なTerraform IaCテンプレートとCI/CD用のJenkinsパイプライン

## ディレクトリ構成

```text
infra/
├── config/                              # 自動生成される設定ファイル配置場所 (backend.hcl 等)
└── project/
    ├── database/
    │   ├── aws-aurora-mysql/            # Aurora MySQL クラスタ
    │   ├── aws-elasticache-memcached/   # ElastiCache (Memcached)
    │   └── aws-elasticache-valkey/      # ElastiCache (Valkey)
    ├── queue/
    │   └── aws-sqs/                     # SQS キュー
    ├── security/
    │   ├── aws-oidc-federation/         # 外部 OIDC IdP → AWS 連携
    │   ├── gcp-aws-workload-identity/   # GCP ⇔ AWS Workload Identity 連携
    │   └── gcp-oidc-federation/         # 外部 OIDC IdP → GCP 連携
    ├── storage/
    │   └── gcp-cloud-storage/           # GCS バケット
    └── terraform-backend/               # Terraform ステートバックエンド構築 (CloudFormation)
        ├── backend.sample.hcl           # backend.hcl 設定ファイルのサンプル
        ├── cfn-terraform-backend.yaml   # CloudFormation テンプレート
        └── Jenkinsfile
```

各Terraformテンプレートディレクトリには `Jenkinsfile`・`main.tf`・`variables.tf`・`outputs.tf`・`versions.tf`・`README.md`・`sample.tfvars` を配置。このリポジトリは**テンプレート集**のため、各テンプレートに同梱するのは雛形の `sample.tfvars` のみで、環境別tfvars（`dev.tfvars` / `stg.tfvars` / `prod.tfvars`）はこのリポジトリでは作成しない。テンプレートを実プロジェクトで採用する際に `cp sample.tfvars <env>.tfvars` で作成し、**そのままリポジトリにコミットする**（`.gitignore` はtfvarsを除外していない）

## テンプレートの利用フロー

全テンプレート共通のJenkinsパイプラインパターン: **plan → 手動承認 → 保存済みplanファイルをapply**

1. **Jenkinsジョブの作成:** テンプレートの `Jenkinsfile`（例: `project/queue/aws-sqs/Jenkinsfile`）を指すPipelineジョブを作成
2. **`<ENV>.tfvars` の作成（テンプレート採用時）:** テンプレートを実プロジェクトで採用する際に、雛形から `cp sample.tfvars <env>.tfvars`（`dev` / `stg` / `prod`）で作成し、**リポジトリにコミットする**。コミットされていればクリーンチェックアウトにも含まれるため、`Jenkinsfile` の `-var-file="${ENV}.tfvars"` はそのまま動く（Config File Provider等での外部注入は不要）
3. **パラメータを指定して実行:**
   * `ACTION`: `apply` または `destroy`
   * `ENV`: `dev` / `stg` / `prod`
   * `AWS_REGION`: AWSリージョン（デフォルト: `ap-northeast-1`）
   * `AWS_PROFILE`: AWS CLIのプロファイル名
   * `BACKEND_STACK_NAME`: ステートバックエンドのCloudFormationスタック名（デフォルト: `terraform-backend`）
4. **backend設定の生成:** パイプラインがCloudFormationスタックからS3バケット名を解決し、`<カテゴリ>/<テンプレート名>/<ENV>/terraform.tfstate` 規約のstateキーを含む `config/backend.hcl` を生成して `terraform init` を実行
5. **Plan:** `terraform plan -var-file=<ENV>.tfvars -out=tfplan`（`destroy` の場合は `terraform plan -destroy ...`）
6. **承認:** パイプラインが手動承認で一時停止。plan結果を確認してから承認する
7. **Apply:** `terraform apply tfplan` — 保存済みplanファイルを適用するため、確認した内容がそのまま実行される

### destroy時の注意

* `ACTION=destroy` はdestroy planを生成し、承認後に**そのstateで管理されている全リソースを削除**する。承認前に `ENV` を必ず再確認すること
* 削除保護や最終スナップショット設定を持つリソースが含まれる場合があるため、destroy planを慎重に確認すること

## CI

`main` への Pull Request は GitHub Actions（`.github/workflows/ci.yml`）で 4 つのジョブが並列にチェックする:

| ジョブ | チェック内容 |
|---|---|
| `validate` | 全テンプレートの `terraform fmt -check` と `terraform validate` |
| `tflint` | AWS / Google ルールセット付き TFLint（設定: `.tflint.hcl`） |
| `trivy` | 設定ミスのセキュリティスキャン。HIGH/CRITICAL で失敗（例外は `.trivyignore`） |
| `docs` | 各テンプレート README 内の terraform-docs 生成テーブルが最新かの検査 |

### コミット前にやること

ツールを未導入なら `brew install tflint trivy terraform-docs` で導入した上で、リポジトリルートから実行する:

```bash
# フォーマット (リポジトリ全体)
terraform fmt -recursive project/

# 変更したテンプレートごと
terraform -chdir=project/<カテゴリ>/<テンプレート> init -backend=false
terraform -chdir=project/<カテゴリ>/<テンプレート> validate
tflint --config "$PWD/.tflint.hcl" --chdir project/<カテゴリ>/<テンプレート>

# variables.tf / outputs.tf を変更した場合は必須: READMEのテーブルを再生成
terraform-docs -c .terraform-docs.yml project/<カテゴリ>/<テンプレート>

# セキュリティスキャン (CIと同一)
trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore project/
```

CI 落ちで最も多いのは `terraform-docs` の再生成忘れ。README のテーブルが `variables.tf` / `outputs.tf` とずれていると `docs` ジョブが失敗する。

## 運用規約

* **環境名:** `dev` / `stg` / `prod` に統一
* **tfvars:** このリポジトリはテンプレート集のため、各テンプレートに同梱するのは雛形の**`sample.tfvars` のみ**。実プロジェクトで採用する際に環境別tfvars（`dev.tfvars` / `stg.tfvars` / `prod.tfvars`）を `cp sample.tfvars <env>.tfvars` で作成し、**そのままリポジトリにコミットする**（`.gitignore` はtfvarsを除外していない）。コミットされていればJenkinsのクリーンチェックアウトにも含まれるため、外部からの事前配置は不要。機密値（パスワード・秘密鍵・トークン等）はtfvarsに書かず、`TF_VAR_*` 環境変数またはAWS Secrets Managerで注入する
* **stateキー:** `<カテゴリ>/<テンプレート名>/<ENV>/terraform.tfstate`（Jenkinsが `backend.hcl` 生成時に付与）
* **プロバイダのバージョン:** AWS は `~> 5.73`、Google は `~> 6.0` に統一
* **`.terraform.lock.hcl`:** 現状未生成。プロバイダのバージョン固定のため、各自 `terraform init` 実行後にコミットすることを推奨

## セットアップ (terraform-backend)

Terraformはステートファイルを保存するためのバックエンドが必要

様々な選択肢があるが、ここではAWS S3用のCloudFormationテンプレートを提供している。

### 前提条件

* **Terraform:** v1.10.0 以上 (S3ネイティブロックに必須)
* **AWS CLI:** Jenkinsエージェントにインストールおよび設定済みであること
* **Jenkins:** パイプライン実行環境

### 主な特徴

* **DynamoDB不要のロック機構:** ステート管理にS3ネイティブロック (`use_lockfile = true`) を使用
* **強固なセキュリティガードレール:** S3バケットポリシーに **明示的な拒否（Explicit Deny）**
  を設定し、Jenkinsパイプラインを実行する特定のIAMロール/ユーザー以外からのアクセスを完全に遮断し、HTTPS通信を強制
* **動的な設定ファイル生成:** Jenkinsパイプライン内で実行者のAWS ARNを動的に解決し、`writeFile` ステップを使用して再利用可能な
  `backend.hcl` を自動生成

### 実行フロー

1. **IAM認証情報の解決:** Jenkinsが `aws sts get-caller-identity` を使用し、自身の現在のAWS IAM Identity（ロールまたはユーザー）を解決。`ADDITIONAL_ALLOWED_IAM_ARNS` パラメータ（カンマ区切り・ワイルドカード可）で追加のプリンシパルも許可可能
2. **バックエンドの構築:** CloudFormationの**Change Set**を作成し、内容の手動確認・承認を経て実行。S3バケットを作成/更新し、許可されたIdentityのみにアクセスを制限する強固なバケットポリシーを適用
3. **設定ファイルの生成:** 生成されたバケット名を取得し、`config/backend.hcl` に書き出す
4. **Terraformの初期化（各テンプレート側）:** 各テンプレートのパイプラインがstateキー（`<カテゴリ>/<テンプレート名>/<ENV>/terraform.tfstate`）を付与して `terraform init` を実行
