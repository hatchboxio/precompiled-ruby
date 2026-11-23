#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "yaml"

# Bumps the gems staged into every portable Ruby (recipes/series.yml bundled_gems) to the
# newest stable release that is safe for the series:
#
# - same major version as the pinned one, so a breaking release is a manual bump
# - required_ruby_version satisfied by the oldest Ruby the entry applies to
# - platform "ruby" only (the source gem, never the java one)
#
# Prints one line per bump and rewrites recipes/series.yml in place. Adapted from jdx/ruby.
class UpdateBundledGems
  ROOT = File.expand_path("..", __dir__)
  SERIES_PATH = File.join(ROOT, "recipes", "series.yml")

  Entry = Struct.new(:series, :name, :line, :version, :min_ruby)

  def self.run!
    new.run!
  end

  def run!
    text = File.read(SERIES_PATH)
    lines = text.lines
    bumped = false

    entries(text, lines).each do |entry|
      latest = latest_for(entry)
      next if latest.nil? || latest.fetch("number") == entry.version

      version = latest.fetch("number")
      url = "https://rubygems.org/downloads/#{entry.name}-#{version}.gem"
      sha256 = Digest::SHA256.hexdigest(fetch(url))
      unless sha256 == latest.fetch("sha")
        abort "error: #{url} sha256 #{sha256} does not match rubygems.org metadata #{latest.fetch("sha")}"
      end

      indent = lines[entry.line][/\A\s*/]
      lines[entry.line] = "#{indent}version: #{version}\n"
      lines[entry.line + 1] = "#{indent}url: #{url}\n"
      lines[entry.line + 2] = "#{indent}sha256: #{sha256}\n"
      bumped = true
      puts "#{entry.name} #{entry.version} -> #{version} (#{entry.series})"
    end

    if bumped
      File.write(SERIES_PATH, lines.join)
    else
      puts "bundled gems are up to date"
    end
  end

  private

  # Every `name:` block under a bundled_gems key, with the oldest Ruby it applies to.
  def entries(text, lines)
    doc = YAML.safe_load(text, permitted_classes: [], aliases: false)
    section = nil

    lines.each_with_index.filter_map do |line, index|
      section = "defaults" if line.start_with?("defaults:")
      section = line[/\A  "(\d+\.\d+)":/, 1] || section
      next unless line.match?(/\A\s+[\w-]+:\s*\z/) && lines[index + 1].to_s.match?(/\A\s+version: /)
      next unless lines[index + 2].to_s.include?("rubygems.org/downloads/")

      name = line[/([\w-]+):/, 1]
      Entry.new(
        series: section,
        name: name,
        line: index + 1,
        version: lines[index + 1][/version: (\S+)/, 1],
        min_ruby: min_ruby(doc.fetch("series"), section, name)
      )
    end
  end

  # A series entry applies to its own series. The defaults apply to every series that neither
  # overrides the gem nor opts out of bundled gems (`bundled_gems: ~`, as Ruby 1.8-3.1 do).
  def min_ruby(series, section, name)
    return Gem::Version.new("#{section}.0") unless section == "defaults"

    inheriting = series.filter_map do |key, settings|
      gems = (settings || {}).fetch("bundled_gems", {})
      Gem::Version.new("#{key}.0") if gems && gems[name].nil?
    end
    abort "error: no series uses the default #{name}" if inheriting.empty?
    inheriting.min
  end

  # Cached per gem: a gem can have entries for the defaults and for series that pin their own.
  def releases(name)
    @releases ||= {}
    @releases[name] ||= JSON.parse(fetch("https://rubygems.org/api/v1/versions/#{name}.json"))
  end

  def latest_for(entry)
    major = Gem::Version.new(entry.version).segments.first
    candidates = releases(entry.name).select do |release|
      release.fetch("platform") == "ruby" && !release.fetch("prerelease") &&
        Gem::Version.new(release.fetch("number")).segments.first == major &&
        Gem::Requirement.new(*(release["ruby_version"] || ">= 0").split(",").map(&:strip)).satisfied_by?(entry.min_ruby)
    end
    candidates.max_by { |release| Gem::Version.new(release.fetch("number")) }
  end

  def fetch(url)
    response = Net::HTTP.get_response(URI(url))
    response = Net::HTTP.get_response(URI(response["location"])) while response.is_a?(Net::HTTPRedirection)
    abort "error: GET #{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    response.body
  end
end

UpdateBundledGems.run! if $PROGRAM_NAME == __FILE__
