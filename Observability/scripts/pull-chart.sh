#!/usr/bin/env bash
# Re-download the pinned chart into charts/ (untarred).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/CHART_VERSION" 2>/dev/null || true

CHART="${chart:-kube-prometheus-stack}"
VERSION="${version:-86.0.1}"
REPO_NAME="prometheus-community"
REPO_URL="https://prometheus-community.github.io/helm-charts"

cd "$ROOT"
helm repo add "$REPO_NAME" "$REPO_URL" 2>/dev/null || true
helm repo update "$REPO_NAME"

rm -rf "charts/${CHART}"
mkdir -p charts
helm pull "${REPO_NAME}/${CHART}" --version "$VERSION" --untar -d charts

echo "Pulled ${CHART} ${VERSION} -> charts/${CHART}/"
