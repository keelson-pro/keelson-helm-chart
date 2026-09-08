#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Keelson contributors (Fred Cooke)
#
# Phase 4, via build-and-publish-chart.bash.
#
# Maintains index.yaml on gh-pages, the classic Helm repo.
#
# Everything up to the commit runs every build, so a PR exercises the clone, the
# merge and the commit. Only the push is gated, on IS_RELEASE and BUILD_MODE.
#
# The .tgz is not committed: index.yaml points at the GitHub Release asset, whose
# URL comes from $VERSION, so nothing has to fire after the release attach.
#
# With no gh-pages branch this bootstraps one as an orphan, seeded from
# src/pages-README.md. Enable GitHub Pages once afterwards.

set -euo pipefail

: "${VERSION:?VERSION is required (set by the versions-and-naming build step)}"
: "${REPOSITORY_OWNER:?REPOSITORY_OWNER is required (set by the build)}"
: "${REPOSITORY_NAME:?REPOSITORY_NAME is required (set by the build)}"

# Defaulted only so a direct call lands somewhere sane; real builds always set it.
OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"

BUILD_MODE="${BUILD_MODE:-local}"
IS_RELEASE="${IS_RELEASE:-false}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v helm >/dev/null 2>&1; then
    printf 'helm not found on PATH - required for repo index\n' >&2
    exit 1
fi

# Publishing needs both: a real release, and a build server to do it from.
PUBLISH=false
if [[ "${IS_RELEASE}" == "true" && "${BUILD_MODE}" == "build_server" ]]; then
    PUBLISH=true
fi

GITHUB_REPOSITORY="${REPOSITORY_OWNER}/${REPOSITORY_NAME}"

GH_AUTH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ "${PUBLISH}" == "true" && -z "${GH_AUTH_TOKEN}" ]]; then
    printf 'GH_TOKEN or GITHUB_TOKEN is required to push gh-pages on a release build.\n' >&2
    exit 1
fi

# Absolute, because we cd into the gh-pages clone below.
if [[ "${OUTPUT_SUB_PATH}" == /* ]]; then
    OUTPUT_ABS="${OUTPUT_SUB_PATH%/}"
else
    OUTPUT_ABS="${REPO_ROOT}/${OUTPUT_SUB_PATH%/}"
fi
HELM_BUILD_DIR="${OUTPUT_ABS}/helm-build"
UNVERSIONED_TGZ="${OUTPUT_ABS}/chart-release/keelson.tgz"
if [[ ! -f "${UNVERSIONED_TGZ}" ]]; then
    printf 'Expected unversioned tgz not found at %s\n' "${UNVERSIONED_TGZ}" >&2
    printf 'package-chart.bash should run before this script.\n' >&2
    exit 1
fi

# Kept: the clone and its index are what you read when a publish misbehaves.
WORK="${HELM_BUILD_DIR}/gh-pages-publish"
rm -rf "${WORK}"
mkdir -p "${WORK}"

PAGES_REPO="${WORK}/clone"
if [[ -n "${GH_AUTH_TOKEN}" ]]; then
    REMOTE_URL="https://x-access-token:${GH_AUTH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
else
    # Anonymous clone - fine for the dry run against a public repo.
    REMOTE_URL="https://github.com/${GITHUB_REPOSITORY}.git"
fi

PAGES_URL="https://${REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME}"

printf '== publish-chart-index: gh-pages workspace at %s ==\n' "${PAGES_REPO}"
printf '   IS_RELEASE=%s BUILD_MODE=%s -> %s\n' \
    "${IS_RELEASE}" "${BUILD_MODE}" \
    "$([[ "${PUBLISH}" == "true" ]] && printf 'PUBLISH' || printf 'dry run (no push)')"

# Asked, not inferred from a failed clone: index.yaml is the only record of every
# version published, and bootstrapping starts an empty one. A network blip must
# not look like "no branch yet".
if ! REMOTE_HEADS="$(git ls-remote --heads "${REMOTE_URL}" gh-pages)"; then
    printf 'Could not reach %s to check for the gh-pages branch.\n' "${GITHUB_REPOSITORY}" >&2
    printf 'Refusing to continue: bootstrapping now could discard the published index.\n' >&2
    exit 1
fi

if [[ -n "${REMOTE_HEADS}" ]]; then
    git clone --quiet --depth 1 --branch gh-pages "${REMOTE_URL}" "${PAGES_REPO}"
    cd "${PAGES_REPO}"
    printf 'Cloned existing gh-pages branch.\n'
else
    git clone --quiet --depth 1 "${REMOTE_URL}" "${PAGES_REPO}"
    cd "${PAGES_REPO}"
    printf 'gh-pages branch does not exist on the remote - bootstrapping as orphan.\n'
    git checkout --quiet --orphan gh-pages
    git rm --quiet -rf .
    printf '# Turns off Jekyll so Pages serves this branch as committed.\n' > .nojekyll
    sed "s|@PAGES_URL@|${PAGES_URL}|g" "${REPO_ROOT}/src/pages-README.md" > README.md
fi

# Rewritten every run, not just at bootstrap, so a fix to it reaches a branch
# that already exists. Pages serves the branch raw, so without this the site is
# a 404 and the README a download.
cp "${REPO_ROOT}/src/pages-index.html" index.html

# Staged under its release-asset filename so helm repo index can checksum it.
# Not committed: the release holds it, index.yaml points at its URL.
TGZ_STAGE="${WORK}/stage"
mkdir -p "${TGZ_STAGE}"
RELEASE_TGZ_NAME="keelson-${VERSION}.tgz"
cp "${UNVERSIONED_TGZ}" "${TGZ_STAGE}/${RELEASE_TGZ_NAME}"

URL_BASE="https://github.com/${GITHUB_REPOSITORY}/releases/download/${VERSION}"

printf '== helm repo index ==\n'
if [[ -f index.yaml ]]; then
    helm repo index "${TGZ_STAGE}" --url "${URL_BASE}" --merge index.yaml
else
    helm repo index "${TGZ_STAGE}" --url "${URL_BASE}"
fi
cp "${TGZ_STAGE}/index.yaml" index.yaml

git config user.email 'keelson-bot@users.noreply.github.com'
git config user.name 'keelson-bot'

git add .nojekyll README.md index.html index.yaml
if git diff --cached --quiet; then
    printf 'No changes to gh-pages - nothing to publish.\n'
    exit 0
fi

git commit --quiet -m "Publish chart ${VERSION} to index.yaml"

if [[ "${PUBLISH}" != "true" ]]; then
    printf '\n== dry run - gh-pages commit prepared but NOT pushed ==\n'
    git --no-pager show --stat --oneline HEAD
    printf '\nWould publish chart %s at %s\n' "${VERSION}" "${URL_BASE}/${RELEASE_TGZ_NAME}"
    exit 0
fi

git push --quiet origin gh-pages
printf 'Pushed updated index.yaml for chart %s.\n' "${VERSION}"
