#!/usr/bin/env bash
# Zettlab Publish CLI -- one-shot installer.
#
# Source of truth lives at hack/install/install.sh in zettlab-server.
# Every CLI release uploads this same file as a Release Asset (alongside
# the binaries) AND adds it to checksums.txt so its integrity can be
# verified after download.
#
# Operator-facing canonical URL:
#
#   curl -fsSL https://raw.githubusercontent.com/zettlab/homebrew-tap/main/install.sh | bash
#
# Release assets are public in zettlab/homebrew-tap. GITHUB_TOKEN remains
# optional for API rate-limit relief, but operators do not need any GitHub
# token to install.
#
# Dependencies: bash >= 3.2 (macOS default /bin/bash works -- we keep
# the script free of associative arrays (`declare -A`, bash 4+) and
# `[[ var =~ regex ]]` so the macOS-native bash 3.2 runs the same
# path as linux bash 4+. Process substitution `< <(...)` IS used (e.g.
# `locate_binary` reads find output that way); it has been supported
# since bash 2.04 and runs fine on macOS bash 3.2. opus round 4 P3
# corrected the old comment that promised bash >= 4 -- not true and
# not enforced; round 5 P1-B clarified the process-substitution
# exemption.), curl >= 7.86, tar, sha256sum or shasum, and jq
# (required -- parsing GitHub's JSON with awk is too fragile across
# BSD awk / gawk / busybox awk; opus review 2026-06-02 round 2
# P1.1+P1.2).

set -euo pipefail

REPO_OWNER="zettlab"
REPO_NAME="homebrew-tap"
BINARY_NAME="zettlab-publish"
INSTALL_DIR_PRIMARY="/usr/local/bin"
INSTALL_DIR_FALLBACK="${HOME}/.local/bin"
CURL_MIN_VERSION="7.86"

# tmpdir is global so the EXIT trap below can see it (a `local` inside
# main() goes out of scope before EXIT fires, leaving the cleanup as
# a silent no-op -- the r4/r5 trap saga). main() assigns this when it
# creates the download workspace. Empty default keeps `set -u` happy
# in the trap body if main() never gets that far.
tmpdir=""
cleanup_tmpdir() {
  if [ -n "${tmpdir}" ] && [ -d "${tmpdir}" ]; then
    rm -rf "${tmpdir}"
  fi
}
# Trap covers EXIT plus the common signals that bypass EXIT -- so a
# SIGTERM from a parent supervisor doesn't leave the tmpdir behind.
trap cleanup_tmpdir EXIT INT TERM

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
info()  { printf "==> %s\n" "$*"; }
warn()  { printf "\033[33m==> warn:\033[0m %s\n" "$*" >&2; }
fatal() { printf "\033[31m==> error:\033[0m %s\n" "$*" >&2; exit 1; }

# with_silenced_trace runs the given command-line with trace disabled
# (so `bash -x install.sh` never echoes the PAT), then restores trace
# to its prior state. The previous `silence_trace` helper just called
# `set +x` once and left trace off for the rest of the script — that
# meant the very first download disabled tracing for everything after
# (verify, extract, install), defeating operator debugging.
# (opus round 3 P2-A.)
with_silenced_trace() {
  local _was_x=0
  case $- in
    *x*) _was_x=1 ;;
  esac
  { set +x; } 2>/dev/null
  "$@"
  local _rc=$?
  if [ "${_was_x}" = "1" ]; then
    set -x
  fi
  return ${_rc}
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fatal "$1 not found on PATH ($2)"
}

require_min_curl() {
  local v
  v="$(curl --version 2>/dev/null | head -n 1 | awk '{print $2}')"
  [ -n "${v}" ] || fatal "could not parse curl version"
  # version-sort: if min sorts after current, current is too old
  local newest
  newest="$(printf "%s\n%s\n" "${v}" "${CURL_MIN_VERSION}" | sort -V | tail -n 1)"
  if [ "${newest}" != "${v}" ]; then
    fatal "curl >= ${CURL_MIN_VERSION} required when GITHUB_TOKEN is set (found ${v}); needed for safe cross-host redirect Authorization stripping"
  fi
}

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "${os}" in
    darwin|linux) ;;
    *) fatal "unsupported OS: ${os} (mac and linux only)" ;;
  esac
  case "${arch}" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) fatal "unsupported arch: ${arch} (amd64 and arm64 only)" ;;
  esac
  printf "%s_%s" "${os}" "${arch}"
}

# resolve_install_dir picks /usr/local/bin if it can be created and is
# writable; otherwise ~/.local/bin. Captures the mkdir error so the
# warn message is diagnosable. (opus review round 2 P2.)
resolve_install_dir() {
  local dir mkdir_err
  for dir in "${INSTALL_DIR_PRIMARY}" "${INSTALL_DIR_FALLBACK}"; do
    mkdir_err="$(mkdir -p "${dir}" 2>&1)" && [ -w "${dir}" ] && {
      if [ "${dir}" = "${INSTALL_DIR_FALLBACK}" ]; then
        warn "${INSTALL_DIR_PRIMARY} not writable; installing to ${INSTALL_DIR_FALLBACK}"
        warn "make sure ${INSTALL_DIR_FALLBACK} is on your \$PATH"
      fi
      printf "%s" "${dir}"
      return 0
    } || warn "${dir} not usable: ${mkdir_err:-not writable}"
  done
  fatal "no writable install directory among: ${INSTALL_DIR_PRIMARY}, ${INSTALL_DIR_FALLBACK}"
}

# GET helper for GitHub release downloads and metadata. If GITHUB_TOKEN is
# present, it is used for rate-limit relief and never required for normal
# operator installs.
curl_get() {
  local url="$1"
  local accept="$2"
  local out="$3"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    with_silenced_trace curl --fail --silent --show-error --location \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: ${accept}" \
      --output "${out}" "${url}"
  else
    curl --fail --silent --show-error --location \
      -H "Accept: ${accept}" \
      --output "${out}" "${url}"
  fi
}

api_get_json() {
  local url="$1"
  local out="$2"
  curl_get "${url}" "application/vnd.github+json" "${out}"
}

# resolve_latest_publish_cli_tag walks /releases (not /releases/latest)
# and picks the newest non-draft, non-prerelease CLI release whose tag is
# a plain semver `vX.Y.Z`. GoReleaser OSS requires semver tags, so the
# older prefixed `publish-cli/vX.Y.Z` shape is intentionally rejected.
# (opus review round 2 P2.)
resolve_latest_publish_cli_tag() {
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  api_get_json "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases?per_page=100" "${tmp}" \
    || fatal "could not query GitHub Releases from ${REPO_OWNER}/${REPO_NAME}"
  # Reverse-chronological order is GitHub's default; jq's `first(...)`
  # short-circuits inside the filter so we never need a `| head -n 1`
  # downstream. The previous form was vulnerable to SIGPIPE under
  # `set -o pipefail` once tag_name list filled the pipe buffer.
  # (opus round 3 P1-B.)
  # Filter out draft + prerelease so a stray `v0.2.0-rc1`
  # uploaded by an operator doesn't auto-install via the no-tag path.
  # If someone really wants the RC they pass ZETTLAB_PUBLISH_TAG
  # explicitly. (opus round 4 P2.)
  jq -r 'first(.[] | select(.draft == false and .prerelease == false) | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | .tag_name) // empty' "${tmp}"
}

# resolve_asset_api_url returns the api.github.com asset URL for a
# named asset on the given tag. Asset API URLs serve bytes via 302 to
# release-assets.githubusercontent.com -- curl's default --location
# strips Authorization on the cross-host hop (curl >= 7.86, enforced
# above).
resolve_asset_api_url() {
  local tag="$1"
  local asset_name="$2"
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  api_get_json "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/tags/${tag}" "${tmp}" \
    || fatal "could not look up release for tag ${tag}"
  jq -r --arg name "${asset_name}" '.assets[] | select(.name == $name) | .url' "${tmp}"
}

verify_checksum() {
  local archive="$1"
  local checksums="$2"
  local archive_basename
  archive_basename="$(basename "${archive}")"
  local expected
  expected="$(awk -v f="${archive_basename}" '$2==f{print $1; exit}' "${checksums}")"
  if [ -z "${expected}" ]; then
    fatal "no checksum entry for ${archive_basename}"
  fi
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${archive}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  else
    fatal "neither sha256sum nor shasum is available"
  fi
  if [ "${expected}" != "${actual}" ]; then
    fatal "checksum mismatch for ${archive_basename}: expected ${expected}, got ${actual}"
  fi
}

# locate_binary uses portable octal `-perm -100` (owner-exec bit) so
# BSD find / gnu find / busybox find all agree. Avoids `find | head`
# pipe to keep set -o pipefail from interpreting SIGPIPE as failure.
# (opus review round 2 P1.4 + P1.5.)
locate_binary() {
  # Renamed from `tmpdir` to `search_root` to avoid shadowing the
  # global `tmpdir` -- harmless in practice (callers pass the same
  # value) but reads cleaner. (opus round 6 P3-1.)
  local search_root="$1"
  local found=""
  local f
  while IFS= read -r -d '' f; do
    if [ -z "${found}" ]; then
      found="${f}"
    fi
  done < <(find "${search_root}" -type f -name "${BINARY_NAME}" -perm -100 -print0 2>/dev/null)
  if [ -z "${found}" ]; then
    fatal "archive did not contain an executable ${BINARY_NAME}"
  fi
  printf "%s" "${found}"
}

main() {
  require_tool curl "needed to download release assets"
  require_tool tar "needed to extract the binary archive"
  require_tool jq "needed to parse GitHub Releases API JSON; install via brew/apt/yum"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    require_min_curl
  fi

  local tag="${ZETTLAB_PUBLISH_TAG:-}"
  if [ -z "${tag}" ]; then
    info "resolving latest zettlab-publish release tag from GitHub"
    tag="$(resolve_latest_publish_cli_tag)"
  fi
  [ -n "${tag}" ] || fatal "could not resolve a vX.Y.Z CLI release tag; set ZETTLAB_PUBLISH_TAG=vX.Y.Z and retry"
  if ! printf "%s\n" "${tag}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
    fatal "refusing to install tag ${tag} -- only semver CLI release tags like v0.1.0 are valid"
  fi
  # goreleaser's .Version strips the leading `v`, so the archive name
  # contains the bare semver (e.g. 0.1.0, not v0.1.0). Match that here.
  # (opus review round 2 P1.3.)
  local version="${tag#v}"
  info "installing zettlab-publish ${version}"

  local platform
  platform="$(detect_platform)"
  # Archive name pattern echoed exactly from .goreleaser.yaml's
  # archives.name_template (uses {{ .Version }}). Change one, change
  # the other.
  local archive_name="zettlab-publish_${version}_${platform}.tar.gz"

  # tmpdir is a GLOBAL on purpose -- the EXIT trap (registered at
  # script top, not inside main) fires AFTER main() returns and any
  # `local` would have already been torn down, expanding to the empty
  # string. The r4 fix `${tmpdir:-}` silenced the set -u "unbound
  # variable" error but left `rm -rf ""` as a no-op, meaning every
  # install leaked a `/tmp/zettlab-publish.XXXXXX/` directory with
  # the downloaded archive + extracted binary. Promoting to global
  # makes the trap see the real path. (opus round 5 P1-A.)
  tmpdir="$(mktemp -d -t zettlab-publish.XXXXXX)"

  info "downloading ${archive_name}"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    local archive_url
    archive_url="$(resolve_asset_api_url "${tag}" "${archive_name}")"
    [ -n "${archive_url}" ] || fatal "release ${tag} has no asset ${archive_name}"
    curl_get "${archive_url}" "application/octet-stream" "${tmpdir}/${archive_name}"
  else
    curl_get "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/${archive_name}" \
      "*/*" "${tmpdir}/${archive_name}"
  fi

  info "downloading checksums.txt"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    local checksums_url
    checksums_url="$(resolve_asset_api_url "${tag}" "checksums.txt")"
    [ -n "${checksums_url}" ] || fatal "release ${tag} has no asset checksums.txt"
    curl_get "${checksums_url}" "application/octet-stream" "${tmpdir}/checksums.txt"
  else
    curl_get "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/checksums.txt" \
      "*/*" "${tmpdir}/checksums.txt"
  fi

  info "verifying sha256"
  verify_checksum "${tmpdir}/${archive_name}" "${tmpdir}/checksums.txt"

  info "extracting"
  tar -C "${tmpdir}" -xzf "${tmpdir}/${archive_name}"
  local binary_path
  binary_path="$(locate_binary "${tmpdir}")"
  chmod +x "${binary_path}"

  local install_dir target
  install_dir="$(resolve_install_dir)"
  target="${install_dir}/${BINARY_NAME}"
  info "installing to ${target}"
  mv "${binary_path}" "${target}"

  bold "[ok] zettlab-publish ${version} installed at ${target}"
  "${target}" version || true
}

main "$@"
