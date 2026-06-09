# Zettlab Homebrew Tap

Public Homebrew tap for Zettlab internal CLI distribution.

This repository stores Homebrew formula metadata and the bootstrap installer
only. It does not store private binaries, service credentials, or Zettlab
business source code.

## Install zettlab-publish

`zettlab-publish` binaries are published as private Release Assets in
`zettlab/zettlab-server`. Set a GitHub token that can read that repository
before installing or upgrading.

```bash
export HOMEBREW_GITHUB_API_TOKEN=<github-token-with-zettlab-server-read>
brew tap zettlab/tap
brew install zettlab-publish
zettlab-publish version
```

Upgrade:

```bash
export HOMEBREW_GITHUB_API_TOKEN=<github-token-with-zettlab-server-read>
brew update
brew upgrade zettlab-publish
```

## One-shot Installer

Use this path for machines without Homebrew, Linux workstations, or temporary
bootstrap.

```bash
export GITHUB_TOKEN=<github-token-with-zettlab-server-read>
curl -fsSL https://raw.githubusercontent.com/zettlab/homebrew-tap/main/install.sh | bash
zettlab-publish version
```

Pin a specific CLI release:

```bash
export GITHUB_TOKEN=<github-token-with-zettlab-server-read>
curl -fsSL https://raw.githubusercontent.com/zettlab/homebrew-tap/main/install.sh \
  | ZETTLAB_PUBLISH_TAG=publish-cli/v0.1.0 bash
```

## Release Ownership

Do not edit `Formula/zettlab-publish.rb` by hand for normal releases. It is
updated by GoReleaser from `zettlab/zettlab-server` when a
`publish-cli/v*` tag is pushed.

`install.sh` is sourced from `zettlab-server/hack/install/install.sh`; keep the
two copies aligned when changing installer behavior.
