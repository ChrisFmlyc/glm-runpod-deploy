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
# before `args` is fully populated and reports spurious MISSING flags.
sleep 3
curl -sS "https://api.runpod.io/v2/pods/${POD}" -H "Authorization: Bearer ${RP}" | python -c "
import sys,json
d=json.load(sys.stdin); a=d.get('args','')
md=sys.argv[1]
print('image        :', d.get('image'))
print('status       :', d.get('status'))
print('model dir    :', 'OK' if ('--model '+md) in a else 'MISSING')
print('served name  :', 'OK' if '--served-model-name glm53-uncensored' in a else 'MISSING')
print('max-num-seqs :', 'OK' if '--max-num-seqs 256' in a else 'MISSING')
print('max-model-len:', 'OK' if '--max-model-len 1048576' in a else 'MISSING')
if not a: print('WARN: args still empty on GET - re-run this check in a few seconds')
" "$MODEL_DIR"
