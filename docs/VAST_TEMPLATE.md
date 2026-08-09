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
so a Vast host needs no registry credentials. Available tags:

| Tag | Use |
|---|---|
| `latest` | tracks `main` — fine for testing |
| `sha-<short>` | **pin this for production**, so a later push can't change what your template launches |
| `main` | same as `latest` |

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

You lose nothing by choosing `Docker ENTRYPOINT`: the base image starts SSH and
Jupyter itself through its own supervisor units, so you still get both.

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

A fine-grained token scoped to that single repository with **Contents: Read**
is sufficient — it does not need write or org-wide access.

**Recommended:**

| Variable | Value | Why |
|---|---|---|
| `STORYRENDR_REF` | `main` | Pin the deployed branch/tag/SHA. |

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

## Troubleshooting

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
