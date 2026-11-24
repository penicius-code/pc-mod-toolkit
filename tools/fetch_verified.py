"""Download GitHub release assets and verify each against the sha256 digest the GitHub API lists.

Usage: python -I fetch_verified.py <out_dir> <owner/repo>@<tag>@<asset name> [...]
Files that fail the check are renamed to *.BAD and reported; nothing is extracted or run.
"""
import hashlib
import json
import os
import sys
import urllib.request

UA = {"User-Agent": "local-check", "Accept": "application/vnd.github+json"}


def api(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return json.load(r)


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    bad = 0
    for spec in sys.argv[2:]:
        repo, tag, name = spec.split("@", 2)
        rel = api(f"https://api.github.com/repos/{repo}/releases/tags/{tag}")
        asset = next((a for a in rel["assets"] if a["name"] == name), None)
        if not asset:
            print(f"MISSING  {spec}")
            bad += 1
            continue
        want = (asset.get("digest") or "").replace("sha256:", "").lower()
        dst = os.path.join(out, name)
        h = hashlib.sha256()
        req = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "local-check"})
        with urllib.request.urlopen(req, timeout=120) as r, open(dst + ".part", "wb") as f:
            while True:
                b = r.read(1 << 20)
                if not b:
                    break
                h.update(b)
                f.write(b)
        got = h.hexdigest()
        if want and got == want:
            os.replace(dst + ".part", dst)
            print(f"OK       {name}  {asset['size']}  sha256 {got}")
        else:
            os.replace(dst + ".part", dst + ".BAD")
            print(f"BAD      {name}  got {got} want {want or '(no digest listed)'}")
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
