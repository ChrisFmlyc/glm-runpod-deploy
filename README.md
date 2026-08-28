# GLM-5.3-Flash on RunPod

Deploy **GLM-5.3-Flash** (321B MoE, 1M context, vision) as a private
OpenAI-compatible endpoint on RunPod, and drive it from OpenCode.

No application code lives here — this is a runbook, deploy payloads, and lifecycle skills.

## Quick start

| Task | Command |
|---|---|
| Deploy from nothing → serving | `/glm3:start` |
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
  claude-code-litellm-guide.html   run Claude Code against this endpoint via LiteLLM
deploy/                    RunPod REST payloads, one per hardware config
scripts/
  test-endpoint.sh         smoke test: /models, a completion, and a 401 check
config/
  opencode.json.example    OpenCode provider block — copy and set your pod ID
litellm/                   LiteLLM proxy config + PowerShell launchers
plugins/glm3/              the start/stop/destroy skills
archive/                   one-off scripts from the original build; disposable
```

## Setup

Create `.env` in the repo root (gitignored):

```
RUNPOD_API_KEY=rpa_...     # console.runpod.io → Settings → API Keys, Read/Write
GLM_API_KEY=glm-...        # a secret you invent, protects the endpoint
```

The skills are installed as a local plugin:

```bash
claude plugin marketplace add .
claude plugin install glm3@glm3
```

## Connecting OpenCode

Copy `config/opencode.json.example` to `~/.config/opencode/opencode.jsonc`, set the
`baseURL` to your pod ID, then in OpenCode run `/connect` → **Other** → provider ID
`runpod-glm` → paste your `GLM_API_KEY`. Fully quit and relaunch — it doesn't reload
config live.

## Things that will bite you

The full list is in `AGENTS.md` and the guide. The three that cost the most time:

1. **Never pass a Hugging Face repo ID to `--model`** — it crashes on startup. Download
   the weights first and pass a local path.
2. **Always set `--max-num-seqs 256`** — the default crash-loops forever during CUDA
   graph capture on this architecture.
3. **Prefer terminate over stop.** Stopping releases your GPUs to other renters; you may
   not get them back. Re-downloading is only ~7 minutes.

## Cost

4× H200 is **$18.36/hr ≈ $441/day**. A crash-looping pod bills exactly like a healthy one.
After teardown, verify **zero pods and zero network volumes** — deleting a pod does not
delete a volume.
