#!/usr/bin/env ruby
# frozen_string_literal: true

# Print a Ruby version's effective series settings as key=value lines, for workflows that
# need to know things like whether the series has a yjit variant. Same merge as package.rb.
require "yaml"

ROOT = File.expand_path("..", __dir__)

def load_yaml(path)
  YAML.safe_load(File.read(File.join(ROOT, path)), permitted_classes: [], aliases: false)
end

def deep_merge(left, right)
  left.merge(right) do |_key, old_value, new_value|
    old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
  end
end

version = ARGV.fetch(0) { abort "Usage: bin/recipe-info VERSION [KEY...]" }
keys = ARGV.drop(1)

rubies = load_yaml("recipes/rubies.yml").fetch("rubies")
series_doc = load_yaml("recipes/series.yml")
recipe = rubies.fetch(version) { abort "Unknown Ruby version: #{version}" }
series = deep_merge(series_doc.fetch("defaults"), series_doc.fetch("series").fetch(recipe.fetch("series")) || {})

settings = {
  "series" => recipe.fetch("series"),
  "legacy" => series["test"] == "legacy",
  "yjit" => !!series["yjit"]
}
settings.each do |key, value|
  next unless keys.empty? || keys.include?(key)
  puts "#{key}=#{value}"
end
