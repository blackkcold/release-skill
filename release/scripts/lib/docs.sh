#!/usr/bin/env bash
# docs.sh - CHANGELOG and version-file updates.

docs_update() { # docs_update <tag> <bare> <previous-tag>
    python3 - "$1" "$2" "$3" <<'PY'
import datetime
import json
import os
import re
import sys

tag, bare, prev = sys.argv[1:4]
data = json.loads(os.environ.get("RS_CONFIG_JSON") or "{}")
repo = data.get("repo") or ""
if not repo:
    try:
        import subprocess
        url = subprocess.check_output(["git", "remote", "get-url", "origin"], text=True).strip()
        match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
        if match:
            repo = match.group(1)
    except Exception:
        repo = ""

changed = []
date = datetime.date.today().isoformat()


def emit(path):
    changed.append(path)
    print("CHANGED=" + path)


# ---- CHANGELOG.md ----------------------------------------------------------
changelog = "CHANGELOG.md"
if os.path.exists(changelog):
    with open(changelog, encoding="utf-8") as fh:
        text = fh.read()
    has_version = re.search(r"^## \[" + re.escape(tag) + r"\]", text, re.M) is not None
    if not has_version:
        unreleased = re.search(r"^## \[Unreleased\][^\n]*\n", text, re.M)
        section = "## [%s] - %s\n" % (tag, date)
        if unreleased:
            text = text[:unreleased.start()] + "## [Unreleased]\n\n" + section + text[unreleased.end():]
        else:
            h1 = re.search(r"^# .*\n", text, re.M)
            insert_at = h1.end() if h1 else 0
            prefix = "\n" if insert_at else ""
            text = text[:insert_at] + prefix + section + ("\n" if not insert_at else "") + text[insert_at:]
        if repo:
            compare_base = prev if prev and prev != "v0.0.0" else tag
            text = re.sub(
                r"^\[Unreleased\]:.*$",
                "[Unreleased]: https://github.com/%s/compare/%s...HEAD" % (repo, tag),
                text,
                flags=re.M,
            )
            link = "[%s]: https://github.com/%s/compare/%s...%s" % (tag, repo, compare_base, tag)
            if link not in text:
                text = text.rstrip() + "\n" + link + "\n"
        with open(changelog, "w", encoding="utf-8") as fh:
            fh.write(text)
        emit(changelog)


# ---- version files ---------------------------------------------------------
def update_version_file(path, kind):
    if not os.path.exists(path):
        return
    if kind == "auto":
        name = os.path.basename(path)
        if name.lower() == "version":
            kind = "version"
        elif path.endswith(".json"):
            kind = "json"
        else:
            kind = "text"
            try:
                with open(path, encoding="utf-8") as fh:
                    head = fh.read(4)
                if head.startswith("---"):
                    kind = "frontmatter"
            except Exception:
                pass

    if kind == "version":
        with open(path, encoding="utf-8") as fh:
            old = fh.read().strip()
        if old != bare:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(bare + "\n")
            emit(path)
        return

    if kind == "json":
        try:
            with open(path, encoding="utf-8") as fh:
                obj = json.load(fh)
        except Exception:
            return
        if isinstance(obj, dict) and str(obj.get("version")) != bare:
            obj["version"] = bare
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(obj, fh, ensure_ascii=False, indent=2)
                fh.write("\n")
            emit(path)
        return

    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    if kind == "frontmatter":
        match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
        if not match:
            return
        block = match.group(1)
        lines = block.split("\n")
        in_metadata = False
        replaced = False
        for index, line in enumerate(lines):
            if re.match(r"^metadata:\s*$", line):
                in_metadata = True
                continue
            if in_metadata and re.match(r"^[^\s]", line):
                in_metadata = False
            if in_metadata and re.match(r"^\s+version:\s*", line):
                indent = re.match(r"^(\s*)", line).group(1)
                lines[index] = '%sversion: "%s"' % (indent, bare)
                replaced = True
                break
        if not replaced:
            lines.append("metadata:")
            lines.append('  version: "%s"' % bare)
        new_block = "\n".join(lines)
        new_text = "---\n" + new_block + "\n---\n" + text[match.end():]
        if new_text != text:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_text)
            emit(path)
        return

    if kind == "text":
        if prev and prev != tag and prev in text:
            new_text = text.replace(prev, tag)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_text)
            emit(path)
        return


for entry in data.get("version_files", []) or []:
    if isinstance(entry, str):
        path = entry
        kind = "auto"
        for suffix in ("version", "json", "frontmatter", "text"):
            if path.endswith(":" + suffix):
                path = path[: -(len(suffix) + 1)]
                kind = suffix
                break
    elif isinstance(entry, dict):
        path = entry.get("path", "")
        kind = entry.get("kind", "auto")
    else:
        continue
    if path:
        update_version_file(path, kind)

if not changed:
    print("CHANGED=")
PY
}
