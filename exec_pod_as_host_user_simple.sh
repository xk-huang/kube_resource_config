#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: $0 [pod_name|statefulset_name]"
  echo "Environment: CONTAINER_NAME=<name> POD_ORDINAL=0 KUBECTL_BIN=kubectl KUBECTL_NAMESPACE=<namespace>"
  exit 0
fi

target_name="${1:-1x8xa100-80gb}"
pod_name="$target_name"
container_name="${CONTAINER_NAME:-}"
pod_ordinal="${POD_ORDINAL:-0}"
user_name="$(id -un)"
user_uid="$(id -u)"
user_gid="$(id -g)"
kubectl_cmd=("${KUBECTL_BIN:-kubectl}")

if [ -n "${KUBECTL_NAMESPACE:-}" ]; then
  kubectl_cmd+=(-n "$KUBECTL_NAMESPACE")
fi

if ! "${kubectl_cmd[@]}" get pod "$pod_name" >/dev/null 2>&1; then
  if "${kubectl_cmd[@]}" get statefulset "$target_name" >/dev/null 2>&1; then
    pod_name="$target_name-$pod_ordinal"
  fi
fi

if [ -z "$container_name" ]; then
  read -r -a containers <<< "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{range .spec.containers[*]}{.name}{' '}{end}")"
  if [ "${#containers[@]}" -ne 1 ]; then
    echo "pod $pod_name has multiple containers, set CONTAINER_NAME" >&2
    exit 1
  fi
  container_name="${containers[0]}"
fi

"${kubectl_cmd[@]}" exec -it "$pod_name" -c "$container_name" -- bash -lc '
set -euo pipefail

user_name="$1"
user_uid="$2"
user_gid="$3"

if ! command -v sudo >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sudo
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo
  else
    yum install -y sudo
  fi
fi

getent group "$user_gid" >/dev/null 2>&1 || groupadd -g "$user_gid" "$user_name"
getent passwd "$user_name" >/dev/null 2>&1 || useradd -m -u "$user_uid" -g "$user_gid" -s /bin/bash "$user_name"
install -d -m 0755 /etc/sudoers.d
printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$user_name" > "/etc/sudoers.d/90-$user_name"
chmod 0440 "/etc/sudoers.d/90-$user_name"

exec sudo -u "$user_name" -i
' bash "$user_name" "$user_uid" "$user_gid"
