---
name: destroy
user-invocable: true
disable-model-invocation: true
description: >-
  Permanently tear down the GLM-5.3-Flash RunPod deployment — terminate the pod and
  delete any network volumes — then verify billing has actually stopped. Use when the
  user says "destroy the pod", "tear it down", "delete everything", "I'm done with the
  model", or /glm3:destroy. Destructive and irreversible; confirm first.
allowed-tools: Bash
compatibility: Linux, macOS, Windows
---

# glm3:destroy — full teardown

Irreversible. Stops **all** billing.

## Confirm first

Show exactly what will be destroyed and what it costs to rebuild:

> **Two response-shape traps that once caused a live $18.36/hr pod to be
> reported as "already gone".** REST `/v2/pods` nests the list under `pods`, not
> `items` — keying into `['items']` reads nothing and hides a running pod. And
> `/v2/networkvolumes` returns **404** — that REST path does not exist; volumes
> only come from GraphQL. Both fixes are baked into the commands below. Do not
> revert them to `['items']` or the REST volumes path.

```bash
K=$(python -c "print(open('.env').read().split('RUNPOD_API_KEY=')[1].split(chr(10))[0].strip())")

# Pods: REST v2 returns {"pods":[...]}, NOT {"items":[...]}.
curl -s "https://api.runpod.io/v2/pods" -H "Authorization: Bearer $K" | python -c "
import json,sys
pods=json.load(sys.stdin).get('pods',[])
print('pods:', len(pods))
for p in pods: print(' ', p['id'], p['name'], p.get('desiredStatus'), '\$'+str(p.get('costPerHr'))+'/hr')
"

# Network volumes: /v2/networkvolumes 404s — list via GraphQL.
curl -s -X POST "https://api.runpod.io/graphql" -H "Authorization: Bearer $K" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{myself{networkVolumes{id name size dataCenterId}}}"}' | python -m json.tool
```

Tell them plainly:

> This deletes the pod **and its 306 GiB of weights**. Rebuilding means a ~20 minute
> re-download plus re-competing for 4× H200 capacity, which is not always immediately
> available. Roughly 30 minutes and ~$10 to get back. Proceed?

Get an explicit yes. **Never destroy on an ambiguous instruction** — "remove that
volume/pod" while the user is actively using the model is not consent to delete the
deployment. Ask which resource they mean.

## API health note

`DELETE /v2/pods/{id}` is **unaffected** by the `objectMounts` bug that once broke pod
*creation* (AGENTS.md BUG-13). Teardown works normally on REST v2. As of 2026-09-01 REST
creation works again too, so the GraphQL bypass is a fallback rather than a requirement. If a DELETE ever does fail with an `objectMounts` or
schema error, the GraphQL equivalent is `podTerminate(input: {podId: "..."})`.

## Terminate the pod

```bash
POD=$(curl -s "https://api.runpod.io/v2/pods" -H "Authorization: Bearer $K" \
  | python -c "import json,sys; p=json.load(sys.stdin).get('pods',[]); print(p[0]['id'] if p else '')")

curl -sS -X DELETE "https://api.runpod.io/v2/pods/$POD" -H "Authorization: Bearer $K" \
  -w '\nHTTP %{http_code}\n'
```

204 means success.

## Delete network volumes — the step everyone forgets

**Terminating a pod does not delete its network volume.** The volume keeps billing at
$0.20/GB/month indefinitely. A 750 GB volume is ~$150/month for data nothing can reach.

```bash
# List via GraphQL — the /v2/networkvolumes REST path 404s.
curl -s -X POST "https://api.runpod.io/graphql" -H "Authorization: Bearer $K" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{myself{networkVolumes{id name size dataCenterId}}}"}' | python -m json.tool

# Delete each one by id (REST DELETE on a specific volume does work).
curl -sS -X DELETE "https://api.runpod.io/v2/networkvolumes/<VOLUME_ID>" -H "Authorization: Bearer $K" \
  -w '\nHTTP %{http_code}\n'
```

A volume is only worth keeping if the user plans to redeploy **in that same datacenter**
soon — volumes cannot move between regions, and a stranded volume in a region with no GPU
capacity is pure cost. Re-downloading is ~20 minutes; err toward deleting.

Pod-local `persistent` mounts need no separate cleanup — they die with the pod.

## Verify zero

Do not report success from the DELETE response alone. Prove it:

```bash
curl -s "https://api.runpod.io/v2/pods" -H "Authorization: Bearer $K" \
  | python -c "import json,sys; print('pods   :', len(json.load(sys.stdin).get('pods',[])))"
curl -s -X POST "https://api.runpod.io/graphql" -H "Authorization: Bearer $K" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{myself{networkVolumes{id}}}"}' \
  | python -c "import json,sys; print('volumes:', len(json.load(sys.stdin)['data']['myself']['networkVolumes']))"
```

Cross-check the pod count against GraphQL too — a wrong REST key is exactly what
once masked a running pod:

```bash
curl -s -X POST "https://api.runpod.io/graphql" -H "Authorization: Bearer $K" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{myself{pods{id name desiredStatus}}}"}' | python -m json.tool
```

Both must be **0**. Report the totals explicitly.

## Tidy up afterwards

Mention, but do not do without asking:

- The glm-codex launcher's `.env` (`glm-codex\.env`) still points at the dead pod. It
  will fail until the next `/glm3:start` updates `GLM_BASE_URL`. Harmless to leave.
- `GLM_API_KEY` in `.env` was only ever for that endpoint. Rotating it is optional, but
  note that vLLM logged it in plaintext, so treat it as exposed if the logs were shared.
- The weights are gone. `/glm3:start` rebuilds from scratch.

## Report

Confirm zero pods and zero volumes, state that all billing has stopped, and give the
approximate total spend for the session if known.
