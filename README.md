# binget

A fast, native package manager for downloading and running binary distributions and language runtimes, built in Zig.

## Features

- **Fast Downloads**: Uses Zig's HTTP client to fetch binaries.
- **Archive Extraction**: Natively extracts `.tar.gz`, `.zip`, `.tar.xz` avoiding external shell dependencies.
- **Built-in Runtimes**: Out-of-the-box support for fetching the latest versions of common environments:
  - Node.js (`node`)
  - Rust (`rust`)
  - .NET (`dotnet`)
  - Deno (`deno`)
  - uv (`uv`)
  - Python (`python`)
  - Ruby (`ruby`)
- **Native Shims**: Creates efficient shims to proxy arguments into the executed binaries.
- **Registry Integration**: Installs software based on manifest files from the central `binget-pkgs` repository.

## Commands

- `binget install <package>`: Install a package
- `binget uninstall <package>`: Uninstall a package
- `binget upgrade <package>`: Upgrade an installed package
- `binget env`: Print the environment variables
- `binget exec <command>`: Execute a command within the binget environment
- `binget version`: Print version

## Development

Requires Zig 0.15.2 or newer.

```bash
# Build
zig build

# Run unit tests
zig build test

# Run End-to-End tests
./eng/e2e.sh
```
