# Colossul Multi-Seat — Storyrendr on Vast.ai

A Vast.ai Docker image that runs **four independent Storyrendr stacks on one
instance**, each pinned to its own GPU, so four employees can work at the same
time without sharing a render queue, a project database, or VRAM.

Each "seat" is a complete stack:

```
Seat 0 → GPU 0 → ComfyUI + backend + frontend
Seat 1 → GPU 1 → ComfyUI + backend + frontend
Seat 2 → GPU 2 → ComfyUI + backend + frontend
Seat 3 → GPU 3 → ComfyUI + backend + frontend
```

An employee opens **one URL** and gets everything — the Storyrendr UI, the
embedded ComfyUI graph editor, and their own private project library.

Employees **should never share their seat URL.** The links handed out by the
Instance Portal carry an access token in the query string, so passing one on
grants full access to that seat. The seats *are* behind Caddy's basic auth, but
every seat shares the instance's single credential — there is no per-seat
authentication and no barrier between employees. See
[Ports, tunnels, and auth](#ports-tunnels-and-auth).

---

## Why one image instead of four containers

Vast.ai runs exactly one container per instance, so the usual answer — four
containers with `--gpus device=N` — isn't available. Instead this image runs
`4 × 3 = 12` processes under the base image's supervisor, isolating seats by
port, GPU, and data directory rather than by container.

---

## Architecture

```
                    Caddy (TLS + Vast auth, from the base image)
                                     │
        ┌───────────────┬────────────┴────────────┬───────────────┐
      :8190           :8200                     :8210           :8220
     Seat 0          Seat 1                    Seat 2          Seat 3
        │
        ▼
  Vite preview server  :18190          ← the only port an employee needs
        │
        ├── /api/*         ──────────▶  backend  :18192   (GPU 0)
        ├── /comfyui-api/* ──────────▶  ComfyUI  :18191   (GPU 0)
        ├── /ws, /colossul ──────────▶  ComfyUI  :18191
        └── /comfyui-frame ──────────▶  ComfyUI UI, same-origin
```

The frontend already reverse-proxies everything it needs, so only the frontend
port has to be public. Backends stay on loopback.

### What is shared vs. isolated

**Every seat runs its own ComfyUI process on its own GPU.** Nobody ever waits on
anyone else's render. ComfyUI's job queue is an in-memory object built once per
process, so four processes means four independent queues — seat 2 submitting a
40-minute video job has no effect on seat 3.

What's shared is only **read-only bytes on disk**: the ComfyUI code and the
model weights. Concurrent reads don't contend, and each process loads what it
needs into *its own* GPU's VRAM. Sharing them keeps disk flat as seats are
added — four seats cost roughly one seat's disk — without coupling any two
seats at runtime.

| Shared (read-only, never serialises) | Isolated per seat (everything writable) |
|---|---|
| ComfyUI *install directory* and `custom_nodes/` | **The ComfyUI process, its GPU, and its job queue** |
| **The model store** — one copy of every checkpoint | ComfyUI `input/`, `output/`, `user/`, `temp/` |
| Storyrendr checkout, backend `.venv`, `node_modules`, `dist/` | Backend `outputs/` and the SQLite databases under it |
| Workflow JSONs, preset media | ComfyUI's own `comfyui.db` asset database |
| — | All three ports |

> One install directory is not one server. The four seats exec the same
> `main.py` as four separate processes, each with `CUDA_VISIBLE_DEVICES` pinned
> and its own `--port`, `--user-directory`, `--database-url` and output paths.
> `tests/check-parallelism.sh` asserts this: distinct processes, GPUs, ports and
> writable paths, and that each backend resolves its ComfyUI from its own seat
> index rather than a constant.

Isolation is enforced by environment variables and CLI flags, not by copying
code: `OUTPUTS_DIR` is a pydantic setting and the backend stores its databases
at `${OUTPUTS_DIR}/_databases/`, so pointing each seat at its own path gives
each employee their own projects, outputs, and history.

ComfyUI needs one extra nudge. It derives its SQLite path from `__file__` —
`<install>/user/comfyui.db` — and does *not* re-derive it from
`--user-directory`, so every seat would otherwise contend on a single database
file. Each seat is given an explicit `--database-url`.

One `dist/` safely backs all four frontends because the only build-time flag
the client reads is `VITE_COMFYUI_EMBED`, which is identical for every seat.
The per-seat ComfyUI and backend URLs are read by the preview server at
**runtime**.

---

## Ports

Each seat owns a block of ten external ports from 8190. Internal = external +
10000, per the Vast base-image convention where Caddy terminates TLS and auth
on the external port.

| Seat | GPU | Storyrendr (open this) | ComfyUI direct | Backend |
|------|-----|------------------------|----------------|---------|
| 0 | 0 | **8190** → 18190 | 8191 → 18191 | 18192 (loopback) |
| 1 | 1 | **8200** → 18200 | 8201 → 18201 | 18202 (loopback) |
| 2 | 2 | **8210** → 18210 | 8211 → 18211 | 18212 (loopback) |
| 3 | 3 | **8220** → 18220 | 8221 → 18221 | 18222 (loopback) |

This range avoids every port the base image binds: instance portal `11111`,
tunnel manager `11112`, tensorboard `16006`, Jupyter `18080`, stock ComfyUI
`18188`, **ComfyUI API wrapper `18288`**, syncthing `18384`. The obvious
`8188/8288/8388` per-seat layout collides with that API wrapper on seat 1, so
`tests/check-topology.sh` asserts against the reserved list.

---

## Ports, tunnels, and auth

Three separate mechanisms, and this image only controls two of them.

| Step | Who does it | Automatic? |
|---|---|---|
| Declare the host ports | **The Vast template** | ❌ **You must add the port list** |
| Reverse-proxy external → internal, with TLS + auth | Caddy, from our `PORTAL_CONFIG` | ✅ baked into the image |
| Create a public Cloudflare tunnel per seat | `tunnel_manager`, from `/etc/portal.yaml` | ✅ one per seat, at boot |

**Ports are the manual step.** The image cannot open host ports — `EXPOSE` is
decorative and Vast maps ports from the template alone. Worse, the mapping is
what *activates* the rest: Caddy's config generator skips any entry where

```python
if external_port == internal_port or not os.environ.get(f"VAST_TCP_PORT_{external_port}"):
    continue
```

`VAST_TCP_PORT_8190` only exists if 8190 is in the template's port list. Omit a
seat's port and that seat is silently absent from the portal and unreachable —
the process is running fine, nothing proxies to it.

**Tunnels are automatic.** `tunnel_manager` calls `_create_default_tunnels()`
unconditionally at startup and creates a Cloudflare quick tunnel for *every*
application in `/etc/portal.yaml` — which is generated from our `PORTAL_CONFIG`.
Because each seat is its own portal entry, each employee gets their own
`https://<four-random-words>.trycloudflare.com` URL with no extra configuration.
(The seat frontends set `VITE_ALLOWED_HOSTS=all` precisely because those
hostnames are random per boot and can't be allow-listed ahead of time.)

**Auth is automatic but shared.** Caddy adds `basic_auth` to every proxied entry
unless `ENABLE_AUTH=false` or the port is in `AUTH_EXCLUDE`. Credentials are
instance-wide: `WEB_USERNAME` (default `vastai`) and `WEB_PASSWORD` /
`OPEN_BUTTON_TOKEN`. Portal links append `?token=…` so they open without a
prompt — convenient, and the reason a shared link is a shared seat.

---

## Deploying

> **Not technical?** [docs/QUICK_START.md](docs/QUICK_START.md) is a
> click-by-click, no-terminal walkthrough for producers and artists. The rest of
> this section is the engineering view.

**You never build anything on Vast.** Vast only *pulls* a prebuilt image and
runs it. Two different things get built, at two different times — that
distinction is the thing to get straight:

| | What it builds | Where | When | Takes |
|---|---|---|---|---|
| **Image build** | the Docker image (Node, ffmpeg, scripts on top of `vastai/comfy`) | GitHub Actions | on every push to `main` | ~10 min, automatic |
| **App build** | Storyrendr itself (`uv sync`, `npm ci`, `vite build`) | *inside the running instance* | first boot of each instance | 10–20 min, automatic |

The app is built on the instance rather than baked into the image because the
Storyrendr source is private and fetched at runtime — that's what keeps this
repo and image publishable, and lets you ship code changes without a rebuild.

### Step 1 — Get the image published (automatic)

Pushing to `main` builds and publishes the image. Nothing else to do — the
package inherits this repo's public visibility, so Vast hosts can pull it
anonymously. Tags published on each push:

```
ghcr.io/wasasquatch/colossul-vast-multiseat:latest
ghcr.io/wasasquatch/colossul-vast-multiseat:main
ghcr.io/wasasquatch/colossul-vast-multiseat:sha-<short>   <- pin this for production
```

Watch builds under
[Actions](https://github.com/WASasquatch/colossul-vast-multiseat/actions). To
confirm a host can pull it, from a machine *not* logged in to GHCR:

```bash
docker manifest inspect ghcr.io/wasasquatch/colossul-vast-multiseat:latest
```

If that ever fails with `denied`, the package visibility has been changed —
fix it under Repo → **Packages** → **Package settings** → **Change visibility**.

(Local building with `./build.sh` is only for iterating on the Dockerfile — it
is not part of deployment.)

### Step 2 — Create the Vast template (one time)

Full field list in [docs/VAST_TEMPLATE.md](docs/VAST_TEMPLATE.md). The essentials:

| Field | Value |
|---|---|
| Image | `ghcr.io/wasasquatch/colossul-vast-multiseat:latest` |
| Ports | `1111,8080,8190,8191,8200,8201,8210,8211,8220,8221` |
| Env | `GITHUB_TOKEN=<fine-grained PAT, Contents:Read on storyrender-services>` |
| Disk | 150 GB+ |
| Launch mode | **`Docker ENTRYPOINT`** — the other modes replace the entrypoint and nothing starts |

> The port list is **not optional**, and getting it wrong fails silently. Caddy
> skips any portal entry whose `VAST_TCP_PORT_<external>` variable is missing,
> and Vast only sets that for ports declared here — so an undeclared seat has no
> URL and no tunnel, while its processes run perfectly.
> See [Ports, tunnels, and auth](#ports-tunnels-and-auth).

### Step 3 — Rent a 4-GPU machine and launch

Boot order, all automatic:

```
Vast pulls the image
  └─ supervisord starts                       (/.provisioning held)
       ├─ your PROVISIONING_SCRIPT, if set    <- model downloads go here
       └─ Colossul provisioning               <- clone + build Storyrendr, 10-20 min
            └─ 4 seats start, one per GPU
```

Follow it in the instance **Logs** tab; look for `[colossul]` lines. It ends with:

```
[colossul] Provisioning complete — 4 seat(s) starting
[colossul]   Seat 0  GPU 0  Storyrendr :8190   ComfyUI :8191
```

Restarting a stopped instance skips the app build and comes up in under a minute.

### Step 4 — Hand out the URLs

```bash
colossul-seats urls
```

Each seat has its own auto-created Cloudflare tunnel. Give each employee one
link — and see the sharing warning at the top of this README.

### Shipping a Storyrendr change later

No image rebuild, no new template:

```bash
colossul-seats provision
```

That fetches the new commit, rebuilds, and **restarts the seats itself** when
the build actually changed. (`supervisorctl update` alone wouldn't: it only
restarts programs whose *config* changed, and the seat configs are identical
across a source update — so the seats would have carried on serving the old
build.) Nothing restarts when there's nothing new, so re-running it is safe
while artists are working.

---

## Operating an instance

```bash
colossul-seats status        # per-seat process state
colossul-seats urls          # the URL for each employee
colossul-seats logs 2        # tail seat 2's three services
colossul-seats restart 2     # recycle one employee's stack
colossul-seats restart all   # recycle every seat
colossul-seats gpu           # nvidia-smi, annotated with seat ownership
colossul-seats provision     # pull the latest commit and reload
colossul-seats rebuild       # force a full rebuild, then reload
```

Standard `supervisorctl` also works: seats are grouped as `seat0`…`seat3`, so
`supervisorctl restart seat1:` recycles just that seat.

### Models

All seats read **one shared store**, so a 40 GB checkpoint costs 40 GB whether
you run one seat or eight:

```
/workspace/ComfyUI_Assets/models/
├── checkpoints/     ├── loras/          ├── vae/
├── controlnet/      ├── text_encoders/  ├── diffusion_models/
└── … 25 folder types, mirroring ComfyUI's own models/ layout
```

Drop weights straight in — `models/checkpoints/foo.safetensors` is visible to
every seat immediately, no restart needed. Vast's `PROVISIONING_SCRIPT` is the
natural place to download them on boot; it runs before the seats start.

It is wired up with a generated `extra_model_paths.yaml` (at
`/etc/colossul/extra_model_paths.yaml`) passed to each seat via
`--extra-model-paths-config`. Three design points worth knowing:

- **It lives outside the ComfyUI install** (`ComfyUI_Assets`, not
  `ComfyUI/models`), so reinstalling or upgrading ComfyUI can't take the weights
  with it, and the store can be moved to its own volume. Relocate with
  `COLOSSUL_ASSETS_ROOT`.
- **`is_default: true`**, so a model downloaded through one seat's ComfyUI
  Manager lands in the shared store where all seats see it — rather than inside
  a single install.
- **It's additive.** ComfyUI still scans its own `models/` dir, so anything
  already there (the base image symlinks SD 1.5 in) keeps resolving.

Legacy aliases are preserved — `models/clip/`, `models/unet/` and
`models/t2i_adapter/` resolve alongside their modern names, so older workflows
keep loading.

To add paths of your own without them being overwritten, create
`/workspace/ComfyUI_Assets/extra_model_paths.yaml`; provisioning never touches
that file and passes it alongside the generated one.

### Updating Storyrendr

Source is fetched at boot, not baked into the image, so shipping a code change
does not need an image rebuild:

```bash
colossul-seats provision && colossul-seats restart all
```

---

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | — | **Required.** PAT with read access to the private repo. Issued by [@WASasquatch](https://github.com/WASasquatch) (Colossul). |
| `STORYRENDR_REF` | `main` | Branch/tag/SHA to deploy. |
| `STORYRENDR_REPO` | the Colossul repo | Override to deploy a fork. |
| `NUM_SEATS` | `4` | Seat count. Also update `PORTAL_CONFIG` — see below. |
| `GPU_MAP` | identity | Comma-separated physical GPUs, e.g. `4,5,6,7`. |
| `COLOSSUL_COMFYUI_ARGS` | — | Extra ComfyUI flags for every seat. **Not** `COMFYUI_ARGS` — see caveats. |
| `COMFYUI_HOME` | auto-detected | Override if the base image moves ComfyUI. |
| `COLOSSUL_ASSETS_ROOT` | `$WORKSPACE/ComfyUI_Assets` | Shared model store. Point at a mounted volume to keep weights across instances. |
| `SKIP_VNCCS_EXTRAS` | `0` | `1` skips the multi-GB SAM3D install (disables Pose Studio extraction). |
| `SKIP_COMFYUI_REQS` | `0` | `1` skips re-syncing ComfyUI's own requirements. |
| `FORCE_REPROVISION` | `0` | `1` rebuilds even when the commit is unchanged. |

### Changing the seat count

`PORTAL_CONFIG` is read at first boot, so provisioning cannot add ports to it
afterwards. Changing `NUM_SEATS` is a two-step:

```bash
colossul-portal-config 6        # prints PORTAL_CONFIG + the port list
```

Paste both into the template alongside `NUM_SEATS=6`.

---

## Testing

```bash
tests/run-all.sh [path/to/colossul-frontend]
```

Runs everything; no Docker build required. CI additionally runs **shellcheck**
at `warning` level over every script — string/array confusion in a shell script
is exactly what produced the empty-argument bug above, and a linter catches that
class of thing where a behavioural test only catches one instance of it.

Individually:

| Check | Guards |
|---|---|
| `tests/check-parallelism.sh` | The core requirement: **N ComfyUI processes, one per GPU**, with distinct ports and distinct writable paths, and each backend/frontend resolving its ComfyUI from its own seat index. Fails if anything writable ever becomes shared. |
| `tests/check-seat-argv.sh` | Runs the **real** seat scripts against a stub interpreter and asserts the exact argv and environment: no stray empty argument (argparse rejects one, and it stopped every seat from starting), correct per-seat ports/dirs/database, GPU pinning, `GPU_MAP`, glob safety, and that `COLOSSUL_ASSETS_ROOT` overrides actually take effect. |
| `tests/check-update-path.sh` | That `colossul-seats provision` genuinely ships a change: the patched (always-dirty) tree doesn't block the update, the patch is re-applied afterwards, and seats are restarted so they serve the new build. |
| `tests/check-topology.sh` | Ports never collide (1–8 seats) **and never hit a base-image service**; generated supervisor units are valid INI with the right start order and real script paths; seats map to distinct GPUs; **the `PORTAL_CONFIG` baked into the Dockerfile and the port list in the docs both still match the port math**. |
| `tests/check-args.sh` | The base image's `COMFYUI_ARGS` can never smuggle a `--port` into a seat; all nine seat-owned flags are stripped in both `--flag value` and `--flag=value` form; each seat still gets its own `--database-url`. |
| `tests/check-tunnels.sh` | `colossul-seats urls` maps each seat to **its own** tunnel and never another seat's; an unmapped port yields empty rather than a wrong URL; malformed payloads degrade quietly. |
| `tests/check-models.sh` | The generated `extra_model_paths.yaml` parses the way ComfyUI parses it and every path resolves to a real directory; all 25 v0.30 model folder types are covered; the three legacy aliases survive; `custom_nodes` is never redirected. |
| `tests/check-patch.sh` | The upstream patch applies, produces valid TypeScript, honours `VITE_BACKEND_URL`, is idempotent, preserves line endings, and **fails loudly** if upstream moves. |

The `PORTAL_CONFIG` check earns its keep: that variable is consumed at first
boot and cannot be corrected afterwards, so drift between it and the ports the
seats actually bind would send employees to dead ports with a new template as
the only fix.

---

## Security model

This repo and the image it publishes are public. The Storyrendr application
itself is **private** and is not redistributed here.

**Nothing in this repo or image grants access to the private repo.** No token,
key, or source is baked in at build time — the image is built entirely from
public bases and the scripts in this repo. The only reference to
`storyrender-services` is its URL, which returns 404 to anyone without access.

Access is supplied at *runtime*, by the operator, as a `GITHUB_TOKEN` in their
own Vast template. Recommended handling:

- Use a **fine-grained PAT** scoped to `storyrender-services` alone, with
  **Contents: Read-only** — the only permission you select. GitHub adds
  **Metadata: Read-only** automatically and won't let you remove it. Nothing
  else is needed: provisioning clones and fetches, never pushes.
- Give it an **expiry**, and rotate it when employees change.
- Treat it as readable by anyone who can reach the instance: it lands in the
  container's environment, and all seats share the instance's Vast token. It is
  not a per-employee secret.

The clone uses a git credential helper rather than an `https://token@github.com`
URL, so the token is never written into `.git/config` and never appears in git's
output on failure.

## Known caveats

**`COMFYUI_ARGS` is deliberately ignored.** The base image presets it to
`--disable-auto-launch --enable-cors-header --port 18188` for its single stock
instance. Because argparse takes the *last* occurrence of a flag, passing that
through would pin every seat to port 18188 and three of four would crash-loop.
Use `COLOSSUL_COMFYUI_ARGS`; seat-owned flags are stripped from it with a
warning.

**The frontend patch should go upstream.** `vite.config.ts` reads the ComfyUI
endpoint from the environment but hardcodes the `/api` proxy to
`http://127.0.0.1:8189`. With one backend per seat, every frontend would
otherwise proxy to seat 0 and employees would silently share one database.
`scripts/patches/patch_vite_backend_url.py` rewrites it at provision time and
refuses to apply if upstream changes shape. Adding `VITE_BACKEND_URL` support
to storyrender-services would let this patch be deleted.

**No isolation between seats.** Per the deployment brief, all seats sit behind
the instance's single Vast token. Employees are handed distinct URLs but can
reach each other's seats. Their *data* is separate; their *access* is not.

**Jupyter is a root shell, behind that same credential.** The base image runs
JupyterLab on 8080 with `--IdentityProvider.token='' --ServerApp.password=''`
and `root_dir=/`, plus a `bash` terminal. It binds loopback and relies on
Caddy's auth — which is the one instance-wide credential every seat already
uses. So anyone with a seat URL can, if they look, read any other seat's work or
read `GITHUB_TOKEN` from the environment. That is also *how you administer the
box*: `Docker ENTRYPOINT` mode means Vast injects no SSH, so Jupyter's terminal
is the way in. Dropping 8080 from the template locks everyone out including you.
Keep the token short-expiry, read-only and single-repo accordingly.

**ComfyUI Manager is shared.** Installing custom nodes from one seat's UI
writes to the shared `custom_nodes/` and affects everyone, and concurrent
installs from two seats can conflict. Prefer `colossul-seats provision`.

**Host RAM, not just VRAM.** Four ComfyUI processes each load their own copy of
a model into system RAM. Size the instance for 4× the single-seat footprint;
GPU count alone is not the constraint.

---

## Layout

```
colossul-vast-multiseat/
├── Dockerfile                  # vastai/comfy + node, ffmpeg, uv; retires the stock unit
├── build.sh
├── supervisor/
│   └── colossul-provision.conf # one-shot boot provisioner
├── scripts/
│   ├── provision.sh            # fetch, build once, generate seat units
│   ├── seat-comfyui.sh         # per-seat wrappers (GPU pinning lives here)
│   ├── seat-backend.sh
│   ├── seat-frontend.sh
│   ├── lib/common.sh           # port math, GPU map, ComfyUI discovery, unit generation
│   ├── bin/colossul-seats      # operator CLI
│   ├── bin/colossul-portal-config
│   └── patches/patch_vite_backend_url.py
├── tests/
│   ├── run-all.sh
│   ├── check-topology.sh
│   └── check-patch.sh
└── docs/VAST_TEMPLATE.md
```

Seat units are **generated at provision time**, not baked into the image, which
guarantees no seat can start before the source tree and venv it needs exist.
