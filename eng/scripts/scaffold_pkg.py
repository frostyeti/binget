# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import os
import json
import urllib.request
import re
import sys
import argparse

GITHUB_REPO_API_URL = "https://api.github.com/repos/{owner}/{repo}"
GITHUB_LATEST_API_URL = "https://api.github.com/repos/{owner}/{repo}/releases/latest"


def get_github_repo_metadata(owner, repo, headers):
    url = GITHUB_REPO_API_URL.format(owner=owner, repo=repo)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            meta = {}
            meta["description"] = data.get("description", "")
            meta["project_url"] = data.get("homepage") or data.get("html_url", "")
            meta["repo_url"] = data.get("html_url", "")

            license_data = data.get("license")
            if license_data:
                spdx = license_data.get("spdx_id")
                if spdx and spdx != "NOASSERTION":
                    meta["license"] = spdx
                else:
                    meta["license"] = license_data.get("name", "")

                if spdx == "NOASSERTION" and license_data.get("url"):
                    meta["license_url"] = license_data.get("url")

            owner_data = data.get("owner", {})
            if owner_data.get("login"):
                meta["authors"] = [owner_data.get("login")]
            if owner_data.get("avatar_url"):
                meta["icon_url"] = owner_data.get("avatar_url")

            return meta
    except Exception as e:
        print(f"Failed to fetch metadata for {owner}/{repo}: {e}")
        return None


def match_platform(asset_name):
    name = asset_name.lower()

    # Exclude non-archives
    if not (
        name.endswith(".zip") or name.endswith(".tar.gz") or name.endswith(".tar.xz")
    ):
        return None

    os_str = None
    if "linux" in name or "ubuntu" in name:
        os_str = "linux"
    elif "darwin" in name or "mac" in name or "apple" in name:
        os_str = "darwin"
    elif "windows" in name or "win" in name or "pc-windows" in name:
        os_str = "windows"

    arch_str = None
    if "amd64" in name or "x86_64" in name or "x64" in name:
        arch_str = "amd64"
    elif "arm64" in name or "aarch64" in name:
        arch_str = "arm64"

    # special fallbacks for mac
    if os_str == "darwin" and arch_str is None:
        arch_str = "amd64"  # assume universal or x64 if missing

    if os_str and arch_str:
        # Avoid things like musl if gnu is available (simplification)
        if "musl" in name and "gnu" not in name and os_str == "linux":
            # still linux, but maybe deprioritize? We'll just return it
            pass
        return f"{os_str}.{arch_str}"

    return None


def get_latest_github_release(owner, repo, headers):
    url = GITHUB_LATEST_API_URL.format(owner=owner, repo=repo)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            tag = data.get("tag_name", "")

            assets = data.get("assets", [])
            asset_map = {}
            for asset in assets:
                p = match_platform(asset["name"])
                if p:
                    # Prefer gnu over musl for linux
                    if p in asset_map and "musl" in asset["name"].lower():
                        continue
                    asset_map[p] = asset["browser_download_url"]

            ver_match = re.search(r"(\d+\.\d+.*)", tag)
            if ver_match:
                return ver_match.group(1), tag, asset_map
            return tag, tag, asset_map
    except Exception as e:
        print(f"Failed to fetch latest release for {owner}/{repo}: {e}")
        return None, None, {}


def main():
    parser = argparse.ArgumentParser(
        description="Scaffold a new binget package from GitHub"
    )
    parser.add_argument("pkg_id", help="The package ID (e.g. bun, jq)")
    parser.add_argument("github_repo", help="The GitHub repository (e.g. oven-sh/bun)")
    parser.add_argument(
        "--dir", default=".", help="Base directory of binget-pkgs repository"
    )
    args = parser.parse_args()

    owner, repo = args.github_repo.split("/")

    token = os.environ.get("GITHUB_TOKEN", "")
    headers = {
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "binget-scaffolder",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    print(f"Fetching metadata for {owner}/{repo}...")
    meta = get_github_repo_metadata(owner, repo, headers)
    if not meta:
        print("Could not fetch metadata. Exiting.")
        sys.exit(1)

    print(f"Fetching latest release for {owner}/{repo}...")
    version, tag, assets = get_latest_github_release(owner, repo, headers)
    if not version:
        print("Could not fetch latest release. Using '0.0.0'.")
        version = "0.0.0"
        tag = "v0.0.0"
        assets = {}

    first_char = args.pkg_id[0].lower()
    pkg_dir = os.path.join(args.dir, first_char, args.pkg_id)
    ver_dir = os.path.join(pkg_dir, version)

    os.makedirs(ver_dir, exist_ok=True)

    versions_file = os.path.join(pkg_dir, "versions.json")
    if not os.path.exists(versions_file):
        with open(versions_file, "w") as f:
            json.dump(
                {
                    "latest": version,
                    "versions": [{"version": version, "status": "active"}],
                },
                f,
                indent=2,
            )
            f.write("\n")

    # Root manifest for metadata
    manifest_file = os.path.join(ver_dir, "manifest.json")
    manifest_data = {
        "name": args.pkg_id,
        "version": version,
    }
    manifest_data.update(meta)

    with open(manifest_file, "w") as f:
        json.dump(manifest_data, f, indent=2)
        f.write("\n")

    # Generate platform manifests
    for platform, dl_url in assets.items():
        plat_manifest_file = os.path.join(ver_dir, f"manifest.{platform}.json")
        plat_data = {
            "name": args.pkg_id,
            "version": version,
            "install_modes": {"archive": {"url": dl_url, "bin": [args.pkg_id]}},
        }
        with open(plat_manifest_file, "w") as f:
            json.dump(plat_data, f, indent=2)
            f.write("\n")

    print(f"Successfully scaffolded {args.pkg_id} at {ver_dir}")
    print(f"Created {len(assets)} platform manifests based on github releases.")


if __name__ == "__main__":
    main()
