# Kubernetes

Show nodes

```bash
kubectl get nodes  --show-labels
```

```
NAME                                           STATUS   ROLES    AGE    VERSION               INTERNAL-IP      EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION                    CONTAINER-RUNTIME
ip-172-31-135-246.us-west-2.compute.internal   Ready    <none>   5d3h   v1.32.7-eks-3abbec1   172.31.135.246   <none>        Amazon Linux 2023.8.20250721   6.1.144-170.251.amzn2023.x86_64   containerd://1.7.27
ip-172-31-135-70.us-west-2.compute.internal    Ready    <none>   5d3h   v1.32.7-eks-3abbec1   172.31.135.70    <none>        Amazon Linux 2023.8.20250721   6.1.144-170.251.amzn2023.x86_64   containerd://1.7.27
ip-172-31-140-225.us-west-2.compute.internal   Ready    <none>   18d    v1.32.7-eks-3abbec1   172.31.140.225   <none>        Amazon Linux 2023.8.20250721   6.1.144-170.251.amzn2023.x86_64   containerd://1.7.27
ip-172-31-150-203.us-west-2.compute.internal   Ready    <none>   15d    v1.32.7-eks-3abbec1   172.31.150.203   <none>        Amazon Linux 2023.8.20250721   6.1.144-170.251.amzn2023.x86_64   containerd://1.7.27
(No GPU) ip-172-31-159-22.us-west-2.compute.internal    Ready    <none>   224d   v1.32.7-eks-3abbec1   172.31.159.22    <none>        Amazon Linux 2023.8.20250721   6.1.144-170.251.amzn2023.x86_64   containerd://1.7.27
```

The node types
- sys nodes: c5.24xlarge, no GPU
- trainer nodes: p4de.24xlarge, nvidia.com/gpu.count=8, nvidia.com/gpu.product=NVIDIA-A100-SXM4-80GB, feature.node.kubernetes.io/rdma.available=true

Check nodes resources

```bash
kubectl describe node ip-172-31-135-70.us-west-2.compute.internal
```


Show used pods

```bash
kubectl get pods -o wide
```

```
NAME              READY   STATUS    RESTARTS   AGE     IP               NODE                                           NOMINATED NODE   READINESS GATES
deepseek-worker   1/1     Running   0          5h58m   172.31.135.70    ip-172-31-135-70.us-west-2.compute.internal    <none>           <none>
sod-worker        1/1     Running   0          2d17h   172.31.140.225   ip-172-31-140-225.us-west-2.compute.internal   <none>           <none>
```


Start statefulset and service pods, check the status, and exec into the pods.

Service is for torch distributed training, as it provides stable network identity and DNS for the pods in the statefulset. Each pod can be accessed via a predictable hostname, which is crucial for distributed training where each worker needs to communicate with others.

```bash
# Start the statefulset and service
kubectl apply -f ./2x8xa100-80gb-svc.yaml
kubectl apply -f ./2x8xa100-80gb-sts.yaml

# Check the status of the statefulset and service
kubectl get statefulsets
kubectl describe sts 2x8xa100-80gb
kubectl get svc svc-2x8xa100-80gb

# Exec into the pods as your current host user
bash ./exec_pod_as_host_user.sh 2x8xa100-80gb-0
bash ./exec_pod_as_host_user.sh 2x8xa100-80gb-1

# Or target the StatefulSet name and pick the ordinal
POD_ORDINAL=0 bash ./exec_pod_as_host_user.sh 2x8xa100-80gb
POD_ORDINAL=1 bash ./exec_pod_as_host_user.sh 2x8xa100-80gb

# To delete the statefulset and service
kubectl delete statefulset 2x8xa100-80gb
kubectl delete service svc-2x8xa100-80gb


# Check pod status
kubectl describe pod <pod-name>
#  If running but app seems bad, use 
kubectl logs -f <pod-name>
```


In the container

```bash
getent hosts 2x8xa100-80gb-0.svc-2x8xa100-80gb
getent hosts 2x8xa100-80gb-1.svc-2x8xa100-80gb

# sudo apt install iputils-ping dnsutils
nslookup 2x8xa100-80gb-0.svc-2x8xa100-80gb

# Do not use it; the below command raises ticket on AWS
# python -m http.server 29500
# curl 2x8xa100-80gb-0.svc-2x8xa100-80gb:29500
```


## Storage on AWS: EFS vs FSX

EFS is way slower than FSX.

FSX can be viewed as local SSD internally.

AWS Kubernetes use FSX.

The other AWS nodes use EFS.


## Single node

```bash
kubectl apply -f 1x8xa100-80gb.yaml
kubectl delete pod 1x8xa100-80gb --grace-period=0 --force
```