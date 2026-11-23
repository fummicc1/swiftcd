# SwiftCD

Swiftで作る、ローカルで完結するミニArgoCDです。Gitリポジトリのマニフェストを、kindで立てたローカルのKubernetesへ同期します。

## 仕組み

```
Application定義 (examples/apps/*.yaml)
        │
        ▼
AppController (アプリごとのactor, 既定30秒ごと)
  1. git clone / fetch → targetRevisionをcheckout      … GitClient
  2. YAMLを読み、管理ラベルを付けてList(JSON)にまとめる … ManifestRenderer
  3. kubectl diff --server-side で差分を検出           … ClusterClient
  4. automated かつ未Syncのリビジョンなら kubectl apply --server-side
  5. ライブの状態からHealthを判定                       … HealthAssessor
        │
        ▼
AppStore ── HTTP API (Hummingbird) ── Web UI / swiftcd CLI
```

| ArgoCDの概念 | SwiftCDでの実装 |
|---|---|
| Application CRD | `examples/apps/*.yaml` |
| repo-server | `ManifestRenderer`（プレーンなYAMLだけ対応） |
| application-controller | `AppController` |
| Sync Status | `kubectl diff` の終了コード（0=Synced、1=OutOfSync） |
| Health Status | `HealthAssessor`（Deployment / StatefulSet / ReplicaSet / Pod） |
| 管理対象の識別 | ラベル `swiftcd.io/app=<name>` |

ソースのディレクトリ構成は [docs/directory-structure.md](docs/directory-structure.md) にまとめています。

### Prune

Gitからマニフェストを消したリソースは、Refreshで「Prune が必要」と表示され、アプリはOutOfSyncになります。SwiftCDは、namespace内で `swiftcd.io/app=<name>` ラベルが付いているのにGitに無いリソースを、prune対象として探します。ただし `ownerReferences` を持つもの（Deploymentが作ったReplicaSetなど）と、Serviceのラベルがコピーされる Endpoints / EndpointSlice は対象にしません。

既定では削除しません。削除するのは次のどちらかのときだけです。

- 手動Syncでpruneを指定したとき（`swiftcd app sync <name> --prune`、UIの「Sync + Prune」ボタン、`POST /api/apps/:name/sync?prune=true`）
- Application定義に `syncPolicy.prune: true` を書いたとき（自動Syncでも削除します）

### 自動Sync

自動Syncは、ArgoCDと同じく「まだSyncしていないリビジョン」だけが対象です。`kubectl scale` などの手動変更はOutOfSyncと表示しますが、元には戻しません（self-healは未対応）。

## 必要なもの

- Xcodeに入っているSwift 6.x（`.swift-version` でswiftlyに `xcode` を指定しています）
- Docker（Docker Desktopなど）が起動していること
- `kind`、`kubectl`、`git`

## 使い方

```bash
# 1. kindクラスタ "swiftcd" を作る
./scripts/setup-kind.sh

# 2. サーバーを起動する（既定で kubectl context は kind-swiftcd）
swift run swiftcd-server --apps examples/apps
# → http://127.0.0.1:8080 をブラウザで開く

# 3. 別のターミナルでCLIから操作する
swift run swiftcd app list
swift run swiftcd app get guestbook
swift run swiftcd app sync guestbook-staging

# 4. マニフェストのリポジトリを変更してpushし、自動で同期されるのを見る
cd ../swiftcd-demo-manifests
perl -pi -e 's/replicas: 1/replicas: 3/' guestbook/deployment.yaml
git commit -am "scale to 3" && git push
```

`examples/apps/*.yaml` は GitHub の公開リポジトリ [fummicc1/swiftcd-demo-manifests](https://github.com/fummicc1/swiftcd-demo-manifests) をHTTPSでポーリングします（認証は不要）。`guestbook` は自動Sync、`guestbook-staging` は手動Sync（UIのSyncボタンかCLIで同期）の例です。

`repoURL` にはローカルのパスも書けます。GitHubを使わずに試す場合は `./scripts/init-demo-repo.sh` で `~/.swiftcd/demo-repo` を作り、`repoURL: ~/.swiftcd/demo-repo` にしてください（E2Eもこの方法でローカルリポジトリを使います）。

サーバーのオプションは `swift run swiftcd-server --help` で確認できます（`--interval`、`--port`、`--context`、`--work-dir`、`--command-timeout`）。

## テスト

```bash
swift test          # 単体テスト（Fakeを使うのでクラスタは不要）
./scripts/e2e.sh    # kindでのE2E（初回同期 → 自動同期 → ドリフト検出 → 手動Sync）
```

## API

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/api/apps` | 全アプリの状態 |
| GET | `/api/apps/:name` | 1つのアプリの状態 |
| POST | `/api/apps/:name/refresh` | Gitとクラスタを再比較する |
| POST | `/api/apps/:name/sync` | 同期する |

## 未対応（今後の候補）

- self-heal
- namespaceを持たないリソース（ClusterRoleなど）のprune
- Git webhook、Kustomize / Helm のレンダリング
- kubectlを使わないREST版の `ClusterClient`、Application CRD化
