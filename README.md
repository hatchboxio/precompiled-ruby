# Portable Ruby Binaries

Tools to build Ruby tarballs for Linux that can be installed and run from anywhere on the
filesystem, from Ruby 1.8.7 to the current releases. [Hatchbox](https://hatchbox.io)
maintains them to install Ruby on its customers' servers without compiling it there.

Every tarball is self-contained: OpenSSL, libyaml, libffi, zlib and libxcrypt (and libedit
and ncurses where a series uses them) are linked in statically, so the only shared libraries
a build needs are glibc's. They are built against glibc 2.28 (AlmaLinux 8), which means any
Ubuntu LTS from 20.04 (Focal) on, Debian 10 on, RHEL 8 on, and other distributions of that
vintage or newer, on x86_64 and arm64. At run time they use the system's glibc; the build
glibc only limits which of its functions Ruby can use. 2.28 is as new as it can go while
still running on Ubuntu 20.04, and it gives Ruby 2.7 and later `File.birthtime` (through
`statx`) and `copy_file_range` for `IO.copy_stream`, which glibc 2.17 builds lacked.
Headers, static libraries and pkg-config files for the bundled dependencies ship in the
tarball, so native gems compile after it has been moved.

## How do I use these rubies

With [mise](https://mise.jdx.dev), point its precompiled Rubies at this repository and
install as usual:

```toml
# ~/.config/mise/config.toml
[settings]
ruby.precompiled_url = "hatchboxio/precompiled-ruby"
```

```sh
mise install ruby@3.4.11
```

Without mise, download the tarball for your platform from the
[releases page](https://github.com/hatchboxio/precompiled-ruby/releases) and extract it to
any location. Each tarball holds a single `ruby-VERSION/` directory:

```sh
curl -fsSLO https://github.com/hatchboxio/precompiled-ruby/releases/download/3.4.11/ruby-3.4.11.x86_64_linux.tar.gz
tar -xzf ruby-3.4.11.x86_64_linux.tar.gz
ruby-3.4.11/bin/ruby -v
```

For asdf, extract it as `~/.asdf/installs/ruby/VERSION` (without the `ruby-` prefix) and
run `asdf reshim ruby VERSION`.

Every version has two kinds of release. The one tagged with the plain version (`3.4.11`)
always serves the newest build and its download URLs never change, so link to that one.
Releases tagged with a build revision (`3.4.11-2`) are the individual builds; only the two
newest are kept.

Release artifacts are named:

- `ruby-VERSION.x86_64_linux.tar.gz`
- `ruby-VERSION.x86_64_linux.no_yjit.tar.gz`
- `ruby-VERSION.arm64_linux.tar.gz`
- `ruby-VERSION.arm64_linux.no_yjit.tar.gz`

Series without YJIT (everything up to 3.1) have a single build per target, released under
the plain name (`ruby-VERSION.x86_64_linux.tar.gz`), which is the name mise and asdf ask for.

### What's available

| Series | Versions | OpenSSL | YJIT |
| --- | --- | --- | --- |
| 3.2 and later | every release | 3.5 | yes (Ruby 3.2 needs `RUBY_YJIT_ENABLE=1` or `--yjit`; Rails turns it on itself from 3.3) |
| 3.1, 3.0, 2.7 | every release | 1.1.1w | no |
| 2.6, 2.5, 2.4 | last release only (2.6.10, 2.5.9, 2.4.10) | 1.1.1w | no |
| 2.3 to 1.8 | last release only (2.3.8, 2.2.10, 2.1.10, 2.0.0-p648, 1.9.3-p551, 1.8.7-p374) | 1.0.2u | no |

`recipes/rubies.yml` is the full list. New releases of supported series are added
automatically.

## Rails applications

Every series has been deployed as a fresh Rails application on Ubuntu 24.04, the way a
server deploy does it: the tarball extracted into place, gems installed in deployment mode
with their native extensions compiled from source, migrations over TLS to PostgreSQL, asset
precompilation, a runner script making an HTTPS request, and Puma serving a form.

| Ruby | Rails |
| --- | --- |
| 1.8.7 | 3.2 |
| 1.9.3, 2.0, 2.1 | 4.2 |
| 2.2, 2.3, 2.4 | 5.2 |
| 2.5, 2.6 | 6.1 |
| 2.7, 3.0 | 7.1 (7.0 on 2.7.0, whose parser rejects 7.1) |
| 3.1 | 7.2 |
| 3.2 | 8.0, with Solid Queue |
| 3.2, 3.3, 3.4, 4.0 | 8.1, also on Ubuntu 20.04, 22.04 and 26.04, Debian 12 and 13, with MySQL and MariaDB |

Old applications need the usual gem pins for their age (for example `loofah` 2.20 or older
with the Nokogiri that Ruby 2.4 and earlier are limited to, and PostgreSQL 11 or older for
Rails 4.2 and earlier); none of that is particular to these builds.

## Native gems

Gems with C extensions compile against an installed tarball as they would against a Ruby
built on the machine, given a compiler and the distribution's development packages for
whatever the gem itself links to (`libpq-dev` for pg, and so on). A few things are arranged
so that the result doesn't depend on how or where the Ruby was built:

- The headers, static libraries and pkg-config files of the bundled dependencies are in the
  tarball's `include/` and `lib/`, ahead of the system's on the compiler's search path. A
  gem that uses OpenSSL (puma, eventmachine) therefore links the bundled one statically,
  matching Ruby's own `openssl` extension, and doesn't export it either.
- `rbconfig` is rewritten at load time for wherever the tarball now lives: compiler and
  linker names are the generic `cc` and `c++`, flags that named the build tree are removed,
  and the `--with-*-dir` options recorded at build time point at the tarball.
- Ruby is linked statically, and its internal functions are not linkable from
  `libruby-static.a`. An extension's `have_func` check then finds exactly the functions the
  `ruby` executable exports; without this a gem can compile against an internal function
  and fail to load (`undefined symbol: rb_deprecate_constant` from strscan on Ruby 2.4 to
  2.7).
- The bundled ncurses (behind readline, where a series uses libedit) reads the system's
  terminfo from `/etc/terminfo`, `/lib/terminfo` and `/usr/share/terminfo`.

## End-of-life Rubies

Ruby 1.8.7 through 3.1 are in the recipes as well, so that applications which haven't
been upgraded yet keep deploying on current distributions, where these Rubies no longer
compile against the system's OpenSSL 3 or with its compiler. Ruby itself gets no security
fixes in these series, and neither do OpenSSL 1.0.2 and 1.1.1; treat them as a way to keep
an application running while it is upgraded.

They build the same relocatable way, with a few differences that `recipes/series.yml`
spells out per series: OpenSSL 1.0.2 or 1.1.1 where the openssl extension predates
OpenSSL 3, readline through a bundled libedit, the host Ruby hidden from configures that
would otherwise use it as baseruby, no bundled msgpack/bootsnap, and a version-appropriate
native gem as the installation test. All of them are built and released for both
`x86_64_linux` and `arm64_linux`.

Things to know when running them:

- Ruby 1.8 predates `--enable-load-relative`, so its `bin/ruby` is a shell wrapper that
  supplies the load path. Symlink the directory, not `bin/ruby` itself.
- Ruby 1.8 has no RubyGems of its own; 1.8.23 is installed into it. Bundler 1.17.3 is
  preinstalled up to 2.7, together with 2.3.27 (Ruby 2.4 and 2.5) or 2.4.22 (2.6 and 2.7).
- Ruby 1.8's `net/http` verifies against no certificate store unless given one; set
  `ca_file` when using `VERIFY_PEER`.
- RubyGems older than 3.3.6 writes the absolute path of `ruby` into the executables of the
  gems it installs, so reinstall gems (or fix their first lines) after moving one of these
  Rubies. The tarball's own executables are relocatable.
- MJIT (2.6 to 3.1, off unless asked for) compiles with `/usr/bin/cc` at run time.
- On Ruby 1.9.3, Puma 3.10 and later never finishes a graceful stop (a `Thread#join` bug in
  that Ruby); use Puma 3.8.2 or older there.

Series with `yjit: false` (everything up to 3.1, whose C-based YJIT was experimental) get
one build per target in a release, under the plain name. A hand-run `bin/package --yjit` on
one prints a warning and builds without YJIT, producing that same artifact, rather than failing.

## Alongside the system's OpenSSL

A Ruby process often loads a second OpenSSL: the `pg` and `mysql2` gems link to the
system's libpq or libmysqlclient, which bring in the distribution's `libssl.so.3`. The
OpenSSL inside these Rubies is kept out of its way. Its symbols are not exported, and for
the series on OpenSSL 1.x the `openssl` and `digest` extensions export nothing but their
`Init` function, because they define stand-ins for functions that OpenSSL 3 also has. The
build fails if any of that regresses.

Without this, the dynamic linker binds one library's calls to the other's functions and
the process segfaults or fails its TLS handshakes, depending on which was loaded first.
The published builds of every series from 1.8 to 4.0 are tested on Ubuntu 24.04 with `pg`
compiled against the system libpq: a TLS connection to PostgreSQL and an HTTPS request in
the same process, requiring `pg` before `openssl` and the other way round.

Native gems that use OpenSSL themselves (puma, eventmachine) compile against the bundled
headers and static libraries, and get the same linker flag through `rbconfig`; see
[Native gems](#native-gems).

## SSL certificates

These Rubies use the first available certificate source in this order:

| Priority | Source | Paths |
| --- | --- | --- |
| 1 | Standard OpenSSL overrides | `SSL_CERT_FILE`, `SSL_CERT_DIR` |
| 2 | Portable Ruby overrides | `JDX_RUBY_SSL_CERT_FILE`, `JDX_RUBY_SSL_CERT_DIR` |
| 3 | System bundles | `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/ca-bundle.pem`, `/etc/ssl/cert.pem` |
| 4 | Bundled CA bundle | Last-resort fallback included with the portable build. |

## Local development

Recipes are checked in under `recipes/`:

- `recipes/rubies.yml`: Ruby source URLs, SHA256 values, series, and prerelease versions.
- `recipes/dependencies.yml`: portable dependency source URLs and SHA256 values.
- `recipes/series.yml`: per-series build settings.
- `recipes/targets.yml`: release target metadata and pinned Linux containers.

Validate recipes and build a tarball with:

```sh
bin/validate-recipes
bin/package 3.4.9 --target x86_64_linux --no-yjit --output rubies
```

`bin/package-linux VERSION TARGET [--yjit|--no-yjit]` runs the same thing inside the pinned
manylinux container for a Linux target, the way CI does, so a Linux tarball can be built
and tested locally without a Linux machine.

Linux release builds are expected to run in the pinned manylinux_2_28 containers (GCC 14) from `recipes/targets.yml`. Builds need a baseruby of Ruby 3.0.0 or newer; set `JDX_RUBY_BASERUBY` when your shell default is older. Ruby 3.2 needs a baseruby of exactly the version being built: the build makes one first, or uses `JDX_RUBY_BASERUBY` when it points at one. YJIT builds use rustup/rustc from `PATH`, with optional `JDX_RUBY_RUSTUP_HOME`.

Every build ends by testing the packaged tree from a different directory: the standard
library and its extensions load, a native gem compiles and loads, nothing links to a shared
library outside glibc or needs a glibc newer than 2.28, no OpenSSL symbol is exported
(see [below](#alongside-the-systems-openssl)), and nothing a native gem is built from still
names the build tree (see [Native gems](#native-gems)). Pull requests only build Ruby 3.4.1
(all four artifacts), so build a change to an older series locally with `bin/package-linux`
before merging it.

## How do I issue a new release

[An automated release workflow is available to use](https://github.com/hatchboxio/precompiled-ruby/actions/workflows/release.yml).
Dispatch the workflow with a Ruby version and it will build, upload SLSA provenance, publish an immutable build revision release (e.g. `3.4.7-2`), and then re-point the floating release (e.g. `3.4.7`) at that build. The floating release is updated in place rather than recreated, so its download URLs keep working while a rebuild is in flight or if one fails; new assets are renamed over the old ones rather than re-uploaded in place.

A dispatched release only builds when something that affects the build has changed. Each
revision release records a build fingerprint (`bin/build-fingerprint VERSION`: the version's
recipe, its effective series settings, dependency versions and checksums, the targets, the
packaging script and the build workflow), and a run whose fingerprint matches the newest
revision's exits after its first job. Tick `force` to rebuild anyway, for example when a
pinned container or the Rust toolchain is the reason.

Each version keeps its two newest revision releases, the current build and the previous one
for rollback; older revisions and their tags are deleted after a publish (`bin/prune-revisions`,
`KEEP_REVISIONS` in the workflow). The floating release is never pruned. A mise lockfile that
pins a pruned revision falls back to the newest one.

[Release New Versions](https://github.com/hatchboxio/precompiled-ruby/actions/workflows/release-new.yml)
dispatches that for every recipe that has no release yet; it runs on a schedule, when
`recipes/rubies.yml` changes on `main`, or by hand, where its `only` input releases exactly
the versions you name instead. On a fresh fork the default means every recipe, so the first
run is a big one; use `only` to start smaller.

Series can opt out of the yjit variants with `yjit: false` in `recipes/series.yml`; the
end-of-life series do, and release one tarball per target under the plain name.

[Bump Ruby recipes](https://github.com/hatchboxio/precompiled-ruby/actions/workflows/autobump.yml)
runs twice a day and adds a recipe for each new Ruby release; Release New Versions then
builds it.

A change to the packaging script or a series' settings doesn't rebuild anything by itself.
Dispatch Release New Versions with `only` set to the versions it affects, or with
`replace_all` when it affects every build. The packaging script is part of every version's
fingerprint, so `replace_all` after a change to it rebuilds everything.

No secrets are required. One is optional:

- `RELEASE_TOKEN`: a personal access token with contents and actions write. Without it the
  workflows use the built-in token, which works for releasing; the one difference is that
  pushes made by the autobump workflow don't trigger Release New Versions, so its schedule
  picks new recipes up instead.

On a fork, GitHub disables scheduled workflows until they are enabled once in the Actions
tab.

## Thanks

Forked from [jdx/ruby](https://github.com/jdx/ruby), itself a fork of [spinel-coop/rv-ruby](https://github.com/spinel-coop/rv-ruby), which was based on [Homebrew/homebrew-portable-ruby](https://github.com/Homebrew/homebrew-portable-ruby).

## License

Code is under the [BSD 2-Clause "Simplified" License](/LICENSE.txt).
