#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TASK_MASTER_BIN="${REPO_ROOT}/tools/task-master/node_modules/.bin/task-master"
CONFIG_FILE="${REPO_ROOT}/.taskmaster/config.json"

if [[ ! -x "${TASK_MASTER_BIN}" ]]; then
  echo "Task Master is not installed. Run pnpm install in tools/task-master first." >&2
  exit 1
fi

if ! grep -Eq '"anonymousTelemetry"[[:space:]]*:[[:space:]]*false' "${CONFIG_FILE}"; then
  echo "Refusing to run: anonymousTelemetry must be false." >&2
  exit 1
fi

if ! grep -Eq '"enableCodebaseAnalysis"[[:space:]]*:[[:space:]]*false' "${CONFIG_FILE}"; then
  echo "Refusing to run: enableCodebaseAnalysis must be false." >&2
  exit 1
fi

COMMAND="${1:---help}"
case "${COMMAND}" in
  --help|-h|--version|list|show|next|set-status|validate-dependencies|generate)
    ;;
  *)
    echo "Blocked by HAE.NA offline policy: task-master ${COMMAND}" >&2
    exit 2
    ;;
esac

# Remove every provider or cloud credential that Task Master 0.43.1 knows how
# to consume. The graph commands above do not need any of them.
unset ANTHROPIC_API_KEY PERPLEXITY_API_KEY OPENAI_API_KEY GOOGLE_API_KEY
unset MISTRAL_API_KEY XAI_API_KEY GROQ_API_KEY OPENROUTER_API_KEY
unset AZURE_OPENAI_API_KEY OLLAMA_API_KEY GITHUB_API_KEY ZAI_API_KEY
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset GOOGLE_APPLICATION_CREDENTIALS
export SENTRY_DSN=""

if ! command -v node >/dev/null 2>&1; then
  CODEX_NODE_DIR="${HOME}/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin"
  if [[ -x "${CODEX_NODE_DIR}/node" ]]; then
    export PATH="${CODEX_NODE_DIR}:${PATH}"
  else
    echo "Node.js is required to run Task Master." >&2
    exit 1
  fi
fi

cd "${REPO_ROOT}"
exec "${TASK_MASTER_BIN}" "$@"
