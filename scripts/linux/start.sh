#!/usr/bin/env bash
# Starts ComfyUI (127.0.0.1:8188), comfy-api-proxy (127.0.0.1:8189) and the app (127.0.0.1:3000) in the background
# after scripts/linux/setup.sh, and waits until each one answers. Logs and process ids go to $OPENJUTSU_HOME/logs.
#
#   bash scripts/linux/start.sh          start whatever is not running yet
#   bash scripts/linux/start.sh stop     stop everything this script started
#
# Everything listens on loopback only. To reach the app:
#   - over SSH (RunPod, Vast.ai, a server): ssh -N -L 3000:127.0.0.1:3000 <host>, then open http://127.0.0.1:3000
#   - with TUNNEL=cloudflared (Colab): a Cloudflare quick tunnel gives the app a public https://….trycloudflare.com
#     address. Anyone with the address reaches the sign-in page, so OPENJUTSU_PASSWORD (12+ characters) is required.
#     Cloudflare documents that quick tunnels do not carry Server-Sent Events, so the progress view falls back to
#     polling: the status and the result show, but not the steps, clip numbers or mask previews.
#
# Settings (environment variables): OPENJUTSU_HOME, COMFYUI_DIR and PYTHON as for setup.sh; OPENJUTSU_PASSWORD;
# TUNNEL=cloudflared; COMFYUI_ARGS for extra ComfyUI flags (for example --lowvram).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENJUTSU_HOME="${OPENJUTSU_HOME:-$(dirname "$REPO_DIR")}"
COMFYUI_DIR="${COMFYUI_DIR:-$OPENJUTSU_HOME/ComfyUI}"
PYTHON="${PYTHON:-python3}"
TUNNEL="${TUNNEL:-}"
CLOUDFLARED_VERSION=2026.11.2
LOGS="$OPENJUTSU_HOME/logs"
mkdir -p "$LOGS"
# The Node.js setup.sh installed, when the machine had none recent enough.
[[ -x "$OPENJUTSU_HOME/node/bin/node" ]] && export PATH="$OPENJUTSU_HOME/node/bin:$PATH"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
running() { [[ -f "$LOGS/$1.pid" ]] && kill -0 "$(cat "$LOGS/$1.pid")" 2>/dev/null; }

# Each service gets its own process group, so stopping it also stops what it spawned (npm starts Next).
launch() {
  local name=$1
  shift
  if running "$name"; then
    echo "$name is already running"
    return
  fi
  setsid nohup "$@" >"$LOGS/$name.log" 2>&1 </dev/null &
  echo $! >"$LOGS/$name.pid"
}

# Any HTTP answer counts, including the app's 401 sign-in prompt.
wait_http() {
  local name=$1 url=$2 limit=$3 i
  for ((i = 0; i < limit; i += 2)); do
    curl -s -o /dev/null -m 5 "$url" && { echo "$name is up"; return; }
    running "$name" || { tail -40 "$LOGS/$name.log"; die "$name stopped (log: $LOGS/$name.log)."; }
    sleep 2
  done
  tail -40 "$LOGS/$name.log"
  die "$name did not answer at $url within $limit s (log: $LOGS/$name.log)."
}

if [[ ${1:-} == stop ]]; then
  for name in tunnel app proxy comfyui; do
    if running "$name"; then
      pid=$(cat "$LOGS/$name.pid")
      kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      echo "stopped $name"
    fi
    rm -f "$LOGS/$name.pid"
  done
  exit 0
fi

if [[ -n $TUNNEL ]]; then
  [[ $TUNNEL == cloudflared ]] || die "TUNNEL can only be cloudflared."
  password=${OPENJUTSU_PASSWORD:-}
  ((${#password} >= 12)) || die "A tunnel makes the app public: set OPENJUTSU_PASSWORD to 12 or more characters."
fi
[[ -d "$COMFYUI_DIR" && -d "$REPO_DIR/.next" ]] || die "Run scripts/linux/setup.sh first."

read -ra comfyui_args <<<"${COMFYUI_ARGS:-}"
launch comfyui "$PYTHON" "$COMFYUI_DIR/main.py" --listen 127.0.0.1 --port 8188 --disable-auto-launch ${comfyui_args[@]+"${comfyui_args[@]}"}
# Loading the custom nodes takes a while on the first start.
wait_http comfyui http://127.0.0.1:8188/queue 600

launch proxy "$REPO_DIR/.venv-proxy/bin/comfy-api-proxy" run --max-upload-mb 500
wait_http proxy http://127.0.0.1:8189/ 60

[[ -n ${OPENJUTSU_PASSWORD:-} ]] && export OPENJUTSU_PASSWORD
(cd "$REPO_DIR" && launch app npm start)
wait_http app http://127.0.0.1:3000/ 120

address=http://127.0.0.1:3000
if [[ $TUNNEL == cloudflared ]]; then
  cloudflared="$OPENJUTSU_HOME/bin/cloudflared"
  if [[ ! -x $cloudflared ]]; then
    case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "No cloudflared build for $(uname -m)." ;; esac
    mkdir -p "$OPENJUTSU_HOME/bin"
    curl -fsSL -o "$cloudflared.part" "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$arch"
    chmod +x "$cloudflared.part" && mv "$cloudflared.part" "$cloudflared"
  fi
  launch tunnel "$cloudflared" tunnel --no-autoupdate --url http://127.0.0.1:3000
  address=""
  for ((i = 0; i < 60; i++)); do
    address=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOGS/tunnel.log" | head -1 || true)
    [[ -n $address ]] && break
    sleep 1
  done
  [[ -n $address ]] || { tail -20 "$LOGS/tunnel.log"; die "cloudflared gave no address (log: $LOGS/tunnel.log)."; }
  echo "$address" >"$LOGS/tunnel.url"
fi

echo
echo "Openjutsu is running at $address"
[[ -n ${OPENJUTSU_PASSWORD:-} ]] && echo "Sign in as openjutsu with OPENJUTSU_PASSWORD."
echo "Logs: $LOGS   Stop: bash scripts/linux/start.sh stop"
