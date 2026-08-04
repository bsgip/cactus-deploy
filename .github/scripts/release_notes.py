#!/usr/bin/env python3
"""Build the cactus-deploy release body and the release-notes.json asset.

Usage: release_notes.py --previous release-176 --current release-177 \
           --previous-lock versions/previous --current-lock versions/current \
           --out-markdown versions/changes --out-json versions/release-notes.json
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass

import tomllib

GITHUB_API = "https://api.github.com"
DEPLOY_REPO = "bsgip/cactus-deploy"
TEST_DEFINITIONS = "cactus-test-definitions"
TEST_DEFINITIONS_REPO = f"bsgip/{TEST_DEFINITIONS}"


@dataclass
class Component:
    key: str
    name: str
    repo: str


ORCHESTRATOR = Component(
    "CACTUS_ORCHESTRATOR_VERSION", "Orchestrator", "bsgip/cactus-orchestrator"
)

COMPONENTS = [
    ORCHESTRATOR,
    Component("CACTUS_UI_VERSION", "Web UI", "bsgip/cactus-ui"),
    Component(
        "CACTUS_CLIENT_NOTIFICATIONS_VERSION",
        "Client Notifications",
        "bsgip/cactus-client-notifications",
    ),
    Component("V12_CACTUS_RUNNER_VERSION", "Test Runner (v1.2)", "bsgip/cactus-runner"),
    Component("V12_ENVOY_VERSION", "Utility Server (v1.2)", "bsgip/envoy"),
    Component(
        "V13_STORAGE_BETA_CACTUS_RUNNER_VERSION",
        "Test Runner (v1.3-storage-beta)",
        "synergy-au/cactus-runner",
    ),
    Component(
        "V13_STORAGE_BETA_ENVOY_VERSION",
        "Utility Server (v1.3-storage-beta)",
        "synergy-au/envoy",
    ),
    Component("V13_CACTUS_RUNNER_VERSION", "Test Runner (v1.3)", "bsgip/cactus-runner"),
    Component("V13_ENVOY_VERSION", "Utility Server (v1.3)", "bsgip/envoy"),
]

# GitHub's auto-generated release note format, which every component repo uses:
# "* Some change by @someone in https://github.com/org/repo/pull/123"
PR_BULLET = re.compile(
    r"^\s*[*-]\s+(?P<title>.+?)\s+by\s+@[\w-]+\s+in\s+(?P<url>\S*?/pull/(?P<pr>\d+))\s*$"
)
CLIENT_PROCEDURES = "cactus_test_definitions/client/procedures"
CLIENT_PROCEDURE_FILE = re.compile(rf"^{CLIENT_PROCEDURES}/[^/]+\.yaml$")

# The one degradation message. A section says this instead of quietly reporting less than it
# should, because a missing section is indistinguishable from nothing having changed.
UNREADABLE = "Some details could not be read from GitHub when these notes were generated."


def fetch(url: str, accept: str = "application/vnd.github+json") -> bytes | None:
    """GET url, or None on any failure. Never raises - callers degrade to a link-out."""
    req = urllib.request.Request(
        url, headers={"Accept": accept, "User-Agent": "cactus-deploy-release-notes"}
    )
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"  ! fetch failed {url}: {exc}", file=sys.stderr)
        return None


def api_json(path: str):
    raw = fetch(f"{GITHUB_API}{path}")
    try:
        return json.loads(raw) if raw is not None else None
    except json.JSONDecodeError:
        return None


def parse_changes(body: str | None) -> list[dict]:
    """Pull PR bullets out of an auto-generated release body."""
    changes = []
    for line in (body or "").splitlines():
        match = PR_BULLET.match(line)
        if match:
            changes.append(
                {
                    "title": match.group("title").strip(),
                    "pr": int(match.group("pr")),
                    "url": match.group("url"),
                }
            )
    return changes


def read_lock(path: str) -> dict[str, str]:
    versions = {}
    with open(path) as handle:
        for line in handle:
            key, _, value = line.strip().partition("=")
            if value and not key.startswith("#"):
                versions[key.strip()] = value.strip().strip('"')
    return versions


def build_components(
    previous: dict[str, str], current: dict[str, str]
) -> tuple[list[dict], list[str]]:
    """One entry per known component, in COMPONENTS order, with PR bullets for the ones that moved."""
    entries, warnings = [], []
    for component in COMPONENTS:
        old, new = previous.get(component.key), current.get(component.key)
        if new is None:
            if old is not None:
                warnings.append(f"`{component.name}` was removed from versions.lock.")
            continue
        entry = {
            "key": component.key,
            "name": component.name,
            "repo": component.repo,
            "previous": old,
            "current": new,
            "changed": old != new,
            "changes": [],
            "notes": [],
        }
        if entry["changed"]:
            release = api_json(f"/repos/{component.repo}/releases/tags/{new}")
            body = release.get("body") if isinstance(release, dict) else None
            if body:
                entry["changes"] = parse_changes(body)
            else:
                entry["notes"].append(f"No release notes published for `{new}`.")
        entries.append(entry)

    known = {component.key for component in COMPONENTS}
    warnings += [
        f"Unrecognised dependency `{key}` in versions.lock - not in these notes."
        for key in current.keys() - known
    ]
    return entries, warnings


def test_definitions_version(ref: str) -> str | None:
    """The cactus-test-definitions version locked in cactus-orchestrator at ref.

    None covers every way this can come up empty: unreachable ref, unparseable lockfile, or a
    git dependency, whose recorded version does not correspond to a published release.
    """
    raw = fetch(
        f"{GITHUB_API}/repos/{ORCHESTRATOR.repo}/contents/uv.lock?ref={ref}",
        "application/vnd.github.raw",
    )
    if raw is None:
        return None
    try:
        lock = tomllib.loads(raw.decode())
    except (tomllib.TOMLDecodeError, UnicodeDecodeError):
        return None
    for package in lock.get("package", []):
        if package.get("name") == TEST_DEFINITIONS:
            return None if "git" in package.get("source", {}) else package.get("version")
    return None


def version_sort_key(version: str) -> tuple:
    """Non-standard tags exist (v1.14.6.1), so sort on the numeric parts rather than assume semver."""
    return tuple(int(part) for part in re.findall(r"\d+", version))


def build_test_definitions(
    previous: dict[str, str], current: dict[str, str]
) -> dict | None:
    """The test procedure version transition for this release, or None if it did not move.

    Derived from cactus-orchestrator's uv.lock, which is the authority: the orchestrator pins
    cactus-test-definitions exactly, while the runners carry a range that resolves to whatever
    was current when their lockfile was last regenerated.
    """
    old_tag, new_tag = previous.get(ORCHESTRATOR.key), current.get(ORCHESTRATOR.key)
    if not old_tag or not new_tag or old_tag == new_tag:
        return None

    old, new = test_definitions_version(old_tag), test_definitions_version(new_tag)
    if old and new and old == new:
        return None

    entry = {
        "previous": old,
        "current": new,
        "procedures": None,
        "changes": [],
        "notes": [],
    }
    if not old or not new:
        entry["notes"].append(UNREADABLE)
        return entry

    entry["procedures"] = count_procedures(old, new)
    if not entry["procedures"]:
        entry["notes"].append(UNREADABLE)

    # An orchestrator bump can skip several test-definitions releases, so walk all of (old, new]
    # rather than just the endpoint.
    low, high = version_sort_key(old), version_sort_key(new)
    releases = api_json(f"/repos/{TEST_DEFINITIONS_REPO}/releases?per_page=100") or []
    in_range = sorted(
        (
            release
            for release in releases
            if isinstance(release, dict)
            and low < version_sort_key(release.get("tag_name", "")) <= high
        ),
        key=lambda release: version_sort_key(release.get("tag_name", "")),
    )
    for release in in_range:
        entry["changes"] += parse_changes(release.get("body"))
    return entry


def count_procedures(old: str, new: str) -> dict | None:
    """How many client test procedures were edited between two test-definitions versions.

    One YAML file per procedure id, so this is a path diff - no YAML is parsed and no procedure
    ids are listed. It exists to prompt someone to go and look, so it stays a handful of numbers
    however large the release is.
    """
    compare = api_json(f"/repos/{TEST_DEFINITIONS_REPO}/compare/v{old}...v{new}")
    if not isinstance(compare, dict) or "files" not in compare:
        return None
    counts = {"modified": 0, "added": 0, "removed": 0}
    for changed in compare["files"]:
        if CLIENT_PROCEDURE_FILE.match(changed.get("filename", "")):
            # Renames and copies count as modified, so no procedure file goes uncounted.
            status = changed.get("status")
            counts[status if status in counts else "modified"] += 1
    listing = api_json(
        f"/repos/{TEST_DEFINITIONS_REPO}/contents/{CLIENT_PROCEDURES}?ref=v{new}"
    )
    return counts | {"total": len(listing) if isinstance(listing, list) else None}


def compare_url(repo: str, old: str | None, new: str) -> str | None:
    return f"https://github.com/{repo}/compare/{old}...{new}" if old else None


def render_section(
    name: str, entry: dict, changelog: str | None, lead: str | None = None
) -> list[str]:
    """A `## Component` block: version transition, any degradation notes, then the PR bullets."""
    heading = " → ".join(
        f"`{version}`" for version in (entry["previous"], entry["current"]) if version
    )
    if changelog:
        heading += f" · [full changelog]({changelog})"
    lines = [f"## {name}"] + ([heading, ""] if heading else [])
    if lead:
        lines += [lead, ""]
    for note in entry["notes"]:
        lines += ["> [!NOTE]", f"> {note}", ""]
    if entry["changes"]:
        lines += [
            f"- {c['title']} ([#{c['pr']}]({c['url']}))" for c in entry["changes"]
        ] + [""]
    elif not entry["notes"]:
        lines += ["No pull requests listed for this release.", ""]
    return lines


def render_procedure_count(procedures: dict | None) -> str | None:
    """Deliberately says "modified", not "changed behaviour" - a formatting sweep counts too."""
    counts = [
        f"{procedures[status]} {status}"
        for status in ("modified", "added", "removed")
        if procedures and procedures[status]
    ]
    if not counts:
        return None
    total = f" ({procedures['total']} in total)" if procedures["total"] else ""
    return (
        f"**Client test procedures: {', '.join(counts)}**{total} - "
        "worth checking whether ones you rely on are affected."
    )


def render_markdown(data: dict) -> str:
    lines = [f"# CACTUS Deploy {data['tag']}"]
    deploy_compare = compare_url(DEPLOY_REPO, data["previous_tag"], data["tag"])
    if deploy_compare:
        lines.append(f"[Compare with {data['previous_tag']}]({deploy_compare})")
    lines.append("")

    changed = [c for c in data["components"] if c["changed"]]
    unchanged = [c for c in data["components"] if not c["changed"]]

    if changed:
        lines += ["| Component | Previous | Current |", "|---|---|---|"]
        for component in changed:
            previous = f"`{component['previous']}`" if component["previous"] else "—"
            lines.append(
                f"| **{component['name']}** | {previous} | **`{component['current']}`** |"
            )
    else:
        lines.append("No component versions changed in this release.")
    lines.append("")

    if unchanged:
        lines += [
            f"<details><summary>{len(unchanged)} component{'s' if len(unchanged) != 1 else ''} unchanged</summary>",
            "",
            "| Component | Version |",
            "|---|---|",
        ]
        lines += [f"| {c['name']} | `{c['current']}` |" for c in unchanged]
        lines += ["", "</details>", ""]

    for component in changed:
        changelog = compare_url(
            component["repo"], component["previous"], component["current"]
        )
        lines += render_section(component["name"], component, changelog)

    entry = data["test_definitions"]
    if entry:
        both = entry["previous"] and entry["current"]
        changelog = (
            compare_url(
                TEST_DEFINITIONS_REPO, f"v{entry['previous']}", f"v{entry['current']}"
            )
            if both
            else None
        )
        lines += render_section(
            "Test Procedures",
            entry,
            changelog,
            render_procedure_count(entry["procedures"]),
        )

    for warning in data["warnings"]:
        lines += ["> [!CAUTION]", f"> {warning}", ""]

    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--previous", required=True)
    parser.add_argument("--current", required=True)
    parser.add_argument("--previous-lock", required=True)
    parser.add_argument("--current-lock", required=True)
    parser.add_argument("--out-markdown", required=True)
    parser.add_argument("--out-json", required=True)
    args = parser.parse_args()

    previous, current = read_lock(args.previous_lock), read_lock(args.current_lock)
    components, warnings = build_components(previous, current)

    data = {
        "tag": args.current,
        "previous_tag": args.previous,
        "components": components,
        "test_definitions": build_test_definitions(previous, current),
        "warnings": warnings,
    }
    markdown = render_markdown(data)

    with open(args.out_markdown, "w") as handle:
        handle.write(markdown)
    with open(args.out_json, "w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    print(markdown)


if __name__ == "__main__":
    main()
