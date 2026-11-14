# 19. Run a job without naming a GPU vendor: AIJob

> Status: done (T-133). Tested on the lab cluster on 2026-11-14: `tests/lab/t133-aijob.sh` 17/17
> ([evidence](../evidence/T-133/01-lab.txt)). The lab has one GPU per worker: every job there is one pod with one GPU.

## What you get

An `AIJob` says what to run and how many GPUs, not whose. oif picks NVIDIA or AMD, creates a plain Kubernetes Job on
that vendor, and Run:ai's scheduler places it under the project's GPU quota, as any other job in the project.

- **Vendor choice**, before the Job exists (a pod must name `nvidia.com/gpu` or `amd.com/gpu`; the scheduler cannot
  choose between them): `preferVendor` when it has room for all the job's GPUs, else a vendor with room, else the
  preferred (or first) vendor, where the job waits. Room comes from the AcceleratorDomain view (guide 17), refreshed
  every 30 s. Without a preference the vendors are tried in the project's PlacementPolicy order (below), else NVIDIA
  first.
- **One vendor per job**, always: `allowCrossVendor: true` is refused, because no engine runs one job on both yet.
- **One domain**, when asked: `requireSameDomain: true` keeps all pods inside one accelerator domain (KAI topology,
  guide 17). `workers` greater than 1 starts the pods together (one gang) or not at all.
- **Status:** phase, vendor, the domains and nodes the pods run on, `crossVendor: false`, and why that vendor.
- The container gets `OIF_GPU_VENDOR`, and `OIF_MODEL` and `OIF_PRECISION` when the AIJob names them.

An AIJob sets only image, command, args and env: no host paths, privileges or other pod fields. Its spec cannot change;
delete it and create it again. Deleting it deletes its Job and pods.

## Before you start

- oif installed with GPUs (stage `aijob` runs after `runai-topology`), and a Run:ai project: create AIJobs in its
  namespace (`runai-<project>`). Elsewhere the AIJob fails with "not a Run:ai project".
- Anyone who may edit the namespace may create AIJobs there (the `edit` and `admin` roles include them).

## Submit one

```yaml
apiVersion: oif.ai/v1alpha1
kind: AIJob
metadata:
  name: finetune-qwen
  namespace: runai-team-a
spec:
  model: Qwen/Qwen3-8B          # optional: passed as OIF_MODEL
  precision: bf16               # optional: passed as OIF_PRECISION
  gpuCount: 1                   # GPUs per pod
  workers: 1                    # pods (default 1)
  template:
    image: docker.io/library/busybox:1.37.0
    command: ["sh", "-c", "echo running on $OIF_GPU_VENDOR; sleep 600"]
  placement:                    # all optional
    preferVendor: amd           # nvidia | amd: a preference, not a rule
    requireSameDomain: false
```

```bash
kubectl apply -f finetune-qwen.yaml
kubectl -n runai-team-a get aijobs
```

```text
NAME            VENDOR   PHASE     DOMAINS       NODES         AGE
finetune-qwen   amd      Running   ["gpu-amd"]   ["gpu-amd"]   40s
```

`kubectl -n runai-team-a get aijob finetune-qwen -o jsonpath='{.status.message}'` says why: `amd: the preferred vendor,
it has room`. The Job has the AIJob's name: `kubectl -n runai-team-a logs job/finetune-qwen`.

## Defaults per project: PlacementPolicy (T-134)

A PlacementPolicy named `default` in a project's namespace sets what that project's AIJobs get when they do not say;
one named `default` in namespace `oif-aijob` applies to every project without its own. The namespace's wins, field by
field, and an AIJob's own fields win over both.

```yaml
apiVersion: oif.ai/v1alpha1
kind: PlacementPolicy
metadata:
  name: default
  namespace: runai-team-a
spec:
  vendorPriority: [amd, nvidia]   # the order vendors are tried in when an AIJob has no preferVendor; left out: last
  requireSameDomain: true         # for AIJobs that do not set it
```

```bash
kubectl -n runai-team-a get placementpolicy
```

```text
NAME      VENDOR-PRIORITY      REQUIRE-SAME-DOMAIN
default   ["amd","nvidia"]     true
```

The order is soft like `preferVendor`: a vendor without room is passed over. Only `nvidia` and `amd` are accepted, each
once. A namespace's admins set its policy; editors can read it. The AIJob's status message names the policy that
applied (`amd: it has room for 1 GPUs (PlacementPolicy runai-team-a/default)`). A policy applies when the AIJob is
created: changing it later does not move a job. Not offered (they would do nothing today): `allowCrossVendor` (only
false is possible) and `preferSameDomain` (Run:ai already prefers packing every workload, guide 17).

```bash
sudo tests/lab/t134-policy.sh
```

In Grafana (T-135, guide 7): OIF Scheduling, row "Accelerator domains and AIJobs": AIJob GPUs by vendor and phase (`oif:aijob_gpu_requested`) and the count of AIJobs on more than one vendor (`oif:aijob_cross_vendor`, 0).

## Check it worked

```bash
sudo tests/lab/t133-aijob.sh
```

It checks the admission rules, a job that prefers AMD (runs on AMD), one that prefers AMD while AMD is busy (runs on
NVIDIA), one with no vendor, the status fields, and that a plain GPU pod is not touched.

## What changed on the cluster

- CRD `aijobs.oif.ai`, namespace `oif-aijob` with Deployment `oif-aijob` (image built by oif from images/oif-aijob,
  one replica on a system node; it lists AIJobs, Jobs, pods, nodes, namespaces and AcceleratorDomains, and creates Jobs),
  ClusterRoles `oif-aijob`, `oif-aijob-edit` and `oif-placementpolicy-admin`; CRD `placementpolicies.oif.ai` (T-134).
- Without GPUs the stage removes all of it, with every AIJob, its Job and every PlacementPolicy. `oif uninstall` removes it with the cluster.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `cross-vendor jobs (allowCrossVendor: true) are not supported yet` | Leave `allowCrossVendor` out or set it to false. |
| `an AIJob's spec cannot change` | Delete the AIJob and create it again. |
| Phase `Failed`, message `not a Run:ai project` | Create the AIJob in a project's namespace (`kubectl get ns -l runai/queue`). |
| Phase `Pending` for long | The project's quota or the vendor's GPUs are taken: `kubectl -n <ns> describe pod -l oif.ai/aijob=<name>` shows the scheduler's reason. |
| The vendor is not the preferred one | The preferred vendor had no room when the AIJob was created (status message). The choice is made once. |
| `Pending` on a busy vendor while the other is free | When the AIJob was created neither had room in the view (it is up to 30 s old, and pods that are stopping still count), so it waits on the first in order. The choice is not revisited: delete the AIJob and create it again. |
