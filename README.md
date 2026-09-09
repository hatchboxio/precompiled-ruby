# Portable Ruby Binaries

Tools to build Ruby tarballs that can be installed and run from anywhere on the filesystem.

## How do I use these rubies

Download the appropriate tarball for your platform from the [releases page](https://github.com/hatchboxio/precompiled-ruby/releases) and extract it to any location.

Release artifacts are named:

- `ruby-VERSION.macos.tar.gz`
- `ruby-VERSION.x86_64_linux.tar.gz`
- `ruby-VERSION.x86_64_linux.no_yjit.tar.gz`
- `ruby-VERSION.arm64_linux.tar.gz`
- `ruby-VERSION.arm64_linux.no_yjit.tar.gz`

## Local development

Recipes are checked in under `recipes/`:

- `recipes/rubies.yml`: Ruby source URLs, SHA256 values, series, and prerelease versions.
- `recipes/dependencies.yml`: portable dependency source URLs and SHA256 values.
- `recipes/series.yml`: per-series build settings.
- `recipes/targets.yml`: release target metadata and pinned Linux containers.

Validate recipes and build a tarball with:

```sh
bin/validate-recipes
bin/package 3.4.9 --target macos --yjit --output rubies
bin/package 3.4.9 --target x86_64_linux --no-yjit --output rubies
```

`bin/package-linux VERSION TARGET [--yjit|--no-yjit]` runs the same thing inside the pinned
manylinux2014 container for a Linux target, the way CI does, so a Linux tarball can be built
and tested locally without a Linux machine.

Linux release builds are expected to run in the pinned manylinux2014 containers from `recipes/targets.yml`. Builds need a baseruby of Ruby 3.0.0 or newer; set `JDX_RUBY_BASERUBY` when your shell default is older. Ruby 3.2 builds require `JDX_RUBY_BASERUBY` to match the exact version being built. YJIT builds use rustup/rustc from `PATH`, with optional `JDX_RUBY_RUSTUP_HOME`.

## End-of-life Rubies

Ruby 1.8.7 through 3.1 are in the recipes as well, for local development against old
applications; they are not for production use. They build the same relocatable way, with
a few differences that `recipes/series.yml` spells out per series: OpenSSL 1.0.2 or 1.1.1
where the openssl extension predates OpenSSL 3, readline through a bundled libedit, the
host Ruby hidden from configures that would otherwise use it as baseruby, no bundled
msgpack/bootsnap, and a version-appropriate native gem as the installation test. Ruby 1.8
predates `--enable-load-relative`, so its `bin/ruby` is a shell wrapper that supplies the
load path. Every one of these series has been built and tested for `arm64_linux`, and
2.3.8 and 2.7.8 for `x86_64_linux` as well; macOS is not covered, and OpenSSL 1.0.2 has no
arm64 macOS configuration at all.

Because they are built against glibc 2.17 like everything else here, the tarballs run on
any Ubuntu LTS from 20.04 (Focal) on, and on other distributions of that vintage or newer.

Series with `yjit: false` (everything up to 3.1, whose C-based YJIT was experimental) get
only the `no_yjit` variants in a release. A hand-run `bin/package --yjit` on one prints a
warning and builds without YJIT under the requested name rather than failing.

## SSL certificates

These Rubies use the first available certificate source in this order:

| Priority | Source | Paths |
| --- | --- | --- |
| 1 | Standard OpenSSL overrides | `SSL_CERT_FILE`, `SSL_CERT_DIR` |
| 2 | Portable Ruby overrides | `JDX_RUBY_SSL_CERT_FILE`, `JDX_RUBY_SSL_CERT_DIR` |
| 3 | System bundles | `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/ca-bundle.pem`, `/etc/ssl/cert.pem` |
| 4 | Bundled CA bundle | Last-resort fallback included with the portable build. |

## How do I issue a new release

[An automated release workflow is available to use](https://github.com/hatchboxio/precompiled-ruby/actions/workflows/release.yml).
Dispatch the workflow with a Ruby version and it will build, tag, upload SLSA provenance, and publish both the floating release and immutable build revision release.

[Release New Versions](https://github.com/hatchboxio/precompiled-ruby/actions/workflows/release-new.yml)
dispatches that for every recipe that has no release yet and that upstream does not build;
it runs on a schedule, when `recipes/rubies.yml` changes on `main`, or by hand, where its
`only` input releases exactly the versions you name instead, upstream's or not.

Series can opt out of the macOS build with `macos: false` in `recipes/series.yml`, and out
of the yjit variants with `yjit: false`; the end-of-life series do both, and release Linux
`no_yjit` tarballs only.

No secrets are required. Optional ones:

- `RELEASE_TOKEN`: a personal access token with contents and actions write. Without it the
  workflows use the built-in token, which works for releasing; the one difference is that
  pushes made by the autobump workflow don't trigger Release New Versions, so its schedule
  picks new recipes up instead.
- `RESEND_API_KEY` and `NOTIFY_EMAIL`: release result emails via Resend.

On a fork, GitHub disables scheduled workflows until they are enabled once in the Actions
tab; the upstream mirror is one of them.

## Upstream releases

Current Rubies are not built here at all. [Mirror Upstream Releases](https://github.com/hatchboxio/precompiled-ruby/actions/workflows/mirror-upstream.yml)
copies every published release of [jdx/ruby](https://github.com/jdx/ruby/releases) into
this repository as it appears, assets, provenance file, and release notes included, so the
releases here are a superset of upstream's: current series from upstream's builds, the
end-of-life series from the recipes here. It runs every three hours, mirrors oldest first,
and refreshes a floating release (`3.4.9`) whenever upstream adds a build revision to it
(`3.4.9-5`), the way upstream's own release does. Release New Versions leaves every version
upstream has a recipe for to it; set its `UPSTREAM_REPO` to `''` to build everything here.

The logic is `bin/mirror-upstream-releases`, which runs from any machine with `gh` logged
in: `--dry-run` prints the plan, `--limit N` caps a run (the workflow's default is 40, within
the built-in token's API rate limit), and `--only TAG...` mirrors exactly those tags,
replacing whatever this repository has under them, which is also how to redo a mirror that
went wrong. The first run on a fresh fork has a couple of hundred releases to copy and
spreads them over several scheduled runs.

## Thanks

Forked from [spinel-coop/rv-ruby](https://github.com/spinel-coop/rv-ruby), which was based on [Homebrew/homebrew-portable-ruby](https://github.com/Homebrew/homebrew-portable-ruby).

## License

Code is under the [BSD 2-Clause "Simplified" License](/LICENSE.txt).
