# How To Get `MASTER_ADDR` For Torch Distributed Training On This StatefulSet

For this repository, the correct `MASTER_ADDR` for the 2-node A100 StatefulSet is:

`2x8xa100-80gb-0.svc-2x8xa100-80gb`

## Why It Has This Format

Kubernetes `StatefulSet` pods have stable names:

`<statefulset-name>-<ordinal>`

In [`2x8xa100-80gb-sts.yaml`](/fsx/xhuan192/code/kube_resource_config/2x8xa100-80gb-sts.yaml#L5), the StatefulSet name is:

`2x8xa100-80gb`

The replicas are:

`2`

So Kubernetes creates these pod names:

- `2x8xa100-80gb-0`
- `2x8xa100-80gb-1`

The StatefulSet also declares:

`serviceName: svc-2x8xa100-80gb`

That service is defined in [`2x8xa100-80gb-svc.yaml`](/fsx/xhuan192/code/kube_resource_config/2x8xa100-80gb-svc.yaml#L1) and is a headless service because it sets:

`clusterIP: None`

For a StatefulSet behind a headless service, Kubernetes publishes stable DNS entries for each pod using:

`<pod-name>.<service-name>`

So pod 0 becomes:

`2x8xa100-80gb-0.svc-2x8xa100-80gb`

This is the address used as `MASTER_ADDR`.

## Why Torch Uses Pod 0

For multi-node `torchrun`, all workers need a common rendezvous endpoint. One process group member acts as rank 0, and every node points to the same:

- `MASTER_ADDR`
- `MASTER_PORT`

Using pod `-0` is the standard choice because its name is deterministic. You do not need to discover an IP dynamically, and the name stays stable across pod restarts.

## How To Derive It Yourself

Use this formula:

`MASTER_ADDR = <statefulset-name>-0.<service-name>`

For this repo:

- `<statefulset-name>` = `2x8xa100-80gb`
- `<service-name>` = `svc-2x8xa100-80gb`

Result:

`2x8xa100-80gb-0.svc-2x8xa100-80gb`

If needed, the fully qualified cluster DNS name is:

`2x8xa100-80gb-0.svc-2x8xa100-80gb.<namespace>.svc.cluster.local`

## Example

```bash
# pod 0
torchrun \
  --nnodes=2 \
  --nproc-per-node=8 \
  --node-rank=0 \
  --master-addr=2x8xa100-80gb-0.svc-2x8xa100-80gb \
  --master-port=29500 \
  ddp_smoke.py

# pod 1
torchrun \
  --nnodes=2 \
  --nproc-per-node=8 \
  --node-rank=1 \
  --master-addr=2x8xa100-80gb-0.svc-2x8xa100-80gb \
  --master-port=29500 \
  ddp_smoke.py
```

The repo already uses this exact value in [`ddp_smoke.py`](/fsx/xhuan192/code/kube_resource_config/ddp_smoke.py#L10).

## How To Verify DNS Resolution

From inside one of the pods:

```bash
getent hosts 2x8xa100-80gb-0.svc-2x8xa100-80gb
```

The repository README shows the same check in [`README.md`](/fsx/xhuan192/code/kube_resource_config/README.md#L76).

## Summary

- `StatefulSet` gives stable pod names.
- The headless service gives stable per-pod DNS records.
- `torchrun` needs one stable rendezvous address.
- Pod `-0` is used as rank 0, so `MASTER_ADDR` is `2x8xa100-80gb-0.svc-2x8xa100-80gb`.
