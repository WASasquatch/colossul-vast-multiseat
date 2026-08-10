# Starting a Storyrendr work session — plain-English guide

This guide is for whoever starts the server for the team. **No coding, no
terminal.** Everything is done on a website.

You'll rent a computer with 4 graphics cards on it. Our software turns that into
**4 separate Storyrendr workstations** — one per artist, all running at the same
time, nobody waiting on anyone else.

There are two parts:

- **Part 1** — one-time setup. You do this once, ever. About 10 minutes.
- **Part 2** — starting a work session. You do this each time the team works.
  About 5 minutes of clicking, then ~20 minutes of waiting.

Artists who just want to use their workstation: skip to
[Part 4](#part-4--for-artists).

---

## Before you start

You need:

- A credit card (Vast.ai bills by the hour).
- **The access key** — a long line of text starting with `github_pat_...`.

### Getting the access key

**Request it from [@WASasquatch](https://github.com/WASasquatch) (Colossul).**
It's the only thing that lets the server download our Storyrendr software, and
it isn't something you can generate yourself — it has to be issued from the
Colossul GitHub account that owns the private repository.

When you ask, mention that it's for a Vast.ai render server, so the right kind
of key is issued (read-only, limited to the one repository).

Treat the key like a password:

- Don't paste it into group chat, email threads, or a shared doc.
- Don't put it in a Vast **template** — Step 2 shows where it goes instead.
- If you think it has leaked, tell WASasquatch so it can be revoked and
  reissued. Keys also **expire**, so expect to request a fresh one periodically.

---

## Part 1 — One-time setup

### Step 1: Make an account

1. Go to **[cloud.vast.ai](https://cloud.vast.ai)**
2. Sign up, confirm your email, sign in.
3. Click **Billing** in the left sidebar and add credit.

> **How much?** A 4-GPU machine typically runs a few dollars per hour. Start
> with $50 to try it. You are charged **only while the server is running** —
> see [Part 3](#part-3--when-youre-done-important) for how to stop it.

### Step 2: Store the access key on your account

This keeps the key encrypted on Vast and out of the template.

1. Click your **account name** (top right) → **Account** / **Settings**.
2. Scroll to the **Environment Variables** section.
3. In the **key** box type exactly:
   ```
   GITHUB_TOKEN
   ```
4. In the **value** box paste the long `github_pat_...` key you got from
   [@WASasquatch](https://github.com/WASasquatch) (Colossul).
5. Click the **+** button to save it.

> Do this **here**, not in the template. Values stored on your account are
> encrypted. Vast's own docs warn: *"Never put sensitive information (passwords,
> API keys) in template environment variables."*

> ⚠️ **Vast has TWO different places called "Environment Variables", and they
> are not interchangeable.**
>
> - **This one** (account settings) feeds the software *inside* the server.
>   Only `GITHUB_TOKEN` goes here.
> - **The template's** Docker Options (Step 3) feeds *Vast's website* — the
>   Open button, port mappings. `OPEN_BUTTON_PORT` **only works there**;
>   putting it here does nothing, and the instance will say *"running but has
>   no web interface"*.

### Step 3: Create the template

A "template" is a saved recipe telling Vast what to run. You make it once and
reuse it forever.

1. Go to **[cloud.vast.ai/templates](https://cloud.vast.ai/templates)**
2. Click **+ New** (or the **pencil** icon on any template to start from a copy).
3. Fill in these fields — copy and paste exactly:

**Template Name**
```
Colossul Storyrendr — 4 seats
```

**Image Path:Tag**
```
ghcr.io/wasasquatch/colossul-vast-multiseat:latest
```

> **If you're told to use a specific version**, paste that instead — it'll look
> like `...colossul-vast-multiseat:sha-c833194`. Rented machines sometimes hold
> on to an old copy of `latest`, so a version number is the reliable way to be
> sure you're getting the newest software.

**Docker Options** (this opens the doors artists connect through, **and** makes
the blue "Open" button appear)
```
-e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=1 -p 1111:1111 -p 8080:8080 -p 8190:8190 -p 8191:8191 -p 8200:8200 -p 8201:8201 -p 8210:8210 -p 8211:8211 -p 8220:8220 -p 8221:8221
```

> The two `-e` entries at the front are exactly what Vast's own official
> templates use — without them the console says *"Instance is running but has
> no web interface"*. The `1` is a placeholder Vast replaces automatically.

**Launch Mode** — choose **`Docker ENTRYPOINT`**

> ⚠️ **This one matters most.** The other options ("Jupyter + SSH", "SSH only")
> switch off our software's startup process, and the server will boot up and
> then just sit there doing nothing. Pick `Docker ENTRYPOINT`.

**Disk Space** — set to **150 GB** or more.

**Template Visibility** — set to **Private**.

**Environment Variables** — add one here (this is *not* the secret key; that
went on your account in Step 2):

| Key | Value |
|---|---|
| `WEB_PASSWORD` | a password you choose |

> `WEB_PASSWORD` becomes the password for every seat and for the file manager.
> Without it the system generates a random one. The username is always `vastai`.
>
> (The Open-button settings went in **Docker Options** above — don't add them
> twice.)

4. Click **Create**.

Done. You never have to do Part 1 again.

---

## Part 2 — Starting a work session

### Step 4: Pick a machine

1. Go to **[cloud.vast.ai](https://cloud.vast.ai)** → **Search** in the sidebar.
2. Top-left, click the template selector / **Change Template** and pick
   **Colossul Storyrendr — 4 seats**.
3. In the filters on the left, set **# of GPUs** to **4**.
4. You'll get a list of machines. A good pick has:
   - **4 GPUs** (that's one per artist)
   - Plenty of **RAM** — aim for 128 GB or more
   - A **high reliability** score
   - **Fast download speed** (the server has a lot to fetch on first run)
   - **Max CUDA of 13.0 or higher** — shown on each offer. If the machine's
     number is lower, use the `...:latest-cuda12.9` image instead (see the
     cheat sheet), or pick a different machine.
5. Click **RENT** on the one you like.

> **Machines vary in quality.** Some hosts are simply broken and a rented
> instance will fail to start through no fault of yours. This is normal on a
> marketplace — destroy it and rent a different one. You are billed by the
> second, so a failed start costs pennies. See the first troubleshooting entry.

### Step 5: Wait for it to get ready

1. Click **Instances** in the sidebar. Your new server is there.
2. **First time on a brand-new server it takes about 20–30 minutes.** It's
   downloading and setting itself up. This is normal and only happens once per
   server.
3. Click the **Logs** button (📄 icon) on the instance to watch progress.
   Look for lines starting with `[colossul]`.

**Within the first minute or two**, a box like this appears in the log:

```
------------------------------------------------------------------
  CONTROL PANEL IS UP — you can open it NOW (setup continues)
      https://something-random.trycloudflare.com/?token=...
------------------------------------------------------------------
```

That link opens the control panel **already logged in** — one click, no
password. You can watch setup from there instead of the raw log.

You're ready when the log says:

```
[colossul] Provisioning complete — 4 seat(s) starting
[colossul]   Seat 0  GPU 0  Storyrendr :8190   ComfyUI :8191
[colossul]   Seat 1  GPU 1  Storyrendr :8200   ComfyUI :8201
[colossul]   Seat 2  GPU 2  Storyrendr :8210   ComfyUI :8211
[colossul]   Seat 3  GPU 3  Storyrendr :8220   ComfyUI :8221
```

### Step 6: Get the 4 artist links

The easiest way: scroll to the **end of the log**. The setup finishes by
printing a `COLOSSUL MULTI-SEAT — READY` block containing **one
already-logged-in link per artist** — copy each line and send it. That block is
also saved on the server (control panel → **Logs** → **ACCESS**), so you can
find it again any time.

Or use the control panel:

1. On your instance, click the **Open** button (or the CONTROL PANEL link from
   Step 5 if the button is missing).
2. A page opens listing every app on the server. You'll see four entries:

   | Entry | Give to |
   |---|---|
   | **Seat 0 Storyrendr** | Artist 1 |
   | **Seat 1 Storyrendr** | Artist 2 |
   | **Seat 2 Storyrendr** | Artist 3 |
   | **Seat 3 Storyrendr** | Artist 4 |

3. Right-click each **Seat N Storyrendr** link → **Copy link address**, and send
   one to each artist.

> The "Seat N ComfyUI" entries are for advanced users who want the node editor
> directly. Artists don't need them — it's built into Storyrendr already.

**Send each artist their own link and only their own.** Anyone with a link can
use that workstation, so treat the links like passwords. Don't post them in a
group chat.

If a link ever stops working, open the instance and click **Open** again — the
addresses change each time the server restarts.

---

## Part 2b — Getting updates

There are two different kinds of update, and they work very differently.

### Storyrendr changes (new features, bug fixes) — no new server needed

The server downloads Storyrendr fresh **every time it boots**. So:

- **STOP then START the instance.** That's it. It picks up the latest code,
  rebuilds if anything changed, and comes back in a couple of minutes.

If artists are mid-session and you'd rather not interrupt everyone, an admin can
run this from the Jupyter terminal instead — it only restarts seats if there was
actually something new:

```bash
colossul provision
```

### Server image changes (our launch scripts, ports, CUDA version) — new server

The image is fixed when the instance is **created**. Stopping and starting
reuses the same one, so an image update never reaches an existing instance.

- **DESTROY the instance and rent again.** You'll get the current image.
- Save anything you care about first — Destroy is permanent.

> **Which do I have?** If we tell you "we shipped a Storyrendr update", restart.
> If we tell you "there's a new image", rent a fresh instance. When in doubt,
> renting fresh always gets you everything.

---

## Part 3 — When you're done (important!)

**You are charged for every hour the server runs, even overnight while nobody
is using it.**

On the **Instances** page, each instance has two buttons:

| Button | What it does | When to use |
|---|---|---|
| ⏹ **STOP** | Pauses the server. **Keeps all work and settings.** Costs a small storage fee only. | End of the work day |
| 🗑 **DESTROY** | Deletes the server **and everything on it, permanently**. | Only when the project is finished and files are saved elsewhere |

**Use STOP at the end of each day.** Starting a stopped server again takes about
a minute, not 20 — it remembers everything.

**DESTROY cannot be undone.** Anything not downloaded is gone for good.

---

## Part 4 — For artists

Your producer sends you a link. That's everything you need.

1. Open the link in Chrome or Edge.
2. If asked to sign in, use the username and password your producer gives you.
3. You'll see Storyrendr. **This workstation is yours alone** — your own
   projects, your own renders, your own graphics card. Nothing you do slows
   anyone else down, and nobody can see your work.
4. Don't share your link with anyone, including teammates. Each person has
   their own.

Your finished renders appear in the gallery inside Storyrendr. **Download
anything you want to keep** — if the server is destroyed, files left on it are
gone.

### Getting files on and off the server

Most of the time Storyrendr's own upload and gallery download is all you need.

For anything else — bulk uploads, dragging files around, poking at folders —
there's a **file manager** at the **Jupyter** link on the Instance Portal
(port `8080`). It gives you a file browser, a text editor, drag-and-drop upload,
and download.

> **Ask your producer before using it.** Jupyter can see the *whole* server,
> including other artists' work and system settings, and it includes a terminal
> that can change anything. It's there for admin tasks, not day-to-day work.
> Nothing you need for normal rendering requires it.

---

## If something looks wrong

**It says "Instance is running but has no web interface" and there's no
Open button.**

The server is running fine — Vast just doesn't know which page to open.

**The #1 cause: `OPEN_BUTTON_PORT` was added to the wrong "Environment
Variables".** Vast has two sections with that name. The one in your **account
settings** (where the `GITHUB_TOKEN` goes) does *not* control the button —
only the **template's Docker Options** does. If you added it under your
account, that's why: move it into the template as shown in Step 3.

**Check what the instance actually received:** on the instance card, open the
**Environment** tab. If `OPEN_BUTTON_PORT` is not in that list, this instance
was created without it and the button can never appear on it.

**The fix:** make sure your template's **Docker Options** starts with

```
-e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=1
```

(exactly as in Step 3 — this mirrors Vast's own templates), **save the
template**, then destroy and re-rent. Editing a template never changes an
already-created instance, and be careful to rent using the *edited* template —
after saving, re-select it in the search page's template picker so you're not
launching a stale copy.

**You don't have to wait for that to get in.** Click the **LOG** button and look
near the end for lines like:

```
Default Tunnel started for Instance Portal (http://localhost:1111)
  - https://lesser-chocolate-moves-aircraft.trycloudflare.com
* Your web credentials are: vastai / 6618bbe7...
```

That first link **is** the portal — open it and log in with those credentials
(username `vastai`), and you'll get the same page the Open button would have
shown, with every seat listed.

**A login box is normal**, not an error — it's the instance's security. If the
long password is awkward to paste, put it in the address instead and the prompt
is skipped:

```
https://<your-tunnel>.trycloudflare.com/?token=<the long credential>
```

That's exactly what the Open button does behind the scenes. Setting
`WEB_PASSWORD` on the template (Step 3) replaces this long random string with a
password you choose.

To rescue the one you have:
1. Click the **⇄** (IP & Port Info) button on the instance card.
2. Find the line for port **1111** and open `http://<the address shown>`.
3. Log in as `vastai` with the `WEB_PASSWORD` you set in the template.

**The instance says "Error response from daemon ... nvidia-container-cli:
device error: GPU-xxxx: unknown device".**

**This is a broken machine, not a problem with our software** — the server never
even started. The host's graphics card isn't answering properly, and *any*
image would fail the same way on it.

> **DESTROY the instance and rent a different machine.** That's the fix. It
> costs pennies. If you like, note the Machine ID so you can avoid it later.

If it happens on several machines in a row, the image and the hosts' drivers may
be mismatched — switch the template's image to:
```
ghcr.io/wasasquatch/colossul-vast-multiseat:latest-cuda12.9
```
which works with older graphics drivers, and prefer offers whose **Max CUDA** is
13.0 or higher.

**A seat link just shows a spinner saying "Loading: Check instance logs for
progress".**

Almost always this means **the server isn't finished setting up yet** — it is
not an error. The web addresses go live within seconds of the server starting,
but the four workstations are the *last* thing to be built, 10–20 minutes in. So
the links exist and answer long before there's anything behind them.

Check the **LOG**. You are ready when you see the big block that ends with:

```
==================================================================
  COLOSSUL MULTI-SEAT — READY
==================================================================
```

Until then, the spinner is expected. If it's still spinning **30+ minutes** in,
look in the log for a line containing `ERROR` — that will say what went wrong.

**It's been half an hour and it isn't ready.**
Open the **Logs**. If you see `[colossul]` lines still appearing, it's working —
downloading takes a while on slower machines. Leave it another 15 minutes.

**The log says "no GITHUB_TOKEN was provided".**
The access key didn't reach the server. Go back to **Step 2** and check it's
saved on your account, spelled exactly `GITHUB_TOKEN`. Then **STOP** and
**START** the instance.

**The log mentions a token or authentication error.**
The key has probably expired — they're issued with an expiry date. Request a
fresh one from [@WASasquatch](https://github.com/WASasquatch) (Colossul), update
it in your account settings (Step 2), then **STOP** and **START** the instance.

**Nothing happens at all — no `[colossul]` lines ever appear.**
The **Launch Mode** is wrong. It must be `Docker ENTRYPOINT`. Fix the template,
then destroy this instance and rent again. (An existing instance can't be
changed — the setting is baked in when it's created.)

**Only some artists have a working link.**
The port list in **Docker Options** is missing entries. Compare it against
Step 3 — all ten `-p` entries must be there. Fix the template and rent a new
instance.

**An artist says their workstation is frozen.**
The producer can restart just that one without disturbing the others. Ask your
admin — it's one command (`colossul restart 2`).

---

## Cheat sheet

| | |
|---|---|
| Website | [cloud.vast.ai](https://cloud.vast.ai) |
| Image | `ghcr.io/wasasquatch/colossul-vast-multiseat:latest` |
| Image (older drivers) | `ghcr.io/wasasquatch/colossul-vast-multiseat:latest-cuda12.9` |
| Launch Mode | **Docker ENTRYPOINT** |
| Disk | 150 GB+ |
| GPUs | 4 |
| Account env var | `GITHUB_TOKEN` = the key from [@WASasquatch](https://github.com/WASasquatch) (Colossul) |
| First start | ~20–30 min |
| Later starts | ~1 min |
| End of day | **STOP** (not Destroy) |

---

## For WASasquatch / Colossul: issuing the access key

Only someone with access to the private `storyrendr-services` repository can
create this. The `GITHUB_TOKEN` in Step 2 is a GitHub **fine-grained personal
access token**.

1. [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)
2. **Resource owner** → your own account (the repo lives at
   `WASasquatch/storyrendr-services`).
3. **Expiration** → 90 days is reasonable.
4. **Repository access** → *Only select repositories* → `storyrendr-services`.
5. **Permissions** → *Repository permissions*:

| Permission | Access | Why |
|---|---|---|
| **Contents** | **Read-only** | The only one you set. Lets the server `git clone`/`fetch` the source. |
| **Metadata** | Read-only | GitHub adds this **automatically** and won't let you remove it — it's mandatory whenever a token touches a repository. Expect to see it pre-ticked. |

**That is the entire list.** Nothing else — no write access anywhere, no
Actions, Pull requests, Issues, Packages, Webhooks, or any account permission.
The server only ever reads the source; it never pushes.

6. Create it and copy the `github_pat_...` value — GitHub shows it once.

### Notes

- **The public submodule works automatically.** Storyrendr pulls in
  `AHEKOT/ComfyUI_VNCCS_Utils` (Pose Studio), which is a public third-party
  repository. You do **not** need to add it: GitHub tokens "always include
  read-only access to all public repositories", so restricting the token to one
  repo doesn't break it.
- **If the repo ever moves to a Colossul organization**, two extra steps apply:
  the org must enable *Allow access via fine-grained personal access tokens*,
  and an org owner may have to approve the token — it stays **pending** and the
  server will fail to clone until they do.
- **On expiry**, provisioning fails with an authentication error and the seats
  never start. Issue a fresh token, update it in the operator's Vast account
  settings, and STOP/START the instance.

Hand it over privately — a DM or password manager, not a group channel. Anyone
holding it can read the Storyrendr source. Rotate it when someone leaves.
