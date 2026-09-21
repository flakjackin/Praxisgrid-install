#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${PRAXISGRID_TARGET:-auto}"

usage() {
  cat <<'EOF'
Install PraxisGrid and its first execution runner.

Usage:
  ./install.sh [linux|macos|kubernetes] [--yes] [--build-local] [--no-apparmor]
               [--emulator]

With no target, the installer detects Ubuntu and any reachable kubectl context.
It only asks you to choose when both are available.

On macOS, the Docker Desktop installer uses named Linux volumes so SQLite,
repository worktrees, and CLI identities retain POSIX ownership and locking.

On Windows, run deploy/windows/install.ps1 from PowerShell instead. It checks
WSL2 and Docker and then runs this same Linux path inside the distribution --
there is no native Windows install, and the runner is a Linux container either
way. Inside a WSL2 Ubuntu distribution this script works unchanged.

On a fresh Ubuntu host this is the only command needed: Docker Engine and the
Compose v2 plugin are installed from Docker's own apt repository when missing.
Released container images are pulled by default; --build-local builds them from
this checkout instead. --yes answers every prompt, for an unattended install.

PRAXISGRID_ADMIN_PASSWORD sets the first administrator password without a
prompt, which --yes cannot do on its own.

--emulator adds an Android device for the emulator preview surface, on the
Linux target only. It is a separate container because it needs /dev/kvm and
the runner holds every credential this deployment has; the host must expose
that device, and the ~4 GB image is built from a checkout rather than pulled.
On Kubernetes the device is k8s/android-emulator.yaml, applied deliberately.

On Kubernetes the installer offers to load the praxisgrid-runner AppArmor
profile onto every node. Codex sandboxes its own tool calls with bubblewrap,
and containerd's default profile denies the mounts bubblewrap needs, so
without it a Codex provider fails every run. --apparmor loads it without
asking and --no-apparmor skips it; skipping is safe, and the Runners page then
explains what to do. It has no effect on the Linux target, where the runner is
a Docker container and the same choice is made with Docker's own profile.

Private release images take one credential per host, supplied once and stored
by Docker:
  sudo PRAXISGRID_REGISTRY_USERNAME=<user> PRAXISGRID_REGISTRY_PASSWORD=<token> \
       ./install.sh linux
EOF
}

for argument in "$@"; do
  case "$argument" in
    linux|ubuntu) TARGET="linux" ;;
    macos|mac) TARGET="macos" ;;
    kubernetes|k8s) TARGET="kubernetes" ;;
    --yes|-y) export PRAXISGRID_YES=1 ;;
    --build-local) export PRAXISGRID_BUILD_LOCAL=1 ;;
    --apparmor) export PRAXISGRID_APPARMOR=1 ;;
    --emulator) export PRAXISGRID_ANDROID_EMULATOR=1 ;;
    --no-emulator) export PRAXISGRID_ANDROID_EMULATOR=0 ;;
    --no-apparmor) export PRAXISGRID_APPARMOR=0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $argument" >&2; usage >&2; exit 2 ;;
  esac
done

is_ubuntu=0
if [[ -r /etc/os-release ]] && grep -qi '^ID=ubuntu' /etc/os-release; then
  is_ubuntu=1
fi
is_macos=0
if [[ "$(uname -s)" == "Darwin" ]]; then
  is_macos=1
fi
# A WSL2 Ubuntu distribution is an Ubuntu host as far as every check here is
# concerned, and the Linux target is the right one for it. Detected only so
# the messages can be true -- "this Ubuntu machine" is a distribution, and the
# Kubernetes context a Docker Desktop install exposes is on the same computer
# rather than somewhere else.
is_wsl=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || { [[ -r /proc/sys/kernel/osrelease ]] \
   && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; }; then
  is_wsl=1
fi
# A Kubernetes install applies the manifests in k8s/, so it exists only in a
# checkout. The published installer carries the two compose paths and this
# dispatcher, and a machine that merely has a kubectl context must not be
# offered a target whose script is not here -- the offer would be accepted and
# then fail on a missing file.
has_kubernetes_installer=0
[[ -x "$SCRIPT_DIR/deploy/kubernetes/install.sh" ]] && has_kubernetes_installer=1

has_cluster=0
if [[ "$has_kubernetes_installer" == "1" ]] \
  && command -v kubectl >/dev/null 2>&1 \
  && kubectl config current-context >/dev/null 2>&1 \
  && kubectl cluster-info >/dev/null 2>&1; then
  has_cluster=1
fi

if [[ "$TARGET" == "auto" ]]; then
  if [[ "$is_ubuntu" == "1" && "$has_cluster" == "1" ]]; then
    context="$(kubectl config current-context)"
    echo "PraxisGrid can be installed in either location:"
    if [[ "$is_wsl" == "1" ]]; then
      echo "  1) This WSL distribution, ${WSL_DISTRO_NAME:-Ubuntu} (Docker Compose)"
    else
      echo "  1) This Ubuntu machine (Docker Compose)"
    fi
    echo "  2) Kubernetes context '$context'"
    if [[ ! -t 0 ]]; then
      echo "Choose explicitly: ./install.sh linux or ./install.sh kubernetes" >&2
      exit 2
    fi
    read -rp "Install target [1]: " choice
    case "${choice:-1}" in
      1) TARGET="linux" ;;
      2) TARGET="kubernetes" ;;
      *) echo "Enter 1 or 2." >&2; exit 2 ;;
    esac
  elif [[ "$is_macos" == "1" && "$has_cluster" == "1" ]]; then
    context="$(kubectl config current-context)"
    echo "PraxisGrid can be installed in either location:"
    echo "  1) This Mac (Docker Desktop)"
    echo "  2) Kubernetes context '$context'"
    if [[ ! -t 0 ]]; then
      echo "Choose explicitly: ./install.sh macos or ./install.sh kubernetes" >&2
      exit 2
    fi
    read -rp "Install target [1]: " choice
    case "${choice:-1}" in
      1) TARGET="macos" ;;
      2) TARGET="kubernetes" ;;
      *) echo "Enter 1 or 2." >&2; exit 2 ;;
    esac
  elif [[ "$has_cluster" == "1" ]]; then
    TARGET="kubernetes"
  elif [[ "$is_macos" == "1" ]]; then
    TARGET="macos"
  elif [[ "$is_ubuntu" == "1" ]]; then
    TARGET="linux"
  else
    echo "No supported target was detected." >&2
    echo "Use Ubuntu or macOS with Docker, or configure a reachable kubectl context." >&2
    echo "On Windows, run deploy/windows/install.ps1 from PowerShell." >&2
    exit 1
  fi
fi

# Refused by name rather than accepted and silently ignored. Only the Linux
# target has a Compose service for the device; a Mac has no /dev/kvm to give a
# container, and a cluster's device is a manifest that names a node.
if [[ "${PRAXISGRID_ANDROID_EMULATOR:-0}" == "1" && "$TARGET" != "linux" ]]; then
  if [[ "$TARGET" == "macos" ]]; then
    echo "--emulator is a Linux target option." >&2
    echo "" >&2
    echo "Docker Desktop's virtual machine does not pass /dev/kvm through to a" >&2
    echo "container, so the device cannot run beside the runner here. Run an" >&2
    echo "emulator on the Mac itself with Android Studio, and point the runner at" >&2
    echo "it: PRAXISGRID_ADB_SERVER_SOCKET=tcp:host.docker.internal:5037" >&2
  else
    echo "--emulator is a Linux target option." >&2
    echo "" >&2
    echo "On Kubernetes the device is k8s/android-emulator.yaml. It is applied" >&2
    echo "deliberately rather than by the installer, because three things have to" >&2
    echo "be true first and none can be asserted from a manifest -- the manifest's" >&2
    echo "own header lists them." >&2
  fi
  exit 2
fi

case "$TARGET" in
  linux)
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      exec "$SCRIPT_DIR/deploy/ubuntu/install.sh"
    fi
    echo "Installing PraxisGrid on this Ubuntu machine (sudo is required once)."
    exec sudo -E "$SCRIPT_DIR/deploy/ubuntu/install.sh"
    ;;
  macos)
    exec "$SCRIPT_DIR/deploy/macos/install.sh"
    ;;
  kubernetes)
    if [[ "$has_kubernetes_installer" != "1" ]]; then
      echo "A Kubernetes install applies the manifests in k8s/, which the published" >&2
      echo "installer does not carry. Clone the repository for that target:" >&2
      echo "  git clone https://github.com/flakjackin/PraxisGrid.git" >&2
      echo "  cd PraxisGrid && ./install.sh kubernetes" >&2
      exit 1
    fi
    exec "$SCRIPT_DIR/deploy/kubernetes/install.sh"
    ;;
esac
