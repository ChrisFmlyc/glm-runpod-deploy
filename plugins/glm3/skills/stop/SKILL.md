---
name: stop
user-invocable: true
disable-model-invocation: true
description: >-
  Pause the running GLM-5.3-Flash RunPod pod without deleting its weights, after
  warning the user that stopping releases the GPUs and may leave the pod unable to
  restart. Use when the user says "stop the model", "pause the pod", "shut it down
  for now", or /glm3:stop. For permanent teardown use glm3:destroy instead.
allowed-tools: Bash
compatibility: Linux, macOS, Windows
---

# glm3:stop — pause the pod

Stops billing for GPU time while keeping the 306 GiB of weights on disk.

## Warn first — stopping is riskier than it sounds

**Do not stop silently.** Present this before acting, because the failure mode is
non-obvious and expensive to recover from:

> Stopping releases your GPUs on that **specific physical machine** back to the pool.
> If another renter takes them, restarting gives you a **"Zero GPU Pod"** — it boots with
> no GPUs, vLLM dies immediately, and you get storage access only. It does not queue
> or wait for capacity.

The asymmetry that matters:

| Action | Requires |
|---|---|
| Restart after stop | 4 free H200s on **that one machine** |
| Fresh deploy | 4 free H200s on **any machine in the network** |

A fresh deploy has far better odds. Re-downloading the weights is ~20 minutes.

**Also tell them:** stopping is not free. Volume disk bills at $0.20/GB/month —
a 420 GB mount is ~$84/month, about **$2.76/day**, while stopped. And a restart still
takes ~25 minutes, because the weight load is a cold read (~13.5 min) rather than the
~37 s page-cached first boot.

## Recommend the right choice

- **Returning within a few hours** → stop is reasonable.
- **Returning tomorrow or later** → recommend `/glm3:destroy` and a fresh deploy.
  More predictable, and only costs a 7-minute download.

If the user is on a **pod-local persistent mount** (not a network volume), they are
maximally exposed: the weights are pinned to that one machine and cannot be migrated.
Check `mounts` on the pod and say so explicitly if it is `persistent`.

## API health note

`POST /v2/pods` was broken upstream with an `objectMounts` schema error (AGENTS.md BUG-13),
forcing pod creation through GraphQL. **REST creation worked normally on 2026-09-01**, so
treat GraphQL as the fallback rather than the required path. Stop, read, PATCH and DELETE
on REST v2 have always been unaffected.

That lowers the stakes on a failed restart slightly — a rebuild no longer needs a
workaround — but the capacity risk below is the real reason to prefer keeping the pod
running, or destroying deliberately, over an optimistic stop.

## Do it

```bash
K=$(python -c "print(open('.env').read().split('RUNPOD_API_KEY=')[1].split(chr(10))[0].strip())")
# REST v2 returns {"pods":[...]}, NOT {"items":[...]}. Keying into ['items']
# reads nothing and would make this look like "no pod to stop" while one is
# live and billing. Use ['pods'].
POD=$(curl -s "https://api.runpod.io/v2/pods" -H "Authorization: Bearer $K" \
  | python -c "import json,sys; p=json.load(sys.stdin).get('pods',[]); print(p[0]['id'] if p else '')")

curl -sS -X POST "https://api.runpod.io/v2/pods/$POD/stop" -H "Authorization: Bearer $K"
```

If that endpoint is rejected, fall back to the RunPod MCP tool `stop-pod`, or tell the
user to use **Pods → ⋯ → Stop** in the console. Do not silently substitute
`DELETE` — that is a destroy, not a stop, and would lose the weights.

## Confirm and report

```bash
curl -s "https://api.runpod.io/v2/pods/$POD" -H "Authorization: Bearer $K" | python -m json.tool
```

Report: pod ID, that GPU billing has stopped, ongoing disk cost per day, and that
restarting takes ~25 minutes and is not guaranteed to get GPUs back.

Remind them the glm-codex launcher will get **bad gateway / 404** from the endpoint until
the pod is running again — that is expected, not a config fault.
