# GitHub Repositories Integration

`binget` leverages GitHub as its primary decentralized registry for binary distributions, meaning you do not need a central package index to install most open-source command line tools.

## The Installation Process

When you run an install command pointing to a GitHub repo:

```bash
binget install <owner>/<repo>
```

*(For example: `binget install BurntSushi/ripgrep`)*

Here is exactly how `binget` processes the request behind the scenes:

### 1. API Lookup
`binget` connects to the GitHub REST API (`https://api.github.com/repos/<owner>/<repo>/releases/latest`) to discover the most recently published release for the target repository.

### 2. Intelligent Asset Heuristics
The fetched release metadata contains a list of `assets`—these are the compiled binaries or compressed archives uploaded by the software author.
Since authors use varying naming conventions, `binget` evaluates all assets using an intelligent scoring system to find the correct artifact for your specific machine. It inspects the `name` of each asset and looks for optimal matches against:
- **Operating System:** (`linux`, `macos`, `darwin`, `windows`, `win`).
- **CPU Architecture:** (`x86_64`, `amd64`, `aarch64`, `arm64`, etc.).
- **File Format:** Prioritizes specific packaging structures like `.tar.gz`, `.zip`, `.tar.xz`, and `.deb` (on Linux).

The asset that accumulates the highest relevance score is ultimately selected.

### 3. Download & Extraction
The selected asset is securely downloaded into a `.tmp` directory located inside your system's `binget` share folder. If the asset is a compressed archive (like `tar.gz` or `zip`), `binget` handles extracting the files automatically.

### 4. Binary Discovery
Once unzipped, `binget` recursively scans the extracted directory to locate the core executable file. 
- It first looks for an exact filename match corresponding to the `<repo>` name (e.g., `ripgrep` or `ripgrep.exe`).
- If an exact match is missing, it falls back to a generalized heuristic, looking for the largest executable file that has no file extension (on Unix systems) or one that ends in `.exe` (on Windows).

### 5. Linking & Database Tracking
The discovered binary is moved into `binget`'s isolated, versioned package directory (`packages/<repo>/<version>/`) and verified as executable (`chmod +x`). 
A symlink is then automatically created in your `binget` bin directory—making it instantly available in your terminal if you have properly configured `binget shell-hook`. 

Finally, the installation details are recorded in the local SQLite `binget.db` database so that the package can be tracked, upgraded, or cleanly uninstalled in the future.
