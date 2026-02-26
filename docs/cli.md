# CLI Reference

The `binget` command-line interface provides various subcommands to install binaries and manage project environments.

## Global Options

These options can be used with the root `binget` command:

- `-h, --help`: Show the global help message and exit.
- `-v, --version`: Show version and exit.

## Commands

### `install`
Installs packages from remote repositories, registries, or according to a local configuration file. 
**Usage:**
```bash
binget install                             # Installs binaries defined in local .binget.yaml
binget install --config <path>             # Installs binaries from specified config file
binget install <id>[@version]              # Installs package from default binget registry
binget install github.com/<owner>/<repo>[@version] # Installs package explicitly from GitHub
```

**Options:**
- `--global`: Install the package globally so it is available across all projects instead of locally.
- `--user`: Install the package for the current user in `~/.local/share/binget/bin` (this is the default when installing a specific target).
- `--shim`: Install into the shim directory `~/.local/share/binget/env/<package>/<version>` (this is the default when installing from a `.binget` config).
- `--config <path>`: Specify a path to a `.binget` or `.binget.yaml` file to use for resolving dependencies.

### `upk`
Installs a package from a local metadata YAML file.
**Usage:** `binget upk <meta.yaml> [--global]`
- `<meta.yaml>`: Path to the local metadata file describing the package properties.
- `--global`: Install the package globally.

### `uninstall`
Uninstalls a previously installed package.
**Usage:** `binget uninstall <name>`
- `<name>`: The name of the package to uninstall.

### `upgrade`
Upgrades an installed package to its latest available version.
**Usage:** `binget upgrade <name> [--global]`
- `<name>`: The name of the installed package.
- `--global`: Specify if the package was installed globally.

### `env`
Evaluates the `.binget` / `.binget.yaml` file in the current directory tree and prints the resulting environment variables.
**Usage:** `binget env`

### `shell-activate`
Outputs the shell script code required to activate the local project environment for your specific shell.
**Usage:** `binget shell-activate <bash|zsh|fish|pwsh>`

### `exec`
Executes a command within the context of the environment variables defined in the local `.binget` / `.binget.yaml` file.
**Usage:** `binget exec <command> [<args>...]`
- `<command>`: The command to execute.

### `init`
Initializes a new empty `binget` package configuration in the current directory.
**Usage:** `binget init`

### `pack`
Packs a local package into an archive, preparing it for distribution.
**Usage:** `binget pack`

### `trust`
Explicitly trusts the current directory. This is required for security reasons before `binget` will evaluate dynamic environment variables and execute nested shell scripts defined in the local `.binget` / `.binget.yaml` configuration.
**Usage:** `binget trust`

### `shell-hook`
Outputs the shell hook code necessary to add the `binget` managed bin directory to your system's `$PATH`.
**Usage:** `binget shell-hook`
