# frozen_string_literal: true

require "download_strategy"
require "json"
require "uri"

class ZettlabPrivateReleaseDownloadStrategy < CurlDownloadStrategy
  GITHUB_RELEASE_ASSET_URL = %r{\Ahttps://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/?#]+)}.freeze

  def initialize(url, name, version, **meta)
    token = self.class.github_token
    headers = Array(meta[:headers]).reject { |header| header.match?(/\AAuthorization:\s*bearer\s*\z/i) }
    headers << "Accept: application/octet-stream" unless headers.any? { |header| header.start_with?("Accept:") }
    headers << "Authorization: Bearer #{token}" unless token.empty? || headers.any? { |header| header.start_with?("Authorization:") }
    meta[:headers] = headers
    super
  end

  def _fetch(url:, resolved_url:, timeout:)
    api_url = asset_api_url(url, timeout: timeout)
    ohai "Downloading private GitHub release asset via API"
    _curl_download api_url, temporary_path, timeout
  rescue ErrorDuringExecution => e
    raise CurlDownloadStrategyError.new(url, e.stderr.strip)
  end

  private

  def self.github_token
    ENV.fetch("HOMEBREW_GITHUB_API_TOKEN", "").empty? ? ENV.fetch("GITHUB_TOKEN", "") : ENV.fetch("HOMEBREW_GITHUB_API_TOKEN")
  end

  def github_token
    token = self.class.github_token
    return token unless token.empty?

    raise CurlDownloadStrategyError.new(url, "set HOMEBREW_GITHUB_API_TOKEN to a GitHub token that can read zettlab/zettlab-server")
  end

  def asset_api_url(release_url, timeout:)
    match = release_url.match(GITHUB_RELEASE_ASSET_URL)
    raise CurlDownloadStrategyError.new(release_url, "unsupported private GitHub release URL") unless match

    owner, repo, tag, asset_name = match.captures
    asset_name = URI.decode_www_form_component(asset_name)
    curl_args = [
        Utils::Curl.curl_executable.to_s,
        "--disable",
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--header",
        "Authorization: Bearer #{github_token}",
        "--header",
        "Accept: application/vnd.github+json",
        "https://api.github.com/repos/#{owner}/#{repo}/releases/tags/#{tag}",
    ]
    curl_args.insert(6, "--max-time", timeout.to_s) if timeout

    release = JSON.parse(Utils.safe_popen_read(*curl_args))
    asset = release.fetch("assets", []).find { |item| item.fetch("name", nil) == asset_name }
    raise CurlDownloadStrategyError.new(release_url, "release #{tag} has no asset #{asset_name}") unless asset

    asset.fetch("url")
  end
end
