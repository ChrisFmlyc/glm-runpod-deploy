#!/usr/bin/env bash
# Flip a pod back to the PyTorch image (with a shell) so weights can be managed.
# The vLLM image has no shell, so SSH is unavailable while it is running.
# Usage: ./scripts/swap-to-pytorch.sh <POD_ID>
set -euo pipefail
cd "$(dirname "$0")/.."
POD="${1:?usage: swap-to-pytorch.sh <POD_ID>}"
RP=$(grep '^RUNPOD_API_KEY=' .env | cut -d= -f2-)

python -c "
import json,sys
json.dump({'image':'runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404','args':''}, sys.stdout)
" > ./.pt-patch.json

curl -sS -X PATCH "https://api.runpod.io/v2/pods/${POD}" \
  -H "Authorization: Bearer ${RP}" -H 'Content-Type: application/json' \
  -d @./.pt-patch.json | python -c "
import sys,json
d=json.load(sys.stdin)
print('image :', d.get('image'))
print('status:', d.get('status'))
print('args  :', repr(d.get('args')))
"
rm -f ./.pt-patch.json
