#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_ROOT="${PRAXISGRID_CONFIG_ROOT:-$HOME/Library/Application Support/PraxisGrid}"
ENV_FILE="${PRAXISGRID_ENV_FILE:-$CONFIG_ROOT/praxisgrid.env}"
PORT="${PRAXISGRID_PORT:-8080}"
IMAGE_PREFIX="${PRAXISGRID_IMAGE_PREFIX:-ghcr.io/flakjackin/praxisgrid}"
RELEASE_TAG="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
TAG="${PRAXISGRID_TAG:-$RELEASE_TAG}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer supports macOS. Use ./install.sh linux on Ubuntu." >&2
  exit 1
fi

# The published installer is this script, the compose files and VERSION, and
# nothing else -- so it can be fetched without a credential. Building images
# needs the Dockerfiles and the whole build context, which only a checkout
# has. Refused by name rather than inside `docker compose build`.
if [[ "${PRAXISGRID_BUILD_LOCAL:-0}" == "1" && ! -f "$REPO_ROOT/Dockerfile" ]]; then
  echo "This is the published installer, which carries no Dockerfiles." >&2
  echo "" >&2
  echo "Building images needs the repository:" >&2
  echo "  git clone https://github.com/flakjackin/PraxisGrid.git" >&2
  echo "  cd PraxisGrid && PRAXISGRID_BUILD_LOCAL=1 ./install.sh macos" >&2
  exit 1
fi

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

# macOS ships /usr/bin/python3 as a stub that installs the Command Line Tools
# the first time it is *run*. So `command -v python3` succeeds on a machine
# where python3 does not work, and the failure arrives later as a GUI dialog
# in the middle of generating the secrets. Ask the real question.
if ! python3 -c "pass" >/dev/null 2>&1; then
  echo "python3 is not usable on this Mac; it derives this install's secrets."
  confirm "Install the Apple Command Line Tools now?" || exit 1
  xcode-select --install >/dev/null 2>&1 || true
  echo "Accept the installer dialog. Waiting for it to finish."
  for _ in $(seq 1 180); do
    python3 -c "pass" >/dev/null 2>&1 && break
    sleep 10
  done
  if ! python3 -c "pass" >/dev/null 2>&1; then
    echo "The Command Line Tools are still not installed." >&2
    echo "Finish that install and run this again." >&2
    exit 1
  fi
fi

for command in curl; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

# Docker Desktop is obtained rather than demanded, the same way the Ubuntu
# installer obtains Docker Engine. Homebrew first when it is there: its cask
# pins a sha256 for the disk image, so it is the auditable route and the one
# a Mac with Homebrew should take. Without Homebrew the image comes from
# docker.com over HTTPS -- the same file the cask downloads -- rather than
# piping Homebrew's own installer into a shell to get back to the same place.
install_docker_desktop() {
  if [[ -d /Applications/Docker.app ]]; then
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    echo "Installing Docker Desktop with Homebrew."
    brew install --cask docker
    return 0
  fi
  local architecture url image
  architecture="arm64"
  [[ "$(uname -m)" == "x86_64" ]] && architecture="amd64"
  url="https://desktop.docker.com/mac/main/$architecture/Docker.dmg"
  echo "Downloading Docker Desktop from $url"
  image="$(mktemp -d)/Docker.dmg"
  curl -fL --progress-bar "$url" -o "$image"
  echo "Installing it. macOS will ask for your password: Docker Desktop"
  echo "installs a privileged helper, which is its own requirement."
  local mount
  mount="$(mktemp -d)"
  hdiutil attach -nobrowse -quiet -mountpoint "$mount" "$image"
  # Docker ships this installer inside the app precisely so the .dmg does not
  # have to be dragged to /Applications by hand.
  sudo "$mount/Docker.app/Contents/MacOS/install" --accept-license
  hdiutil detach -quiet "$mount" || true
  rm -rf "$(dirname "$image")" "$mount"
}

if ! command -v docker >/dev/null 2>&1 && [[ ! -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
  echo "Docker Desktop is not installed. PraxisGrid runs its control plane and"
  echo "its runner as Linux containers, so it is what actually runs them."
  confirm "Install Docker Desktop now?" || exit 1
  install_docker_desktop
  # The CLI lands in /usr/local/bin only once Docker Desktop has run.
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi

if ! docker info >/dev/null 2>&1; then
  if [[ -d /Applications/Docker.app ]]; then
    echo "Starting Docker Desktop."
    open -a Docker
    echo "Waiting for the Docker daemon."
    for _ in $(seq 1 90); do
      docker info >/dev/null 2>&1 && break
      sleep 2
    done
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker Desktop is installed but its CLI is not on PATH." >&2
  echo "Open Docker Desktop once, then run this again." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "The Docker daemon did not become reachable." >&2
  echo "Open Docker Desktop, finish any first-run dialog it shows, then run this again." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required (the 'docker compose' command)." >&2
  echo "Update Docker Desktop, which ships it." >&2
  exit 1
fi

mkdir -p "$CONFIG_ROOT"
chmod 700 "$CONFIG_ROOT"

# An existing environment file is the installation record. Preserve its port,
# image source and secrets unless the operator explicitly overrides them.
if [[ -s "$ENV_FILE" ]]; then
  if [[ -z "${PRAXISGRID_PORT+x}" ]]; then
    persisted="$(sed -n 's/^PRAXISGRID_PORT=//p' "$ENV_FILE" | tail -1)"
    PORT="${persisted:-$PORT}"
  fi
  if [[ -z "${PRAXISGRID_IMAGE_PREFIX+x}" ]]; then
    persisted="$(sed -n 's/^PRAXISGRID_IMAGE_PREFIX=//p' "$ENV_FILE" | tail -1)"
    IMAGE_PREFIX="${persisted:-$IMAGE_PREFIX}"
  fi
  if [[ -z "${PRAXISGRID_TAG+x}" ]]; then
    persisted="$(sed -n 's/^PRAXISGRID_TAG=//p' "$ENV_FILE" | tail -1)"
    TAG="${persisted:-$TAG}"
  fi
  echo "Reusing existing secrets in $ENV_FILE"
else
  if [[ -n "${PRAXISGRID_ADMIN_PASSWORD:-}" ]]; then
    admin_password="$PRAXISGRID_ADMIN_PASSWORD"
    admin_confirm="$PRAXISGRID_ADMIN_PASSWORD"
  elif [[ ! -t 0 ]]; then
    echo "Set PRAXISGRID_ADMIN_PASSWORD for an unattended install." >&2
    exit 1
  else
    read -rsp "New PraxisGrid administrator password (12+ characters): " admin_password
    echo
    read -rsp "Confirm password: " admin_confirm
    echo
  fi
  if [[ "$admin_password" != "$admin_confirm" || ${#admin_password} -lt 12 ]]; then
    echo "Passwords must match and contain at least 12 characters." >&2
    exit 1
  fi
  temp_env="$(mktemp)"
  temp_script="$(mktemp)"
  trap 'rm -f "$temp_env" "$temp_script"' EXIT
  cat > "$temp_script" <<'PYTHON'
import base64, hashlib, secrets, sys
password = sys.stdin.read()
encode = lambda value: base64.urlsafe_b64encode(value).decode().rstrip("=")
salt = secrets.token_bytes(16)
digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
print("ADMIN_PASSWORD_HASH='scrypt$16384$8$1$" + encode(salt) + "$" + encode(digest) + "'")
print("SESSION_SECRET=" + secrets.token_urlsafe(48))
print("PROVIDER_ENCRYPTION_KEY=" + base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())
PYTHON
  printf '%s' "$admin_password" | python3 "$temp_script" > "$temp_env"
  {
    echo "PRAXISGRID_PORT=$PORT"
    echo "PRAXISGRID_IMAGE_PREFIX=$IMAGE_PREFIX"
    echo "PRAXISGRID_TAG=$TAG"
    echo "PRAXISGRID_ORGANIZATION_SLUG=praxisgrid"
    # Docker Desktop can prevent Codex from creating its own bubblewrap
    # sandbox. Preserve the secure default unless the operator explicitly
    # accepts the runner container as the execution boundary.
    echo "PRAXISGRID_CODEX_SANDBOX_MODE=${PRAXISGRID_CODEX_SANDBOX_MODE:-}"
    echo "SECURE_COOKIE=false"
    echo "PRAXISGRID_ALLOW_SELF_SIGNUP=false"
  } >> "$temp_env"
  install -m 600 "$temp_env" "$ENV_FILE"
  rm -f "$temp_env" "$temp_script"
  trap - EXIT
  unset admin_password admin_confirm PRAXISGRID_ADMIN_PASSWORD
fi

REGISTRY_SERVER="${PRAXISGRID_REGISTRY_SERVER:-}"
if [[ -z "$REGISTRY_SERVER" && "$IMAGE_PREFIX" == ghcr.io/* ]]; then
  REGISTRY_SERVER="ghcr.io"
fi
if [[ -n "${PRAXISGRID_REGISTRY_USERNAME:-}" || -n "${PRAXISGRID_REGISTRY_PASSWORD:-}" ]]; then
  : "${PRAXISGRID_REGISTRY_USERNAME:?set registry username with registry password}"
  : "${PRAXISGRID_REGISTRY_PASSWORD:?set registry password with registry username}"
  printf '%s' "$PRAXISGRID_REGISTRY_PASSWORD" \
    | docker login "$REGISTRY_SERVER" --username "$PRAXISGRID_REGISTRY_USERNAME" --password-stdin
fi

cd "$REPO_ROOT"
compose=(docker compose --env-file "$ENV_FILE" \
  -f deploy/ubuntu/compose.yaml -f deploy/macos/compose.yaml)
if [[ "${PRAXISGRID_BUILD_LOCAL:-0}" == "1" ]]; then
  echo "Building native PraxisGrid images from this checkout."
  "${compose[@]}" up -d --build
else
  echo "Pulling PraxisGrid images."
  if ! "${compose[@]}" pull; then
    echo "Unable to pull $IMAGE_PREFIX-*:$TAG." >&2
    echo "Supply GHCR credentials or test this checkout with: ./install.sh macos --build-local" >&2
    exit 1
  fi
  "${compose[@]}" up -d --no-build
fi

attempt=1
while [[ $attempt -le 60 ]]; do
  if curl --fail --silent "http://127.0.0.1:$PORT/api/health" >/dev/null; then
    echo "PraxisGrid is ready at http://localhost:$PORT/"
    echo "Configuration: $ENV_FILE"
    echo "State: Docker Desktop named volumes (docker volume ls --filter label=com.docker.compose.project=praxisgrid)"
    exit 0
  fi
  sleep 2
  attempt=$((attempt + 1))
done

echo "Containers started, but the health check did not pass. Inspect:" >&2
echo "  docker compose --env-file '$ENV_FILE' -f deploy/ubuntu/compose.yaml -f deploy/macos/compose.yaml logs" >&2
exit 1
