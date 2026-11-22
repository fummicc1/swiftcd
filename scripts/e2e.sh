#!/usr/bin/env bash
# kind上で「初回同期 → Gitの変更が自動同期される → ドリフト検出 → 手動Sync」を通しで確認する。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="kind-swiftcd"
PORT="${PORT:-18080}"
SERVER="http://127.0.0.1:$PORT"
export DEMO_REPO="$(mktemp -d)/demo-repo"
WORK_DIR="$(mktemp -d)"
APPS_DIR="$(mktemp -d)"
kc() { kubectl --context "$CONTEXT" "$@"; }

cd "$ROOT"
swift build
"$ROOT/scripts/setup-kind.sh"
"$ROOT/scripts/init-demo-repo.sh"

kc delete namespace e2e-auto e2e-manual --ignore-not-found --wait=true

cat > "$APPS_DIR/auto.yaml" <<EOF
name: e2e-auto
source: { repoURL: $DEMO_REPO, path: guestbook, targetRevision: main }
destination: { namespace: e2e-auto }
syncPolicy: { automated: true }
EOF
cat > "$APPS_DIR/manual.yaml" <<EOF
name: e2e-manual
source: { repoURL: $DEMO_REPO, path: guestbook, targetRevision: main }
destination: { namespace: e2e-manual }
EOF

.build/debug/swiftcd-server --apps "$APPS_DIR" --port "$PORT" --interval 3 --work-dir "$WORK_DIR" --context "$CONTEXT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; kc delete namespace e2e-auto e2e-manual --ignore-not-found --wait=false >/dev/null' EXIT

cli() { .build/debug/swiftcd app "$@" --server "$SERVER"; }

# NAME SYNC HEALTH の列で状態を待つ
wait_for() {
  local app="$1" sync="$2" health="$3"
  for _ in $(seq 1 60); do
    if cli list 2>/dev/null | awk -v a="$app" -v s="$sync" -v h="$health" '$1==a && $2==s && $3==h {found=1} END {exit !found}'; then
      echo "ok: $app is $sync/$health"
      return 0
    fi
    sleep 2
  done
  echo "timeout: $app did not become $sync/$health" >&2
  cli get "$app" >&2 || true
  exit 1
}

echo "== 1. automatedのアプリは初回で同期され、manualのアプリはOutOfSyncのまま"
wait_for e2e-auto Synced Healthy
wait_for e2e-manual OutOfSync Missing

echo "== 2. Gitでreplicasを変更すると自動同期される"
perl -pi -e 's/replicas: 1/replicas: 2/' "$DEMO_REPO/guestbook/deployment.yaml"
git -C "$DEMO_REPO" -c user.name=e2e -c user.email=e2e@localhost commit --quiet -am "scale to 2"
for _ in $(seq 1 60); do
  [ "$(kc -n e2e-auto get deploy guestbook -o jsonpath='{.spec.replicas}')" = "2" ] && break
  sleep 2
done
[ "$(kc -n e2e-auto get deploy guestbook -o jsonpath='{.spec.replicas}')" = "2" ] || { echo "replicas were not synced" >&2; exit 1; }
wait_for e2e-auto Synced Healthy

echo "== 3. 手動のscaleはドリフトとしてOutOfSyncになる（self-healはしない）"
kc -n e2e-auto scale deploy guestbook --replicas=3
wait_for e2e-auto OutOfSync Healthy

echo "== 4. CLIからSyncするとGitの状態に戻る"
cli sync e2e-auto >/dev/null
cli sync e2e-manual >/dev/null
[ "$(kc -n e2e-auto get deploy guestbook -o jsonpath='{.spec.replicas}')" = "2" ] || { echo "sync did not restore replicas" >&2; exit 1; }
wait_for e2e-auto Synced Healthy
wait_for e2e-manual Synced Healthy

echo "== 5. 管理ラベルが付いている"
kc -n e2e-manual get deploy,svc -l swiftcd.io/app=e2e-manual -o name

echo "== 6. GitからServiceを消すと、prune無効なら残ってOutOfSyncになる"
git -C "$DEMO_REPO" rm --quiet guestbook/service.yaml
git -C "$DEMO_REPO" -c user.name=e2e -c user.email=e2e@localhost commit --quiet -m "remove service"
wait_for e2e-auto OutOfSync Healthy
kc -n e2e-auto get svc guestbook -o name
cli get e2e-auto | grep -q "OutOfSync (prune)" || { echo "service was not marked for pruning" >&2; exit 1; }

echo "== 7. --prune付きのSyncでServiceだけが削除される"
cli sync e2e-auto --prune >/dev/null
wait_for e2e-auto Synced Healthy
[ -z "$(kc -n e2e-auto get svc guestbook --ignore-not-found -o name)" ] || { echo "service was not pruned" >&2; exit 1; }
kc -n e2e-auto get deploy guestbook -o name

echo "E2E passed"
