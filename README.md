# GLM-5.3-Flash on RunPod

Deploy **GLM-5.3-Flash UNCENSORED** (321B MoE, 1M context) as a private
OpenAI-compatible endpoint on RunPod, and drive it from the **glm-codex** Codex launcher.

No application code lives here — this is a runbook, deploy payloads, and lifecycle skills.
The Codex launcher itself lives in a separate repo (`glm-codex`); this repo stands up
the model and points that launcher at it.

## Quick start

| Task | Command |
|---|---|
| Deploy from nothing → serving + verified launcher | `/glm3:start` |
| Pause the pod | `/glm3:stop` |
| Tear everything down | `/glm3:destroy` |

Roughly 30 minutes and **$18.36/hr** on 4× H200.

Doing it by hand instead? Open **[`docs/deployment-guide.html`](docs/deployment-guide.html)**
in a browser — console *and* CLI paths, with every bug encountered.

## Layout

```
AGENTS.md                  agent guidance — read first if you're an agent
docs/
  deployment-guide.html    the human guide (standalone, open in a browser)
deploy/                    RunPod REST payloads, one per hardware config
scripts/
  swap-to-vllm.sh          hot-swap a pod's PyTorch image to vLLM (serve)
  swap-to-pytorch.sh       swap back to a shell image (manage weights)
  test-endpoint.sh         smoke test: /models, a completion, and a 401 check
plugins/glm3/              the start/stop/destroy skills
archive/                   one-off scripts from the original build; disposable
```

## Setup

Create `.env` in the repo root (gitignored):

```
RUNPOD_API_KEY=rpa_...     # console.runpod.io → Settings → API Keys, Read/Write
GLM_API_KEY=glm-...        # a secret you invent, protects the endpoint
HF_TOKEN=hf_...            # optional; speeds the weight download
```

The skills are installed as a local plugin:

```bash
claude plugin marketplace add .
claude plugin install glm3@glm3
```

## The Codex launcher

The one true launcher is **glm-codex** (`glm-codex` repo) — Codex only, no OpenCode,
no Claude Code. `/glm3:start` writes the live pod URL and key into that launcher's `.env`
and verifies it works. To run Codex against the endpoint afterwards:

```powershell
..\glm-codex\scripts\codex-glm.ps1
```

Any Codex window open from before a redeploy still holds the old pod — relaunch to pick up
the new one.

## Things that will bite you

The full list is in `AGENTS.md` and the guide. The ones that cost the most time:

1. **Never pass a Hugging Face repo ID to `--model`** — it crashes on startup. Download
   the weights first and pass a local path.
2. **Always set `--max-num-seqs 256`** — the default crash-loops forever during CUDA
   graph capture on this architecture.
3. **Don't pin `dataCenterIds` or `allowedCudaVersions: ["13.0"]`** — both return false
   "no capacity" errors. Let RunPod choose the region; allow CUDA 12.8 and pick the
   `-cu129` vLLM image.
4. **Prefer terminate over stop.** Stopping releases your GPUs to other renters; you may
   not get them back. Re-downloading is ~10–20 minutes.

## Cost

4× H200 is **$18.36/hr ≈ $441/day**. A crash-looping pod bills exactly like a healthy one.
After teardown, verify **zero pods and zero network volumes** — deleting a pod does not
delete a volume.
