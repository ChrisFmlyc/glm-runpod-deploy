#!/usr/bin/env bash
# Swap a pod from the PyTorch image to vLLM serving a local uncensored build.
# Usage: ./scripts/swap-to-vllm.sh <POD_ID> [MODEL_DIR] [cu129|cu130]
#   MODEL_DIR defaults to /workspace/models/GLM-5.3-DEALIGN
set -euo pipefail
cd "$(dirname "$0")/.."

POD="${1:?usage: swap-to-vllm.sh <POD_ID> [MODEL_DIR] [cu129|cu130]}"
MODEL_DIR="${2:-/workspace/models/GLM-5.3-DEALIGN}"
TAG="${3:-cu129}"

RP=$(grep '^RUNPOD_API_KEY=' .env | cut -d= -f2-)
GK=$(grep '^GLM_API_KEY='    .env | cut -d= -f2-)

ARGS="--model ${MODEL_DIR} --served-model-name glm53-uncensored --tensor-parallel-size 4 --max-model-len 1048576 --max-num-seqs 256 --gpu-memory-utilization 0.92 --api-key ${GK} --enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm45 --host 0.0.0.0 --port 8000"

ARGS="$ARGS" TAG="$TAG" python -c "
import json,sys,os
json.dump({'image':'vllm/vllm-openai:glm53-flash-x86_64-'+os.environ['TAG'],
           'args':os.environ['ARGS']}, sys.stdout)
" > ./.vllm-patch.json

curl -sS -X PATCH "https://api.runpod.io/v2/pods/${POD}" \
  -H "Authorization: Bearer ${RP}" -H 'Content-Type: application/json' \
  -d @./.vllm-patch.json >/dev/null
rm -f ./.vllm-patch.json

# Verify against a FRESH GET, not the PATCH response: the PATCH reply returns
# before `args` is populated, and the GET itself lags 20-30s and may briefly
# echo a partial string. So POLL the GET until --model appears, then check.
#
# All substring checks are done in BASH (`case`), never by passing MODEL_DIR to
# python. Under Git Bash, a value starting with "/" (like /workspace/...) passed
# as argv/env to native Windows python is rewritten by MSYS path conversion to
# "C:/Program Files/Git/workspace/..." - which made the check report a spurious
# "model dir: MISSING" while the pod was configured correctly. `case` in bash
# does no such conversion. (The --model value sent to the pod is unaffected: it
# is mid-string in ARGS, not a leading-slash argument.)
echo "waiting for args to populate on the pod..."
a=""; img=""
for _ in $(seq 1 20); do
  resp=$(curl -sS "https://api.runpod.io/v2/pods/${POD}" -H "Authorization: Bearer ${RP}")
  a=$(printf '%s' "$resp"   | python -c "import sys,json; print(json.load(sys.stdin).get('args','') or '')")
  img=$(printf '%s' "$resp" | python -c "import sys,json; print(json.load(sys.stdin).get('image','') or '')")
  case "$a" in *"--model ${MODEL_DIR}"*) break ;; esac
  sleep 5
done

chk() { case "$a" in *"$1"*) echo OK ;; *) echo MISSING ;; esac; }
echo "image        : $img"
echo "model dir    : $(chk "--model ${MODEL_DIR}")"
echo "served name  : $(chk "--served-model-name glm53-uncensored")"
echo "max-num-seqs : $(chk "--max-num-seqs 256")"
echo "max-model-len: $(chk "--max-model-len 1048576")"
[ -z "$a" ] && echo "WARN: args still empty after polling - check the pod manually"
