# AGENTS.md — GLM-5.3-Flash on RunPod

Operational repo for deploying the **GLM-5.3-Flash UNCENSORED** build as a private
OpenAI-compatible inference endpoint on RunPod, consumed by the glm-codex Codex launcher.

There is no application code here. This repo is **runbook + deploy payloads + skills**.

---

## Quick orientation

| Want to… | Do this |
|---|---|
| Deploy from nothing → serving | `/glm3-start` |
| Pause (read the warning first) | `/glm3-stop` |
| Tear down completely | `/glm3-destroy` |
| Read the full human guide | `glm53-deployment-guide.html` |

**This repo deploys the uncensored build, and only the uncensored build.**
`orcarouter/GLM-5.3-Flash-Uncensored-FP8` — never any other build.
Not as a fallback, not for debugging, not temporarily. If the uncensored build fails,
report the failure rather than substituting a different model: a healthy endpoint serving
the wrong weights is a failed deployment.

Verify from `/v1/models` — its `root` field reports the real weights directory. The
served name proves nothing, since it is just a label passed on the command line.

---

## Non-negotiables

Read these before touching anything. Each one cost real time and money to learn.

1. **Never pass a Hugging Face repo ID to `--model`.** It crashes on startup.
   Always download first and pass a local directory. See BUG-01.
2. **Always include `--max-num-seqs 256`.** Without it vLLM crash-loops forever
   during CUDA graph capture. See BUG-02.
3. **Use `https://api.runpod.io/v2` for everything except creating a pod.**
   `rest.runpod.io/v1` is deprecated and takes a different schema. **Pod creation on REST
   v2 is currently broken upstream** — use the GraphQL mutation instead (BUG-13). Read,
   PATCH and DELETE on REST v2 are unaffected.
4. **Confirm with the user before creating any pod.** These cost **$18.36/hr**.
   Never deploy speculatively, never "just test something" on 4× H200.
5. **Prefer terminate over stop.** Stopping releases the GPUs to other renters and
   restarting may yield a zero-GPU pod. See *Stop vs terminate*.
6. **Verify from `/v1/models`, never from pod `args`.** The args show what was
   *requested*; only the endpoint proves what vLLM actually allocated.
7. **The glm-codex launcher needs BOTH no-prompt settings.** `approval_policy = "never"`
   *and* `sandbox_mode = "danger-full-access"`, *and* a `[projects.<dir>]`
   `trust_level = "trusted"` entry. Neither works alone. See *The client: glm-codex launcher*.

---

## Credentials

`.env` in this repo (gitignored — never commit, never print in full):

```
RUNPOD_API_KEY=rpa_...      # RunPod, needs Read/Write
GLM_API_KEY=glm-...         # the secret protecting the vLLM endpoint
```

Read them without echoing:

```bash
K=$(python -c "print(open('.env').read().split('RUNPOD_API_KEY=')[1].split(chr(10))[0].strip())")
```

Note: **vLLM prints `--api-key` in plaintext in its startup log.** Treat `GLM_API_KEY`
as visible to anyone who can read pod logs.

---

## The model

| | |
|---|---|
| Parameters | 321.3B total, 18B active (288 experts, 8+1 active) |
| Precision | FP8 e4m3 (314.4B) + BF16 (6.9B vision/embeds/norms) |
| Weights on disk | **306 GiB**, 62 safetensors shards |
| Layers | 45 — 34 KDA linear-attention + 11 NoPE sparse MLA |
| Attention heads | **64 — tensor-parallel size must divide 64** (3/5/6/7 invalid) |
| Max context | 1,048,576 (verified working on 4× H200) |
| KV cost | ~11 KiB/token → ~14.5M token pool at TP4 |
| Modality | text + vision (GLM-4.1V tower) |

Both builds are architecturally identical — same parameter count, same shapes.
Only the download URL and `--model` path differ.

---

## Hardware

| Config | VRAM | TP | $/hr | Notes |
|---|---|---|---|---|
| **4 × H200 141GB** | 525 GiB | 4 | **18.36** | Default. Proven working |
| 8 × H100 80GB | 596 GiB | 8 | 26.32 | Works, harder to schedule |
| 4 × B200 180GB | 670 GiB | 4 | 27.16 | Fastest; allows `--kv-cache-dtype fp8` |
| 4 × H100 80GB | 298 GiB | — | — | **Too small** (306 GiB needed) |
| 2 × H200 | 262 GiB | — | — | **Too small** |
| Any A100 | — | — | — | **No FP8 support** |
| AMD MI300X | — | — | — | **Needs gfx950**, MI300X is gfx942 |

**Hopper (H100/H200) cannot use `--kv-cache-dtype fp8` for this model.** Blackwell can.

**Prefer 4 large GPUs over 8 small ones.** 8-GPU nodes failed every scheduling attempt
during the original deployment; 4-GPU succeeded.

---

## Deploy strategy: one pod, two images

Do **not** create separate download and serve pods. Multi-GPU capacity is scarce —
releasing it between steps means re-competing for it.

```
1. POST /v2/pods  with runpod/pytorch image   → get a shell
2. SSH in, download 306 GiB to /workspace     → ~20 min
3. PATCH image + args to vLLM                 → same pod, same GPUs, same ID
4. Poll /v1/models until 200                  → ~15-20 min
```

The pod ID never changes across the image swap, so the launcher base URL stays valid
throughout a single deploy.

**Always deploy the uncensored build.** It has been run successfully on this exact stack —
it loaded and served first time, 75.65 GiB per worker, passing chat, tool-calling and auth
checks. Treat it as known-good. If a deployment fails, the cause is the engine, the
hardware or the configuration, not the checkpoint; debug those. Do not substitute the base
model to "isolate" a problem — that changes what the user asked for and leaves them with
the wrong model running.

---

## Storage: read this before choosing

Two mount types, **immutable after pod creation**:

```jsonc
// network volume — survives the pod, but PINS it to that datacenter
"mounts": { "network": [{ "volumeId": "abc123", "path": "/workspace" }] }

// pod-local persistent — works in ANY datacenter, dies with the pod
"mounts": { "persistent": { "size": 420, "path": "/workspace" } }
```

**Not every datacenter supports network volumes.** `US-GA-2` — frequently the only
region with 4× H200 capacity — supports **none**. The original deployment used a
persistent mount for exactly this reason.

Sizing: 420 GB holds one model. 750 GB holds two. Volume disk bills at
**$0.20/GB/month** (420 GB ≈ $84/mo) — *including while the pod is stopped*.

---

## Canonical serve arguments

```
--model /workspace/models/GLM-5.3-UNCENSORED
--served-model-name glm53-uncensored
--tensor-parallel-size 4
--max-model-len 1048576
--max-num-seqs 256
--gpu-memory-utilization 0.92
--api-key $GLM_API_KEY
--enable-auto-tool-choice
--tool-call-parser glm47
--reasoning-parser glm45
--host 0.0.0.0 --port 8000
```

Image: `vllm/vllm-openai:glm53-flash-x86_64-cu130`
(use `-cu129` if the host reports CUDA 12.8 rather than 13.0)

Every flag is load-bearing:

| Flag | Why |
|---|---|
| local path in `--model` | BUG-01 — repo IDs crash |
| `--max-num-seqs 256` | BUG-02 — prevents crash-loop |
| `--tool-call-parser glm47` | agent tool calling |
| `--reasoning-parser glm45` | splits CoT into its own field |
| `--api-key` | endpoint is publicly routable without it |

---

## Bugs — do not rediscover these

**BUG-01 — repo ID crashes on startup.**
`FileNotFoundError: '<repo>/processor_config.json'`. `Glm5NextProcessor.from_pretrained`
calls `open()` on the model string as a local path instead of resolving via the Hub.
→ Download first, pass a local directory.

**BUG-02 — crash-loop during CUDA graph capture.**
`ValueError: max_num_seqs (1024) exceeds available Mamba cache blocks (512)`.
34 of 45 layers are linear-attention needing one state block per sequence.
→ `--max-num-seqs 256`.

**BUG-03 — `glm5_next` is not in vLLM main.** Support is unmerged (vllm#53906).
→ Use the per-model preview image. Match the CUDA tag to the host.

**BUG-04 — loading and crash-looping look identical.** Both reprint shard progress.
→ Check the worker PID (`Worker_TP0 pid=1048`). Stable = loading. Changing = crashing.
Healthy startup ≈ 20 min; past 25, grep the log for `Error`/`Traceback`.

**BUG-05 — the model card's launch command doesn't work.** It assumes a GB200:
TP4 needs 76.5 GiB/GPU (OOMs on 80 GB cards) and `--kv-cache-dtype fp8` is Blackwell-only.

**BUG-06 — storage and GPUs live in different datacenters.** Repeated
`no longer any instances available` is a scheduling failure, not a bad request.
→ Check GPU *and* volume support in the same region before creating anything.

**BUG-07 — pip refuses.** `externally-managed-environment` (PEP 668).
→ `pip install --break-system-packages`.

**BUG-08 — SSH stops working after the image swap.** Two mechanisms: proxy SSH
(`ssh.runpod.io`) needs an *account-level* key; direct SSH uses the pod's `PUBLIC_KEY`
and only works on images running sshd. **The vLLM image has none.**
→ Do all shell work while on the PyTorch image.

**BUG-09 — the endpoint is public and the key is logged.** The proxy URL is
publicly routable; vLLM has no auth by default and prints the key at startup.
→ Always `--api-key`; always verify a wrong key returns 401.

**BUG-10 — prefill is slower than advertised.** `No MLA prefill backend supports this
model`. Cosmetic; expect below-spec prefill throughput.

**BUG-11 — `HF_HUB_ENABLE_HF_TRANSFER` is deprecated.** → `HF_XET_HIGH_PERFORMANCE=1`.

**BUG-13 — `POST /v2/pods` fails with `objectMounts` (upstream, as of 2026-08-28).**
```
Field "objectMounts" is not defined by type "PodFindAndDeployOnDemandInput"
```
RunPod's REST layer injects `objectMounts: null` into a GraphQL mutation that rejects it.
Both halves are RunPod's. The field is **not in their published v2 OpenAPI spec** — an
unreleased feature leaked ahead of its schema. `GET /v2/gputypes` also 404s; same churn.

**Do not debug your payload.** It fails on a minimal `{name, image, gpu}` body, every GPU
type, every datacenter, via raw curl *and* the MCP client. Identical payloads worked on
2026-08-27.

→ **Create pods via GraphQL instead.** Same operation, no broken translation layer:

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
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' -d @-
```

**Use GraphQL variables, never string interpolation** — an SSH key containing a backslash
(`azuread\user`) produces `Invalid character escape sequence` in an inline literal.

Field mapping differs from REST: `volumeInGb`/`volumeMountPath` replace `mounts.persistent`,
`ports` is a comma-separated string, `env` is a list of `{key, value}` pairs, and there is
no `dataCenterIds` — GraphQL picks any region with capacity.

`SUPPLY_CONSTRAINT` from GraphQL is genuine capacity exhaustion. `objectMounts` is a schema
fault. Do not confuse them: the first is worth retrying, the second never is.

Retest REST periodically — when it starts working, prefer it.

**BUG-12 — restarts are 25× slower than first boot.** First load reads from page cache
(~37s); any later start is a cold 306 GiB read (~13.5 min). The kernel-JIT cache lives on
container disk and is wiped on restart.
→ Budget **~25 min and ~$7** per restart. **Batch flag changes**; never iterate one at a time.

---

## The client: glm-codex launcher

**Codex only.** There is no OpenCode path and no Claude Code path — both were removed. The
one true launcher is **glm-codex**, a separate repo:

```
C:\Users\ChrisPowell\code\glm-codex
  scripts/codex-glm.ps1   scripts/codex-glm.sh
```

It reads its own `.env` (`GLM_BASE_URL`, `GLM_API_KEY`, `GLM_MODEL_NAME`), regenerates a
scoped Codex config on each run, and connects straight to the Responses API (no proxy).

After every deploy, the only thing to update is that launcher's `.env` — `GLM_BASE_URL`
embeds the pod ID. `/glm3:start` Step 6 does this and then verifies the launcher with a
`codex-ok` round-trip.

### Codex will prompt on every command unless BOTH of these are set

This cost most of a day. Do not re-derive it, and do not remove either setting.

Both live in one generated file, `glm-codex\.codex-home\config.toml` — the scoped
`CODEX_HOME`. Not `~/.codex`, and not the directory you launch from.

**1. Approval and sandbox, as a pair.**

```toml
approval_policy = "never"
sandbox_mode    = "danger-full-access"
```

`approval_policy` alone does nothing. Codex derives a *permission profile* from the
sandbox: `danger-full-access` gives `disabled` and `never` is honoured; `workspace-write`
or `read-only` give `managed`, and the interactive TUI then promotes `never` to
`on-request`, because escaping a managed sandbox requires approval to be possible.

**2. Directory trust.**

```toml
[projects.'c:\users\you\code\yourproject']
trust_level = "trusted"
```

Checked **before and independently of** the approval settings. An untrusted directory
prompts before every command regardless of `approval_policy`. The key must be the native
path — a Git Bash `/c/users/...` key never matches.

**Why it broke at random:** Codex persists the trust entry itself once you approve a
folder, but the launcher regenerates `config.toml` on every run and used to wipe it. Both
launchers now merge existing `[projects.…]` entries. Preserve that if you touch them.

**Ruled out — do not chase these again:** `default_permissions`, `[features]
guardian_approval`, either `managed_config.toml` (ignored; the scoped one prints a
deprecation warning), `CODEX_PERMISSION_PROFILE`,
`--dangerously-bypass-approvals-and-sandbox`, `-a`/`-s` flags, `-c` overrides, ChatGPT
Enterprise policy (not signed in), and the custom model. Each was tested by enabling every
lever at once and removing them one at a time.

**`codex exec` is not a valid test.** Exec cannot prompt, so it reports `never` under any
sandbox and passes even when the TUI is broken. Verify interactively, and read the truth
from the rollout log's `turn_context` (`approval_policy`, `sandbox_policy`,
`permission_profile`) or `/debug-config` inside the TUI. The banner can say "YOLO mode"
while the session actually runs `on-request`.

Things that bite:

- **The served name is `glm53-uncensored`.** Requesting `glm53` returns
  `The model 'glm53' does not exist` (404). The launcher passes the model explicitly.
- **A running Codex session holds its old config.** Relaunch after a redeploy or it keeps
  hitting the previous pod.
- **Refusals are a reasoning-mode setting, not the model.** This build is fully uncensored
  at reasoning **off** or **max**; intermediate effort keeps some refusals by design.
- **Codex context is capped near 258K** for a custom provider regardless of the configured
  window (upstream bug openai/codex#19185).
- **`.ps1` must be pure ASCII.** PowerShell reads a BOM-less script as cp1252; one em-dash
  produces `The string is missing the terminator` pointing at a line that is fine — the
  reported line is where the parser gave up, not where the bad byte is.

## Stop vs terminate

**Default to terminate.**

Stopping releases your GPUs on that *specific physical machine*. On restart you may get a
"Zero GPU Pod" — it starts with no GPUs, vLLM dies immediately, and you get storage access
only. It does not queue or wait.

| Action | Needs |
|---|---|
| Restart after stop | 4 free H200s on **that one machine** |
| Fresh deploy | 4 free H200s on **any machine in the network** |

The second has far better odds. Re-downloading is ~20 minutes. Stopping also still bills
~$2.76/day for the disk and still needs ~25 min to serve.

Stop only if returning within hours.

---

## Cost discipline

- 4× H200: **$18.36/hr** ≈ $441/day
- Volume disk: **$0.20/GB/month**, billed while stopped
- Full deploy from scratch: **$10–35**
- A crash-looping pod bills exactly like a healthy one

Always report accumulated spend when giving status. Always confirm before creating a pod.
After teardown, verify **zero** pods *and* **zero** network volumes — deleting a pod does
not delete a volume.

---

## Repo contents

```
README.md                        human entry point
AGENTS.md                        this file
.env                             secrets — gitignored, never commit or print
.gitignore

docs/
  deployment-guide.html          full human guide, console + CLI, all 12 bugs
deploy/
  pod-h200x4.json                default: 4× H200, TP4
  pod-h100x8.json                fallback: 8× H100, TP8
  pod-h200x8.json                8× H200, most KV headroom
  pod-persistent-mount.json      pod-local disk (regions without network volumes)
  pod-downloader.json            cheap single-GPU pod for weight downloads
  capacity-probe.json            multi-datacenter probe to find free GPUs
scripts/
  swap-to-vllm.sh                hot-swap a pod to vLLM (serve the model)
  swap-to-pytorch.sh             swap back to a shell image (manage weights)
  test-endpoint.sh               smoke test: /models, a completion, a 401 check
plugins/glm3/
  skills/{start,stop,destroy}/   the lifecycle skills
archive/                         one-off scripts and logs from the original build
```

**All payloads in `deploy/` carry placeholders** (`YOUR_SECRET_KEY`,
`ssh-ed25519 AAAA... you@host`) — substitute from `.env` and `~/.ssh/id_ed25519.pub`
before sending. Never write a real key back into these files.

`archive/` is disposable; delete it freely.

---

## Verification status

Honesty about provenance, so nothing here is trusted more than it deserves:

- **Executed and verified**: `POST/PATCH/GET/DELETE /v2/pods`, SSH + `hf download`,
  all `/v1` endpoint checks, both bug fixes, 1M context.
- **From documentation, not executed**: RunPod console click-paths,
  `/v2/networkvolumes` endpoints, `runpodctl` (never used).
- **Not done**: no vLLM source audit. BUG-01 and BUG-02 root causes are inferred from a
  traceback and an error string, and were never confirmed against the code or by a
  maintainer, nor checked against the upstream issue tracker.
