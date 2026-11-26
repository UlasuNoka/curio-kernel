#!/usr/bin/env python3
import gzip
import importlib.util
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def run(cmd, cwd=None, env=None, check=True):
    return subprocess.run(
        cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=check
    )


def load_targets_module(root):
    tpath = os.path.join(root, ".github/scripts/targets.py")
    spec = importlib.util.spec_from_file_location("curio_targets", tpath)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check_hygiene(root):
    staged = run(["git", "ls-files", "--stage"], cwd=root).stdout.splitlines()
    tracked_modes = {}
    for line in staged:
        meta, path = line.split("\t", 1)
        tracked_modes[path] = meta.split()[0]

    errs = []
    sh_files = []
    py_files = []
    text_exts = (".sh", ".py", ".yml", ".yaml", ".conf", ".toml", ".json", ".xml")
    ascii_exts = (".sh", ".py", ".yml", ".yaml", ".conf", ".toml")

    for path, mode in sorted(tracked_modes.items()):
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            continue
        if path.endswith((".sh", ".py")) and not path.endswith("lib/common.sh"):
            if mode != "100755":
                errs.append(f"{path}: git mode {mode} != 100755")
        if path.endswith(text_exts):
            raw = open(full, "rb").read()
            if raw.startswith(b"\xef\xbb\xbf"):
                errs.append(f"{path}: contains UTF-8 BOM")
            if b"\r\n" in raw:
                errs.append(f"{path}: contains CRLF")
            if path.endswith(ascii_exts) and any(b >= 128 for b in raw):
                errs.append(f"{path}: contains non-ASCII bytes")
        if path.endswith(".sh"):
            sh_files.append(path)
            txt = open(full, "r", encoding="utf-8", errors="replace").read()
            for ln, l in enumerate(txt.splitlines(), 1):
                if re.search(r'^\s*echo\s+"[^"]*(?<!\\)`', l):
                    errs.append(f"{path}:{ln}: unescaped backtick inside double-quoted echo")
                if re.search(r'(?:curl|wget)\b[^|]*\|\s*(?:bash|sh)\b', l):
                    errs.append(f"{path}:{ln}: unsafe pipe to shell")
                if re.search(r'(?<!:-)/tmp/[a-zA-Z0-9_.-]+', l):
                    errs.append(f"{path}:{ln}: hardcoded /tmp path")
        elif path.endswith(".py"):
            py_files.append(path)

    return errs, sh_files, py_files


def check_syntax(root, sh_files, py_files):
    errs = []
    for sp in sh_files:
        r = run(["bash", "-n", sp], cwd=root, check=False)
        if r.returncode != 0:
            errs.append(f"{sp}: {r.stderr.strip()}")
    with tempfile.TemporaryDirectory(prefix="curio_pyc_") as pyc_tmp:
        pe = os.environ.copy()
        pe["PYTHONPYCACHEPREFIX"] = pyc_tmp
        for pp in py_files:
            r = run([sys.executable, "-m", "py_compile", pp], cwd=root, env=pe, check=False)
            if r.returncode != 0:
                errs.append(f"{pp}: {r.stderr.strip()}")
    return errs


def check_pins(root):
    defaults_path = os.path.join(root, ".github/actions/kernel-pipeline/config/defaults.conf")
    defaults_txt = open(defaults_path, "r", encoding="utf-8").read()
    defaults_kv = {m.group(1): m.group(2) for m in re.finditer(r'^([A-Z0-9_]+)="([^"]*)"', defaults_txt, re.M)}
    errs = []
    for key in ("PATCHES_REPO_REF", "AK3_REPO_REF", "BBG_REPO_REF", "GKI_VERIFIER_REPO_REF"):
        val = defaults_kv.get(key, "")
        if not re.match(r"^[0-9a-f]{40}$", val):
            errs.append(f"{key}='{val}'")
    return errs, defaults_kv


def check_fragments(root):
    frag_dir = os.path.join(root, ".github/actions/kernel-pipeline/config/fragments")
    cfg_sh = open(os.path.join(root, ".github/actions/kernel-pipeline/scripts/06_configure.sh"), "r", encoding="utf-8").read()
    refs = sorted(set(re.findall(r'append_defconfig_fragment\s+"([^"]+)"', cfg_sh)))
    actual = sorted(f for f in os.listdir(frag_dir) if f.endswith(".conf"))
    errs = [f"missing fragment: {r}" for r in refs if r not in actual]
    unused = sorted(set(actual) - set(refs))
    if unused:
        errs.append("unused fragments: " + ", ".join(unused))
    return errs, len(refs)


def check_matrix(root):
    tscript = os.path.join(root, ".github/scripts/targets.py")
    if not os.path.isfile(tscript):
        return [".github/scripts/targets.py missing"]
    errs = []
    with tempfile.TemporaryDirectory(prefix="curio_mat_") as tmp_mat:
        gh_o = os.path.join(tmp_mat, "out")
        gh_s = os.path.join(tmp_mat, "sum")
        cases = [
            ("default ALL", {"INPUT_OS": "ALL", "INPUT_KERNEL": "ALL", "INPUT_DEVICE": "ALL", "INPUT_FILTER": ""}, True),
            ("fail-fast empty", {"INPUT_OS": "ALL", "INPUT_KERNEL": "ALL", "INPUT_DEVICE": "ALL", "INPUT_FILTER": "__nonexistent_target__"}, False),
        ]
        for label, ov, expect_ok in cases:
            open(gh_o, "w").close()
            open(gh_s, "w").close()
            env = os.environ.copy()
            env.update(ov)
            env["GITHUB_WORKSPACE"] = root
            env["GITHUB_OUTPUT"] = gh_o
            env["GITHUB_STEP_SUMMARY"] = gh_s
            res = subprocess.run([sys.executable, tscript, "plan"], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if (res.returncode == 0) != expect_ok:
                errs.append(f"matrix case '{label}' returned rc={res.returncode} (expected_ok={expect_ok})")
    return errs


def check_targets(root):
    wf_ci = open(os.path.join(root, ".github/workflows/kernel-ci.yml"), "r", encoding="utf-8").read()
    dev_m = re.search(r"device:.*?options:\n(.*?)\n\s+default:", wf_ci, re.S)
    dropdown_devices = set(re.findall(r"^\s*-\s+([A-Za-z0-9._-]+)\s*$", dev_m.group(1), re.M)) if dev_m else set()
    tmod = load_targets_module(root)
    profiles = tmod.load_all_profiles(root)
    tscript = os.path.join(root, ".github/scripts/targets.py")

    seen_tags = {}
    parsed_targets = []
    target_rows = []
    errors = []
    warnings = []

    for p in profiles:
        norm = p["profile"]
        target_dir = p["target_dir"]
        model = p["id"]
        variant = p["variant"]
        os_ver = p["os"]
        av = p["android_version"]
        kv = p["kernel_version"]
        art_tag = p["artifact_tag"]
        t_errs = list(p["errors"])

        tag_key = (art_tag, os_ver, av, kv)
        if tag_key in seen_tags:
            t_errs.append(f"artifact collision with {seen_tags[tag_key]}")
        else:
            seen_tags[tag_key] = norm

        with tempfile.TemporaryDirectory(prefix="curio_exp_") as tv:
            ev = os.environ.copy()
            ev.update({
                "GITHUB_WORKSPACE": root,
                "GITHUB_ENV": os.path.join(tv, "env"),
            })
            vr = run([sys.executable, tscript, "export-env", norm], cwd=root, env=ev, check=False)
            if vr.returncode != 0:
                t_errs.append("targets.py export-env failed")

        manifest_name = p["manifest"]
        manifest_path = os.path.join(root, target_dir, "manifests", manifest_name)
        manifest_ok = False
        if os.path.isfile(manifest_path):
            try:
                mroot = ET.parse(manifest_path).getroot()
                remotes = {r.get("name") for r in mroot.findall("remote") if r.get("name")}
                def_el = mroot.find("default")
                def_rem = def_el.get("remote") if def_el is not None else None
                def_rev = def_el.get("revision") if def_el is not None else None
                projs = mroot.findall("project")
                paths = {pr.get("path", pr.get("name", "")) for pr in projs}
                has_common = any(pt == "common" or pt.endswith("/common") for pt in paths)
                bad_refs = [
                    pr.get("name", "?") for pr in projs
                    if pr.get("remote", def_rem) not in remotes or not pr.get("revision", def_rev)
                ]
                if has_common and not bad_refs:
                    manifest_ok = True
                elif not has_common:
                    t_errs.append("manifest missing common kernel project")
                else:
                    t_errs.append("manifest invalid remote/revision: " + ", ".join(bad_refs[:3]))
            except Exception as exc:
                t_errs.append(f"invalid XML ({exc})")
        else:
            t_errs.append(f"missing manifest {manifest_name}")

        stub_name = p["boot_stub"]
        stub_path = os.path.join(root, target_dir, "stubs", stub_name)
        stub_ok = False
        if stub_name == "none":
            stub_ok = True
        elif os.path.isfile(stub_path):
            proc = subprocess.run(
                ["tar", "-I", "zstd -d", "-xf", stub_path, "-O"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if proc.returncode == 0 and proc.stdout.startswith(b"ANDROID!"):
                avb_pos = proc.stdout.rfind(b"AVBf")
                if avb_pos != -1 and avb_pos + 64 <= len(proc.stdout):
                    # AVBFooter big-endian fields: magic(4s), major(I), minor(I), orig_image_size(Q), vbmeta_offset(Q), vbmeta_size(Q)
                    _m, _maj, _min, _orig, _off, vb_sz = struct.unpack_from(">4sIIQQQ", proc.stdout, avb_pos)
                    if vb_sz > 0:
                        stub_ok = True
                    else:
                        t_errs.append("stub AVB vbmeta_size=0")
                else:
                    t_errs.append("stub missing AVBf footer")
            else:
                t_errs.append("invalid boot_stub archive or header")
        else:
            t_errs.append(f"missing boot_stub {stub_name}")

        base_name = p["kmi_baseline"]
        base_path = os.path.join(root, target_dir, "baselines", base_name)
        base_ok = False
        sym_cnt = 0
        if base_name == "none":
            base_ok = True
        elif os.path.isfile(base_path):
            try:
                with gzip.open(base_path, "rt", encoding="utf-8") as bf:
                    bdata = json.load(bf)
                syms = bdata.get("symbols") or bdata.get("crcs") or {}
                sym_cnt = len(syms) if isinstance(syms, (dict, list)) else 0
                rel_ver = str(bdata.get("kernel_release") or bdata.get("banner") or "")
                if sym_cnt > 0 and (not rel_ver or kv in rel_ver):
                    base_ok = True
                else:
                    t_errs.append(f"baseline mismatch (syms={sym_cnt}, rel={rel_ver})")
            except Exception as exc:
                t_errs.append(f"invalid baseline ({exc})")
        else:
            t_errs.append(f"missing baseline {base_name}")

        if model and model not in dropdown_devices:
            warnings.append(f"Model '{model}' in {norm} is absent from kernel-ci.yml device dropdown")

        row_status = "PASS" if not t_errs else "FAIL (" + "; ".join(t_errs) + ")"
        target_rows.append((
            model, variant, os_ver, f"{av}-{kv}", art_tag,
            manifest_name if manifest_ok else f"ERR:{manifest_name}",
            stub_name if stub_ok else f"ERR:{stub_name}",
            f"{base_name} ({sym_cnt})" if base_ok and sym_cnt else (base_name if base_ok else f"ERR:{base_name}"),
            row_status,
        ))
        if t_errs:
            errors.extend(f"{norm}: {e}" for e in t_errs)
        parsed_targets.append(p)

    return errors, warnings, target_rows, parsed_targets


def check_patches(root, defaults_kv, parsed_targets):
    local_patches = os.environ.get("CURIO_AUDIT_LOCAL_PATCHES", "").strip()
    tmp_patches = None
    try:
        if local_patches and os.path.isdir(local_patches):
            p_dir = local_patches
        else:
            tmp_patches = tempfile.mkdtemp(prefix="curio_patches_audit_")
            p_url = defaults_kv["PATCHES_REPO_URL"]
            p_ref = defaults_kv["PATCHES_REPO_REF"]
            run(["git", "init", "-q", tmp_patches])
            run(["git", "remote", "add", "origin", p_url], cwd=tmp_patches)
            run(["git", "fetch", "-q", "--depth", "1", "origin", p_ref], cwd=tmp_patches)
            run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=tmp_patches)
            p_dir = tmp_patches

        series_file = os.path.join(p_dir, "patches/opt/series")
        missing_series = []
        if not os.path.isfile(series_file):
            missing_series.append("patches/opt/series missing")
        else:
            for line in open(series_file, "r", encoding="utf-8").read().splitlines():
                s = line.split("#", 1)[0].strip()
                if s and not os.path.isfile(os.path.join(p_dir, "patches/opt", s)):
                    missing_series.append(s)

        patch_stat_errs = []
        patch_count = 0
        for dp, dns, fns in os.walk(p_dir):
            if ".git" in dns:
                dns.remove(".git")
            for fn in sorted(fns):
                if fn.endswith(".patch"):
                    fp = os.path.join(dp, fn)
                    patch_count += 1
                    if os.path.getsize(fp) == 0:
                        continue
                    sr = run(["git", "apply", "--stat", fp], cwd=p_dir, check=False)
                    if sr.returncode != 0:
                        patch_stat_errs.append(os.path.relpath(fp, p_dir))

        ref_errs = []
        ref_scripts = [
            ".github/actions/kernel-pipeline/scripts/05_apply_patches.sh",
            ".github/actions/kernel-pipeline/scripts/06_configure.sh",
            ".github/actions/kernel-pipeline/scripts/09_package_verify.sh",
        ]
        for cfg in parsed_targets:
            av = cfg["android_version"]
            kv = cfg["kernel_version"]
            os_l = cfg["os"].lower()
            vendor = cfg["vendor"]
            for rs in ref_scripts:
                stxt = open(os.path.join(root, rs), "r", encoding="utf-8").read()
                for m in re.finditer(r'\$\{KERNEL_PATCHES_FOLDER\}/([^\s"\'`]+)', stxt):
                    raw_ref = m.group(1)
                    resolved = (
                        raw_ref.replace("${ANDROID_VER}", av)
                        .replace("${KERNEL_VER}", kv)
                        .replace("${OS_LOWER}", os_l)
                        .replace("${CFG_OS_VERSION}", cfg["os"])
                        .replace("${CFG_VENDOR:-oplus}", vendor)
                        .replace("${CFG_VENDOR}", vendor)
                    )
                    if "$" in resolved:
                        continue
                    if not os.path.exists(os.path.join(p_dir, resolved.rstrip("/"))):
                        ref_errs.append(f"[{av}-{kv}] {os.path.basename(rs)}: {resolved}")

        ok = not (missing_series or patch_stat_errs or ref_errs)
        detail = (
            f"{patch_count} patches valid, opt/series OK, cross-refs OK"
            if ok
            else f"series={missing_series} stat={patch_stat_errs} refs={ref_errs}"
        )
        return ok, detail
    finally:
        if tmp_patches:
            shutil.rmtree(tmp_patches, ignore_errors=True)


def write_summary(check_rows, target_rows, warnings):
    gh_sum = os.environ.get("GITHUB_STEP_SUMMARY")
    if not gh_sum:
        return
    with open(gh_sum, "a", encoding="utf-8") as f:
        f.write("### Curio Kernel Repository Audit\n\n")
        f.write("| Check | Status | Details |\n|---|---|---|\n")
        for name, st, det in check_rows:
            f.write(f"| {name} | `{st}` | {det} |\n")
        f.write("\n#### Target Matrix Inventory\n\n")
        f.write("| Model | Variant | OS | Kernel | Tag | Manifest | Stub | Baseline | Status |\n")
        f.write("|---|---|---|---|---|---|---|---|---|\n")
        for r in target_rows:
            f.write(f"| `{r[0]}` | `{r[1]}` | `{r[2]}` | `{r[3]}` | `{r[4]}` | `{r[5]}` | `{r[6]}` | `{r[7]}` | `{r[8]}` |\n")
        if warnings:
            f.write("\n#### Warnings\n\n")
            for w in warnings:
                f.write(f"- {w}\n")


def main():
    root = os.getcwd()
    errors = []
    check_rows = []

    def record(name, ok, detail):
        check_rows.append((name, "PASS" if ok else "FAIL", detail))
        print(f"[{'OK' if ok else 'ERROR'}] {name}: {detail}")
        if not ok:
            errors.append(f"{name}: {detail}")

    hygiene_errs, sh_files, py_files = check_hygiene(root)
    record("Repo Hygiene & Hermetic Rules", not hygiene_errs, "clean across all tracked files" if not hygiene_errs else "; ".join(hygiene_errs[:5]))

    syntax_errs = check_syntax(root, sh_files, py_files)
    record("Shell & Python Syntax", not syntax_errs, f"bash -n ({len(sh_files)}), py_compile ({len(py_files)})" if not syntax_errs else "; ".join(syntax_errs[:3]))

    pin_errs, defaults_kv = check_pins(root)
    record("Hermetic SHA Pins (defaults.conf)", not pin_errs, "all 4 external repos pinned to 40-char hex SHAs" if not pin_errs else ", ".join(pin_errs))

    frag_errs, frag_cnt = check_fragments(root)
    record("Kconfig Fragments", not frag_errs, f"{frag_cnt} fragments verified" if not frag_errs else "; ".join(frag_errs))

    mat_errs = check_matrix(root)
    record("Workflow Matrix Resolver", not mat_errs, "default and fail-fast cases verified" if not mat_errs else "; ".join(mat_errs))

    t_errs, warnings, target_rows, parsed_targets = check_targets(root)
    record("Target Matrix & Artifacts", len(parsed_targets) > 0 and not t_errs, f"validated {len(parsed_targets)} target profile(s)" if not t_errs else "; ".join(t_errs[:3]))

    p_ok, p_detail = check_patches(root, defaults_kv, parsed_targets)
    record("Cross-Repo Patches & Series", p_ok, p_detail)

    write_summary(check_rows, target_rows, warnings)
    for w in warnings:
        print(f"::warning::{w}")

    if errors:
        print(f"\n[ERROR] Audit failed with {len(errors)} error(s).")
        sys.exit(1)
    print("\n[OK] All repository audit checks passed.")


if __name__ == "__main__":
    main()
