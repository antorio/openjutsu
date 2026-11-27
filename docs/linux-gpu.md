# Running Openjutsu on a Linux GPU

Two scripts install and start the whole stack on one Linux machine with an NVIDIA GPU: ComfyUI with the custom nodes and models, comfy-api-proxy, and the app. They are written for Google Colab, RunPod and Vast.ai, and should also work on a plain Ubuntu server with a recent NVIDIA driver. They have not been run end to end on every one of these yet.

- `scripts/linux/setup.sh` installs everything. Running it again skips what is there and resumes interrupted downloads.
- `scripts/linux/start.sh` starts ComfyUI (`127.0.0.1:8188`), the proxy (`127.0.0.1:8189`) and the app (`127.0.0.1:3000`) in the background and waits until each answers. `start.sh stop` stops them. Logs and process ids are in `$OPENJUTSU_HOME/logs`.

Everything listens on loopback only. You reach the app through an SSH tunnel, or on Colab through a Cloudflare quick tunnel (`TUNNEL=cloudflared`), which requires `OPENJUTSU_PASSWORD`.

## What the machine needs

- An NVIDIA GPU with 16 GB or more (24 GB gives headroom), and 48–64 GB of system RAM. H3 was tested on 16 GB with 64 GB of RAM.
- Disk: about 70 GB for the swaps and Fix faces, about 100 GB with From picture. Python packages need some of that too.
- Python 3.10+ with pip, git and curl. A preinstalled CUDA build of PyTorch, as on Colab and RunPod's PyTorch images, is kept: custom-node requirements are installed with it pinned.

## Settings

| Variable | Default | |
| --- | --- | --- |
| `OPENJUTSU_HOME` | the folder that holds this repository | ComfyUI, Node.js, `logs/` |
| `COMFYUI_DIR` | `$OPENJUTSU_HOME/ComfyUI` | |
| `COMFYUI_REF` | `v0.43.2` | ComfyUI release, the latest on 30 October 2026 (the last upstream commit). The README asks for 0.41.2 or newer and does not record the version the author used. Every node type the app sends exists in it; outside partner nodes it differs from 0.43.0 only by a Linux `memfd_create` fix for some Python builds |
| `MODELS_DIR` | `$COMFYUI_DIR/models` | put it on a persistent volume to download the models once |
| `WITH_FACE` | `1` | Fix faces packs and detectors (about 0.5 GB) |
| `WITH_PICTURE` | `0` | From picture: FLUX 3 Klein, SolarRenderer, Metric3D (about 30 GB). Needs `HF_TOKEN` |
| `SOLAR_RANK` | `384` | `64` downloads the smaller SolarRenderer pair; select it under From picture |
| `HF_TOKEN` | | a Hugging Face read token. black-forest-labs gates FLUX 3 Klein: accept its licence first |
| `PYTHON` | `python3` | the Python that runs ComfyUI. Where the system Python refuses pip, use a venv's |
| `OPENJUTSU_PASSWORD` | | `start.sh`: required with a tunnel, 12+ characters, user `openjutsu` |
| `TUNNEL` | | `start.sh`: `cloudflared` for a public quick-tunnel address |
| `COMFYUI_ARGS` | | `start.sh`: extra ComfyUI flags, such as `--lowvram` |

## What setup.sh installs

The custom nodes are the README's packs plus ComfyUI-Impact-Subpack, which registers `models/ultralytics`. Without it, H3 Face Track + Crop offers only a placeholder `face_yolov8m.pt`, not the workflow's `bbox/face_yolov8m.pt`, so the setup check reports the detectors missing. Packs with a commit in `CUSTOM_NODES_REPORT.md` are installed at that commit: Fantastic PromptBuilder `01b6d8d`, VideoHelperSuite `115de7a` and H3-FaceRefine 1.0.0 (`79a97ce`), since FaceRefine 1.1 replaced the `select` choices: `workflows/face.api.json` sends `largest`, which 1.1 no longer lists, so ComfyUI rejects the job (D3voz/openjutsu#45). The others are installed from their default branch; the script prints each pack's commit. SolarRenderer gets `patches/solarrenderer-long-clips.patch`. [ComfyUI-Spectrum-MiniMax-H3](https://github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3), needed only for Acceleration → Spectrum, is not installed.

The models come from these Hugging Face repositories:

| File | Source |
| --- | --- |
| `minimax_h3_ref2va_pruned_int8_convrot`, video and audio VAEs | `Comfy-Org/MiniMax-H3` |
| `qwen3vl_32b_minimax_h3_int4_convrot` | `Merserk/MiniMax-H3-INT4-ConvRot`, a community upload. `Comfy-Org/MiniMax-H3` has this encoder only as bf16, int8_convrot (27 GB) and nvfp4_awq |
| `qwen3vl_8b_int8_convrot`, `qwen3vl_4b_fp8_scaled` | `Comfy-Org/Qwen3-VL` |
| `sam3.1_multiplex_fp16` | `Comfy-Org/sam3.1` |
| `minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16` | `Kijai/MiniMax-H3-experimental` (`loras/`), a community upload with the exact name; the author never linked a source |
| FLUX 3 Klein, its prompt upsampler and VAE | `black-forest-labs/flux-3-image-klein-comfy` (see below) |
| SolarRenderer LoRAs | `Enderfga/SolarRenderer` or `mdevoz/SolarRendererRank64` |
| `face_yolov8m.pt`, `person_yolov8m-seg.pt` | `Bingsu/adetailer` |
| `sam_vit_b_01ec64.pth` | Meta's `dl.fbaipublicfiles.com` |

The workflows name FLUX 3 Klein `flux3_image_klein_sd_int8_convrot.safetensors`, but black-forest-labs' repository now has `flux3-image-klein-int8-convrot.safetensors` and no file of the old name. The evidence that they are one file:

- `KoalaNation/FLUX-3-KLEIN-MODELS` (uploaded 16 October 2026) has the old name; `ml-resources/flux-3-image-klein-comfy` has the new name after a 17 October commit titled "Rename diffusion models to match upstream (base / distilled)". Both copies have SHA-256 `847d8933…` and 5,827,874,779 bytes.
- black-forest-labs' file has the same size. Its hash and commit history are hidden behind the licence gate, so the rename date and byte identity with the official file are inferred, not seen.

`setup.sh` downloads the official file and links the old name to it.

## Google Colab

Open `notebooks/openjutsu_colab.ipynb` in Colab: upload the file (*File → Upload notebook*), or open it from GitHub, `https://colab.research.google.com/github/antorio/openjutsu/blob/<branch>/notebooks/openjutsu_colab.ipynb`. Then *Runtime → Run all*. The Settings cell's `BRANCH` (default `linux-gpu`) picks the branch the runtime installs; the install cell switches an existing checkout to it. The notebook runs `setup.sh` with `OPENJUTSU_HOME=/content`, then `start.sh` with `TUNNEL=cloudflared`, and prints the `https://….trycloudflare.com` address, the user `openjutsu` and the password: the `OPENJUTSU_PASSWORD` secret, or one it makes and keeps for the runtime. A failing step stops the run with one red line, below the output that explains it. Edit the cells in `notebooks/build_openjutsu_colab.py` and run it to rewrite the notebook.

- Not yet run end to end on Colab.
- **No live progress through the tunnel.** Cloudflare's [quick-tunnel limitations](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/) say quick tunnels do not support Server-Sent Events, which the progress view (`/api/jobs/[id]/events`) uses. The page also polls the job every 5 s, so the status (queued, running, done) and the result still appear; steps, clip numbers and mask previews do not. From picture only polls, so it is not affected.
- Choose an L4 or A100 runtime on a paid plan. Google publishes no RAM figures for Colab runtimes, only "standard" (free) and "high memory" (paid) profiles; H3 was tested with 64 GB, and the notebook's first cell shows what the runtime has.
- Colab's [FAQ](https://research.google.com/colaboratory/faq.html) lists *creating deepfakes* and "web service offerings not related to interactive compute" among the activities disallowed on all managed Colab runtimes, paid ones included. Swapping a person in a video can count as the first. The FAQ does not say what happens on a paid runtime; on free ones, disallowed use "may be terminated at any time without warning".
- The disk is wiped when the runtime ends, so every new runtime downloads the models again.
- Cloudflare's quick-tunnel page states no upload size limit. The app takes up to 512 MB per job; whether a quick tunnel carries that much is untested.
- The FAQ says free notebooks run for at most 12 hours and Pro+ supports up to 24 hours of continuous execution; it gives no figure for Pro or Pay As You Go. Idle runtimes time out, with no definition of idle; the notebook's last cell keeps a cell running, which is meant to count as busy.

## RunPod and Vast.ai

1. Rent a machine with an NVIDIA GPU and a PyTorch/CUDA image, and attach a volume of about 150 GB (RunPod mounts it at `/workspace`).
2. In its terminal:

   ```sh
   cd /workspace
   git clone https://github.com/antorio/openjutsu
   cd openjutsu
   OPENJUTSU_HOME=/workspace bash scripts/linux/setup.sh
   OPENJUTSU_HOME=/workspace bash scripts/linux/start.sh
   ```

   On a pod that restarts with a fresh container but the same volume, run `setup.sh` again: it reinstalls the Python packages and skips the models.
3. On your own computer, tunnel the app over SSH (use the host, port and key the provider shows) and open <http://127.0.0.1:3000>. Through SSH the app sees a loopback address, so no password is needed:

   ```sh
   ssh -N -L 3000:127.0.0.1:3000 -p <port> root@<host>
   ```

To run the app on your own computer instead, while changing its code, tunnel ComfyUI and the proxy, then use `npm run dev` with the default `.env.local`. Both are needed: every job reads the model lists from ComfyUI directly, and From picture talks only to ComfyUI. From picture gives each ComfyUI request 30 seconds, including uploading the video, so a slow connection can fail with a large video.

```sh
ssh -N -L 8188:127.0.0.1:8188 -L 8189:127.0.0.1:8189 -p <port> root@<host>
```

Stop the machine when you finish, to end the GPU charges. Resuming a swap relies on the clip checkpoints in ComfyUI's `output/` folder, which survive only on the volume.
