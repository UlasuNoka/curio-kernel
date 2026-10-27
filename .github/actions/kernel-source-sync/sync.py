#!/usr/bin/env python3
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

MAX_WORKERS = (os.cpu_count() or 2) * 4
NPROC = int(subprocess.check_output("nproc", shell=True).strip())
TARGET_REPO = os.environ.get("TARGET_REPO", "")
DEBUG = os.environ.get("DEBUG", "false").lower() == "true"

TOOLCHAIN_MAP = {
    "clang/host/linux-x86": "clang",
    "prebuilts/rust": "rust",
    "prebuilts/clang-tools": "clang-tools",
    "kernel/prebuilts/build-tools": "build-tools",
}

aria_quiet_flags = "--quiet --summary-interval=0" if not DEBUG else ""

curl_headers = (
    "-H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' "
    "-H 'Accept: */*' "
    "-H 'Connection: keep-alive' "
    "--tcp-fastopen"
)

aria2_headers = (
    "--header='User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' "
    "--header='Accept: */*' "
    "--header='Connection: keep-alive' "
)


def sync_project(task):
    name, path, url, strip, rev = task
    if path not in ["./", "."]:
        os.makedirs(path, exist_ok=True)

    start_time = time.time()
    MAX_ATTEMPTS = 3

    for attempt in range(1, MAX_ATTEMPTS + 1):
        shm_workspace = tempfile.mkdtemp(dir="/dev/shm", prefix="sync_")

        print(f"Syncing: {name} -> {path}")
        try:
            label = None
            for repo_key, type_label in TOOLCHAIN_MAP.items():
                if repo_key in name:
                    label = type_label
                    break

            found_in_cache = False
            base_filename = ""

            if label and TARGET_REPO:
                base_filename = f"{label}-{rev}.tar.gz"
                base_url = f"https://github.com/{TARGET_REPO}/releases/download/toolchain-cache"

                check_single = (
                    f"curl -IsL {curl_headers} --retry 5 --connect-timeout 20 "
                    f"-o /dev/null -w '%{{http_code}}' {base_url}/{base_filename}"
                )
                status_code = subprocess.check_output(check_single, shell=True).decode().strip()

                if status_code == "200":
                    if DEBUG:
                        print(f"  [CACHE] Downloading single file: {base_filename}")
                    aria_cmd = (
                        f"aria2c -x16 -s16 -k1M -j16 --retry-wait=5 --max-tries=10 "
                        f"-d {shm_workspace} --file-allocation=none {aria_quiet_flags} "
                        f"{aria2_headers} -o {base_filename} {base_url}/{base_filename}"
                    )
                    subprocess.run(aria_cmd, shell=True, check=True, capture_output=not DEBUG)
                    found_in_cache = True
                else:
                    if DEBUG:
                        print(f"  [CACHE] Single file not found, checking split parts for {base_filename}...")
                    parts_to_download = []
                    for suffix in [f"a{c}" for c in "abcdefghijklmnopqrstuvwxyz"]:
                        part_name = f"{base_filename}.part{suffix}"
                        check_part = (
                            f"curl -IsL {curl_headers} --retry 5 --connect-timeout 20 "
                            f"-o /dev/null -w '%{{http_code}}' {base_url}/{part_name}"
                        )
                        if subprocess.check_output(check_part, shell=True).decode().strip() == "200":
                            parts_to_download.append(f"{base_url}/{part_name}")
                        else:
                            break

                    if parts_to_download:
                        if DEBUG:
                            print(f"  [CACHE] Found {len(parts_to_download)} parts. Downloading...")
                        input_file_path = os.path.join(shm_workspace, f"{base_filename}.urls")
                        with open(input_file_path, "w") as f:
                            for part_url in parts_to_download:
                                p_suffix = part_url.split(".part")[-1]
                                p_name = f"{base_filename}.part{p_suffix}"
                                f.write(f"{part_url}\n  out={p_name}\n")

                        aria_bulk_cmd = (
                            f"aria2c -x16 -s16 -k1M -j16 --retry-wait=5 --max-tries=10 "
                            f"-d {shm_workspace} --file-allocation=none "
                            f"{aria_quiet_flags} {aria2_headers} --input-file={input_file_path}"
                        )
                        subprocess.run(aria_bulk_cmd, shell=True, check=True, capture_output=not DEBUG)
                        os.remove(input_file_path)
                        found_in_cache = True

                if not found_in_cache:
                    print(
                        f"::warning::Toolchain '{base_filename}' not found in GitHub Release cache! "
                        f"Falling back to direct upstream download from: {url}"
                    )

            if found_in_cache:
                parts = sorted(glob.glob(os.path.join(shm_workspace, "*.part*")))
                source = (
                    f"cat {' '.join(parts)} | "
                    if parts
                    else f"cat {os.path.join(shm_workspace, base_filename)} | "
                )
                extract_cmd = (
                    f"{source} tar -I 'pigz -p {NPROC} -b 256' -x "
                    f"--record-size=1M --no-same-owner -C {path} {strip}"
                )
                subprocess.run(extract_cmd, shell=True, check=True)
            else:
                direct_file = "dynamic_file.tar.gz"
                archive_path = os.path.join(shm_workspace, direct_file)
                aria_cmd = (
                    f"aria2c -x16 -s16 -k1M -j16 --allow-overwrite=true --retry-wait=5 --max-tries=10 "
                    f"-d {shm_workspace} -o {direct_file} {aria_quiet_flags} {aria2_headers} '{url}'"
                )
                if DEBUG:
                    print(f"  [DIRECT] Fetching: {url}")
                subprocess.run(aria_cmd, shell=True, check=True, capture_output=not DEBUG)
                extract_cmd = (
                    f"tar -I 'pigz -p {NPROC} -b 256' -x --record-size=1M "
                    f"-f {archive_path} -C {path} {strip}"
                )
                subprocess.run(extract_cmd, shell=True, check=True)

            duration = time.time() - start_time
            print(f"[OK] Synced {name} successfully! ({duration:.2f}s)")
            return True

        except subprocess.CalledProcessError as e:
            print(f"  [RETRY {attempt}/{MAX_ATTEMPTS}] {name} failed (exit {e.returncode}).")
            if e.stderr:
                print(f"  Stderr: {e.stderr.decode(errors='ignore')}")
            if attempt < MAX_ATTEMPTS:
                time.sleep(5)
        except Exception as e:
            print(f"  [RETRY {attempt}/{MAX_ATTEMPTS}] {name} failed with error: {e}")
            if attempt < MAX_ATTEMPTS:
                time.sleep(5)
        finally:
            if os.path.exists(shm_workspace):
                shutil.rmtree(shm_workspace, ignore_errors=True)

    return False


def main():
    print("::group::Download Manifest Archives")
    global_start = time.time()

    with open("manifest.xml", "r", encoding="utf-8") as f:
        manifest_content = f.read()

    root = ET.fromstring(manifest_content)
    top_dir = os.getcwd()

    remotes = {r.get("name"): r.get("fetch").rstrip("/") for r in root.findall("remote")}
    default = root.find("default")
    def_remote = default.get("remote") if default is not None else None
    def_rev = default.get("revision") if default is not None else None

    sync_tasks = []
    post_process_data = []

    for project in root.findall("project"):
        name = project.get("name")
        path = project.get("path", name)
        remote_name = project.get("remote", def_remote)
        rev = project.get("revision", def_rev)
        base_url = remotes.get(remote_name)

        if not base_url:
            continue

        if "github.com" in base_url:
            url = f"{base_url}/{name}/archive/{rev}.tar.gz"
            strip = "--strip-components=1"
        elif "googlesource.com" in base_url:
            url = f"{base_url}/{name}/+archive/{rev}.tar.gz"
            strip = ""
        elif "git.codelinaro.org" in base_url or "gitlab.com" in base_url:
            url = f"{base_url}/{name}/-/archive/{rev}.tar.gz"
            strip = "--strip-components=1"
        else:
            continue

        sync_tasks.append((name, path, url, strip, rev))

        for child in project:
            if child.tag in ["linkfile", "copyfile"]:
                post_process_data.append((path, child))

    if DEBUG:
        print(f"Starting parallel sync of {len(sync_tasks)} projects...")

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        success_list = list(executor.map(sync_project, sync_tasks))
        if not all(success_list):
            print("::error::One or more projects failed to sync!")
            print("::endgroup::")
            sys.exit(1)

    print("Processing linkfiles and copyfiles...")
    for path, child in post_process_data:
        src_rel = child.get("src")
        dest_rel = child.get("dest")
        if not src_rel or not dest_rel:
            continue

        src_path = os.path.join(top_dir, path, src_rel)
        dest_path = os.path.join(top_dir, dest_rel)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)

        if child.tag == "linkfile":
            if os.path.lexists(dest_path):
                os.remove(dest_path)
            rel_target = os.path.relpath(src_path, os.path.dirname(dest_path))
            os.symlink(rel_target, dest_path)
            print(f"  [Link] {dest_rel} -> {src_rel}")
        elif child.tag == "copyfile":
            shutil.copy2(src_path, dest_path)
            print(f"  [Copy] {dest_rel} from {src_rel}")

    total_duration = time.time() - global_start
    minutes = int(total_duration // 60)
    seconds = total_duration % 60
    print(f"Kernel Sync completed in {minutes}m {seconds:.2f}s")
    print("::endgroup::")


if __name__ == "__main__":
    main()
