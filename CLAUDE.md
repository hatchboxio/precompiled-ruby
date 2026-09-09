# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository builds portable Linux Ruby binaries that can be installed and run from anywhere on the filesystem. The build source of truth is the checked-in YAML under `recipes/`; Homebrew is not used by local packaging or CI release workflows.

## Development Commands

Validate the recipe files:

```bash
bin/validate-recipes
```

Build a Ruby version locally:

```bash
bin/package 3.4.9 --target x86_64_linux --no-yjit --output rubies
```

Linux targets must be built inside their manylinux2014 container; `bin/package-linux` does that from any Docker host, including macOS.

Builds need a baseruby of Ruby 3.0.0 or newer; set `JDX_RUBY_BASERUBY` when the shell default is older. Ruby 3.2.x builds require `JDX_RUBY_BASERUBY` to point to an existing Ruby executable with the same version.

YJIT builds require `rustup` or `rustc` in `PATH`. Set `JDX_RUBY_RUSTUP_HOME` to isolate rustup state when desired.

## Architecture

### Recipe Files

- `recipes/rubies.yml`: Ruby source URL, SHA256, series, and prerelease version metadata.
- `recipes/dependencies.yml`: portable dependency source URL and SHA256 metadata.
- `recipes/series.yml`: per-series behavior such as libedit, bundled gems, and baseruby requirements.
- `recipes/targets.yml`: release targets, artifact platform names, and pinned manylinux2014 containers.

### Commands

- `bin/package`: Builds portable dependencies, builds Ruby, runs runtime/linkage/ABI checks, and writes release tarballs.
- `bin/validate-recipes`: Validates YAML shape, required fields, duplicate versions, URL/SHA256 formats, and target matrix completeness.
- `bin/update-ruby-recipe`: Adds or updates a Ruby entry in `recipes/rubies.yml`; used by autobump.
- `bin/package-linux`: Runs `bin/package` for a Linux target inside its pinned manylinux2014 container, mirroring the build workflow, for local Linux builds.
- `bin/recipe-info`: Prints a version's effective series settings (`legacy`, `yjit`, ...) for workflows.

### Old series

`recipes/series.yml` carries per-series switches (`openssl`, `baseruby`, `load_relative`, `readline_ext`, `cflags`, `patches`, `bundler`, `test`, ...) with defaults that reproduce the current Rubies' build. Ruby 1.8.7 through 3.1 override them; the comments in that file explain each. New knobs belong there and in `package.rb`, never in ad hoc version checks.

### Key Build Details

- Linux builds use pinned manylinux2014/glibc 2.17 containers for both YJIT and no-YJIT artifacts.
- `pkgconf` is built as a bootstrap tool so the build has no host package-manager dependency.
- OpenSSL, libyaml, libffi, libxcrypt, zlib, ncurses, and libedit are source-built into an isolated prefix as needed.
- Bundled `msgpack` and `bootsnap` gems are staged during the Ruby build.
- SSL certificates are bundled in `libexec/cert.pem`.
- Native gem compilation headers, static libs, and pkg-config files are copied into the portable Ruby prefix.
- Shell polyglot executables and `rbconfig.rb` are patched for relocatable native gem builds.

### Output Naming

Release tarballs keep the existing names:

- `ruby-VERSION.x86_64_linux.tar.gz`
- `ruby-VERSION.x86_64_linux.no_yjit.tar.gz`
- `ruby-VERSION.arm64_linux.tar.gz`
- `ruby-VERSION.arm64_linux.no_yjit.tar.gz`
