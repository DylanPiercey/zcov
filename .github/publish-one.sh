#!/usr/bin/env bash
# Publishes one package directory, unless that exact version is already on the
# registry. Releases are otherwise all-or-nothing: a network failure halfway
# through ten packages leaves a rerun dead on the first one it already sent.
set -euo pipefail

# `./` matters: npm reads a bare `a/b` as a GitHub shorthand, not a directory,
# and goes looking for github.com/a/b instead of publishing the folder.
dir="./${1#./}"
name="$(node -p "require('./$dir/package.json').name")"
version="$(node -p "require('./$dir/package.json').version")"

if npm view "$name@$version" version >/dev/null 2>&1; then
  echo "  $name@$version is already published, skipping"
  exit 0
fi

# An account with 2FA needs a one-time password to publish, which only a human
# has. In CI the trusted publisher authenticates instead, and signs provenance
# without being asked, so neither this nor a token is set there.
otp=()
if [ -n "${NPM_OTP:-}" ]; then otp=(--otp "$NPM_OTP"); fi

echo "  publishing $name@$version"
npm publish "$dir" --access public "${otp[@]}"
