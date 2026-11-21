#!/usr/bin/env bash
# kindクラスタ "swiftcd" を作成する（作成済みなら何もしない）。
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-swiftcd}"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "kind cluster '$CLUSTER_NAME' already exists"
else
  kind create cluster --name "$CLUSTER_NAME" --wait 120s
fi

kubectl --context "kind-$CLUSTER_NAME" get nodes
