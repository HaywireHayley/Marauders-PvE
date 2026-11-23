"""Every PR merged since a release, and whether CHANGELOG.md mentions it (issue #199).

    python scripts/changelog_prs.py [<since-tag>] [--repo owner/name] [--all]

<since-tag> defaults to the newest public-test-* release on GitHub. Lists each PR merged into master after that
release was published: number, author, title, and MISSING when neither its number nor an issue it closes ("(#N)" in
its title, "Fixes #N" in its body) is anywhere in CHANGELOG.md as "#N". PRs that are the notes themselves (titles
starting "Changelog") are left out. --all also lists the covered ones. Exits 1 when any is missing, so a release step
can stop on it.

Needs the GitHub CLI (gh), signed in. Write the notes from this list, not from memory: a bullet names its PR(s), and
work by anyone but the maintainer says "thanks <user>".
"""
import json
import os
import re
import subprocess
import sys

REPO = "HaywireHayley/Marauders-PvE"
MAINTAINERS = {"HaywireHayley", "dmchaledev"}  # everyone else is thanked by name
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def gh(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        sys.exit("gh " + " ".join(args) + ": " + (out.stderr.strip() or "failed"))
    return out.stdout


def latest_tag(repo):
    rows = json.loads(gh("release", "list", "-R", repo, "--limit", "30", "--json", "tagName,publishedAt"))
    rows = [r for r in rows if r["tagName"].startswith("public-test-") and r.get("publishedAt")]
    if not rows:
        sys.exit("no public-test-* release found")
    return max(rows, key=lambda r: r["publishedAt"])["tagName"]


def published(repo, tag):
    return json.loads(gh("release", "view", tag, "-R", repo, "--json", "publishedAt"))["publishedAt"]


def merged_since(repo, when):
    rows = json.loads(gh("pr", "list", "-R", repo, "--state", "merged", "--base", "master", "--limit", "200",
                         "--search", f"merged:>{when}", "--json", "number,title,body,author,mergedAt"))
    rows = [r for r in rows if not r["title"].lower().startswith("changelog")]
    return sorted(rows, key=lambda r: r["mergedAt"])


def mentioned(text):
    return {int(n) for n in re.findall(r"#(\d+)\b", text)}


def closes(pr):
    """The PR's own number and the issues it names: "(#N)" in the title, "Fixes/Closes/Resolves #N" in the body."""
    nums = {pr["number"]} | {int(n) for n in re.findall(r"\(#(\d+)\)", pr["title"])}
    nums |= {int(n) for n in re.findall(r"(?i)\b(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?)\s+#(\d+)", pr.get("body") or "")}
    return nums


def main(argv):
    repo, show_all, tag = REPO, "--all" in argv, None
    rest = [a for a in argv if a != "--all"]
    if "--repo" in rest:
        i = rest.index("--repo")
        repo = rest[i + 1]
        del rest[i:i + 2]
    if rest:
        tag = rest[0]
    tag = tag or latest_tag(repo)
    when = published(repo, tag)
    with open(os.path.join(HERE, "CHANGELOG.md"), encoding="utf-8") as f:
        seen = mentioned(f.read())
    prs = merged_since(repo, when)
    missing = 0
    print(f"PRs merged since {tag} ({when}): {len(prs)}")
    for pr in prs:
        login = (pr.get("author") or {}).get("login", "?")
        refs = closes(pr)
        gap = not (refs & seen)
        missing += gap
        if gap or show_all:
            thanks = "" if login in MAINTAINERS else f"  (thanks {login})"
            others = sorted(refs - {pr["number"]})
            also = f"  [closes {', '.join('#%d' % n for n in others)}]" if others else ""
            print(f"  {'MISSING ' if gap else 'ok      '}#{pr['number']:<5} {pr['title']}{also}{thanks}")
    print(f"{missing} not in CHANGELOG.md" if missing else "All are in CHANGELOG.md.")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
