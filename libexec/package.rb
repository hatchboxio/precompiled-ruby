#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "English"
require "etc"
require "fileutils"
require "optparse"
require "rbconfig"
require "rubygems"
require "shellwords"
require "tmpdir"
require "uri"
require "yaml"

class PackageError < StandardError; end

class PortableRubyPackage
  ROOT = File.expand_path("..", __dir__)
  CACHE_DIR = File.join(ROOT, ".cache", "sources")

  attr_reader :version, :target, :yjit, :output_dir

  def initialize(options)
    @version = options.fetch(:version)
    @target = options.fetch(:target)
    @yjit = options.fetch(:yjit)
    @output_dir = File.expand_path(options.fetch(:output), ROOT)
    @skip_tests = options.fetch(:skip_tests)

    @rubies = load_yaml("recipes/rubies.yml").fetch("rubies")
    @deps = load_yaml("recipes/dependencies.yml").fetch("dependencies")
    @series_doc = load_yaml("recipes/series.yml")
    @targets = load_yaml("recipes/targets.yml").fetch("targets")
    @ruby_recipe = @rubies.fetch(version) { raise PackageError, "Unknown Ruby version: #{version}" }
    @target_recipe = @targets.fetch(target) { raise PackageError, "Unknown target: #{target}" }
    @series = merged_series(@ruby_recipe.fetch("series"))

    @build_root = File.join(ROOT, ".build", "#{version}-#{target}-#{yjit ? "yjit" : "no_yjit"}")
    @source_root = File.join(@build_root, "src")
    @tools_prefix = File.join(@build_root, "tools")
    @deps_root = File.join(@build_root, "deps")
    @package_root = File.join(@build_root, "package")
    @install_prefix = File.join(@package_root, "ruby-#{version}")
    @dep_prefixes = {}
  end

  def self.parse!(argv)
    options = { output: "rubies", skip_tests: false }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: bin/package VERSION --target TARGET --yjit|--no-yjit [--output DIR]"
      opts.on("--target TARGET", "Target: macos, x86_64_linux, arm64_linux") { |value| options[:target] = value }
      opts.on("--yjit", "Build Ruby with YJIT") { options[:yjit] = true }
      opts.on("--no-yjit", "Build Ruby without YJIT") { options[:yjit] = false }
      opts.on("--output DIR", "Artifact output directory") { |value| options[:output] = value }
      opts.on("--skip-tests", "Build and package without running runtime tests") { options[:skip_tests] = true }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit
      end
    end
    parser.parse!(argv)
    options[:version] = argv.shift
    raise PackageError, parser.to_s unless options[:version]
    raise PackageError, "--target is required" unless options[:target]
    raise PackageError, "choose exactly one of --yjit or --no-yjit" if options[:yjit].nil?
    options
  end

  def run!
    validate_host!
    validate_yjit!
    prepare_workspace!
    build_tool_pkgconf!
    build_dependencies!
    build_ruby!
    test_installation! unless @skip_tests
    artifact = package!
    puts "Created #{artifact}"
  end

  private

  def load_yaml(path)
    YAML.safe_load(File.read(File.join(ROOT, path)), permitted_classes: [], aliases: false)
  end

  def merged_series(name)
    defaults = deep_dup(@series_doc.fetch("defaults"))
    override = @series_doc.fetch("series").fetch(name) { {} }
    deep_merge(defaults, override || {})
  end

  def deep_dup(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child), copy| copy[key] = deep_dup(child) }
    when Array
      value.map { |child| deep_dup(child) }
    else
      value
    end
  end

  def deep_merge(left, right)
    left.merge(right) do |_key, old_value, new_value|
      old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
    end
  end

  # Old series have no YJIT worth shipping. The release workflow doesn't ask for the yjit
  # variant of those, but a hand-run request is honoured by building the same Ruby under
  # the requested name rather than failing.
  def validate_yjit!
    return unless yjit
    return if @series["yjit"]

    warn "warning: Ruby #{version} has no supported YJIT; building without it under the --yjit artifact name"
  end

  def validate_host!
    host_os = RbConfig::CONFIG.fetch("host_os")
    if @target_recipe.fetch("os") == "linux"
      raise PackageError, "#{target} must be built inside a Linux container" unless host_os.include?("linux")
      glibc = `getconf GNU_LIBC_VERSION 2>/dev/null`.split.last
      if glibc && glibc != @target_recipe["max_glibc"]
        raise PackageError, "expected glibc #{@target_recipe["max_glibc"]}, found #{glibc}; " \
                            "Linux targets must be built inside the manylinux2014 container"
      end
    elsif !host_os.include?("darwin")
      raise PackageError, "macos target must be built on macOS"
    end
  end

  def prepare_workspace!
    FileUtils.rm_rf(@build_root)
    FileUtils.mkdir_p([@source_root, @tools_prefix, @deps_root, @package_root, CACHE_DIR, output_dir])
  end

  def build_tool_pkgconf!
    recipe = @deps.fetch("pkgconf")
    source = extract_source("pkgconf", recipe)
    run "./configure", "--prefix=#{@tools_prefix}", "--disable-shared", "--enable-static", cwd: source
    make source
    make source, "install"
    pkgconf = File.join(@tools_prefix, "bin", "pkgconf")
    pkg_config = File.join(@tools_prefix, "bin", "pkg-config")
    FileUtils.ln_sf("pkgconf", pkg_config) unless File.exist?(pkg_config)
  end

  def build_dependencies!
    build_libyaml
    build_openssl
    build_libffi
    build_zlib
    build_ncurses_and_libedit if @series["use_libedit"]
    if linux?
      build_libxcrypt
    end
  end

  def build_libyaml
    source = extract_source("libyaml", @deps.fetch("libyaml"))
    prefix = dep_prefix("libyaml")
    env = dependency_build_env
    run "./configure",
        "--disable-dependency-tracking",
        "--prefix=#{prefix}",
        "--enable-static",
        "--disable-shared",
        cwd: source,
        env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_libffi
    source = extract_source("libffi", @deps.fetch("libffi"))
    prefix = dep_prefix("libffi")
    env = dependency_build_env
    run "./configure",
        "--prefix=#{prefix}",
        "--libdir=#{File.join(prefix, "lib")}",
        "--disable-dependency-tracking",
        "--enable-static",
        "--disable-shared",
        "--disable-docs",
        cwd: source,
        env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_libxcrypt
    source = extract_source("libxcrypt", @deps.fetch("libxcrypt"))
    prefix = dep_prefix("libxcrypt")
    env = dependency_build_env
    run "./configure",
        "--prefix=#{prefix}",
        "--disable-dependency-tracking",
        "--enable-static",
        "--disable-shared",
        "--disable-obsolete-api",
        "--disable-xcrypt-compat-files",
        "--disable-failure-tokens",
        "--disable-valgrind",
        cwd: source,
        env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_zlib
    source = extract_source("zlib", @deps.fetch("zlib"))
    prefix = dep_prefix("zlib")
    env = dependency_build_env
    run "./configure", "--static", "--prefix=#{prefix}", cwd: source, env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_ncurses_and_libedit
    ncurses_source = extract_source("ncurses", @deps.fetch("ncurses"))
    ncurses = dep_prefix("ncurses")
    ncurses_pkgconfig = File.join(ncurses, "lib", "pkgconfig")
    FileUtils.mkdir_p(ncurses_pkgconfig)
    ncurses_env = dependency_build_env("PKG_CONFIG_LIBDIR" => ncurses_pkgconfig)
    run "./configure",
        "--disable-dependency-tracking",
        "--prefix=#{ncurses}",
        "--enable-static",
        "--disable-shared",
        "--without-cxx-binding",
        "--enable-pc-files",
        "--with-pkg-config-libdir=#{ncurses_pkgconfig}",
        "--enable-sigwinch",
        "--enable-symlinks",
        "--enable-widec",
        "--with-gpm=no",
        "--without-ada",
        cwd: ncurses_source,
        env: ncurses_env
    make ncurses_source, env: ncurses_env
    make ncurses_source, "install", env: ncurses_env
    make_ncurses_symlinks(ncurses)

    libedit_source = extract_source("libedit", @deps.fetch("libedit"))
    libedit = dep_prefix("libedit")
    env = dependency_build_env(
      "CPPFLAGS" => "-I#{File.join(ncurses, "include")} -I#{File.join(ncurses, "include", "ncursesw")}",
      "LDFLAGS" => "-L#{File.join(ncurses, "lib")}",
      "PKG_CONFIG_PATH" => File.join(ncurses, "lib", "pkgconfig")
    )
    run "./configure",
        "--prefix=#{libedit}",
        "--disable-dependency-tracking",
        "--enable-static",
        "--disable-shared",
        "--disable-examples",
        cwd: libedit_source,
        env: env
    make libedit_source, env: env
    make libedit_source, "install", env: env
  end

  def make_ncurses_symlinks(prefix)
    lib = File.join(prefix, "lib")
    include = File.join(prefix, "include")
    pkgconfig = File.join(lib, "pkgconfig")
    %w[form menu ncurses panel].each do |name|
      link_file(File.join(lib, "lib#{name}w.a"), File.join(lib, "lib#{name}.a"))
      link_file(File.join(lib, "lib#{name}w_g.a"), File.join(lib, "lib#{name}_g.a"))
    end
    link_file(File.join(lib, "libncurses.a"), File.join(lib, "libcurses.a"))
    link_file(File.join(pkgconfig, "ncursesw.pc"), File.join(pkgconfig, "ncurses.pc"))
    link_file(File.join(include, "ncursesw"), File.join(include, "ncurses"))
    %w[curses.h form.h ncurses.h panel.h term.h termcap.h].each do |header|
      link_file(File.join(include, "ncursesw", header), File.join(include, header))
    end
  end

  # Which OpenSSL a series gets is a recipe decision: Ruby's openssl extension only learned
  # OpenSSL 3 in 3.1, and only learned 1.1 in 2.4.
  def openssl_dependency
    @series.fetch("openssl")
  end

  def openssl_version
    Gem::Version.new(@deps.fetch(openssl_dependency).fetch("version"))
  end

  def legacy_openssl?
    openssl_version < Gem::Version.new("3")
  end

  def build_openssl
    source = extract_source("openssl", @deps.fetch(openssl_dependency))
    prefix = dep_prefix("openssl")
    env = dependency_build_env
    if legacy_openssl?
      if macos? && openssl_version < Gem::Version.new("1.1")
        raise PackageError, "OpenSSL #{openssl_version} has no arm64 macOS target; Ruby #{version} is Linux-only here"
      end
      # 1.0.2 and 1.1.1 have no e_os.h and no ossl_safe_getenv, so the certificate lookup
      # patch does not apply. bundle_certificates compensates from the Ruby side instead.
      args = [
        "--prefix=#{prefix}",
        "--openssldir=#{File.join(prefix, "libexec", "etc", "openssl")}",
        "--libdir=lib",
        "no-shared",
        "no-ssl2",
        "no-ssl3",
        "-fPIC"
      ]
      if openssl_version < Gem::Version.new("1.1")
        # 1.0.2: no-comp leaves out a header err_all.c still includes, the Makefiles are
        # not parallel-safe, and its aarch64 assembly carries relocations a shared object
        # can't have ("dangerous relocation" linking Ruby's digest extensions), so no-asm.
        args << "no-asm"
        install_target = "install_sw"
        env = env.merge("MAKEFLAGS" => "-j1")
      else
        args << "no-comp"
        install_target = "install_dev"
      end
    else
      patch_openssl_cert_lookup(source)
      args = [
        "--prefix=#{prefix}",
        "--openssldir=#{File.join(prefix, "libexec", "etc", "openssl")}",
        "--libdir=#{File.join(prefix, "lib")}",
        "no-legacy",
        "no-module",
        "no-shared",
        "no-engine",
        "no-makedepend"
      ]
      install_target = "install_dev"
    end
    args += openssl_arch_args
    run "perl", "./Configure", *args, cwd: source, env: env
    make source, env: env
    make source, install_target, env: env
    libcrypto_pc = File.join(prefix, "lib", "pkgconfig", "libcrypto.pc")
    inreplace(libcrypto_pc, "\nLibs.private:", "") if File.read(libcrypto_pc).include?("\nLibs.private:")
    cacert = download("cacert", @deps.fetch("cacert"))
    cert_dir = File.join(prefix, "libexec", "etc", "openssl")
    FileUtils.mkdir_p(cert_dir)
    FileUtils.cp(cacert, File.join(cert_dir, "cert.pem"))
  end

  def build_ruby!
    ensure_rust! if yjit && @series["yjit"]
    source = extract_source("ruby", @ruby_recipe)
    apply_source_patches(source)
    remove_extensions(source) if package_version < Gem::Version.new("1.9")
    freshen_config_guess(source) if @series["freshen_config_guess"]
    stage_bundled_gems(source) if bundled_gems?

    args = ruby_configure_args(source)
    env = ruby_build_env
    run "./configure", *args, cwd: source, env: env
    make source, "extract-gems", env: env if bundled_gems?
    make source, env: env
    if bundled_gems?
      make source, "ruby.pc", env: env
      make_portable_gems_load_path(source)
    end
    make source, @series.fetch("install_target"), env: env

    install_wrapper if @series["load_relative"] == "wrapper"
    install_rubygems if @series["rubygems"]
    patch_executables
    install_bundlers
    patch_executables
    patch_rbconfig
    copy_native_gem_dependencies
    bundle_certificates
  end

  # The Ruby being packaged, as a comparable version. (ruby_version(ruby) below asks a
  # Ruby executable for its version; this is the recipe's.)
  def package_version
    Gem::Version.new(version.split("-").first)
  end

  # 1.8 has no --with-out-ext; an extension is left out by not being there. gdbm and dbm
  # matter: the build container has their libraries, so they would link against them.
  def remove_extensions(source)
    Array(@series["extra_out_ext"]).each do |ext|
      FileUtils.rm_rf(File.join(source, "ext", ext))
    end
  end

  def bundled_gems?
    gems = @series["bundled_gems"]
    gems.is_a?(Hash) && !gems.empty?
  end

  # Source patches are named in the series recipe and implemented here, so a recipe can't
  # smuggle in arbitrary edits and every patch has a place to explain itself.
  def apply_source_patches(source)
    Array(@series["patches"]).each do |name|
      case name
      when "lex_c99"
        # https://bugs.ruby-lang.org/issues/1382 — 1.8.7's gperf-generated rb_reserved_word
        # is declared inline without static, which C99 inline semantics (the default since
        # GCC 5) turn into an undefined reference at link time.
        inreplace(File.join(source, "lex.c"), "struct kwtable *\nrb_reserved_word", "static struct kwtable *\nrb_reserved_word")
      else
        raise PackageError, "unknown source patch: #{name}"
      end
    end
  end

  # config.guess older than 2012 doesn't know aarch64. Take automake's copy when the build
  # host has one (the manylinux images do), otherwise GNU's.
  def freshen_config_guess(source)
    dir = File.exist?(File.join(source, "tool", "config.guess")) ? File.join(source, "tool") : source
    local = Dir["/usr/share/automake-*/config.guess"].max
    %w[config.guess config.sub].each do |name|
      if local
        FileUtils.cp(File.join(File.dirname(local), name), File.join(dir, name))
      else
        run "curl", "-fsSL", "-o", File.join(dir, name),
            "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=#{name};hb=HEAD"
      end
      FileUtils.chmod(0o755, File.join(dir, name))
    end
  end

  # Ruby 1.8 predates --enable-load-relative. The binary moves to libexec/ and bin/ruby
  # becomes a shell wrapper that finds the prefix from its own location and hands the
  # load path over with -I. rbconfig.rb already locates itself relative to the prefix, so
  # RubyGems and native gem builds follow along.
  def install_wrapper
    libexec = File.join(@install_prefix, "libexec")
    FileUtils.mkdir_p(libexec)
    FileUtils.mv(ruby_bin, File.join(libexec, "ruby"))
    arch = capture(File.join(libexec, "ruby"), "-rrbconfig", "-e", "print Config::CONFIG['arch']").strip
    lib_version = capture(File.join(libexec, "ruby"), "-rrbconfig", "-e", "print Config::CONFIG['ruby_version']").strip
    load_path = [
      "site_ruby/#{lib_version}", "site_ruby/#{lib_version}/#{arch}", "site_ruby",
      "vendor_ruby/#{lib_version}", "vendor_ruby/#{lib_version}/#{arch}", "vendor_ruby",
      lib_version, "#{lib_version}/#{arch}"
    ].map { |dir| %(-I "$prefix/lib/ruby/#{dir}") }.join(" \\\n  ")
    File.write(ruby_bin, <<~SH)
      #!/bin/sh
      # Ruby #{lib_version} cannot find its own prefix at run time; this wrapper does it instead.
      bindir="${0%/*}"
      prefix=$(cd "$bindir/.." && pwd -P)
      exec "$prefix/libexec/ruby" \\
        #{load_path} \\
        "$@"
    SH
    FileUtils.chmod(0o755, ruby_bin)
  end

  # Ruby 1.8 ships without RubyGems; install it from source with the freshly built Ruby.
  def install_rubygems
    source = extract_source("rubygems", @deps.fetch(@series.fetch("rubygems")))
    run ruby_bin, "setup.rb", "--no-ri", "--no-rdoc", cwd: source, env: test_env
  end

  def install_bundlers
    versions = Array(@series["bundler"])
    return if versions.empty?

    gem = File.join(@install_prefix, "bin", "gem")
    no_doc = capture(gem, "--version", env: test_env).strip.start_with?("1.") ? %w[--no-ri --no-rdoc] : %w[--no-document]
    versions.each do |bundler|
      run gem, "install", "bundler", "-v", bundler, *no_doc, env: test_env
    end
  end

  # The built Ruby, run from its build location, with nothing from the host leaking in.
  def test_env
    { "PATH" => "#{File.join(@install_prefix, "bin")}:/usr/bin:/bin", "GEM_HOME" => nil, "GEM_PATH" => nil, "RUBYOPT" => nil }
  end

  def ensure_rust!
    env_home = ENV["JDX_RUBY_RUSTUP_HOME"]
    ENV["RUSTUP_HOME"] = env_home if env_home && !env_home.empty?
    ENV["RUSTUP_TOOLCHAIN"] ||= "1.58"
    if find_executable("rustup")
      run "rustup", "install", ENV.fetch("RUSTUP_TOOLCHAIN"), "--profile", "minimal"
    elsif !find_executable("rustc")
      raise PackageError, "YJIT builds require rustup or rustc in PATH"
    end
  end

  def ruby_configure_args(_source)
    libyaml = dep_prefix("libyaml")
    openssl = dep_prefix("openssl")
    out_ext = %w[win32 win32ole] + Array(@series["extra_out_ext"])
    out_ext << "readline" unless @series["readline_ext"]
    args = [
      "--prefix=#{@install_prefix}",
      "--with-out-ext=#{out_ext.uniq.join(",")}",
      "--without-gmp",
      "--disable-dependency-tracking",
      "--with-libyaml-dir=#{libyaml}"
    ]
    args << "--enable-load-relative" if @series["load_relative"] == "configure"
    args << (@series["install_doc"] ? "--with-rdoc=ri" : "--disable-install-doc")
    # Extensions older than 2.7 take pkg-config's word over --with-openssl-dir, and 1.8 has
    # no pkg-config support at all; naming the directory covers both.
    if legacy_openssl?
      args << "--with-openssl-dir=#{openssl}"
      # Static libcrypto needs pthread_atfork and dlopen. On glibc older than 2.34 those
      # live in libpthread and libdl, and an extconf that takes --with-openssl-dir at its
      # word links -lcrypto alone, so its SSL_new probe fails and the extension is silently
      # skipped. Ruby's LIBS reach every extension's link line.
      args << "LIBS=-lpthread -ldl" if linux?
    end
    args << "MJIT_CC=#{@series["mjit_cc"]}" if @series["mjit_cc"]

    baseruby = ENV["JDX_RUBY_BASERUBY"]
    case @series.fetch("baseruby")
    when "none"
      # Every generated file ships in the tarball, and this configure would otherwise pick
      # up whatever `ruby` is on PATH — the 3.x bootstrap — to run its own 2.x-era tools
      # with. ruby_build_env hides it.
    when "no"
      args << "--with-baseruby=no"
    else
      args += baseruby_args(baseruby)
    end

    args << "--enable-yjit" if yjit && @series["yjit"]
    if @series["use_libedit"]
      args << "--enable-libedit=#{dep_prefix("libedit")}"
      args << "--with-libedit-dir=#{dep_prefix("libedit")}"
      args << "--with-opt-dir=#{dep_prefix("ncurses")}"
      # Before 2.1 the readline extconf only looks where --with-readline-dir points; later
      # ones look there too, so every old series gets it.
      args << "--with-readline-dir=#{dep_prefix("libedit")}" if @series["test"] == "legacy"
    end

    args << "--with-libffi-dir=#{dep_prefix("libffi")}"
    args << "--with-zlib-dir=#{dep_prefix("zlib")}"

    if linux?
      args << "MKDIR_P=/bin/mkdir -p"
      args << "ac_cv_lib_z_uncompress=no"
    end

    ENV["OPENSSL_PREFIX"] = openssl
    args
  end

  def baseruby_args(baseruby)
    args = []
    if @series["requires_matching_baseruby"]
      baseruby = matching_baseruby(baseruby)
      args << "--with-baseruby=#{baseruby}"
      args << "MJIT_CC=/usr/bin/#{ENV.fetch("CC", "cc")}"
    elsif baseruby && !baseruby.empty?
      unless File.executable?(baseruby)
        raise PackageError, "JDX_RUBY_BASERUBY must point to an executable Ruby"
      end
      unless ruby_at_least?(baseruby, "3.0.0")
        raise PackageError, "JDX_RUBY_BASERUBY must be Ruby 3.0.0 or newer"
      end
      args << "--with-baseruby=#{baseruby}"
    else
      unless ruby_at_least?(RbConfig.ruby, "3.0.0")
        raise PackageError, "Ruby #{version} requires a baseruby >= 3.0.0; set JDX_RUBY_BASERUBY"
      end
      args << "--with-baseruby=#{RbConfig.ruby}"
    end
    args
  end

  def matching_baseruby(candidate)
    unless candidate.to_s.empty?
      raise PackageError, "JDX_RUBY_BASERUBY must point to an executable Ruby #{version}" unless File.executable?(candidate)
      raise PackageError, "JDX_RUBY_BASERUBY must be Ruby #{version}" unless ruby_version_matches?(candidate)
      return candidate
    end

    build_matching_baseruby!
  end

  def build_matching_baseruby!
    @matching_baseruby ||= begin
      bootstrap = RbConfig.ruby
      unless ruby_at_least?(bootstrap, "3.0.0")
        raise PackageError, "Ruby #{version} requires a baseruby >= 3.0.0 to build a matching baseruby"
      end

      source = extract_source("baseruby", @ruby_recipe)
      prefix = File.join(@build_root, "baseruby")
      env = dependency_build_env(
        "BASERUBY" => bootstrap,
        "LC_ALL" => "C.UTF-8",
        "LANG" => "C.UTF-8",
        "PKG_CONFIG_PATH" => [
          File.join(dep_prefix("libyaml"), "lib", "pkgconfig"),
          File.join(dep_prefix("zlib"), "lib", "pkgconfig")
        ].join(File::PATH_SEPARATOR)
      )
      args = [
        "--prefix=#{prefix}",
        "--disable-install-doc",
        "--disable-dependency-tracking",
        "--with-baseruby=#{bootstrap}",
        "--with-libyaml-dir=#{dep_prefix("libyaml")}",
        "--with-zlib-dir=#{dep_prefix("zlib")}",
        "--without-gmp",
        "--with-out-ext=win32,win32ole,openssl,readline,fiddle"
      ]
      args << "MKDIR_P=/bin/mkdir -p" if linux?

      run "./configure", *args, cwd: source, env: env
      make source, env: env
      make source, "install", env: env

      ruby = File.join(prefix, "bin", "ruby")
      unless File.executable?(ruby) && ruby_version_matches?(ruby)
        raise PackageError, "failed to build matching baseruby #{version}"
      end
      ruby
    end
  end

  def ruby_version_matches?(ruby)
    ruby_version(ruby) == version.split("-").first
  end

  def ruby_at_least?(ruby, minimum)
    Gem::Version.new(ruby_version(ruby)) >= Gem::Version.new(minimum)
  rescue ArgumentError
    false
  end

  def ruby_version(ruby)
    `#{ruby.shellescape} -e 'print RUBY_VERSION' 2>/dev/null`
  end

  def ruby_build_env
    pkg_paths = [File.join(dep_prefix("openssl"), "lib", "pkgconfig")]
    pkg_paths << File.join(dep_prefix("libffi"), "lib", "pkgconfig")
    pkg_paths << File.join(dep_prefix("zlib"), "lib", "pkgconfig")
    if @series["use_libedit"]
      pkg_paths << File.join(dep_prefix("libedit"), "lib", "pkgconfig")
      pkg_paths << File.join(dep_prefix("ncurses"), "lib", "pkgconfig")
    end
    pkg_paths << ENV["PKG_CONFIG_PATH"] if ENV["PKG_CONFIG_PATH"]

    cppflags = []
    ldflags = []
    if linux?
      cppflags << "-I#{File.join(dep_prefix("libxcrypt"), "include")}"
      ldflags << "-L#{File.join(dep_prefix("libxcrypt"), "lib")}"
    end
    extra_cflags = []
    extra_cflags << "-mno-outline-atomics" if linux_arm64?

    env = build_env(
      "PKG_CONFIG_PATH" => pkg_paths.compact.join(File::PATH_SEPARATOR),
      "CPPFLAGS" => cppflags.join(" "),
      "LDFLAGS" => ldflags.join(" "),
      "XCFLAGS" => (cppflags + extra_cflags).join(" "),
      "XLDFLAGS" => ldflags.join(" ")
    )
    # A series may pin CFLAGS outright. Ruby's configure then uses them instead of its own
    # optflags, exactly as ruby-build does — which is the point for the old sources that
    # need -fno-strict-overflow to keep their fixnum arithmetic honest.
    env["CFLAGS"] = @series["cflags"] if @series["cflags"]
    env["MAKEFLAGS"] = "-j#{@series["make_jobs"]}" if @series["make_jobs"]
    env["PATH"] = path_without_ruby(env["PATH"]) if @series["baseruby"] == "none"
    env
  end

  def path_without_ruby(path)
    path.split(File::PATH_SEPARATOR).reject { |dir| File.executable?(File.join(dir, "ruby")) }.join(File::PATH_SEPARATOR)
  end

  def stage_bundled_gems(source)
    bundled = File.join(source, "gems", "bundled_gems")
    raise PackageError, "Ruby #{version} has no gems/bundled_gems; set bundled_gems: ~ for its series" unless File.file?(bundled)
    lines = File.readlines(bundled).reject do |line|
      stripped = line.strip
      stripped.empty? || stripped.start_with?("#") || stripped.include?("win32")
    end
    @series.fetch("bundled_gems").each do |name, recipe|
      gem = download(name, recipe)
      FileUtils.cp(gem, File.join(source, "gems", File.basename(gem)))
      lines << "#{name} #{recipe.fetch("version")}\n"
    end
    File.write(bundled, lines.join)
  end

  def make_portable_gems_load_path(source)
    pc_file = Dir[File.join(source, "ruby-*.pc")].first
    raise PackageError, "ruby pkg-config file was not generated" unless pc_file

    arch = capture(pkgconf, "--variable=arch", pc_file).strip
    lib_arch = File.join(source, "lib", arch)
    FileUtils.mkdir_p(lib_arch)
    File.open(File.join(lib_arch, "portable_ruby_gems.rb"), "w") do |file|
      (Dir.glob(File.join(source, ".bundle", "extensions", "*", "*", "*")) +
        Dir.glob(File.join(source, ".bundle", "gems", "*", "lib"))).each do |path|
        relative = path.sub(%r{\A#{Regexp.escape(File.join(source, ".bundle"))}/}, "")
        file.puts %($:.unshift "\#{RbConfig::CONFIG["rubylibprefix"]}/gems/\#{RbConfig::CONFIG["ruby_version"]}/#{relative}")
      end
    end
  end

  # The sh/ruby polyglot Ruby's installer writes for bin/* under --enable-load-relative.
  RELATIVE_STUB_PROLOG = [
    "#!/bin/sh",
    "# -*- ruby -*-",
    "_=_\\",
    "=begin",
    'bindir="${0%/*}"',
    'exec "$bindir/ruby" "-x" "$0" "$@"',
    "=end",
    ""
  ].join("\n").freeze

  RUBYGEMS_MARKER = "#\n# This file was generated by RubyGems.\n"

  # Three things can be wrong with a bin/* stub, depending on the RubyGems that wrote it.
  #
  # RubyGems before 3.3 knows nothing of load-relative prefixes and writes an absolute
  # "#!<build prefix>/bin/ruby" shebang, so anything `gem install` produced during the
  # build (bundler, mostly) would break the moment the tree moved. Those get Ruby's own
  # relative prolog.
  #
  # RubyGems before 3.3 also checks whether an existing stub is its own by looking for its
  # marker on line three; in a polyglot that line is code, so reinstalling a gem whose
  # executable exists is refused as a conflict. The marker goes in right after the shebang.
  #
  # Newer RubyGems writes the polyglot itself but wants the marker after the inner ruby
  # shebang, which is the original patch below.
  def patch_executables
    build_ruby = File.join(@install_prefix, "bin", "ruby")
    Dir.glob(File.join(@install_prefix, "bin", "*")).each do |exe|
      next unless File.file?(exe)

      content = File.binread(exe)
      next unless content.start_with?("#!")

      patched = content.sub(/\A#!#{Regexp.escape(build_ruby)}\S*[^\n]*\n/) { RELATIVE_STUB_PROLOG + "#!/usr/bin/env ruby\n" }
      if patched.start_with?("#!/bin/sh\n") && patched.include?("This file was generated by RubyGems") &&
         patched.lines[2].to_s !~ /This file was generated by RubyGems/
        patched = patched.sub("\n", "\n" + RUBYGEMS_MARKER)
      end
      patched = patched.sub(
        %r{(#!/usr/bin/env ruby\n)\n(require 'rubygems')},
        "\\1#\n# This file was generated by RubyGems.\n#\n\\2"
      )
      File.binwrite(exe, patched) if patched != content
    end
  end

  def patch_rbconfig
    abi_version = capture(ruby_bin, "-rrbconfig", "-e", "print RbConfig::CONFIG['ruby_version']").strip
    abi_arch = capture(ruby_bin, "-rrbconfig", "-e", "print RbConfig::CONFIG['arch']").strip
    rbconfig = File.join(@install_prefix, "lib", "ruby", abi_version, abi_arch, "rbconfig.rb")
    raise PackageError, "Missing rbconfig.rb at #{rbconfig}" unless File.file?(rbconfig)

    content = File.read(rbconfig)
    content.gsub!(%r{ ?-I#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(%r{ ?-L#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(%r{ ?-B#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(%r{ ?-Wl,-rpath-link=#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(/(CONFIG\["CC"\] = )"[^"]*gcc(?:-\d+)?"/, '\\1"cc"')
    content.gsub!(/(CONFIG\["LDSHARED"\] = )"[^"]*gcc(?:-\d+)?/, '\\1"cc')
    content.gsub!(/(CONFIG\["CXX"\] = )"[^"]*g\+\+(?:-\d+)?"/, '\\1"c++"')
    content.gsub!(/(CONFIG\["(?:AR|NM|RANLIB)"\] = )"gcc-(?:ar|nm|ranlib)-\d+"/) do
      key = Regexp.last_match(1)
      tool = Regexp.last_match(0)[/gcc-(ar|nm|ranlib)-\d+/, 1]
      %(#{key}"#{tool}")
    end
    content << rbconfig_portability_patch
    File.write(rbconfig, content)
  end

  def rbconfig_portability_patch
    build_root = @build_root
    <<~RUBY

      # Prefer the relocated portable Ruby prefix when building native gems.
      module RbConfig
        build_root = #{build_root.dump}
        portable_prefix = CONFIG["prefix"]
        portable_include = File.join(portable_prefix, "include")
        portable_lib = File.join(portable_prefix, "lib")
        portable_pkgconfig = File.join(portable_lib, "pkgconfig")
        portable_cppflags = "-include stdbool.h -I\#{portable_include}"
        scrub_patterns = [
          Regexp.new(" ?-I" + Regexp.escape(build_root) + "[^ ]*"),
          Regexp.new(" ?-L" + Regexp.escape(build_root) + "[^ ]*"),
          Regexp.new(" ?-B" + Regexp.escape(build_root) + "[^ ]*"),
          Regexp.new(" ?-Wl,-rpath-link=" + Regexp.escape(build_root) + "[^ ]*"),
          / ?-fuse-linker-plugin/,
          / ?-fuse-ld=[^ ]+/,
          / ?-flto(?:=[^ ]+)?/,
          / ?[^ ]*liblto_plugin\\.so/,
          / ?-mbranch-protection=[^ ]+/,
          / ?-mno-outline-atomics/,
          / ?-Wduplicated-cond/,
          / ?-Wimplicit-fallthrough(?:=\\d+)?/,
          / ?-Wmisleading-indentation/
        ]

        darwin = CONFIG["host_os"].to_s.include?("darwin")
        linux = CONFIG["host_os"].to_s.include?("linux")

        [CONFIG, MAKEFILE_CONFIG].each do |config|
          config["CC"] = "cc"
          config["CPP"] = "cc -E"
          config["CXX"] = "c++"
          if darwin
            config["LDSHARED"] = "cc -dynamic -bundle"
            config["LDSHAREDXX"] = "c++ -dynamic -bundle" if config["LDSHAREDXX"]
            config["DLDSHARED"] = "cc -dynamiclib" if config["DLDSHARED"]
          else
            config["LDSHARED"] = "cc -shared"
            config["LDSHAREDXX"] = "c++ -shared" if config["LDSHAREDXX"]
            config["DLDSHARED"] = "cc -shared" if config["DLDSHARED"]
          end
          config["AR"] = "ar"
          config["NM"] = "nm"
          config["RANLIB"] = "ranlib"
          # Let mkmf honor ENV["PKG_CONFIG"] or find pkg-config on PATH.
          config.delete("PKG_CONFIG")
          %w[CFLAGS CPPFLAGS CXXFLAGS XCFLAGS XCXXFLAGS LDFLAGS DLDFLAGS LIBS LDSHARED LDSHAREDXX DLDSHARED cflags cxxflags hardenflags warnflags].each do |key|
            next unless config[key]
            scrub_patterns.each { |pattern| config[key] = config[key].gsub(pattern, "") }
            config[key] = config[key].squeeze(" ").strip
          end
          if linux
            %w[CFLAGS cflags].each do |key|
              next unless config[key]
              config[key] = "-std=gnu99 \#{config[key]}".squeeze(" ").strip unless config[key].include?("-std=")
            end
          end
          config["CPPFLAGS"] = "\#{portable_cppflags} \#{config["CPPFLAGS"]}".strip
          config["LDFLAGS"] = "-L\#{portable_lib} \#{config["LDFLAGS"]}".strip
          config["DLDFLAGS"] = "-L\#{portable_lib} \#{config["DLDFLAGS"]}".strip
          # One line each: Ruby 1.8 cannot parse a method chain that starts a line with a dot.
          config["PKG_CONFIG_PATH"] = [portable_pkgconfig, config["PKG_CONFIG_PATH"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
        end
        ENV["PKG_CONFIG_PATH"] = [portable_pkgconfig, ENV["PKG_CONFIG_PATH"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
      end
    RUBY
  end

  def copy_native_gem_dependencies
    deps = [dep_prefix("libyaml"), dep_prefix("openssl")]
    deps += [dep_prefix("libffi"), dep_prefix("zlib")]
    deps << dep_prefix("libxcrypt") if linux?
    deps += [dep_prefix("libedit"), dep_prefix("ncurses")] if @series["use_libedit"]

    include_dir = File.join(@install_prefix, "include")
    lib_dir = File.join(@install_prefix, "lib")
    pkgconfig_dir = File.join(lib_dir, "pkgconfig")
    FileUtils.mkdir_p([include_dir, lib_dir, pkgconfig_dir])

    deps.each do |dep|
      includes = Dir[File.join(dep, "include", "*")]
      static_libs = Dir[File.join(dep, "lib", "*.a")]
      FileUtils.cp_r(includes, include_dir) unless includes.empty?
      FileUtils.cp(static_libs, lib_dir) unless static_libs.empty?
      Dir[File.join(dep, "lib", "pkgconfig", "*.pc")].each do |pc|
        dest = File.join(pkgconfig_dir, File.basename(pc))
        FileUtils.cp(pc, dest)
        content = File.read(dest)
        content.gsub!(/^prefix=.*$/, "prefix=${pcfiledir}/../..")
        File.write(dest, content)
      end
    end
  end

  def bundle_certificates
    cert_src = File.join(dep_prefix("openssl"), "libexec", "etc", "openssl", "cert.pem")
    libexec = File.join(@install_prefix, "libexec")
    FileUtils.mkdir_p(libexec)
    FileUtils.cp(cert_src, File.join(libexec, "cert.pem"))

    openssl_rb = Dir[File.join(@install_prefix, "lib", "ruby", "*", "openssl.rb")].first
    return unless openssl_rb

    # With OpenSSL 3 the patched libcrypto searches the system stores itself, so Ruby only
    # has to supply the bundled file when there is none. Older OpenSSLs are unpatched and
    # would look in the build directory, so Ruby names the system store for them too.
    # Written for the oldest Ruby it will run under: no RbConfig.ruby, no Dir.exist?.
    use_system = legacy_openssl? ? "ENV[\"SSL_CERT_FILE\"] = found" : "nil"
    replacement = <<~RUBY.chomp
      require "rbconfig"
      if ENV["SSL_CERT_FILE"].to_s.empty? && ENV["SSL_CERT_DIR"].to_s.empty?
        jdx_cert_file = ENV["JDX_RUBY_SSL_CERT_FILE"].to_s
        if !jdx_cert_file.empty? && File.exist?(jdx_cert_file)
          ENV["SSL_CERT_FILE"] = jdx_cert_file
        else
          jdx_cert_dir = ENV["JDX_RUBY_SSL_CERT_DIR"].to_s
          ENV["SSL_CERT_DIR"] = jdx_cert_dir if !jdx_cert_dir.empty? && File.directory?(jdx_cert_dir)
        end
      end
      if ENV["SSL_CERT_FILE"].to_s.empty? && ENV["SSL_CERT_DIR"].to_s.empty?
        system_certs = %w[
          /etc/ssl/certs/ca-certificates.crt
          /etc/pki/tls/certs/ca-bundle.crt
          /etc/ssl/ca-bundle.pem
          /etc/ssl/cert.pem
        ]
        found = system_certs.find { |f| File.exist?(f) }
        if found
          #{use_system}
        else
          bundled = File.join(RbConfig::CONFIG["prefix"], "libexec", "cert.pem")
          ENV["SSL_CERT_FILE"] = bundled if File.exist?(bundled)
        end
      end
      require 'openssl.so'
    RUBY
    inreplace(openssl_rb, "require 'openssl.so'", replacement)
  end

  def test_installation!
    test_root = File.join(@build_root, "test", "ruby-#{version}")
    FileUtils.rm_rf(File.dirname(test_root))
    FileUtils.mkdir_p(File.dirname(test_root))
    FileUtils.cp_r(@install_prefix, test_root)
    ruby = File.realpath(File.join(test_root, "bin", "ruby"))
    gem = File.join(test_root, "bin", "gem")
    bundle = File.join(test_root, "bin", "bundle")
    env = { "PATH" => "/usr/bin:/bin", "GEM_HOME" => nil, "GEM_PATH" => nil, "RUBYOPT" => nil }
    ruby_version = Gem::Version.new(version.split("-").first)

    assert_equal(version.split("-").first, capture(ruby, "-e", "print RUBY_VERSION", env: env).strip) unless version.include?("preview")
    # RbConfig.ruby arrived in 1.9; this spelling is what it computes.
    assert_equal(ruby, capture(ruby, "-rrbconfig", "-e", "print File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])", env: env).strip)
    assert_equal("3632233996", capture(ruby, "-rzlib", "-e", "print Zlib.crc32('test')", env: env).strip)
    readline_breaks = capture(ruby, "-rreadline", "-e", "print Readline.basic_word_break_characters", env: env)
    if @series["use_libedit"]
      unless [" \t\n\"\\'`@$><=;|&{(", " \t\n`><=;|&{("].include?(readline_breaks)
        raise PackageError, "unexpected readline word breaks: #{readline_breaks.inspect}"
      end
    else
      assert_equal(" \t\n`><=;|&{(", readline_breaks)
    end
    # inspect, not print: 1.8's Hash#to_s runs the values together.
    yaml_output = capture(ruby, "-ryaml", "-e", "print YAML.load('a: b').inspect", env: env).strip
    raise PackageError, "unexpected YAML output: #{yaml_output}" unless yaml_output.include?('"a"') && yaml_output.include?('"b"')
    assert_equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                 capture(ruby, "-ropenssl", "-e", "print OpenSSL::Digest::SHA256.hexdigest('')", env: env).strip)
    # URI.open is 2.5+; before that open-uri extends Kernel#open. rubygems.org rather than
    # google.com because the oldest openssl extensions don't send SNI.
    open_call = ruby_version >= Gem::Version.new("2.5") ? "URI.open" : "open"
    run ruby, "-ropen-uri", "-e", "#{open_call}('https://rubygems.org/') { |f| abort unless f.status.first == '200' }", env: env
    if bundled_gems?
      requires = %w[portable_ruby_gems fiddle bootsnap]
      requires << "debug" if ruby_version >= Gem::Version.new("3.1")
      run ruby, "-rrbconfig", "-e", "Gem.discover_gems_on_require = false if Gem.respond_to?(:discover_gems_on_require=); #{requires.map { |r| "require '#{r}'" }.join("; ")}", env: env
    elsif ruby_version >= Gem::Version.new("1.9")
      run ruby, "-rfiddle", "-rbigdecimal", "-rjson", "-rdate", "-rsocket", "-rdigest/sha2", "-e", "true", env: env
    end
    run gem, "environment", env: env
    run bundle, "init", cwd: File.dirname(test_root), env: env
    run ruby, File.join(test_root, "bin", "ri"), "-T", "-f", "markdown", "Object", env: env if @series["install_doc"]
    if @series["test"] == "modern"
      run gem, "install", "byebug", env: env
      run File.join(test_root, "bin", "byebug"), "--version", env: env
      install_default_native_gem(ruby, "openssl", env)
      install_default_native_gem(ruby, "psych", env)
      run gem, "install", "ruby-lsp", env: env
    elsif (native = @series["test_native_gem"])
      # A C extension that supports this Ruby, to prove native gems still build once the
      # tree has moved: the compiler must find the bundled headers and static libraries.
      no_doc = capture(gem, "--version", env: env).strip.start_with?("1.") ? %w[--no-ri --no-rdoc] : %w[--no-document]
      run gem, "install", native.fetch("name"), "-v", native.fetch("version"), *no_doc, env: env
      # From -e, not -r: on 1.8 the command-line -r bypasses RubyGems' require and can't
      # see installed gems.
      run ruby, "-e", "require 'rubygems'; require '#{native.fetch("require", native.fetch("name"))}'", env: env
    end
    check_no_homebrew_paths!(test_root, ruby, env)
    check_linkage!(test_root) if linux?
    check_abi!(test_root) if linux?
  end

  # Nothing in the tree may need a shared library that isn't part of glibc. This is the
  # static-linking promise, checked rather than assumed.
  def check_linkage!(root)
    # libanl (getaddrinfo_a, wanted by socket.so) is glibc too: separate before 2.34, a
    # compatibility stub after.
    allowed = /\A(linux-vdso|ld-linux[^ ]*|libc|libm|libpthread|libdl|librt|libcrypt|libgcc_s|libresolv|libutil|libnsl|libanl)\.so/
    offenders = []
    Dir.glob(File.join(root, "**", "*")).each do |path|
      next unless File.file?(path)
      kind = capture("file", path)
      # Object files and static archives are ELF too, but have nothing to resolve.
      next unless kind.include?("ELF") && kind.include?("dynamically linked")

      capture("ldd", path, allow_failure: true).each_line do |line|
        lib = line.strip.split(/\s+/).first.to_s
        next if lib.empty? || lib =~ /\Alinux-vdso/
        next if File.basename(lib) =~ allowed
        offenders << "#{path.sub("#{root}/", "")} -> #{lib}"
      end
    end
    raise PackageError, "not portable, dynamic dependencies outside glibc:\n  #{offenders.uniq.join("\n  ")}" unless offenders.empty?
  end

  def install_default_native_gem(ruby, gem_name, env)
    version = capture(ruby, "-r#{gem_name}", "-e", "print Gem.loaded_specs.fetch(#{gem_name.dump}).version", env: env).strip
    run File.join(File.dirname(ruby), "gem"), "install", gem_name, "--version", version, "--force", env: env
  rescue PackageError
    Dir[File.join(File.dirname(ruby), "..", "lib", "ruby", "gems", "*", "extensions", "**", "#{gem_name}-#{version}", "mkmf.log")].each do |log|
      puts "==> #{log}"
      puts File.read(log)
    end
    raise
  end

  def check_no_homebrew_paths!(root, ruby, env)
    forbidden = %w[/home/linuxbrew/.linuxbrew /opt/homebrew /usr/local/Homebrew liblto_plugin.so]
    config = capture(ruby, "-rrbconfig", "-e", "puts((RbConfig::CONFIG.values + RbConfig::MAKEFILE_CONFIG.values).compact)", env: env)
    forbidden.each do |needle|
      raise PackageError, "RbConfig contains forbidden path #{needle}" if config.include?(needle)
    end
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if File.size(path) > 20 * 1024 * 1024
      begin
        body = File.binread(path)
      rescue
        next
      end
      forbidden.each do |needle|
        raise PackageError, "#{path} contains forbidden path #{needle}" if body.include?(needle)
      end
    end
  end

  def check_abi!(root)
    raise PackageError, "Linux ABI checks require readelf from binutils" unless find_executable("readelf")

    max = @target_recipe.fetch("max_glibc").split(".").map(&:to_i)
    Dir.glob(File.join(root, "**", "*")).each do |path|
      next unless File.file?(path)
      next unless capture("file", path).include?("ELF")

      versions = capture("readelf", "--version-info", path, allow_failure: true).scan(/GLIBC_(\d+)\.(\d+)/)
      versions.each do |major, minor|
        tuple = [major.to_i, minor.to_i]
        if (tuple <=> max) == 1
          raise PackageError, "#{path} requires GLIBC_#{tuple.join(".")}, above #{max.join(".")}"
        end
      end
    end
  end

  def package!
    run "chmod", "-R", "u+w", @install_prefix
    platform = @target_recipe.fetch("artifact_platform")
    yjit_tag = yjit ? "" : ".no_yjit"
    artifact = File.join(output_dir, "ruby-#{version}.#{platform}#{yjit_tag}.tar.gz")
    FileUtils.rm_f(artifact)
    run "tar", "-czf", artifact, "-C", @package_root, "ruby-#{version}"
    artifact
  end

  def download(name, recipe)
    uri = URI.parse(recipe.fetch("url"))
    filename = File.basename(uri.path)
    path = File.join(CACHE_DIR, filename)
    if File.file?(path) && Digest::SHA256.file(path).hexdigest == recipe.fetch("sha256")
      return path
    end

    FileUtils.rm_f(path)
    urls = [recipe["url"], recipe["mirror"]].compact
    urls.each_with_index do |url, index|
      begin
        run "curl", "-fL", "--retry", "3", "-o", path, url
        actual = Digest::SHA256.file(path).hexdigest
        raise PackageError, "#{name}: expected #{recipe.fetch("sha256")}, got #{actual}" unless actual == recipe.fetch("sha256")
        return path
      rescue PackageError
        FileUtils.rm_f(path)
        raise if index == urls.length - 1
      end
    end
  end

  def extract_source(name, recipe)
    archive = download(name, recipe)
    dest = File.join(@source_root, name)
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
    run "tar", "-xf", archive, "-C", dest
    children = Dir.children(dest)
    raise PackageError, "#{name}: archive did not extract to one directory" unless children.length == 1
    File.join(dest, children.first)
  end

  def run(*cmd, cwd: ROOT, env: {}, allow_failure: false)
    command = cmd.flatten.compact.map(&:to_s)
    pretty = command.shelljoin
    puts "==> #{pretty}"
    ok = system(clean_env(env), *command, chdir: cwd)
    return ok if ok || allow_failure
    raise PackageError, "Command failed: #{pretty}"
  end

  def capture(*cmd, env: {}, allow_failure: false)
    command = cmd.flatten.compact.map(&:to_s)
    output = IO.popen(clean_env(env), command, err: [:child, :out], &:read)
    status = $CHILD_STATUS
    if !status.success? && !allow_failure
      raise PackageError, "Command failed: #{command.shelljoin}\n#{output}"
    end
    output
  end

  def clean_env(env)
    merged = ENV.to_h.merge(env.compact)
    env.each_key { |key| merged.delete(key) if env[key].nil? }
    merged
  end

  def build_env(extra = {})
    {
      "PATH" => [File.join(@tools_prefix, "bin"), ENV["PATH"]].compact.join(File::PATH_SEPARATOR),
      "PKG_CONFIG" => pkgconf,
      "MAKEFLAGS" => "-j#{jobs}"
    }.merge(extra.reject { |_key, value| value.to_s.empty? })
  end

  def dependency_build_env(extra = {})
    flags = {}
    if linux?
      compile_flags = ["-fPIC"]
      compile_flags << "-mno-outline-atomics" if linux_arm64?
      flags["CFLAGS"] = [ENV["CFLAGS"], *compile_flags].compact.join(" ")
      flags["CXXFLAGS"] = [ENV["CXXFLAGS"], *compile_flags].compact.join(" ")
    end
    build_env(flags.merge(extra))
  end

  def make(cwd, *targets, env: build_env)
    run "make", *targets, cwd: cwd, env: env
  end

  def jobs
    @jobs ||= begin
      requested = ENV["JDX_RUBY_JOBS"].to_i
      requested > 0 ? requested : [Etc.respond_to?(:nprocessors) ? Etc.nprocessors : 2, 2].max
    end
  end

  def dep_prefix(name)
    @dep_prefixes[name] ||= File.join(@deps_root, name)
  end

  def pkgconf
    File.join(@tools_prefix, "bin", "pkgconf")
  end

  def ruby_bin
    File.join(@install_prefix, "bin", "ruby")
  end

  def linux?
    @target_recipe.fetch("os") == "linux"
  end

  def linux_arm64?
    linux? && target == "arm64_linux"
  end

  def macos?
    @target_recipe.fetch("os") == "macos"
  end

  def openssl_arch_args
    return ["linux-x86_64"] if target == "x86_64_linux"
    return ["linux-aarch64"] if target == "arm64_linux"
    return ["darwin64-arm64-cc", "enable-ec_nistp_64_gcc_128"] if host_machine.match?(/\A(?:arm64|aarch64)\z/)
    ["darwin64-x86_64-cc", "enable-ec_nistp_64_gcc_128"]
  end

  def host_machine
    @host_machine ||= `uname -m`.strip
  end

  def link_file(src, dest)
    return unless File.exist?(src)
    FileUtils.ln_sf(src, dest)
  end

  def find_executable(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      File.executable?(File.join(dir, name))
    end
  end

  def inreplace(path, before, after)
    content = File.read(path)
    raise PackageError, "#{path}: pattern not found" unless content.include?(before)
    File.write(path, content.gsub(before) { after })
  end

  def assert_equal(expected, actual)
    raise PackageError, "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def patch_openssl_cert_lookup(source)
    path = File.join(source, "crypto", "x509", "x509_def.c")
    inreplace(path, <<~'ORIG'.chomp, <<~'PATCHED'.chomp)
      #include "internal/e_os.h"
    ORIG
      #include "internal/e_os.h"
      #include <unistd.h>
    PATCHED

    inreplace(path, <<~'ORIG'.chomp, <<~'PATCHED'.chomp)
      const char *X509_get_default_cert_file(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_fileptr;
      #else
          return X509_CERT_FILE;
      #endif
      }
    ORIG
      const char *X509_get_default_cert_file(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_fileptr;
      #else
          const char *jdx_cert_file = ossl_safe_getenv("JDX_RUBY_SSL_CERT_FILE");
          if (jdx_cert_file != NULL && jdx_cert_file[0] != '\0' && access(jdx_cert_file, R_OK) == 0)
              return jdx_cert_file;
          static const char *system_cert_files[] = {
              "/etc/ssl/certs/ca-certificates.crt",
              "/etc/pki/tls/certs/ca-bundle.crt",
              "/etc/ssl/ca-bundle.pem",
              "/etc/ssl/cert.pem",
              NULL
          };
          for (int i = 0; system_cert_files[i] != NULL; i++) {
              if (access(system_cert_files[i], R_OK) == 0)
                  return system_cert_files[i];
          }
          return X509_CERT_FILE;
      #endif
      }
    PATCHED

    inreplace(path, <<~'ORIG'.chomp, <<~'PATCHED'.chomp)
      const char *X509_get_default_cert_dir(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_dirptr;
      #else
          return X509_CERT_DIR;
      #endif
      }
    ORIG
      const char *X509_get_default_cert_dir(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_dirptr;
      #else
          const char *jdx_cert_dir = ossl_safe_getenv("JDX_RUBY_SSL_CERT_DIR");
          if (jdx_cert_dir != NULL && jdx_cert_dir[0] != '\0' && access(jdx_cert_dir, R_OK) == 0)
              return jdx_cert_dir;
          static const char *system_cert_dirs[] = {
              "/etc/ssl/certs",
              "/etc/pki/tls/certs",
              NULL
          };
          for (int i = 0; system_cert_dirs[i] != NULL; i++) {
              if (access(system_cert_dirs[i], R_OK) == 0)
                  return system_cert_dirs[i];
          }
          return X509_CERT_DIR;
      #endif
      }
    PATCHED
  end
end

begin
  PortableRubyPackage.new(PortableRubyPackage.parse!(ARGV)).run!
rescue PackageError => e
  warn "error: #{e.message}"
  exit 1
end
