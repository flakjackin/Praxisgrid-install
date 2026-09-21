#!/usr/bin/env bash
#
# One command, on Ubuntu and macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/flakjackin/praxisgrid-install/main/install.sh | bash
#
# A bootstrap fetches and dispatches. It never provisions: Docker, the
# secrets, the volumes and the containers are all obtained by the platform
# installer in the payload, because that is where the reasoning about each
# platform lives and where the tests point. A bootstrap that installed Docker
# would be a second description of an install, and the second description is
# the one that goes stale.
#
# The payload is public and carries no secret -- it is `VERSION`, the two
# compose files, and the installers that read them. The only credential this
# path ever asks for is a GitHub token with `read:packages`, for the private
# images, and the installer asks for that itself at the moment it pulls.
set -euo pipefail

INSTALLER_REPO="${PRAXISGRID_INSTALLER_REPO:-flakjackin/praxisgrid-install}"
INSTALLER_REF="${PRAXISGRID_INSTALLER_REF:-main}"
# Overridable as a whole, not only by repository and ref: a deployment that
# mirrors the installer internally, or installs from a copy on a machine with
# no route to github.com, is naming an archive rather than a GitHub project.
# It is also the only way to exercise this download path without publishing
# something, and `curl` accepts a file:// URL, so the test is a real fetch.
TARBALL="${PRAXISGRID_INSTALLER_TARBALL:-https://codeload.github.com/$INSTALLER_REPO/tar.gz/refs/heads/$INSTALLER_REF}"

say()  { printf '==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
fail() { printf '\n%s\n' "$1" >&2; exit 1; }

# --- Which installer ---------------------------------------------------------
#
# Named explicitly wherever the caller knows, because the Windows path calls
# this from inside a distribution it has just provisioned and has no reason to
# let it guess. Everything else is passed through to the payload's own
# dispatcher untouched.

TARGET=""
WANTS_HELP=0
PASSTHROUGH=()
for argument in "$@"; do
  case "$argument" in
    linux|ubuntu) TARGET="linux" ;;
    macos|mac)    TARGET="macos" ;;
    kubernetes|k8s)
      fail "A Kubernetes install reads the manifests in k8s/, which are not in the
payload. Clone the repository and run ./install.sh kubernetes."
      ;;
    --help|-h) WANTS_HELP=1; PASSTHROUGH+=("$argument") ;;
    *) PASSTHROUGH+=("$argument") ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    TARGET="macos"
  elif [[ -r /etc/os-release ]] && grep -qi '^ID=ubuntu' /etc/os-release; then
    TARGET="linux"
  else
    fail "This bootstrap installs PraxisGrid on Ubuntu or macOS.

On Windows, run this in PowerShell instead -- it provisions WSL2 and Ubuntu
for you and then runs this same Linux installer inside it:
  irm https://raw.githubusercontent.com/$INSTALLER_REPO/$INSTALLER_REF/install.ps1 | iex

For a Kubernetes cluster, clone the repository and run ./install.sh kubernetes."
  fi
fi

# --- The payload -------------------------------------------------------------
#
# Kept rather than discarded. The installer prints `docker compose -f
# <root>/deploy/.../compose.yaml` commands for restarting and reading logs, and
# a root under /tmp makes every one of those a command that stops working.

case "$TARGET" in
  linux) PAYLOAD_ROOT="${PRAXISGRID_PAYLOAD_ROOT:-/opt/praxisgrid/install}" ;;
  macos) PAYLOAD_ROOT="${PRAXISGRID_PAYLOAD_ROOT:-$HOME/Library/Application Support/PraxisGrid/install}" ;;
esac

# A checkout is a payload. This is how the whole path is tested without
# publishing anything, and how an operator installs an unreleased build.
if [[ -n "${PRAXISGRID_PAYLOAD_DIR:-}" ]]; then
  [[ -x "$PRAXISGRID_PAYLOAD_DIR/install.sh" ]] \
    || fail "PRAXISGRID_PAYLOAD_DIR has no install.sh: $PRAXISGRID_PAYLOAD_DIR"
  PAYLOAD_ROOT="$PRAXISGRID_PAYLOAD_DIR"
  say "Using the payload at $PAYLOAD_ROOT"
else
  command -v curl >/dev/null 2>&1 || fail "curl is required. Install it and run this again."
  command -v tar  >/dev/null 2>&1 || fail "tar is required. Install it and run this again."

  say "Downloading the PraxisGrid installer"
  note "$INSTALLER_REPO ($INSTALLER_REF)"
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT
  if ! curl -fsSL "$TARBALL" | tar -xz -C "$staging"; then
    fail "Could not download the installer from:
  $TARBALL

Check this machine's network access to github.com."
  fi
  # One directory, named for the repository and ref, and its `payload/`
  # subtree is what an install is. The bootstrap scripts beside it are what
  # is already running.
  extracted="$(find "$staging" -maxdepth 2 -type d -name payload | head -1)"
  [[ -n "$extracted" ]] || fail "The downloaded installer has no payload/ directory."

  say "Installing it to $PAYLOAD_ROOT"
  # Whether this needs sudo is a question about the destination, not about the
  # platform: /opt needs it, and a directory the operator named through
  # PRAXISGRID_PAYLOAD_ROOT may not. Asking for a password that is not
  # required is the kind of prompt that makes a one-command install feel like
  # a procedure, and on a machine with no sudo at all it is a refusal.
  if mkdir -p "$PAYLOAD_ROOT" 2>/dev/null && [[ -w "$PAYLOAD_ROOT" ]]; then
    cp -R "$extracted/." "$PAYLOAD_ROOT/"
    chmod +x "$PAYLOAD_ROOT/install.sh" "$PAYLOAD_ROOT"/deploy/*/install.sh
  else
    sudo install -d -m 0755 "$PAYLOAD_ROOT"
    sudo cp -R "$extracted/." "$PAYLOAD_ROOT/"
    sudo chmod +x "$PAYLOAD_ROOT/install.sh" "$PAYLOAD_ROOT"/deploy/*/install.sh
  fi
  # Removed here rather than left to the trap: this script ends in `exec`,
  # which replaces the process, so an EXIT trap never runs.
  rm -rf "$staging"
  trap - EXIT
fi

# --- Hand off ----------------------------------------------------------------
#
# stdin is the tarball's pipe when this script was itself piped from curl, so
# the installer's password prompt would read the end of a shell script rather
# than a password. Reconnect it to the terminal, and say so plainly when there
# is not one rather than letting the prompt read EOF as an empty password.

if [[ ! -t 0 ]]; then
  # `exec` failing takes the shell down with it, so whether /dev/tty can be
  # opened is asked in a subshell that can afford to die. A test for the file
  # is not that question: /dev/tty exists in a session with no controlling
  # terminal and opening it fails there.
  if ( exec < /dev/tty ) 2>/dev/null; then
    exec < /dev/tty
  elif [[ "$WANTS_HELP" != "1" && -z "${PRAXISGRID_ADMIN_PASSWORD:-}" \
          && ! -s "${PRAXISGRID_ENV_FILE:-/etc/praxisgrid/praxisgrid.env}" ]]; then
    fail "This install needs to ask for an administrator password and has no terminal.

Set PRAXISGRID_ADMIN_PASSWORD for an unattended install, or run the installer
directly:
  sudo $PAYLOAD_ROOT/install.sh $TARGET"
  fi
fi

say "Starting the $TARGET installer"
exec "$PAYLOAD_ROOT/install.sh" "$TARGET" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
