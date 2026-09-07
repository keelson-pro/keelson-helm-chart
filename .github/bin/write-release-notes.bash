#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Keelson contributors (Fred Cooke)
#
# Phase 3, via build-and-publish-chart.bash.
#
# Writes the GitHub Release notes, naming the OCI chart instead of leaving the
# reader to guess. Prose is src/release-notes.md; this fills in the version, the
# pins and the URLs, so they cannot drift. KaptainPM points notesFile here.

set -euo pipefail

: "${VERSION:?VERSION is required (set by the versions-and-naming build step)}"
: "${PROJECT_NAME:?PROJECT_NAME is required (set by the build)}"
: "${DOCKER_TARGET_REGISTRY:?DOCKER_TARGET_REGISTRY is required (set by the build)}"
: "${REPOSITORY_OWNER:?REPOSITORY_OWNER is required (set by the build)}"
: "${REPOSITORY_NAME:?REPOSITORY_NAME is required (set by the build)}"

OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

HELM_BUILD_DIR="${OUTPUT_SUB_PATH%/}/helm-build"
NOTES_FILE="${HELM_BUILD_DIR}/release-notes.md"

KEELSON_PIN=$(grep -E '^[0-9]+\.[0-9]+$' src/upstream/KeelsonVersion)
ARGO_PIN=$(grep -E '^[0-9]+\.[0-9]+$' src/upstream/KeelsonArgoRolloutsRbacVersion)
FOREIGN_PIN=$(grep -E '^[0-9]+\.[0-9]+$' src/upstream/KeelsonForeignNsRbacVersion)

# The same reference publish-chart-oci.bash pushes to, empty namespace included.
CHART_PREFIX="${PROJECT_NAME%%-*}"
CHART_REF="${DOCKER_TARGET_REGISTRY}/${DOCKER_TARGET_NAMESPACE:+${DOCKER_TARGET_NAMESPACE}/}helm-charts/${CHART_PREFIX}/${PROJECT_NAME}/keelson"

# Same Pages URL publish-chart-index.bash writes index.yaml to.
PAGES_OWNER="${REPOSITORY_OWNER}"
PAGES_REPO="${REPOSITORY_NAME}"

NOTES_SOURCE="src/release-notes.md"
if [[ ! -f "${NOTES_SOURCE}" ]]; then
    printf 'Release notes source not found: %s\n' "${NOTES_SOURCE}" >&2
    exit 1
fi

mkdir -p "${HELM_BUILD_DIR}"
sed -e "s|@VERSION@|${VERSION}|g" \
    -e "s|@KEELSON_PIN@|${KEELSON_PIN}|g" \
    -e "s|@ARGO_PIN@|${ARGO_PIN}|g" \
    -e "s|@FOREIGN_PIN@|${FOREIGN_PIN}|g" \
    -e "s|@CHART_REF@|${CHART_REF}|g" \
    -e "s|@PAGES_URL@|https://${PAGES_OWNER}.github.io/${PAGES_REPO}|g" \
    "${NOTES_SOURCE}" > "${NOTES_FILE}"

if grep -n '@[A-Z_]*@' "${NOTES_FILE}" >&2; then
    printf 'Unsubstituted token left in the release notes (above).\n' >&2
    exit 1
fi

printf 'Wrote %s\n' "${NOTES_FILE}"
