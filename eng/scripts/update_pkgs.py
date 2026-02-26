# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import os
import json
import urllib.request
import re
import shutil
import subprocess

GITHUB_API_URL = "https://api.github.com/repos/{owner}/{repo}/releases/latest"
GITHUB_REPO_API_URL = "https://api.github.com/repos/{owner}/{repo}"


def run_cmd(cmd, cwd=None, env=None):
    print(f"Running: {' '.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, env=env, check=True)


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

                # Only use URL if it's not a common license, but GitHub's API usually provides a generic URL.
                # Actually, let's just provide the URL if available and it's not a standard SPDX we know?
                # We'll just include it if it's not a standard one, or maybe just include it if provided.
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


def get_latest_github_release(owner, repo, headers):
    url = GITHUB_API_URL.format(owner=owner, repo=repo)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            tag = data.get("tag_name", "")

            # Extract just the version number part (e.g. bun-v1.1.0 -> 1.1.0)
            ver_match = re.search(r"(\d+\.\d+.*)", tag)
            if ver_match:
                return ver_match.group(1), tag
            return tag, tag
    except Exception as e:
        print(f"Failed to fetch latest release for {owner}/{repo}: {e}")
        return None, None


def process_package(pkg_path, headers):
    versions_file = os.path.join(pkg_path, "versions.json")
    if not os.path.exists(versions_file):
        return

    with open(versions_file, "r") as f:
        try:
            versions_data = json.load(f)
        except json.JSONDecodeError:
            print(f"Invalid JSON in {versions_file}")
            return

    latest_ver = versions_data.get("latest")
    if not latest_ver:
        return

    latest_dir = os.path.join(pkg_path, latest_ver)
    if not os.path.exists(latest_dir):
        return

    owner = None
    repo = None
    for manifest_name in os.listdir(latest_dir):
        if not manifest_name.endswith(".json") and not manifest_name.endswith(".yaml"):
            continue
        manifest_path = os.path.join(latest_dir, manifest_name)
        with open(manifest_path, "r") as f:
            try:
                m_data = json.load(f)
            except json.JSONDecodeError:
                continue

        modes = m_data.get("install_modes", {})
        for mode, cfg in modes.items():
            url = cfg.get("url", "")
            match = re.search(r"github\.com/([^/]+)/([^/]+)/releases", url)
            if match:
                owner, repo = match.groups()
                break
        if owner and repo:
            break

    if not owner or not repo:
        print(f"Could not determine upstream GitHub repo for package in {pkg_path}")
        return

    # Check if we need to enrich the latest manifest
    main_manifest_path = os.path.join(latest_dir, "manifest.json")
    if os.path.exists(main_manifest_path):
        m_data_main = None
        with open(main_manifest_path, "r") as f:
            try:
                m_data_main = json.load(f)
                needs_enrichment = not all(
                    k in m_data_main for k in ["description", "project_url", "license"]
                )
            except json.JSONDecodeError:
                needs_enrichment = False

        if needs_enrichment and m_data_main is not None:
            print(f"Enriching metadata for {pkg_path} from {owner}/{repo}...")
            meta = get_github_repo_metadata(owner, repo, headers)
            if meta:
                for k, v in meta.items():
                    if k not in m_data_main and v:
                        m_data_main[k] = v

                with open(main_manifest_path, "w") as f:
                    json.dump(m_data_main, f, indent=2)
                    f.write("\n")

    print(f"Checking {owner}/{repo} for package {os.path.basename(pkg_path)}...")
    new_ver, raw_tag = get_latest_github_release(owner, repo, headers)
    if not new_ver or new_ver == latest_ver:
        return

    print(
        f"Found new version for {owner}/{repo}: {latest_ver} -> {new_ver} (tag: {raw_tag})"
    )

    new_dir = os.path.join(pkg_path, new_ver)
    if not os.path.exists(new_dir):
        os.makedirs(new_dir)

    for manifest_name in os.listdir(latest_dir):
        if os.path.isdir(os.path.join(latest_dir, manifest_name)):
            continue
        old_manifest = os.path.join(latest_dir, manifest_name)
        new_manifest = os.path.join(new_dir, manifest_name)

        with open(old_manifest, "r") as f:
            content = f.read()

        # If the version name is "stable", don't do a blind replace, just replace in URL
        if latest_ver == "stable":
            content = re.sub(
                r"/releases/download/[^/]+/", f"/releases/download/{raw_tag}/", content
            )
        else:
            # Replace the clean version string (e.g. 1.1.0 -> 1.3.10)
            content = content.replace(latest_ver, new_ver)

        with open(new_manifest, "w") as f:
            f.write(content)

    versions_data["latest"] = new_ver
    existing = [
        v for v in versions_data.get("versions", []) if v.get("version") == new_ver
    ]
    if not existing:
        versions_data["versions"].insert(0, {"version": new_ver, "status": "active"})

    with open(versions_file, "w") as f:
        json.dump(versions_data, f, indent=2)
        f.write("\n")

    print(f"Updated {pkg_path} to {new_ver}")


def main():
    token = os.environ.get("GITHUB_TOKEN", "")
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    repo_url = "https://github.com/frostyeti/binget-pkgs.git"
    clone_dir = os.path.join("eng", "tmp", "binget-pkgs-master")

    if token:
        push_url = (
            f"https://x-access-token:{token}@github.com/frostyeti/binget-pkgs.git"
        )
    else:
        push_url = repo_url

    if os.path.exists(clone_dir):
        print(f"Removing existing directory {clone_dir}")

        def on_rm_error(func, path, exc_info):
            import stat

            os.chmod(path, stat.S_IWRITE)
            func(path)

        shutil.rmtree(clone_dir, onerror=on_rm_error)

    run_cmd(["git", "clone", "--branch", "master", repo_url, clone_dir])

    # Now we process packages inside the clone_dir
    base_dir = clone_dir

    for first_char in os.listdir(base_dir):
        char_path = os.path.join(base_dir, first_char)
        if not os.path.isdir(char_path) or len(first_char) != 1:
            continue

        for pkg_name in os.listdir(char_path):
            pkg_path = os.path.join(char_path, pkg_name)
            if os.path.isdir(pkg_path):
                process_package(pkg_path, headers)

    # Check for changes
    status_result = subprocess.run(
        ["git", "status", "-s"], cwd=clone_dir, capture_output=True, text=True
    )
    if status_result.stdout.strip():
        print("Changes detected, committing to master...")
        run_cmd(["git", "config", "user.name", "github-actions[bot]"], cwd=clone_dir)
        run_cmd(
            [
                "git",
                "config",
                "user.email",
                "github-actions[bot]@users.noreply.github.com",
            ],
            cwd=clone_dir,
        )
        run_cmd(["git", "add", "."], cwd=clone_dir)
        run_cmd(
            ["git", "commit", "-m", "chore(registry): automated package updates"],
            cwd=clone_dir,
        )

        if os.environ.get("CI") == "true":
            print("Pushing to master...")
            run_cmd(["git", "push", push_url, "master"], cwd=clone_dir)
        else:
            print("Not in CI, skipping push.")
            run_cmd(["git", "log", "-1", "--stat"], cwd=clone_dir)
    else:
        print("No updates found. Registry is up to date.")

    print("Update process completed.")


if __name__ == "__main__":
    main()
