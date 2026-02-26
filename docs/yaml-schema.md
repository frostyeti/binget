# YAML Schema (`.binget.yaml`)

The local project configuration file (often named `.binget` or `.binget.yaml`) is used to define project-level binary dependencies, specify `.env` files to be loaded, and declare dynamic inline environment variables.

## Top-Level Sections

The configuration file is divided into three primary sections: `bin:`, `dotenv:`, and `env:`.

### `bin:` (Dependencies)
Specifies binary tools that the project depends on. These can be mapped directly to remote sources like GitHub.

```yaml
bin:
    github.com/org/repo@v1:
        template: v{version}/{repo}_{platform}_{arch}.tar.gz 
        bin:
             - "first_bin"
             - "second_bin" 
    ripgrep@vwhatever
```

### `dotenv:` (Environment Files)
Specifies file paths to standard `.env` files that should be parsed, loaded, and injected into the current environment.

```yaml
dotenv:
     - ./relative/path/.env
     - ./relative/path/.env.user?  # The `?` suffix makes the file optional. No error is thrown if missing.
```

### `env:` (Dynamic Environment Variables)
Defines inline environment variables. This section supports robust string interpolation, dynamic default values, shell command execution, and referencing previously loaded variables.

```yaml
env:
     MY_VAR="test"
     NEXT_VAR="${MY_VAR}"           # Interpolates variable defined above
     DEFAULTED="${DEF:-whatever}"   # Uses a default value if `DEF` is unset
     SECRET="$(kpv ensure --name 'name' --size 32)" # Executes a shell command and assigns its standard output
     MULTILINE="first
next
    "                               # Supports multi-line string assignments
     SINGLE=''                      # Empty single quotes
     BACKTICK=``                    # Empty backticks
```

> **Security Notice:** Because the `env:` section has the power to execute shell commands directly via `$(...)` subshells, `binget` blocks evaluation by default. The directory containing this file must be explicitly approved by running `binget trust` before variables will be parsed and loaded.
