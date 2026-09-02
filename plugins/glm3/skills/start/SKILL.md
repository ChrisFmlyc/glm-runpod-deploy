---
name: start
user-invocable: true
disable-model-invocation: true
description: >-
  Deploy GLM-5.3-Flash UNCENSORED to RunPod as a private OpenAI-compatible vLLM
  endpoint, from nothing to serving. Creates a 4x H200 pod, downloads 306 GiB of
  weights, hot-swaps the container to vLLM, verifies the endpoint, points the
  glm-codex Codex launcher at the new pod, and confirms that launcher works.
  Deploys dealignai/GLM-5.3-Flash-UNCENSORED-FP8 only - never any other build.
  Codex only - no OpenCode, no Claude Code. Invoke with /glm3:start.
allowed-tools: Bash, Read, Edit, Write, WebFetch
compatibility: Linux, macOS, Windows
---

# glm3:start - deploy GLM-5.3-Flash UNCENSORED

End to end: ~30 minutes. **$18.36/hr** once running (~$441/day).

---

## Step 0 - Read the model card first. Every time.

**Do this before touching the RunPod API.** The card is the source of truth; this
skill is a summary that goes stale.

```
WebFetch https://huggingface.co/dealignai/GLM-5.3-Flash-UNCENSORED-FP8
```

Extract four things, and say what you found before proceeding:

| Look for | Why it matters |
|---|---|
| **Reasoning-mode behaviour** | Refusal rates differ per effort level. This is the single most common cause of "it stopped being uncensored". |
| **Chat-template / `clear_thinking` notes** | Template changes alter refusal behaviour without any weight change. |
| **Recommended sampling** (temperature, top_p, repetition penalty) | The author tests at specific values; defaults may not match. |
| **Gating status** | Determines whether `HF_TOKEN` is needed at all. |

Then check the revision history, because the weights move:

```bash
curl -s "https://huggingface.co/api/models/dealignai/GLM-5.3-Flash-UNCENSORED-FP8/commits/main" \
  | python -c "
import json,sys
for c in json.load(sys.stdin)[:6]:
    print(c['id'][:12], c['date'][:19], '|', (c.get('title') or '')[:60])
"
```

If the top commit is newer than the user's last deploy, **say so**. A same-repo,
same-command deploy can still behave differently from last week.

> Real example: on 2026-09-02 the card documented "fully uncensored at reasoning-OFF
> and MAX effort ... low effort retains some refusals **by design**", and a commit that
> same morning changed `clear_thinking` to default true in the chat template. A user
> reporting "it was unrestricted last week, not this week" was hitting both at once.

**Follow what the card says over what this file says.** If they disagree, the card wins
and this skill needs updating.

---

## Step 0b - When to stop and ask

This deployment has choices that are the user's to make, not yours. When you hit one,
**stop and ask a short, concrete question with a recommendation.** Do not pick silently,
and do not bury the choice in a status update.

Ask when the card reveals a setting that trades one thing off against another:

> "The card says this build is fully uncensored only at reasoning **off** or **max**
> effort - intermediate levels keep some refusals by design. Reasoning-off is also the
> fastest. Do you want me to set reasoning off, or max?"

Ask when the requested target is ambiguous:

> "You asked me to swap the model. I can keep pod `abc123` and replace the weights in
> place (~10 min, keeps the scarce 4x H200 allocation), or destroy and redeploy fresh
> (~30 min, re-competes for capacity). Which?"

Ask when a credential is needed:

> "`orcarouter/...` is gated and returns 401 anonymously. I need an `HF_TOKEN` in `.env`.
> Do you have one, or should I use the ungated `dealignai` build instead?"

Ask when the safe default may not be what they want:

> "The volume is a pod-local `persistent` mount, so stopping pins you to this exact
> machine and a restart may return a zero-GPU pod. Destroy is more predictable and a
> rebuild is only ~10 minutes now. Stop or destroy?"

Ask before anything irreversible:

> "This deletes 306 GiB of weights. Rebuilding costs ~10 minutes. Proceed?"

**Do not ask** about things with an obvious correct answer - which CUDA image tag matches
the pod, whether to count shards, whether to verify the endpoint. Make those calls and
report them.

---

## The one thing this skill guarantees

**This deploys `dealignai/GLM-5.3-Flash-UNCENSORED-FP8` and nothing else.**

Never substitute another build - not temporarily, not for debugging, not as a fallback if
this one misbehaves. If it fails, report the failure. A healthy endpoint serving the wrong
weights is a failed deployment, not a partial success.

Three values must agree, and Step 5 asserts it:

| | Value |
|---|---|
| Download source | `dealignai/GLM-5.3-Flash-UNCENSORED-FP8` |
| Local path | `/workspace/models/GLM-5.3-DEALIGN` |
| Served name | `glm53-uncensored` |

`dealignai` is **ungated** - anonymous download returns 200, so `HF_TOKEN` is optional
(it only improves throughput). Verify before spending:

```bash
curl -s -o /dev/null -L -w '%{http_code}\n' \
  https://huggingface.co/dealignai/GLM-5.3-Flash-UNCENSORED-FP8/resolve/main/config.json
```

**200** = good. **401** = needs a token. **403** = token valid but repo terms not accepted
(accept them on the model page - the banner is on the page itself, not in settings).

---

## Step 1 - Confirm the spend, and check nothing is running

State the cost and get an explicit yes:

> "This creates a 4x H200 pod at $18.36/hr (~$441/day). Deploy takes ~30 min:
> ~10 min downloading 306 GiB, ~20 min loading and compiling. Proceed?"

```bash
K=$(grep '^RUNPOD_API_KEY=' .env | cut -d= -f2-)
curl -s "https://api.runpod.io/v2/pods" -H "Authorization: Bearer $K" \
  | python -c "import sys,json; p=json.load(sys.stdin).get('pods') or []; print('pods:',len(p)); [print(' ',x['id'],x['status']) for x in p]"
```

If a pod already exists, **do not create a second one.** Report the existing one and ask
whether to reuse, swap its model, or destroy it.

---

## Step 2 - Create the pod

Use the **PyTorch image first**. The vLLM image has no shell, so weights cannot be
downloaded onto it. Step 3 swaps the same pod to vLLM, which keeps the scarce 4-GPU
allocation instead of releasing it.

```bash
python -c "
import json,sys,pathlib,os
pub=pathlib.Path(os.path.expanduser('~/.ssh/id_ed25519.pub')).read_text().strip()
json.dump({
 'name':'glm53-flash','image':'runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404',
 'cloud':'SECURE',
 'gpu':{'id':'NVIDIA H200','count':4,'allowedCudaVersions':['13.0','12.8']},
 'disk':60,'startSsh':True,'ports':['8000/http','22/tcp'],
 'env':{'PUBLIC_KEY':pub,'HF_XET_HIGH_PERFORMANCE':'1'},
 'mounts':{'persistent':{'size':420,'path':'/workspace'}}
}, sys.stdout)" > /tmp/pod.json

curl -sS -X POST "https://api.runpod.io/v2/pods" -H "Authorization: Bearer $K" \
  -H 'Content-Type: application/json' -d @/tmp/pod.json
```

Build the payload with `json.dump`, never a shell heredoc - SSH public keys often contain
a backslash (`azuread\user`) which is an invalid JSON escape.

**Do not pin `dataCenterIds`.** Passing a region list has returned
`There are no longer any instances available` while the *identical* request with no region
list succeeded immediately. Let RunPod choose.

**Do not pin `allowedCudaVersions` to `["13.0"]` alone.** H200 hosts are widely on 12.8;
requesting only 13.0 returns zero capacity across every region and looks exactly like a
genuine outage. Allow both, then read the created pod's `cudaVersion` and pick the vLLM
tag from it.

**Mount type is immutable after creation.** `persistent` is pod-local: the weights pin to
one physical machine and cannot migrate. That is usually right, but it makes `/glm3:stop`
risky - say so when the user later asks to stop.

Expose port 8000 now; adding it later forces a restart.

> **If `POST /v2/pods` fails with `Field "objectMounts" is not defined`** - that is an
> upstream schema bug (AGENTS.md BUG-13), not your payload. It was fixed by 2026-09-01 and
> REST creation works, so try REST first. If it returns, fall back to the GraphQL
> `podFindAndDeployOnDemand` mutation, passing the SSH key as a **GraphQL variable**, never
> string-interpolated.

---

## Step 3 - Download the weights

Poll `GET /v2/pods/{id}` until `ssh.direct` appears (`runtime` is `null` until live), then
confirm the shell actually answers before trusting the port.

```bash
ssh -o StrictHostKeyChecking=no -p <PORT> root@<HOST> \
  "pip install --break-system-packages -q -U 'huggingface_hub[cli,hf_xet]' && \
   mkdir -p /workspace/models && cd /workspace && \
   HF_XET_HIGH_PERFORMANCE=1 setsid nohup /usr/local/bin/hf download dealignai/GLM-5.3-Flash-UNCENSORED-FP8 \
     --local-dir /workspace/models/GLM-5.3-DEALIGN \
     > /workspace/dl.log 2>&1 < /dev/null & sleep 20; echo started"
```

Add `HF_TOKEN=<TOKEN>` before `setsid` if the user supplied one - it roughly doubles
throughput even on an ungated repo.

`--break-system-packages` is required (PEP 668). Run detached so it survives disconnects.

Poll until **62 shards** and ~306G:

```bash
ssh -p <PORT> root@<HOST> \
  'ls -1 /workspace/models/GLM-5.3-DEALIGN/*.safetensors | wc -l; du -sh /workspace/models/GLM-5.3-DEALIGN'
```

- Shards are named `model-00001-of-00062.safetensors` (five digits).
- Do **not** use `pgrep -f "hf download"` to test completion - the SSH command string
  itself matches the pattern and always reports running. Count shards.
- Check `dl.log` for `401`/`403`/`GatedRepo` early rather than waiting out a download that
  will never produce shards.
- Confirm both `config.json` and `processor_config.json` exist before continuing.

Authenticated on a fast host this is a few minutes; unauthenticated the Hub throttles to
~420 MB/s and it takes ~20.

---

## Step 4 - Swap to vLLM

```bash
./scripts/swap-to-vllm.sh <POD_ID> /workspace/models/GLM-5.3-DEALIGN cu129
```

The script PATCHes the pod, keeping its ID, GPUs, storage and URL, then prints a check of
every critical flag. Match the tag to the pod's `cudaVersion`: **`cu129` for 12.8**,
`cu130` for 13.0.

The arguments it sets, and why:

- `--model /workspace/models/GLM-5.3-DEALIGN` - must be a **local path**. A Hugging Face
  repo ID crashes on startup.
- `--max-num-seqs 256` - prevents an endless crash-loop in CUDA graph capture.
- `--max-model-len 1048576` - the full 1M window.
- `--served-model-name glm53-uncensored`
- `--reasoning-parser glm45`, `--tool-call-parser glm47`, `--enable-auto-tool-choice`

**To go the other way** (to manage weights, since vLLM has no shell):

```bash
./scripts/swap-to-pytorch.sh <POD_ID>
```

Swapping a model on an existing pod - delete, re-download, swap back - takes ~10 minutes
and never releases the GPUs. Prefer it over destroy-and-redeploy whenever capacity is
tight.

---

## Step 5 - Wait, then verify

```bash
until curl -sf "https://<POD_ID>-8000.proxy.runpod.net/v1/models" \
  -H "Authorization: Bearer $GLM_API_KEY" >/dev/null; do sleep 30; done
```

`404` = container restarting or image still extracting. `502` = container up, vLLM not
listening yet. Both are normal early.

**Distinguish loading from crash-looping.** Both reprint shard progress. Check the worker
PID in the logs (`Worker_TP0 pid=1048`): stable = loading, changing every ~3 min =
crashing. Past 25 minutes, stop waiting and grep for `Error`/`Traceback`. Report progress
honestly - never claim it is loading without checking.

Then run all four checks:

```bash
BASE="https://<POD_ID>-8000.proxy.runpod.net/v1"

# 1+2. identity and context, and the uncensored assertion
curl -s "$BASE/models" -H "Authorization: Bearer $KEY" | python -c "
import sys, json
d = json.load(sys.stdin)['data'][0]
EXPECTED = '/workspace/models/GLM-5.3-DEALIGN'
ok = d['root'] == EXPECTED and d['id'] == 'glm53-uncensored'
print('served :', d['id'])
print('weights:', d['root'])
print('ctx len:', d.get('max_model_len'))
print('VERDICT:', 'CONFIRMED' if ok else 'WRONG MODEL - DO NOT REPORT SUCCESS')
sys.exit(0 if ok else 1)
"

# 3. inference
curl -s "$BASE/chat/completions" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm53-uncensored","messages":[{"role":"user","content":"Reply with exactly: it works"}],"max_tokens":32}'

# 4. auth - must be 401
curl -o /dev/null -w '%{http_code}\n' "$BASE/models" -H "Authorization: Bearer wrong"
```

Why each one:

- **`root` is the only proof of which weights are loaded.** The served name is just a label
  passed on the command line and proves nothing. Compare it to the **exact expected path** -
  do not substring-match on "UNCENSORED", because a correct directory may not contain that
  word and a wrong one might.
- **`max_model_len` from `/v1/models` is the only proof the context setting took.** The
  pod's `args` merely show what was requested.
- **A non-401 means the endpoint is open to the internet.** Fix before proceeding.

If the assertion fails, say so plainly and stop.

---

## Step 6 - Point the glm-codex launcher at the new pod, and verify it

The model is serving; now make the **glm-codex launcher** use it, and prove it works. That
launcher is a **separate repo** - the single source of truth for running Codex against this
endpoint. This skill does not generate or duplicate it:

```
C:\Users\ChrisPowell\code\glm-codex
  scripts/codex-glm.ps1   scripts/codex-glm.sh
```

It reads its own `.env` (`GLM_BASE_URL`, `GLM_API_KEY`, `GLM_MODEL_NAME`), regenerates a
scoped Codex config on every run, and connects straight to the Responses API. The pod ID
changes each deploy, so the only thing to update is that `.env`.

There is no OpenCode path and no Claude Code path here - Codex only.

### Update the launcher's `.env`

```bash
LAUNCHER="/c/Users/ChrisPowell/code/glm-codex"
[ -f "$LAUNCHER/.env" ] || { echo "glm-codex launcher not at $LAUNCHER - ask the user where it is"; exit 1; }
GK=$(grep '^GLM_API_KEY='  .env | cut -d= -f2-)
URL=$(grep '^GLM_BASE_URL=' .env | cut -d= -f2-)
python - "$LAUNCHER/.env" "$URL" "$GK" <<'PY'
import re, sys
p, url, key = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
s = re.sub(r'(?m)^GLM_BASE_URL=.*$',   'GLM_BASE_URL='   + url, s)
s = re.sub(r'(?m)^GLM_API_KEY=.*$',    'GLM_API_KEY='    + key, s)
s = re.sub(r'(?m)^GLM_MODEL_NAME=.*$', 'GLM_MODEL_NAME=glm53-uncensored', s)
open(p, 'w', encoding='utf-8').write(s)
print('launcher .env ->', url)
PY
```

If that path does not exist, **stop and ask the user where the glm-codex launcher lives**.
Do not invent a launcher inside this repo - the duplication of launchers is exactly what
caused a full session of confusion once.

### Verify the launcher actually works

This is the "ensure the codex script is working" check. The skill is **not done** until it
passes. Run the launcher headless against the live endpoint:

```powershell
& "$env:USERPROFILE\code\glm-codex\scripts\codex-glm.ps1" `
    exec --skip-git-repo-check "Reply with exactly: codex-ok"
```

A clean `codex-ok` proves the whole chain: the launcher resolved its `.env`, generated its
config, reached the live pod, and the served model answered. Confirm the launcher's own
target line reads the **new** pod and the right model:

```
Codex -> GLM at https://<NEW_POD_ID>-8000.proxy.runpod.net/v1 (model glm53-uncensored)
```

If it prints a different pod, or `model glm53` (without `-uncensored`), the `.env` did not
take - fix it before reporting. Requesting a name the pod does not serve returns
`The model 'glm53' does not exist`; the served name is `glm53-uncensored` only.

### Two things to tell the user

- **Refusals are a reasoning-mode setting** (Step 0), not the model. The launcher does not
  pin reasoning effort, so the served default applies. If they report refusals, that is the
  knob - reasoning **off** or **max** are the fully-uncensored modes.
- **A running Codex session holds its old config.** Any window open from before this deploy
  still points at the previous pod - they must relaunch.

---

## Step 7 - Report

Give:

- endpoint URL, model name, context length
- the verification results, including the `VERDICT` line
- which reasoning mode governs refusals, and how to change it
- the launcher command (`glm-codex\scripts\codex-glm.ps1`) and its `codex-ok` result
- that any already-open Codex session must be relaunched
- billing has started at **$18.36/hr**, with `/glm3:stop` and `/glm3:destroy` available
- if the mount is pod-local `persistent`, that stopping pins them to one machine

Report honestly. If a step was skipped, blocked, or only partly verified, say which and
why. Never report success on an unverified assertion.

---

## Note for whoever edits this file

Plugin skills are snapshotted when the session starts. Edits here do not take effect until
Claude Code is restarted, so a `/glm3:start` invoked in the same session will still run the
old text.
