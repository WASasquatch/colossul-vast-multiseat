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

**Docker Options** (this opens the doors artists connect through)
```
-p 1111:1111 -p 8080:8080 -p 8190:8190 -p 8191:8191 -p 8200:8200 -p 8201:8201 -p 8210:8210 -p 8211:8211 -p 8220:8220 -p 8221:8221
```

**Launch Mode** — choose **`Docker ENTRYPOINT`**

> ⚠️ **This one matters most.** The other options ("Jupyter + SSH", "SSH only")
> switch off our software's startup process, and the server will boot up and
> then just sit there doing nothing. Pick `Docker ENTRYPOINT`.

**Disk Space** — set to **150 GB** or more.

**Template Visibility** — set to **Private**.

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
5. Click **RENT** on the one you like.

### Step 5: Wait for it to get ready

1. Click **Instances** in the sidebar. Your new server is there.
2. **First time on a brand-new server it takes about 20–30 minutes.** It's
   downloading and setting itself up. This is normal and only happens once per
   server.
3. Click the **Logs** button (📄 icon) on the instance to watch progress.
   Look for lines starting with `[colossul]`.

You're ready when the log says:

```
[colossul] Provisioning complete — 4 seat(s) starting
[colossul]   Seat 0  GPU 0  Storyrendr :8190   ComfyUI :8191
[colossul]   Seat 1  GPU 1  Storyrendr :8200   ComfyUI :8201
[colossul]   Seat 2  GPU 2  Storyrendr :8210   ComfyUI :8211
[colossul]   Seat 3  GPU 3  Storyrendr :8220   ComfyUI :8221
```

### Step 6: Get the 4 artist links

1. On your instance, click the **Open** button.
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
admin — it's one command (`colossul-seats restart 2`).

---

## Cheat sheet

| | |
|---|---|
| Website | [cloud.vast.ai](https://cloud.vast.ai) |
| Image | `ghcr.io/wasasquatch/colossul-vast-multiseat:latest` |
| Launch Mode | **Docker ENTRYPOINT** |
| Disk | 150 GB+ |
| GPUs | 4 |
| Account env var | `GITHUB_TOKEN` = the key from [@WASasquatch](https://github.com/WASasquatch) (Colossul) |
| First start | ~20–30 min |
| Later starts | ~1 min |
| End of day | **STOP** (not Destroy) |

---

## For WASasquatch / Colossul: issuing the access key

Only someone with access to the private `storyrender-services` repository can
create this. The `GITHUB_TOKEN` in Step 2 is a GitHub **fine-grained personal
access token**.

1. [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)
2. **Resource owner** → your own account (the repo lives at
   `WASasquatch/storyrender-services`).
3. **Expiration** → 90 days is reasonable.
4. **Repository access** → *Only select repositories* → `storyrender-services`.
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
