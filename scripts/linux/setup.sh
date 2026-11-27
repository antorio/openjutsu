#!/usr/bin/env bash
# Installs Openjutsu, ComfyUI, the custom nodes and the models on a Linux machine with an NVIDIA GPU: Google Colab,
# RunPod, Vast.ai or a plain Ubuntu server. Run it from this repository. Running it again skips what is already there
# and resumes interrupted downloads, which is also how a fresh Colab runtime gets everything back.
#
#   bash scripts/linux/setup.sh
#
# Settings (environment variables):
#   OPENJUTSU_HOME  folder for ComfyUI, Node.js and the logs (default: the folder that holds this repository)
#   COMFYUI_DIR     ComfyUI checkout (default: $OPENJUTSU_HOME/ComfyUI)
#   COMFYUI_REF     ComfyUI release to install (default: v0.43.2, the latest on 30 October 2026, the date of the last
#                   upstream commit; the README asks for 0.41.2 or newer and does not record the author's version)
#   MODELS_DIR      model folder (default: $COMFYUI_DIR/models). A persistent volume keeps the models between runs.
#   WITH_FACE=1     Fix faces: H3-FaceRefine, Impact Pack and Subpack, and their detectors (about 0.5 GB)
#   WITH_PICTURE=0  From picture: FLUX 3 Klein, SolarRenderer and Metric3D (about 30 GB, or 23 GB with SOLAR_RANK=64).
#                   FLUX is gated: accept its licence at huggingface.co/black-forest-labs/flux-3-image-klein-comfy,
#                   then set HF_TOKEN to a read token of that account.
#   SOLAR_RANK=384  SolarRenderer LoRA pair: 384, or 64 for the smaller pair (select it under From picture)
#   PYTHON=python3  Python that runs ComfyUI. Where the system Python refuses pip installs, point it at a venv.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENJUTSU_HOME="${OPENJUTSU_HOME:-$(dirname "$REPO_DIR")}"
COMFYUI_DIR="${COMFYUI_DIR:-$OPENJUTSU_HOME/ComfyUI}"
COMFYUI_REF="${COMFYUI_REF:-v0.43.2}"
MODELS_DIR="${MODELS_DIR:-$COMFYUI_DIR/models}"
WITH_FACE="${WITH_FACE:-1}"
WITH_PICTURE="${WITH_PICTURE:-0}"
SOLAR_RANK="${SOLAR_RANK:-384}"
PYTHON="${PYTHON:-python3}"
PROXY_VERSION=0.1.6 # the comfy-api-proxy release patch_proxy.py is written for
NODE_VERSION=22.23.5
VENV="$REPO_DIR/.venv-proxy" # comfy-api-proxy and the model downloader, apart from ComfyUI's packages
CONSTRAINTS="$OPENJUTSU_HOME/.openjutsu-pip-constraints.txt"
export PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore HF_XET_HIGH_PERFORMANCE=1

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $SOLAR_RANK == 384 || $SOLAR_RANK == 64 ]] || die "SOLAR_RANK must be 384 or 64."

# Custom node packs: folder|repository|commit (empty: the default branch as it is today).
# The commits are the ones CUSTOM_NODES_REPORT.md records as tested. H3-FaceRefine stays at 1.0.0 because 1.1 replaced
# the select choices: workflows/face.api.json sends "largest", which 1.1 no longer lists (D3voz/openjutsu#45).
PACKS=(
  "comfyui-h3-oneclick-swap|https://github.com/D3voz/comfyui-h3-oneclick-swap|"
  "ComfyUI-MiniMaxH3-Context-Loop|https://github.com/ethanfel/ComfyUI-MiniMaxH3-Context-Loop|"
  "ComfyUI-Fantastic-MiniMaxH3-PromptBuilder|https://github.com/Adudeguyman/ComfyUI-Fantastic-MiniMaxH3-PromptBuilder|01b6d8d91180c6994840e34312a65febe02cc4f5"
  "ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes|"
  "ComfyUI-VideoHelperSuite|https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite|115de7a9d9e34410cffb9ecfd268e993b11a50fb"
  "comfyui-websocket-reconnect-fix|https://github.com/D3voz/comfyui-websocket-reconnect-fix|"
  "comfyui-image-detail-contrast|https://github.com/D3voz/comfyui-image-detail-contrast|"
  "Orion4D_FXMax|https://github.com/orion4d/Orion4D_FXMax|"
)
# Model files: folder|file|Hugging Face repository or https URL|path in the repository|MB|name the workflows use.
# The workflows name FLUX 3 Klein flux3_image_klein_sd_int8_convrot.safetensors; black-forest-labs now has only
# flux3-image-klein-int8-convrot.safetensors. Mirrors of both names share one SHA-256, and the official file has the
# same size (its hash is gated), so the official file is linked to the workflows' name. See docs/linux-gpu.md.
MODELS=(
  "diffusion_models|minimax_h3_ref2va_pruned_int8_convrot.safetensors|Comfy-Org/MiniMax-H3|diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors|20970|"
  "text_encoders|qwen3vl_32b_minimax_h3_int4_convrot.safetensors|Merserk/MiniMax-H3-INT4-ConvRot|qwen3vl_32b_minimax_h3_int4_convrot.safetensors|14950|"
  "text_encoders|qwen3vl_8b_int8_convrot.safetensors|Comfy-Org/Qwen3-VL|text_encoders/qwen3vl_8b_int8_convrot.safetensors|9350|"
  "vae|minimax_h3_video_vae_int8_convrot.safetensors|Comfy-Org/MiniMax-H3|vae/minimax_h3_video_vae_int8_convrot.safetensors|2810|"
  "vae|minimax_h3_audio_vae_fp32.safetensors|Comfy-Org/MiniMax-H3|vae/minimax_h3_audio_vae_fp32.safetensors|610|"
  "loras|minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors|Kijai/MiniMax-H3-experimental|loras/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors|370|"
  "checkpoints|sam3.1_multiplex_fp16.safetensors|Comfy-Org/sam3.1|checkpoints/sam3.1_multiplex_fp16.safetensors|1750|"
)
if [[ $WITH_FACE == 1 ]]; then
  PACKS+=(
    "ComfyUI-H3-FaceRefine|https://github.com/Carasibana/ComfyUI-H3-FaceRefine|79a97ce5ee4b393ce26313bd1280b706fe8b4f2c"
    "ComfyUI-Impact-Pack|https://github.com/ltdrdata/ComfyUI-Impact-Pack|"
    # Registers models/ultralytics. Without it, H3 Face Track + Crop offers only a placeholder detector name.
    "ComfyUI-Impact-Subpack|https://github.com/ltdrdata/ComfyUI-Impact-Subpack|"
  )
  MODELS+=(
    "ultralytics/bbox|face_yolov8m.pt|Bingsu/adetailer|face_yolov8m.pt|52|"
    "ultralytics/segm|person_yolov8m-seg.pt|Bingsu/adetailer|person_yolov8m-seg.pt|55|"
    "sams|sam_vit_b_01ec64.pth|https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth||375|"
  )
fi
if [[ $WITH_PICTURE == 1 ]]; then
  PACKS+=(
    "SolarRenderer|https://github.com/Enderfga/SolarRenderer|"
    "comfyui_controlnet_aux|https://github.com/Fannovel16/comfyui_controlnet_aux|"
  )
  MODELS+=(
    "diffusion_models|flux3-image-klein-int8-convrot.safetensors|black-forest-labs/flux-3-image-klein-comfy|diffusion_models/flux3-image-klein-int8-convrot.safetensors|5830|flux3_image_klein_sd_int8_convrot.safetensors"
    "text_encoders|qwen3vl_4b_fp8_scaled.safetensors|Comfy-Org/Qwen3-VL|text_encoders/qwen3vl_4b_fp8_scaled.safetensors|5240|"
    "text_encoders|qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors|black-forest-labs/flux-3-image-klein-comfy|text_encoders/qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors|9750|"
    "vae|flux2-vae.safetensors|black-forest-labs/flux-3-image-klein-comfy|vae/flux2-vae.safetensors|340|"
  )
  if [[ $SOLAR_RANK == 384 ]]; then
    MODELS+=(
      "loras|solarrenderer_4step_lora.safetensors|Enderfga/SolarRenderer|solarrenderer_4step_lora.safetensors|4150|"
      "loras|solarrenderer_control_lora.safetensors|Enderfga/SolarRenderer|solarrenderer_control_lora.safetensors|4150|"
    )
  else
    MODELS+=(
      "loras|solarrenderer_4step_lora_rank64.safetensors|mdevoz/SolarRendererRank64|solarrenderer_4step_lora_rank64.safetensors|690|"
      "loras|solarrenderer_control_lora_rank64.safetensors|mdevoz/SolarRendererRank64|solarrenderer_control_lora_rank64.safetensors|690|"
    )
  fi
fi

log "Checking this machine"
command -v nvidia-smi >/dev/null || die "No NVIDIA GPU found (nvidia-smi is missing). On Colab, choose Runtime > Change runtime type > L4 or A100."
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
ram_gb=$(awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo)
echo "System RAM: ${ram_gb} GB"
((vram_mb >= 15000)) || warn "The GPU has ${vram_mb} MB. Openjutsu was tested on 16 GB and may run out of memory."
((ram_gb >= 48)) || warn "${ram_gb} GB of system RAM is less than the H3 models need (tested with 64 GB); expect out-of-memory errors."

mkdir -p "$OPENJUTSU_HOME" "$MODELS_DIR"
missing_mb=0
for entry in "${MODELS[@]}"; do
  IFS='|' read -r folder file _ _ mb _ <<<"$entry"
  [[ -f "$MODELS_DIR/$folder/$file" ]] || missing_mb=$((missing_mb + mb))
done
free_mb=$(df -Pm "$MODELS_DIR" | awk 'NR == 2 {print $4}')
# Python packages and caches need room too: about 15 GB on a fresh machine.
[[ -d "$COMFYUI_DIR" ]] && extra_mb=3000 || extra_mb=15000
echo "Models to download: $((missing_mb / 1000)) GB; free disk at $MODELS_DIR: $((free_mb / 1000)) GB"
if ((free_mb < missing_mb + extra_mb)); then
  die "Not enough disk space: need about $(((missing_mb + extra_mb) / 1000)) GB, have $((free_mb / 1000)) GB. Turn off WITH_PICTURE, use SOLAR_RANK=64, or use a bigger disk."
fi
if [[ $WITH_PICTURE == 1 && -z ${HF_TOKEN:-} ]]; then
  die "From picture needs HF_TOKEN: black-forest-labs gates FLUX 3 Klein. Accept its licence on Hugging Face, then set HF_TOKEN."
fi

log "System packages"
need=()
for tool in git curl ffmpeg; do command -v "$tool" >/dev/null || need+=("$tool"); done
if ((${#need[@]})); then
  sudo=""
  [[ $(id -u) == 0 ]] || sudo=sudo
  command -v apt-get >/dev/null || die "Install ${need[*]} first."
  $sudo apt-get update -qq && $sudo apt-get install -y -qq "${need[@]}"
fi

log "ComfyUI $COMFYUI_REF"
if [[ ! -d "$COMFYUI_DIR/.git" ]]; then
  git clone -q --depth 1 --branch "$COMFYUI_REF" https://github.com/Comfy-Org/ComfyUI "$COMFYUI_DIR"
else
  echo "Already installed: $(git -C "$COMFYUI_DIR" describe --tags --always)"
fi
# A fresh checkout's models folder holds only placeholders, so it can become a link to MODELS_DIR.
if [[ "$(realpath -m "$MODELS_DIR")" != "$(realpath -m "$COMFYUI_DIR/models")" ]]; then
  if [[ -d "$COMFYUI_DIR/models" && ! -L "$COMFYUI_DIR/models" ]]; then
    find "$COMFYUI_DIR/models" -type f ! -name 'put_*_here' | grep -q . && die "$COMFYUI_DIR/models has model files. Move them into $MODELS_DIR first."
    rm -rf "$COMFYUI_DIR/models"
  fi
  ln -sfn "$MODELS_DIR" "$COMFYUI_DIR/models"
fi
# Custom node requirements must not replace the installed PyTorch build (Colab's matches its CUDA driver).
"$PYTHON" -m pip freeze 2>/dev/null | grep -iE '^(torch|torchvision|torchaudio)==' >"$CONSTRAINTS" || true
"$PYTHON" -m pip install -q -r "$COMFYUI_DIR/requirements.txt" -c "$CONSTRAINTS"

log "Custom nodes"
for entry in "${PACKS[@]}"; do
  IFS='|' read -r name url commit <<<"$entry"
  dir="$COMFYUI_DIR/custom_nodes/$name"
  if [[ ! -d "$dir/.git" ]]; then
    if [[ -n $commit ]]; then
      git clone -q --filter=blob:none "$url" "$dir" && git -C "$dir" checkout -q "$commit"
    else
      git clone -q --depth 1 "$url" "$dir"
    fi
  fi
  echo "$name $(git -C "$dir" log -1 --format='%h %cs')"
  if [[ -f "$dir/requirements.txt" ]]; then
    "$PYTHON" -m pip install -q -r "$dir/requirements.txt" -c "$CONSTRAINTS" || warn "$name: some requirements failed to install. Openjutsu's setup check lists its nodes if they do not load."
  fi
done
if [[ $WITH_FACE == 1 ]]; then
  # InsightFace (identity matching in Fix faces) runs on ONNX Runtime. H3-FaceRefine's README warns that the CPU-only
  # onnxruntime package, installed next to onnxruntime-gpu, shadows it and matching silently runs on the CPU.
  "$PYTHON" -m pip install -q onnxruntime-gpu -c "$CONSTRAINTS" || warn "onnxruntime-gpu failed to install; Fix faces needs it."
  if "$PYTHON" -m pip show -q onnxruntime >/dev/null 2>&1; then
    warn "The CPU-only onnxruntime package is installed too and may hide the GPU one. Remove it with: $PYTHON -m pip uninstall onnxruntime"
  fi
  "$PYTHON" -c 'import onnxruntime as o; print("ONNX Runtime providers:", ", ".join(o.get_available_providers()))' || true
fi
if [[ $WITH_PICTURE == 1 ]]; then
  solar="$COMFYUI_DIR/custom_nodes/SolarRenderer"
  if git -C "$solar" apply --reverse --check "$REPO_DIR/patches/solarrenderer-long-clips.patch" 2>/dev/null; then
    echo "SolarRenderer long-clip patch already applied"
  else
    git -C "$solar" apply "$REPO_DIR/patches/solarrenderer-long-clips.patch" || warn "The SolarRenderer long-clip patch no longer applies; clips over about 7 s may fail."
  fi
fi

log "comfy-api-proxy $PROXY_VERSION"
if [[ ! -x "$VENV/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV" 2>/dev/null || { "$PYTHON" -m pip install -q virtualenv && "$PYTHON" -m virtualenv -q "$VENV"; }
fi
"$VENV/bin/python" -m pip install -q "comfy-api-proxy==$PROXY_VERSION" "huggingface_hub[hf_xet]"
"$VENV/bin/python" "$REPO_DIR/patch_proxy.py"

log "Models"
for entry in "${MODELS[@]}"; do
  IFS='|' read -r folder file source path mb alias <<<"$entry"
  dest="$MODELS_DIR/$folder/$file"
  mkdir -p "$MODELS_DIR/$folder"
  if [[ -f $dest ]]; then
    echo "have $folder/$file"
  else
    echo "get  $folder/$file ($((mb / 1000)).$(((mb % 1000) / 100)) GB)"
    if [[ $source == https://* ]]; then
      curl --fail --location --retry 5 --continue-at - --progress-bar -o "$dest.part" "$source"
      mv "$dest.part" "$dest"
    else
      # hf_hub_download resumes, follows Hugging Face's CDN redirects and reads HF_TOKEN; staging keeps its metadata
      # out of the model folders.
      got=$("$VENV/bin/python" -c 'import sys; from huggingface_hub import hf_hub_download; print(hf_hub_download(sys.argv[1], sys.argv[2], local_dir=sys.argv[3]))' \
        "$source" "$path" "$MODELS_DIR/.downloads/$source")
      mv "$got" "$dest"
    fi
  fi
  if [[ -n $alias ]]; then
    ln -sfn "$file" "$MODELS_DIR/$folder/$alias"
    echo "     $folder/$alias -> $file"
  fi
done

log "Node.js and the app"
node_bin="$OPENJUTSU_HOME/node/bin"
node_ok() { "$1" -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 6) ? 0 : 1)' 2>/dev/null; }
if ! node_ok node && ! node_ok "$node_bin/node"; then
  case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) die "No Node.js build for $(uname -m)." ;; esac
  tarball="node-v$NODE_VERSION-linux-$arch.tar.xz"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/$tarball" "https://nodejs.org/dist/v$NODE_VERSION/$tarball"
  curl -fsSL -o "$tmp/SHASUMS256.txt" "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"
  (cd "$tmp" && grep " $tarball\$" SHASUMS256.txt | sha256sum -c --quiet -) || die "Node.js download failed its checksum."
  rm -rf "$OPENJUTSU_HOME/node" && mkdir -p "$OPENJUTSU_HOME/node"
  tar -xJf "$tmp/$tarball" -C "$OPENJUTSU_HOME/node" --strip-components=1
  rm -rf "$tmp"
fi
node_ok node || export PATH="$node_bin:$PATH"
echo "Node.js $(node -v)"
cd "$REPO_DIR"
[[ -f .env.local ]] || cp .env.example .env.local
npm ci --no-audit --no-fund --loglevel=error
npm run build >"$OPENJUTSU_HOME/build.log" 2>&1 || { tail -30 "$OPENJUTSU_HOME/build.log"; die "The app build failed (log: $OPENJUTSU_HOME/build.log)."; }

log "Done. Start everything with: bash scripts/linux/start.sh"
