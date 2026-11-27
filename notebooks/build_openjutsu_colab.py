"""Writes notebooks/openjutsu_colab.ipynb. Edit the cells here, then run: python3 notebooks/build_openjutsu_colab.py"""
import json
from pathlib import Path


def md(text):
    return {"cell_type": "markdown", "metadata": {}, "source": text.strip("\n").splitlines(keepends=True)}


def code(text):
    return {"cell_type": "code", "execution_count": None, "metadata": {"cellView": "form"}, "outputs": [],
            "source": text.strip("\n").splitlines(keepends=True)}


INTRO = """
# Openjutsu on Google Colab

Installs ComfyUI, the custom nodes, the models, comfy-api-proxy and the Openjutsu app on this runtime, starts them, and gives the app a public `https://….trycloudflare.com` address. **Runtime → Run all** does everything; the last cell then keeps the runtime busy.

**Before you start**

- **Runtime:** an **L4** or **A100** GPU on a paid plan (*Runtime → Change runtime type*). H3 was tested with 64 GB of system RAM; cell 1 shows what this runtime has.
- **Secrets** (key icon on the left), both optional:
  - `OPENJUTSU_PASSWORD`, 12 or more characters, for signing in to the app as `openjutsu`. Without it, cell 3 makes a password for this runtime and shows it.
  - `HF_TOKEN`, a Hugging Face read token. From picture needs it, after you accept the licence at [black-forest-labs/flux-3-image-klein-comfy](https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy). When it is set, the other model downloads use it too.
- **Every new runtime starts empty**, so cell 2 downloads the models again: about 51 GB, plus about 30 GB with From picture.

**Good to know**

- Through the tunnel the app shows a job's status and result, but not its steps, clip numbers or mask previews: Cloudflare's quick tunnels do not carry server-sent events. Finished videos are also saved in `/content/ComfyUI/output`.
- If a cell stops, its red line and the output above it say why.
- Colab's [FAQ](https://research.google.com/colaboratory/faq.html) lists *creating deepfakes* among the activities disallowed on all managed runtimes, paid ones included. Only use videos and photos of people who agreed.
"""

SETTINGS = r'''
#@title Settings
REPO = "https://github.com/antorio/openjutsu"  #@param {type:"string"}
BRANCH = "linux-gpu"  #@param {type:"string"}
#@markdown Fix faces adds about 0.5 GB of downloads. From picture adds about 30 GB (23 GB with rank 64) and needs the `HF_TOKEN` secret.
WITH_FACE = True  #@param {type:"boolean"}
WITH_PICTURE = False  #@param {type:"boolean"}
SOLAR_RANK = "384"  #@param ["384", "64"]

# Shared by the cells below.
import codecs, os, subprocess, sys

HOME = "/content"
REPO_DIR = f"{HOME}/openjutsu"
LOGS = f"{HOME}/logs"
PASSWORD_FILE = f"{HOME}/.openjutsu_password"


class Stop(Exception):
    """Ends the cell, and the rest of a Run all, with just this message in red."""

    def _render_traceback_(self):
        return [f"\x1b[1;31m{self}\x1b[0m"]


class Done(Stop):
    """Ends the cell, and the rest of a Run all, with a plain message."""

    def _render_traceback_(self):
        return [str(self)]


def sh(*command):
    """Runs a command, shows its output as it arrives, and stops if it fails."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = codecs.getincrementaldecoder("utf-8")(errors="replace")
    while chunk := process.stdout.read1(65536):
        sys.stdout.write(text.decode(chunk))
        sys.stdout.flush()
    if process.wait():
        raise Stop(f"Stopped: {' '.join(command)} failed with exit code {process.returncode}. The output above says why.")


def alive(name):
    """Whether the service start.sh started under this name is running."""
    try:
        os.kill(int(open(f"{LOGS}/{name}.pid").read()), 0)
        return True
    except (OSError, ValueError):
        return False


def secret(name):
    """A Colab secret, or None when it is not set or this notebook may not read it."""
    try:
        from google.colab import userdata
        return userdata.get(name) or None
    except Exception:
        return None


print(f"Settings saved: {REPO} @ {BRANCH}")
'''

CHECK = r'''
#@title 1. Check the runtime
import shutil

gpu = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"], capture_output=True, text=True)
if gpu.returncode:
    raise Stop("No GPU on this runtime. Choose Runtime > Change runtime type > L4 or A100, then run all again.")
ram = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30
disk = shutil.disk_usage(HOME).free / 2**30
need = 51 + (0.5 if WITH_FACE else 0) + ((23 if SOLAR_RANK == "64" else 30) if WITH_PICTURE else 0) + 15
print(f"GPU:       {gpu.stdout.strip()}")
print(f"RAM:       {ram:.0f} GB")
print(f"Free disk: {disk:.0f} GB (these settings need about {need:.0f} GB)")
if ram < 48:
    print("Warning: less than 48 GB of RAM. H3 was tested with 64 GB, so long or high-resolution jobs may run out of memory.")
if disk < need:
    raise Stop("Not enough disk for these settings. Turn off From picture, or choose rank 64.")
'''

INSTALL = r'''
#@title 2. Install
#@markdown Takes a while on a new runtime: everything is installed and the models are downloaded. Running it again updates to the branch's latest commit and skips what is already there.
if os.path.isdir(f"{REPO_DIR}/.git"):
    # An earlier run may have used another branch or repository; the build also edits a tracked file.
    sh("git", "-C", REPO_DIR, "remote", "set-url", "origin", REPO)
    sh("git", "-C", REPO_DIR, "fetch", "-q", "origin", BRANCH)
    sh("git", "-C", REPO_DIR, "checkout", "-q", "-f", "-B", BRANCH, "FETCH_HEAD")
else:
    sh("git", "clone", "-q", "--branch", BRANCH, REPO, REPO_DIR)
sh("git", "-C", REPO_DIR, "log", "-1", "--format=Openjutsu %h (%cs) %s")
if not os.path.isfile(f"{REPO_DIR}/scripts/linux/setup.sh"):
    raise Stop(f"The {BRANCH} branch has no scripts/linux/setup.sh. Set BRANCH in Settings to a branch that has it, such as linux-gpu.")

os.environ.update(OPENJUTSU_HOME=HOME, WITH_FACE=str(int(WITH_FACE)), WITH_PICTURE=str(int(WITH_PICTURE)), SOLAR_RANK=SOLAR_RANK)
token = secret("HF_TOKEN")
if token:
    os.environ["HF_TOKEN"] = token
elif WITH_PICTURE:
    raise Stop("From picture needs the HF_TOKEN secret (key icon on the left), with this notebook allowed to read it.")
sh("bash", f"{REPO_DIR}/scripts/linux/setup.sh")
'''

START = r'''
#@title 3. Start Openjutsu
import json, secrets

if not os.path.isfile(f"{REPO_DIR}/scripts/linux/start.sh"):
    raise Stop("Run 2. Install first.")
if alive("app") and os.path.isfile(PASSWORD_FILE):
    # The app keeps the password it started with; a new secret takes effect after 5. Stop and this cell.
    sign_in = json.load(open(PASSWORD_FILE))
elif alive("app"):
    raise Stop("Openjutsu is already running with a password this notebook did not save. Run 5. Stop Openjutsu, then this cell.")
else:
    password = secret("OPENJUTSU_PASSWORD")
    if password and len(password) < 12:
        raise Stop("The OPENJUTSU_PASSWORD secret needs 12 or more characters.")
    sign_in = {"password": password, "secret": True} if password else {"password": secrets.token_urlsafe(18), "secret": False}
    with open(os.open(PASSWORD_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as saved:
        json.dump(sign_in, saved)

os.environ.update(OPENJUTSU_HOME=HOME, OPENJUTSU_PASSWORD=sign_in["password"], TUNNEL="cloudflared")
sh("bash", f"{REPO_DIR}/scripts/linux/start.sh")
print()
print("Open:     ", open(f"{LOGS}/tunnel.url").read().strip())
print("User:      openjutsu")
print("Password: ", "your OPENJUTSU_PASSWORD secret" if sign_in["secret"] else sign_in["password"])
'''

KEEP = r'''
#@title 4. Keep the runtime busy
#@markdown Shows the address and ComfyUI's latest line every 30 s while this cell runs, and stops when a service stops. Colab does not say what counts as idle, so a running cell is meant to keep the runtime busy, without a guarantee. Stop the cell (■) when you are done; Openjutsu keeps running until the runtime ends.
import time
from IPython.display import clear_output

if not os.path.isfile(f"{LOGS}/tunnel.url"):
    raise Stop("Run 3. Start Openjutsu first.")
address = open(f"{LOGS}/tunnel.url").read().strip()


def last_line(name):
    with open(f"{LOGS}/{name}.log", errors="replace") as log:
        lines = log.read()[-4000:].replace("\r", "\n").strip().splitlines()
    return lines[-1] if lines else ""


try:
    while True:
        stopped = [name for name in ("comfyui", "proxy", "app", "tunnel") if not alive(name)]
        clear_output(wait=True)
        print(f"Openjutsu: {address}  (user: openjutsu)")
        print(time.strftime("%H:%M:%S"), "ComfyUI:", last_line("comfyui")[:200])
        if stopped:
            for name in stopped:
                print(f"\n{name} stopped. The end of {LOGS}/{name}.log:\n")
                print(open(f"{LOGS}/{name}.log", errors="replace").read()[-3000:])
            raise Stop(f"{', '.join(stopped)} stopped; see above. Run 3. Start Openjutsu to start it again.")
        time.sleep(30)
except KeyboardInterrupt:
    raise Done("Stopped watching. Openjutsu keeps running at the address above until the runtime ends.") from None
'''

STOP_NOTE = """
### Stop Openjutsu

Only to stop the services before the runtime ends, for example to start them again with another password.
"""

STOP = r'''
#@title 5. Stop Openjutsu
if not os.path.isfile(f"{REPO_DIR}/scripts/linux/start.sh"):
    raise Stop("Nothing to stop: Openjutsu is not installed on this runtime.")
sh("bash", f"{REPO_DIR}/scripts/linux/start.sh", "stop")
'''

notebook = {
    "cells": [md(INTRO), code(SETTINGS), code(CHECK), code(INSTALL), code(START), code(KEEP), md(STOP_NOTE), code(STOP)],
    "metadata": {
        "accelerator": "GPU",
        "colab": {"gpuType": "L4", "machine_shape": "hm", "provenance": []},
        "kernelspec": {"display_name": "Python 3", "name": "python3"},
        "language_info": {"name": "python"},
    },
    "nbformat": 4,
    "nbformat_minor": 0,
}
out = Path(__file__).resolve().parent / "openjutsu_colab.ipynb"
out.write_text(json.dumps(notebook, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
print(out)
