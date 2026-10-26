#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import tempfile

MAX_SINGLE_BYTES = 1_900_000_000
CHUNK_BYTES = 1_500_000_000


def gh_list_assets(repo, tag):
    res = subprocess.run(
        ["gh", "release", "view", tag, "--repo", repo, "--json", "assets"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if res.returncode != 0:
        return None
    data = json.loads(res.stdout or "{}")
    return sorted(a["name"] for a in data.get("assets", []))


def ensure_release(repo, tag):
    if gh_list_assets(repo, tag) is not None:
        return
    print(f"[INFO] Creating release bucket '{tag}' in {repo}...")
    subprocess.run(
        [
            "gh",
            "release",
            "create",
            tag,
            "--repo",
            repo,
            "--title",
            f"Build Cache ({tag})",
            "--notes",
            "Automated build cache storage.",
        ],
        check=False,
    )


def restore_cache(repo, tag, key, fallbacks, target_path):
    print("::group::Release Cache Restore")
    assets = gh_list_assets(repo, tag)
    if not assets:
        print(f"[INFO] Cache bucket '{tag}' empty or absent; starting cold.")
        print("::endgroup::")
        return

    prefixes = [k.strip() for k in [key] + fallbacks.splitlines() if k.strip()]
    chosen_base = None
    chosen_files = []

    for pref in prefixes:
        needle = f"cache-{pref}"
        matches = [a for a in assets if a.startswith(needle) and ".tzst" in a]
        if not matches:
            continue
        first = sorted(matches, reverse=True)[0]
        base = first.split(".tzst")[0] + ".tzst"
        parts = sorted(a for a in assets if a.startswith(base + ".part"))
        if parts:
            chosen_base = base
            chosen_files = parts
        elif base in assets:
            chosen_base = base
            chosen_files = [base]
        if chosen_files:
            break

    if not chosen_files:
        print(f"[INFO] No cache hit for key '{key}'; starting cold.")
        print("::endgroup::")
        return

    print(f"[OK] Cache hit: {chosen_base} ({len(chosen_files)} file(s))")
    os.makedirs(target_path, exist_ok=True)
    parent_dir = os.path.dirname(os.path.abspath(target_path))

    with tempfile.TemporaryDirectory(prefix="curio_cache_dl_") as tmp_dir:
        dl_paths = []
        for name in chosen_files:
            print(f"[INFO] Downloading {name}...")
            subprocess.run(
                [
                    "gh",
                    "release",
                    "download",
                    tag,
                    "--repo",
                    repo,
                    "--pattern",
                    name,
                    "--dir",
                    tmp_dir,
                    "--clobber",
                ],
                check=True,
            )
            dl_paths.append(os.path.join(tmp_dir, name))

        tar_proc = subprocess.Popen(
            ["tar", "-I", "zstd -d -T0", "-xf", "-", "-C", parent_dir],
            stdin=subprocess.PIPE,
        )
        assert tar_proc.stdin is not None
        for p in dl_paths:
            with open(p, "rb") as src:
                shutil.copyfileobj(src, tar_proc.stdin, length=4 * 1024 * 1024)
        tar_proc.stdin.close()
        rc = tar_proc.wait()
        if rc != 0:
            raise SystemExit(f"[ERROR] Failed to extract cache archive (exit {rc})")

    print(f"[OK] Restored cache into {target_path}")
    print("::endgroup::")


def save_cache(repo, tag, key, target_path, zstd_level):
    print("::group::Release Cache Save")
    if not os.path.exists(target_path):
        print(f"[WARN] Cache path '{target_path}' does not exist; skipping save.")
        print("::endgroup::")
        return

    ensure_release(repo, tag)
    existing_assets = gh_list_assets(repo, tag) or []

    abs_target = os.path.abspath(target_path)
    parent_dir = os.path.dirname(abs_target)
    base_name = os.path.basename(abs_target)
    archive_name = f"cache-{key}.tzst"

    with tempfile.TemporaryDirectory(prefix="curio_cache_up_") as tmp_dir:
        archive_path = os.path.join(tmp_dir, archive_name)
        print(f"[INFO] Packing {abs_target} -> {archive_name} (zstd -{zstd_level})...")
        subprocess.run(
            [
                "tar",
                "--posix",
                "-h",
                "-I",
                f"zstd -T0 -{zstd_level}",
                "-cf",
                archive_path,
                "-C",
                parent_dir,
                base_name,
            ],
            check=True,
        )

        size = os.path.getsize(archive_path)
        upload_paths = []
        if size > MAX_SINGLE_BYTES:
            print(f"[INFO] Archive exceeds single-asset limit ({size} B); splitting into chunks...")
            idx = 0
            with open(archive_path, "rb") as src:
                while True:
                    chunk_path = os.path.join(tmp_dir, f"{archive_name}.part{idx:02d}")
                    written = 0
                    with open(chunk_path, "wb") as dst:
                        while written < CHUNK_BYTES:
                            buf = src.read(min(4 * 1024 * 1024, CHUNK_BYTES - written))
                            if not buf:
                                break
                            dst.write(buf)
                            written += len(buf)
                    if written == 0:
                        os.remove(chunk_path)
                        break
                    upload_paths.append(chunk_path)
                    idx += 1
            os.remove(archive_path)
        else:
            upload_paths.append(archive_path)

        uploaded_names = set()
        for up in upload_paths:
            fname = os.path.basename(up)
            print(f"[INFO] Uploading {fname} ({os.path.getsize(up)} B)...")
            subprocess.run(
                ["gh", "release", "upload", tag, up, "--repo", repo, "--clobber"],
                check=True,
            )
            uploaded_names.add(fname)

        stale = [
            a
            for a in existing_assets
            if (a == archive_name or a.startswith(archive_name + ".part")) and a not in uploaded_names
        ]
        for old_asset in stale:
            print(f"[INFO] Removing stale asset {old_asset}...")
            subprocess.run(
                ["gh", "release", "delete-asset", tag, old_asset, "--repo", repo, "--yes"],
                check=False,
            )

    print(f"[OK] Saved cache key '{key}' ({len(uploaded_names)} asset(s))")
    print("::endgroup::")


def main():
    mode = os.environ["CACHE_MODE"].strip().lower()
    repo = os.environ["TARGET_REPO"].strip()
    tag = os.environ.get("CACHE_TAG", "ccache-cache").strip()
    key = os.environ["CACHE_KEY"].strip()
    target_path = os.environ["CACHE_PATH"].strip()
    fallbacks = os.environ.get("CACHE_FALLBACKS", "")
    zstd_level = os.environ.get("CACHE_ZSTD_LEVEL", "6").strip()

    if mode == "restore":
        restore_cache(repo, tag, key, fallbacks, target_path)
    elif mode == "save":
        save_cache(repo, tag, key, target_path, zstd_level)
    else:
        raise SystemExit(f"[ERROR] Unsupported cache mode: {mode}")


if __name__ == "__main__":
    main()
