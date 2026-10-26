#!/usr/bin/env python3
import fnmatch
import glob
import json
import os
import re
import sys
import tomllib

VALID_LTO = {"none", "thin", "full"}
VALID_OPT = {"O2", "O3"}
VALID_SCHED = {"none", "hmbird"}
VALID_TCP = {"bbr", "bbr3"}
VALID_NF = {"ttl", "ipset"}


def load_protected_modules(root):
    p = os.path.join(root, ".github/actions/kernel-pipeline/config/protected_modules.txt")
    if not os.path.isfile(p):
        return set()
    res = set()
    for line in open(p, "r", encoding="utf-8").read().splitlines():
        s = line.split("#", 1)[0].strip()
        if s:
            res.add(s)
    return res


def parse_profile(root, rel_path, protected=None):
    norm = rel_path.replace("\\", "/")
    full = os.path.join(root, norm) if not os.path.isabs(norm) else norm
    rel = os.path.relpath(full, root).replace("\\", "/")
    target_dir = os.path.dirname(os.path.dirname(rel))
    stem = os.path.splitext(os.path.basename(rel))[0]

    with open(full, "rb") as f:
        raw = tomllib.load(f)

    errs = []
    if raw.get("schema") != 1:
        errs.append(f"unsupported schema: {raw.get('schema')}")

    dev = raw.get("device") or {}
    src = raw.get("source") or {}
    krn = raw.get("kernel") or {}
    tc = raw.get("toolchain") or {}
    art = raw.get("artifacts") or {}
    feat = raw.get("features") or {}
    mods = raw.get("modules") or {}
    run_cfg = raw.get("runner") or {}

    model = str(dev.get("id", "")).strip()
    vendor = str(dev.get("vendor", "oplus")).strip().lower()
    soc = str(dev.get("soc", "")).strip()
    platform = str(dev.get("platform", "")).strip()
    os_ver = str(dev.get("os", "")).strip()
    variant = str(dev.get("variant", "") or stem).strip()

    if not re.match(r"^[A-Za-z0-9._-]+$", model):
        errs.append(f"invalid device.id '{model}'")
    if not re.match(r"^[a-z0-9_-]+$", vendor):
        errs.append(f"invalid device.vendor '{vendor}'")
    if not re.match(r"^[A-Za-z0-9_-]+$", soc):
        errs.append(f"invalid device.soc '{soc}'")
    if not re.match(r"^[A-Za-z0-9._-]+$", platform):
        errs.append(f"invalid device.platform '{platform}'")
    if not re.match(r"^A[0-9]+$", os_ver):
        errs.append(f"invalid device.os '{os_ver}'")

    manifest = str(src.get("manifest", "")).strip()
    if not manifest or "/" in manifest or ".." in manifest or " " in manifest or not manifest.endswith(".xml"):
        errs.append(f"source.manifest must be a local .xml filename: '{manifest}'")

    gki = str(krn.get("gki", "")).strip()
    gm = re.match(r"^(android[0-9]+)-([0-9]+\.[0-9]+)$", gki)
    if not gm:
        errs.append(f"kernel.gki must match android<N>-<X.Y>: '{gki}'")
        av, kv = "", ""
    else:
        av, kv = gm.group(1), gm.group(2)

    localver = str(krn.get("localversion", "")).strip()
    if " " in localver:
        errs.append("kernel.localversion cannot contain spaces")
    build_ts = str(krn.get("build_timestamp", "")).strip()
    opt_level = str(krn.get("opt_level", "O2")).strip()
    lto = str(krn.get("lto", "none")).strip()

    if opt_level not in VALID_OPT:
        errs.append(f"kernel.opt_level must be in {sorted(VALID_OPT)}: '{opt_level}'")
    if lto not in VALID_LTO:
        errs.append(f"kernel.lto must be in {sorted(VALID_LTO)}: '{lto}'")

    clang = str(tc.get("clang", "")).strip()
    rust_build = bool(tc.get("rust", False))
    rustc = str(tc.get("rustc", "")).strip()
    bindgen = str(tc.get("bindgen", "")).strip()

    boot_stub = str(art.get("boot_stub", "")).strip()
    if not boot_stub or (boot_stub != "none" and ("/" in boot_stub or ".." in boot_stub or not boot_stub.endswith(".tzst"))):
        errs.append(f"artifacts.boot_stub must be a .tzst filename or 'none': '{boot_stub}'")

    kmi_base = str(art.get("kmi_baseline", "")).strip()
    if not kmi_base or (kmi_base != "none" and ("/" in kmi_base or ".." in kmi_base or not kmi_base.endswith(".kmi.json.gz"))):
        errs.append(f"artifacts.kmi_baseline must be a .kmi.json.gz filename or 'none': '{kmi_base}'")

    v_sched = str(feat.get("vendor_sched", "none")).strip().lower()
    if v_sched not in VALID_SCHED:
        errs.append(f"features.vendor_sched must be in {sorted(VALID_SCHED)}: '{v_sched}'")

    tcp_list = feat.get("tcp_congestion", [])
    nf_list = feat.get("netfilter", [])
    if not isinstance(tcp_list, list) or any(x not in VALID_TCP for x in tcp_list):
        errs.append(f"features.tcp_congestion invalid: {tcp_list}")
    if not isinstance(nf_list, list) or any(x not in VALID_NF for x in nf_list):
        errs.append(f"features.netfilter invalid: {nf_list}")

    raw_block = mods.get("blocklist", [])
    if not isinstance(raw_block, list):
        errs.append("modules.blocklist must be a list")
        raw_block = []

    prot = protected if protected is not None else load_protected_modules(root)
    blocklist = []
    seen_m = set()
    for m in raw_block:
        ms = str(m).strip()
        if not ms or ms in seen_m:
            continue
        if ms in prot:
            errs.append(f"modules.blocklist contains protected module '{ms}'")
        seen_m.add(ms)
        blocklist.append(ms)

    zip_model = re.sub(r"-[0-9]+\.[0-9]+\.[0-9]+$", "", model)
    if variant and variant.lower() not in (model.lower(), zip_model.lower(), os_ver.lower(), "default"):
        artifact_tag = f"{zip_model}_{variant}"
    else:
        artifact_tag = zip_model

    env_map = {
        "CFG_MODEL": model,
        "CFG_VENDOR": vendor,
        "CFG_SOC": soc,
        "CFG_PLATFORM": platform,
        "CFG_OS_VERSION": os_ver,
        "CFG_VARIANT": variant,
        "CFG_TARGET_DIR": target_dir,
        "CFG_MANIFEST": manifest,
        "CFG_ANDROID_VERSION": av,
        "CFG_KERNEL_VERSION": kv,
        "CFG_KERNEL_LOCALVERSION": localver,
        "CFG_BUILD_TIMESTAMP": build_ts,
        "CFG_OPTIMIZE_LEVEL": opt_level,
        "CFG_LTO": lto,
        "CFG_C_COMPILER": clang,
        "CFG_RUST_BUILD": "true" if rust_build else "false",
        "CFG_RUST_COMPILER": rustc,
        "CFG_BINDGEN": bindgen,
        "CFG_BOOT_STUB": boot_stub,
        "CFG_KMI_BASELINE": kmi_base,
        "CFG_HMBIRD": "true" if v_sched == "hmbird" else "false",
        "CFG_OPT": "true" if bool(feat.get("optimizations", False)) else "false",
        "CFG_CONTAINERS": "true" if bool(feat.get("containers", False)) else "false",
        "CFG_USB_GADGET": "true" if bool(feat.get("usb_gadget", False)) else "false",
        "CFG_BBG": "true" if bool(feat.get("baseband_guard", False)) else "false",
        "CFG_NTSYNC": "true" if bool(feat.get("ntsync", False)) else "false",
        "CFG_UNICODE": "true" if bool(feat.get("unicode_fix", False)) else "false",
        "CFG_WAKELOCK_BLOCKER": "true" if bool(feat.get("wakelock_blocker", False)) else "false",
        "CFG_REKERNEL": "true" if bool(feat.get("rekernel", False)) else "false",
        "CFG_USB_SDP_900MA": "true" if bool(feat.get("usb_sdp_900ma", False)) else "false",
        "CFG_BBR": "true" if "bbr" in tcp_list else "false",
        "CFG_BBR3": "true" if "bbr3" in tcp_list else "false",
        "CFG_TTL": "true" if "ttl" in nf_list else "false",
        "CFG_IP_SET": "true" if "ipset" in nf_list else "false",
        "CFG_BLACKLIST_MODULES": ",".join(blocklist),
        "ARTIFACT_TAG": artifact_tag,
    }

    return {
        "profile": rel,
        "target_dir": target_dir,
        "id": model,
        "vendor": vendor,
        "soc": soc,
        "platform": platform,
        "os": os_ver,
        "variant": variant,
        "gki": gki,
        "android_version": av,
        "kernel_version": kv,
        "manifest": manifest,
        "boot_stub": boot_stub,
        "kmi_baseline": kmi_base,
        "artifact_tag": artifact_tag,
        "prune_disk": bool(run_cfg.get("prune_disk", False)),
        "env": env_map,
        "errors": errs,
    }


def load_all_profiles(root):
    prot = load_protected_modules(root)
    paths = sorted(glob.glob(os.path.join(root, "targets/**/profiles/*.toml"), recursive=True))
    return [parse_profile(root, p, prot) for p in paths if os.path.isfile(p)]


def classify_atom(atom):
    low = atom.lower()
    if re.match(r"^a[0-9*]+$", low):
        return "os"
    if re.match(r"^(android[0-9*]+-)?[0-9]+\.[0-9*]+(\.[0-9*]+)?$", low) or low.startswith("android"):
        return "kernel"
    return "device"


def match_atom(item, atom):
    low = atom.lower()
    axis = classify_atom(low)
    if axis == "os":
        return fnmatch.fnmatchcase(item["os"].lower(), low)
    if axis == "kernel":
        return any(fnmatch.fnmatchcase(v.lower(), low) for v in (item["gki"], item["kernel_version"], item["android_version"]))
    return any(
        fnmatch.fnmatchcase(v.lower(), low)
        for v in (item["id"], item["variant"], item["soc"], item["platform"], item["target_dir"], item["profile"])
    )


def cmd_plan(root):
    print("::group::Matrix Resolution")
    in_os = os.environ.get("INPUT_OS", "ALL").strip() or "ALL"
    in_kernel = os.environ.get("INPUT_KERNEL", "ALL").strip() or "ALL"
    in_device = os.environ.get("INPUT_DEVICE", "ALL").strip() or "ALL"
    in_filter = os.environ.get("INPUT_FILTER", "").strip()

    profiles = load_all_profiles(root)
    bad = [p for p in profiles if p["errors"]]
    if bad:
        for p in bad:
            for e in p["errors"]:
                print(f"::error::{p['profile']}: {e}", file=sys.stderr)
        sys.exit(1)

    raw_groups = [g.strip() for g in re.split(r"[,;\s]+", in_filter) if g.strip()]
    pos_groups, neg_groups, overridden = [], [], set()

    for grp in raw_groups:
        is_neg = grp[0] in ("!", "-")
        clean = grp[1:].strip() if is_neg else grp
        atoms = [a.strip() for a in re.split(r"[+/]+", clean) if a.strip()]
        if not atoms:
            continue
        if is_neg:
            neg_groups.append(atoms)
        else:
            pos_groups.append(atoms)
            for a in atoms:
                overridden.add(classify_atom(a))

    eff_os = "ALL" if "os" in overridden else in_os
    eff_kernel = "ALL" if "kernel" in overridden else in_kernel
    eff_device = "ALL" if "device" in overridden else in_device

    for ax, orig, eff in [("os_version", in_os, eff_os), ("kernel_version", in_kernel, eff_kernel), ("device", in_device, eff_device)]:
        if orig != "ALL" and eff == "ALL":
            print(f"[INFO] custom_filter overrides dropdown '{ax}' ({orig} -> manual filter)")

    selected = []
    for p in profiles:
        if eff_os != "ALL" and not match_atom(p, eff_os):
            continue
        if eff_kernel != "ALL" and not match_atom(p, eff_kernel):
            continue
        if eff_device != "ALL" and not match_atom(p, eff_device):
            continue
        if pos_groups and not any(all(match_atom(p, a) for a in grp) for grp in pos_groups):
            continue
        if any(all(match_atom(p, a) for a in grp) for grp in neg_groups):
            continue
        selected.append(p)

    if not selected:
        print(f"::error::No targets matched (os={in_os}, kernel={in_kernel}, device={in_device}, filter='{in_filter}')")
        sys.exit(1)

    selected.sort(
        key=lambda c: (
            -(int(re.sub(r"[^0-9]", "", c["os"]) or "0")),
            c["id"],
            c["variant"],
        )
    )

    matrix_items = []
    print(f"[OK] Selected {len(selected)} target(s):")
    for c in selected:
        print(f"  - {c['id']} [{c['variant']}] ({c['os']}, {c['gki']}) -> {c['profile']}")
        matrix_items.append({
            "profile": c["profile"],
            "id": c["id"],
            "variant": c["variant"],
            "os": c["os"],
            "gki": c["gki"],
            "prune_disk": c["prune_disk"],
        })

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as f:
            f.write(f"matrix={json.dumps({'include': matrix_items}, separators=(',', ':'))}\n")

    gh_sum = os.environ.get("GITHUB_STEP_SUMMARY")
    if gh_sum:
        with open(gh_sum, "a", encoding="utf-8") as f:
            f.write("### Curio Kernel Build Plan\n\n")
            f.write("| Filter | Value |\n|---|---|\n")
            f.write(f"| OS | `{in_os}`{' (overridden)' if eff_os != in_os else ''} |\n")
            f.write(f"| Kernel | `{in_kernel}`{' (overridden)' if eff_kernel != in_kernel else ''} |\n")
            f.write(f"| Device | `{in_device}`{' (overridden)' if eff_device != in_device else ''} |\n")
            f.write(f"| Custom | `{in_filter or 'none'}` |\n")
            f.write(f"| Matched | `{len(selected)}` (`{', '.join(c['id'] + ':' + c['variant'] for c in selected)}`) |\n")
    print("::endgroup::")


def cmd_export_env(root, profile_arg):
    print("::group::Parse and Validate Target Profile")
    if not profile_arg:
        print("::error::Target profile path is empty", file=sys.stderr)
        sys.exit(1)
    p = parse_profile(root, profile_arg)
    if p["errors"]:
        for e in p["errors"]:
            print(f"::error::{p['profile']}: {e}", file=sys.stderr)
        sys.exit(1)

    gh_env = os.environ.get("GITHUB_ENV")
    for k, v in p["env"].items():
        if gh_env:
            with open(gh_env, "a", encoding="utf-8") as f:
                f.write(f"{k}={v}\n")
        print(f"  {k}={v}")

    print(f"[OK] Validated profile {p['profile']}")
    print("::endgroup::")


def main():
    root = os.environ.get("GITHUB_WORKSPACE") or os.getcwd()
    sub = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if sub == "plan":
        cmd_plan(root)
    elif sub == "export-env":
        cmd_export_env(root, sys.argv[2] if len(sys.argv) > 2 else "")
    elif sub == "validate-all":
        profs = load_all_profiles(root)
        errs = [f"{p['profile']}: {e}" for p in profs for e in p["errors"]]
        if errs or not profs:
            for e in errs:
                print(f"[ERROR] {e}", file=sys.stderr)
            sys.exit(1)
        print(f"[OK] Validated {len(profs)} profile(s)")
    else:
        raise SystemExit(f"Unknown subcommand: {sub}")


if __name__ == "__main__":
    main()
