# ai-disclosure-crosscheck

[English README is here](./README.md)

読み取り専用・リポジトリ横断型のlinterです。サーバー側から外部のAI API（OpenAI、Anthropic、Gemini、Mistralなど）を呼び出している場合に、そのAI利用がユーザーに対して実際に開示されているか——クライアントアプリのUI内か、公開されているプライバシーポリシー内か——を、App Store審査に提出する前に確認します。

## このツールが埋めるギャップ

App Store提出前チェックのスキャナーの多くは、**単一リポジトリ・クライアントのみ**を対象にしています。iOS/Androidクライアントのソースコードを見て、AI SDKの使用箇所を検出し、そのクライアント自身が開示文言を表示しているかどうかをチェックする、というものです。AI呼び出しがクライアントから直接行われている場合はこれで機能します。

しかし、AI呼び出しが**バックエンド**に移った瞬間、これは機能しなくなります。よくある構成として、ユーザーの入力を自社サーバーに送り、そのサーバーがユーザーの代わりにOpenAI/Anthropicなどを呼び出す、というアーキテクチャがあります。クライアントのみを見るスキャナーは、このサーバー側の呼び出しを検出できません——クライアントのリポジトリの中には見つけるものが何もないからです。結果として「クリーン」という判定が出てしまいますが、実際にはApp Store審査ガイドライン5.1.1 / 5.1.2(i)が求める開示がなされていない可能性があります。

このツールは、実際のプロジェクトでそのギャップを確認した上で作られました。クライアントのみを見るスキャナーはクライアント側リポジトリではクリーンな結果を返しましたが、サーバー側リポジトリでは外部AI APIへの未開示の呼び出しが行われていました。これは仮説上の話ではなく、このツールが対処する具体的な失敗パターンです。

`ai-disclosure-crosscheck`は、1つではなく**3つの入力信号**を受け取ることでこのギャップを埋めます。

| 信号 | 確認する内容 | 入力元 |
|---|---|---|
| A — サーバー側のAI呼び出し | サーバーコードが既知のAIプロバイダーのSDKやエンドポイントを呼び出しているか | `--server-dir` |
| B — クライアント側の開示 | クライアント向けの文言のいずれかが、そのプロバイダー名を含んでいるか | `--client-dir` |
| C — ポリシー上の開示 | 公開されているプライバシーポリシーが、AI/機械学習を示すキーワードと同じ文・ブロック内でそのプロバイダー名に言及しているか | `--policy-file`（省略可） |

この3つの信号を突き合わせ、以下のマトリクスに沿って1つの判定を出します。

## 判定マトリクス

| サーバー呼び出し(A) | クライアントで開示(B) | ポリシーで開示(C) | 判定 |
|---|---|---|---|
| no | – | – | （検出なし——ルールが発火しない） |
| yes | yes | – | **PASS** |
| yes | no | yes | **WARN** — ポリシーのみの開示。2026年時点のApple審査実務では、アプリ内の同意画面がない場合、これを不十分とみなす可能性がある |
| yes | no | no（`--policy-file`指定あり） | **FAIL** — どの同意面にもプロバイダー名の記載がない |
| yes | no | 未チェック（`--policy-file`未指定） | **WARN** — 判断材料不足。`--policy-file`を指定して再実行を推奨 |

## インストール

```bash
npx ai-disclosure-crosscheck --client-dir <path> --server-dir <path> --policy-file <path>
```

`PATH`上に`bash`、`grep`、`find`があれば動作します。認証情報も、ネットワークアクセスも、テレメトリも不要です——すべて自分のソースツリーに対してローカルで実行されます。

## 使い方

```bash
ai-disclosure-crosscheck \
  --client-dir  ./ios/App \
  --server-dir  ./backend \
  --policy-file ./legal/privacy-policy.html \
  [--format text|json] \
  [--fail-on warn|fail] \
  [--config .ai-disclosure-crosscheck.json]
```

例（WARNケース——サーバーがOpenAIを呼び出しており、ポリシーには開示があるが、クライアント側の文言にはプロバイダー名が出てこない場合）。

```
WARN: cross-repo-ai-consent-mismatch — OpenAI endpoint/SDK present in --server-dir
(backend/client.js); the public policy document discloses OpenAI, but no
client-facing string under --client-dir names the provider. Apple 5.1.1/5.1.2(i)
2026 review practice may treat policy-only disclosure as insufficient without
an in-app consent screen naming the provider.
      policy evidence: legal/privacy-policy.html:2
      server evidence: backend/client.js
SUMMARY: fail=0 warn=1 pass=0 suppressed=0
```

`--format json`を指定すると、構造化されたJSON形式で出力されます。

```json
{
  "tool": "ai-disclosure-crosscheck",
  "version": "0.1.0",
  "findings": [{
    "rule_id": "cross-repo-ai-consent-mismatch",
    "severity": "warn",
    "guideline": "5.1.1 / 5.1.2(i)",
    "provider": "OpenAI",
    "evidence": {
      "server_ai_call": {"file": "backend/client.js", "line": null},
      "client_ui_disclosure": null,
      "policy_disclosure": {"file": "legal/privacy-policy.html", "line": 2}
    },
    "suppressed": false
  }],
  "verdict": "WARN",
  "summary": {"fail": 0, "warn": 1, "pass": 0, "suppressed": 0}
}
```

### オプション

| フラグ | 説明 |
|---|---|
| `--client-dir <path>` | クライアント/UI側のソースディレクトリ（必須。`--config`経由での指定でも可） |
| `--server-dir <path>` | AI API呼び出しを検出するサーバー側ソースディレクトリ（必須。`--config`経由での指定でも可） |
| `--policy-file <path>` | 公開プライバシーポリシー文書（HTMLまたはMarkdown）。省略可だが強く推奨 |
| `--format <fmt>` | `text`（デフォルト）または`json` |
| `--fail-on <level>` | `warn`または`fail`（デフォルト`fail`）——指定した深刻度以上で終了コード1を返す |
| `--config <path>` | `.ai-disclosure-crosscheck.json`へのパス（カレントディレクトリに存在すれば自動検出） |

`--config`の例（`.ai-disclosure-crosscheck.json`）。

```json
{
  "clientDir": "ios/App",
  "serverDir": "backend",
  "policyFile": "legal/privacy-policy.html"
}
```

CLIフラグは常に設定ファイルより優先されます。設定ファイルは、CLIで指定されなかった値のみを補います。これはCI利用を想定した仕組みで、毎回同じ3つのパスを指定し直す必要がなくなります。

### 検出結果を抑制する

作業ディレクトリに置く`.precheck-ignore`ファイルで、以下がサポートされます。

```
# comment
cross-repo-ai-consent-mismatch                 # ルールを全体で抑制
cross-repo-ai-consent-mismatch  path/glob/**    # このパス配下のみ抑制
path/glob/**                                    # このパスをスキャン対象から除外
```

### 終了コード

`0` 正常 · `1` `--fail-on`で指定した深刻度以上の判定 · `64` 使用方法エラー · `70` 実行環境エラー（bashまたは同梱スキャナーが見つからない）

## サポートされているプロバイダー

検出はシグネチャベースで、[`scripts/lib/providers.conf`](scripts/lib/providers.conf)に定義されています（SDKのインポート指定子、またはAPIホスト名で判定）。対応プロバイダー: OpenAI、Anthropic、Gemini、Mistral、OpenRouter、Groq、Perplexity、Together。プロバイダーの追加は、このファイルへのタブ区切り1行の追加のみで済み、`scan.sh`の変更は不要です。他プロバイダー対応のPull Requestを歓迎します。

現状の対象範囲はNode.js/JavaScript/TypeScriptのサーバーコード（`require()` / `import`指定子およびエンドポイントのリテラル）です。他言語・他ランタイムへのサーバー側検出の拡張に関するコントリビューションを歓迎します——拡張時のinclude-filterパターンは`scripts/lib/prune.sh`を参照してください。

## 設計方針

- **bash/grep/find以外の依存なし。** コアのスキャン処理（`bin/cli.js`は`npx`用の薄いラッパーに過ぎません。`scripts/scan.sh`を直接呼び出すこともできます）に`jq`、`python3`、Node.jsは不要です。
- **読み取り専用。** このツールはソースコードを変更せず、ネットワーク通信も行わず、どこにも何も送信しません。
- **単一責任。** このツールが答えるのは「検出したサーバー側のAI呼び出しについて、そのプロバイダーが*どこかで*開示されているか」という1つの問いだけです。App Store審査全体をカバーするlintは他のツールに委ね、クライアントのみを見るスキャナーを置き換えるのではなく、並行して使うことを想定しています。

## テスト

```bash
npm test
```

29件のブラックボックステストが、引数パース、設定ファイルとのマージ、全信号パターンにおけるPASS/WARN/FAILマトリクス、`.precheck-ignore`による抑制、CLIラッパーの終了コード伝播をカバーしています。

## ライセンス

MIT — [LICENSE](LICENSE)を参照してください。
