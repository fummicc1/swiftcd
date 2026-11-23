# ディレクトリ構成

新しいファイルをどこに置くかを決められるように、各ディレクトリに何を置くかをまとめています。

## 全体

```
Sources/
  SwiftCDCore/      ドメインロジック（ライブラリ）
  swiftcd-server/   reconcileループとHTTP API、Web UIを動かす実行ファイル
  swiftcd/          サーバーのAPIを呼ぶCLI
Tests/
  SwiftCDCoreTests/ SwiftCDCoreの単体テスト
examples/           Application定義と、デモ用マニフェストのひな形
scripts/            kindの準備、デモ用リポジトリの作成、E2E
docs/               開発者向けの説明
```

## ターゲットの分け方

ロジックは `SwiftCDCore` に置き、実行ファイルのターゲットは入出力だけを受け持ちます。

| ターゲット | 置くもの | 置かないもの |
|---|---|---|
| `SwiftCDCore` | Git、マニフェスト、クラスタ、reconcileに関する処理すべて | HTTPやコマンドライン引数の扱い（HummingbirdやArgumentParserに依存させない） |
| `swiftcd-server` | 起動オプション、ルーティング、`Public/` の静的ファイル | 同期や判定のロジック |
| `swiftcd` | サブコマンドと表示の整形 | サーバーを介さないクラスタ操作 |

サーバーとCLIは、`SwiftCDCore` の `AppStatus` などの型と `APICoding` を共有して、JSONの形をそろえています。

## SwiftCDCore の中

ディレクトリは型名の接尾辞ではなく、役割で分けています。たとえば `Controller/` には `AppStore` や `PrunePlanner` のように、名前に `Controller` が付かない型も入ります。

| ディレクトリ | 置くもの | 例 |
|---|---|---|
| `Model/` | Application定義と、APIで返す状態を表す `public` な型。定義ファイルの読み込みと、APIのJSON形式を決める処理も含みます | `Application`、`AppStatus`、`ResourceRef`、`ApplicationLoader`、`APICoding` |
| `Shell/` | 外部コマンドの実行 | `CommandRunner`、`ProcessRunner` |
| `Git/` | Gitリポジトリの取得 | `GitClient`、`CLIGitClient` |
| `Manifest/` | リポジトリ内のマニフェストを、クラスタへ渡せる形にする処理 | `ManifestRenderer` |
| `Cluster/` | クラスタの読み書き | `ClusterClient`、`KubectlClient` |
| `Health/` | ライブのオブジェクトからHealthを判定する処理 | `HealthAssessor` |
| `Controller/` | 上の部品を組み合わせるreconcileの流れと、その中だけで使う型 | `AppController`、`AppStore`、`PrunePlanner`、`SyncState` |

### 置き場所を決めるときの目安

- 外部のコマンドを呼ぶ処理は、protocolと実装を同じファイルに置きます（`GitClient` と `CLIGitClient`、`ClusterClient` と `KubectlClient`）。テストはprotocolをFakeに差し替えます。
- 入力から結果を計算するだけの処理は、状態を持たない `enum` の `static` 関数にします（`ManifestRenderer`、`HealthAssessor`、`PrunePlanner`）。
- サーバーとCLIの両方が使う型は `Model/` に `public` で置きます。1つの機能の中だけで使う型は、その機能のディレクトリに `internal` で置きます（`SyncState` は `AppController` だけが使うので `Controller/`）。
- `Controller/` は他のディレクトリに依存してよく、他のディレクトリは `Controller/` に依存しません。

## テスト

`Tests/SwiftCDCoreTests/` は、テスト対象ごとに `<対象>Tests.swift` を置きます。Fakeとテスト用のヘルパーは `Fakes.swift` にまとめています。kindクラスタを使った確認は `scripts/e2e.sh` で行います。
