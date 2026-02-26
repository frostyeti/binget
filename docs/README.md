# Binget Architecture & Overview

`binget` is a lightweight, cross-platform binary package manager that simplifies installing, managing, and executing standalone binaries from various sources (like GitHub Releases or custom registries), while also managing local project environment variables.

## Core Concepts & How It Works

1. **Installation Modes (Global vs User vs Shim)**: 
   - `binget` supports three different installation tiers:
     - **User Mode (`--user`)**: The default behavior for explicit tool installs. Binaries are installed to the user's primary bin directory (e.g., `~/.local/share/binget/bin`) replacing previous versions.
     - **Global Mode (`--global`)**: Installs to system-wide paths or the main global user scope, so all projects can access it without a local override.
     - **Shim Mode (`--shim`)**: Used when running `binget install` from a local project `.binget.yaml`. It installs the binary exactly to `~/.local/share/binget/env/<package>/<version>`, ensuring strict version isolation. Project shims or `binget shell-activate` put this exact version into your PATH for the project.

2. **Registry & GitHub Releases Integration**:
   - `binget` supports declarative manifests from a default registry (using the `id@version` syntax). It pulls a manifest describing exactly how to download, extract, and shim complex apps based on the OS/Architecture.
   - For simpler tools, `binget` natively understands GitHub repositories. Using `binget install github.com/<owner>/<repo>@version`, it connects directly to the GitHub API.
   - It utilizes a smart heuristics engine to locate the appropriate release asset (e.g., a `.tar.gz` or `.zip` file) based on the user's Operating System and CPU architecture, extracts it, finds the binary, and symlinks it automatically.

3. **Project Environment Management (`.binget` / `.binget.yaml`)**:
   - In any directory, a configuration file can be used to define local binary dependencies, specify standard `.env` files to source, and construct dynamic inline environment variables.
   - When you run `binget install` in a directory with this file, all missing binaries are pulled into shim mode directories.
   - `binget shell-activate` activates the environment (updating PATH to include the required shims).
   - `binget exec <cmd>` executes a given command securely isolated within these loaded environment variables.

4. **Complex Runtimes**:
   - Outliers like standard runtimes (`ruby`, `python`, `uv`, `dotnet`) usually involve complex multi-binary extraction logic. Manifests handle special cases for these, ensuring `binget` can shim them successfully across environments while respecting global OS installations.

5. **Trust System for Security**:
   - Because the environment configuration allows executing arbitrary shell commands to build variables dynamically (e.g., `SECRET="$(vault get secret)"`), `binget` features a rigorous Trust system.
   - By default, executing environment-based commands in a directory is blocked. Users must explicitly whitelist the directory by running `binget trust` before `binget` will evaluate its configuration file and run any nested shell scripts.
