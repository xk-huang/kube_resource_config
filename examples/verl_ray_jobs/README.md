# KubeRay

`kuberay-operator-*` is just the controller pod. Your actual Ray workload pods like
`ray-3x8xa100-head-*` and `ray-3x8xa100-gpu-workers-*` come from a `RayCluster`
or `RayJob` manifest.

This repo now includes:

- `raycluster-3x8xa100.yaml`: fixed-size Ray cluster with 1 head + 2 workers
- `rayjob-3x8xa100.yaml`: same cluster shape, but runs one entrypoint job and
  tears the cluster down after completion

Apply and inspect:

```bash
kubectl apply -f ./raycluster-3x8xa100.yaml
kubectl get rayclusters
kubectl get pods | grep ray-3x8xa100
kubectl describe raycluster ray-3x8xa100
kubectl logs -f <ray-head-pod>
```

Delete:

```bash
kubectl delete -f ./raycluster-3x8xa100.yaml
```

If you want a one-shot training/inference run instead of a long-lived cluster,
edit the `entrypoint` in `rayjob-3x8xa100.yaml` and use:

```bash
kubectl apply -f ./rayjob-3x8xa100.yaml
kubectl get rayjobs
kubectl describe rayjob rayjob-3x8xa100
kubectl logs -f <ray-job-submit-or-head-pod>
```
