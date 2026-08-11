#!/usr/bin/env python3
"""Check models.txt against a colossul-model-scanner report.

    tools/workflow-parity.py <report.csv> [models.txt]

Answers one question: if an artist opens these workflows on a provisioned
instance, does every model resolve — or do they have to go swapping paths?

The subtlety this exists to catch: ComfyUI resolves a model name INSIDE its
category folder, so a workflow saved with "Qwen\\Edit\\foo.safetensors" needs
models/loras/Qwen/Edit/foo.safetensors. A flat models/loras/foo.safetensors
downloads perfectly and still leaves a red node — present, but unreachable.
That failure is invisible to any check that only compares filenames.

Exit status is 1 if anything is present-but-unreachable, since that is a bug in
this repo. Genuinely absent models (our own trained LoRAs) exit 0 with a note:
they are expected, and no manifest can fix them.
"""
import csv, sys, os

# Scanner category -> ComfyUI models/ subfolder. None = a node pack fetches it
# itself on first use, so it is deliberately not ours to provision.
FOLDER = {
    "checkpoints": "checkpoints", "diffusion_models": "diffusion_models",
    "vae": "vae", "loras": "loras", "controlnet": "controlnet",
    "text_encoders": "text_encoders", "clip_vision": "clip_vision",
    "upscale_models": "upscale_models", "audio_encoders": "audio_encoders",
    "audio_separation": "audio_separation",
    "depthanything": None, "birefnet": None, "film": None, "rife": None,
    "preprocessor": None, "llm": None,
}
# Models that live in a pack-specific folder rather than a standard one.
FOLDER_OVERRIDE = {"video_depth_anything_vitb.pth": "video_depth_anything"}


def manifest_dests(path):
    out = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#") or s.startswith("["):
                continue
            out.add(s.split()[0])
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    report = argv[1]
    manifest = argv[2] if len(argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "models.txt")

    provided = manifest_dests(manifest)
    with open(report, encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))

    covered, wrongpath, absent, notours = [], [], [], []
    for r in rows:
        cat, ref, name = r["category"], r["model"], r["name"]
        n = int(r.get("workflow_count") or 0)
        if r.get("kind") != "file":
            notours.append((ref, n, f"{r.get('kind')}: the node resolves this, not a path"))
            continue
        folder = FOLDER_OVERRIDE.get(name, FOLDER.get(cat, "?"))
        if folder is None:
            notours.append((ref, n, "the node pack downloads it on first use"))
            continue
        want = "models/{}/{}".format(folder, ref.replace("\\", "/"))
        if want in provided:
            covered.append((want, n))
            continue
        elsewhere = sorted(p for p in provided if p.rsplit("/", 1)[-1] == name)
        (wrongpath if elsewhere else absent).append((ref, n, want, elsewhere))

    print(f"parity: {len(covered)} covered, {len(wrongpath)} unreachable, "
          f"{len(absent)} absent, {len(notours)} not ours "
          f"({len(rows)} references)")

    if wrongpath:
        print("\nPRESENT BUT UNREACHABLE — downloads fine, workflow still red:")
        for ref, n, want, elsewhere in sorted(wrongpath, key=lambda x: -x[1]):
            print(f"  {n:2d} workflow(s)  {ref}")
            print(f"      wants    {want}")
            print(f"      manifest {elsewhere[0]}")

    if absent:
        print("\nNOT PROVISIONED (expected for our own trained LoRAs):")
        for ref, n, want, _ in sorted(absent, key=lambda x: -x[1]):
            print(f"  {n:2d} workflow(s)  {want}")

    if wrongpath:
        print(f"\nFAIL: {len(wrongpath)} model(s) would not resolve. Fix the dest "
              f"paths in models.txt, or add a link: entry.")
        return 1
    print("\nOK: every provisioned model is at the path its workflows ask for.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
