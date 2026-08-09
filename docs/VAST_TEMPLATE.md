# Vast.ai template setup

Exact settings for a 4-seat Colossul instance. Fields map to the "Create
Template" form on [cloud.vast.ai](https://cloud.vast.ai/templates/).

> **Nothing is built on Vast.** Vast pulls a prebuilt image and runs it. The
> image is built by GitHub Actions on every push to `main`; the Storyrendr
> application is then built *inside* the instance on first boot, because its
> source is private and fetched at runtime. Both are automatic — see
> [Deploying](../README.md#deploying).

---

## 1. Image

```
ghcr.io/wasasquatch/colossul-vast-multiseat:latest
```

Published automatically by CI and **publicly pullable** — verified anonymously,
so a Vast host needs no registry credentials. Two CUDA variants are built from
every commit, because hosts differ in driver version:

| Tag | Base | Use |
|---|---|---|
| `latest` | CUDA 13.2 | Default. Needs a host with **Max CUDA ≥ 13.0**. |
| `latest-cuda12.9` | CUDA 12.9 | Fallback for hosts with older drivers. |
| `sha-<short>` / `sha-<short>-cuda12.9` | either | **Pin one for production**, so a later push can't change what your template launches. |
| `main` | CUDA 13.2 | Same as `latest`. |

Check the **Max CUDA** figure on a Vast offer before renting. If it is below the
image's CUDA version, the instance will fail to start.

If a host ever reports `denied` or `manifest unknown`, the package visibility
was changed: Repo → **Packages** → `colossul-vast-multiseat` → **Package
settings** → **Change visibility** → **Public**. To deliberately keep it
private, add GHCR credentials (a PAT with `read:packages`) in the template's
registry authentication section instead.

**Launch mode:** `Docker ENTRYPOINT` — **this one is not optional.**

The other two modes ("Jupyter + SSH" and "Interactive shell server, SSH")
*replace* the image's entrypoint: per Vast's docs, "the docker entrypoint for
your image will not be run. It will be replaced with our instance setup
script." That would stop `/opt/instance-tools/bin/entrypoint.sh` from running,
so supervisord never starts, so no seat ever starts — the instance boots and
sits there doing nothing.

**What you keep, and what you give up:**

| | Available? | How |
|---|---|---|
| **JupyterLab** — file browser, editor, terminal | ✅ Yes | The image runs its own Jupyter on internal `18080`, proxied to external **8080**. Vast's docs explicitly support this: *"To run a proxied Jupyter application, you should run the instance in SSH or Entrypoint mode with Jupyter's configuration retained in the PORTAL_CONFIG variable."* |
| Instance Portal, tunnels, Caddy auth | ✅ Yes | The image's own supervisor units |
| **Vast's injected SSH / `scp`** | ❌ No | Entrypoint mode injects nothing: *"As ssh/jupyter access is not provided, your docker image is responsible for setting up any such connections as needed."* |

So you do **not** lose file management. Jupyter gives a file browser, an editor,
upload/download, and a **terminal that is a full root `bash` shell** — which is
also where you run `colossul-seats`. What you give up is Vast's own SSH/`scp`.

Keeping port **8080** in the port list is therefore not optional if you want any
way into the box. See [Who can reach Jupyter](#who-can-reach-jupyter).

---

## 2. Ports to expose

```
1111,8080,8190,8191,8200,8201,8210,8211,8220,8221
```

| Port | Purpose |
|------|---------|
| 1111 | Instance Portal (the landing page with every seat's link) |
| 8080 | Jupyter |
| 8190 / 8200 / 8210 / 8220 | **Storyrendr, seats 0–3 — what employees open** |
| 8191 / 8201 / 8211 / 8221 | ComfyUI direct, seats 0–3 |

### Who can reach Jupyter

Worth a deliberate decision rather than a default. The base image starts Jupyter
with **no authentication of its own**:

```
--IdentityProvider.token=''  --ServerApp.password=''  --ServerApp.root_dir=/
--ServerApp.terminado_settings="{'shell_command': ['/bin/bash']}"
```

It binds `127.0.0.1` and relies entirely on Caddy's basic auth on port 8080. But
**every seat shares the one instance credential**, so in practice anyone you
give a seat URL to also holds the credential for Jupyter — and Jupyter is a
**root shell rooted at `/`**. That means any artist could, if they went looking:

- read or delete another artist's projects and renders,
- read `GITHUB_TOKEN` out of the environment.

Three options:

| Option | Effect |
|---|---|
| **Keep 8080 exposed** (default) | Everyone can reach Jupyter. Fine for a trusted in-house team; assume the token is readable by anyone with a seat. |
| **Drop 8080 from the port list** | Nobody can reach Jupyter — **including you**. No terminal, no file manager, no `colossul-seats`. Only choose this if you never need to touch the box. |
| **Set a separate `WEB_PASSWORD`** and hand seat URLs out as portal links only | Slightly raises the bar, but the token is still in the link. Not real isolation. |

Given the brief — a trusted internal team — the default is reasonable. Just
treat `GITHUB_TOKEN` as visible to everyone with a seat, and prefer a
short-expiry, read-only, single-repo token accordingly.

Each seat owns a block of ten ports from 8190. That range deliberately avoids
everything the base image binds — notably its ComfyUI API wrapper on **18288**,
which the more obvious `8188/8288/8388` layout would have collided with on
seat 1.

Backends are intentionally absent: the frontend proxies `/api` to them over
loopback. To expose their FastAPI `/docs` too, regenerate with
`colossul-portal-config 4 --backends` and add the resulting ports.

---

## 3. Environment variables

**Required:**

| Variable | Value |
|---|---|
| `GITHUB_TOKEN` | A GitHub PAT with read access to `WASasquatch/storyrender-services` — request it from [@WASasquatch](https://github.com/WASasquatch) (Colossul) |

A fine-grained token scoped to that single repository is sufficient:

| Permission | Access |
|---|---|
| **Contents** | **Read-only** — the only one you select |
| **Metadata** | Read-only — added automatically by GitHub, cannot be removed |

Nothing else: no write access, no Actions/PRs/Packages, no account permissions.
Provisioning only clones and fetches; it never pushes. The public
`ComfyUI_VNCCS_Utils` submodule needs no extra grant — GitHub tokens always
carry read-only access to public repositories.

**Recommended:**

| Variable | Value | Why |
|---|---|---|
| `STORYRENDR_REF` | `main` | Pin the deployed branch/tag/SHA. |
| `WEB_PASSWORD` | a password you choose | The login for every seat, ComfyUI, Jupyter and the portal. |

> **Set `WEB_PASSWORD`.** Without it the password is the auto-generated
> `OPEN_BUTTON_TOKEN`, which you can normally only read by SSHing in and running
> `echo $OPEN_BUTTON_TOKEN` — and `Docker ENTRYPOINT` mode has no SSH. The Open
> button still works (it sets the cookie for you), but if you ever need to hand
> someone a bare URL, or the Open button is unavailable, a known `WEB_PASSWORD`
> is the difference between getting in and rebuilding the instance. Username is
> `vastai`.

**Optional:**

| Variable | Example | Why |
|---|---|---|
| `NUM_SEATS` | `6` | Seat count. Requires a matching `PORTAL_CONFIG` — see below. |
| `GPU_MAP` | `4,5,6,7` | Run seats on specific physical GPUs. |
| `COLOSSUL_COMFYUI_ARGS` | `--highvram` | Extra flags for every seat's ComfyUI. |
| `SKIP_VNCCS_EXTRAS` | `1` | Skip the multi-GB SAM3D install. Disables Pose Studio pose extraction. |
| `SKIP_COMFYUI_REQS` | `1` | Skip the ComfyUI requirements re-sync at provision time. |
| `COLOSSUL_ASSETS_ROOT` | `/mnt/models` | Relocate the shared model store, e.g. onto a mounted volume so weights outlive the instance. Default `/workspace/ComfyUI_Assets`. |
| `PROVISIONING_SCRIPT` | a URL | Vast's own hook — good for downloading models on boot. Runs *before* Colossul provisioning. |

> **Use `COLOSSUL_COMFYUI_ARGS`, not `COMFYUI_ARGS`.** The base image presets
> `COMFYUI_ARGS=--disable-auto-launch --enable-cors-header --port 18188` for its
> single stock instance. Since argparse takes the *last* occurrence of a flag,
> honouring it would pin every seat to port 18188 and three of four would
> crash-loop. The image therefore ignores `COMFYUI_ARGS` entirely and strips any
> seat-owned flag (`--port`, `--listen`, `--database-url`, the `*-directory`
> flags, `--cuda-device`) from `COLOSSUL_COMFYUI_ARGS`, logging what it dropped.

`PORTAL_CONFIG` is already baked into the image for 4 seats. Only set it if you
change `NUM_SEATS`.

---

## 4. Disk

**150 GB minimum**, more if you use large video models. Rough budget:

| Item | Size |
|---|---|
| Image | ~15 GB |
| Backend venv (torch for SAM3D) | ~8 GB |
| `node_modules` + `dist` | ~1 GB |
| Models — **one shared copy** at `/workspace/ComfyUI_Assets/models` | 20–100 GB+ |
| Per-seat outputs (×4) | grows with use |

Only the model store scales with your workflows, and every seat reads the same
copy of it — so a 40 GB checkpoint costs 40 GB whether you run one seat or
eight. Adding a fifth seat costs almost no extra disk.

Set `COLOSSUL_ASSETS_ROOT` to a mounted volume if you want the weights to
outlive the instance.

---

## 5. Machine selection

- **4 GPUs** for 4 seats, one each.
- **System RAM matters as much as VRAM.** Each ComfyUI process loads its own
  copy of a model into host RAM. Budget ~4× a single-seat instance; aim for
  32 GB+ per seat for video workflows.
- Prefer hosts with good disk bandwidth — four processes loading checkpoints
  simultaneously is I/O heavy on first use.

---

## 6. First boot — what to expect, and for how long

| Phase | Duration | Where to watch |
|---|---|---|
| Vast pulls the image | 2–10 min, host-dependent | instance card status |
| supervisord starts, `/.provisioning` held | seconds | Logs tab |
| Your `PROVISIONING_SCRIPT` (model downloads) | yours | Logs tab |
| Colossul provisioning: clone → `uv sync` → `npm ci` → `vite build` | **10–20 min** | Logs tab, `[colossul]` lines |
| 4 seats start | ~1 min | `colossul-seats status` |

Only the last two are ours. A stopped-and-restarted instance skips the build
entirely and is up in under a minute.



The boot order is fixed by the base image: supervisord starts, then Vast runs
`PROVISIONING_SCRIPT`/`PROVISIONING_MANIFEST` while `/.provisioning` exists,
then that flag clears. Colossul provisioning waits for the flag, so your model
downloads finish before the Storyrendr build starts and seats never boot
against a half-built instance.

Provisioning then takes **10–20 minutes**: clone, `uv sync`, `npm ci`, frontend
build, SAM3D extras. Watch it in the instance **Logs** tab — look for lines
prefixed `[colossul]`.

It finishes with:

```
[colossul] Provisioning complete — 4 seat(s) starting
[colossul]   Seat 0  GPU 0  Storyrendr :8190   ComfyUI :8191
...
```

Subsequent restarts skip the build and come up in well under a minute.

---

## 7. Handing out seats

Each seat gets its own public Cloudflare tunnel automatically — `tunnel_manager`
opens one for every entry in `/etc/portal.yaml`, which is generated from
`PORTAL_CONFIG`. No extra configuration, but the hostnames are random per boot,
so collect them after the instance is up:

```bash
colossul-seats urls        # queries tunnel_manager for the live tunnel per seat
```

Or open the Instance Portal (port 1111) for the same links, labelled per seat.

> Tunnels only exist for ports that were declared in the template. Caddy skips
> any portal entry without a matching `VAST_TCP_PORT_<external>` variable, so a
> missing port means that seat never appears in the portal and gets no tunnel —
> even though its processes are running normally.

Every seat uses the instance's standard Vast credentials: username `vastai`,
password `$OPEN_BUTTON_TOKEN` (or `WEB_PASSWORD` if you set one in the
template). Per the deployment brief there is no per-seat password — employees
can reach each other's seats if they try, though their projects and outputs
remain separate.

---

## Updating an instance

| What changed | How it reaches a running instance |
|---|---|
| **Storyrendr source** (the app) | Automatically on every boot. **STOP → START**, or `colossul-seats provision` for no downtime. |
| **This image** (seat scripts, ports, `OPEN_BUTTON_PORT`, CUDA base) | **Not at all.** Destroy and rent again. |

The image is fixed at instance *creation*. Stop/start reuses the existing
container, so it never re-pulls — standard Docker semantics, not a Vast quirk.

That split is deliberate: the app is fetched at runtime precisely so day-to-day
code changes never require an image rebuild, a new template, or a new instance.
Only changes to the launch machinery itself do.

`colossul-seats provision` is the no-downtime path: it fetches, rebuilds only if
the commit moved, and restarts seats **only** when a new build actually landed —
so it's safe to run while artists are working.

---

## Troubleshooting

**"Instance is running but has no web interface" / no Open button.**

The instance is fine — Vast just doesn't know which port to open. That comes
from `OPEN_BUTTON_PORT`, which the image now sets to `1111` (the Instance
Portal). An instance created from an image built **before** that fix shows this
message.

To get into an already-running instance without the Open button:

1. Click the **IP & Port Info** button (⇄) on the instance card.
2. Find the host port mapped to container port **1111** and open
   `http://<instance-ip>:<that port>`.
3. Log in as `vastai` with your `WEB_PASSWORD` — or, if you didn't set one,
   the auto-generated `OPEN_BUTTON_TOKEN`, which is awkward to retrieve without
   SSH. This is why setting `WEB_PASSWORD` in the template is recommended.

Port **1111 must be in the port list** for any of this to work.

**The instance never starts: `nvidia-container-cli: device error: GPU-<uuid>:
unknown device`.**

Not an image problem — the container never ran. This is an OCI *prestart hook*,
executed by the NVIDIA runtime before your entrypoint: it asked the host driver
for a GPU by UUID and the driver didn't recognise it. Usually a host whose GPU
has dropped off the bus or whose driver state is stale after maintenance. Any
image, including stock `vastai/comfy` or `nvidia/cuda`, fails identically on
that machine.

**Destroy the instance and rent a different one.** If it repeats across several
machines, suspect a driver/CUDA mismatch instead: switch to
`:latest-cuda12.9` and filter for offers with a higher **Max CUDA**.

**Provisioning failed with a token error.** `GITHUB_TOKEN` is missing, expired,
or lacks read access to the repo. Fix it in the template and restart, or set it
in the shell and run `colossul-seats provision`.

**A seat is missing from the portal / has no tunnel.** Its external port isn't
in the template's port list. Caddy only proxies an entry when Vast has set
`VAST_TCP_PORT_<external>`, and it sets that only for declared ports. Check with
`env | grep VAST_TCP_PORT` — you should see one per seat port. Adding a port
needs a template edit and a fresh instance; `PORTAL_CONFIG` is read at first
boot and cannot be extended in place.

**A seat's frontend crash-loops.** Usually a port collision: `--strictPort`
makes Vite fail loudly rather than quietly moving to another seat's port. Check
`colossul-seats logs <n>` and confirm no stray process holds the port.

**All seats show the same projects.** The `vite.config.ts` patch did not apply.
Check the provisioning log for `[patch]`, and run `tests/check-patch.sh`
against the deployed commit — upstream may have changed shape.

**ComfyUI won't start on a seat.** Confirm `torch` imports with the detected
interpreter, and check `nvidia-smi` shows as many GPUs as `NUM_SEATS`. If the
base image relocated ComfyUI, set `COMFYUI_HOME` explicitly.

**A model dropdown is empty in one seat.** Models go in
`/workspace/ComfyUI_Assets/models/<type>/`, and the type folder must match
ComfyUI's own naming (`checkpoints`, `loras`, `text_encoders`, …). Confirm the
seat actually loaded the config — its startup log lists the extra model paths —
and that the file exists at `/etc/colossul/extra_model_paths.yaml`. Regenerate
with `colossul-seats provision`. Weights added to the store are picked up
without a restart; a *new folder type* is not.

**Everything lands on GPU 0.** `nvidia-smi` inside the container should list all
4 GPUs. If the instance was rented with fewer GPUs than `NUM_SEATS`, seats will
collide on device 0 — reduce `NUM_SEATS` or rent a bigger machine.
