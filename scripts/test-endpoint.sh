#!/usr/bin/env bash
# Smoke-test the GLM-5.3-Flash endpoint. Usage: ./test-endpoint.sh <pod-id>
set -euo pipefail
POD_ID="${1:?usage: test-endpoint.sh <pod-id>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY=$(grep '^GLM_API_KEY=' "$ROOT/.env" | cut -d= -f2- | tr -d '\r\n')
BASE="https://${POD_ID}-8000.proxy.runpod.net/v1"

echo "=== 1. models ==="
curl -sS "$BASE/models" -H "Authorization: Bearer $KEY" | python -m json.tool

echo "=== 2. chat ==="
curl -sS "$BASE/chat/completions" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm53","messages":[{"role":"user","content":"Reply with exactly: it works"}],"max_tokens":32}' \
  | python -m json.tool

echo "=== 3. auth rejects a bad key (should be 401) ==="
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/models" -H "Authorization: Bearer wrong-key"
