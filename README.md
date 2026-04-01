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

```bash
# Start the statefulset and service
kubectl apply -f ./kube_resource_config/2x8xa100-80gb-svc.yaml
kubectl apply -f ./kube_resource_config/2x8xa100-80gb-sts.yaml

# Check the status of the statefulset and service
kubectl get statefulsets
kubectl describe sts 2x8xa100-80gb
kubectl get svc 2x8xa100-80gb

# Exec into the pods as your current host user
./exec_pod_as_host_user.sh 2x8xa100-80gb-0
./exec_pod_as_host_user.sh 2x8xa100-80gb-1

# Or target the StatefulSet name and pick the ordinal
POD_ORDINAL=0 ./exec_pod_as_host_user.sh 2x8xa100-80gb
POD_ORDINAL=1 ./exec_pod_as_host_user.sh 2x8xa100-80gb

# To delete the statefulset and service
kubectl delete statefulset 2x8xa100-80gb
kubectl delete service 2x8xa100-80gb
```


In the container

```bash
getent hosts 2x8xa100-80gb-0.2x8xa100-80gb
getent hosts 2x8xa100-80gb-1.2x8xa100-80gb

# nslookup 2x8xa100-80gb-0.2x8xa100-80gb

python -m http.server 29500
curl 2x8xa100-80gb-0.2x8xa100-80gb:29500
```


## Storage on AWS: EFS vs FSX

EFS is way slower than FSX.

FSX can be viewed as local SSD internally.

AWS Kubernetes use FSX.

The other AWS nodes use EFS.
