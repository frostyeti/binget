# Complex Runtimes in Binget

Some applications, particularly language runtimes like `go`, `node`, and `dotnet`, cannot be installed as simple standalone binaries (`raw`) or purely moved flat binaries (`archive`). These runtimes expect a specific folder layout to function correctly, meaning standard library files, SDKs, or tools must sit in relative paths alongside the main executable (e.g. `../src` or `../lib` relative to the binary). 

To solve this, `binget` introduces the `runtime` install type in the registry manifest.

## How `runtime` works

When `binget` installs a package marked as `"type": "runtime"`, the installer executes the following sequence:

1. **Download and Extract**: The `.tar.gz` or `.zip` archive is downloaded and extracted, similar to the `archive` type.
2. **Relocate Full Directory**: Instead of plucking specific binaries out of the extraction directory, `binget` moves the **entire directory** intact into the global cache:
   `~/.local/share/binget/packages/<id>/<version>/`
3. **Generate Shims**: `binget` iterates over the `bin` array defined in the manifest. These strings define the relative paths to the executables within the runtime directory (e.g. `"bin/node"`, `"bin/npm"`).
   - For each executable, `binget` creates a shell script wrapper (or `.bat`/`.cmd` script on Windows) inside your installation `bin` directory (`~/.local/bin`, or `~/.local/share/binget/env/...` for shims).
   - This wrapper points directly to the absolute path of the relocated executable inside the package folder.

## Example Manifest (`node`)

```json
{
  "install_modes": {
    "user": {
      "type": "runtime",
      "format": "tar.xz",
      "url": "https://nodejs.org/dist/v20.11.1/node-v20.11.1-linux-x64.tar.xz",
      "extract_dir": "node-v20.11.1-linux-x64",
      "bin": [
        "bin/node",
        "bin/npm",
        "bin/npx"
      ]
    }
  }
}
```

When a user runs `binget install node`:
- The folder `node-v20.11.1-linux-x64` is placed in `~/.local/share/binget/packages/node/20.11.1/`.
- Executable wrappers named `node`, `npm`, and `npx` are generated in `~/.local/bin`.
- Running `node` from the terminal will launch the real executable, which correctly finds its `lib/node_modules/npm` dependencies via relative paths.

## Cross-Platform Considerations
- **Unix**: Shims are simple `#!/bin/sh` wrappers utilizing `exec "$@"`.
- **Windows**: Shims are `.bat` scripts mapping `%*` to pass all arguments cleanly.
