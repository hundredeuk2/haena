#!/bin/bash
#
# Builds the benchmark harness and runs it over the Meeting Execution development split with the
# offline stub extractor.
#
# Offline by default and offline only: this script never passes --provider, --allow-network, or
# --i-accept-dataset-transfer. Sending the corpus to an external provider is a decision that has
# to be made deliberately at the command line, with the dataset's usage terms checked first — it
# must not be something a convenience script can do on your behalf.
#
# Nothing this produces is a score. Every case is emitted as `unscored` because no human has
# confirmed semantic gold yet, and a stub run says nothing at all about accuracy.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DATASET_ROOT="${REPO_ROOT}/data/benchmarks/haena-v0/meeting-execution-v0"
DERIVED_DATA="${REPO_ROOT}/.build/BenchmarkDerivedData"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
OUTPUT_DIR="${DATASET_ROOT}/predictions/${RUN_ID}"

log() { printf '==> %s\n' "$1" >&2; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install Xcode and run: xcode-select --install"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found. Install it with: brew install xcodegen"

[ -f "${DATASET_ROOT}/source-index.jsonl" ] || fail "no transcript-free benchmark source index at ${DATASET_ROOT}. Build it first — see docs/benchmark-data-contract.md"

log "Regenerating HAENA.xcodeproj from project.yml"
( cd "${REPO_ROOT}" && xcodegen generate >/dev/null )

log "Building haena-benchmark (Debug) into .build/BenchmarkDerivedData"
xcodebuild \
    -project "${REPO_ROOT}/HAENA.xcodeproj" \
    -scheme HAENABenchmarkCLI \
    -configuration Debug \
    -derivedDataPath "${DERIVED_DATA}" \
    build >/dev/null

BINARY="${DERIVED_DATA}/Build/Products/Debug/haena-benchmark"
[ -x "${BINARY}" ] || fail "build succeeded but ${BINARY} is missing"

log "Running the development split offline into ${OUTPUT_DIR}"
"${BINARY}" \
    --dataset-root "${DATASET_ROOT}" \
    --output-dir "${OUTPUT_DIR}" \
    --split development \
    "$@"

log "Predictions written to ${OUTPUT_DIR} (inside /data/, which .gitignore excludes)"
