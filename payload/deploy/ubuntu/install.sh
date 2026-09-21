#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${PRAXISGRID_ENV_FILE:-/etc/praxisgrid/praxisgrid.env}"
# The published installer is this script, the compose files and VERSION, and
# nothing else -- so it can be fetched without a credential. Building images
# needs the Dockerfiles and the whole build context, which only a checkout
# has. Refused here, by name, rather than several minutes later inside
# `docker compose build` with a "failed to read dockerfile" that names neither
# the cause nor the remedy.
if [[ "${PRAXISGRID_BUILD_LOCAL:-0}" == "1" && ! -f "$REPO_ROOT/Dockerfile" ]]; then
  echo "This is the published installer, which carries no Dockerfiles." >&2
  echo "" >&2
  echo "Building images needs the repository. Clone it and use its own entry point:" >&2
  echo "  git clone https://github.com/flakjackin/PraxisGrid.git" >&2
  echo "  cd PraxisGrid && sudo PRAXISGRID_BUILD_LOCAL=1 ./install.sh linux" >&2
  echo "" >&2
  echo "Or install the released images, which is the ordinary path:" >&2
  echo "  sudo $REPO_ROOT/install.sh linux" >&2
  exit 1
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this installer with sudo: sudo ./deploy/ubuntu/install.sh" >&2
  exit 1
fi
DATA_ROOT="${PRAXISGRID_DATA_ROOT:-/var/lib/praxisgrid}"
PORT="${PRAXISGRID_PORT:-8080}"
# Kept in step with deploy/ubuntu/compose.yaml, which reads the same two
# variables. Named here so the registry messages can print what was tried.
IMAGE_PREFIX="${PRAXISGRID_IMAGE_PREFIX:-ghcr.io/flakjackin/praxisgrid}"
RELEASE_TAG="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
# On an idempotent rerun, health-check the persisted port and prepare the
# persisted data root unless the operator explicitly overrides either one.
if [[ -s "$ENV_FILE" && -z "${PRAXISGRID_DATA_ROOT+x}" ]]; then
  DATA_ROOT="$(sed -n 's/^PRAXISGRID_DATA_ROOT=//p' "$ENV_FILE" | tail -1)"
  DATA_ROOT="${DATA_ROOT:-/var/lib/praxisgrid}"
fi
if [[ -s "$ENV_FILE" && -z "${PRAXISGRID_PORT+x}" ]]; then
  PORT="$(sed -n 's/^PRAXISGRID_PORT=//p' "$ENV_FILE" | tail -1)"
  PORT="${PORT:-8080}"
fi
# The registry this host was installed from is part of how it was configured,
# not a property of the shell that happened to run the installer. Compose reads
# PRAXISGRID_IMAGE_PREFIX from the env file at every `up`, so leaving it out
# meant a rerun without the variable exported silently recreated the backend,
# frontend and runner from ghcr `latest` -- a different release, on a host
# deliberately installed from a private registry.
if [[ -s "$ENV_FILE" && -z "${PRAXISGRID_IMAGE_PREFIX+x}" ]]; then
  persisted_prefix="$(sed -n 's/^PRAXISGRID_IMAGE_PREFIX=//p' "$ENV_FILE" | tail -1)"
  IMAGE_PREFIX="${persisted_prefix:-$IMAGE_PREFIX}"
fi
TAG="${PRAXISGRID_TAG:-$RELEASE_TAG}"
if [[ -s "$ENV_FILE" && -z "${PRAXISGRID_TAG+x}" ]]; then
  persisted_tag="$(sed -n 's/^PRAXISGRID_TAG=//p' "$ENV_FILE" | tail -1)"
  TAG="${persisted_tag:-$TAG}"
fi

if [[ ! -r /etc/os-release ]] || ! grep -qi '^ID=ubuntu' /etc/os-release; then
  echo "This installer supports Ubuntu hosts. Use deploy/kubernetes/install.sh for a cluster." >&2
  exit 1
fi

# An Ubuntu distribution under WSL2 satisfies every check above, and the
# containers it runs are the same Linux containers as on a bare host -- the
# runner never meets Windows. Two things about that host are different enough
# to change what this script says and what it refuses.
running_under_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  [[ -r /proc/sys/kernel/osrelease ]] \
    && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease
}
IS_WSL=0
running_under_wsl && IS_WSL=1

# The one that destroys an installation rather than inconveniencing it. A
# Windows drive appears under /mnt/<letter>, reached through the 9p/virtiofs
# translation layer, and it does not carry POSIX advisory locking across to
# the Windows filesystem underneath. The backend and the runner are two
# processes sharing one SQLite file -- that is the whole reason the runner is
# pinned to the host holding it -- so the failure is not "slow", it is two
# writers with no lock between them. It also cannot honour the ownership this
# script sets below, so the credential directory would be world-readable on a
# machine holding every identity's vendor CLI logins.
#
# Refused rather than warned about: the symptom is intermittent "database is
# locked", which reads as ordinary contention, and by the time it appears the
# board has history in it.
case "$DATA_ROOT" in
  /mnt/*)
    echo "PRAXISGRID_DATA_ROOT is on a Windows drive: $DATA_ROOT" >&2
    echo "" >&2
    echo "Paths under /mnt are the Windows filesystem seen through a translation" >&2
    echo "layer. It does not carry the file locking SQLite needs, and the backend" >&2
    echo "and runner share one database file, so this would corrupt the control" >&2
    echo "plane rather than merely slow it down. It also cannot hold the 0700" >&2
    echo "ownership the credential directory is given." >&2
    echo "" >&2
    echo "Use a path inside the Linux filesystem -- the default is fine:" >&2
    echo "  sudo ./install.sh linux            # /var/lib/praxisgrid" >&2
    echo "" >&2
    echo "Your Windows files stay reachable: mount a repository directory into" >&2
    echo "the runner separately if agents need to read one." >&2
    exit 1
    ;;
esac
confirm() {
  if [[ "${PRAXISGRID_YES:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "$1" >&2
    echo "Re-run with --yes to allow this without a prompt." >&2
    exit 1
  fi
  local reply
  read -rp "$1 [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

# A just-provisioned Ubuntu host has neither curl nor Docker. Installing them
# here is the difference between one command and a documented prerequisite
# list, and Docker's own apt repository is used rather than piping its
# convenience script into a shell -- the key and the source are both visible.
install_docker() {
  apt_install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [[ -z "$codename" ]]; then
    echo "Could not determine this Ubuntu release codename." >&2
    exit 1
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  # Starting the daemon is attempted, never required. Installing docker-ce
  # puts `systemctl` on PATH even where systemd is not PID 1 -- a container,
  # a WSL distribution without systemd -- and it then fails with "Failed to
  # connect to bus", which under `set -e` would abort an install whose only
  # real question is whether the daemon ends up reachable. The `docker info`
  # check below is that question, and it reports the answer directly.
  systemctl enable --now docker >/dev/null 2>&1 \
    || service docker start >/dev/null 2>&1 \
    || true
}

# Ubuntu Server ships python3, but a minimal or container image may not, and
# it derives the secrets below. Acquire it the same way as everything else
# rather than ending the install on a prerequisite apt can satisfy.
missing_base=()
command -v python3 >/dev/null 2>&1 || missing_base+=(python3)
command -v curl >/dev/null 2>&1 || missing_base+=(curl)
if [[ ${#missing_base[@]} -gt 0 ]]; then
  confirm "This host is missing: ${missing_base[*]}. Install with apt now?" || exit 1
  apt_install ca-certificates "${missing_base[@]}"
fi

if ! command -v docker >/dev/null 2>&1; then
  if [[ "$IS_WSL" == "1" ]]; then
    # Docker Desktop is the better answer on this host and cannot be installed
    # from in here: it is a Windows application, and its WSL integration puts
    # a working `docker` on PATH in every distribution without any of them
    # running a daemon. Said before the apt route rather than after, because
    # afterwards the operator has two.
    echo "No Docker in this WSL distribution."
    echo "Docker Engine can be installed here, and that is the ordinary path:"
    echo "Docker Desktop is not a prerequisite. systemd is enabled afterwards"
    echo "so the daemon comes back on its own."
    echo ""
    echo "If you already run Docker Desktop on Windows, cancel and enable its"
    echo "integration for '${WSL_DISTRO_NAME:-this distribution}' instead"
    echo "(Settings -> Resources -> WSL integration) -- two daemons on one host"
    echo "is the thing worth avoiding."
    echo ""
  fi
  confirm "Docker is not installed. Install Docker Engine and Compose v2 from Docker's official repository?" || exit 1
  echo "Installing Docker Engine and the Compose v2 plugin."
  install_docker
elif ! docker compose version >/dev/null 2>&1; then
  confirm "Docker is installed without the Compose v2 plugin. Install it now?" || exit 1
  echo "Installing the Docker Compose v2 plugin."
  install_docker
fi

for command in docker curl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command after installation: $command" >&2
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required (the 'docker compose' command)." >&2
  exit 1
fi
# A WSL distribution with no systemd has no PID 1 that can hold a service, so
# an installed Docker is not running and `systemctl enable --now docker` failed
# on a missing bus. Both halves are fixable from in here, and only one of them
# by this process: the sysvinit script Docker's deb ships starts the daemon for
# this session, and enabling systemd makes it come back -- but only after a
# `wsl --shutdown`, which is a Windows command a process inside the
# distribution cannot issue for itself.
if [[ "$IS_WSL" == "1" ]] && ! docker info >/dev/null 2>&1; then
  service docker start >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  if docker info >/dev/null 2>&1 \
     && ! grep -qE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null; then
    if { [[ -t 0 ]] || [[ "${PRAXISGRID_YES:-0}" == "1" ]]; } \
       && confirm "Enable systemd so Docker starts automatically in this distribution?"; then
      touch /etc/wsl.conf
      sed -i '/^[[:space:]]*systemd[[:space:]]*=/d' /etc/wsl.conf
      if grep -q '^\[boot\]' /etc/wsl.conf; then
        sed -i '0,/^\[boot\]/s//[boot]\nsystemd=true/' /etc/wsl.conf
      else
        printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
      fi
      echo "Enabled. It takes effect after 'wsl --shutdown' from Windows;"
      echo "Docker is already running for this session, so nothing is blocked."
    fi
  fi
fi

if ! docker info >/dev/null 2>&1; then
  if [[ "$IS_WSL" == "1" ]]; then
    echo "The Docker daemon is not reachable from this WSL distribution." >&2
    echo "" >&2
    echo "Either start Docker Desktop on Windows and enable integration for this" >&2
    echo "distribution (Settings -> Resources -> WSL integration), or run Docker" >&2
    echo "inside the distribution itself. A distribution without systemd will not" >&2
    echo "start it at boot -- enable systemd once and restart WSL:" >&2
    echo "" >&2
    echo "  printf '[boot]\\nsystemd=true\\n' | sudo tee -a /etc/wsl.conf" >&2
    echo "  # then, from Windows:  wsl --shutdown" >&2
    echo "" >&2
    echo "Or start it for this session only:  sudo service docker start" >&2
  else
    echo "The Docker daemon is not running. Start it with: systemctl start docker" >&2
  fi
  exit 1
fi

# The runner image creates /workspace/tools/bin and /workspace/worktrees, but
# the host bind mount shadows them, so they have to exist here too. The tool
# root is where a runtime-installed CLI such as Hermes lands, and it is first
# on the runner's PATH -- without it the install has nowhere to write and the
# tool is reported unavailable rather than installed.
mkdir -p "$(dirname "$ENV_FILE")" "$DATA_ROOT/data" "$DATA_ROOT/credentials" \
  "$DATA_ROOT/workspace" "$DATA_ROOT/workspace/tools/bin" \
  "$DATA_ROOT/workspace/worktrees" "$DATA_ROOT/repos"
chmod 700 "$(dirname "$ENV_FILE")" "$DATA_ROOT/credentials"
chown -R 10001:10001 "$DATA_ROOT/data" "$DATA_ROOT/credentials" "$DATA_ROOT/workspace" "$DATA_ROOT/repos"

if [[ ! -s "$ENV_FILE" ]]; then
  # An unattended install has no terminal to prompt at, and --yes cannot answer
  # this one: there is no default administrator password to agree to. Supplying
  # it in the environment is the only way to make the first install scriptable.
  # It is read once, hashed with scrypt, and never written down in clear.
  if [[ -n "${PRAXISGRID_ADMIN_PASSWORD:-}" ]]; then
    admin_password="$PRAXISGRID_ADMIN_PASSWORD"
    admin_confirm="$PRAXISGRID_ADMIN_PASSWORD"
  elif [[ ! -t 0 ]]; then
    echo "No terminal to read an administrator password from." >&2
    echo "Set PRAXISGRID_ADMIN_PASSWORD for an unattended install." >&2
    exit 1
  else
    read -rsp "New PraxisGrid administrator password (12+ characters): " admin_password
    echo
    read -rsp "Confirm password: " admin_confirm
    echo
  fi
  if [[ "$admin_password" != "$admin_confirm" ]]; then
    echo "Passwords do not match." >&2
    exit 1
  fi
  if [[ ${#admin_password} -lt 12 ]]; then
    echo "Password must contain at least 12 characters." >&2
    exit 1
  fi
  temp_env="$(mktemp)"
  # The program is written to a file rather than passed with `python3 -c '...'`.
  # Its own output contains a single quote -- the one that opens the stored
  # `'scrypt$...'` value -- which closed the shell's quoting and left
  # `$16384`, `$8` and `$1` to be expanded by bash. Under `set -u` the last of
  # those is unbound, so generating the environment file aborted the install:
  # first-time setup was the only path that ran this, and a rerun skips it.
  # A quoted heredoc cannot be reopened by anything the program prints, and
  # stdin stays free to carry the password rather than the program.
  temp_script="$(mktemp)"
  cat > "$temp_script" <<'PYTHON'
import base64, hashlib, secrets, sys
password = sys.stdin.read()
def enc(value): return base64.urlsafe_b64encode(value).decode().rstrip("=")
salt = secrets.token_bytes(16)
digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
print("ADMIN_PASSWORD_HASH='scrypt$16384$8$1$" + enc(salt) + "$" + enc(digest) + "'")
print("SESSION_SECRET=" + secrets.token_urlsafe(48))
print("PROVIDER_ENCRYPTION_KEY=" + base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())
PYTHON
  printf '%s' "$admin_password" | python3 "$temp_script" > "$temp_env"
  rm -f "$temp_script"
  {
    echo "PRAXISGRID_DATA_ROOT=$DATA_ROOT"
    echo "PRAXISGRID_PORT=$PORT"
    echo "PRAXISGRID_IMAGE_PREFIX=$IMAGE_PREFIX"
    echo "PRAXISGRID_TAG=$TAG"
    # Written out rather than left to a default in the compose file, so it is
    # visible and editable beside everything else the host was configured
    # with. A runner that names no organization claims nothing as soon as a
    # second one exists.
    echo "PRAXISGRID_ORGANIZATION_SLUG=praxisgrid"
    # Empty is the secure default: if Docker blocks Codex's inner bubblewrap
    # sandbox, that runner refuses Codex work. A disposable install can
    # explicitly accept the runner container as its boundary with
    # PRAXISGRID_CODEX_SANDBOX_MODE=danger-full-access.
    echo "PRAXISGRID_CODEX_SANDBOX_MODE=${PRAXISGRID_CODEX_SANDBOX_MODE:-}"
    echo "SECURE_COOKIE=false"
    echo "PRAXISGRID_ALLOW_SELF_SIGNUP=false"
  } >> "$temp_env"
  install -m 600 "$temp_env" "$ENV_FILE"
  rm -f "$temp_env"
  unset admin_password admin_confirm PRAXISGRID_ADMIN_PASSWORD
else
  echo "Reusing existing secrets in $ENV_FILE"
fi

cd "$REPO_ROOT"

# One registry login per host. Docker persists it in this user's
# ~/.docker/config.json, so every later pull -- a rerun, a restart, a
# `docker compose pull` by hand -- reuses it and nothing has to be supplied
# again. The credential is deliberately NOT copied into $ENV_FILE: Docker
# already stores it, and a second copy of a registry token is a second thing
# to leak and rotate.
#
# The installer runs under sudo, so it is root's credential store that
# matters. `docker login` run as the invoking user writes a different file,
# which is the failure this handles by name rather than as a denied pull.
REGISTRY_SERVER="${PRAXISGRID_REGISTRY_SERVER:-}"
if [[ -z "$REGISTRY_SERVER" && "$IMAGE_PREFIX" == ghcr.io/* ]]; then
  REGISTRY_SERVER="ghcr.io"
fi

registry_is_authenticated() {
  [[ -n "$REGISTRY_SERVER" ]] || return 1
  local config="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  [[ -s "$config" ]] || return 1
  python3 - "$config" "$REGISTRY_SERVER" <<'PYTHON'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        config = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
server = sys.argv[2]
auths = config.get("auths") or {}
stores = config.get("credHelpers") or {}
hit = server in auths or server in stores or config.get("credsStore")
raise SystemExit(0 if hit else 1)
PYTHON
}

if [[ -n "${PRAXISGRID_REGISTRY_USERNAME:-}" || -n "${PRAXISGRID_REGISTRY_PASSWORD:-}" ]]; then
  : "${PRAXISGRID_REGISTRY_USERNAME:?set PRAXISGRID_REGISTRY_USERNAME with PRAXISGRID_REGISTRY_PASSWORD}"
  : "${PRAXISGRID_REGISTRY_PASSWORD:?set PRAXISGRID_REGISTRY_PASSWORD with PRAXISGRID_REGISTRY_USERNAME}"
  echo "Signing in to $REGISTRY_SERVER as $PRAXISGRID_REGISTRY_USERNAME."
  # --password-stdin so the token never appears in argv or the process list.
  if ! printf '%s' "$PRAXISGRID_REGISTRY_PASSWORD" \
    | docker login "$REGISTRY_SERVER" --username "$PRAXISGRID_REGISTRY_USERNAME" --password-stdin; then
    echo "Registry sign-in failed for $REGISTRY_SERVER." >&2
    exit 1
  fi
  echo "Stored for this host. Later installs and restarts reuse it."
fi

registry_help() {
  echo "" >&2
  echo "The host could not pull $IMAGE_PREFIX-*:$TAG." >&2
  if [[ -n "$REGISTRY_SERVER" ]] && ! registry_is_authenticated; then
    echo "This host has no $REGISTRY_SERVER credential for the root user, and the" >&2
    echo "installer runs under sudo -- a 'docker login' as your own account is" >&2
    echo "stored somewhere this cannot see." >&2
    echo "" >&2
    echo "Sign in once, as root, and the credential persists for every later run:" >&2
    echo "  sudo docker login $REGISTRY_SERVER -u <github-username>" >&2
    echo "" >&2
    echo "Or let the installer do it in the same step:" >&2
    echo "  sudo PRAXISGRID_REGISTRY_USERNAME=<github-username> \\" >&2
    echo "       PRAXISGRID_REGISTRY_PASSWORD=<token-with-read:packages> \\" >&2
    echo "       ./install.sh linux" >&2
  else
    echo "Confirm the images exist and this host can reach $REGISTRY_SERVER." >&2
  fi
  echo "" >&2
  echo "To build this checkout instead of pulling:" >&2
  echo "  sudo PRAXISGRID_BUILD_LOCAL=1 ./install.sh linux" >&2
}

compose=(docker compose --env-file "$ENV_FILE" -f deploy/ubuntu/compose.yaml)

# The block above writes $ENV_FILE only on a first install, so anything an
# operator can turn on or off later has to be able to rewrite it. GNU sed -i
# renames a temporary over the original and preserves its mode, so this stays
# 0600.
set_env_var() {
  local name="$1" value="$2"
  sed -i "/^${name}=/d" "$ENV_FILE"
  printf '%s=%s\n' "$name" "$value" >> "$ENV_FILE"
}

# --- An Android device for the emulator preview surface --------------------
#
# Off unless asked for, and a separate container for the reason
# k8s/android-emulator.yaml gives: /dev/kvm is a privilege, and the runner is
# the container holding every credential this deployment has.
#
# Compose reads COMPOSE_PROFILES from --env-file, so persisting it there is
# what makes a later bare `docker compose up` keep the device rather than
# leaving it behind.
persisted_profiles="$(sed -n 's/^COMPOSE_PROFILES=//p' "$ENV_FILE" | tail -1)"
want_emulator="${PRAXISGRID_ANDROID_EMULATOR:-}"
if [[ -z "$want_emulator" ]]; then
  # A rerun keeps what this host was installed with, the same way the port,
  # the data root and the registry prefix do.
  if [[ "$persisted_profiles" == *emulator* ]]; then want_emulator=1; else want_emulator=0; fi
fi

if [[ "$want_emulator" == "1" ]]; then
  if [[ ! -f "$REPO_ROOT/Dockerfile.emulator" ]]; then
    echo "--emulator needs the repository, which this installer is not part of." >&2
    echo "" >&2
    echo "The device image is ~4 GB of Android system image. It is optional, and a" >&2
    echo "deployment with no Android work should not fetch it, so it is published" >&2
    echo "with none of the other three and is built from a checkout instead:" >&2
    echo "  git clone https://github.com/flakjackin/PraxisGrid.git" >&2
    echo "  cd PraxisGrid && sudo ./install.sh linux --emulator" >&2
    exit 1
  fi
  if [[ ! -e /dev/kvm ]]; then
    echo "This host has no /dev/kvm, so it cannot run the Android device." >&2
    echo "" >&2
    echo "Without KVM the emulator falls back to software translation: minutes to" >&2
    echo "boot, a frame or two a second. That is not a slow preview, it is one that" >&2
    echo "reads as broken and gets diagnosed as a PraxisGrid bug -- so the device" >&2
    echo "refuses rather than degrading, and so does this." >&2
    echo "" >&2
    if [[ "$IS_WSL" == "1" ]]; then
      echo "WSL2 is itself a virtual machine, so it needs nested virtualization." >&2
      echo "In %USERPROFILE%\\.wslconfig on Windows:" >&2
      echo "  [wsl2]" >&2
      echo "  nestedVirtualization=true" >&2
      echo "then run 'wsl --shutdown' from Windows and install again." >&2
    else
      echo "Check that virtualization is enabled in this machine's firmware, and" >&2
      echo "that the module is loaded:  lsmod | grep kvm" >&2
    fi
    echo "" >&2
    echo "Or install without it and attach a device elsewhere later, with" >&2
    echo "PRAXISGRID_ADB_SERVER_SOCKET or PRAXISGRID_EMULATOR_CONNECT:" >&2
    echo "  sudo ./install.sh linux --no-emulator" >&2
    exit 1
  fi
  set_env_var COMPOSE_PROFILES emulator
  # The service name on the network the runner shares with it. The runner
  # reads this as ADB_SERVER_SOCKET and becomes a client of that container's
  # adb server, so it sees an ordinary `emulator-5554`.
  set_env_var PRAXISGRID_ADB_SERVER_SOCKET tcp:android-emulator:5037
  echo "The Android device is enabled for this host."
else
  if [[ "$persisted_profiles" == *emulator* ]]; then
    # Turning the profile off only stops Compose managing the service; the
    # container it already started would go on running, holding /dev/kvm and
    # advertising an adb server the runner has just been told to ignore.
    echo "Removing the Android device from this host."
    COMPOSE_PROFILES=emulator "${compose[@]}" rm --stop --force android-emulator \
      >/dev/null 2>&1 || true
  fi
  set_env_var COMPOSE_PROFILES ""
  set_env_var PRAXISGRID_ADB_SERVER_SOCKET ""
fi

build_the_device() {
  [[ "$want_emulator" == "1" ]] || return 0
  echo "Building the Android device image. It carries ~4 GB of system image, so"
  echo "the first build takes a while; later runs reuse Docker's cache."
  "${compose[@]}" build android-emulator
}
if [[ "${PRAXISGRID_BUILD_LOCAL:-0}" == "1" ]]; then
  echo "Building PraxisGrid images from this checkout."
  "${compose[@]}" up -d --build
else
  echo "Pulling the released PraxisGrid control-plane and runner images."
  # COMPOSE_PROFILES is overridden for this one call: the device image is built
  # here rather than published, so a pull must not ask the registry for a tag
  # that does not exist there. The shell environment wins over --env-file.
  if ! COMPOSE_PROFILES= "${compose[@]}" pull; then
    # The images are private while the repository is. Rather than ending here
    # and making the operator restart with environment variables, ask for the
    # credential once, in the run that needs it. Docker stores it, so this is
    # asked on the first install of a host and never again.
    # Asked whenever there is a terminal, including under --yes. `--yes`
    # answers prompts that have a default to agree to, and a credential has
    # none -- which is exactly the rule the administrator password already
    # follows a few lines up. Treating --yes as "ask nothing" instead meant
    # the Windows path, which sets it once it has installed Docker itself,
    # reached the pull with no credential and no way to supply one.
    if [[ -n "$REGISTRY_SERVER" ]] && ! registry_is_authenticated && [[ -t 0 ]]; then
      echo ""
      echo "These images are private and this host has no $REGISTRY_SERVER credential."
      echo "Sign in with a GitHub token that has the read:packages scope."
      read -rp "GitHub username (blank to cancel): " registry_user
      if [[ -n "$registry_user" ]]; then
        read -rsp "Token: " registry_token
        echo
        if printf '%s' "$registry_token" \
          | docker login "$REGISTRY_SERVER" --username "$registry_user" --password-stdin; then
          unset registry_token
          echo "Stored for this host. Retrying the pull."
          if ! COMPOSE_PROFILES= "${compose[@]}" pull; then
            registry_help
            exit 1
          fi
          build_the_device
          "${compose[@]}" up -d --no-build
          registry_pull_done=1
        else
          unset registry_token
          registry_help
          exit 1
        fi
      fi
    fi
    if [[ "${registry_pull_done:-0}" != "1" ]]; then
      registry_help
      exit 1
    fi
  else
    build_the_device
    "${compose[@]}" up -d --no-build
  fi
fi

for attempt in $(seq 1 60); do
  if curl --fail --silent "http://127.0.0.1:$PORT/api/health" >/dev/null; then
    if [[ "$IS_WSL" == "1" ]]; then
      # WSL2 forwards localhost from Windows, so this is the address that
      # works in the Windows browser. `hostname -I` is the VM's own address:
      # it is reassigned at every boot and reaches nothing from the LAN.
      echo "PraxisGrid is ready at http://localhost:$PORT (from Windows or from here)"
      echo "To reach it from other machines on the network, forward the port on"
      echo "Windows, in an administrator PowerShell:"
      echo "  netsh interface portproxy add v4tov4 listenport=$PORT \\"
      echo "        listenaddress=0.0.0.0 connectport=$PORT connectaddress=127.0.0.1"
      echo "  New-NetFirewallRule -DisplayName PraxisGrid -Direction Inbound \\"
      echo "        -LocalPort $PORT -Protocol TCP -Action Allow"
    else
      echo "PraxisGrid is ready at http://$(hostname -I | awk '{print $1}'):$PORT"
    fi
    echo "Repositories mounted for agents: $DATA_ROOT/repos"
    echo "Configuration: $ENV_FILE"
    if [[ "$want_emulator" == "1" ]]; then
      echo "Android device: reachable by the runner at tcp:android-emulator:5037"
      echo "  A cold boot is 30-90 s, and the container reports when the device"
      echo "  itself is ready rather than when adb starts listening:"
      echo "    docker compose --env-file $ENV_FILE \\"
      echo "      -f $REPO_ROOT/deploy/ubuntu/compose.yaml ps android-emulator"
    fi
    exit 0
  fi
  sleep 2
done

echo "Containers started, but the health check did not pass. Inspect:" >&2
echo "  docker compose --env-file $ENV_FILE -f $REPO_ROOT/deploy/ubuntu/compose.yaml logs" >&2
exit 1
