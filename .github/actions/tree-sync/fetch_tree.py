#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

TOOLCHAIN_KEYS = {
    "clang/host/linux-x86": "clang",
    "prebuilts/rust": "rust",
    "prebuilts/clang-tools": "clang-tools",
    "prebuilts/build-tools": "build-tools",
}


def resolve_manifest(workspace, dest_dir):
    manifest_ref = os.environ.get("CFG_MANIFEST", "").strip()
    target_root = os.environ.get("CFG_TARGET_DIR", "").strip()
    model = os.environ.get("CFG_MODEL", "").strip()
    out_xml = os.path.join(dest_dir, "manifest.xml")

    if not manifest_ref or "/" in manifest_ref or ".." in manifest_ref:
        print(f"::error::Invalid local manifest name: '{manifest_ref}'", file=sys.stderr)
        sys.exit(1)

    search_dirs = []
    if target_root:
        search_dirs.append(os.path.join(workspace, target_root, "manifests"))
    if model:
        search_dirs.append(os.path.join(workspace, "targets", model, "manifests"))

    for d in search_dirs:
        cand = os.path.join(d, manifest_ref)
        if os.path.isfile(cand):
            print(f"[INFO] Using target manifest: {os.path.relpath(cand, workspace)}")
            shutil.copy2(cand, out_xml)
            return out_xml

    print(f"::error::Manifest '{manifest_ref}' not found in targets/{model}/manifests/", file=sys.stderr)
    sys.exit(1)


def fetch_mirror_index(repo):
    if not repo:
        return set()
    res = subprocess.run(
        ["gh", "release", "view", "toolchain-cache", "--repo", repo, "--json", "assets"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if res.returncode != 0:
        return set()
    data = json.loads(res.stdout or "{}")
    return {a["name"] for a in data.get("assets", [])}


def build_archive_url(base_url, name, rev):
    if "github.com" in base_url:
        return f"{base_url}/{name}/archive/{rev}.tar.gz", True
    if "googlesource.com" in base_url:
        return f"{base_url}/{name}/+archive/{rev}.tar.gz", False
    if "git.codelinaro.org" in base_url or "gitlab.com" in base_url:
        return f"{base_url}/{name}/-/archive/{rev}.tar.gz", True
    return None, False


def extract_stream(archive_paths, dest_path, strip_one, nproc):
    cmd = ["tar", "-I", f"pigz -p {nproc}", "-x", "--no-same-owner", "-C", dest_path]
    if strip_one:
        cmd.append("--strip-components=1")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    assert proc.stdin is not None
    for p in archive_paths:
        with open(p, "rb") as src:
            shutil.copyfileobj(src, proc.stdin, length=4 * 1024 * 1024)
    proc.stdin.close()
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"tar extraction exited with code {rc}")


def sync_single_project(task, dest_root, repo, mirror_assets, nproc, debug):
    name, rel_path, url, strip_one, rev = task
    out_dir = os.path.join(dest_root, rel_path) if rel_path not in (".", "./") else dest_root
    os.makedirs(out_dir, exist_ok=True)

    tc_label = next((lbl for k, lbl in TOOLCHAIN_KEYS.items() if k in name), None)
    cache_base = f"{tc_label}-{rev}.tar.gz" if tc_label else ""

    t0 = time.time()
    for attempt in range(1, 4):
        shm_base = "/dev/shm" if os.path.isdir("/dev/shm") else None
        with tempfile.TemporaryDirectory(dir=shm_base, prefix="curio_sync_") as tmp_dir:
            try:
                used_mirror = False
                if cache_base and mirror_assets:
                    parts = sorted(a for a in mirror_assets if a.startswith(cache_base + ".part"))
                    dl_targets = parts if parts else ([cache_base] if cache_base in mirror_assets else [])
                    if dl_targets:
                        dl_paths = []
                        for asset in dl_targets:
                            subprocess.run(
                                [
                                    "gh",
                                    "release",
                                    "download",
                                    "toolchain-cache",
                                    "--repo",
                                    repo,
                                    "--pattern",
                                    asset,
                                    "--dir",
                                    tmp_dir,
                                    "--clobber",
                                ],
                                check=True,
                                stdout=None if debug else subprocess.DEVNULL,
                                stderr=None if debug else subprocess.DEVNULL,
                            )
                            dl_paths.append(os.path.join(tmp_dir, asset))
                        extract_stream(dl_paths, out_dir, strip_one, nproc)
                        used_mirror = True

                if not used_mirror:
                    if cache_base:
                        print(f"[WARN] Toolchain '{cache_base}' absent from mirror; fetching upstream")
                    dl_file = os.path.join(tmp_dir, "archive.tar.gz")
                    aria_cmd = [
                        "aria2c",
                        "-x16",
                        "-s16",
                        "-k1M",
                        "--allow-overwrite=true",
                        "--retry-wait=5",
                        "--max-tries=8",
                        "--file-allocation=none",
                        "-d",
                        tmp_dir,
                        "-o",
                        "archive.tar.gz",
                    ]
                    if not debug:
                        aria_cmd.extend(["--quiet", "--summary-interval=0", "--console-log-level=error"])
                    aria_cmd.append(url)
                    subprocess.run(aria_cmd, check=True)
                    extract_stream([dl_file], out_dir, strip_one, nproc)

                src_tag = "mirror" if used_mirror else "upstream"
                print(f"[OK] Synced {name} ({src_tag}, {time.time() - t0:.1f}s)")
                return True
            except Exception as exc:
                print(f"[RETRY] Attempt {attempt}/3 failed for {name}: {exc}")
                if attempt < 3:
                    time.sleep(attempt * 4)
    return False


def main():
    print("::group::Sync Kernel Source Tree")
    t_all = time.time()
    workspace = os.environ["GITHUB_WORKSPACE"]
    dest_dir = os.path.abspath(os.environ["SYNC_DEST"])
    repo = os.environ.get("TARGET_REPO", "").strip()
    debug = os.environ.get("SYNC_DEBUG", "false").lower() == "true"
    nproc = os.cpu_count() or 4

    os.makedirs(dest_dir, exist_ok=True)
    xml_path = resolve_manifest(workspace, dest_dir)
    mirror_assets = fetch_mirror_index(repo)
    if mirror_assets:
        print(f"[INFO] Indexed {len(mirror_assets)} asset(s) in toolchain-cache mirror")

    root = ET.parse(xml_path).getroot()
    remotes = {r.get("name"): r.get("fetch", "").rstrip("/") for r in root.findall("remote")}
    default = root.find("default")
    def_remote = default.get("remote") if default is not None else None
    def_rev = default.get("revision") if default is not None else None

    tasks = []
    links_and_copies = []
    for proj in root.findall("project"):
        name = proj.get("name", "")
        rel_path = proj.get("path", name)
        remote_name = proj.get("remote", def_remote)
        rev = proj.get("revision", def_rev)
        base_url = remotes.get(remote_name, "")
        url, strip_one = build_archive_url(base_url, name, rev)
        if not url:
            continue
        tasks.append((name, rel_path, url, strip_one, rev))
        for child in proj:
            if child.tag in ("linkfile", "copyfile"):
                links_and_copies.append((rel_path, child.tag, child.get("src"), child.get("dest")))

    workers = min(max(nproc * 2, 4), 16)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(
            pool.map(lambda t: sync_single_project(t, dest_dir, repo, mirror_assets, nproc, debug), tasks)
        )
    if not all(results):
        print("::error::One or more manifest repositories failed to sync")
        print("::endgroup::")
        sys.exit(1)

    for rel_path, tag, src_rel, dst_rel in links_and_copies:
        if not src_rel or not dst_rel:
            continue
        src_abs = os.path.join(dest_dir, rel_path, src_rel)
        dst_abs = os.path.join(dest_dir, dst_rel)
        os.makedirs(os.path.dirname(dst_abs), exist_ok=True)
        if tag == "linkfile":
            if os.path.lexists(dst_abs):
                os.remove(dst_abs)
            os.symlink(os.path.relpath(src_abs, os.path.dirname(dst_abs)), dst_abs)
        else:
            shutil.copy2(src_abs, dst_abs)

    elapsed = time.time() - t_all
    print(f"[OK] Synced {len(tasks)} repositories in {int(elapsed // 60)}m {elapsed % 60:.1f}s")
    print("::endgroup::")


if __name__ == "__main__":
    main()
