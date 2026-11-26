#!/usr/bin/env python3
import glob
import tomllib
import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET


def run(cmd, cwd=None, check=True):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=check)


def ls_remote_heads(url):
    res = run(["git", "ls-remote", "--heads", url], check=False)
    if res.returncode != 0:
        return {}
    heads = {}
    for line in res.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2 and parts[1].startswith("refs/heads/"):
            heads[parts[1][len("refs/heads/"):]] = parts[0]
    return heads


def ls_remote_head_sha(url):
    res = run(["git", "ls-remote", url, "HEAD"], check=False)
    if res.returncode != 0 or not res.stdout.strip():
        return ""
    return res.stdout.strip().split()[0]


def fetch_github_makefile_version(owner_repo, ref):
    url = f"https://raw.githubusercontent.com/{owner_repo}/{ref}/Makefile"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "curio-kernel-monitor"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            head = resp.read(2048).decode("utf-8", errors="replace")
        ver = re.search(r"^VERSION\s*=\s*(\d+)", head, re.M)
        pl = re.search(r"^PATCHLEVEL\s*=\s*(\d+)", head, re.M)
        sl = re.search(r"^SUBLEVEL\s*=\s*(\d+)", head, re.M)
        if ver and pl and sl:
            return f"{ver.group(1)}.{pl.group(1)}.{sl.group(1)}"
    except Exception:
        pass
    return "unknown"


def fetch_github_commit_date(owner_repo, ref):
    res = run(["gh", "api", f"repos/{owner_repo}/commits/{ref}", "--jq", ".commit.committer.date"], check=False)
    if res.returncode == 0 and res.stdout.strip():
        return res.stdout.strip()[:10]
    return "unknown"


def parse_version_tuple(text):
    m = re.search(r"(?:^|[_\-/])(\d+)\.(\d+)(?:\.(\d+))?(?:[_\-/]|$)", text)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or "0"))


def check_kernel_targets(root):
    kernel_rows = []
    manifest_rows = []
    alerts = []
    seen_manifest_queries = set()

    for cp in sorted(glob.glob(os.path.join(root, "targets/**/profiles/*.toml"), recursive=True)):
        norm = os.path.relpath(cp, root).replace("\\", "/")
        target_dir = os.path.dirname(os.path.dirname(norm))
        with open(cp, "rb") as tf:
            raw_toml = tomllib.load(tf)
        dev = raw_toml.get("device") or {}
        src = raw_toml.get("source") or {}

        model = str(dev.get("id", ""))
        os_ver = str(dev.get("os", ""))
        os_major = int(re.sub(r"[^0-9]", "", os_ver) or "0")
        manifest_name = str(src.get("manifest", ""))
        platform_cfg = str(dev.get("platform", ""))
        platform = platform_cfg.split("/")[-1]
        device_stem = os.path.splitext(os.path.basename(manifest_name))[0]

        manifest_path = os.path.join(root, target_dir, "manifests", manifest_name)
        if not os.path.isfile(manifest_path):
            continue

        mroot = ET.parse(manifest_path).getroot()
        remotes = {r.get("name"): r.get("fetch", "").rstrip("/") for r in mroot.findall("remote")}
        def_el = mroot.find("default")
        def_rem = def_el.get("remote") if def_el is not None else None
        def_rev = def_el.get("revision") if def_el is not None else None

        for proj in mroot.findall("project"):
            p_path = proj.get("path", proj.get("name", ""))
            if not (p_path == "common" or p_path.endswith("/common")):
                continue
            rem_name = proj.get("remote", def_rem)
            proj_name = proj.get("name", "")
            rev = proj.get("revision", def_rev) or ""
            base_url = remotes.get(rem_name, "")
            if not base_url:
                continue

            repo_url = f"{base_url}/{proj_name}.git"
            heads = ls_remote_heads(repo_url)
            head_sha = heads.get(rev, "")
            gh_match = re.match(r"^https://github\.com/([^/]+)/([^/]+)$", f"{base_url}/{proj_name}")
            gh_org = gh_match.group(1) if gh_match else ""
            gh_repo = f"{gh_org}/{gh_match.group(2)}" if gh_match else ""

            kver = fetch_github_makefile_version(gh_repo, head_sha or rev) if gh_repo else "n/a"
            cdate = fetch_github_commit_date(gh_repo, head_sha or rev) if gh_repo else "n/a"

            newer_branches = []
            cur_ver = parse_version_tuple(rev) or (os_major, 0, 0)
            for bname in sorted(heads):
                if device_stem and device_stem.lower() not in bname.lower():
                    continue
                if bname == rev:
                    continue
                bver = parse_version_tuple(bname)
                if bver and bver > cur_ver:
                    newer_branches.append(bname)

            if newer_branches:
                alerts.append(f"New kernel branch(es) for `{model}` ({os_ver}): " + ", ".join(f"`{b}`" for b in newer_branches))

            kernel_rows.append((
                f"{model} ({os_ver})",
                gh_repo or proj_name,
                rev,
                head_sha[:12] if head_sha else "unmatched",
                kver,
                cdate,
                ", ".join(newer_branches) if newer_branches else "none",
            ))

            brand_prefix = rev.split("/", 1)[0] if "/" in rev else (platform_cfg.split("/", 1)[0] if "/" in platform_cfg else "")
            if gh_org and brand_prefix and platform:
                km_branch = f"{brand_prefix}/{platform}"
                qkey = (gh_org, km_branch, device_stem)
                if qkey not in seen_manifest_queries:
                    seen_manifest_queries.add(qkey)
                    res = run(
                        ["gh", "api", f"repos/{gh_org}/kernel_manifest/contents?ref={km_branch}", "--jq", ".[].name"],
                        check=False,
                    )
                    if res.returncode == 0:
                        xml_files = sorted(l.strip() for l in res.stdout.splitlines() if l.strip().endswith(".xml"))
                        matched_xmls = [x for x in xml_files if device_stem and device_stem.lower() in x.lower()]
                        higher_xmls = []
                        for xf in matched_xmls:
                            vm = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", xf)
                            if vm and int(vm.group(1)) > os_major:
                                higher_xmls.append(xf)
                        if higher_xmls:
                            alerts.append(f"New XML manifest(s) in `{gh_org}/kernel_manifest` ({km_branch}): " + ", ".join(f"`{x}`" for x in higher_xmls))
                        manifest_rows.append((
                            f"{gh_org}/kernel_manifest",
                            km_branch,
                            ", ".join(matched_xmls) if matched_xmls else f"{len(xml_files)} XMLs",
                            ", ".join(higher_xmls) if higher_xmls else "none",
                        ))

    return kernel_rows, manifest_rows, alerts


def check_pinned_deps(root):
    conf_path = os.path.join(root, ".github/actions/kernel-pipeline/config/defaults.conf")
    txt = open(conf_path, "r", encoding="utf-8").read()
    kv = {m.group(1): m.group(2) for m in re.finditer(r'^([A-Z0-9_]+)="([^"]*)"', txt, re.M)}

    dep_rows = []
    alerts = []
    deps = [
        ("Baseband-guard", "BBG_REPO_URL", "BBG_REPO_REF"),
        ("AnyKernel3", "AK3_REPO_URL", "AK3_REPO_REF"),
        ("gki-verifier", "GKI_VERIFIER_REPO_URL", "GKI_VERIFIER_REPO_REF"),
    ]
    for label, url_k, ref_k in deps:
        url = kv.get(url_k, "")
        pinned = kv.get(ref_k, "")
        if not url or not pinned:
            continue
        live = ls_remote_head_sha(url)
        if not live:
            status = "UNREACHABLE"
        elif live == pinned:
            status = "UP_TO_DATE"
        else:
            status = "UPDATE_AVAILABLE"
            alerts.append(f"`{label}` has upstream commits: `{pinned[:12]}` -> `{live[:12]}`")
        dep_rows.append((label, pinned[:12], live[:12] if live else "error", status))

    return dep_rows, alerts


def check_ci_tools(root):
    tool_rows = []
    alerts = []

    setup_txt = open(os.path.join(root, ".github/actions/runner-setup/setup.sh"), "r", encoding="utf-8").read()
    m_cc = re.search(r"ccache/releases/download/(v[0-9.]+)/", setup_txt)
    if m_cc:
        pinned_cc = m_cc.group(1)
        r = run(["gh", "release", "view", "--repo", "ccache/ccache", "--json", "tagName", "-q", ".tagName"], check=False)
        latest_cc = r.stdout.strip() if r.returncode == 0 else "error"
        st = "UP_TO_DATE" if latest_cc == pinned_cc else ("UPDATE_AVAILABLE" if latest_cc != "error" else "UNREACHABLE")
        if st == "UPDATE_AVAILABLE":
            alerts.append(f"`ccache` release update: `{pinned_cc}` -> `{latest_cc}`")
        tool_rows.append(("ccache", pinned_cc, latest_cc, st))

    lint_path = os.path.join(root, ".github/workflows/lint.yml")
    if os.path.isfile(lint_path):
        lint_txt = open(lint_path, "r", encoding="utf-8").read()
        m_al = re.search(r"actionlint/releases/download/(v[0-9.]+)/", lint_txt)
        if m_al:
            pinned_al = m_al.group(1)
            r = run(["gh", "release", "view", "--repo", "rhysd/actionlint", "--json", "tagName", "-q", ".tagName"], check=False)
            latest_al = r.stdout.strip() if r.returncode == 0 else "error"
            st = "UP_TO_DATE" if latest_al == pinned_al else ("UPDATE_AVAILABLE" if latest_al != "error" else "UNREACHABLE")
            if st == "UPDATE_AVAILABLE":
                alerts.append(f"`actionlint` release update: `{pinned_al}` -> `{latest_al}`")
            tool_rows.append(("actionlint", pinned_al, latest_al, st))

    return tool_rows, alerts


def render_markdown(kernel_rows, manifest_rows, dep_rows, tool_rows, alerts):
    lines = ["### Curio Kernel Upstream Monitor", ""]
    if alerts:
        lines.append("#### Actionable Updates Detected")
        lines.append("")
        for a in alerts:
            lines.append(f"- {a}")
        lines.append("")
    else:
        lines.append("Status: no new OS branches, manifests, or dependency updates detected.")
        lines.append("")

    lines.append("#### Tracked Kernel Sources")
    lines.append("")
    lines.append("| Target | Repository | Tracked Branch | HEAD | Makefile Version | Commit Date | Newer Branches |")
    lines.append("|---|---|---|---|---|---|---|")
    for r in kernel_rows:
        lines.append(f"| `{r[0]}` | `{r[1]}` | `{r[2]}` | `{r[3]}` | `{r[4]}` | `{r[5]}` | `{r[6]}` |")

    if manifest_rows:
        lines.append("")
        lines.append("#### OEM Manifest Repositories")
        lines.append("")
        lines.append("| Repository | Branch | Matching XMLs | Newer OS XMLs |")
        lines.append("|---|---|---|---|")
        for r in manifest_rows:
            lines.append(f"| `{r[0]}` | `{r[1]}` | `{r[2]}` | `{r[3]}` |")

    lines.append("")
    lines.append("#### Pinned Dependencies & CI Tools")
    lines.append("")
    lines.append("| Component | Pinned | Upstream | Status |")
    lines.append("|---|---|---|---|")
    for r in dep_rows + tool_rows:
        lines.append(f"| `{r[0]}` | `{r[1]}` | `{r[2]}` | `{r[3]}` |")

    return "\n".join(lines) + "\n"


def sync_issue(repo, md_body, alerts):
    if not repo or not alerts:
        return
    digest = hashlib.sha256("\n".join(sorted(alerts)).encode("utf-8")).hexdigest()[:12]
    marker = f"<!-- curio-upstream-digest: {digest} -->"
    full_body = md_body + "\n" + marker + "\n"

    run(["gh", "label", "create", "upstream-update", "--repo", repo, "--color", "0e8a16", "--description", "Automated upstream tracking", "--force"], check=False)

    res = run(
        ["gh", "issue", "list", "--repo", repo, "--label", "upstream-update", "--state", "open", "--json", "number,body"],
        check=False,
    )
    existing = json.loads(res.stdout or "[]") if res.returncode == 0 else []

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", delete=False) as tf:
        tf.write(full_body)
        body_path = tf.name

    try:
        if existing:
            issue = existing[0]
            num = str(issue["number"])
            if marker in (issue.get("body") or ""):
                print(f"[INFO] Open issue #{num} already reflects digest {digest}; skipping update.")
                return
            run(["gh", "issue", "edit", num, "--repo", repo, "--body-file", body_path])
            print(f"[OK] Updated existing upstream-update issue #{num} (digest {digest}).")
        else:
            run([
                "gh", "issue", "create", "--repo", repo,
                "--title", "Upstream updates detected for Curio Kernel",
                "--label", "upstream-update",
                "--body-file", body_path,
            ])
            print(f"[OK] Created upstream-update issue (digest {digest}).")
    finally:
        if os.path.exists(body_path):
            os.remove(body_path)


def main():
    root = os.getcwd()
    repo = os.environ.get("TARGET_REPO", "").strip()
    if os.environ.get("EVENT_NAME") == "workflow_dispatch":
        create_issue = os.environ.get("INPUT_CREATE_ISSUE", "true").lower() == "true"
    else:
        create_issue = True

    kernel_rows, manifest_rows, k_alerts = check_kernel_targets(root)
    dep_rows, d_alerts = check_pinned_deps(root)
    tool_rows, t_alerts = check_ci_tools(root)
    alerts = k_alerts + d_alerts + t_alerts

    md = render_markdown(kernel_rows, manifest_rows, dep_rows, tool_rows, alerts)
    print(md)

    gh_sum = os.environ.get("GITHUB_STEP_SUMMARY")
    if gh_sum:
        with open(gh_sum, "a", encoding="utf-8") as f:
            f.write(md)

    if create_issue and alerts:
        sync_issue(repo, md, alerts)
    elif alerts:
        print(f"[INFO] {len(alerts)} update(s) detected; issue creation disabled (create_issue=false).")
    else:
        print("[OK] Everything is up to date.")


if __name__ == "__main__":
    main()
