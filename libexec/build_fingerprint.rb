#!/usr/bin/env ruby
# frozen_string_literal: true

# Print a digest of everything in this repository that determines what a Ruby version's
# build produces, so the release workflow can skip a rebuild when none of it changed.
# Covered: the version's recipe, its effective series settings (same merge as package.rb),
# every dependency's version and checksum, the release targets, the packaging script and
# the build workflow. Not covered: what the pinned containers, the Rust toolchain and the
# bootstrap Ruby resolve to at build time, so pass `force` to the release workflow when
# one of those is the reason to rebuild.
require "digest"
require "json"
require "yaml"

ROOT = File.expand_path("..", __dir__)

# Bump when the inputs below change shape, so older fingerprints never compare equal.
FORMAT = 1

HASHED_FILES = %w[
  libexec/package.rb
  .github/workflows/build.yml
].freeze

def load_yaml(path)
  YAML.safe_load_file(File.join(ROOT, path), permitted_classes: [], aliases: false)
end

def deep_merge(left, right)
  left.merge(right) do |_key, old_value, new_value|
    old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
  end
end

def canonical(value)
  case value
  when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, canonical(item)] }
  when Array then value.map { |item| canonical(item) }
  else value
  end
end

version = ARGV.fetch(0) { abort "Usage: bin/build-fingerprint VERSION" }

rubies = load_yaml("recipes/rubies.yml").fetch("rubies")
recipe = rubies.fetch(version) { abort "Unknown Ruby version: #{version}" }
series_doc = load_yaml("recipes/series.yml")
series = deep_merge(series_doc.fetch("defaults"), series_doc.fetch("series").fetch(recipe.fetch("series")) || {})
dependencies = load_yaml("recipes/dependencies.yml").fetch("dependencies").transform_values do |dependency|
  dependency.slice("version", "sha256")
end
targets = load_yaml("recipes/targets.yml").fetch("targets")
files = HASHED_FILES.to_h { |path| [path, Digest::SHA256.file(File.join(ROOT, path)).hexdigest] }

inputs = {
  "format" => FORMAT,
  "version" => version,
  "recipe" => recipe,
  "series" => series,
  "dependencies" => dependencies,
  "targets" => targets,
  "files" => files
}

puts "v#{FORMAT}-#{Digest::SHA256.hexdigest(JSON.generate(canonical(inputs)))}"
