#!/usr/bin/env bash
set -euo pipefail

kubectl_bin="${KUBECTL_BIN:-kubectl}"
kubectl_cmd=("$kubectl_bin")
pod_workdir="${POD_WORKDIR:-$PWD}"

usage() {
  echo "Usage: $0 [--cwd pod_workdir] <pod_name> [container_name] -- <command> [args...]"
  echo "Environment: KUBECTL_BIN=kubectl KUBECTL_NAMESPACE=<namespace> POD_WORKDIR=<path>"
  echo "Notes:"
  echo "  - Non-interactive command runner for automation and agents."
  echo "  - Defaults POD_WORKDIR to the current host directory: $PWD"
  echo "Examples:"
  echo "  $0 2x8xa100-80gb-0 -- python -m torch.distributed.run --nproc_per_node=8 train.py"
  echo "  $0 --cwd /fsx/xhuan192/code/kube_resource_config 2x8xa100-80gb-0 trainer -- bash -lc 'pwd && id'"
}

if ! command -v "$kubectl_bin" >/dev/null 2>&1; then
  echo "kubectl not found: $kubectl_bin" >&2
  exit 1
fi

if [ -n "${KUBECTL_NAMESPACE:-}" ]; then
  kubectl_cmd+=(-n "$KUBECTL_NAMESPACE")
fi

positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --cwd)
      shift
      if [ "$#" -eq 0 ]; then
        echo "missing value for --cwd" >&2
        exit 1
      fi
      pod_workdir="$1"
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [ "${#positional[@]}" -lt 1 ] || [ "${#positional[@]}" -gt 2 ]; then
  usage
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "missing command after --" >&2
  usage
  exit 1
fi

pod_name="${positional[0]}"
container_name="${positional[1]:-}"
command=("$@")

if ! "${kubectl_cmd[@]}" get pod "$pod_name" >/dev/null 2>&1; then
  if "${kubectl_cmd[@]}" get statefulset "$pod_name" >/dev/null 2>&1; then
    echo "statefulset found: $pod_name, use a pod name by appending \"-<ordinal>\" (for example, \"${pod_name}-0\")" >&2
    exit 1
  fi

  echo "pod or statefulset not found: $pod_name, see available pods:" >&2
  "${kubectl_cmd[@]}" get pods
  exit 1
fi

read -r -a containers <<< "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{range .spec.containers[*]}{.name}{' '}{end}")"

if [ "${#containers[@]}" -eq 0 ]; then
  echo "pod $pod_name has no containers" >&2
  exit 1
fi

if [ -z "$container_name" ]; then
  if [ "${#containers[@]}" -gt 1 ]; then
    echo "pod $pod_name has multiple containers, set [container_name]" >&2
    echo "available containers: ${containers[*]}" >&2
    exit 1
  fi
  container_name="${containers[0]}"
else
  container_found=0
  for candidate in "${containers[@]}"; do
    if [ "$candidate" = "$container_name" ]; then
      container_found=1
      break
    fi
  done

  if [ "$container_found" -ne 1 ]; then
    echo "container not found: $container_name in pod $pod_name" >&2
    echo "available containers: ${containers[*]}" >&2
    exit 1
  fi
fi

if [ "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container_name\")].ready}")" != "true" ]; then
  echo "container not ready: $container_name in pod $pod_name" >&2
  exit 1
fi

user_name="$(id -un)"
user_uid="$(id -u)"
user_gid="$(id -g)"

"${kubectl_cmd[@]}" exec -i "$pod_name" -c "$container_name" -- bash -s -- \
  "$user_name" "$user_uid" "$user_gid" "$pod_workdir" "${command[@]}" <<'EOF'
set -euo pipefail

user_name="$1"
user_uid="$2"
user_gid="$3"
workdir="$4"
shift 4

if [ "$#" -eq 0 ]; then
  echo "missing command to execute" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ] && [ "$(id -u)" -ne "$user_uid" ]; then
  echo "container session must start as root or already be uid $user_uid" >&2
  exit 1
fi

run_cmd=(bash -lc 'set -euo pipefail; workdir="$1"; shift; if [ -n "$workdir" ]; then cd "$workdir"; fi; exec "$@"' bash "$workdir" "$@")

if [ "$(id -u)" -eq "$user_uid" ]; then
  exec "${run_cmd[@]}"
fi

for tool in getent groupadd useradd; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool in container: $tool" >&2
    exit 1
  fi
done

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

if command -v sudo >/dev/null 2>&1; then
  exec sudo -H -u "$user_name" -- "${run_cmd[@]}"
fi

if command -v runuser >/dev/null 2>&1; then
  exec runuser -u "$user_name" -- "${run_cmd[@]}"
fi

if command -v setpriv >/dev/null 2>&1; then
  exec env HOME="$home_dir" USER="$user_name" LOGNAME="$user_name" \
    setpriv --reuid "$user_uid" --regid "$user_gid" --init-groups "${run_cmd[@]}"
fi

if command -v su >/dev/null 2>&1; then
  quoted_cmd="$(printf '%q ' "${run_cmd[@]}")"
  exec su -s /bin/bash "$user_name" -c "$quoted_cmd"
fi

echo "need one of sudo, runuser, setpriv, or su in the container to switch users" >&2
exit 1
EOF
