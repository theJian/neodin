# Neodin

A work-in-progress, cross-platform Neovim GUI written mainly in Odin.
Requires **Neovim 0.12+** and loads your usual Neovim configuration.

## Build and run on macOS

Requires Odin `dev-2026-10` or newer, Python 3.12+, CMake, and a C compiler.

```sh
brew install odin neovim cmake sdl3 sdl3_ttf utf8proc libuv
python3 build.py build --release
./build/neodin path/to/file
```

## Configuration

Use [config.example.json](config.example.json) as a starting point:

```sh
./build/neodin --config config.json
./build/neodin --renderer metal -- --clean
./build/neodin --server 127.0.0.1:6666
```

Default config: `$XDG_CONFIG_HOME/neodin/config.json` or
`~/.config/neodin/config.json`.
`NEODIN_CONFIG` can override the path. Editor settings belong in `init.lua`.

## Development

```sh
python3 build.py check
python3 build.py test
./build/neodin --smoke-test
```
