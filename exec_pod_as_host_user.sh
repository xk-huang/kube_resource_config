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
kubectl_bin="${KUBECTL_BIN:-kubectl}"

kubectl_cmd=("$kubectl_bin")
if [ -n "${KUBECTL_NAMESPACE:-}" ]; then
  kubectl_cmd+=(-n "$KUBECTL_NAMESPACE")
fi

if ! command -v "$kubectl_bin" >/dev/null 2>&1; then
  echo "kubectl not found: $kubectl_bin" >&2
  exit 1
fi

if ! "${kubectl_cmd[@]}" get pod "$pod_name" >/dev/null 2>&1; then
  if "${kubectl_cmd[@]}" get statefulset "$target_name" >/dev/null 2>&1; then
    pod_name="$target_name-$pod_ordinal"
  else
    echo "pod or statefulset not found: $target_name" >&2
    exit 1
  fi
fi

if ! "${kubectl_cmd[@]}" get pod "$pod_name" >/dev/null 2>&1; then
  echo "pod not found: $pod_name" >&2
  exit 1
fi

if [ -z "$container_name" ]; then
  read -r -a containers <<< "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{range .spec.containers[*]}{.name}{' '}{end}")"
  if [ "${#containers[@]}" -ne 1 ]; then
    echo "pod $pod_name has multiple containers, set CONTAINER_NAME" >&2
    exit 1
  fi
  container_name="${containers[0]}"
fi

if [ "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{.spec.containers[?(@.name==\"$container_name\")].name}")" != "$container_name" ]; then
  echo "container not found: $container_name in pod $pod_name" >&2
  exit 1
fi

if [ "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container_name\")].ready}")" != "true" ]; then
  echo "container not ready: $container_name in pod $pod_name" >&2
  exit 1
fi

"${kubectl_cmd[@]}" exec -it "$pod_name" -c "$container_name" -- bash -lc '
set -euo pipefail

user_name="$1"
user_uid="$2"
user_gid="$3"

if [ "$(id -u)" -ne 0 ]; then
  echo "container session must start as root" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sudo
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo
  else
    echo "sudo is missing and no supported package manager was found" >&2
    exit 1
  fi
fi

if ! command -v groupadd >/dev/null 2>&1 || ! command -v useradd >/dev/null 2>&1; then
  echo "groupadd and useradd are required in the container" >&2
  exit 1
fi

group_name="$(getent group "$user_gid" | cut -d: -f1 || true)"
if [ -z "$group_name" ]; then
  if getent group "$user_name" >/dev/null 2>&1; then
    echo "group $user_name already exists with gid $(getent group "$user_name" | cut -d: -f3), expected $user_gid" >&2
    exit 1
  fi
  groupadd -g "$user_gid" "$user_name"
  group_name="$user_name"
fi

if getent passwd "$user_name" >/dev/null 2>&1; then
  if [ "$(id -u "$user_name")" != "$user_uid" ]; then
    echo "user $user_name already exists with uid $(id -u "$user_name"), expected $user_uid" >&2
    exit 1
  fi
  if [ "$(id -g "$user_name")" != "$user_gid" ]; then
    echo "user $user_name already exists with gid $(id -g "$user_name"), expected $user_gid" >&2
    exit 1
  fi
else
  uid_owner="$(getent passwd "$user_uid" | cut -d: -f1 || true)"
  if [ -n "$uid_owner" ]; then
    echo "uid $user_uid is already owned by $uid_owner" >&2
    exit 1
  fi
  useradd -m -u "$user_uid" -g "$group_name" -s /bin/bash "$user_name"
fi

home_dir="$(getent passwd "$user_name" | cut -d: -f6)"
if [ -z "$home_dir" ]; then
  home_dir="/home/$user_name"
fi
mkdir -p "$home_dir"
chown "$user_uid:$user_gid" "$home_dir"

install -d -m 0755 /etc/sudoers.d
printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$user_name" > "/etc/sudoers.d/90-$user_name"
chmod 0440 "/etc/sudoers.d/90-$user_name"

exec sudo -u "$user_name" -i
' bash "$user_name" "$user_uid" "$user_gid"
