# Agents

## ✅ Always DO

- When you start a session read `mise.toml` or `build.zig` files to know which apps, runtimes and tools should be used.
- When writing Python scripts, ensure they are cross-platform (Linux, macOS, Windows) and use `uv` to run them. Add `uv` to `mise.toml`.
- Write tests for any code changes if they do not exist.
- Run tests before completing the task using `zig build test`.
- Fix any broken tests.
- Keep the project structure section up to date. Focus only on directories and key files such as `build.zig`, `build.zig.zon`, etc.
- If you write scripts that need to stay around, save them to `eng/scripts/`.
- If you write temporary scripts, save them to `eng/tmp/`.
- For CI/CD, store artifacts in the `.artifacts/` folder.
- Store product requirement documents in the `docs/prd/` folder.
- Use the `gh` cli to interact with github and github.com/frostyeti projects.
- Create separate files for integration tests if needed.
- Write E2E tests by compiling `binget` and using it to generate files, install packages, and clean up afterwards.
- When creating alpha releases, only bump the pre-release identifier (e.g., `v0.0.0-alpha.0` to `v0.0.0-alpha.1`). Do not bump the major, minor, or patch numbers.
- Always prefer Zig native libraries, standard library, and cross-compilation friendly C code over complex system dependencies.
- Keep `build.zig` and `build.zig.zon` clean and up to date.
- Use `zig fmt` to keep the code formatted and consistent.

## Project Structure

```text
.
├── build.zig             # Zig build script
├── build.zig.zon         # Zig dependencies
├── src/                  # Source code for binget
│   ├── main.zig          # CLI entrypoint
│   ├── core.zig          # Core execution logic
│   ├── install_cmd.zig   # Install command parser
│   ├── db.zig            # SQLite tracking database
│   ├── registry.zig      # Registry parsing logic
│   └── runtimes/         # Built-in runtime resolvers
├── eng/                  # Scripts and automation
├── docs/                 # Documentation
└── vendor/               # Vendor code (e.g. sqlite3 amalgamation)
```
