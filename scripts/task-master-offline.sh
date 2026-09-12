#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Reuse an already installed offline executable; never install/download on invocation.
TASK_MASTER_BIN="${HAENA_TASK_MASTER_BIN:-${REPO_ROOT}/tools/task-master/node_modules/.bin/task-master}"
CONFIG_FILE="${REPO_ROOT}/.taskmaster/config.json"
[[ -x "${TASK_MASTER_BIN}" ]] || { echo "Set HAENA_TASK_MASTER_BIN to the installed offline Task Master." >&2; exit 1; }
grep -Eq '"anonymousTelemetry"[[:space:]]*:[[:space:]]*false' "${CONFIG_FILE}"
grep -Eq '"enableCodebaseAnalysis"[[:space:]]*:[[:space:]]*false' "${CONFIG_FILE}"
case "${1:---help}" in
  --help|-h|--version|list|show|next|set-status|validate-dependencies|generate) ;;
  *) echo "Blocked by offline policy" >&2; exit 2 ;;
esac
unset ANTHROPIC_API_KEY PERPLEXITY_API_KEY OPENAI_API_KEY GOOGLE_API_KEY
unset MISTRAL_API_KEY XAI_API_KEY GROQ_API_KEY OPENROUTER_API_KEY
unset AZURE_OPENAI_API_KEY OLLAMA_API_KEY GITHUB_API_KEY ZAI_API_KEY
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN GOOGLE_APPLICATION_CREDENTIALS
export SENTRY_DSN=""
if ! command -v node >/dev/null 2>&1; then
  CODEX_NODE_DIR="${HOME}/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin"
  export PATH="${CODEX_NODE_DIR}:${PATH}"
fi
cd "${REPO_ROOT}"
exec "${TASK_MASTER_BIN}" "$@"
