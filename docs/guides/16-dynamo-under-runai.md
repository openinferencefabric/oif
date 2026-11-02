# Guide 16: Dynamo under Run:ai

Spike S-4 and step T-201. The hand install (appendix) was tested on the lab cluster (guide 10) on 2026-11-01 and
2026-11-02; the `oif install` path is T-201 and is tested with `tests/lab/t201-dynamo.sh`.

## What you get

- NVIDIA Dynamo 1.6.1 (operator and CRDs) on the cluster, with Grove and Dynamo's own bundled KAI Scheduler **off**
  ([platform/dynamo/values.yaml](../../platform/dynamo/values.yaml)). Dynamo's pods are then scheduled by Run:ai's KAI
  like any other project workload.
- A DynamoGraphDeployment (a frontend and one vLLM worker serving Qwen3-0.6B), submitted to a project through the
  Run:ai UI or with `kubectl`. Run:ai shows it in **Workloads** as type DynamoGraphDeployment, the worker gets an
  NVIDIA GPU from the project's quota in pool `nvidia`, and the frontend answers OpenAI-compatible requests.
- Quotas hold: a second deployment over the project's quota waits with `NonPreemptibleOverQuota`.

## Before you start

- A multi-node cluster with Run:ai and per-vendor node pools (guide 10), and a project with NVIDIA GPU quota in pool
  `nvidia`. The lab uses `team-c`, with a quota of 1 GPU in pool `nvidia`.
- NVIDIA driver 580 or newer on the NVIDIA node (`NVIDIA_DRIVER_MIN`; the lab runs 615, guide 2).
- Internet access to `helm.ngc.nvidia.com`, `nvcr.io` and Hugging Face. These public artefacts need no NGC key.

## Steps

1. Get the oif version with T-201 and run the install on the first node:

   ```bash
   cd ~/open-inference-fabric && git pull
   sudo ./oif install
   ```

   On a new cluster this is part of the normal install. On an installed one only the new stage runs:

   ```text
   == stage: dynamo
   == Dynamo 1.6.1 platform (operator and CRDs, 1-3 min)
     [ok] Dynamo 1.6.1 operator ready, 6 CRDs; no Grove or bundled KAI: Run:ai's KAI schedules Dynamo's pods
   == install finished
   ```

   The stage installs Helm release `dynamo-platform` in namespace `dynamo-system`, the names used by the hand install
   in the appendix, so it takes over a hand install instead of adding a second one. It is skipped on a cluster without
   NVIDIA GPUs (Dynamo on AMD comes with S-1). `DYNAMO=none` in `.env` turns it off (see "What changed").

2. Take the deployment from [tests/lab/s4-dynamo-agg.yaml](../../tests/lab/s4-dynamo-agg.yaml). It sets the pool
   label `runai/node-pool: nvidia` on the deployment **and in each component's `podTemplate.metadata.labels`**. The
   deployment-level label does not reach the pods. Without the per-pod label, the frontend, which asks for no GPU,
   lands in another pool (see Troubleshooting).

3. Submit it to the project, either way:
   - In the Run:ai UI, open **Workload manager > Workloads > New workload > Via YAML**. Paste only the file's content
     (from `apiVersion:` to the last line, with no shell prompt), open **Projects** and pick the project, then click
     **Create workload**.
   - Or with `kubectl` into the project's namespace:
     `kubectl -n runai-<project> apply -f tests/lab/s4-dynamo-agg.yaml`.

4. Wait for both pods. The first start pulls the runtime image (about 20 GB) and the model:

   ```bash
   kubectl -n runai-<project> get pods -o wide -L runai/node-pool
   ```

   ```text
   NAME                                       READY   STATUS    ...   NODE         NODE-POOL
   s4-qwen-frontend-c4b58957-86drb            1/1     Running   ...   gpu-nvidia   nvidia
   s4-qwen-worker-5fa00681-6b75cdc9fb-qnjjj   1/1     Running   ...   gpu-nvidia   nvidia
   ```

## Check it worked

1. Run:ai **Workloads** shows `s4-qwen` as type DynamoGraphDeployment, project `team-c`, node pool `nvidia`,
   Running, 2/2 pods, GPU compute request 1.

2. Chat through the frontend:

   ```bash
   kubectl -n runai-<project> port-forward svc/s4-qwen-frontend 8000:8000 >/tmp/pf.log 2>&1 &
   sleep 3
   curl -s localhost:8000/v1/models; echo
   curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
     -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":40}'; echo
   kill %1
   ```

   `/v1/models` lists `Qwen/Qwen3-0.6B`, and the completion returns text. With `max_tokens` set to 40, the answer ends
   inside Qwen3's `<think>` block with `"finish_reason":"length"`. That is the token cap, not an error.

3. Quota: while the first deployment runs, submit the same file again with `name: s4-qwen-2`. Its worker stays
   Pending:

   ```text
   NonPreemptibleOverQuota: Non-preemptible workload is over quota. Workload requested 1 GPUs, but team-c-nvidia
   quota is 1 GPUs, while 1 GPUs are already allocated for non-preemptible pods.
   ```

   Run:ai schedules a DynamoGraphDeployment as non-preemptible (inference), so it cannot borrow over-quota capacity.
   Its frontend still starts. Delete `s4-qwen-2` afterwards.

4. The lab script does all of the above with deployments of its own (`t201-qwen`, `t201-qwen-2`, deleted at the
   end), submitted with `kubectl`. It needs team-c's NVIDIA quota free:

   ```bash
   sudo tests/lab/t201-dynamo.sh              # platform, deployment, chat, over quota
   sudo tests/lab/t201-dynamo.sh --platform   # the platform checks only
   ```

Recorded output: [docs/evidence/S-4/](../evidence/S-4/) (hand install) and `docs/evidence/T-201/`.

## What changed on the host

Nothing on the hosts themselves; oif keeps the chart in its state folder. In the cluster:

| Change | Undo |
| --- | --- |
| Helm release `dynamo-platform`, namespace `dynamo-system`, the six Dynamo CRDs (`dynamocomponentdeployments`, `dynamographdeploymentrequests`, `dynamographdeployments`, `dynamographdeploymentscalingadapters`, `dynamomodels`, `dynamoworkermetadatas`) | `sudo ./oif uninstall` removes them with the cluster. To remove only Dynamo, set `DYNAMO=none` in `.env` and run `sudo ./oif install --reconfigure`; `DYNAMO=all` installs it again (an empty value keeps the saved `none`) |
| Your Dynamo deployments | Delete them in the Run:ai UI. Removing the CRDs (above) deletes them too; the install warns how many |

## Troubleshooting

- **The frontend runs in pool `amd` (or another pool) while its worker is in `nvidia`.** The frontend asks for no
  GPU and carries no pool label, so KAI books it against the project's parent queue (`team-c`). Pool `nvidia` does not
  have that queue (`QueueDoesNotExist`), so the frontend falls through to the next pool. Put `runai/node-pool` in each
  component's `podTemplate.metadata.labels` (step 2). T-129 makes oif do this for you.
- **The new worker stays Pending after deleting an earlier deployment.** Pods of the deleted deployment may still be
  Terminating and holding the project's GPU. Wait, and check before forcing anything:
  `kubectl -n runai-<project> get pods -o custom-columns=NAME:.metadata.name,DELETED:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers`.
- **The UI says "Add a valid Kubernetes YAML".** The pasted text contains something other than the file, such as a
  shell prompt. Clear the box and paste only the file.
- **The install stops with "Dynamo started its own scheduler".** A chart version turned Grove or its KAI on despite
  oif's values. Check `platform/dynamo/values.yaml` against the new chart's `values.yaml`.
- **`kubectl describe pod` shows no events.** Events expire after an hour; read them while the problem is happening.

## Appendix: the hand install (S-4)

How S-4 installed Dynamo before T-201. `oif install` now does the same; keep this for a cluster oif did not build.

1. Fetch the chart and check it against `DYNAMO_PLATFORM_SHA256` in `versions.env`:

   ```bash
   mkdir -p ~/s4 && cd ~/s4
   helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-1.6.1.tgz
   sha256sum dynamo-platform-1.6.1.tgz
   ```

   ```text
   c10af6c9a9dc13d9a26623cc159cc2b3043d86e092e6ad85c17224f59f997d3e  dynamo-platform-1.6.1.tgz
   ```

2. Install it. The chart's own defaults already keep Grove and its KAI off; oif's values file only makes that explicit:

   ```bash
   helm install dynamo-platform dynamo-platform-1.6.1.tgz -n dynamo-system --create-namespace --wait --timeout 10m
   kubectl get crd | grep -i dynamo
   ```

3. Undo: `helm uninstall dynamo-platform -n dynamo-system; kubectl delete ns dynamo-system`, then
   `kubectl delete crd <name>` for the six CRDs above, and `rm -rf ~/s4`.
