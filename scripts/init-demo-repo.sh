#!/usr/bin/env bash
# examples/gitops-repo-template からデモ用のGitリポジトリを作る。
# このリポジトリの中にネストしたgitリポジトリを置かないよう、作業ディレクトリの外に作る。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_REPO="${DEMO_REPO:-$HOME/.swiftcd/demo-repo}"

if [ -d "$DEMO_REPO/.git" ]; then
  echo "demo repo already exists: $DEMO_REPO"
  echo "作り直す場合は rm -rf $DEMO_REPO を実行してください"
  exit 0
fi

mkdir -p "$DEMO_REPO"
cp -R "$ROOT/examples/gitops-repo-template/." "$DEMO_REPO/"
git -C "$DEMO_REPO" init --quiet -b main
git -C "$DEMO_REPO" add .
git -C "$DEMO_REPO" -c user.name=swiftcd -c user.email=swiftcd@localhost commit --quiet -m "initial guestbook"
echo "created demo repo: $DEMO_REPO"
