---
name: start
user-invocable: true
disable-model-invocation: true
description: >-
  Deploy GLM-5.3-Flash UNCENSORED to RunPod as a private OpenAI-compatible vLLM
  endpoint, from nothing to serving. Creates a 4x H200 pod, downloads 306 GiB of
  weights, hot-swaps the container to vLLM, waits for the endpoint, and rewires the
  local OpenCode config. Deploys dealignai/GLM-5.3-Flash-UNCENSORED-FP8 only —
  never the base model. Invoke with /glm3:start.
allowed-tools: Bash, Read, Edit, Write
compatibility: Linux, macOS, Windows
---

# glm3:start — deploy GLM-5.3-Flash UNCENSORED

Takes ~30 minutes end to end and costs **$18.36/hr** once running.

## The one thing this skill guarantees

**This deploys `dealignai/GLM-5.3-Flash-UNCENSORED-FP8` and nothing else.**

Never substitute the base `zai-org/GLM-5.3-Flash`, not even temporarily, not for
debugging, not as a fallback if the uncensored build misbehaves. If it fails, report the
failure — do not quietly deploy a different model. The user expects to find the
uncensored model serving when this finishes, and anything else is a wrong result even if
the endpoint is healthy.

Three places must agree, and step 6 asserts it:

| | Value |
|---|---|
| Download source | `dealignai/GLM-5.3-Flash-UNCENSORED-FP8` |
| Local path | `/workspace/models/GLM-5.3-UNCENSORED` |
| Served name | `glm53-uncensored` |

## 0. Confirm before spending

**Never skip this.** State the cost and get explicit approval:

> "This creates a 4× H200 pod at $18.36/hr (~$441/day). Deploy takes ~30 min:
> ~7 min downloading 306 GiB, ~20 min loading and compiling. Proceed?"

Also check nothing is already running:

```bash
K=$(python -c "print(open('.env').read().split('RUNPOD_API_KEY=')[1].split(chr(10))[0].strip())")
curl -s "https://api.runpod.io/v2/pods" -H "Authorization: Bearer $K" | python -m json.tool
```

If a pod exists, do not create a second one — report the existing one instead.

## 1. Find capacity

Availability is per-datacenter and volatile. Probe with a throwaway request rather than
guessing — pass several datacenters and let RunPod choose:

```json
{
  "name": "capacity-probe",
  "image": "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404",
  "cloud": "SECURE",
  "dataCenterIds": ["US-GA-2","US-CA-2","EU-FR-1","EUR-IS-4","AP-JP-1","US-NC-1","EUR-IS-2"],
  "gpu": { "id": "NVIDIA H200", "count": 4 },
  "disk": 20
}
```

`POST` it to `https://api.runpod.io/v2/pods`. If it succeeds, note `dataCenterId`,
**then immediately DELETE the probe** and create the real pod in that region.

Repeated `There are no longer any instances available with the requested specifications`
is a scheduling failure, not a bad request. If all regions are dry, report that and stop —
do not loop indefinitely burning the user's time.

## 2. Create the real pod

Use the **PyTorch image first** — the vLLM image has no shell, so weights could not be
downloaded onto it. Same pod is swapped to vLLM in step 4, which keeps the scarce 4-GPU
allocation instead of releasing it.

```json
{
  "name": "glm53-flash",
  "image": "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404",
  "cloud": "SECURE",
  "dataCenterIds": ["<REGION FROM STEP 1>"],
  "gpu": { "id": "NVIDIA H200", "count": 4, "allowedCudaVersions": ["13.0"] },
  "disk": 60,
  "startSsh": true,
  "ports": ["8000/http", "22/tcp"],
  "env": {
    "PUBLIC_KEY": "<contents of ~/.ssh/id_ed25519.pub>",
    "HF_XET_HIGH_PERFORMANCE": "1"
  },
  "mounts": { "persistent": { "size": 420, "path": "/workspace" } }
}
```

Build this with Python (`json.dump`) rather than a shell heredoc — SSH public keys often
contain a backslash (`azuread\user`) which is an invalid JSON escape.

### If POST /v2/pods returns an `objectMounts` error — use GraphQL instead

```
Field "objectMounts" is not defined by type "PodFindAndDeployOnDemandInput"
```

This is an **upstream RunPod bug**, not your payload — it fails even on a minimal
`{name, image, gpu}` body, for every GPU type and datacenter. RunPod's REST layer injects
`objectMounts` into a GraphQL mutation that rejects it. Do not debug your request; a
four-field body fails identically.

**The bypass: call GraphQL directly.** It is the same operation without the broken
translation layer, and it works.

```bash
python -c "
import json,sys,pathlib,os
pub=pathlib.Path(os.path.expanduser('~/.ssh/id_ed25519.pub')).read_text().strip()
q='mutation(\$input: PodFindAndDeployOnDemandInput!) { podFindAndDeployOnDemand(input: \$input) { id machineId } }'
v={'input':{
  'cloudType':'SECURE','gpuCount':4,'gpuTypeId':'NVIDIA H200',
  'containerDiskInGb':60,'volumeInGb':420,'volumeMountPath':'/workspace',
  'ports':'8000/http,22/tcp','name':'glm53-flash',
  'imageName':'runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404',
  'env':[{'key':'PUBLIC_KEY','value':pub},{'key':'HF_XET_HIGH_PERFORMANCE','value':'1'}]
}}
json.dump({'query':q,'variables':v}, sys.stdout)
" | curl -sS -X POST "https://api.runpod.io/graphql" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H 'Content-Type: application/json' -d @-
```

Use **GraphQL variables, never string interpolation** — an SSH key containing a backslash
produces `Invalid character escape sequence` in an inline literal.

Note the differences from REST: `volumeInGb`/`volumeMountPath` replace `mounts.persistent`,
`ports` is a comma-separated string, and `env` is a list of `{key, value}` pairs. There is
no `dataCenterIds` — GraphQL picks any region with capacity, which is usually what you want.

A `SUPPLY_CONSTRAINT` error from GraphQL is genuine capacity exhaustion, unlike the
`objectMounts` error which is a schema fault. Read/PATCH/DELETE on REST v2 are unaffected —
only pod **creation** is broken, so use REST for everything else.

**Mount type is immutable after creation.** Use `persistent` unless the chosen region
supports network volumes *and* the user wants storage to outlive the pod. `US-GA-2`
supports no network volumes at all.

Expose port 8000 now; adding it later forces a restart.

## 3. Download the weights

Poll `GET /v2/pods/{id}` until `ssh.direct` appears (`runtime` is `null` until live), then:

```bash
ssh -o StrictHostKeyChecking=no -p <PORT> root@<HOST> \
  'pip install --break-system-packages -q -U "huggingface_hub[cli,hf_xet]" && \
   mkdir -p /workspace/models && cd /workspace && \
   setsid nohup /usr/local/bin/hf download dealignai/GLM-5.3-Flash-UNCENSORED-FP8 \
     --local-dir /workspace/models/GLM-5.3-UNCENSORED \
     > /workspace/dl.log 2>&1 < /dev/null & sleep 10; echo started'
```

`--break-system-packages` is required (PEP 668). Run detached so it survives disconnects.

Poll until **62 shards** and ~306G:

```bash
ssh -p <PORT> root@<HOST> \
  'ls /workspace/models/GLM-5.3-UNCENSORED/*.safetensors | wc -l; du -sh /workspace/models/GLM-5.3-UNCENSORED'
```

Do **not** use `pgrep -f "hf download"` to test completion — the SSH command string itself
matches the pattern and always reports running. Count shards instead.

Takes ~7 min at ~750 MB/s. Confirm `processor_config.json` exists before continuing.

## 4. Swap to vLLM

`PATCH https://api.runpod.io/v2/pods/{id}` — keeps the pod ID, GPUs, storage and URL:

```json
{
  "image": "vllm/vllm-openai:glm53-flash-x86_64-cu130",
  "args": "--model /workspace/models/GLM-5.3-UNCENSORED --served-model-name glm53-uncensored --tensor-parallel-size 4 --max-model-len 1048576 --max-num-seqs 256 --gpu-memory-utilization 0.92 --api-key <GLM_API_KEY> --enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm45 --host 0.0.0.0 --port 8000"
}
```

Use `-cu129` if the pod reports CUDA 12.8.

**Two flags are mandatory and non-obvious:**
- `--model` must be a **local path**. A Hugging Face repo ID crashes on startup.
- `--max-num-seqs 256` prevents an endless crash-loop in CUDA graph capture.

## 5. Wait for it to serve

~20 min. Poll:

```bash
until curl -sf "https://<POD_ID>-8000.proxy.runpod.net/v1/models" \
  -H "Authorization: Bearer $GLM_API_KEY" >/dev/null; do sleep 30; done
```

502 means vLLM is not listening yet; 404 means the container is restarting.

**Distinguish loading from crash-looping.** Both reprint shard progress. Check the worker
PID in the logs (`Worker_TP0 pid=1048`): stable = loading, changing every ~3 min = crashing.
Past 25 minutes, stop waiting and grep for `Error`/`Traceback`.

Report progress honestly — do not claim it is loading without checking the PID.

## 6. Verify

```bash
BASE="https://<POD_ID>-8000.proxy.runpod.net/v1"
curl -s "$BASE/models" -H "Authorization: Bearer $KEY"          # check max_model_len
curl -s "$BASE/chat/completions" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm53-uncensored","messages":[{"role":"user","content":"Reply with exactly: it works"}],"max_tokens":32}'
curl -o /dev/null -w '%{http_code}\n' "$BASE/models" -H "Authorization: Bearer wrong"   # must be 401
```

`max_model_len` from `/v1/models` is the **only** proof the context setting took —
the pod's `args` merely show what was requested. A non-401 on the third check means the
endpoint is open to the internet; fix before proceeding.

### Assert the uncensored build is what is actually serving

Do not report success without this. `/v1/models` reports the real weights directory, so
it is the only check that can distinguish the two builds — the served name alone proves
nothing, because a name is just a label passed on the command line.

```bash
curl -s "$BASE/models" -H "Authorization: Bearer $KEY" | python -c "
import sys, json
d = json.load(sys.stdin)['data'][0]
root, mid = d['root'], d['id']
ok = 'UNCENSORED' in root.upper() and mid == 'glm53-uncensored'
print('served :', mid)
print('weights:', root)
print('VERDICT:', 'UNCENSORED CONFIRMED' if ok else 'WRONG MODEL — DO NOT REPORT SUCCESS')
sys.exit(0 if ok else 1)
"
```

If this fails, say so plainly and stop. A healthy endpoint serving the wrong weights is a
failed deployment, not a partial success.

## 7. Rewire OpenCode

**The base URL embeds the pod ID, so it is wrong after every deploy.** A new pod means a
new ID; OpenCode will keep hitting the dead one and report bad gateway. Patch it rather
than hand-editing JSON:

```bash
python -c "
import json
POD='<NEW_POD_ID>'
path=r'C:/Users/ChrisPowell/.config/opencode/opencode.jsonc'
c=json.load(open(path))
p=c['provider']['runpod-glm']
p['options']['baseURL']=f'https://{POD}-8000.proxy.runpod.net/v1'
for m in p['models'].values(): m['limit']['context']=1048576
json.dump(c,open(path,'w'),indent=2)
print('baseURL:', p['options']['baseURL'])
print('models :', list(p['models'].keys()))
"
```

Three rules this enforces:

- **`limit.context` must equal `--max-model-len`.** Client lower than server silently
  wastes the window; client *higher* fails mid-conversation once context accumulates,
  which looks intermittent and is miserable to diagnose.
- **List only models the server actually serves.** OpenCode does not validate the list —
  a stale entry is offered in `/models` and returns
  `The model 'x' does not exist` (404) on first use.
- **`auth.json` needs no change** if `GLM_API_KEY` is unchanged, since the new pod was
  launched with the same secret. Only touch it if the key rotated.

**Check for a project-scoped `opencode.json`.** It overrides the global config, producing
auth that works in one directory and fails in another. In this repo the example lives at
`config/opencode.json.example` — deliberately named so it *cannot* be picked up. If you
find a real `opencode.json` in a project root, reconcile or delete it.

Finally, tell the user to **fully quit and relaunch** OpenCode — it does not reload config
live, and a running instance still holds the old pod ID.

## 8. Report

Give the endpoint URL, model name, context length, and a reminder that billing has started
at $18.36/hr with `/glm3:stop` and `/glm3:destroy` available.
