#!/usr/bin/env bash
set -euo pipefail

kubectl_bin="${KUBECTL_BIN:-kubectl}"
kubectl_cmd=("$kubectl_bin")


# Show basic usage and current pod choices.
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "$#" -eq 0 ]; then
  echo "Usage: $0 [pod_name] [container_name]"
  echo "Environment: KUBECTL_BIN=kubectl KUBECTL_NAMESPACE=<namespace>"
  echo "Interactive login shell only. For non-interactive automation, use ./run_pod_command_as_host_user.sh"
  echo "See available pods:"
  "${kubectl_cmd[@]}" get pods
  exit 0
fi

pod_name="${1:-}"
container_name="${2:-}"

if [ -n "${KUBECTL_NAMESPACE:-}" ]; then
  kubectl_cmd+=(-n "$KUBECTL_NAMESPACE")
fi

if ! command -v "$kubectl_bin" >/dev/null 2>&1; then
  echo "kubectl not found: $kubectl_bin" >&2
  exit 1
fi


# Resolve the target pod first; a StatefulSet name is not directly exec-able.
if ! "${kubectl_cmd[@]}" get pod "$pod_name" >/dev/null 2>&1; then

  if "${kubectl_cmd[@]}" get statefulset "$pod_name" >/dev/null 2>&1; then
    echo "statefulset found: $pod_name, use a pod name by appending \"-<ordinal>\" (for example, \"${pod_name}-0\")" >&2
    exit 1
  fi

  echo "pod or statefulset not found: $pod_name, see available pods:" >&2
  "${kubectl_cmd[@]}" get pods
	exit 1
fi


# Read container names once so selection and validation stay consistent.
read -r -a containers <<< "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{range .spec.containers[*]}{.name}{' '}{end}")"


# Caveat: this should not happen for a normal running pod, but fail clearly if it does.
if [ "${#containers[@]}" -eq 0 ]; then
  echo "pod $pod_name has no containers" >&2
  exit 1
fi


# Auto-pick the only container, otherwise require an explicit match.
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


# Caveat: readiness is checked from containerStatuses, which may lag right after pod updates.
if [ "$("${kubectl_cmd[@]}" get pod "$pod_name" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container_name\")].ready}")" != "true" ]; then
  echo "container not ready: $container_name in pod $pod_name" >&2
  exit 1
fi


# Mirror the local host identity inside the container session.
user_name="$(id -un)"
user_uid="$(id -u)"
user_gid="$(id -g)"


# Bootstrap a matching user inside the container, then switch into that login shell.
"${kubectl_cmd[@]}" exec -it "$pod_name" -c "$container_name" -- bash -lc '
set -euo pipefail

user_name="$1"
user_uid="$2"
user_gid="$3"


# Caveat: package install and user management require the exec session to start as root.
if [ "$(id -u)" -ne 0 ]; then
  echo "container session must start as root" >&2
  exit 1
fi


# Track the supported package manager once so required and optional installs stay separate.
pkg_manager=""
if command -v apt-get >/dev/null 2>&1; then
  pkg_manager="apt-get"
elif command -v dnf >/dev/null 2>&1; then
  pkg_manager="dnf"
elif command -v yum >/dev/null 2>&1; then
  pkg_manager="yum"
fi


install_packages() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  if [ -z "$pkg_manager" ]; then
    echo "missing packages: $*; no supported package manager was found" >&2
    exit 1
  fi

  if [ "$pkg_manager" = "apt-get" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "$@"
  else
    "$pkg_manager" install -y "$@"
  fi
}


# Install sudo only when missing; package-manager support is intentionally narrow.
if ! command -v sudo >/dev/null 2>&1; then
  install_packages sudo
fi


# Install interactive tools independently so they do not depend on sudo being absent.
missing_tools=()
for tool in zsh tmux ffmpeg; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done
if [ "${#missing_tools[@]}" -gt 0 ]; then
  install_packages "${missing_tools[@]}"
fi


# Fail fast if the base image lacks standard Linux account-management tools.
if ! command -v groupadd >/dev/null 2>&1 || ! command -v useradd >/dev/null 2>&1; then
  echo "groupadd and useradd are required in the container" >&2
  exit 1
fi


# Reuse an existing group for the gid when possible, otherwise create one.
group_name="$(getent group "$user_gid" | cut -d: -f1 || true)"
if [ -z "$group_name" ]; then
  if getent group "$user_name" >/dev/null 2>&1; then
    echo "group $user_name already exists with gid $(getent group "$user_name" | cut -d: -f3), expected $user_gid" >&2
    exit 1
  fi
  groupadd -g "$user_gid" "$user_name"
  group_name="$user_name"
fi


# Reuse the username only if its uid/gid already matches the host identity.
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


# Ensure the login home exists and is owned by the mapped user.
home_dir="$(getent passwd "$user_name" | cut -d: -f6)"
if [ -z "$home_dir" ]; then
  home_dir="/home/$user_name"
fi
mkdir -p "$home_dir"
chown "$user_uid:$user_gid" "$home_dir"


# Grant passwordless sudo for the interactive session.
install -d -m 0755 /etc/sudoers.d
printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$user_name" > "/etc/sudoers.d/90-$user_name"
chmod 0440 "/etc/sudoers.d/90-$user_name"


# Hand off to the mapped user as a login shell.
exec sudo -u "$user_name" -i
' bash "$user_name" "$user_uid" "$user_gid"
