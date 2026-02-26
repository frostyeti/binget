# binget TODOs & Roadmap

This document outlines upcoming features, advanced installation strategies, and the next batch of runtimes and dev/devops tools to add to the `binget-pkgs` registry.

## Next 50 Runtimes & Dev/DevOps Tools to Add
Inspired by top scoop, choco, and brew packages.

### Runtimes & Languages
1. **java** (OpenJDK distributions like Temurin or Corretto)
2. **dotnet** (.NET SDK & Runtime)
3. **ocaml** (via opam or direct binaries)
4. **odin** (Odin programming language)
5. **ruby** (Ruby runtime)
6. **elixir** (Elixir language)
7. **erlang** (Erlang/OTP)
8. **haskell** (via GHCup)
9. **php** (PHP CLI)
10. **lua** (Lua runtime)

### Shells, Terminal & Prompt
11. **nushell** (A new type of shell)
12. **zoxide** (A smarter cd command)
13. **starship** (Cross-shell prompt)
14. **oh-my-posh** (Prompt theme engine)
15. **tmux** (Terminal multiplexer)
16. **psmux** (Terminal multiplexer alternative)
17. **zellij** (Terminal workspace with batteries included)
18. **alacritty** (GPU-accelerated terminal emulator)
19. **wezterm** (GPU-accelerated cross-platform terminal)
20. **yazi** (Blazing fast terminal file manager)
21. **nnn** (Tiny, lightning fast, feature-packed file manager)
22. **superfile** (Very fancy terminal file manager)
23. **fzf** (Command-line fuzzy finder)
24. **ripgrep** (rg - fast search tool)

### DevOps, Cloud & Containers
25. **rancher-desktop** (Kubernetes and container management)
26. **docker** (Docker CLI client)
27. **lazydocker** (Simple terminal UI for both docker and docker-compose)
28. **kubectl** (Kubernetes command-line tool)
29. **k9s** (Kubernetes CLI UI)
30. **helm** (Kubernetes package manager)
31. **minikube** (Local Kubernetes)
32. **terraform** (Infrastructure as code)
33. **awscli** (AWS command-line interface)
34. **azure-cli** (Azure command-line interface)
35. **gcloud** (Google Cloud CLI)
36. **pulumi** (Infrastructure as code in any language)
37. **vagrant** (Development environment manager)
38. **ansible** (IT automation)
39. **packer** (Machine image builder)
40. **kustomize** (Kubernetes native configuration management)

### General CLI Utilities
41. **zip** (Compression utility)
42. **unzip** (Extraction utility)
43. **7zip** (High-compression file archiver)
44. **bat** (A cat clone with wings)
45. **jq** (Command-line JSON processor)
46. **yq** (Command-line YAML/XML/JSON processor)
47. **eza** (A modern, maintained replacement for ls)
48. **git** (Version control)
49. **gh** (GitHub CLI)
50. **lazygit** (Simple terminal UI for git commands)
51. **btop** (Resource monitor that shows usage and stats)
52. **bottom** (Cross-platform graphical process/system monitor)
53. **pingme** (CLI to send messages/alerts to various messaging platforms)
54. **gping** (Ping, but with a graph)
55. **opencode** (Interactive CLI agent specializing in software engineering)
56. **codex** (AI-assisted CLI dev tool / code generation)
57. **bruno** (Fast and Git-friendly open-source API client)

### Editors & Database Tools
58. **neovim** (Vim-fork focused on extensibility and usability)
59. **helix** (Post-modern modal text editor)
60. **sqlite3** (SQLite command-line interface)
61. **psql** (PostgreSQL command-line client)
62. **redis-cli** (Redis command-line interface)
63. **lazysql** (Cross-platform TUI database management tool)

---

## Advanced Windows Installer Handling

Currently `binget` focuses on user-level archive extractions and shims. To support the broader Windows ecosystem, we need to handle "crappy" or traditional installers.

### 1. "Heavy" System Installers (Visual Studio & SSMS)
Some tools are impossible to run as portable user-level apps (e.g., they need deep registry hooks, drivers, or system-level services).
* **Visual Studio Build Tools / Community**: Requires running `vs_setup.exe` with heavy arguments.
* **SQL Server Management Studio (SSMS)**: Distributed as an enormous `.exe`.
* **Solution**: Add a new `"type": "installer"` install mode.
  * **UAC Elevation**: `binget` will need to spawn the process requesting Administrator privileges if not already elevated.
  * **Silent Args**: Manifests must provide `silent_args` (e.g., `["--quiet", "--wait", "--norestart"]` for VS, `/Quiet` for SSMS).

### 2. MSI Extraction (Treating MSI as an Archive)
Many tools are distributed *only* as `.msi` files, but the files inside are perfectly portable. Instead of "installing" the MSI and polluting the Windows Registry / Add/Remove Programs, `binget` should extract the payload.
* **Solution**: Add support for `.msi` in the `"archive"` install mode.
  * Under the hood, `binget` can run: `msiexec /a "target.msi" /qb TARGETDIR="C:\path\to\binget\store\app\version"`
  * This bypasses the actual installation sequence and just dumps the packaged files, allowing us to shim them normally without requiring UAC/Admin rights.

### 3. Squirrel Installers (Discord, Slack, Postman, etc.)
Squirrel installers (often named `Setup.exe`) are actually archives. They usually contain an `Update.exe` and a `app-X.X.X-full.nupkg`.
* **Solution**: 
  * A `.nupkg` is just a ZIP file containing the app payload inside a `lib/net45/` (or similar) directory.
  * If we detect a Squirrel setup or a `.nupkg`, we can treat it as an archive, unzip it, locate the main executable inside the `lib/` directory, and shim it.
  * This prevents the app from auto-updating itself outside of `binget`'s control and avoids putting files in `AppData\Local\<App>`.

---

## Linux Advanced Packaging

### 1. AppImage Integration
AppImages are standalone files that include the app and its dependencies.
* **Solution**: Enable a `"type": "appimage"` or extend `"file"` install mode.
  * The file simply needs to be marked executable (`chmod +x`).
  * **Bonus**: `binget` could optionally run `./app.AppImage --appimage-extract *.desktop` to extract icons and `.desktop` files for integration into the user's application menu (e.g., `~/.local/share/applications/`).

### 2. Flatpak Integration
Many GUI Linux apps are now distributed primarily via Flatpak.
* **Solution**: Add a `"type": "flatpak"` mode.
  * Manifests define the application ID (e.g., `org.mozilla.firefox`) and the remote (usually `flathub`).
  * `binget` executes: `flatpak install --user --noninteractive flathub <app_id>`.
  * `binget` can track these via its own SQLite DB for unified uninstalls/updates while letting Flatpak handle the heavy lifting of containerization.
