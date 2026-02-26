# binget

A fast, lightweight, and cross-platform native package manager for downloading, extracting, and executing binary distributions and language runtimes. Built from the ground up in Zig.

## What is binget?

`binget` solves the frustration of installing portable binaries, command-line tools, and language runtimes across multiple operating systems. Instead of juggling `apt`, `brew`, `winget`, `choco`, `npm`, and `cargo` to get your toolchain set up, `binget` natively downloads and shims them into an isolated environment without polluting your system PATH.

## Features

- **Fast & Native**: Written in Zig, resulting in a single fast, native executable with no dependencies.
- **Cross-Platform**: Works identically on Windows, macOS, and Linux (x86_64 and arm64).
- **Native Archive Extraction**: Zero reliance on external shell tools. Extracts `.tar.gz`, `.zip`, `.tar.xz`, and `.tar.bz2` directly.
- **Declarative Post-Install Hooks**: Automatically manages OS-specific shortcuts (Start Menu / Desktop / Application folders), sets Windows Registry Keys, and maps symlinks/hardlinks safely.
- **Smart Shims**: Executables are smartly proxied (using symlinks on POSIX and the lightweight Scoop shim engine on Windows) to keep your environment completely isolated.
- **Source Compilation**: Built-in support to fetch source tarballs and seamlessly compile them from source using engines like `zig build`.
- **System Package Manager Proxy**: Seamlessly proxies to `apt`, `brew`, `winget`, or `choco` when a native package is required.

## Installation

### Linux & macOS

```bash
curl -fsSL https://raw.githubusercontent.com/frostyeti/binget/main/eng/scripts/install.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/frostyeti/binget/main/eng/scripts/install.ps1 | iex
```

*Ensure the installed bin directory is added to your PATH.*

## Usage

### Commands

- `binget install <package>`: Install a package from the central registry
  - `--user`: Install globally for the current user
  - `--shim`: Install locally into an isolated environment
- `binget uninstall <package>`: Remove an installed package
- `binget upgrade <package>`: Upgrade an installed package
- `binget env`: Print your current binget environment configurations
- `binget exec <command>`: Execute a command within the binget environment context
- `binget shell-hook`: Print the shell hook script to inject binget paths into your current terminal
- `binget version`: Print version information

### Examples

**Install an application system-wide for the user:**
```bash
binget install zed --user
```

**Install an application into an isolated local shim environment:**
```bash
binget install node --shim
```

## How It Works

1. `binget` resolves your query against the [binget-pkgs](https://github.com/frostyeti/binget-pkgs) JSON registry.
2. It identifies the optimal asset for your architecture (OS, CPU).
3. It downloads, extracts, and caches the archive into its local `.local/share/binget` or `AppData\Local\binget` vault.
4. It creates localized execution shims inside the designated `bin` directory.

## Development

Requires **Zig 0.15.2 (Master)** or newer. We recommend using `mise` to automatically provision the required Zig compiler.

```bash
# Build the project
mise run build

# Run unit tests
zig build test

# Run full cross-platform compile
zig build cross

# Run End-to-End local tests
./eng/scripts/test_post_install_e2e.sh
```

## License

MIT

