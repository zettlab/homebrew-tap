# Zettlab Homebrew Tap

Public Homebrew tap for Zettlab internal CLI distribution.

This repository stores Homebrew formula metadata, public CLI release binaries,
and the bootstrap installer. It does not store service credentials or Zettlab
business source code.

## Install zettlab-publish

`zettlab-publish` binaries are published as public Release Assets in this tap.
Operators do not need a GitHub token to install or upgrade.

```bash
brew tap zettlab/tap
brew install zettlab-publish
zettlab-publish version
```

Upgrade:

```bash
brew update
brew upgrade zettlab-publish
```

## One-shot Installer

Use this path for machines without Homebrew, Linux workstations, or temporary
bootstrap.

```bash
curl -fsSL https://raw.githubusercontent.com/zettlab/homebrew-tap/main/install.sh | bash
zettlab-publish version
```

Pin a specific CLI release:

```bash
curl -fsSL https://raw.githubusercontent.com/zettlab/homebrew-tap/main/install.sh \
  | ZETTLAB_PUBLISH_TAG=v0.1.0 bash
```

## Release Ownership

Do not edit `Formula/zettlab-publish.rb` by hand for normal releases. It is
updated by GoReleaser from `zettlab/zettlab-server` when a
`v*` CLI release tag is pushed. GoReleaser OSS requires the git tag itself to
be valid semver, so CLI releases use tags like `v0.1.0`.

`install.sh` is sourced from `zettlab-server/hack/install/install.sh`; keep the
two copies aligned when changing installer behavior.
