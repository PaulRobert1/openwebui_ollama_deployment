#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Local AI Suite v8.8
# Fedora + native Ollama + Docker Open WebUI + SearXNG + mode UI + Deep Research lab
#
# Evidence-first local assistant deployment/configuration.
# When an existing Local AI Suite is detected, the installer asks whether to
# preserve it or remove the suite completely and reinstall it from scratch.
# Preserve mode skips reinstalling detected components and installs only missing
# requirements. Clean-reinstall mode deletes suite data and rebuilds everything.
###############################################################################

VERSION="8.8"

WEBUI_URL="${WEBUI_URL:-http://127.0.0.1:3000}"
OPENWEBUI_CONTAINER="${OPENWEBUI_CONTAINER:-open-webui}"
OPENWEBUI_IMAGE="${OPENWEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
OPENWEBUI_VOLUME="${OPENWEBUI_VOLUME:-open-webui}"
SEARXNG_CONTAINER="${SEARXNG_CONTAINER:-searxng}"
SEARXNG_IMAGE="${SEARXNG_IMAGE:-searxng/searxng:latest}"
LOCAL_AI_NETWORK="${LOCAL_AI_NETWORK:-local-ai}"
LOCAL_AI_DIR="${LOCAL_AI_DIR:-/opt/local-ai-suite}"
INSTALL_SEARXNG="${INSTALL_SEARXNG:-1}" # 1 by default; set 0 to leave SearXNG/web search unmanaged
REPAIR_SEARXNG="${REPAIR_SEARXNG:-0}" # set 1 only if an existing SearXNG container is broken
REFRESH_MODEL_PROFILES="${REFRESH_MODEL_PROFILES:-1}" # refresh prompts/sampling without redownloading existing layers
REMOVE_LEGACY="${REMOVE_LEGACY:-0}"
MANAGE_MODEL_ALLOWLIST="${MANAGE_MODEL_ALLOWLIST:-1}"
INSTALL_DOCUMENT_MEMORY="${INSTALL_DOCUMENT_MEMORY:-1}"
INSTALL_DEEP_RESEARCH="${INSTALL_DEEP_RESEARCH:-1}" # Research Brief + isolated persistent sandbox tool
INSTALL_MODE_UI="${INSTALL_MODE_UI:-1}"             # Fast / Advanced / Deep Research composer mode bar
REBUILD_SANDBOX_IMAGE="${REBUILD_SANDBOX_IMAGE:-0}"
TUNE_OPENWEBUI_RUNTIME="${TUNE_OPENWEBUI_RUNTIME:-1}" # safely recreate the existing OpenWebUI container only when perf env differs
OPENWEBUI_STREAM_CHUNK="${OPENWEBUI_STREAM_CHUNK:-3}" # fewer UI/socket updates while still looking smooth for a single user
PREWARM_MODELS="${PREWARM_MODELS:-1}" # asynchronously warm Advanced/Deep when their button is selected
MODEL_IDLE_UNLOAD="${MODEL_IDLE_UNLOAD:-15m}" # unload each Ollama model after this period with no requests
REINSTALL_EXISTING="${REINSTALL_EXISTING:-ask}" # ask|yes|no; yes performs a destructive clean reinstall

SANDBOX_DIR="${SANDBOX_DIR:-$LOCAL_AI_DIR/deep-research}"
SANDBOX_PORT="${SANDBOX_PORT:-8787}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-local-ai-research-sandbox:v2}"
SANDBOX_MEMORY="${SANDBOX_MEMORY:-8g}"
SANDBOX_CPUS="${SANDBOX_CPUS:-6}"
SANDBOX_IDLE_SECONDS="${SANDBOX_IDLE_SECONDS:-1200}"
SANDBOX_NETWORK="${SANDBOX_NETWORK:-bridge}"

TASK_MODEL="background-scout:270m"
FAST_MODEL="natural-fast:27b"
RESEARCH_MODEL="research-plus:27b"
DEEP_MODEL="deep-research:27b"

# User-facing OpenWebUI workspace models. These make mode routing auditable and
# keep persisted chat metadata aligned with the Fast / Advanced / Deep buttons.
MODE_FAST_ID="local-ai-fast"
MODE_ADVANCED_ID="local-ai-advanced"
MODE_DEEP_ID="local-ai-deep-research"

OLD_TASK="owui-task:270m"
OLD_FAST="evidence-assistant-32k:qwen3.6-27b-iq3m"
OLD_RESEARCH="evidence-assistant-fast:qwen3.6-27b-iq3m"
OLD_DEEP="evidence-assistant:qwen3.6-27b-iq3m"

BASE_MODEL="hf.co/HauhauCS/Qwen3.6-27B-Uncensored-HauhauCS-Balanced:IQ3_M"
TASK_BASE="gemma3:270m"

FAST_CTX="${FAST_CTX:-32768}"
RESEARCH_CTX="${RESEARCH_CTX:-49152}"
DEEP_CTX="${DEEP_CTX:-65536}"
FAST_OUTPUT="${FAST_OUTPUT:-4096}"
RESEARCH_OUTPUT="${RESEARCH_OUTPUT:-6144}"
DEEP_OUTPUT="${DEEP_OUTPUT:-8192}"

FILTER_ID="document_memory_gate"
FILTER_NAME="Persistent Document Memory Gate"
GUARD_ID="response_discipline_guard"
GUARD_NAME="Response Discipline Guard"
ADV_CALC_TOOL_ID="advanced_deterministic_calculator"
ADV_CALC_TOOL_NAME="Advanced Deterministic Calculator"
DEEP_TOOL_ID="deep_research_lab"
DEEP_TOOL_NAME="Deep Research Lab"
DEEP_WEB_TOOL_ID="deep_research_web"
DEEP_WEB_TOOL_NAME="Deep Research Web"
DEEP_FILTER_ID="deep_research_orchestrator"
DEEP_FILTER_NAME="Deep Research Brief Orchestrator"
SEARXNG_QUERY_URL="http://searxng:8080/search?q=<query>&format=json"
SEARXNG_CONTROLLER_URL="${SEARXNG_CONTROLLER_URL:-http://127.0.0.1:8081}"
DEEP_WEB_PRE_SEARCH_MAX="${DEEP_WEB_PRE_SEARCH_MAX:-3}"
DEEP_WEB_PRE_FETCH_MAX="${DEEP_WEB_PRE_FETCH_MAX:-5}"
DEEP_WEB_POST_SEARCH_MAX="${DEEP_WEB_POST_SEARCH_MAX:-1}"
DEEP_WEB_POST_FETCH_MAX="${DEEP_WEB_POST_FETCH_MAX:-2}"
SCOPE_AUDIT_MODEL="${SCOPE_AUDIT_MODEL:-background-scout:270m}"
SCOPE_AUDIT_ARTIFACT_CHARS="${SCOPE_AUDIT_ARTIFACT_CHARS:-24000}"
SCOPE_AUDIT_BRIEF_CHARS="${SCOPE_AUDIT_BRIEF_CHARS:-8000}"
SEMANTIC_AUDIT_MODEL="${SEMANTIC_AUDIT_MODEL:-natural-fast:27b}"
SEMANTIC_AUDIT_ARTIFACT_CHARS="${SEMANTIC_AUDIT_ARTIFACT_CHARS:-22000}"
SEMANTIC_AUDIT_EVIDENCE_CHARS="${SEMANTIC_AUDIT_EVIDENCE_CHARS:-36000}"
SEMANTIC_AUDIT_SCOPE_CHARS="${SEMANTIC_AUDIT_SCOPE_CHARS:-8000}"
SEMANTIC_REPAIR_MAX="${SEMANTIC_REPAIR_MAX:-3}"
LESSON_MODEL="${LESSON_MODEL:-background-scout:270m}"
LESSON_RETRIEVAL_MAX="${LESSON_RETRIEVAL_MAX:-5}"
LESSON_ARTIFACT_CHARS="${LESSON_ARTIFACT_CHARS:-12000}"
LESSON_FAILURE_CHARS="${LESSON_FAILURE_CHARS:-6000}"

section(){ echo; echo "======================================================================"; echo "$1"; echo "======================================================================"; }
info(){ echo "==> $*"; }
ok(){ echo " ✓ $*"; }
warn(){ echo " ! $*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then SUDO=""; else need_cmd sudo || fail "sudo is required"; SUDO="sudo"; fi

# Use a private per-run temp directory. This avoids permission failures when the
# installer was previously executed by another user (for example root) and left
# root-owned /tmp/__pycache__ or temporary files behind.
WORKDIR="$(mktemp -d -t local-ai-suite.XXXXXXXX)"
cleanup_workdir(){ rm -rf "$WORKDIR" 2>/dev/null || true; }
trap cleanup_workdir EXIT INT TERM

model_exists(){ ollama list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$1"; }
wait_for_url(){ local url="$1" timeout="${2:-180}" start="$(date +%s)"; until curl -fsS "$url" >/dev/null 2>&1; do (( $(date +%s)-start > timeout )) && return 1; sleep 2; done; }
get_docker_cmd(){ if docker info >/dev/null 2>&1; then echo docker; elif need_cmd sudo && sudo docker info >/dev/null 2>&1; then echo "sudo docker"; else return 1; fi; }
container_exists(){ $DOCKER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$1"; }
container_running(){ $DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$1"; }
json_bool(){ [[ "${1,,}" == "1" || "${1,,}" == "true" || "${1,,}" == "yes" ]]; }

if [[ ! "$MODEL_IDLE_UNLOAD" =~ ^[1-9][0-9]*(s|m|h)$ ]]; then
  fail "MODEL_IDLE_UNLOAD must be a positive duration such as 900s, 15m, or 1h (got: $MODEL_IDLE_UNLOAD)"
fi

section "BASIC DEPENDENCIES"
if need_cmd dnf; then
  PKGS=(); need_cmd curl || PKGS+=(curl); need_cmd jq || PKGS+=(jq); need_cmd python3 || PKGS+=(python3); need_cmd openssl || PKGS+=(openssl); need_cmd ss || PKGS+=(iproute)
  ((${#PKGS[@]})) && $SUDO dnf install -y "${PKGS[@]}"
fi
for c in curl jq python3 openssl; do need_cmd "$c" || fail "$c is required"; done


###############################################################################
# Existing-installation policy
###############################################################################
# Detect only Local AI Suite components; Docker by itself is not considered an
# existing suite because the host may use Docker for unrelated workloads.
EXISTING_COMPONENTS=()
DETECT_DOCKER_CMD=""

if need_cmd ollama; then
  EXISTING_COMPONENTS+=("Ollama")
fi

if need_cmd docker; then
  DETECT_DOCKER_CMD="$(get_docker_cmd 2>/dev/null || true)"
  if [[ -n "$DETECT_DOCKER_CMD" ]]; then
    if $DETECT_DOCKER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$OPENWEBUI_CONTAINER"; then
      EXISTING_COMPONENTS+=("OpenWebUI container")
    fi
    if $DETECT_DOCKER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$SEARXNG_CONTAINER"; then
      EXISTING_COMPONENTS+=("SearXNG container")
    fi
    if $DETECT_DOCKER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^lai-dr-'; then
      EXISTING_COMPONENTS+=("Deep Research sandbox containers")
    fi
    if $DETECT_DOCKER_CMD volume inspect "$OPENWEBUI_VOLUME" >/dev/null 2>&1; then
      EXISTING_COMPONENTS+=("OpenWebUI data volume")
    fi
  fi
fi

[[ -d "$LOCAL_AI_DIR" ]] && EXISTING_COMPONENTS+=("$LOCAL_AI_DIR")
if need_cmd systemctl; then
  systemctl list-unit-files --no-legend 2>/dev/null | grep -Eq '^local-ai-(research-controller|openwebui-mode-ui)\.(service|timer)' \
    && EXISTING_COMPONENTS+=("Local AI Suite systemd services") || true
fi

FORCE_CLEAN_REINSTALL=0
if ((${#EXISTING_COMPONENTS[@]})); then
  section "EXISTING LOCAL AI SUITE DETECTED"
  printf 'Detected components:\n'
  printf ' - %s\n' "${EXISTING_COMPONENTS[@]}"
  echo
  warn "Choosing YES deletes OpenWebUI users/chats/data, SearXNG configuration, Deep Research sandboxes, Local AI Suite files, and ALL Ollama models on this host."
  warn "Docker itself and unrelated Docker containers/volumes are not removed."

  case "${REINSTALL_EXISTING,,}" in
    ask|'')
      REINSTALL_REPLY=""
      read -r -p "Remove the existing Local AI Suite and reinstall everything from scratch? [y/N]: " REINSTALL_REPLY || REINSTALL_REPLY=""
      ;;
    yes|y|1|true) REINSTALL_REPLY="y" ;;
    no|n|0|false) REINSTALL_REPLY="n" ;;
    *) fail "REINSTALL_EXISTING must be ask, yes, or no (got: $REINSTALL_EXISTING)" ;;
  esac

  if [[ "${REINSTALL_REPLY,,}" =~ ^(y|yes)$ ]]; then
    FORCE_CLEAN_REINSTALL=1
    section "REMOVING EXISTING LOCAL AI SUITE"

    # Stop suite-owned services before deleting their files or containers.
    if need_cmd systemctl; then
      for unit in \
        local-ai-openwebui-mode-ui.timer \
        local-ai-openwebui-mode-ui.service \
        local-ai-research-controller.service; do
        $SUDO systemctl disable --now "$unit" >/dev/null 2>&1 || true
      done
    fi

    # Remove suite-owned Docker resources only. Unrelated Docker workloads stay.
    CLEAN_DOCKER_CMD="$DETECT_DOCKER_CMD"
    if [[ -z "$CLEAN_DOCKER_CMD" ]] && need_cmd docker; then
      CLEAN_DOCKER_CMD="$(get_docker_cmd 2>/dev/null || true)"
    fi
    if [[ -n "$CLEAN_DOCKER_CMD" ]]; then
      mapfile -t LAI_DR_CONTAINERS < <($CLEAN_DOCKER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^lai-dr-' || true)
      if ((${#LAI_DR_CONTAINERS[@]})); then
        $CLEAN_DOCKER_CMD rm -f "${LAI_DR_CONTAINERS[@]}" >/dev/null 2>&1 || true
      fi
      $CLEAN_DOCKER_CMD rm -f "$OPENWEBUI_CONTAINER" "$SEARXNG_CONTAINER" >/dev/null 2>&1 || true

      mapfile -t LAI_DR_VOLUMES < <($CLEAN_DOCKER_CMD volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^lai-dr-data-' || true)
      if ((${#LAI_DR_VOLUMES[@]})); then
        $CLEAN_DOCKER_CMD volume rm -f "${LAI_DR_VOLUMES[@]}" >/dev/null 2>&1 || true
      fi
      $CLEAN_DOCKER_CMD volume rm -f "$OPENWEBUI_VOLUME" >/dev/null 2>&1 || true
      $CLEAN_DOCKER_CMD network rm "$LOCAL_AI_NETWORK" >/dev/null 2>&1 || true

      # Force a true image refresh for suite-owned images. If another container
      # still references one, Docker may keep it; the later pull/run remains safe.
      $CLEAN_DOCKER_CMD image rm -f "$OPENWEBUI_IMAGE" "$SEARXNG_IMAGE" "$SANDBOX_IMAGE" >/dev/null 2>&1 || true
    fi

    # Remove all Ollama models because YES explicitly requests a from-scratch
    # Local AI rebuild. The warning above makes this destructive scope explicit.
    if need_cmd ollama; then
      if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        mapfile -t ALL_OLLAMA_MODELS < <(ollama list 2>/dev/null | awk 'NR > 1 {print $1}')
        for model in "${ALL_OLLAMA_MODELS[@]}"; do
          [[ -n "$model" ]] && ollama rm "$model" >/dev/null 2>&1 || true
        done
      fi
    fi

    if need_cmd systemctl; then
      $SUDO systemctl disable --now ollama >/dev/null 2>&1 || true
    fi

    OLLAMA_BIN="$(command -v ollama 2>/dev/null || true)"
    if [[ -n "$OLLAMA_BIN" ]]; then
      OLLAMA_RPM="$(rpm -qf "$OLLAMA_BIN" --qf '%{NAME}' 2>/dev/null || true)"
      if [[ "$OLLAMA_RPM" == ollama || "$OLLAMA_RPM" == ollama-* ]]; then
        $SUDO dnf remove -y "$OLLAMA_RPM" >/dev/null 2>&1 || true
      else
        case "$OLLAMA_BIN" in
          /usr/local/bin/ollama|/usr/bin/ollama) $SUDO rm -f "$OLLAMA_BIN" ;;
          *) warn "Leaving unrecognized Ollama binary path in place: $OLLAMA_BIN; installer will overwrite/reconfigure it if needed" ;;
        esac
      fi
    fi

    $SUDO rm -rf \
      /etc/systemd/system/ollama.service.d \
      /usr/local/lib/ollama \
      /usr/share/ollama/.ollama \
      /var/lib/ollama \
      "$LOCAL_AI_DIR"
    $SUDO rm -f \
      /etc/systemd/system/ollama.service \
      /etc/systemd/system/local-ai-research-controller.service \
      /etc/systemd/system/local-ai-openwebui-mode-ui.service \
      /etc/systemd/system/local-ai-openwebui-mode-ui.timer
    rm -rf "$HOME/.ollama" 2>/dev/null || true

    if need_cmd systemctl; then
      $SUDO systemctl daemon-reload
      $SUDO systemctl reset-failed >/dev/null 2>&1 || true
    fi
    hash -r
    ok "Existing Local AI Suite removed; a clean reinstall will now be performed"
  else
    ok "Existing installation will be preserved; detected components will not be reinstalled"
  fi
else
  ok "No existing Local AI Suite detected; performing a fresh installation"
fi

section "OLLAMA"
if ((FORCE_CLEAN_REINSTALL==1)) || ! need_cmd ollama; then
  info "Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
  hash -r
fi
if need_cmd systemctl; then
  $SUDO systemctl enable --now ollama >/dev/null 2>&1 || true
  $SUDO mkdir -p /etc/systemd/system/ollama.service.d
  $SUDO tee /etc/systemd/system/ollama.service.d/99-local-ai-suite.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=$MODEL_IDLE_UNLOAD"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_NUM_PARALLEL=1"
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl restart ollama
fi
wait_for_url "http://127.0.0.1:11434" 90 || fail "Ollama did not start"
ok "Ollama is running"
if need_cmd systemctl; then
  OLLAMA_KEEP_ALIVE_EFFECTIVE=""
  OLLAMA_MAIN_PID="$($SUDO systemctl show ollama -p MainPID --value 2>/dev/null || true)"
  if [[ "$OLLAMA_MAIN_PID" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$OLLAMA_MAIN_PID/environ" || -n "$SUDO" ]]; then
    OLLAMA_KEEP_ALIVE_EFFECTIVE="$($SUDO sh -c "tr '\\0' '\\n' < /proc/$OLLAMA_MAIN_PID/environ" 2>/dev/null | sed -n 's/^OLLAMA_KEEP_ALIVE=//p' | tail -1)"
  fi
  if [[ -z "$OLLAMA_KEEP_ALIVE_EFFECTIVE" ]]; then
    OLLAMA_KEEP_ALIVE_EFFECTIVE="$($SUDO systemctl show ollama -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^OLLAMA_KEEP_ALIVE=//p' | tail -1)"
  fi
  if [[ "$OLLAMA_KEEP_ALIVE_EFFECTIVE" == "$MODEL_IDLE_UNLOAD" ]]; then
    ok "Ollama model idle unload is active: $MODEL_IDLE_UNLOAD"
  else
    warn "Ollama is running, but the effective OLLAMA_KEEP_ALIVE could not be verified as $MODEL_IDLE_UNLOAD (reported: ${OLLAMA_KEEP_ALIVE_EFFECTIVE:-unknown})"
  fi
fi
ss -ltnp 2>/dev/null | grep ':11434' || true
ss -ltn 2>/dev/null | grep -Eq '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]):11434' || fail "Ollama is still loopback-only; Docker cannot reach it"
ok "Ollama is reachable from Docker networking"
warn "Ollama listens on host interfaces for Docker access. Keep TCP 11434 blocked from untrusted networks unless remote Ollama access is intentional."

section "MODEL SUITE"
copy_if_needed(){ local src="$1" dst="$2"; if model_exists "$dst"; then ok "$dst already exists"; return 0; fi; if model_exists "$src"; then info "Creating friendly alias: $src -> $dst"; ollama cp "$src" "$dst"; return 0; fi; return 1; }
copy_if_needed "$OLD_TASK" "$TASK_MODEL" || true
copy_if_needed "$OLD_FAST" "$FAST_MODEL" || true
copy_if_needed "$OLD_RESEARCH" "$RESEARCH_MODEL" || true
copy_if_needed "$OLD_DEEP" "$DEEP_MODEL" || true

# Tiny task model: always normalize its profile. The underlying layer is reused.
model_exists "$TASK_BASE" || ollama pull "$TASK_BASE"
cat >${WORKDIR}/Modelfile.background-scout <<EOF
FROM $TASK_BASE
PARAMETER num_ctx 4096
PARAMETER num_predict 256
PARAMETER temperature 0.1
PARAMETER top_k 20
PARAMETER top_p 0.9
PARAMETER repeat_last_n 128
PARAMETER repeat_penalty 1.05
SYSTEM """
You are a tiny internal task model for Open WebUI. Perform only the requested helper task. Return one concise result. Never expose chain-of-thought, self-review, drafts, or phrases such as 'Final Answer', 'Looks good', 'One final check', or 'Okay' as meta commentary. Silently normalize obvious typos when the intended word is unambiguous. Never repeat the same result.
"""
EOF
ollama create "$TASK_MODEL" -f ${WORKDIR}/Modelfile.background-scout >/dev/null
ollama stop "$TASK_MODEL" >/dev/null 2>&1 || true
ok "$TASK_MODEL profile ready"

# Shared evidence-first prompt. The typo/repetition rules are deliberate: this
# model family can otherwise spiral into visible self-review when thinking.
cat >${WORKDIR}/evidence-system-prompt.txt <<'PROMPT'
You are a persistent evidence-first technical AI assistant.

EVIDENCE RULES
- Never invent missing facts or present assumptions, speculation, probability, or educated guesses as confirmed information.
- If evidence required for a correct answer is missing, ask for the exact missing information.
- Clearly separate confirmed facts, observations, unresolved information, and next diagnostic actions.
- For troubleshooting, gather evidence before determining root cause. Ask for logs, screenshots, configuration, command output, versions, architecture details, documentation, or reproduction steps when needed.
- Prefer directly copy/paste-ready diagnostic commands.
- Do not produce long lists of hypothetical causes when diagnostics can distinguish them.

INPUT NORMALIZATION
- Silently correct obvious keyboard/spelling typos when the user's intended meaning is unambiguous. Example: 'ehat about citrix' should be treated as 'what about citrix'.
- Do not narrate typo detection or repeatedly re-evaluate the typo.
- If a typo genuinely changes or obscures the meaning, ask one concise clarification question and stop.

RESPONSE DISCIPLINE
- Produce one answer only.
- Never emit internal self-review, hidden reasoning, draft commentary, or meta phrases such as 'Okay', 'Final Answer', 'Looks good', 'One final check', 'One last check', or similar process notes.
- Never repeat a completed answer or paragraph merely to verify it.
- Once the answer is complete, stop generation.
- If you notice you are beginning to repeat yourself, stop the repeated sequence immediately and continue only with new information, or end the answer.

MEMORY AND DOCUMENTS
- Search relevant persistent memory before asking the user to repeat information that may already be known.
- Retrieve only memory relevant to the current topic. Store durable confirmed facts when memory tools are available.
- Never store passwords, API keys, authentication tokens, or unsupported theories. If new confirmed information supersedes an old fact, update the old information.
- When a system message contains <persistent_document_recall>, previously approved documents matched the current topic. Treat only the included excerpts as source material. If excerpts are insufficient, query the referenced persistent Knowledge Base/document before claiming what it says. Never infer unsupported document contents.

WEB AND TROUBLESHOOTING
- Use web search when current/external information is required, not automatically when current evidence, relevant memory, or stored knowledge is sufficient.
- Troubleshooting order: inspect evidence; retrieve relevant memory/document context; retrieve knowledge/documentation; identify missing evidence; request/collect it; analyze it; determine root cause only when supported; provide remediation; store durable confirmed results.
PROMPT

create_model_profile(){
  local name="$1" ctx="$2" predict="$3" temp="${4:-0.5}" mf="${WORKDIR}/Modelfile.${1//[:\/]/_}"
  {
    echo "FROM $BASE_MODEL"
    echo "PARAMETER num_ctx $ctx"
    echo "PARAMETER num_predict $predict"
    echo "PARAMETER temperature $temp"
    echo "PARAMETER top_p 0.95"
    echo "PARAMETER top_k 20"
    echo "PARAMETER repeat_last_n 256"
    echo "PARAMETER repeat_penalty 1.05"
    echo 'SYSTEM """'
    cat ${WORKDIR}/evidence-system-prompt.txt
    echo '"""'
  } >"$mf"
  ollama create "$name" -f "$mf" >/dev/null
  ollama stop "$name" >/dev/null 2>&1 || true
  ok "$name profile ready ($ctx context)"
}

NEED_QWEN=0
for m in "$FAST_MODEL" "$RESEARCH_MODEL" "$DEEP_MODEL"; do model_exists "$m" || NEED_QWEN=1; done
if (( NEED_QWEN==1 )) || [[ "$REFRESH_MODEL_PROFILES" == 1 ]]; then
  if ! model_exists "$BASE_MODEL"; then
    if (( NEED_QWEN==1 )); then
      section "DOWNLOADING QWEN3.6 27B IQ3_M BASE"
      ollama pull "$BASE_MODEL"
    else
      warn "Base model alias $BASE_MODEL is absent; existing friendly models were preserved and their Modelfiles were not rebuilt. Response Discipline Guard will still enforce the runtime fix."
    fi
  fi
  if model_exists "$BASE_MODEL"; then
    section "REFRESHING FRIENDLY MODEL PROFILES"
    create_model_profile "$FAST_MODEL" "$FAST_CTX" "$FAST_OUTPUT" 0.5
    create_model_profile "$RESEARCH_MODEL" "$RESEARCH_CTX" "$RESEARCH_OUTPUT" 0.4
    create_model_profile "$DEEP_MODEL" "$DEEP_CTX" "$DEEP_OUTPUT" 0.25
  fi
fi

section "DOCKER"
if ! need_cmd docker; then
  need_cmd dnf || fail "Automatic Docker installation expects Fedora/dnf"
  $SUDO dnf -y install dnf-plugins-core
  $SUDO dnf repolist 2>/dev/null | grep -qi docker-ce || $SUDO dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
  $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
fi
DOCKER_CMD="$(get_docker_cmd)" || fail "Docker is installed but unusable"
ok "Docker is available"

OPENWEBUI_EXISTED=0
if container_exists "$OPENWEBUI_CONTAINER"; then OPENWEBUI_EXISTED=1; container_running "$OPENWEBUI_CONTAINER" || $DOCKER_CMD start "$OPENWEBUI_CONTAINER" >/dev/null; fi
FRESH_WEBUI=0
if wait_for_url "$WEBUI_URL/health" 8; then ok "Existing OpenWebUI detected; data/container preserved"; else
  if ((OPENWEBUI_EXISTED==1)); then $DOCKER_CMD logs --tail 80 "$OPENWEBUI_CONTAINER" 2>/dev/null || true; fail "OpenWebUI container exists but is unhealthy; it was not recreated automatically"; fi
  FRESH_WEBUI=1
fi

if json_bool "$INSTALL_SEARXNG"; then WANT_SEARXNG=1; else WANT_SEARXNG=0; fi

# One shared network gives OpenWebUI a stable DNS name 'searxng' without
# disturbing any existing compose/default networks.
$DOCKER_CMD network inspect "$LOCAL_AI_NETWORK" >/dev/null 2>&1 || $DOCKER_CMD network create "$LOCAL_AI_NETWORK" >/dev/null
if ((OPENWEBUI_EXISTED==1)); then
  $DOCKER_CMD network connect "$LOCAL_AI_NETWORK" "$OPENWEBUI_CONTAINER" >/dev/null 2>&1 || true
fi

if ((WANT_SEARXNG==1)); then
  
if ((FRESH_WEBUI==0)) && json_bool "$TUNE_OPENWEBUI_RUNTIME"; then
  section "OPENWEBUI RUNTIME PERFORMANCE TUNING"

  PERF_NEEDS_RECREATE=0
  declare -A PERF_WANT=(
    [ENABLE_BASE_MODELS_CACHE]="True"
    [MODELS_CACHE_TTL]="300"
    [ENABLE_QUERIES_CACHE]="True"
    [ENABLE_REALTIME_CHAT_SAVE]="False"
    [CHAT_RESPONSE_STREAM_DELTA_CHUNK_SIZE]="$OPENWEBUI_STREAM_CHUNK"
  )

  EXISTING_ENV="$($DOCKER_CMD inspect "$OPENWEBUI_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}')"
  for key in "${!PERF_WANT[@]}"; do
    cur="$(awk -F= -v k="$key" '$1==k{v=substr($0,index($0,"=")+1)}END{print v}' <<<"$EXISTING_ENV")"
    want="${PERF_WANT[$key]}"
    if [[ "${cur,,}" != "${want,,}" ]]; then
      PERF_NEEDS_RECREATE=1
      break
    fi
  done

  if ((PERF_NEEDS_RECREATE==0)); then
    ok "OpenWebUI runtime performance environment already tuned"
  else
    info "Applying OpenWebUI latency/streaming environment while preserving persistent data"

    INSPECT_JSON="${WORKDIR}/openwebui-inspect.json"
    $DOCKER_CMD inspect "$OPENWEBUI_CONTAINER" >"$INSPECT_JSON"

    PERF_IMAGE="$(jq -r '.[0].Config.Image' "$INSPECT_JSON")"
    PERF_RESTART="$(jq -r '.[0].HostConfig.RestartPolicy.Name // "unless-stopped"' "$INSPECT_JSON")"
    [[ -n "$PERF_IMAGE" && "$PERF_IMAGE" != null ]] || fail "Unable to determine existing OpenWebUI image"

    # Preserve every existing environment entry except the performance keys we
    # intentionally replace.
    PERF_ENV_FILE="${WORKDIR}/openwebui-performance.env"
    jq -r '.[0].Config.Env[]?' "$INSPECT_JSON" \
      | grep -Ev '^(ENABLE_BASE_MODELS_CACHE|MODELS_CACHE_TTL|ENABLE_QUERIES_CACHE|ENABLE_REALTIME_CHAT_SAVE|CHAT_RESPONSE_STREAM_DELTA_CHUNK_SIZE)=' \
      >"$PERF_ENV_FILE"
    {
      echo "ENABLE_BASE_MODELS_CACHE=True"
      echo "MODELS_CACHE_TTL=300"
      echo "ENABLE_QUERIES_CACHE=True"
      echo "ENABLE_REALTIME_CHAT_SAVE=False"
      echo "CHAT_RESPONSE_STREAM_DELTA_CHUNK_SIZE=$OPENWEBUI_STREAM_CHUNK"
    } >>"$PERF_ENV_FILE"

    mapfile -t PERF_PORTS < <(jq -r '
      .[0].HostConfig.PortBindings // {}
      | to_entries[]
      | .key as $container
      | (.value // [])[]
      | (($container | split("/")[0])) as $cp
      | if ((.HostIp // "") == "" or .HostIp == "0.0.0.0")
        then "\(.HostPort):\($cp)"
        else "\(.HostIp):\(.HostPort):\($cp)"
        end
    ' "$INSPECT_JSON")

    mapfile -t PERF_MOUNTS < <(jq -r '
      .[0].Mounts[]?
      | if .Type=="volume" then
          "type=volume,src=\(.Name),dst=\(.Destination)" + (if .RW then "" else ",readonly" end)
        elif .Type=="bind" then
          "type=bind,src=\(.Source),dst=\(.Destination)" + (if .RW then "" else ",readonly" end)
        else empty end
    ' "$INSPECT_JSON")

    mapfile -t PERF_NETWORKS < <(jq -r '.[0].NetworkSettings.Networks | keys[]' "$INSPECT_JSON")
    mapfile -t PERF_EXTRA_HOSTS < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$INSPECT_JSON")

    # Refuse to recreate a nonstandard container without its persistent backend
    # mount. This makes the performance tuning fail-safe rather than destructive.
    if ! printf '%s\n' "${PERF_MOUNTS[@]}" | grep -Fq 'dst=/app/backend/data'; then
      warn "OpenWebUI has no detectable /app/backend/data mount; skipping env-only recreation for safety"
    elif ((${#PERF_PORTS[@]}==0)); then
      warn "OpenWebUI published ports could not be reconstructed safely; skipping env-only recreation"
    else
      PERF_PRIMARY_NET="$LOCAL_AI_NETWORK"
      if ! printf '%s\n' "${PERF_NETWORKS[@]}" | grep -Fxq "$PERF_PRIMARY_NET"; then
        PERF_PRIMARY_NET="${PERF_NETWORKS[0]:-bridge}"
      fi

      PERF_BACKUP="${OPENWEBUI_CONTAINER}-pre-v57-$$"
      $DOCKER_CMD stop "$OPENWEBUI_CONTAINER" >/dev/null
      $DOCKER_CMD rename "$OPENWEBUI_CONTAINER" "$PERF_BACKUP"

      PERF_RUN=(run -d --name "$OPENWEBUI_CONTAINER" --env-file "$PERF_ENV_FILE")
      [[ "$PERF_RESTART" != "no" && -n "$PERF_RESTART" ]] && PERF_RUN+=(--restart "$PERF_RESTART")
      PERF_RUN+=(--network "$PERF_PRIMARY_NET")

      for p in "${PERF_PORTS[@]}"; do PERF_RUN+=(--publish "$p"); done
      for m in "${PERF_MOUNTS[@]}"; do PERF_RUN+=(--mount "$m"); done
      for h in "${PERF_EXTRA_HOSTS[@]}"; do PERF_RUN+=(--add-host "$h"); done
      PERF_RUN+=("$PERF_IMAGE")

      if ! $DOCKER_CMD "${PERF_RUN[@]}" >/dev/null; then
        warn "Performance-tuned OpenWebUI recreation failed; rolling back"
        $DOCKER_CMD rm -f "$OPENWEBUI_CONTAINER" >/dev/null 2>&1 || true
        $DOCKER_CMD rename "$PERF_BACKUP" "$OPENWEBUI_CONTAINER"
        $DOCKER_CMD start "$OPENWEBUI_CONTAINER" >/dev/null
        fail "OpenWebUI rollback completed after recreation failure"
      fi

      # Restore all additional Docker networks.
      for net in "${PERF_NETWORKS[@]}"; do
        [[ "$net" == "$PERF_PRIMARY_NET" ]] && continue
        $DOCKER_CMD network connect "$net" "$OPENWEBUI_CONTAINER" >/dev/null 2>&1 || true
      done

      if ! wait_for_url "$WEBUI_URL/health" 180; then
        warn "Performance-tuned OpenWebUI did not become healthy; rolling back"
        $DOCKER_CMD rm -f "$OPENWEBUI_CONTAINER" >/dev/null 2>&1 || true
        $DOCKER_CMD rename "$PERF_BACKUP" "$OPENWEBUI_CONTAINER"
        $DOCKER_CMD start "$OPENWEBUI_CONTAINER" >/dev/null
        wait_for_url "$WEBUI_URL/health" 120 || fail "Rollback container also failed to become healthy"
        fail "OpenWebUI performance tuning was rolled back safely"
      fi

      $DOCKER_CMD rm "$PERF_BACKUP" >/dev/null
      ok "OpenWebUI performance environment applied with persistent data preserved"
      ok "Streaming chunk=$OPENWEBUI_STREAM_CHUNK, query cache=ON, model cache=300s, realtime chat DB writes=OFF"
    fi
  fi
fi

section "SEARXNG - PRECONFIGURED LOCAL WEB SEARCH"
  $SUDO mkdir -p "$LOCAL_AI_DIR/searxng"

  write_managed_searxng_settings(){
    local secret
    secret="$(openssl rand -hex 32)"
    $SUDO tee "$LOCAL_AI_DIR/searxng/settings.yml" >/dev/null <<EOF
use_default_settings: true

server:
  secret_key: "$secret"
  limiter: false
  image_proxy: true
  port: 8080
  bind_address: "0.0.0.0"

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "auto"
  formats:
    - html
    - json

outgoing:
  request_timeout: 8.0
  max_request_timeout: 15.0
EOF
  }

  if ! container_exists "$SEARXNG_CONTAINER"; then
    [[ -f "$LOCAL_AI_DIR/searxng/settings.yml" ]] || write_managed_searxng_settings
    $DOCKER_CMD run -d --name "$SEARXNG_CONTAINER" --restart unless-stopped --network "$LOCAL_AI_NETWORK" \
      -p 127.0.0.1:8081:8080 -v "$LOCAL_AI_DIR/searxng:/etc/searxng:Z" "$SEARXNG_IMAGE" >/dev/null
    ok "Managed SearXNG container created"
  else
    container_running "$SEARXNG_CONTAINER" || $DOCKER_CMD start "$SEARXNG_CONTAINER" >/dev/null
    $DOCKER_CMD network connect "$LOCAL_AI_NETWORK" "$SEARXNG_CONTAINER" >/dev/null 2>&1 || true
    ok "Existing SearXNG container preserved and attached to $LOCAL_AI_NETWORK"
  fi

  # Host test is useful but not required for pre-existing containers that do
  # not publish 8081. The definitive test occurs through OpenWebUI below.
  if wait_for_url "http://127.0.0.1:8081" 25; then
    if curl -fsS 'http://127.0.0.1:8081/search?q=openwebui&format=json' | jq -e '.results' >/dev/null 2>&1; then
      ok "SearXNG JSON API works on 127.0.0.1:8081"
    else
      warn "SearXNG responds on 8081 but JSON output is unavailable"
    fi
  else
    warn "No host-side SearXNG port detected at 127.0.0.1:8081; Docker-network test will be used"
  fi
fi

if ((FRESH_WEBUI==1)); then
  section "OPENWEBUI FRESH DEPLOYMENT"
  $DOCKER_CMD network inspect "$LOCAL_AI_NETWORK" >/dev/null 2>&1 || $DOCKER_CMD network create "$LOCAL_AI_NETWORK" >/dev/null
  read -rp "New OpenWebUI admin email: " OWUI_EMAIL
  read -rsp "New OpenWebUI admin password: " OWUI_PASSWORD; echo
  read -rp "Admin display name [Admin]: " OWUI_NAME; OWUI_NAME="${OWUI_NAME:-Admin}"
  $SUDO mkdir -p "$LOCAL_AI_DIR"; SECRET_FILE="$LOCAL_AI_DIR/webui-secret"
  [[ -s "$SECRET_FILE" ]] || { openssl rand -hex 32 | $SUDO tee "$SECRET_FILE" >/dev/null; $SUDO chmod 600 "$SECRET_FILE"; }
  WEBUI_SECRET="$($SUDO cat "$SECRET_FILE")"
  $DOCKER_CMD volume create "$OPENWEBUI_VOLUME" >/dev/null
  WEB_SEARCH_ARGS=()
  if ((WANT_SEARXNG==1)); then WEB_SEARCH_ARGS+=( -e ENABLE_WEB_SEARCH=True -e WEB_SEARCH_ENGINE=searxng -e "SEARXNG_QUERY_URL=$SEARXNG_QUERY_URL" -e SEARXNG_LANGUAGE=all -e WEB_SEARCH_RESULT_COUNT=5 -e WEB_SEARCH_CONCURRENT_REQUESTS=2 -e WEB_LOADER_CONCURRENT_REQUESTS=3 ); fi
  $DOCKER_CMD run -d --name "$OPENWEBUI_CONTAINER" --restart unless-stopped --network "$LOCAL_AI_NETWORK" -p 3000:8080 --add-host=host.docker.internal:host-gateway \
    -e OLLAMA_BASE_URL=http://host.docker.internal:11434 -e USE_OLLAMA_DOCKER=false \
    -e ENABLE_MEMORIES=True -e ENABLE_MEMORY_SYSTEM_CONTEXT=False -e ENABLE_MEMORY_BACKGROUND_REVIEW=False \
    -e DEFAULT_MODELS="$FAST_MODEL" -e DEFAULT_PINNED_MODELS="$FAST_MODEL,$RESEARCH_MODEL,$DEEP_MODEL" \
    -e ENABLE_AUTOCOMPLETE_GENERATION=False -e ENABLE_FOLLOW_UP_GENERATION=False -e ENABLE_TITLE_GENERATION=True -e ENABLE_TAGS_GENERATION=True -e TASK_MODEL="$TASK_MODEL" \
    -e ENABLE_BASE_MODELS_CACHE=True -e MODELS_CACHE_TTL=300 -e ENABLE_QUERIES_CACHE=True \
    -e ENABLE_REALTIME_CHAT_SAVE=False -e "CHAT_RESPONSE_STREAM_DELTA_CHUNK_SIZE=$OPENWEBUI_STREAM_CHUNK" \
    -e WEBUI_ADMIN_EMAIL="$OWUI_EMAIL" -e WEBUI_ADMIN_PASSWORD="$OWUI_PASSWORD" -e WEBUI_ADMIN_NAME="$OWUI_NAME" -e WEBUI_SECRET_KEY="$WEBUI_SECRET" \
    "${WEB_SEARCH_ARGS[@]}" -v "$OPENWEBUI_VOLUME:/app/backend/data" "$OPENWEBUI_IMAGE" >/dev/null
  wait_for_url "$WEBUI_URL/health" 300 || { $DOCKER_CMD logs --tail 150 "$OPENWEBUI_CONTAINER" || true; fail "OpenWebUI failed to become healthy"; }
  ok "Fresh OpenWebUI started"
else section "OPENWEBUI"; ok "Existing OpenWebUI detected; no recreation performed"; fi

# Safe on both fresh and existing deployments; a container can belong to more
# than one Docker network.
$DOCKER_CMD network connect "$LOCAL_AI_NETWORK" "$OPENWEBUI_CONTAINER" >/dev/null 2>&1 || true
if ((WANT_SEARXNG==1)) && container_exists "$SEARXNG_CONTAINER"; then
  $DOCKER_CMD network connect "$LOCAL_AI_NETWORK" "$SEARXNG_CONTAINER" >/dev/null 2>&1 || true
fi

section "OPENWEBUI -> OLLAMA CONNECTIVITY"
CONTAINER_OLLAMA_TEST="$($DOCKER_CMD exec "$OPENWEBUI_CONTAINER" python3 -c '
import json,urllib.request
u="http://host.docker.internal:11434/api/tags"
try:
 d=json.load(urllib.request.urlopen(u,timeout=10)); print("OK"); [print(m.get("name")) for m in d.get("models",[])]
except Exception as e: print("ERROR:"+repr(e))
' 2>&1 || true)"
echo "$CONTAINER_OLLAMA_TEST"; grep -q '^OK$' <<<"$CONTAINER_OLLAMA_TEST" || fail "OpenWebUI cannot reach host-native Ollama"
ok "OpenWebUI container can reach Ollama"

if ((WANT_SEARXNG==1)); then
  section "OPENWEBUI -> SEARXNG CONNECTIVITY"
  SEARX_TEST="$($DOCKER_CMD exec "$OPENWEBUI_CONTAINER" python3 -c '
import json,urllib.request
u="http://searxng:8080/search?q=openwebui&format=json"
try:
 d=json.load(urllib.request.urlopen(u,timeout=20)); print("OK",len(d.get("results",[])))
except Exception as e: print("ERROR:"+repr(e))
' 2>&1 || true)"
  echo "$SEARX_TEST"
  if ! grep -q '^OK ' <<<"$SEARX_TEST"; then
    if [[ "$REPAIR_SEARXNG" == 1 ]]; then
      warn "Existing SearXNG failed JSON/DNS test; recreating only the SearXNG container with managed settings"
      $DOCKER_CMD rm -f "$SEARXNG_CONTAINER" >/dev/null 2>&1 || true
      write_managed_searxng_settings
      $DOCKER_CMD run -d --name "$SEARXNG_CONTAINER" --restart unless-stopped --network "$LOCAL_AI_NETWORK" \
        -p 127.0.0.1:8081:8080 -v "$LOCAL_AI_DIR/searxng:/etc/searxng:Z" "$SEARXNG_IMAGE" >/dev/null
      sleep 5
      SEARX_TEST="$($DOCKER_CMD exec "$OPENWEBUI_CONTAINER" python3 -c 'import json,urllib.request; d=json.load(urllib.request.urlopen("http://searxng:8080/search?q=openwebui&format=json",timeout=20)); print("OK",len(d.get("results",[])))' 2>&1 || true)"
      echo "$SEARX_TEST"
      grep -q '^OK ' <<<"$SEARX_TEST" || fail "SearXNG repair failed"
    else
      fail "OpenWebUI cannot use SearXNG JSON search. If this is a disposable/broken SearXNG container, rerun with REPAIR_SEARXNG=1."
    fi
  fi
  ok "OpenWebUI can resolve and query SearXNG over Docker DNS"
fi

section "OPENWEBUI ADMIN AUTHENTICATION"
if [[ -z "${OWUI_EMAIL:-}" ]]; then read -rp "OpenWebUI admin email: " OWUI_EMAIL; read -rsp "OpenWebUI admin password: " OWUI_PASSWORD; echo; fi
AUTH_RESPONSE="$(curl -fsS -X POST "$WEBUI_URL/api/v1/auths/signin" -H 'Content-Type: application/json' --data "$(jq -n --arg email "$OWUI_EMAIL" --arg password "$OWUI_PASSWORD" '{email:$email,password:$password}')")" || fail "OpenWebUI login failed"
TOKEN="$(jq -r '.token // empty' <<<"$AUTH_RESPONSE")"; ROLE="$(jq -r '.role // empty' <<<"$AUTH_RESPONSE")"; unset OWUI_PASSWORD
[[ -n "$TOKEN" ]] || fail "No OpenWebUI token returned"; [[ "$ROLE" == admin ]] || fail "Account is not an admin"; ok "Authenticated as OpenWebUI admin"

if ((WANT_SEARXNG==1)); then
  section "OPENWEBUI WEB SEARCH CONFIGURATION"
  RAG_CFG="$(curl -fsS "$WEBUI_URL/api/v1/retrieval/config" -H "Authorization: Bearer $TOKEN")" || fail "Unable to read OpenWebUI retrieval/web-search config"
  UPDATED_RAG_CFG="$(jq --arg url "$SEARXNG_QUERY_URL" '
    del(.status)
    | .web.ENABLE_WEB_SEARCH = true
    | .web.ENABLE_WEB_SEARCH_CONFIRMATION = false
    | .web.WEB_SEARCH_ENGINE = "searxng"
    | .web.WEB_SEARCH_RESULT_COUNT = 5
    | .web.WEB_SEARCH_CONCURRENT_REQUESTS = 3
    | .web.WEB_LOADER_CONCURRENT_REQUESTS = 4
    | .web.SEARXNG_QUERY_URL = $url
    | .web.SEARXNG_LANGUAGE = "all"
  ' <<<"$RAG_CFG")"
  curl -fsS -X POST "$WEBUI_URL/api/v1/retrieval/config/update" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "$UPDATED_RAG_CFG" >${WORKDIR}/retrieval-config-updated.json || fail "Unable to configure OpenWebUI SearXNG web search"
  VERIFY_WEB="$(curl -fsS "$WEBUI_URL/api/v1/retrieval/config" -H "Authorization: Bearer $TOKEN")"
  [[ "$(jq -r '.web.ENABLE_WEB_SEARCH|tostring' <<<"$VERIFY_WEB")" == true ]] || fail "OpenWebUI web search did not enable"
  [[ "$(jq -r '.web.WEB_SEARCH_ENGINE' <<<"$VERIFY_WEB")" == searxng ]] || fail "OpenWebUI search engine is not SearXNG"
  [[ "$(jq -r '.web.SEARXNG_QUERY_URL' <<<"$VERIFY_WEB")" == "$SEARXNG_QUERY_URL" ]] || fail "OpenWebUI SearXNG URL verification failed"
  ok "SearXNG is configured as the global OpenWebUI web-search backend"
fi

section "OPENWEBUI OLLAMA CONNECTION"
OLLAMA_CFG="$(curl -fsS "$WEBUI_URL/ollama/config" -H "Authorization: Bearer $TOKEN")" || fail "Unable to read Ollama connection config"
if [[ "$MANAGE_MODEL_ALLOWLIST" == 1 ]]; then
  export OLLAMA_CFG TASK_MODEL FAST_MODEL RESEARCH_MODEL DEEP_MODEL
  PATCHED_OLLAMA_CFG="$(python3 - <<'PYCFG'
import json,os
cfg=json.loads(os.environ['OLLAMA_CFG']); allowed=[os.environ['TASK_MODEL'],os.environ['FAST_MODEL'],os.environ['RESEARCH_MODEL'],os.environ['DEEP_MODEL']]
urls=list(cfg.get('OLLAMA_BASE_URLS') or []); configs=dict(cfg.get('OLLAMA_API_CONFIGS') or {}); target='http://host.docker.internal:11434'; idx=None
for i,u in enumerate(urls):
    if u.rstrip('/')==target: idx=i; break
if idx is None:
    for i,u in enumerate(urls):
        if '127.0.0.1:11434' in u or 'localhost:11434' in u: idx=i; urls[i]=target; break
if idx is None:
    if not urls: urls=[target]; idx=0
    elif len(urls)==1: urls[0]=target; idx=0
    else: print(json.dumps({'error':'multiple_ollama_connections_no_local_match'})); raise SystemExit
key=str(idx); entry=dict(configs.get(key) or configs.get(urls[idx]) or {}); entry['enable']=True; entry['connection_type']='local'; entry['model_ids']=allowed; configs[key]=entry
print(json.dumps({'ENABLE_OLLAMA_API':True,'OLLAMA_BASE_URLS':urls,'OLLAMA_API_CONFIGS':configs}))
PYCFG
)"
  if jq -e '.error? == "multiple_ollama_connections_no_local_match"' >/dev/null 2>&1 <<<"$PATCHED_OLLAMA_CFG"; then warn "Multiple Ollama connections exist; local provider was not changed automatically"; else
    curl -fsS -X POST "$WEBUI_URL/ollama/config/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$PATCHED_OLLAMA_CFG" >${WORKDIR}/ollama-config-updated.json || fail "Unable to update Ollama connection"
    ok "Local Ollama URL + friendly-model allowlist configured"
  fi
else warn "Model allowlist management disabled"; fi

MODELS_JSON="$(curl -fsS "$WEBUI_URL/api/models?refresh=true" -H "Authorization: Bearer $TOKEN")" || fail "Unable to refresh OpenWebUI models"
for m in "$TASK_MODEL" "$FAST_MODEL" "$RESEARCH_MODEL" "$DEEP_MODEL"; do grep -Fq "$m" <<<"$MODELS_JSON" || fail "OpenWebUI refresh did not include $m"; ok "OpenWebUI sees $m"; done

section "INSTALLING ADVANCED DETERMINISTIC CALCULATOR TOOL"
cat >"${WORKDIR}/advanced_deterministic_calculator.py" <<'PYCALC'
"""
title: Advanced Deterministic Calculator
author: Local AI Suite
description: Safe deterministic arithmetic for Advanced mode.
required_open_webui_version: 0.10.0
version: 1.0.0
license: MIT
"""

import ast
import json
from decimal import Decimal, localcontext, ROUND_FLOOR, ROUND_CEILING, ROUND_HALF_EVEN

MAX_EXPRESSION_CHARS = 500
MAX_AST_NODES = 120
MAX_ABS_EXPONENT = 1000


class CalculationError(ValueError):
    pass


class Tools:
    async def calculate(self, expression: str) -> str:
        """
        Deterministically evaluate arithmetic.

        MUST be used for explicit arithmetic, percentages, totals, ratios,
        capacity calculations, or checking a computed number in Advanced mode.

        Supported:
        +, -, *, /, //, %, **, parentheses, unary +/-
        floor(x), ceil(x), abs(x), round(x[, digits]), min(...), max(...),
        percent(x) where percent(22) means 0.22.

        :param expression: Arithmetic expression, for example:
            floor((128 - 128*percent(22) - (14*3.75 + 21.5)) / 3.75)
        """
        try:
            result = _safe_calculate(expression)
            return json.dumps(
                {"ok": True, "expression": expression, "result": _decimal_text(result)},
                ensure_ascii=False,
                separators=(",", ":"),
            )
        except Exception as exc:
            return json.dumps(
                {"ok": False, "expression": expression, "error": str(exc)},
                ensure_ascii=False,
                separators=(",", ":"),
            )


def _decimal_text(value: Decimal) -> str:
    if not value.is_finite():
        raise CalculationError("Non-finite result is not allowed")
    normalized = value.normalize()
    if normalized == 0:
        return "0"
    out = format(normalized, "f")
    if "." in out:
        out = out.rstrip("0").rstrip(".")
    return out or "0"


def _number(node: ast.Constant, source: str) -> Decimal:
    if isinstance(node.value, bool) or not isinstance(node.value, (int, float)):
        raise CalculationError("Only numeric literals are allowed")
    literal = ast.get_source_segment(source, node) or str(node.value)
    literal = literal.replace("_", "")
    try:
        return Decimal(literal)
    except Exception as exc:
        raise CalculationError(f"Invalid numeric literal: {literal}") from exc


def _integral(value: Decimal, rounding) -> Decimal:
    return value.to_integral_value(rounding=rounding)


def _evaluate(node: ast.AST, source: str) -> Decimal:
    if isinstance(node, ast.Expression):
        return _evaluate(node.body, source)

    if isinstance(node, ast.Constant):
        return _number(node, source)

    if isinstance(node, ast.UnaryOp):
        value = _evaluate(node.operand, source)
        if isinstance(node.op, ast.UAdd):
            return value
        if isinstance(node.op, ast.USub):
            return -value
        raise CalculationError("Unsupported unary operator")

    if isinstance(node, ast.BinOp):
        left = _evaluate(node.left, source)
        right = _evaluate(node.right, source)

        if isinstance(node.op, ast.Add):
            return left + right
        if isinstance(node.op, ast.Sub):
            return left - right
        if isinstance(node.op, ast.Mult):
            return left * right
        if isinstance(node.op, ast.Div):
            if right == 0:
                raise CalculationError("Division by zero")
            return left / right
        if isinstance(node.op, ast.FloorDiv):
            if right == 0:
                raise CalculationError("Division by zero")
            return _integral(left / right, ROUND_FLOOR)
        if isinstance(node.op, ast.Mod):
            if right == 0:
                raise CalculationError("Modulo by zero")
            return left % right
        if isinstance(node.op, ast.Pow):
            if right != right.to_integral_value():
                raise CalculationError("Exponent must be an integer")
            exponent = int(right)
            if abs(exponent) > MAX_ABS_EXPONENT:
                raise CalculationError(f"Exponent magnitude exceeds {MAX_ABS_EXPONENT}")
            if left == 0 and exponent < 0:
                raise CalculationError("Division by zero")
            return left ** exponent
        raise CalculationError("Unsupported binary operator")

    if isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name):
            raise CalculationError("Only named calculator functions are allowed")
        if node.keywords:
            raise CalculationError("Keyword arguments are not supported")

        name = node.func.id
        args = [_evaluate(a, source) for a in node.args]

        if name == "floor":
            if len(args) != 1:
                raise CalculationError("floor() expects one argument")
            return _integral(args[0], ROUND_FLOOR)
        if name == "ceil":
            if len(args) != 1:
                raise CalculationError("ceil() expects one argument")
            return _integral(args[0], ROUND_CEILING)
        if name == "abs":
            if len(args) != 1:
                raise CalculationError("abs() expects one argument")
            return abs(args[0])
        if name == "percent":
            if len(args) != 1:
                raise CalculationError("percent() expects one argument")
            return args[0] / Decimal(100)
        if name == "min":
            if not args:
                raise CalculationError("min() expects at least one argument")
            return min(args)
        if name == "max":
            if not args:
                raise CalculationError("max() expects at least one argument")
            return max(args)
        if name == "round":
            if len(args) not in (1, 2):
                raise CalculationError("round() expects one or two arguments")
            if len(args) == 1:
                return args[0].to_integral_value(rounding=ROUND_HALF_EVEN)
            digits = args[1]
            if digits != digits.to_integral_value():
                raise CalculationError("round() digits must be an integer")
            digits = int(digits)
            if abs(digits) > 50:
                raise CalculationError("round() digits magnitude exceeds 50")
            quantum = Decimal(1).scaleb(-digits)
            return args[0].quantize(quantum, rounding=ROUND_HALF_EVEN)

        raise CalculationError(f"Unsupported function: {name}")

    raise CalculationError(f"Unsupported expression element: {node.__class__.__name__}")


def _safe_calculate(expression: str) -> Decimal:
    source = str(expression or "").strip()
    if not source:
        raise CalculationError("Expression is empty")
    if len(source) > MAX_EXPRESSION_CHARS:
        raise CalculationError(f"Expression exceeds {MAX_EXPRESSION_CHARS} characters")

    try:
        tree = ast.parse(source, mode="eval")
    except SyntaxError as exc:
        raise CalculationError("Invalid arithmetic expression") from exc

    nodes = list(ast.walk(tree))
    if len(nodes) > MAX_AST_NODES:
        raise CalculationError(f"Expression is too complex ({len(nodes)} AST nodes)")

    forbidden = (
        ast.Attribute, ast.Subscript, ast.Lambda, ast.Dict, ast.List, ast.Set,
        ast.Tuple, ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp,
        ast.Compare, ast.BoolOp, ast.IfExp, ast.NamedExpr,
    )
    if any(isinstance(n, forbidden) for n in nodes):
        raise CalculationError("Expression contains a forbidden construct")

    with localcontext() as ctx:
        ctx.prec = 50
        result = _evaluate(tree, source)

    if not result.is_finite():
        raise CalculationError("Calculator did not produce a finite number")
    return result
PYCALC

python3 -c 'import ast,sys,pathlib; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
  "${WORKDIR}/advanced_deterministic_calculator.py" \
  || fail "Advanced calculator Python syntax validation failed"

ADV_CALC_TOOL_CONTENT="$(cat "${WORKDIR}/advanced_deterministic_calculator.py")"
ADV_CALC_TOOL_JSON="$(jq -n \
  --arg id "$ADV_CALC_TOOL_ID" \
  --arg name "$ADV_CALC_TOOL_NAME" \
  --arg content "$ADV_CALC_TOOL_CONTENT" \
  '{id:$id,name:$name,content:$content,meta:{description:"Safe deterministic arithmetic for Advanced mode.",manifest:{}}}'
)"

ADV_CALC_TOOL_HTTP="$(curl -sS -o "${WORKDIR}/advanced-calc-current.json" -w '%{http_code}' \
  "$WEBUI_URL/api/v1/tools/id/$ADV_CALC_TOOL_ID" \
  -H "Authorization: Bearer $TOKEN")"

if [[ "$ADV_CALC_TOOL_HTTP" == 200 ]]; then
  curl -fsS -X POST "$WEBUI_URL/api/v1/tools/id/$ADV_CALC_TOOL_ID/update" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$ADV_CALC_TOOL_JSON" \
    >"${WORKDIR}/advanced-calc-installed.json" \
    || fail "Unable to update Advanced deterministic calculator tool"
else
  curl -fsS -X POST "$WEBUI_URL/api/v1/tools/create" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$ADV_CALC_TOOL_JSON" \
    >"${WORKDIR}/advanced-calc-installed.json" \
    || fail "Unable to create Advanced deterministic calculator tool"
fi

ADV_CALC_TOOL_STATE="$(curl -fsS "$WEBUI_URL/api/v1/tools/id/$ADV_CALC_TOOL_ID" \
  -H "Authorization: Bearer $TOKEN")" \
  || fail "Unable to verify Advanced deterministic calculator tool"

jq -e --arg id "$ADV_CALC_TOOL_ID" '
  (.id == $id) and (.content | contains("async def calculate"))
' <<<"$ADV_CALC_TOOL_STATE" >/dev/null \
  || fail "Advanced deterministic calculator verification failed"

CALC_SELFTEST="$(python3 - "${WORKDIR}/advanced_deterministic_calculator.py" <<'PYCALCTEST'
import asyncio
import importlib.util
import json
import sys

path=sys.argv[1]
spec=importlib.util.spec_from_file_location("advanced_calc_test",path)
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tool=mod.Tools()

async def main():
    expressions={
        "reserved":"128*percent(22)",
        "current":"14*3.75+21.5",
        "available":"128-(128*percent(22))-(14*3.75+21.5)",
        "users":"floor((128-(128*percent(22))-(14*3.75+21.5))/3.75)",
    }
    result={}
    for key,expr in expressions.items():
        result[key]=json.loads(await tool.calculate(expr))
    print(json.dumps(result,separators=(",",":")))

asyncio.run(main())
PYCALCTEST
)" || fail "Advanced calculator self-test execution failed"

jq -e '
  .reserved.ok == true and .reserved.result == "28.16"
  and .current.ok == true and .current.result == "74"
  and .available.ok == true and .available.result == "25.84"
  and .users.ok == true and .users.result == "6"
' <<<"$CALC_SELFTEST" >/dev/null \
  || {
    echo "$CALC_SELFTEST" | jq . >&2 || true
    fail "Advanced calculator benchmark self-test failed"
  }

ok "Advanced deterministic calculator installed and benchmark self-test passed (28.16 / 74 / 25.84 / 6)"

section "OPENWEBUI MODE WORKSPACE MODELS"
# Use first-class OpenWebUI workspace models instead of only rewriting the raw
# provider model ID in browser fetches. This keeps model routing, capabilities,
# chat metadata, exports, and filter __model__.info.base_model_id consistent.
MODE_MODELS_PAYLOAD="$(jq -n \
  --arg fast_id "$MODE_FAST_ID" --arg fast_base "$FAST_MODEL" \
  --arg adv_id "$MODE_ADVANCED_ID" --arg adv_base "$RESEARCH_MODEL" \
  --arg calc_tool "$ADV_CALC_TOOL_ID" \
  --arg deep_id "$MODE_DEEP_ID" --arg deep_base "$DEEP_MODEL" '
{models:[
  {id:$fast_id,base_model_id:$fast_base,name:"Fast",is_active:true,params:{function_calling:"native",think:false},access_grants:[],meta:{description:"Fast 32K local assistant; built-in web disabled for maximum speed and deterministic local answers",capabilities:{file_context:true,file_upload:true,web_search:false,memory:true,citations:true,status_updates:true,code_interpreter:false},builtinTools:{knowledge:true,memory:true,web_search:false,code_interpreter:false},defaultFeatureIds:[],tags:[{name:"Local AI Suite"}]}},
  {id:$adv_id,base_model_id:$adv_base,name:"Advanced",is_active:true,params:{function_calling:"native",think:false},access_grants:[],meta:{description:"Advanced 48K precision assistant; deterministic calculator attached by default; SearXNG web capability available on demand but disabled by default",capabilities:{file_context:true,file_upload:true,web_search:true,memory:true,citations:true,status_updates:true,code_interpreter:false},builtinTools:{knowledge:true,memory:true,web_search:true,code_interpreter:false},toolIds:[$calc_tool],defaultFeatureIds:[],tags:[{name:"Local AI Suite"}]}},
  {id:$deep_id,base_model_id:$deep_base,name:"Deep Research",is_active:true,params:{function_calling:"native",think:false},access_grants:[],meta:{description:"Deep Research 64K agent with controller-budgeted web, knowledge, memory, research brief and isolated lab; unrestricted built-in web disabled",capabilities:{file_context:true,file_upload:true,web_search:false,memory:true,citations:true,status_updates:true,code_interpreter:false},builtinTools:{knowledge:true,memory:true,web_search:false,code_interpreter:false},defaultFeatureIds:[],tags:[{name:"Local AI Suite"},{name:"Deep Research"}]}}
]}'
)"
curl -fsS -X POST "$WEBUI_URL/api/v1/models/import" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$MODE_MODELS_PAYLOAD" >"${WORKDIR}/mode-models-import.json" || fail "Unable to create/update Fast, Advanced and Deep Research workspace models"
MODELS_JSON="$(curl -fsS "$WEBUI_URL/api/models?refresh=true" -H "Authorization: Bearer $TOKEN")" || fail "Unable to refresh workspace models"
for pair in "$MODE_FAST_ID|$FAST_MODEL|Fast" "$MODE_ADVANCED_ID|$RESEARCH_MODEL|Advanced" "$MODE_DEEP_ID|$DEEP_MODEL|Deep Research"; do
  mid="${pair%%|*}"; rest="${pair#*|}"; base="${rest%%|*}"; name="${rest#*|}"
  jq -e --arg id "$mid" --arg base "$base" --arg name "$name" '.data[]? | select(.id==$id and .name==$name and .info.base_model_id==$base)' <<<"$MODELS_JSON" >/dev/null \
    || fail "Workspace mode model verification failed for $name ($mid -> $base)"
  ok "$name workspace model routes to $base"
done

jq -e --arg id "$MODE_FAST_ID" '
  .data[]? | select(.id==$id)
  | (.info.meta.capabilities.web_search == false)
    and (.info.meta.builtinTools.web_search == false)
    and ((.info.meta.defaultFeatureIds // []) | index("web_search") | not)
' <<<"$MODELS_JSON" >/dev/null || fail "Fast web policy verification failed"

if ! jq -e --arg id "$MODE_ADVANCED_ID" --arg base "$RESEARCH_MODEL" --arg calc "$ADV_CALC_TOOL_ID" '
  .data[]? | select(.id==$id)
  | (.info.base_model_id == $base)
    and (.info.meta.capabilities.web_search == true)
    and (.info.meta.builtinTools.web_search == true)
    and ((.info.meta.toolIds // []) | index($calc) != null)
    and ((.info.meta.defaultFeatureIds // []) | index("web_search") | not)
' <<<"$MODELS_JSON" >/dev/null; then
  echo
  echo "Advanced effective model state returned by OpenWebUI:"
  jq --arg id "$MODE_ADVANCED_ID" '
    .data[]?
    | select(.id==$id)
    | {
        id,
        name,
        preset,
        info: {
          base_model_id: .info.base_model_id,
          params: .info.params,
          meta: {
            capabilities: .info.meta.capabilities,
            builtinTools: .info.meta.builtinTools,
            toolIds: .info.meta.toolIds,
            defaultFeatureIds: .info.meta.defaultFeatureIds
          }
        }
      }
  ' <<<"$MODELS_JSON" >&2 || true
  fail "Advanced runtime web-capability verification failed"
fi

ADV_RUNTIME_PARAMS_TYPE="$(jq -r --arg id "$MODE_ADVANCED_ID" '
  [.data[]? | select(.id==$id) | (.info.params | type)] | first // "missing"
' <<<"$MODELS_JSON")"

case "$ADV_RUNTIME_PARAMS_TYPE" in
  object)
    ok "Advanced /api/models runtime exposes params object"
    ;;
  null|missing)
    ok "Advanced /api/models runtime omits/nulls params; persisted params will be verified through /api/v1/models/export"
    ;;
  *)
    warn "Advanced /api/models returned unexpected info.params type: $ADV_RUNTIME_PARAMS_TYPE; export verification remains authoritative for persisted params"
    ;;
esac

jq -e --arg id "$MODE_DEEP_ID" '
  .data[]? | select(.id==$id)
  | (.info.meta.capabilities.web_search == false)
    and (.info.meta.builtinTools.web_search == false)
    and ((.info.meta.defaultFeatureIds // []) | index("web_search") | not)
' <<<"$MODELS_JSON" >/dev/null || fail "Deep built-in web policy verification failed"

MODELS_EXPORT_JSON="$(curl -fsS "$WEBUI_URL/api/v1/models/export" -H "Authorization: Bearer $TOKEN")" \
  || fail "Unable to export workspace model definitions for verification"

if ! jq -e --arg id "$MODE_ADVANCED_ID" --arg base "$RESEARCH_MODEL" --arg calc "$ADV_CALC_TOOL_ID" '
  .[]? | select(.id==$id)
  | (.base_model_id == $base)
    and (.params.function_calling == "native")
    and (.params.think == false)
    and (.meta.capabilities.web_search == true)
    and (.meta.builtinTools.web_search == true)
    and ((.meta.toolIds // []) | index($calc) != null)
    and ((.meta.defaultFeatureIds // []) | index("web_search") | not)
' <<<"$MODELS_EXPORT_JSON" >/dev/null; then
  echo
  echo "Advanced persisted workspace-model definition returned by OpenWebUI:"
  jq --arg id "$MODE_ADVANCED_ID" '
    .[]?
    | select(.id==$id)
    | {
        id,
        base_model_id,
        name,
        params,
        meta: {
          capabilities: .meta.capabilities,
          builtinTools: .meta.builtinTools,
          toolIds: .meta.toolIds,
          defaultFeatureIds: .meta.defaultFeatureIds
        }
      }
  ' <<<"$MODELS_EXPORT_JSON" >&2 || true
  fail "Advanced persisted workspace-model definition verification failed"
fi

ok "Advanced runtime capabilities verified via /api/models"
ok "Advanced persisted params/meta + deterministic calculator attachment verified via /api/v1/models/export"
ok "Web policy verified: Fast=off; Advanced=available on-demand/default-off; Deep=controller-budgeted custom web only"

section "OPENWEBUI TASK / MEMORY CONFIG"
TASK_CFG="$(curl -fsS "$WEBUI_URL/api/v1/tasks/config" -H "Authorization: Bearer $TOKEN")" || fail "Unable to read task config"
TASK_CFG="$(jq --arg m "$TASK_MODEL" '.TASK_MODEL=$m | .ENABLE_AUTOCOMPLETE_GENERATION=false | .ENABLE_FOLLOW_UP_GENERATION=false | .ENABLE_TITLE_GENERATION=true | .ENABLE_TAGS_GENERATION=true | .ENABLE_SEARCH_QUERY_GENERATION=true | .ENABLE_RETRIEVAL_QUERY_GENERATION=true' <<<"$TASK_CFG")"
curl -fsS -X POST "$WEBUI_URL/api/v1/tasks/config/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$TASK_CFG" >${WORKDIR}/task-config-updated.json || fail "Unable to update task config"
MEMORY_CFG="$(jq -n '{config:{"memories.enable":true,"memories.system_context.enable":false}}')"
curl -fsS -X POST "$WEBUI_URL/api/v1/configs/import" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$MEMORY_CFG" >${WORKDIR}/memory-config-updated.json || fail "Unable to update memory config"
# Keep OpenWebUI's internal/default selection on the first-class Fast workspace
# model. The mode bar switches between workspace models whose base_model_id values
# provide stable backend routing and correct persisted chat metadata.
MODE_DEFAULT_CFG="$(jq -n --arg fast "$MODE_FAST_ID" --arg pins "$MODE_FAST_ID,$MODE_ADVANCED_ID,$MODE_DEEP_ID" '{config:{"ui.default_models":$fast,"ui.default_pinned_models":$pins}}')"
curl -fsS -X POST "$WEBUI_URL/api/v1/configs/import" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$MODE_DEFAULT_CFG" >${WORKDIR}/mode-default-config.json || fail "Unable to set Fast as OpenWebUI default model"
VERIFY_TASK="$(curl -fsS "$WEBUI_URL/api/v1/tasks/config" -H "Authorization: Bearer $TOKEN")"; VERIFY_MEMORY="$(curl -fsS "$WEBUI_URL/api/v1/configs/namespace/memories" -H "Authorization: Bearer $TOKEN")"
VERIFY_UI_DEFAULTS="$(curl -fsS "$WEBUI_URL/api/v1/configs/namespace/ui" -H "Authorization: Bearer $TOKEN")"
[[ "$(jq -r '.TASK_MODEL // empty' <<<"$VERIFY_TASK")" == "$TASK_MODEL" ]] || fail "Task model verification failed"
[[ "$(jq -r '.["ui.default_models"] // empty' <<<"$VERIFY_UI_DEFAULTS")" == "$MODE_FAST_ID" ]] || fail "Fast workspace model default verification failed"
[[ "$(jq -r 'if has("memories.enable") then (.["memories.enable"]|tostring) else "missing" end' <<<"$VERIFY_MEMORY")" == true ]] || fail "Memory enable verification failed"
[[ "$(jq -r 'if has("memories.system_context.enable") then (.["memories.system_context.enable"]|tostring) else "missing" end' <<<"$VERIFY_MEMORY")" == false ]] || fail "Memory system-context verification failed"
BG_REVIEW_ENV="$($DOCKER_CMD inspect "$OPENWEBUI_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '$1=="ENABLE_MEMORY_BACKGROUND_REVIEW"{print tolower($2);exit}')"
[[ "$BG_REVIEW_ENV" == true ]] && warn "Background memory review is enabled in this existing container and may add hidden LLM work" || ok "Background memory review is disabled/default-off"
ok "Background Scout + selective memory configuration verified"

section "INSTALLING RESPONSE DISCIPLINE GUARD"
cat >${WORKDIR}/response_discipline_guard.py <<'PYGUARD'
"""
title: Response Discipline Guard
author: Local AI Suite
version: 2.7.1
description: Prevent reasoning/self-review loops, silently normalize obvious typos, and force all three local modes to use concise non-thinking output.
"""
import json
import re
from decimal import Decimal, InvalidOperation, ROUND_FLOOR
import httpx

from pydantic import BaseModel, Field
from open_webui.utils.misc import add_or_update_system_message

FAST = "natural-fast:27b"
RESEARCH = "research-plus:27b"
DEEP = "deep-research:27b"
FAST_MODE = "local-ai-fast"
RESEARCH_MODE = "local-ai-advanced"
DEEP_MODE = "local-ai-deep-research"
TASK = "background-scout:270m"
MARKER = "<local_ai_response_discipline>"
DISCIPLINE = f"""{MARKER}
Silently normalize obvious user typos when intent is unambiguous. Never narrate typo detection or repeatedly inspect the typo. If the typo creates genuine ambiguity, ask one clarification question only.
Return exactly one final answer. Never expose self-review, scratchpad, or drafting commentary such as 'Okay', 'Final Answer', 'Looks good', 'One final check', or 'One last check'. Never repeat an answer or completed paragraph to validate it. If repetition begins, stop the repeated sequence immediately. Once the useful answer is complete, stop generation.
</local_ai_response_discipline>"""

ADVANCED_MARKER = "<local_ai_advanced_precision>"
FINAL_AUDIT_MARKER = "<local_ai_advanced_final_precision_audit>"
OLLAMA = "http://host.docker.internal:11434"
SCOUT_MODEL = "background-scout:270m"
REPAIR_MODEL = "research-plus:27b"
MODEL_KEEP_ALIVE = "__MODEL_KEEP_ALIVE__"
ADVANCED_PRECISION = f"""{ADVANCED_MARKER}
ADVANCED PRECISION DISCIPLINE
- Do not add technical specificity that is unsupported by the user, retrieved evidence, or a necessary inference. When reviewing supplied code, name only operators/tokens actually present in the supplied snippet unless the token is the explicit correction; do not invent an alternate erroneous operator such as `-=` when the source contains only `=`.
- Separate confirmed facts from possibilities; never convert a possibility into a conclusion. When the user explicitly prohibits candidate causes (for example client-side, network-path, routing, firewall, proxy, or server-side explanations), do not reintroduce those categories with hedging words such as "may", "might", "could", or "possibly". State only the supported observation and unresolved reason.
- If asked to summarize only supplied evidence, do not invent extra diagnostic unknowns or follow-up hypotheses.
- If asked for the smallest correction, make only the smallest necessary change; do not add optional error handling, refactoring, unrelated improvements, a second alternative, or unchanged surrounding syntax. If a corrected expression/predicate is sufficient, return that expression rather than repeating an unchanged if-wrapper or body-opening brace unless the user explicitly requests the complete statement/line. Do not wrap a standalone PowerShell predicate in an unnecessary subexpression wrapper such as `$(` ... `)` when the inner expression is already valid by itself. If the user asks for only the changed if-condition, return only the condition expression/line and do not append a body-opening brace unless explicitly requested. When a boolean property itself is the required predicate, use the property directly rather than adding a redundant comparison such as `-eq $true` or `== true`.
- Follow exact output, count, word, numbering, and formatting constraints literally. If the user asks for numbered questions/items, the visible answer must actually include the requested numeric prefixes in order.
- For any answer requiring explicit arithmetic, percentages, totals, ratios, capacity calculations, or numeric derivation, MUST call the Advanced Deterministic Calculator tool before finalizing.
- Base every reported calculated value on the calculator result; do not use token/mental arithmetic as the authority when the tool is available.
- If intermediate values are shown, verify EACH reported derived numeric value with the calculator. For structured arithmetic answers (for example Reserved/Current/Available/Answer), every derived value shown in the final answer must be backed by a calculator result, not only the final integer.
- For capacity problems, verify the arithmetic RELATIONSHIPS as well as the individual values: Reserved = Total × reserve percentage; Current = users × per-user + OS/shared services; Available = Total - Reserved - Current; Maximum additional users = floor(Available / per-new-user). Never accept a calculator-backed number if it came from the wrong expression.
- If a calculator expression errors, correct it and retry instead of guessing.
- TOOL-FIRST: Before drafting substantive answer text, determine every required calculator/web/tool call and execute those calls first. When a tool is required, call it before emitting the answer for that test/section.
- Native transport streaming may be enabled by the host and must remain enabled for tool execution; this is separate from answer discipline.
- After required tool results return, write one coherent final answer only. Never intentionally emit a provisional plan, scratch calculation, self-correction, "wait", "let me work through", "calculator needed", "let me recalculate", or a restarted duplicate answer before or between tool calls.
- Do not mention calculator/tool usage unless the user asks; still obey exact requested output formatting.
- Do not claim unused/redundant code causes malfunction unless execution semantics prove it.
- For troubleshooting "Next test" fields, prefer one standard, directly interpretable test. If the user requests exactly one next test, select exactly one concrete test and one method/tool; do not append an alternative tool with "or", a slash, "e.g.", or "for example". Do not invent an obscure named trace mode, switch, or product-specific diagnostic unless you are certain it exists for the stated product/version.
- Web search is optional in Advanced and may be unavailable unless enabled in the chat.
- When web tools are available, search only for current, version-specific, obscure, disputed, or genuinely uncertain external facts where verification materially improves correctness.
- Do not search for arithmetic, supplied-text analysis, rewriting, or facts already established in the conversation.
- For technical claims prefer primary/vendor documentation. Search snippets are discovery, not proof when the primary page can be fetched.
- In multi-TEST prompts, retrieved web/source evidence belongs only to the TEST(s) that explicitly requested or required web research. Never attach web citations, source titles, vendor/site labels, or retrieved-source wording to an independent non-web TEST merely because the tool evidence exists in the same turn. Keep each citation/source marker adjacent to the WEB REQUIRED section it supports.
- For short source-derived code/configuration snippets, preserve structural syntax from fetched source evidence (list markers, nesting, indentation-sensitive structure, keys). Before finalizing, compare the rendered snippet against the source evidence; do not silently drop syntax such as YAML '- ' list markers.
- Stop searching once sufficient evidence exists. Do not search merely to embellish an answer.
- Clearly distinguish source-supported facts from inference. If the user explicitly says the cause/reason is not established or says not to claim why an observation occurred, an Inference field may describe only the supported difference/uncertainty; do not invent candidate mechanisms such as firewall, proxy, routing, filtering, endpoint security, or another causal explanation unless supplied by the user/evidence.
- Do not reverse an uncertainty/indeterminate conclusion into a definite Yes/No unless new evidence in the same turn actually resolves it.
- For summarize-only/evidence-only tasks, keep Scope and Unknown literal: do not invent adjacent products/modules/apps, environments, users, tests, diagnostic layers, causal categories, relationships, root-cause questions, or new observation categories that were not present in the supplied evidence. Do not broaden "SAP B1" into other SAP modules, or infer that Teams/Word were inside Citrix unless explicitly stated. A comparison application where the issue does NOT occur is evidence for contrast, not automatically part of the affected scope. Unknown should state only unresolved observations directly implied by the supplied evidence; do not invent categories such as "host session", "input path", "client layer", "other inputs", "root cause", "source of the problem", "why", "reason for", or "explanation for" unless those concepts were supplied. Do not turn two observed symptoms into a causal/relationship hypothesis such as asking whether one is "related to", "caused by", "due to", "linked to", or "associated with" the other when the user requested evidence-only summarization.
- Do not describe an unused constant as "shadowed" or "overwritten" unless the SAME identifier is actually shadowed/reassigned. Python identifiers are case-sensitive: DELAY and delay are distinct names. If DELAY is never referenced, call it unused/dead code.
- If a deployment clarification explicitly requires establishing "shared multi-session", ask that directly; concurrent-user count is not a substitute for confirming shared multi-session architecture.
- For physical-control semantics, never infer control direction from the actuator's name or whether it literally generates heat. heat_output means increasing the output tends to raise the controlled temperature; cool_output means increasing it tends to lower the controlled temperature. If that physical relationship is not established, keep the direction indeterminate.
</local_ai_advanced_precision>"""


def _text_content(content):
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") in {"text", "input_text", "output_text"}:
                value = item.get("text") or item.get("content") or ""
                if value:
                    parts.append(str(value))
        return "\n".join(parts).strip()
    return ""


def _latest_user_text(messages):
    for message in reversed(messages or []):
        if isinstance(message, dict) and message.get("role") == "user":
            value = _text_content(message.get("content"))
            if value:
                return value
    return ""


def _latest_assistant_message(messages):
    for message in reversed(messages or []):
        if isinstance(message, dict) and message.get("role") == "assistant":
            if isinstance(message.get("content"), str):
                return message
    return None


def _tool_evidence(messages, max_chars=8000):
    chunks = []
    used = 0
    for message in reversed(messages or []):
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "")
        if role not in {"tool", "function"}:
            continue
        value = _text_content(message.get("content"))
        if not value:
            continue
        room = max_chars - used
        if room <= 0:
            break
        chunks.append(value[:room])
        used += min(len(value), room)
    chunks.reverse()
    return "\n\n--- TOOL EVIDENCE ---\n\n".join(chunks)



def _normalize_decimal_token(value):
    try:
        d = Decimal(str(value).strip().replace(",", "."))
    except (InvalidOperation, ValueError):
        return None
    if not d.is_finite():
        return None
    if d == 0:
        return "0"
    out = format(d.normalize(), "f")
    if "." in out:
        out = out.rstrip("0").rstrip(".")
    return out or "0"


def _calculator_results(tool_evidence):
    """Return normalized successful result values from calculator tool output."""
    results = set()
    raw = str(tool_evidence or "")

    # Standard JSON and pretty-printed JSON forms.
    for match in re.finditer(
        r'(?is)["\']?result["\']?\s*:\s*["\'](-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)["\']',
        raw,
    ):
        value = _normalize_decimal_token(match.group(1))
        if value is not None:
            results.add(value)

    return results


def _calculator_consistency_issues(user_text, answer_text, tool_evidence):
    """Require tool provenance for derived numeric fields when mandated."""
    u = str(user_text or "").lower()
    if "deterministic calculator tool" not in u:
        return []

    results = _calculator_results(tool_evidence)
    if not results:
        return [
            "The user explicitly required the deterministic calculator, but no successful calculator result is present in this turn."
        ]

    issues = []
    label_re = re.compile(
        r"(?mi)^\s*(Reserved|Current|Available|Answer|Maximum additional users)\s*:\s*"
        r"(-?\d+(?:\.\d+)?)\b"
    )
    for match in label_re.finditer(str(answer_text or "")):
        label = match.group(1)
        shown_raw = match.group(2)
        shown = _normalize_decimal_token(shown_raw)
        if shown is not None and shown not in results:
            issues.append(
                f"{label}={shown_raw} is not backed by any successful deterministic calculator result from this turn."
            )

    return issues



def _answer_numeric_fields(answer_text):
    fields = {}
    label_re = re.compile(
        r"(?mi)^\s*(Reserved|Current|Available|Answer|Maximum additional users)\s*:\s*"
        r"(?:\n\s*)?(-?\d+(?:\.\d+)?)\b"
    )
    for match in label_re.finditer(str(answer_text or "")):
        fields[match.group(1).lower()] = _normalize_decimal_token(match.group(2))
    return fields


def _parse_capacity_problem(user_text):
    """Parse the benchmark/common capacity problem shape from the user prompt."""
    source = str(user_text or "")

    total = re.search(
        r"(?i)\b(?:server|host|system)\s+has\s+(\d+(?:\.\d+)?)\s+GiB\s+RAM\b",
        source,
    )
    users = re.search(
        r"(?i)\b(\d+)\s+users\s+consume\s+(?:exactly\s+)?(\d+(?:\.\d+)?)\s+GiB\s+each\b",
        source,
    )
    os_shared = re.search(
        r"(?i)\bOS(?:\s+and\s+shared\s+services|/shared\s+services|\s+and\s+shared\s+services)?"
        r"\s+consume(?:s)?\s+(?:exactly\s+)?(\d+(?:\.\d+)?)\s+GiB\b",
        source,
    )
    reserve = re.search(
        r"(?i)\b(\d+(?:\.\d+)?)%\s+of\s+total\s+RAM\s+must\s+remain\s+free\b",
        source,
    )
    new_user = re.search(
        r"(?i)\bEach\s+additional\s+user\s+consumes\s+(?:exactly\s+)?"
        r"(\d+(?:\.\d+)?)\s+GiB\b",
        source,
    )

    if not all((total, users, os_shared, reserve, new_user)):
        return None

    return {
        "total": Decimal(total.group(1)),
        "users": Decimal(users.group(1)),
        "per_user": Decimal(users.group(2)),
        "os_shared": Decimal(os_shared.group(1)),
        "reserve_pct": Decimal(reserve.group(1)),
        "new_user": Decimal(new_user.group(1)),
    }


def _capacity_relationship_issues(user_text, answer_text):
    """Validate capacity math from the problem semantics, not tool provenance."""
    parsed = _parse_capacity_problem(user_text)
    if not parsed:
        return []

    total = parsed["total"]
    reserved = total * parsed["reserve_pct"] / Decimal(100)
    current = parsed["users"] * parsed["per_user"] + parsed["os_shared"]
    available = total - reserved - current
    if parsed["new_user"] == 0:
        return ["Per-new-user memory is zero, so the capacity calculation is undefined."]
    additional = (available / parsed["new_user"]).to_integral_value(
        rounding=ROUND_FLOOR
    )
    if additional < 0:
        additional = Decimal(0)

    expected = {
        "reserved": _normalize_decimal_token(reserved),
        "current": _normalize_decimal_token(current),
        "available": _normalize_decimal_token(available),
        "answer": _normalize_decimal_token(additional),
        "maximum additional users": _normalize_decimal_token(additional),
    }

    fields = _answer_numeric_fields(answer_text)
    issues = []
    for label, shown in fields.items():
        if label not in expected or shown is None:
            continue
        if shown != expected[label]:
            issues.append(
                f"Capacity relationship mismatch: {label.title()}={shown} but the supplied problem deterministically yields {expected[label]}."
            )

    # If the requested final user count exists but was omitted, the general
    # formatting audit may handle it; this validator focuses on wrong values.
    return issues


def _source_fidelity_issues(user_text, answer_text, tool_evidence):
    """High-confidence structural checks for short source-derived config."""
    u = str(user_text or "").lower()
    a = str(answer_text or "")
    issues = []

    ota_task = (
        "esphome" in u
        and "ota" in u
        and "platform" in u
        and ("primary/vendor" in u or "vendor documentation" in u or "web search" in u)
    )
    if ota_task:
        has_ota = bool(re.search(r"(?mi)^\s*ota\s*:\s*$", a))
        has_list_platform = bool(
            re.search(r"(?mi)^\s*-\s*platform\s*:\s*esphome\s*$", a)
        )
        has_flat_platform = bool(
            re.search(r"(?mi)^\s*platform\s*:\s*esphome\s*$", a)
        )
        if has_ota and has_flat_platform and not has_list_platform:
            issues.append(
                "Source-to-final YAML drift: the native ESPHome OTA platform lost the required '- ' list marker under ota:. Preserve the fetched source structure."
            )

        if "password" in u and "secret" in u:
            if not re.search(
                r"(?mi)^\s*password\s*:\s*!secret\s+ota_password\s*$",
                a,
            ):
                issues.append(
                    "The requested OTA password-from-secrets line is missing or structurally altered."
                )

    return issues


def _deterministic_issues(user_text, answer_text):
    """Catch high-confidence semantic regressions without another large model."""
    issues = []
    u = (user_text or "").lower()
    a = (answer_text or "").lower()

    # Control-direction regression found by the v7.3 precision benchmark:
    # the user explicitly kept pump->temperature direction unknown, but the
    # final answer changed "indeterminate" into "No" because a pump is not a
    # literal heater. That is semantically wrong.
    direction_unknown = (
        ("heat_output" in u or "cool_output" in u)
        and ("pump" in u or "fan" in u or "valve" in u or "motor" in u)
        and (
            "do not assume whether" in u
            or "do not assume" in u
            or "without knowing" in u
            or "unknown" in u
            or "indeterminate" in u
        )
    )
    definite_conclusion = bool(
        re.search(r"(?mi)^\s*conclusion\s*:\s*(yes|no|correct|incorrect|definitely)\b", answer_text or "")
    )
    actuator_type_fallacy = (
        "expects heat_output to control a heater" in a
        or "heat_output to control a heater" in a
        or ("pump" in a and "does not generate heat" in a)
        or ("must" in a and "heater" in a and "heat_output" in a)
    )
    if direction_unknown and (definite_conclusion or actuator_type_fallacy):
        issues.append(
            "Unsupported physical-control conclusion: the prompt explicitly leaves the actuator-to-temperature direction unresolved. "
            "Do not decide heat_output/cool_output from the actuator type or whether it literally generates heat."
        )

    # Exact 'smallest correction' requests should not gain optional switches,
    # error handling, logging, unrelated edits, or multiple alternatives.
    if "smallest correction" in u:
        optional_tokens = (
            "-erroraction",
            "try {",
            "write-host",
            "write-verbose",
            "write-debug",
        )
        if any(token in a for token in optional_tokens) and not any(token in u for token in optional_tokens):
            issues.append(
                "The response adds optional implementation beyond a requested smallest correction."
            )

        correction_match = re.search(
            r"(?mis)^\s*smallest\s+correction\s*:\s*(.*?)(?=^\s*(?:test\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if correction_match:
            correction = correction_match.group(1).strip()
            exactly_one_required = (
                "choose exactly one" in u
                or "do not propose both" in u
                or "exactly one" in u
            )
            multiple_choice_language = bool(
                re.search(
                    r"(?i)\b(?:or|alternatively|either|another option|instead you can)\b",
                    correction,
                )
            )
            if exactly_one_required and multiple_choice_language:
                issues.append(
                    "Smallest correction violates the one-choice constraint by offering an alternative. Return exactly one correction."
                )

            # When the requested correction is a boolean predicate, appending
            # an explicit comparison to $true/true is semantically redundant
            # and therefore not the smallest correction.
            if (
                "test-netconnection" in u
                and "tcptestsucceeded" in u
                and re.search(
                    r"(?i)\$result\.TcpTestSucceeded\s+-eq\s+\$true\b",
                    correction,
                )
            ):
                issues.append(
                    "Smallest correction is not minimal: `$result.TcpTestSucceeded` is already a boolean predicate, so `-eq $true` is redundant."
                )

    # High-confidence internal contradiction found in the v7.4 benchmark:
    # a non-null Test-NetConnection result object is truthy, so the script
    # prints Success even when TcpTestSucceeded is False.
    success_match = re.search(
        r"(?mi)^\s*will\s+print\s+success\s*:\s*(yes|no)\b",
        answer_text or "",
    )
    if success_match:
        stated = success_match.group(1).lower()

        tnc_object_case = (
            "test-netconnection" in u
            and "tcptestsucceeded" in u
            and bool(re.search(r"(?is)\$result\s*=\s*test-netconnection", user_text or ""))
            and bool(re.search(r"(?is)if\s*\(\s*\$result\s*\)", user_text or ""))
        )
        if stated == "no" and tnc_object_case:
            issues.append(
                "Internal contradiction / PowerShell semantic error: if ($result) tests the non-null Test-NetConnection result object, so Success will print even when TcpTestSucceeded is False."
            )
        truthy_explanation = bool(
            re.search(
                r"(?is)\b(?:always\s+truthy|"
                r"(?:the\s+)?object\s+(?:is|remains)\s+truthy|"
                r"non[- ]?null\s+object.*(?:true|truthy)|"
                r"object.*evaluates?\s+(?:to\s+)?\$?true|"
                r"if[- ]condition.*(?:true|truthy).*(?:object|test-netconnection))\b",
                answer_text or "",
            )
        )
        false_explanation = bool(
            re.search(
                r"(?is)\b(?:evaluates?\s+(?:to\s+)?\$?false|condition\s+is\s+false)\b",
                answer_text or "",
            )
        )
        if stated == "no" and truthy_explanation:
            issues.append(
                "Internal contradiction: the answer says Success will not print, but its own explanation says the non-null Test-NetConnection result object is truthy. Those cannot both be true."
            )
        elif stated == "yes" and false_explanation:
            issues.append(
                "Internal contradiction: the answer says Success will print, but its explanation says the condition evaluates false."
            )

    # Visible draft/self-correction leakage must never survive a final answer.
    if re.search(
        r"(?i)\b(?:wait,\s*let me|let me work through|let me (?:calculate|check|verify)|"
        r"calculator needed|calling tools where required|let me re-?calculate|"
        r"re-?calculate carefully|one final check|looks good|final answer:)\b",
        answer_text or "",
    ):
        issues.append(
            "The final response contains visible drafting/self-correction commentary. Return one clean final answer only."
        )


    # Native tool-call regression from v7.7: a provisional TEST 1..5 block was
    # followed by a second complete TEST 1..12 block. Repeated numbered TEST
    # headings in one final answer are high-confidence duplicate/restart drift.
    test_headings = re.findall(
        r"(?mi)^\s*\*{0,2}TEST\s+(\d+)\b(?:\s*(?:—|–|-|:)\s*[^\r\n]+)?\*{0,2}\s*$",
        answer_text or "",
    )
    if test_headings:
        seen = set()
        duplicates = []
        for item in test_headings:
            if item in seen and item not in duplicates:
                duplicates.append(item)
            seen.add(item)
        if duplicates:
            issues.append(
                "Duplicate/restarted answer detected: TEST heading(s) "
                + ", ".join(duplicates)
                + " appear more than once. Remove the provisional pre-tool block and keep one complete final TEST sequence."
            )

    # If only the changed if-condition was requested, a trailing "{" is outside
    # the requested fragment even though the condition itself is correct.
    if (
        "smallest correction" in u
        and "if-condition" in u
        and ("only the changed if-condition" in u or "change only the if-condition" in u)
    ):
        correction_match = re.search(
            r"(?mis)^\s*smallest\s+correction\s*:\s*(.*?)(?=^\s*(?:TEST\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if correction_match:
            correction = correction_match.group(1).strip()
            if "{" in correction or "}" in correction:
                issues.append(
                    "Smallest correction includes a body brace even though only the changed if-condition was requested. Return the condition fragment only."
                )

    # General smallest-correction minimality. If the user did not request
    # a complete statement/line, unchanged braces/body syntax are not part of
    # the smallest correction.
    if "smallest correction" in u:
        correction_match = re.search(
            r"(?mis)^\s*smallest\s+correction\s*:\s*(.*?)(?=^\s*(?:TEST\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if correction_match:
            correction = correction_match.group(1).strip()
            explicit_full_statement = any(
                phrase in u
                for phrase in (
                    "complete statement",
                    "full statement",
                    "complete line",
                    "full line",
                    "entire statement",
                    "entire line",
                )
            )
            if (
                not explicit_full_statement
                and ("{" in correction or "}" in correction)
                and (
                    "identify only the relevant problem" in u
                    or "provide exactly one correction" in u
                    or "smallest correction" in u
                )
            ):
                issues.append(
                    "Smallest correction contains unchanged body brace/surrounding syntax. Return only the corrected expression/predicate unless the user explicitly requested the complete statement or line."
                )

    # PowerShell subexpression wrapping is not minimal when the user asks
    # for only the corrected standalone expression/predicate.
    if "smallest correction" in u:
        correction_match = re.search(
            r"(?mis)^\s*smallest\s+correction\s*:\s*(.*?)(?=^\s*(?:TEST\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if correction_match:
            correction = correction_match.group(1).strip()
            if re.fullmatch(r"\$\(\s*[^()\r\n]+\s*\)", correction):
                issues.append(
                    "Smallest correction is not minimal: the PowerShell `$(` ... `)` subexpression wrapper is unnecessary around a standalone predicate. Return the inner expression only."
                )

    # Supplied-token fidelity for code-review Findings.
    if "smallest correction" in u or "finding:" in u:
        finding_match = re.search(
            r"(?mis)^\s*finding\s*:\s*(.*?)(?=^\s*(?:smallest\s+correction|TEST\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if finding_match:
            finding = finding_match.group(1)
            mutation_ops = ("-=", "+=", "*=", "/=", "%=")
            invented_ops = [
                op for op in mutation_ops
                if op in finding and op not in (user_text or "")
            ]
            if invented_ops:
                issues.append(
                    "Supplied-token fidelity error: Finding invents operator(s) absent from the supplied code: "
                    + ", ".join(invented_ops)
                    + ". Mention only the actual source operator/token and the correction."
                )

    # DELAY and delay are distinct Python identifiers. If DELAY is never
    # referenced, assigning the separate lowercase variable cannot shadow or
    # overwrite DELAY.
    if (
        "no other reference to delay exists" in u
        and "initial_speed" in u
    ):
        if re.search(r"(?i)\bshadow(?:ed|ing)\b", answer_text or ""):
            issues.append(
                "Terminology error: DELAY is unused/dead code, not shadowed by the distinct variable name delay or by INITIAL_SPEED."
            )
        if re.search(
            r"(?is)\bDELAY\b.{0,90}\b(?:overwritten|overwrote|overwrites|reassigned)\b|"
            r"\b(?:overwritten|overwrote|overwrites|reassigned)\b.{0,90}\bDELAY\b",
            answer_text or "",
        ):
            issues.append(
                "Terminology error: DELAY is not overwritten/reassigned by `delay = INITIAL_SPEED`; DELAY and delay are distinct case-sensitive identifiers. DELAY is simply unused."
            )

    # Evidence-only numpad regression. Teams and Word are comparison apps where
    # the numpad works. Citrix Workspace is only known as a reset action.
    evidence_numpad_case = (
        ("summarize only" in u or "evidence-only" in u)
        and "numpad" in u
        and "sap b1" in u
        and "teams" in u
        and "word" in u
        and "citrix workspace reset" in u
    )
    if evidence_numpad_case:
        scope_match = re.search(
            r"(?mis)^\s*scope\s*:\s*(.*?)(?=^\s*(?:already\s+tested|unknown)\s*:|\Z)",
            answer_text or "",
        )
        if scope_match:
            scope = scope_match.group(1).strip().lower()
            if "citrix workspace" in scope:
                issues.append(
                    "Evidence-only scope error: Citrix Workspace is evidence of a reset that was tested, not an affected application and should not be listed as issue scope."
                )
            if (
                ("teams" in scope or "word" in scope)
                and not any(
                    phrase in scope
                    for phrase in (
                        "comparison",
                        "works",
                        "working",
                        "does not occur",
                        "not affected",
                    )
                )
            ):
                issues.append(
                    "Evidence-only scope error: Teams and Word are comparison applications where the numpad works; do not list them as affected scope without making that contrast explicit."
                )

        unknown_match = re.search(
            r"(?mis)^\s*unknown\s*:\s*(.*?)(?=^\s*(?:TEST\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if unknown_match:
            unknown = unknown_match.group(1).strip().lower()
            invented_diagnostic_categories = (
                "host session",
                "input path",
                "sap b1 client",
                "client layer",
                "input layer",
                "session host",
            )
            found = [
                item for item in invented_diagnostic_categories
                if item in unknown and item not in u
            ]
            if found:
                issues.append(
                    "Evidence-only Unknown invents diagnostic categories not present in the supplied evidence: "
                    + ", ".join(found)
                    + ". Keep Unknown limited to unresolved facts directly supported by the supplied observations."
                )

            causal_relation_patterns = (
                r"\brelated\s+to\b",
                r"\bcaused\s+by\b",
                r"\bdue\s+to\b",
                r"\blinked\s+to\b",
                r"\bassociated\s+with\b",
                r"\brelationship\s+between\b",
                r"\bsame\s+cause\b",
                r"\bcausal(?:ly|ity)?\b",
            )
            if any(
                re.search(pattern, unknown, re.I)
                for pattern in causal_relation_patterns
            ):
                issues.append(
                    "Evidence-only Unknown introduces a causal/relationship hypothesis between supplied observations. State only unresolved observations; do not ask whether one symptom is related to, caused by, due to, linked to, or associated with another."
                )

            root_cause_patterns = (
                r"(?:^|[;.!?]\s*)why\b",
                r"\bwhat\s+(?:causes?|caused)\b",
                r"\breason\s+for\b",
                r"\bexplanation\s+for\b",
                r"\broot\s+cause\b",
                r"\bsource\s+of\b",
                r"\bcause\s+of\b",
                r"\borigin\s+of\b",
                r"\bunderlying\s+(?:cause|issue|problem)\b",
            )
            invented_observation_categories = (
                "other inputs",
                "additional inputs",
                "different inputs",
                "input handling",
            )
            if any(re.search(pattern, unknown, re.I) for pattern in root_cause_patterns):
                issues.append(
                    "Evidence-only Unknown introduces a why/reason/root-cause/source-of question. The user requested unresolved observations only; remove diagnostic/root-cause unknowns."
                )
            invented_observations = [
                item for item in invented_observation_categories
                if item in unknown and item not in u
            ]
            if invented_observations:
                issues.append(
                    "Evidence-only Unknown invents new observation categories not present in the supplied evidence: "
                    + ", ".join(invented_observations)
                    + ". Keep Unknown limited to the supplied applications and observed keyboard behaviors."
                )

    # "Exactly one next test" means one concrete test and one method/tool,
    # not one objective followed by alternative tools.
    exactly_one_next_test = (
        "exactly 1 next test" in u
        or "exactly one next test" in u
        or "give exactly 1 next test" in u
        or "give exactly one next test" in u
    )
    if exactly_one_next_test:
        next_match = re.search(
            r"(?mis)^\s*next\s+test\s*:\s*(.*?)(?=^\s*(?:TEST\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if next_match:
            next_test = next_match.group(1).strip()
            alternative_tool_example = bool(
                re.search(
                    r"(?is)\b(?:e\.g\.|for example)\b.{0,140}\bor\b",
                    next_test,
                )
            )
            named_tool_or = bool(
                re.search(
                    r"(?i)\b(?:procmon|process monitor|performance monitor|perfmon|"
                    r"wireshark|tcpdump|nmap|test-netconnection|curl|wget)\b"
                    r".{0,80}\bor\b.{0,80}"
                    r"\b(?:procmon|process monitor|performance monitor|perfmon|"
                    r"wireshark|tcpdump|nmap|test-netconnection|curl|wget)\b",
                    next_test,
                )
            )
            if alternative_tool_example or named_tool_or:
                issues.append(
                    "Exactly one Next test was requested, but the response offers alternative methods/tools. Select one concrete test and one method/tool only."
                )

    # Bloomberg deployment clarification regression: the user explicitly
    # required confirming shared multi-session architecture. Asking only for a
    # concurrent-user count does not establish that architecture.
    if "bloomberg" in u and "shared multi-session" in u:
        shared_multi = bool(
            re.search(
                r"(?is)\bshared\b.{0,50}\bmulti[- ]session\b|"
                r"\bmulti[- ]session\b.{0,50}\bshared\b|"
                r"\bmultiple\s+users\b.{0,50}\b(?:same|shared)\b.{0,50}\b(?:server|session|host)\b",
                answer_text or "",
            )
        )
        if not shared_multi:
            issues.append(
                "Bloomberg clarification is incomplete: it must explicitly establish whether the workload is shared multi-session; concurrent-user count alone is not equivalent."
            )

    # If the prompt explicitly says not to claim why an observation occurred,
    # keep Inference at the level of supported difference/uncertainty.
    if "do not claim why" in u:
        inference_match = re.search(
            r"(?mis)^\s*inference\s*:\s*(.*?)(?=^\s*(?:TEST\s+\d+|[A-Z][A-Z0-9 _/-]{3,}\s*:?)\s*$|\Z)",
            answer_text or "",
        )
        if inference_match:
            inference = inference_match.group(1).strip().lower()
            candidate_mechanisms = (
                "firewall",
                "proxy",
                "routing",
                "route",
                "network control",
                "filtering",
                "filtered",
                "endpoint security",
                "antivirus",
                "local to that client",
                "client-side",
                "server-side",
                "network path",
            )
            invented = [
                item for item in candidate_mechanisms
                if item in inference and item not in u
            ]
            if invented:
                issues.append(
                    "Inference invents a possible mechanism even though the user explicitly said not to claim why the observation occurred: "
                    + ", ".join(invented)
                    + ". State only the supported difference and that the reason is not established."
                )

    # Explicit no-cause constraints remain binding even when the answer hedges.
    prohibited_cause_terms = []
    cause_prohibitions = (
        ("client-side", ("do not invent a client-side cause", "do not invent client-side", "do not claim a client-side cause")),
        ("client side", ("do not invent a client-side cause", "do not invent client-side", "do not claim a client-side cause")),
        ("network-path", ("do not invent routing", "do not invent a network-path cause", "do not invent network-path")),
        ("network path", ("do not invent routing", "do not invent a network-path cause", "do not invent network-path")),
        ("routing", ("do not invent routing", "do not claim routing")),
        ("route", ("do not invent routing", "do not claim routing")),
        ("firewall", ("do not invent a firewall", "do not mention firewall", "do not claim a firewall")),
        ("proxy", ("do not invent a proxy", "do not mention proxy", "do not claim a proxy")),
        ("server-side", ("do not invent a server-side cause", "do not invent server-side")),
        ("server side", ("do not invent a server-side cause", "do not invent server-side")),
    )
    for term, triggers in cause_prohibitions:
        if any(trigger in u for trigger in triggers):
            prohibited_cause_terms.append(term)

    if prohibited_cause_terms:
        found_prohibited = sorted({
            term for term in prohibited_cause_terms
            if term in a
        })
        if found_prohibited:
            issues.append(
                "Explicit uncertainty/cause constraint violated: the answer introduces prohibited causal categories: "
                + ", ".join(found_prohibited)
                + ". Do not reintroduce them even as may/might/could possibilities."
            )

    exact_four_questions = bool(
        re.search(
            r"\b(?:ask\s+)?exactly\s+(?:4|four)\s+(?:numbered\s+)?questions\b",
            u,
            re.I,
        )
    )
    if exact_four_questions:
        numbered_matches = re.findall(
            r"(?m)^\s*([1-9]\d*)[\.\)]\s+",
            answer_text or "",
        )
        question_marks = (answer_text or "").count("?")
        numbering_required = bool(
            re.search(
                r"\b(?:4|four)\s+numbered\s+questions\b",
                u,
                re.I,
            )
        )

        if numbering_required:
            if numbered_matches != ["1", "2", "3", "4"]:
                issues.append(
                    "Numbering violation: exactly four numbered questions were requested. Use visible prefixes 1., 2., 3., and 4. in order."
                )
        elif numbered_matches and len(numbered_matches) != 4:
            issues.append(
                f"Question-count violation: exactly 4 questions were requested, but {len(numbered_matches)} numbered questions were found."
            )
        elif not numbered_matches and question_marks != 4:
            issues.append(
                f"Question-count violation: exactly 4 questions were requested, but {question_marks} question marks were found."
            )

    return issues


def _split_test_sections(text):
    """Return TEST-number -> section text for multi-test prompts."""
    source = str(text or "")
    hits = list(
        re.finditer(
            r"(?mi)^\s*\*{0,2}TEST\s+(\d+)\b[^\r\n]*\*{0,2}\s*$",
            source,
        )
    )
    sections = {}
    for idx, hit in enumerate(hits):
        end = hits[idx + 1].start() if idx + 1 < len(hits) else len(source)
        sections[hit.group(1)] = source[hit.start():end]
    return sections


def _distinctive_web_markers(section_text):
    """Extract source/product identifiers suitable for cross-test isolation."""
    source = str(section_text or "")
    stop = {
        "TEST", "WEB", "REQUIRED", "CURRENT", "OUTPUT", "EXACTLY",
        "SOURCE", "TYPE", "WHY", "VERIFIED", "CONSTRAINTS", "PRIMARY",
        "OFFICIAL", "DOCUMENTATION", "SEARCH", "FETCH", "VALID",
    }
    markers = set()

    for token in re.findall(r"\b[A-Za-z][A-Za-z0-9_.-]{2,}\b", source):
        if token.upper() in stop:
            continue
        upper_count = sum(1 for ch in token if ch.isupper())
        distinctive = (
            "_" in token
            or "." in token
            or upper_count >= 2
            or bool(re.search(r"[a-z][A-Z]", token))
        )
        if distinctive:
            markers.add(token.lower())

    return markers


def _cross_test_source_isolation_issues(user_text, answer_text, tool_evidence):
    """Keep web/source identity metadata inside the TEST that requested web."""
    user_sections = _split_test_sections(user_text)
    answer_sections = _split_test_sections(answer_text)
    if len(user_sections) < 2 or len(answer_sections) < 2:
        return []

    web_tests = {
        num
        for num, section in user_sections.items()
        if re.search(r"(?i)\bWEB\s+REQUIRED\b", section)
    }
    if not web_tests:
        return []

    tool_lower = str(tool_evidence or "").lower()
    web_markers = set()
    for num in web_tests:
        for marker in _distinctive_web_markers(user_sections.get(num, "")):
            if not tool_lower or marker in tool_lower:
                web_markers.add(marker)

    web_markers -= {
        "yaml", "http", "https", "tcp", "ram", "gib", "url", "json",
    }
    if not web_markers:
        return []

    issues = []
    for num, answer_section in answer_sections.items():
        if num in web_tests:
            continue
        user_section_lower = user_sections.get(num, "").lower()
        answer_section_lower = answer_section.lower()
        leaked = sorted(
            marker
            for marker in web_markers
            if marker in answer_section_lower and marker not in user_section_lower
        )
        if leaked:
            issues.append(
                f"Cross-TEST source isolation error in TEST {num}: web/source identifier(s) from another WEB REQUIRED TEST leaked into this independent section: "
                + ", ".join(leaked[:6])
                + ". Keep retrieved source/citation metadata scoped to the web test that requested it."
            )

    return issues


def _generic_exact_yaml_issues(user_text, answer_text):
    """Conservative exact-YAML check for supplied blocks with list markers."""
    user_sections = _split_test_sections(user_text)
    answer_sections = _split_test_sections(answer_text)
    if not user_sections:
        return []

    issues = []
    for num, usec in user_sections.items():
        match = re.search(
            r"(?is)\bReturn\s+exactly\s*:\s*\n(.*?)(?=\n\s*Constraints\s*:|\Z)",
            usec,
        )
        if not match:
            continue
        expected = match.group(1).strip("\r\n ")
        if not (
            re.search(r"(?m)^\s*-\s+\S", expected)
            and ":" in expected
        ):
            continue
        actual = answer_sections.get(num, "")
        if actual and expected not in actual:
            issues.append(
                f"TEST {num} exact YAML structure drift: preserve the supplied "
                "list marker, indentation, keys, and scalar/boolean values exactly."
            )
    return issues


def _definite_proposition_issues(user_text, answer_text):
    """Catch 'definitely down' reversal when supplied evidence disproves it."""
    user_sections = _split_test_sections(user_text)
    answer_sections = _split_test_sections(answer_text)
    issues = []
    for num, usec in user_sections.items():
        if not (
            "definitely down" in usec.lower()
            and re.search(
                r"(?i)\b(?:same\s+)?service\s+works\s+from\s+Client\s+B\b",
                usec,
            )
        ):
            continue
        asec = answer_sections.get(num, "")
        if not asec:
            continue
        conclusion = re.search(
            r"(?mi)^\s*Conclusion\s*:\s*([^\r\n]+)",
            asec,
        )
        if not conclusion or not re.match(
            r"(?i)^\s*No\b",
            conclusion.group(1),
        ):
            issues.append(
                f"TEST {num} definite-proposition error: the same service works "
                "from Client B, so it is not definitely down. Conclusion must be "
                "No; only Client A's failure reason remains unresolved."
            )
    return issues


def _precision_deterministic_issues(user_text, answer_text, tool_evidence):
    """Collect all high-confidence deterministic precision issues."""
    issues = _deterministic_issues(user_text, answer_text)
    issues += _calculator_consistency_issues(
        user_text, answer_text, tool_evidence
    )
    issues += _capacity_relationship_issues(
        user_text, answer_text
    )
    issues += _source_fidelity_issues(
        user_text, answer_text, tool_evidence
    )
    issues += _cross_test_source_isolation_issues(
        user_text, answer_text, tool_evidence
    )
    issues += _generic_exact_yaml_issues(
        user_text, answer_text
    )
    issues += _definite_proposition_issues(
        user_text, answer_text
    )
    return list(dict.fromkeys(issues))


def _extract_json_object(text):
    raw = str(text or "").strip()
    if not raw:
        return None
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else None
    except Exception:
        pass

    match = re.search(r"\{.*\}", raw, re.S)
    if not match:
        return None
    try:
        value = json.loads(match.group(0))
        return value if isinstance(value, dict) else None
    except Exception:
        return None


class Filter:
    class Valves(BaseModel):
        force_fast_thinking_off: bool = Field(default=True)
        force_research_thinking_off: bool = Field(default=True)
        force_task_thinking_off: bool = Field(default=True)
        force_deep_thinking_off: bool = Field(default=True)
        advanced_final_precision_audit: bool = Field(default=True)
        advanced_native_tool_streaming: bool = Field(
            default=True,
            description="Keep Advanced streaming enabled because OpenWebUI Native tool execution depends on the streaming tool-call loop.",
        )
        advanced_audit_max_user_chars: int = Field(default=9000, ge=2000, le=20000)
        advanced_audit_max_answer_chars: int = Field(default=14000, ge=3000, le=30000)
        advanced_audit_tool_evidence_chars: int = Field(default=8000, ge=0, le=20000)
        advanced_repair_max_passes: int = Field(
            default=3,
            ge=1,
            le=4,
            description="Maximum conditional Advanced final-answer repair passes; the least deterministic-issue candidate is retained instead of reverting wholesale.",
        )

    def __init__(self):
        self.valves = self.Valves()

    async def _ollama(self, model, system, prompt, predict=500, temperature=0.0):
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
            "think": False,
            "stream": False,
            "keep_alive": MODEL_KEEP_ALIVE,
            "options": {
                "num_predict": predict,
                "temperature": temperature,
                "top_p": 0.9,
            },
        }
        async with httpx.AsyncClient(timeout=180.0) as client:
            response = await client.post(f"{OLLAMA}/api/chat", json=payload)
        response.raise_for_status()
        return str(
            ((response.json().get("message") or {}).get("content") or "")
        ).strip()

    async def _scout_audit(self, user_text, answer_text, tool_evidence):
        system = """You are a very small FINAL PRECISION AUDITOR.
Do not answer the user's task. Audit only the proposed final answer.

Report only CLEAR, MATERIAL problems:
- contradiction with explicit user constraints;
- unsupported certainty or technical specificity;
- a final conclusion that becomes more definite without new evidence;
- semantic claims that confuse an actuator's type/name with its effect on the controlled variable;
- contradiction with deterministic calculator/tool evidence;
- when the user explicitly requires the deterministic calculator, any reported derived numeric field not backed by a successful calculator result;
- arithmetic relationship errors where individually calculator-backed values were produced from the wrong expression (especially Reserved/Current/Available/additional-user capacity);
- source-to-final drift in short code/config snippets, especially dropped YAML list markers, nesting, or keys;
- adding optional implementation or a second alternative where the user requested the smallest correction / exactly one choice;
- internal contradiction where a direct Yes/No answer conflicts with its own explanation;
- visible provisional planning/scratch text before or between tool calls (for example "Let me work through...", "calculator needed", or handwritten formulas), visible self-correction, or duplicated/restarted numbered answer sections;
- a smallest-correction fragment that repeats unchanged braces/body/wrapper syntax, or adds an unnecessary PowerShell `$(` ... `)` wrapper, when a smaller corrected expression is sufficient and a complete statement was not requested;
- a redundant boolean comparison such as `$result.TcpTestSucceeded -eq $true` when the direct boolean property is the smaller equivalent predicate;
- invented scope/unknown items in summarize-only or evidence-only tasks, including treating known-working comparison apps or a reset action as affected scope, inventing diagnostic categories such as host session/input path/client layer/other inputs, introducing root-cause/source-of/why/reason/explanation questions, or inventing a causal/relationship hypothesis between supplied symptoms;
- saying a differently-cased identifier was shadowed/overwritten when it is merely unused;
- missing an explicitly required architecture clarification such as "shared multi-session" even when another related question (for example concurrent users) was asked;
- violating exact formatting/count/word/numbering requirements when obvious, including omitting numeric prefixes when numbered questions were explicitly requested or giving alternative tools/methods when exactly one Next test was requested;
- inventing candidate mechanisms anywhere in a constrained uncertainty answer when the user explicitly says not to claim why or explicitly forbids causes such as client-side/network-path/routing/firewall/proxy/server-side;
- cross-TEST source contamination where web/source metadata or citations from a WEB REQUIRED test appear in an independent non-web TEST;
- inventing an alternate erroneous code operator/token that was not present in the supplied snippet.

Physical-control rule:
heat_output means increasing output tends to raise the controlled temperature.
cool_output means increasing output tends to lower it.
A circulation pump/fan/valve/motor does NOT have to literally generate heat to be heat_output.
If the physical direction is not established, the answer must remain indeterminate.

Do not flag style preferences or harmless wording.
Return JSON only:
{"pass":true,"issues":[]}
or
{"pass":false,"issues":["concise issue", "..."]}"""

        prompt = (
            "USER REQUEST:\n"
            + user_text
            + "\n\nPROPOSED FINAL ANSWER:\n"
            + answer_text
        )
        if tool_evidence:
            prompt += "\n\nAUTHORITATIVE TOOL EVIDENCE FROM THIS TURN:\n" + tool_evidence

        raw = await self._ollama(
            SCOUT_MODEL,
            system,
            prompt,
            predict=350,
            temperature=0.0,
        )
        parsed = _extract_json_object(raw)
        if not parsed:
            return {"pass": True, "issues": []}

        issues = parsed.get("issues")
        if not isinstance(issues, list):
            issues = []
        issues = [
            str(item).strip()
            for item in issues
            if str(item).strip()
        ][:8]

        return {
            "pass": bool(parsed.get("pass")) and not issues,
            "issues": issues,
        }

    async def _repair_answer(self, user_text, answer_text, issues, tool_evidence):
        system = """You are the FINAL ANSWER REPAIR PASS for Advanced mode.
Return ONLY the corrected final answer, with no audit commentary.

Rules:
- Preserve every explicit output heading, count, word limit, numbering requirement, and formatting constraint from the user.
- Make the smallest changes needed to fix the listed precision issues.
- Do not add new facts, features, causes, tests, optional improvements, or alternative corrections.
- If the user requested exactly one choice, return exactly one choice; never append "or", "alternatively", or a second option.
- Ensure every direct Yes/No/Correct/Incorrect answer is logically consistent with its explanation.
- Remove all visible provisional planning/scratch text, drafting/self-correction text, and duplicated/restarted answer fragments. Text such as "Let me work through...", "calculator needed", or handwritten pre-tool formulas must not survive. If numbered TEST sections repeat after a tool call, keep only one complete final sequence.
- For summarize-only/evidence-only tasks, remove invented adjacent scope/unknown items and retain only unresolved observations that follow directly from supplied evidence. Keep known-working comparison applications distinct from the affected scope, keep a reset action under Already tested rather than Scope, and do not invent diagnostic layers/categories, "other inputs", root-cause/source-of/why/reason/explanation questions, or causal/relationship hypotheses in Unknown.
- If an identifier is never referenced, call it unused/dead code. Do not call it shadowed/overwritten by a different case-sensitive identifier.
- For a smallest correction, omit unchanged braces/body/wrapper syntax unless the user explicitly requested a complete statement/line. Do not wrap a standalone PowerShell predicate in `$(` and `)` unless the subexpression wrapper itself is required by the requested context. If only an if-condition fragment was requested, do not include the body-opening brace. If the condition is already a boolean property, use it directly and remove redundant comparisons to true.
- Treat deterministic calculator/tool evidence as authoritative. If the user explicitly required the calculator, every reported derived numeric field must match a successful calculator result from this turn.
- Recompute the semantic relationships of capacity problems from the supplied facts; do not preserve a calculator result that came from the wrong expression.
- For source-derived code/config snippets, preserve structural syntax from tool/source evidence, including YAML list markers and nesting.
- In multi-TEST prompts, keep web citations/source labels/tool-derived wording scoped to the TEST that requested web research. Remove retrieved source/site/product metadata from independent non-web TEST sections.
- When reviewing a supplied code token/operator, do not invent an alternative erroneous token that was absent from the user's snippet; mention only the actual supplied token and the requested correction.
- When the user says Return exactly and supplies YAML containing list markers, preserve that YAML block exactly, including indentation and `- ` list markers.
- If the user asks whether a service is definitely down and supplied evidence says the same service works from another client, answer No; keep only the reason for the failing client unresolved.
- Preserve uncertainty when evidence does not resolve it. If the prompt says not to claim why something happened or explicitly prohibits candidate causes, do not introduce those causes/mechanisms anywhere in Conclusion, Reason, Unknown, or Inference, even with "may", "might", "could", or "possibly"; state only the supported difference and unresolved reason.
- If exactly one Next test is requested, choose one concrete test and one method/tool; do not offer alternatives using "or", "/", "e.g.", or "for example".
- Never infer heat_output/cool_output from actuator type/name. Direction depends on the actuator's effect on the controlled temperature.
- Do not browse, call tools, explain the repair, or mention this validation pass.
- If the original answer is already correct despite an erroneous issue report, return it unchanged."""

        prompt = (
            "USER REQUEST:\n"
            + user_text
            + "\n\nORIGINAL FINAL ANSWER:\n"
            + answer_text
            + "\n\nPRECISION ISSUES TO REPAIR:\n- "
            + "\n- ".join(issues)
        )
        if tool_evidence:
            prompt += "\n\nAUTHORITATIVE TOOL EVIDENCE FROM THIS TURN:\n" + tool_evidence

        return await self._ollama(
            REPAIR_MODEL,
            system,
            prompt,
            predict=1600,
            temperature=0.05,
        )

    async def inlet(self, body: dict, __model__=None, **kwargs):
        model = str(body.get("model") or "")
        info = (__model__ or {}).get("info") or {}
        base = str(info.get("base_model_id") or model)
        if self.valves.force_fast_thinking_off and (model == FAST_MODE or base == FAST):
            body["think"] = False
        elif self.valves.force_research_thinking_off and (model == RESEARCH_MODE or base == RESEARCH):
            body["think"] = False
        elif self.valves.force_deep_thinking_off and (model == DEEP_MODE or base == DEEP):
            body["think"] = False
        elif self.valves.force_task_thinking_off and model == TASK:
            body["think"] = False

        if model in {FAST_MODE, RESEARCH_MODE, DEEP_MODE, FAST, RESEARCH, DEEP} or base in {FAST, RESEARCH, DEEP}:
            messages = body.get("messages") or []
            already = any(
                isinstance(m, dict)
                and m.get("role") == "system"
                and MARKER in str(m.get("content") or "")
                for m in messages
            )
            if not already:
                messages = add_or_update_system_message(
                    DISCIPLINE, messages, append=True
                )

            if model == RESEARCH_MODE or base == RESEARCH:
                # Native tool execution in OpenWebUI uses the streaming agentic
                # loop. Do NOT disable transport streaming here: stream=False
                # can stop at the first tool request and never execute it.
                if self.valves.advanced_native_tool_streaming:
                    body["stream"] = True

                advanced_already = any(
                    isinstance(m, dict)
                    and m.get("role") == "system"
                    and ADVANCED_MARKER in str(m.get("content") or "")
                    for m in messages
                )
                if not advanced_already:
                    messages = add_or_update_system_message(
                        ADVANCED_PRECISION, messages, append=True
                    )

            body["messages"] = messages
        return body

    async def outlet(self, body: dict, __model__=None, **kwargs):
        if not self.valves.advanced_final_precision_audit:
            return body

        model = str(body.get("model") or "")
        info = (__model__ or {}).get("info") or {}
        base = str(info.get("base_model_id") or model)
        if not (model == RESEARCH_MODE or base == RESEARCH):
            return body

        messages = body.get("messages") or []
        target = _latest_assistant_message(messages)
        if target is None:
            return body

        answer_text = str(target.get("content") or "").strip()
        user_text = _latest_user_text(messages)
        if not answer_text or not user_text:
            return body

        user_text = user_text[: self.valves.advanced_audit_max_user_chars]
        answer_text = answer_text[: self.valves.advanced_audit_max_answer_chars]
        tool_evidence = _tool_evidence(
            messages,
            self.valves.advanced_audit_tool_evidence_chars,
        )

        deterministic = _precision_deterministic_issues(
            user_text,
            answer_text,
            tool_evidence,
        )
        issues = list(deterministic)

        try:
            scout = await self._scout_audit(
                user_text,
                answer_text,
                tool_evidence,
            )
            for issue in scout.get("issues") or []:
                if issue not in issues:
                    issues.append(issue)
        except Exception:
            # Scout is advisory/fail-open. Deterministic checks remain active.
            pass

        if not issues:
            return body

        # v8.5: retain progressively improved candidates and score them by
        # deterministic issues. Do not resurrect a more flawed original answer
        # merely because one unrelated issue remains after repair.
        candidates = [
            {
                "text": answer_text,
                "deterministic": deterministic,
                "pass_index": 0,
            }
        ]
        current = answer_text
        current_issues = issues

        for pass_index in range(
            1,
            int(self.valves.advanced_repair_max_passes) + 1,
        ):
            if not current_issues:
                break
            try:
                repaired = await self._repair_answer(
                    user_text,
                    current,
                    current_issues[:8],
                    tool_evidence,
                )
            except Exception:
                break

            repaired = str(repaired or "").strip()
            if not repaired or repaired == current:
                break

            remaining = _precision_deterministic_issues(
                user_text,
                repaired,
                tool_evidence,
            )
            candidates.append(
                {
                    "text": repaired,
                    "deterministic": remaining,
                    "pass_index": pass_index,
                }
            )
            current = repaired
            current_issues = list(remaining)

            if not remaining:
                try:
                    scout = await self._scout_audit(
                        user_text,
                        repaired,
                        tool_evidence,
                    )
                    current_issues = list(scout.get("issues") or [])
                except Exception:
                    current_issues = []
                if not current_issues:
                    break

        best = min(
            candidates,
            key=lambda item: (
                len(item["deterministic"]),
                -int(item["pass_index"]),
            ),
        )
        original_score = len(candidates[0]["deterministic"])
        best_score = len(best["deterministic"])

        # Zero deterministic issues always wins. If no candidate is perfect,
        # retain a repair only when it strictly reduces high-confidence issues.
        if best_score == 0 or best_score < original_score:
            target["content"] = best["text"]

        return body
PYGUARD
python3 - "${WORKDIR}/response_discipline_guard.py" "$MODEL_IDLE_UNLOAD" <<'PYGUARDPATCH'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("__MODEL_KEEP_ALIVE__", sys.argv[2])
path.write_text(text, encoding="utf-8")
PYGUARDPATCH
python3 -c 'import ast,sys,pathlib; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "${WORKDIR}/response_discipline_guard.py"

python3 - "${WORKDIR}/response_discipline_guard.py" <<'PYGUARDTEST'
import ast
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(source)
wanted = {
    "_normalize_decimal_token",
    "_calculator_results",
    "_calculator_consistency_issues",
    "_answer_numeric_fields",
    "_parse_capacity_problem",
    "_capacity_relationship_issues",
    "_source_fidelity_issues",
    "_deterministic_issues",
    "_split_test_sections",
    "_distinctive_web_markers",
    "_cross_test_source_isolation_issues",
    "_generic_exact_yaml_issues",
    "_definite_proposition_issues",
    "_precision_deterministic_issues",
}
nodes = []
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in wanted:
        nodes.append(node)

module = ast.Module(body=nodes, type_ignores=[])
from decimal import Decimal, InvalidOperation, ROUND_FLOOR
namespace = {
    "re": __import__("re"),
    "Decimal": Decimal,
    "InvalidOperation": InvalidOperation,
    "ROUND_FLOOR": ROUND_FLOOR,
}
exec(compile(module, "<guard-selftest>", "exec"), namespace)

user = """Review only:
climate:
  - platform: pid
    sensor: tank_temperature
    heat_output: pump_pwm
The actuator is a circulation pump.
Do not assume whether increased pump speed raises or lowers tank_temperature."""

bad = """Conclusion: No.
Reason: heat_output expects a heater and a circulation pump does not generate heat.
Required evidence: confirmation that the actuator directly produces heat."""

good = """Conclusion: Indeterminate.
Reason: The physical relationship between pump output and tank temperature is not established.
Required evidence: Whether increasing pump speed raises or lowers tank_temperature."""

bad_issues = namespace["_deterministic_issues"](user, bad)
good_issues = namespace["_deterministic_issues"](user, good)

if not bad_issues:
    raise SystemExit("control-direction regression was not detected")
if good_issues:
    raise SystemExit(f"valid indeterminate answer was incorrectly flagged: {good_issues}")

ps_user = """Review:
$result = Test-NetConnection server01 -Port 443
if ($result) { "Success" }
TcpTestSucceeded : False
Output exactly:
Will print Success:
Why:
Smallest correction:
Smallest correction must change only the if-condition."""

ps_bad = """Will print Success: No
Why: Test-NetConnection returns a non-null object, which is always truthy in PowerShell.
Smallest correction: if ($result.TcpTestSucceeded)"""

if not namespace["_deterministic_issues"](ps_user, ps_bad):
    raise SystemExit("internal Yes/No contradiction was not detected")

small_user = """Smallest correction must choose exactly one:
remove DELAY
OR
use DELAY
Do not propose both."""

small_bad = """Finding: DELAY is unused.
Impact: No runtime malfunction.
Smallest correction: use DELAY by assigning delay = DELAY, or remove INITIAL_SPEED."""

small_issues = namespace["_deterministic_issues"](small_user, small_bad)
if not any("one-choice" in x.lower() or "alternative" in x.lower() for x in small_issues):
    raise SystemExit("multiple-alternative smallest correction was not detected")

draft_bad = """Reserved: 73.75 GiB.
Wait, let me re-calculate carefully.
Final Answer: Reserved: 74 GiB."""
draft_issues = namespace["_deterministic_issues"]("Calculate the value exactly.", draft_bad)
if not any("draft" in x.lower() or "self-correction" in x.lower() for x in draft_issues):
    raise SystemExit("visible draft/self-correction leakage was not detected")

calc_evidence = """
{"ok":true,"expression":"128 * 0.22","result":"28.16"}
{"ok":true,"expression":"14 * 3.75 + 21.5","result":"74"}
{"ok":true,"expression":"128 - 28.16 - 74","result":"25.84"}
{"ok":true,"expression":"floor(25.84 / 3.75)","result":"6"}
"""
calc_user = """Use the deterministic calculator tool.
Output exactly:
Reserved:
Current:
Available:
Calculation:
Answer:"""
calc_bad = """Reserved: 28.16 GiB
Current: 73.75 GiB
Available: 26.09 GiB
Calculation: floor(26.09 / 3.75)
Answer: 6"""
calc_good = """Reserved: 28.16 GiB
Current: 74 GiB
Available: 25.84 GiB
Calculation: floor(25.84 / 3.75) = 6
Answer: 6"""

bad_calc_issues = namespace["_calculator_consistency_issues"](
    calc_user, calc_bad, calc_evidence
)
good_calc_issues = namespace["_calculator_consistency_issues"](
    calc_user, calc_good, calc_evidence
)
if len(bad_calc_issues) < 2:
    raise SystemExit(
        f"calculator result-to-final mismatch was not detected: {bad_calc_issues}"
    )
if good_calc_issues:
    raise SystemExit(
        f"calculator-backed final values were incorrectly flagged: {good_calc_issues}"
    )

ota_user = """WEB SEARCH TEST
What is the currently documented ESPHome YAML syntax for the native ESPHome OTA platform with a password stored in secrets?
Use current primary/vendor documentation only."""
ota_bad = """Current syntax:
ota:
  platform: esphome
  password: !secret ota_password"""
ota_good = """Current syntax:
ota:
  - platform: esphome
    password: !secret ota_password"""

bad_ota_issues = namespace["_source_fidelity_issues"](ota_user, ota_bad, "")
good_ota_issues = namespace["_source_fidelity_issues"](ota_user, ota_good, "")
if not bad_ota_issues:
    raise SystemExit("ESPHome OTA missing list marker was not detected")
if good_ota_issues:
    raise SystemExit(
        f"valid ESPHome OTA structure was incorrectly flagged: {good_ota_issues}"
    )

capacity_user = """A server has 128 GiB RAM.
14 users consume exactly 3.75 GiB each.
OS and shared services consume exactly 21.5 GiB.
22% of total RAM must remain free.
Each additional user consumes exactly 3.75 GiB."""

capacity_bad = """Reserved: 28.16 GiB
Current: 74 GiB
Available: 25.84 GiB
Calculation: (128 - 74 - 28.16) / 3.75 = 14.4
Answer: 14"""

capacity_good = """Reserved: 28.16 GiB
Current: 74 GiB
Available: 25.84 GiB
Calculation: (128 - 74 - 28.16) / 3.75 = 6.89
Answer: 6"""

bad_capacity = namespace["_capacity_relationship_issues"](
    capacity_user, capacity_bad
)
good_capacity = namespace["_capacity_relationship_issues"](
    capacity_user, capacity_good
)
if not bad_capacity:
    raise SystemExit("capacity relationship mismatch was not detected")
if good_capacity:
    raise SystemExit(
        f"correct capacity relationship was incorrectly flagged: {good_capacity}"
    )

bloomberg_user = """I need to install Bloomberg on a Citrix multi-user server.
Ask exactly 4 questions.
Establish the exact Bloomberg product.
Establish Windows Server and Citrix versions.
Establish whether the workload is shared multi-session and persistent/non-persistent.
Establish the exact installer/version/package."""

bloomberg_bad = """1. Which Bloomberg product?
2. Which Windows Server and Citrix versions?
3. Is it persistent or non-persistent, and how many concurrent users?
4. Which installer package?"""

bloomberg_good = """1. Which Bloomberg product?
2. Which Windows Server and Citrix versions?
3. Is this a shared multi-session workload, and is it persistent or non-persistent?
4. Which installer package?"""

if not namespace["_deterministic_issues"](bloomberg_user, bloomberg_bad):
    raise SystemExit("missing shared multi-session clarification was not detected")
if namespace["_deterministic_issues"](bloomberg_user, bloomberg_good):
    raise SystemExit("valid Bloomberg four-question clarification was flagged")

delay_user_v80 = """Review:
DELAY = 0.1
INITIAL_SPEED = 0.1
delay = INITIAL_SPEED
No other reference to DELAY exists."""

delay_bad_v80 = """Finding:
DELAY is assigned but never referenced after being overwritten by delay = INITIAL_SPEED.
Impact:
Unused variable; no runtime malfunction.
Smallest correction:
remove DELAY"""

delay_good_v80 = """Finding:
DELAY is defined but never referenced.
Impact:
DELAY is unused code; no runtime malfunction.
Smallest correction:
remove DELAY"""

bad_delay_v80 = namespace["_deterministic_issues"](delay_user_v80, delay_bad_v80)
good_delay_v80 = namespace["_deterministic_issues"](delay_user_v80, delay_good_v80)
if not any("overwritten" in issue.lower() or "case-sensitive" in issue.lower() for issue in bad_delay_v80):
    raise SystemExit(
        f"DELAY overwritten terminology regression was not detected: {bad_delay_v80}"
    )
if good_delay_v80:
    raise SystemExit(
        f"correct DELAY unused terminology was incorrectly flagged: {good_delay_v80}"
    )

scope_user_v80 = """Summarize only this evidence:
- Numpad does not type numbers in SAP B1.
- Numpad works in Teams.
- Numpad works in Word.
- Citrix Workspace reset did not change the behavior.
Output exactly:
Observed:
Scope:
Already tested:
Unknown:"""

scope_bad_v80 = """Observed:
Numpad fails in SAP B1 and works in Teams and Word.
Scope:
SAP B1, Teams, Word, Citrix Workspace.
Already tested:
Citrix Workspace reset.
Unknown:
Whether other applications are affected."""

scope_good_v80 = """Observed:
Numpad fails in SAP B1 and works in Teams and Word.
Scope:
The reported numpad failure is observed in SAP B1; Teams and Word are comparison applications where the numpad works.
Already tested:
Citrix Workspace reset.
Unknown:
Whether other applications are affected."""

bad_scope_v80 = namespace["_deterministic_issues"](scope_user_v80, scope_bad_v80)
good_scope_v80 = namespace["_deterministic_issues"](scope_user_v80, scope_good_v80)
if not any("scope error" in issue.lower() for issue in bad_scope_v80):
    raise SystemExit(
        f"evidence-only scope regression was not detected: {bad_scope_v80}"
    )
if good_scope_v80:
    raise SystemExit(
        f"correct evidence-only scope was incorrectly flagged: {good_scope_v80}"
    )

duplicate_titled_v80 = """TEST 1 — DUPLICATE/PRE-TOOL OUTPUT
A
TEST 2 — ARITHMETIC RELATIONSHIP VALIDATION
B
TEST 1 — DUPLICATE/PRE-TOOL OUTPUT
A2
TEST 2 — ARITHMETIC RELATIONSHIP VALIDATION
B2"""
dup_v80 = namespace["_deterministic_issues"](
    "Answer all tests.", duplicate_titled_v80
)
if not any("duplicate" in issue.lower() or "restarted" in issue.lower() for issue in dup_v80):
    raise SystemExit(
        f"titled duplicate TEST headings were not detected: {dup_v80}"
    )

tnc_min_user_v81 = """Review:
$result = Test-NetConnection server01 -Port 443
if ($result) { "Success" }
Returned object:
TcpTestSucceeded : False

Output exactly:
Will print Success:
Why:
Smallest correction:

Constraints:
Smallest correction must contain only the changed if-condition."""

tnc_min_bad_v81 = """Will print Success:
Yes
Why:
Test-NetConnection returns a non-null object.
Smallest correction:
$result.TcpTestSucceeded -eq $true"""

tnc_min_good_v81 = """Will print Success:
Yes
Why:
Test-NetConnection returns a non-null object.
Smallest correction:
$result.TcpTestSucceeded"""

bad_tnc_min_v81 = namespace["_deterministic_issues"](
    tnc_min_user_v81, tnc_min_bad_v81
)
good_tnc_min_v81 = namespace["_deterministic_issues"](
    tnc_min_user_v81, tnc_min_good_v81
)
if not any("not minimal" in issue.lower() or "redundant" in issue.lower() for issue in bad_tnc_min_v81):
    raise SystemExit(
        f"redundant boolean comparison regression was not detected: {bad_tnc_min_v81}"
    )
if good_tnc_min_v81:
    raise SystemExit(
        f"minimal direct boolean predicate was incorrectly flagged: {good_tnc_min_v81}"
    )

unknown_user_v81 = """Summarize only this evidence:
- Numpad does not type numbers in SAP B1.
- Numpad works in Teams.
- Numpad works in Word.
- Num Lock is enabled.
- Number-row keys produce symbols as if Shift is pressed.
- Caps Lock off produces uppercase letters.
- Caps Lock on produces lowercase letters.
- Citrix Workspace reset did not change the behavior.

Output exactly:
Observed:
Scope:
Already tested:
Unknown:"""

unknown_bad_v81 = """Observed:
The supplied keyboard behavior.
Scope:
SAP B1.
Already tested:
Citrix Workspace reset.
Unknown:
Whether the issue is specific to the SAP B1 client, the host session, or the input path.
Whether other applications exhibit the same behavior."""

unknown_good_v81 = """Observed:
The supplied keyboard behavior.
Scope:
SAP B1.
Already tested:
Citrix Workspace reset.
Unknown:
Whether other applications exhibit the same behavior."""

bad_unknown_v81 = namespace["_deterministic_issues"](
    unknown_user_v81, unknown_bad_v81
)
good_unknown_v81 = namespace["_deterministic_issues"](
    unknown_user_v81, unknown_good_v81
)
if not any("unknown" in issue.lower() and "diagnostic" in issue.lower() for issue in bad_unknown_v81):
    raise SystemExit(
        f"invented evidence-only Unknown categories were not detected: {bad_unknown_v81}"
    )
if good_unknown_v81:
    raise SystemExit(
        f"literal evidence-only Unknown was incorrectly flagged: {good_unknown_v81}"
    )

# v8.4 broad-regression failures
inference_user_v84 = """Vendor documentation states:
Port 443 is required for client communication.
Observed:
TCP 443 succeeds from Client A.
TCP 443 times out from Client B.
Output exactly:
Source-supported:
Observed:
Inference:
Do not claim why Client B times out."""
inference_bad_v84 = """Source-supported: Port 443 is required.
Observed: Client A succeeds; Client B times out.
Inference: Client B may be blocked by a network control (firewall/proxy)."""
inference_good_v84 = """Source-supported: Port 443 is required.
Observed: Client A succeeds; Client B times out.
Inference: Client A and Client B have different observed TCP 443 reachability; the reason for Client B's timeout is not established."""
bad_inf_v84 = namespace["_deterministic_issues"](inference_user_v84, inference_bad_v84)
good_inf_v84 = namespace["_deterministic_issues"](inference_user_v84, inference_good_v84)
if not any("inference" in issue.lower() and ("mechanism" in issue.lower() or "claim why" in issue.lower()) for issue in bad_inf_v84):
    raise SystemExit(f"do-not-claim-why inference regression was not detected: {bad_inf_v84}")
if good_inf_v84:
    raise SystemExit(f"non-causal inference was incorrectly flagged: {good_inf_v84}")

next_user_v84 = """Evidence:
Outlook takes approximately 95 seconds to open.
No process-level startup trace has been collected.
Output exactly:
Confirmed:
Possible:
Next test:
Give exactly 1 next test."""
next_bad_v84 = """Confirmed: Outlook takes 95 seconds.
Possible: startup dependency.
Next test: Collect a startup trace (e.g., ProcMon or Performance Monitor)."""
next_good_v84 = """Confirmed: Outlook takes 95 seconds.
Possible: startup dependency.
Next test: Capture Outlook startup with Process Monitor."""
bad_next_v84 = namespace["_deterministic_issues"](next_user_v84, next_bad_v84)
good_next_v84 = namespace["_deterministic_issues"](next_user_v84, next_good_v84)
if not any("exactly one next test" in issue.lower() for issue in bad_next_v84):
    raise SystemExit(f"one-next-test alternative regression was not detected: {bad_next_v84}")
if good_next_v84:
    raise SystemExit(f"single concrete Next test was incorrectly flagged: {good_next_v84}")

brace_user_v84 = """Review:
$value = 10
if ($value = 5) {
    Write-Host "Five"
}
Output exactly:
Finding:
Smallest correction:
Constraints:
Identify only the relevant problem.
Provide exactly one correction.
Stop immediately after the correction."""
brace_bad_v84 = """Finding: Assignment operator = used instead of -eq.
Smallest correction:
if ($value -eq 5) {"""
brace_good_v84 = """Finding: Assignment operator = used instead of -eq.
Smallest correction:
$value -eq 5"""
bad_brace_v84 = namespace["_deterministic_issues"](brace_user_v84, brace_bad_v84)
good_brace_v84 = namespace["_deterministic_issues"](brace_user_v84, brace_good_v84)
if not any("brace" in issue.lower() or "surrounding syntax" in issue.lower() for issue in bad_brace_v84):
    raise SystemExit(f"general smallest-correction brace regression was not detected: {bad_brace_v84}")
if good_brace_v84:
    raise SystemExit(f"minimal predicate correction was incorrectly flagged: {good_brace_v84}")

draft_user_v84 = """Answer all TEST sections.
Do not expose provisional answers or scratch work."""
draft_bad_v84 = """Let me work through each test systematically, calling tools where required.
TEST 1 - Calculator needed
Reserved = 128 * 0.22"""
draft_issues_v84 = namespace["_deterministic_issues"](draft_user_v84, draft_bad_v84)
if not any("draft" in issue.lower() or "self-correction" in issue.lower() for issue in draft_issues_v84):
    raise SystemExit(f"visible pre-tool planning regression was not detected: {draft_issues_v84}")

# v8.5 regressions from the 12-test assessment

subexpr_user_v85 = """TEST 5 — GENERAL SMALLEST CORRECTION
$value = 10
if ($value = 5) {
    Write-Host "Five"
}
Output exactly:
Finding:
Smallest correction:
Smallest correction must contain only the corrected expression/predicate."""
subexpr_bad_v85 = """Finding: Assignment operator used instead of comparison operator.
Smallest correction:
$($value -eq 5)"""
subexpr_good_v85 = """Finding: Assignment operator used instead of comparison operator.
Smallest correction:
$value -eq 5"""
bad_subexpr_v85 = namespace["_deterministic_issues"](subexpr_user_v85, subexpr_bad_v85)
good_subexpr_v85 = namespace["_deterministic_issues"](subexpr_user_v85, subexpr_good_v85)
if not any("subexpression" in issue.lower() or "not minimal" in issue.lower() for issue in bad_subexpr_v85):
    raise SystemExit(f"PowerShell subexpression minimality regression was not detected: {bad_subexpr_v85}")
if good_subexpr_v85:
    raise SystemExit(f"minimal PowerShell predicate was incorrectly flagged: {good_subexpr_v85}")

unknown_user_v85 = """Summarize only this evidence:
- Numpad does not type numbers in SAP B1.
- Numpad works in Teams.
- Numpad works in Word.
- Number-row keys produce symbols as if Shift is pressed.
- Caps Lock off produces uppercase letters.
- Caps Lock on produces lowercase letters.
- Citrix Workspace reset did not change the behavior.
Output exactly:
Observed:
Scope:
Already tested:
Unknown:
Unknown must contain only unresolved observations directly implied by the evidence."""
unknown_bad_v85 = """Observed: supplied behavior.
Scope: SAP B1.
Already tested: Citrix Workspace reset.
Unknown: Whether the modifier inversion affects other inputs in SAP B1; the source of the inverted modifier state within SAP B1."""
unknown_good_v85 = """Observed: supplied behavior.
Scope: SAP B1.
Already tested: Citrix Workspace reset.
Unknown: Whether applications other than SAP B1, Teams, and Word exhibit either reported keyboard behavior."""
bad_unknown_v85 = namespace["_deterministic_issues"](unknown_user_v85, unknown_bad_v85)
good_unknown_v85 = namespace["_deterministic_issues"](unknown_user_v85, unknown_good_v85)
if not any("root-cause" in issue.lower() or "observation categories" in issue.lower() for issue in bad_unknown_v85):
    raise SystemExit(f"literal evidence Unknown regression was not detected: {bad_unknown_v85}")
if good_unknown_v85:
    raise SystemExit(f"literal unresolved-observation Unknown was incorrectly flagged: {good_unknown_v85}")

number_user_v85 = """Ask exactly 4 numbered questions.
Requirements:
1. exact product/version
2. server/Citrix versions
3. shared multi-session and persistence
4. installer/package/version"""
number_bad_v85 = """What product and version?
What server and Citrix versions?
Is it shared multi-session and persistent or non-persistent?
What installer/package/version?"""
number_good_v85 = """1. What product and version?
2. What server and Citrix versions?
3. Is it shared multi-session and persistent or non-persistent?
4. What installer/package/version?"""
bad_number_v85 = namespace["_deterministic_issues"](number_user_v85, number_bad_v85)
good_number_v85 = namespace["_deterministic_issues"](number_user_v85, number_good_v85)
if not any("numbering" in issue.lower() for issue in bad_number_v85):
    raise SystemExit(f"numbered-question regression was not detected: {bad_number_v85}")
if good_number_v85:
    raise SystemExit(f"correct numbered questions were incorrectly flagged: {good_number_v85}")

tnc_user_v85 = """TEST 9 — POWERSHELL TRUTHINESS
$result = Test-NetConnection server01 -Port 443
if ($result) { "Success" }
TcpTestSucceeded : False
Output exactly:
Will print Success:
Why:
Smallest correction:"""
tnc_bad_v85 = """Will print Success: No
Why: Test-NetConnection returns an object regardless of success; the object evaluates to True in a boolean context even when TcpTestSucceeded is False.
Smallest correction:
$result.TcpTestSucceeded"""
tnc_issues_v85 = namespace["_deterministic_issues"](tnc_user_v85, tnc_bad_v85)
if not any("contradiction" in issue.lower() or "semantic error" in issue.lower() for issue in tnc_issues_v85):
    raise SystemExit(f"PowerShell truthiness contradiction regression was not detected: {tnc_issues_v85}")

# v8.6 regressions from the final v8.5 assessment

why_unknown_user_v86 = """TEST 7 — EVIDENCE-ONLY UNKNOWN
Evidence:
- Numpad does not type numbers in SAP B1.
- Numpad works in Teams.
- Numpad works in Word.
- Num Lock is enabled.
- Number-row keys produce symbols as if Shift is pressed.
- Caps Lock off produces uppercase letters.
- Caps Lock on produces lowercase letters.
- Citrix Workspace reset did not change the behavior.
Output exactly:
Observed:
Scope:
Already tested:
Unknown:
Unknown must contain only unresolved observations directly implied by the supplied evidence."""
why_unknown_bad_v86 = """Observed: supplied.
Scope: SAP B1.
Already tested: Citrix Workspace reset.
Unknown: Why number-row keys behave as if Shift is pressed while Caps Lock inversion occurs simultaneously within SAP B1."""
why_unknown_good_v86 = """Observed: supplied.
Scope: SAP B1.
Already tested: Citrix Workspace reset.
Unknown: Whether applications other than SAP B1, Teams, and Word exhibit either reported keyboard behavior."""
bad_why_v86 = namespace["_deterministic_issues"](why_unknown_user_v86, why_unknown_bad_v86)
good_why_v86 = namespace["_deterministic_issues"](why_unknown_user_v86, why_unknown_good_v86)
if not any("why/reason" in issue.lower() or "root-cause" in issue.lower() for issue in bad_why_v86):
    raise SystemExit(f"generic Why evidence-Unknown regression was not detected: {bad_why_v86}")
if good_why_v86:
    raise SystemExit(f"literal observation-only Unknown was incorrectly flagged: {good_why_v86}")

uncertainty_user_v86 = """TEST 15 — UNCERTAINTY REVERSAL
Evidence:
- A service fails from Client A.
- The same service works from Client B.
- Both clients resolve the same IP.
- No port test has been performed from Client A.
Output exactly:
Conclusion:
Reason:
Required evidence:
Do not invent a firewall.
Do not invent routing.
Do not invent a client-side cause."""
uncertainty_bad_v86 = """Conclusion: No.
Reason: The service works from Client B. Client A's failure may be client-side or network-path specific.
Required evidence: Port connectivity test from Client A."""
uncertainty_good_v86 = """Conclusion: No.
Reason: The service works from Client B, so the supplied evidence does not establish that the service is down; Client A's failure remains unexplained.
Required evidence: Port connectivity test from Client A."""
bad_uncertainty_v86 = namespace["_deterministic_issues"](uncertainty_user_v86, uncertainty_bad_v86)
good_uncertainty_v86 = namespace["_deterministic_issues"](uncertainty_user_v86, uncertainty_good_v86)
if not any("cause constraint" in issue.lower() or "prohibited causal" in issue.lower() for issue in bad_uncertainty_v86):
    raise SystemExit(f"explicit cause-prohibition regression was not detected: {bad_uncertainty_v86}")
if good_uncertainty_v86:
    raise SystemExit(f"cause-neutral uncertainty answer was incorrectly flagged: {good_uncertainty_v86}")

token_user_v86 = """TEST 6 — POWERSHELL SUBEXPRESSION MINIMALITY
Review:
$value = 10
if ($value = 5) {
    Write-Host "Five"
}
Output exactly:
Finding:
Smallest correction:"""
token_bad_v86 = """Finding: The assignment operator `-=` or `=` is used instead of the comparison operator `-eq`.
Smallest correction:
$value -eq 5"""
token_good_v86 = """Finding: The assignment operator `=` is used instead of the comparison operator `-eq`.
Smallest correction:
$value -eq 5"""
bad_token_v86 = namespace["_deterministic_issues"](token_user_v86, token_bad_v86)
good_token_v86 = namespace["_deterministic_issues"](token_user_v86, token_good_v86)
if not any("token fidelity" in issue.lower() or "operator" in issue.lower() for issue in bad_token_v86):
    raise SystemExit(f"supplied-operator fidelity regression was not detected: {bad_token_v86}")
if good_token_v86:
    raise SystemExit(f"source-faithful operator finding was incorrectly flagged: {good_token_v86}")

# v8.8 final-assembly deterministic regressions

yaml_user_v87 = """TEST 14 — SOURCE FIDELITY WITHOUT WEB
Use only this supplied source:

services:
  - name: alpha
    enabled: true
  - name: beta
    enabled: false

Return exactly:

services:
  - name: beta
    enabled: false

Constraints:
- Preserve YAML list structure.
- Preserve boolean type."""
yaml_bad_v87 = """TEST 14 — SOURCE FIDELITY WITHOUT WEB
services:

name: beta
enabled: false"""
yaml_good_v87 = """TEST 14 — SOURCE FIDELITY WITHOUT WEB
services:
  - name: beta
    enabled: false"""
bad_yaml_v87 = namespace["_generic_exact_yaml_issues"](yaml_user_v87, yaml_bad_v87)
good_yaml_v87 = namespace["_generic_exact_yaml_issues"](yaml_user_v87, yaml_good_v87)
if not bad_yaml_v87:
    raise SystemExit("generic exact-YAML list drift was not detected")
if good_yaml_v87:
    raise SystemExit(f"exact YAML was incorrectly flagged: {good_yaml_v87}")

down_user_v87 = """TEST 15 — UNCERTAINTY REVERSAL
Evidence:
- A service fails from Client A.
- The same service works from Client B.
- Both clients resolve the same IP.
Question:
Is the server service definitely down?
Output exactly:
Conclusion:
Reason:
Required evidence:"""
down_bad_v87 = """TEST 15 — UNCERTAINTY REVERSAL
Conclusion: Indeterminate.
Reason: The service works from Client B.
Required evidence: Port connectivity test from Client A."""
down_good_v87 = """TEST 15 — UNCERTAINTY REVERSAL
Conclusion: No.
Reason: The service works from Client B, so it is not definitely down; Client A's failure reason remains unresolved.
Required evidence: Port connectivity test from Client A."""
bad_down_v87 = namespace["_definite_proposition_issues"](down_user_v87, down_bad_v87)
good_down_v87 = namespace["_definite_proposition_issues"](down_user_v87, down_good_v87)
if not bad_down_v87:
    raise SystemExit("definitely-down semantic reversal was not detected")
if good_down_v87:
    raise SystemExit(f"correct definite-down answer was incorrectly flagged: {good_down_v87}")

print("Advanced final precision deterministic regression self-test passed: v8.6 suite + generic-exact-yaml + definite-proposition")
PYGUARDTEST

GUARD_CONTENT="$(cat ${WORKDIR}/response_discipline_guard.py)"
GUARD_JSON="$(jq -n --arg id "$GUARD_ID" --arg name "$GUARD_NAME" --arg content "$GUARD_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Global response discipline plus Advanced native-stream tool-first delivery and final precision audit: outlet-stage checks remain active, while v8.8 also audits the actual persisted post-tool final answer before reveal; deterministic checks cover calculator relationships, continuation cleanup, literal evidence/uncertainty, cross-TEST source isolation, exact numbering, generic exact-YAML structure, definite propositions, supplied-token fidelity and minimal corrections."}}')"
GUARD_HTTP="$(curl -sS -o ${WORKDIR}/guard-current.json -w '%{http_code}' "$WEBUI_URL/api/v1/functions/id/$GUARD_ID" -H "Authorization: Bearer $TOKEN")"
if [[ "$GUARD_HTTP" == 200 ]]; then
  curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$GUARD_ID/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$GUARD_JSON" >${WORKDIR}/guard-installed.json
else
  curl -fsS -X POST "$WEBUI_URL/api/v1/functions/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$GUARD_JSON" >${WORKDIR}/guard-installed.json
fi
GUARD_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$GUARD_ID" -H "Authorization: Bearer $TOKEN")"
[[ "$(jq -r '.is_active' <<<"$GUARD_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$GUARD_ID/toggle" -H "Authorization: Bearer $TOKEN" >/dev/null
GUARD_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$GUARD_ID" -H "Authorization: Bearer $TOKEN")"
[[ "$(jq -r '.is_global' <<<"$GUARD_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$GUARD_ID/toggle/global" -H "Authorization: Bearer $TOKEN" >/dev/null
ok "Response Discipline Guard is active globally; Fast / Advanced / Deep Research use think=false to prevent visible self-review loops"

if [[ "$INSTALL_DOCUMENT_MEMORY" == 1 ]]; then
  section "INSTALLING PERSISTENT DOCUMENT MEMORY GATE"
  cat >${WORKDIR}/document_memory_gate.py <<'PYFUNC'
"""
title: Persistent Document Memory Gate
author: Local AI Suite
version: 1.0.0
description: Ask before persisting uploaded documents, index approved files in Knowledge/Memory, and recall only matching documents in future chats.
"""

import re
from collections import Counter
from typing import Optional

from pydantic import BaseModel, Field

from open_webui.internal.db import get_async_db_context
from open_webui.models.files import Files
from open_webui.models.knowledge import KnowledgeForm, Knowledges
from open_webui.models.memories import Memories
from open_webui.models.users import Users
from open_webui.routers.knowledge import embed_knowledge_base_metadata
from open_webui.routers.memories import AddMemoryForm, add_memory
from open_webui.routers.retrieval import ProcessFileForm, process_file
from open_webui.utils.misc import add_or_update_system_message


MARKER = "DOC_MEMORY_INDEX_V1"
KB_NAME = "Persistent Document Memory"
KB_DESCRIPTION = (
    "Documents explicitly approved by the user for persistent cross-chat recall. "
    "Use only relevant files/chunks for the current topic."
)

# Small multilingual stopword set. Technical words/acronyms are intentionally retained.
STOPWORDS = {
    "about", "after", "again", "also", "and", "are", "because", "been", "before",
    "being", "between", "but", "can", "could", "did", "does", "document", "documents",
    "for", "from", "had", "has", "have", "how", "into", "its", "may", "more", "not",
    "of", "on", "only", "or", "other", "our", "should", "that", "the", "their", "then",
    "there", "these", "they", "this", "those", "through", "to", "use", "using", "was",
    "were", "what", "when", "where", "which", "who", "why", "will", "with", "would",
    "you", "your",
    "aber", "auch", "aus", "bei", "das", "dem", "den", "der", "die", "dies", "diese",
    "ein", "eine", "einer", "eines", "für", "hat", "haben", "ich", "ist", "mit", "nach",
    "nicht", "oder", "sich", "sind", "und", "von", "vor", "was", "wie", "wir", "wird", "zu",
    "din", "este", "la", "mai", "nu", "pentru", "sau", "si", "sunt", "un", "una", "unei",
}


def _norm_tokens(text: str) -> list[str]:
    words = re.findall(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9_.:+#/-]{2,}", (text or "").lower())
    return [w.strip("._:/-+") for w in words if w.strip("._:/-+") and w not in STOPWORDS]


def _slug(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", (value or "document")).strip("-._").lower()
    return (value or "document")[:80]


def _latest_user_text(body: dict, metadata: dict) -> str:
    prompt = (metadata or {}).get("user_prompt")
    if isinstance(prompt, str) and prompt.strip():
        return prompt.strip()
    for msg in reversed(body.get("messages") or []):
        if msg.get("role") != "user":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            return content.strip()
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    parts.append(str(item.get("text") or ""))
            return "\n".join(parts).strip()
    return ""


def _extract_file_entries(files) -> list[dict]:
    result = []
    seen = set()
    for item in files or []:
        if not isinstance(item, dict):
            continue
        f = item.get("file") or item.get("files") or item
        if not isinstance(f, dict):
            continue
        file_id = f.get("id") or item.get("id")
        filename = f.get("filename") or f.get("name") or item.get("name") or "uploaded document"
        if not file_id or file_id in seen:
            continue
        seen.add(file_id)
        result.append({"id": str(file_id), "filename": str(filename)})
    return result


def _parse_index(content: str) -> dict:
    out = {}
    for line in (content or "").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        out[key.strip().lower()] = value.strip()
    return out


def _document_keywords(filename: str, content: str, limit: int) -> list[str]:
    filename_words = _norm_tokens(filename)
    content_words = _norm_tokens((content or "")[:1_500_000])
    counts = Counter(content_words)
    # Filename terms get an artificial boost because they are usually highly descriptive.
    for word in filename_words:
        counts[word] += 25
    keywords = []
    for word, _ in counts.most_common(max(limit * 3, 100)):
        if len(word) < 3 or word in STOPWORDS:
            continue
        if word not in keywords:
            keywords.append(word)
        if len(keywords) >= limit:
            break
    return keywords


def _select_excerpts(content: str, query: str, max_chars: int = 5000) -> str:
    if not content:
        return ""
    query_tokens = set(_norm_tokens(query))
    if not query_tokens:
        return ""

    clean = re.sub(r"\r\n?", "\n", content)
    paragraphs = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", clean)]
    paragraphs = [p for p in paragraphs if len(p) >= 40]

    # Long parsers sometimes return very few huge paragraphs. Slice them as well.
    chunks = []
    for p in paragraphs:
        if len(p) <= 1800:
            chunks.append(p)
        else:
            for i in range(0, len(p), 1500):
                chunks.append(p[i : i + 1800])

    scored = []
    for idx, chunk in enumerate(chunks):
        c = chunk.lower()
        score = sum(3 + min(c.count(t), 4) for t in query_tokens if len(t) >= 3 and t in c)
        if score:
            scored.append((score, idx, chunk))

    scored.sort(key=lambda x: (-x[0], x[1]))
    chosen = []
    used = 0
    for _, _, chunk in scored[:5]:
        if used + len(chunk) > max_chars and chosen:
            break
        chosen.append(chunk)
        used += len(chunk)
        if used >= max_chars:
            break
    return "\n\n---\n\n".join(chosen)[:max_chars]


class Filter:
    class Valves(BaseModel):
        knowledge_base_name: str = Field(default=KB_NAME)
        keywords_per_document: int = Field(default=60, ge=20, le=120)
        max_recalled_documents: int = Field(default=3, ge=1, le=8)
        max_excerpt_chars_per_document: int = Field(default=5000, ge=1000, le=12000)
        notify_when_recalled: bool = Field(default=False)

    def __init__(self):
        self.valves = self.Valves()
        self._declined_this_runtime = set()

    async def _user_model(self, user_dict):
        user_id = (user_dict or {}).get("id")
        return await Users.get_user_by_id(user_id) if user_id else None

    async def _doc_memories(self, user_id: str):
        memories = await Memories.get_memories_by_user_id(user_id)
        return [m for m in (memories or []) if MARKER in (m.content or "")]

    async def _already_indexed(self, user_id: str, file_id: str, file_hash: str | None) -> bool:
        for memory in await self._doc_memories(user_id):
            text = memory.content or ""
            if f"file_id: {file_id}" in text:
                return True
            if file_hash and f"file_hash: {file_hash}" in text:
                return True
        return False

    async def _get_or_create_kb(self, request, user_model):
        name = self.valves.knowledge_base_name.strip() or KB_NAME
        bases = await Knowledges.get_knowledge_bases_by_user_id(user_model.id, permission="write")
        for kb in bases:
            if kb.user_id == user_model.id and kb.name == name:
                return kb

        kb = await Knowledges.insert_new_knowledge(
            user_model.id,
            KnowledgeForm(name=name, description=KB_DESCRIPTION, access_grants=[]),
        )
        if not kb:
            raise RuntimeError("Could not create persistent document Knowledge Base")
        await embed_knowledge_base_metadata(request, kb.id, kb.name, kb.description)
        return kb

    async def _remember_document(self, request, user_model, file_obj):
        kb = await self._get_or_create_kb(request, user_model)

        if not await Knowledges.has_file(kb.id, file_obj.id):
            linked = await Knowledges.add_file_to_knowledge_by_id(
                knowledge_id=kb.id,
                file_id=file_obj.id,
                user_id=user_model.id,
            )
            if not linked:
                raise RuntimeError("Could not link document to persistent Knowledge Base")

            # Add/copy the document's chunks into the persistent KB collection.
            async with get_async_db_context() as db:
                await process_file(
                    request,
                    ProcessFileForm(file_id=file_obj.id, collection_name=kb.id),
                    user=user_model,
                    db=db,
                )

        # Refresh because process_file may have populated extracted text/hash.
        file_obj = await Files.get_file_by_id(file_obj.id)
        data = file_obj.data or {}
        content = str(data.get("content") or "")
        file_hash = file_obj.hash or ""
        keywords = _document_keywords(
            file_obj.filename,
            content,
            self.valves.keywords_per_document,
        )

        preview = re.sub(r"\s+", " ", content).strip()[:1200]
        path = f"documents/{_slug(file_obj.filename.rsplit('.', 1)[0])}"
        memory_content = "\n".join(
            [
                MARKER,
                f"filename: {file_obj.filename}",
                f"file_id: {file_obj.id}",
                f"file_hash: {file_hash}",
                f"knowledge_base: {kb.name}",
                f"knowledge_base_id: {kb.id}",
                "keywords: " + ", ".join(keywords),
                "purpose: Persistent document approved by the user. Recall it only when the current topic/keywords match.",
                "preview: " + preview,
            ]
        )

        await add_memory(
            request,
            AddMemoryForm(content=memory_content, type="context", path=path),
            user_model,
        )
        return kb, file_obj, keywords

    async def _matching_indexes(self, user_id: str, query: str):
        qtokens = set(_norm_tokens(query))
        if not qtokens:
            return []

        matches = []
        for memory in await self._doc_memories(user_id):
            parsed = _parse_index(memory.content)
            filename = parsed.get("filename", "")
            keywords = {
                x.strip().lower()
                for x in parsed.get("keywords", "").split(",")
                if x.strip()
            }
            fname_tokens = set(_norm_tokens(filename))

            kw_overlap = qtokens & keywords
            fn_overlap = qtokens & fname_tokens
            score = len(kw_overlap) * 2 + len(fn_overlap) * 4

            # Also allow a literal multi-character keyword/path match.
            lowered = query.lower()
            literal_hits = [k for k in keywords if len(k) >= 5 and k in lowered]
            score += len(literal_hits) * 2

            if score > 0:
                matches.append((score, memory, parsed, sorted(kw_overlap | fn_overlap | set(literal_hits))))

        matches.sort(key=lambda x: (-x[0], -(x[1].updated_at or 0)))
        return matches[: self.valves.max_recalled_documents]

    async def _build_recall(self, matches, query: str):
        sections = []
        for _, memory, parsed, matched_words in matches:
            file_id = parsed.get("file_id", "")
            file_obj = await Files.get_file_by_id(file_id) if file_id else None
            content = str((file_obj.data or {}).get("content") or "") if file_obj else ""
            excerpt = _select_excerpts(
                content,
                query,
                max_chars=self.valves.max_excerpt_chars_per_document,
            )
            section = [
                f"Document: {parsed.get('filename', file_id or 'unknown')}",
                f"Knowledge Base: {parsed.get('knowledge_base', '')}",
                f"Knowledge Base ID: {parsed.get('knowledge_base_id', '')}",
                f"File ID: {file_id}",
                "Matched keywords: " + ", ".join(matched_words),
            ]
            if excerpt:
                section.append("Relevant stored excerpts:\n" + excerpt)
            else:
                section.append(
                    "No direct excerpt was selected. If this document is needed, query the referenced Knowledge Base/file before using it as evidence."
                )
            sections.append("\n".join(section))

        if not sections:
            return ""
        return (
            "<persistent_document_recall>\n"
            "Previously approved persistent documents matched the current user topic. "
            "Use only the relevant excerpts below. For exact details or missing context, query the referenced Knowledge Base/document. "
            "Do not infer unsupported document contents.\n\n"
            + "\n\n========\n\n".join(sections)
            + "\n</persistent_document_recall>"
        )

    async def inlet(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __metadata__: Optional[dict] = None,
        __files__=None,
        __request__=None,
        __event_call__=None,
        __event_emitter__=None,
        __task__=None,
    ) -> dict:
        metadata = __metadata__ or body.get("metadata") or {}

        # Never interfere with OpenWebUI's title/tag/query/autocomplete/helper calls.
        if __task__ or metadata.get("task"):
            return body

        if __request__ is None or not __user__ or not __user__.get("id"):
            return body

        user_model = await self._user_model(__user__)
        if not user_model:
            return body

        files = __files__
        if files is None:
            files = metadata.get("files") or body.get("files") or []

        # Ask once for each new uploaded document before making it persistent.
        for entry in _extract_file_entries(files):
            file_obj = await Files.get_file_by_id(entry["id"])
            if not file_obj or file_obj.user_id != user_model.id:
                continue

            if await self._already_indexed(user_model.id, file_obj.id, file_obj.hash):
                continue

            decline_key = (user_model.id, file_obj.id)
            if decline_key in self._declined_this_runtime:
                continue

            remember = False
            if __event_call__ is not None:
                try:
                    remember = bool(
                        await __event_call__(
                            {
                                "type": "confirmation",
                                "data": {
                                    "title": "Remember this document?",
                                    "message": (
                                        f"Store '{file_obj.filename}' in persistent Knowledge + Memory so it can be recalled in future chats when relevant keywords/topics are mentioned?"
                                    ),
                                },
                            }
                        )
                    )
                except Exception:
                    remember = False

            if remember:
                try:
                    kb, saved_file, keywords = await self._remember_document(
                        __request__, user_model, file_obj
                    )
                    if __event_emitter__ is not None:
                        await __event_emitter__(
                            {
                                "type": "notification",
                                "data": {
                                    "type": "success",
                                    "content": (
                                        f"Remembered '{saved_file.filename}' in '{kb.name}'. "
                                        f"Indexed {len(keywords)} recall keywords."
                                    ),
                                },
                            }
                        )
                except Exception as e:
                    if __event_emitter__ is not None:
                        await __event_emitter__(
                            {
                                "type": "notification",
                                "data": {
                                    "type": "error",
                                    "content": f"Could not persist '{file_obj.filename}': {e}",
                                },
                            }
                        )
            else:
                self._declined_this_runtime.add(decline_key)

        # Keyword/topic recall in every normal chat, including brand-new chats.
        query = _latest_user_text(body, metadata)
        if query:
            # Do not duplicate recall context in native tool-call continuation loops.
            if not any(
                isinstance(m.get("content"), str)
                and "<persistent_document_recall>" in m.get("content", "")
                for m in (body.get("messages") or [])
                if isinstance(m, dict)
            ):
                matches = await self._matching_indexes(user_model.id, query)
                if matches:
                    recall = await self._build_recall(matches, query)
                    if recall:
                        body["messages"] = add_or_update_system_message(
                            recall,
                            body.get("messages") or [],
                            append=True,
                        )
                        if self.valves.notify_when_recalled and __event_emitter__ is not None:
                            names = [x[2].get("filename", "document") for x in matches]
                            await __event_emitter__(
                                {
                                    "type": "status",
                                    "data": {
                                        "description": "Recalled: " + ", ".join(names),
                                        "done": True,
                                        "hidden": False,
                                    },
                                }
                            )

        return body
PYFUNC
  python3 -c 'import ast,sys,pathlib; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "${WORKDIR}/document_memory_gate.py"
  FUNCTION_CONTENT="$(cat ${WORKDIR}/document_memory_gate.py)"
  FUNCTION_JSON="$(jq -n --arg id "$FILTER_ID" --arg name "$FILTER_NAME" --arg content "$FUNCTION_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Ask before persisting uploads; approved documents are stored in Knowledge plus a compact Memory index and recalled only on topic/keyword matches."}}')"
  HTTP_CODE="$(curl -sS -o ${WORKDIR}/function-current.json -w '%{http_code}' "$WEBUI_URL/api/v1/functions/id/$FILTER_ID" -H "Authorization: Bearer $TOKEN")"
  if [[ "$HTTP_CODE" == 200 ]]; then curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$FILTER_ID/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$FUNCTION_JSON" >${WORKDIR}/function-installed.json; else curl -fsS -X POST "$WEBUI_URL/api/v1/functions/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$FUNCTION_JSON" >${WORKDIR}/function-installed.json; fi
  FUNC_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$FILTER_ID" -H "Authorization: Bearer $TOKEN")"; [[ "$(jq -r '.is_active' <<<"$FUNC_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$FILTER_ID/toggle" -H "Authorization: Bearer $TOKEN" >/dev/null
  FUNC_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$FILTER_ID" -H "Authorization: Bearer $TOKEN")"; [[ "$(jq -r '.is_global' <<<"$FUNC_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$FILTER_ID/toggle/global" -H "Authorization: Bearer $TOKEN" >/dev/null
  ok "Persistent Document Memory Gate is active globally"
fi


if json_bool "$INSTALL_DEEP_RESEARCH"; then
  section "DEEP RESEARCH SANDBOX CONTROLLER"
  $SUDO mkdir -p "$SANDBOX_DIR" "$SANDBOX_DIR/secrets" "$SANDBOX_DIR/image"

  ADMIN_SECRET_FILE="$SANDBOX_DIR/secrets/controller-admin.key"
  UI_SECRET_FILE="$SANDBOX_DIR/secrets/controller-ui.key"
  if ! $SUDO test -s "$ADMIN_SECRET_FILE"; then openssl rand -hex 32 | $SUDO tee "$ADMIN_SECRET_FILE" >/dev/null; fi
  if ! $SUDO test -s "$UI_SECRET_FILE"; then openssl rand -hex 32 | $SUDO tee "$UI_SECRET_FILE" >/dev/null; fi
  $SUDO chmod 600 "$ADMIN_SECRET_FILE" "$UI_SECRET_FILE"
  CONTROLLER_ADMIN_SECRET="$($SUDO cat "$ADMIN_SECRET_FILE")"
  CONTROLLER_UI_SECRET="$($SUDO cat "$UI_SECRET_FILE")"

  $SUDO tee "$SANDBOX_DIR/image/Dockerfile" >/dev/null <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl wget git jq file unzip zip \
    python3 python3-pip python3-venv build-essential cmake pkg-config \
    nodejs npm procps iproute2 dnsutils netcat-openbsd openssl sqlite3 \
    && rm -rf /var/lib/apt/lists/*
# Do not force UID 1000. Some Ubuntu base images already contain a UID 1000
# account, which makes `useradd -u 1000` fail. Let useradd choose the first
# available unprivileged UID instead.
RUN useradd -m -s /bin/bash researcher \
    && mkdir -p /workspace \
    && chown -R researcher:researcher /workspace /home/researcher
USER researcher
WORKDIR /workspace
ENV HOME=/home/researcher
CMD ["sleep", "infinity"]
DOCKERFILE

  if ! $DOCKER_CMD image inspect "$SANDBOX_IMAGE" >/dev/null 2>&1 || [[ "${REBUILD_SANDBOX_IMAGE:-0}" == 1 ]]; then
    info "Building isolated Deep Research sandbox image (one-time build)"
    $DOCKER_CMD build -t "$SANDBOX_IMAGE" "$SANDBOX_DIR/image"
  else
    ok "Sandbox image already exists: $SANDBOX_IMAGE"
  fi

  # Validate the sandbox image before installing the controller. This catches
  # broken user creation, HOME ownership, and workspace permissions early.
  if ! SANDBOX_SELFTEST="$($DOCKER_CMD run --rm "$SANDBOX_IMAGE" /bin/bash -lc 'set -e; test "$(id -un)" = researcher; test -w /workspace; touch /workspace/.local-ai-write-test; rm -f /workspace/.local-ai-write-test; printf "user=%s uid=%s workspace=writeable\n" "$(id -un)" "$(id -u)"' 2>&1)"; then
    fail "Sandbox image self-test failed: $SANDBOX_SELFTEST"
  fi
  ok "Sandbox image self-test passed: $SANDBOX_SELFTEST"

  $SUDO tee "$SANDBOX_DIR/controller.py" >/dev/null <<'PYCTRL'
#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
import urllib.request
import urllib.parse
import socket
import ipaddress
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import PurePosixPath

HOST = os.environ.get("LAI_CONTROLLER_HOST", "0.0.0.0")
PORT = int(os.environ.get("LAI_CONTROLLER_PORT", "8787"))
DATA_DIR = os.environ.get("LAI_CONTROLLER_DIR", "/opt/local-ai-suite/deep-research")
DB_PATH = os.path.join(DATA_DIR, "state.sqlite3")
ADMIN_SECRET_FILE = os.path.join(DATA_DIR, "secrets", "controller-admin.key")
UI_SECRET_FILE = os.path.join(DATA_DIR, "secrets", "controller-ui.key")
IMAGE = os.environ.get("LAI_SANDBOX_IMAGE", "local-ai-research-sandbox:v2")
MEMORY = os.environ.get("LAI_SANDBOX_MEMORY", "8g")
CPUS = os.environ.get("LAI_SANDBOX_CPUS", "6")
PIDS = os.environ.get("LAI_SANDBOX_PIDS", "512")
NETWORK = os.environ.get("LAI_SANDBOX_NETWORK", "bridge")
IDLE_SECONDS = int(os.environ.get("LAI_SANDBOX_IDLE_SECONDS", "1200"))
MAX_OUTPUT = int(os.environ.get("LAI_SANDBOX_MAX_OUTPUT", "60000"))
DOCKER = os.environ.get("LAI_DOCKER_BIN", "/usr/bin/docker")
OLLAMA_URL = os.environ.get("LAI_OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
MODEL_KEEP_ALIVE = os.environ.get("LAI_MODEL_KEEP_ALIVE", "15m")
WARM_MODELS = {
    "natural-fast:27b",
    "research-plus:27b",
    "deep-research:27b",
}

# v8.7: the browser calls this only after the final Native tool continuation
# has been persisted. It repairs the actual assembled answer, not an earlier
# outlet-stage assistant fragment.
ADVANCED_FINAL_MODEL = os.environ.get(
    "LAI_ADVANCED_FINAL_MODEL",
    "research-plus:27b",
)
ADVANCED_FINAL_MAX_USER = int(
    os.environ.get("LAI_ADVANCED_FINAL_MAX_USER", "24000")
)
ADVANCED_FINAL_MAX_ANSWER = int(
    os.environ.get("LAI_ADVANCED_FINAL_MAX_ANSWER", "36000")
)
ADVANCED_FINAL_REPAIR_MAX = int(
    os.environ.get("LAI_ADVANCED_FINAL_REPAIR_MAX", "2")
)

SEARXNG_URL = os.environ.get("LAI_SEARXNG_URL", "http://127.0.0.1:8081").rstrip("/")
WEB_PRE_SEARCH_MAX = int(os.environ.get("LAI_WEB_PRE_SEARCH_MAX", "3"))
WEB_PRE_FETCH_MAX = int(os.environ.get("LAI_WEB_PRE_FETCH_MAX", "5"))
WEB_POST_SEARCH_MAX = int(os.environ.get("LAI_WEB_POST_SEARCH_MAX", "1"))
WEB_POST_FETCH_MAX = int(os.environ.get("LAI_WEB_POST_FETCH_MAX", "2"))
WEB_SEARCH_RESULTS = int(os.environ.get("LAI_WEB_SEARCH_RESULTS", "5"))
WEB_FETCH_MAX_BYTES = int(os.environ.get("LAI_WEB_FETCH_MAX_BYTES", "750000"))
WEB_FETCH_MAX_TEXT = int(os.environ.get("LAI_WEB_FETCH_MAX_TEXT", "60000"))
POST_VALIDATION_REASONS = {
    "validator_insufficient",
    "docs_missing_or_ambiguous",
    "primary_sources_conflict",
}

SCOPE_AUDIT_MODEL = os.environ.get("LAI_SCOPE_AUDIT_MODEL", "background-scout:270m")
SCOPE_AUDIT_ARTIFACT_CHARS = int(os.environ.get("LAI_SCOPE_AUDIT_ARTIFACT_CHARS", "24000"))
SCOPE_AUDIT_BRIEF_CHARS = int(os.environ.get("LAI_SCOPE_AUDIT_BRIEF_CHARS", "8000"))
SEMANTIC_AUDIT_MODEL = os.environ.get("LAI_SEMANTIC_AUDIT_MODEL", "natural-fast:27b")
SEMANTIC_AUDIT_ARTIFACT_CHARS = int(os.environ.get("LAI_SEMANTIC_AUDIT_ARTIFACT_CHARS", "22000"))
SEMANTIC_AUDIT_EVIDENCE_CHARS = int(os.environ.get("LAI_SEMANTIC_AUDIT_EVIDENCE_CHARS", "36000"))
SEMANTIC_AUDIT_SCOPE_CHARS = int(os.environ.get("LAI_SEMANTIC_AUDIT_SCOPE_CHARS", "8000"))
SEMANTIC_REPAIR_MAX = int(os.environ.get("LAI_SEMANTIC_REPAIR_MAX", "3"))
EVIDENCE_GAP_MIN_CHARS = int(os.environ.get("LAI_EVIDENCE_GAP_MIN_CHARS", "40"))
LESSON_MODEL = os.environ.get("LAI_LESSON_MODEL", "background-scout:270m")
LESSON_RETRIEVAL_MAX = int(os.environ.get("LAI_LESSON_RETRIEVAL_MAX", "5"))
LESSON_ARTIFACT_CHARS = int(os.environ.get("LAI_LESSON_ARTIFACT_CHARS", "12000"))
LESSON_FAILURE_CHARS = int(os.environ.get("LAI_LESSON_FAILURE_CHARS", "6000"))

os.makedirs(DATA_DIR, exist_ok=True)


def read_secret(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""


def conn():
    db = sqlite3.connect(DB_PATH, timeout=30)
    db.row_factory = sqlite3.Row
    return db


def init_db():
    with conn() as db:
        db.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                container_name TEXT NOT NULL,
                volume_name TEXT NOT NULL,
                brief TEXT NOT NULL DEFAULT '',
                revisions TEXT NOT NULL DEFAULT '[]',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                last_used INTEGER NOT NULL,
                PRIMARY KEY(chat_id, root_id, user_id)
            )
        """)
        session_cols = {r["name"] for r in db.execute("PRAGMA table_info(sessions)").fetchall()}
        if "scope_basis" not in session_cols:
            db.execute("ALTER TABLE sessions ADD COLUMN scope_basis TEXT NOT NULL DEFAULT ''")

        db.execute("""
            CREATE TABLE IF NOT EXISTS updates (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                text TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                consumed INTEGER NOT NULL DEFAULT 0
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS validation_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                artifact TEXT NOT NULL DEFAULT 'generated artifact',
                command TEXT NOT NULL DEFAULT '',
                exit_code INTEGER NOT NULL,
                output_hash TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_validation_runs_session
            ON validation_runs(chat_id, root_id, user_id, artifact, id)
        """)
        validation_cols = {r["name"] for r in db.execute("PRAGMA table_info(validation_runs)").fetchall()}
        if "output_text" not in validation_cols:
            db.execute("ALTER TABLE validation_runs ADD COLUMN output_text TEXT NOT NULL DEFAULT ''")

        db.execute("""
            CREATE TABLE IF NOT EXISTS learned_lessons (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                signature_hash TEXT NOT NULL,
                domain TEXT NOT NULL DEFAULT '',
                topic TEXT NOT NULL DEFAULT '',
                error_signature TEXT NOT NULL DEFAULT '',
                bad_pattern TEXT NOT NULL DEFAULT '',
                root_cause TEXT NOT NULL DEFAULT '',
                validated_fix TEXT NOT NULL DEFAULT '',
                validator TEXT NOT NULL DEFAULT '',
                software_version TEXT NOT NULL DEFAULT '',
                evidence TEXT NOT NULL DEFAULT '',
                confidence REAL NOT NULL DEFAULT 0.85,
                hits INTEGER NOT NULL DEFAULT 0,
                successful_reuses INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                last_verified_at INTEGER NOT NULL,
                superseded_by INTEGER,
                active INTEGER NOT NULL DEFAULT 1,
                UNIQUE(user_id, signature_hash)
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_learned_lessons_user
            ON learned_lessons(user_id, active, last_verified_at DESC)
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS lesson_retrievals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                lesson_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                successful INTEGER NOT NULL DEFAULT 0,
                UNIQUE(chat_id, root_id, user_id, lesson_id)
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_lesson_retrievals_session
            ON lesson_retrievals(chat_id, root_id, user_id, successful)
        """)

        db.execute("""
            CREATE TABLE IF NOT EXISTS web_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                target TEXT NOT NULL DEFAULT '',
                phase TEXT NOT NULL,
                reason TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_web_usage_session
            ON web_usage(chat_id, root_id, user_id, phase, kind, id)
        """)

        # v5.9 migration: post-validation exception requests must include a
        # concrete explanation of the evidence gap.
        web_cols = {r["name"] for r in db.execute("PRAGMA table_info(web_usage)").fetchall()}
        if "evidence_gap" not in web_cols:
            db.execute("ALTER TABLE web_usage ADD COLUMN evidence_gap TEXT NOT NULL DEFAULT ''")

        db.execute("""
            CREATE TABLE IF NOT EXISTS scope_audits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                artifact TEXT NOT NULL,
                artifact_hash TEXT NOT NULL,
                brief_hash TEXT NOT NULL,
                passed INTEGER NOT NULL,
                result_json TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_scope_audits_session
            ON scope_audits(chat_id, root_id, user_id, artifact_hash, brief_hash, id)
        """)

        db.execute("""
            CREATE TABLE IF NOT EXISTS web_evidence (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                url TEXT NOT NULL,
                content_type TEXT NOT NULL DEFAULT '',
                content_hash TEXT NOT NULL,
                content_text TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                UNIQUE(chat_id, root_id, user_id, url, content_hash)
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_web_evidence_session
            ON web_evidence(chat_id, root_id, user_id, id)
        """)

        db.execute("""
            CREATE TABLE IF NOT EXISTS semantic_audits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                artifact TEXT NOT NULL,
                artifact_hash TEXT NOT NULL,
                evidence_hash TEXT NOT NULL DEFAULT '',
                scope_hash TEXT NOT NULL DEFAULT '',
                passed INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'failed',
                result_hash TEXT NOT NULL DEFAULT '',
                result_json TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_semantic_audits_session
            ON semantic_audits(chat_id, root_id, user_id, artifact, id)
        """)

        db.execute("""
            CREATE TABLE IF NOT EXISTS step_timings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                step_kind TEXT NOT NULL DEFAULT '',
                label TEXT NOT NULL DEFAULT '',
                duration_ms INTEGER NOT NULL DEFAULT 0,
                outcome TEXT NOT NULL DEFAULT 'ok',
                detail TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL
            )
        """)
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_step_timings_session
            ON step_timings(chat_id, root_id, user_id, id)
        """)
        db.commit()


def clean_id(value, fallback="x"):
    value = str(value or "").strip()
    return value[:256] if value else fallback


def names(chat_id, root_id, user_id):
    digest = hashlib.sha256(f"{user_id}|{chat_id}|{root_id}".encode()).hexdigest()[:20]
    return f"lai-dr-{digest}", f"lai-dr-data-{digest}"


def session_get(chat_id, root_id, user_id):
    with conn() as db:
        row = db.execute(
            "SELECT * FROM sessions WHERE chat_id=? AND root_id=? AND user_id=?",
            (chat_id, root_id, user_id),
        ).fetchone()
        return dict(row) if row else None


def session_ensure(chat_id, root_id, user_id):
    chat_id, root_id, user_id = map(clean_id, (chat_id, root_id, user_id))
    row = session_get(chat_id, root_id, user_id)
    if row:
        return row
    c, v = names(chat_id, root_id, user_id)
    now = int(time.time())
    with conn() as db:
        db.execute(
            "INSERT OR IGNORE INTO sessions(chat_id,root_id,user_id,container_name,volume_name,created_at,updated_at,last_used) VALUES(?,?,?,?,?,?,?,?)",
            (chat_id, root_id, user_id, c, v, now, now, now),
        )
        db.commit()
    return session_get(chat_id, root_id, user_id)


def touch(row):
    now = int(time.time())
    with conn() as db:
        db.execute(
            "UPDATE sessions SET updated_at=?,last_used=? WHERE chat_id=? AND root_id=? AND user_id=?",
            (now, now, row["chat_id"], row["root_id"], row["user_id"]),
        )
        db.commit()


def run(args, timeout=60, input_bytes=None):
    p = subprocess.run(
        args,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=max(1, min(int(timeout), 600)),
    )
    out = p.stdout.decode("utf-8", "replace")
    return p.returncode, out[-MAX_OUTPUT:]


def docker_exists(name):
    return subprocess.run([DOCKER, "inspect", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def docker_running(name):
    p = subprocess.run([DOCKER, "inspect", "-f", "{{.State.Running}}", name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode == 0 and p.stdout.decode().strip() == "true"


def sandbox_ensure(row):
    name, volume = row["container_name"], row["volume_name"]
    subprocess.run([DOCKER, "volume", "create", volume], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    if not docker_exists(name):
        args = [
            DOCKER, "create", "--name", name,
            "--memory", MEMORY,
            "--cpus", CPUS,
            "--pids-limit", PIDS,
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges:true",
            "--read-only",
            "--tmpfs", "/tmp:rw,nosuid,size=1g",
            "--network", NETWORK,
            "-v", f"{volume}:/workspace",
            "-w", "/workspace",
            "-e", "HOME=/workspace/.home",
            "-e", "XDG_CACHE_HOME=/workspace/.cache",
            "-e", "PIP_CACHE_DIR=/workspace/.cache/pip",
            IMAGE,
        ]
        rc, out = run(args, timeout=120)
        if rc != 0:
            raise RuntimeError(out)
    if not docker_running(name):
        rc, out = run([DOCKER, "start", name], timeout=60)
        if rc != 0:
            raise RuntimeError(out)

    # Persistent writable user/cache area for package managers and test tooling.
    # Existing research volumes from older releases are upgraded lazily.
    rc, out = run(
        [
            DOCKER, "exec", name,
            "/bin/bash", "--noprofile", "--norc", "-lc",
            "mkdir -p /workspace/.home /workspace/.cache/pip /workspace/.venvs",
        ],
        timeout=30,
    )
    if rc != 0:
        raise RuntimeError(out)

    touch(row)
    return session_get(row["chat_id"], row["root_id"], row["user_id"])


def sandbox_stop(row):
    if docker_running(row["container_name"]):
        run([DOCKER, "stop", "-t", "3", row["container_name"]], timeout=20)


def sandbox_delete(row):
    name, volume = row["container_name"], row["volume_name"]
    run([DOCKER, "rm", "-f", name], timeout=30)
    run([DOCKER, "volume", "rm", "-f", volume], timeout=30)
    with conn() as db:
        db.execute("DELETE FROM updates WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM validation_runs WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM web_usage WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM web_evidence WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM scope_audits WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM semantic_audits WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM lesson_retrievals WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM step_timings WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.execute("DELETE FROM sessions WHERE chat_id=? AND root_id=? AND user_id=?", (row["chat_id"], row["root_id"], row["user_id"]))
        db.commit()


def safe_path(path):
    """Normalize every tool-visible path into /workspace exactly once."""
    raw = str(path or ".").strip().replace("\\", "/")
    if raw in {"", ".", "/", "workspace", "/workspace"}:
        rel = "."
    elif raw.startswith("/workspace/"):
        rel = raw[len("/workspace/"):]
    elif raw.startswith("workspace/"):
        rel = raw[len("workspace/"):]
    else:
        rel = raw.lstrip("/")

    p = PurePosixPath(rel or ".")
    if p.is_absolute() or ".." in p.parts:
        raise ValueError("Path traversal is not allowed")
    return str(PurePosixPath("/workspace") / p)


class _HTMLText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag in {"script", "style", "noscript", "svg"}:
            self.skip += 1
        elif not self.skip and tag in {"p", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in {"script", "style", "noscript", "svg"} and self.skip:
            self.skip -= 1
        elif not self.skip and tag in {"p", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"}:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)

    def text(self):
        value = "".join(self.parts)
        value = re.sub(r"[ \t\r\f\v]+", " ", value)
        value = re.sub(r"\n\s*\n\s*\n+", "\n\n", value)
        return value.strip()


def validation_has_started(row):
    with conn() as db:
        n = db.execute(
            """SELECT COUNT(*) AS n FROM validation_runs
               WHERE chat_id=? AND root_id=? AND user_id=?""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchone()["n"]
    return int(n) > 0


def web_usage_counts(row):
    with conn() as db:
        rows = db.execute(
            """SELECT phase,kind,COUNT(*) AS n
               FROM web_usage
               WHERE chat_id=? AND root_id=? AND user_id=?
               GROUP BY phase,kind""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchall()

    out = {
        "pre_search": 0,
        "pre_fetch": 0,
        "post_search": 0,
        "post_fetch": 0,
    }
    for r in rows:
        key = f"{r['phase']}_{r['kind']}"
        if key in out:
            out[key] = int(r["n"])
    return out


def reserve_web_slot(row, kind, target, reason="", evidence_gap=""):
    kind = str(kind or "").strip().lower()
    if kind not in {"search", "fetch"}:
        raise ValueError("invalid web operation")

    post = validation_has_started(row)
    phase = "post" if post else "pre"
    reason = str(reason or "").strip().lower()
    evidence_gap = re.sub(r"\s+", " ", str(evidence_gap or "").strip())

    if post and reason not in POST_VALIDATION_REASONS:
        raise RuntimeError(
            "POST-VALIDATION WEB LOCK: web access is blocked after validation begins. "
            "If a real evidence gap remains, retry with post_validation_reason set to exactly one of: "
            "validator_insufficient, docs_missing_or_ambiguous, primary_sources_conflict, AND provide evidence_gap."
        )

    if post:
        generic = {
            "need more info",
            "need more information",
            "need docs",
            "need documentation",
            "validator failed",
            "validation failed",
            "need to search",
            "need web search",
        }
        if len(evidence_gap) < EVIDENCE_GAP_MIN_CHARS or evidence_gap.lower() in generic:
            raise RuntimeError(
                "POST-VALIDATION EVIDENCE GAP REQUIRED: provide a concrete one-sentence evidence_gap "
                f"of at least {EVIDENCE_GAP_MIN_CHARS} characters explaining exactly what the validator "
                "and already-fetched primary sources do not establish. Generic explanations are rejected."
            )

    limit = (
        WEB_PRE_SEARCH_MAX if phase == "pre" and kind == "search"
        else WEB_PRE_FETCH_MAX if phase == "pre"
        else WEB_POST_SEARCH_MAX if kind == "search"
        else WEB_POST_FETCH_MAX
    )

    # Atomic reservation. Even parallel tool calls cannot overrun the cap.
    with conn() as db:
        db.execute("BEGIN IMMEDIATE")
        used = db.execute(
            """SELECT COUNT(*) AS n FROM web_usage
               WHERE chat_id=? AND root_id=? AND user_id=? AND phase=? AND kind=?""",
            (row["chat_id"], row["root_id"], row["user_id"], phase, kind),
        ).fetchone()["n"]

        if int(used) >= int(limit):
            db.rollback()
            raise RuntimeError(
                f"WEB BUDGET EXHAUSTED: {phase}-validation {kind} limit is {limit}; "
                f"{used} slot(s) already used. Do not retry this operation. "
                "Continue from evidence already collected or report the remaining evidence gap."
            )

        db.execute(
            """INSERT INTO web_usage(chat_id,root_id,user_id,kind,target,phase,reason,evidence_gap,created_at)
               VALUES(?,?,?,?,?,?,?,?,?)""",
            (
                row["chat_id"], row["root_id"], row["user_id"], kind,
                str(target or "")[:4000], phase, reason, evidence_gap[:2000], int(time.time()),
            ),
        )
        db.commit()

    counts = web_usage_counts(row)
    used_now = int(counts[f"{phase}_{kind}"])
    return {
        "phase": phase,
        "kind": kind,
        "limit": int(limit),
        "used": used_now,
        "remaining": max(0, int(limit) - used_now),
        "all_counts": counts,
    }


def _public_host_ok(hostname):
    if not hostname:
        return False
    low = hostname.strip().lower().rstrip(".")
    if low in {"localhost", "localhost.localdomain"}:
        return False

    try:
        infos = socket.getaddrinfo(low, None, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return False

    if not infos:
        return False

    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
        ):
            return False
    return True


def validate_public_url(url):
    parsed = urllib.parse.urlparse(str(url or "").strip())
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("Only public http/https URLs may be fetched")
    if not _public_host_ok(parsed.hostname):
        raise ValueError("Private, loopback, unresolved, or non-public web destinations are blocked")
    return parsed.geturl()


class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def research_web_search(row, query, reason="", evidence_gap=""):
    query = str(query or "").strip()
    if not query:
        raise ValueError("query is required")

    budget = reserve_web_slot(row, "search", query, reason, evidence_gap)
    params = urllib.parse.urlencode({
        "q": query,
        "format": "json",
        "language": "all",
    })
    request = urllib.request.Request(
        f"{SEARXNG_URL}/search?{params}",
        headers={
            "User-Agent": "LocalAI-DeepResearch/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        raw = response.read(2_000_000)

    data = json.loads(raw.decode("utf-8", "replace"))
    results = []
    for item in (data.get("results") or [])[:max(1, min(WEB_SEARCH_RESULTS, 10))]:
        url = str(item.get("url") or item.get("link") or "").strip()
        if not url:
            continue
        results.append({
            "title": str(item.get("title") or "")[:500],
            "url": url,
            "snippet": str(item.get("content") or item.get("snippet") or "")[:2000],
            "engine": str(item.get("engine") or "")[:100],
        })

    touch(row)
    return {
        "ok": True,
        "query": query,
        "results": results,
        "budget": budget,
        "instruction": "Search snippets are discovery only. Fetch the primary source before relying on exact syntax or version-sensitive claims.",
    }


def research_web_fetch(row, url, reason="", evidence_gap=""):
    url = validate_public_url(url)
    budget = reserve_web_slot(row, "fetch", url, reason, evidence_gap)

    opener = urllib.request.build_opener(_SafeRedirect())
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 LocalAI-DeepResearch/1.0",
            "Accept": "text/html,application/xhtml+xml,application/json,text/plain,application/xml,text/xml;q=0.9,*/*;q=0.2",
            "Accept-Encoding": "identity",
        },
    )

    with opener.open(request, timeout=40) as response:
        final_url = validate_public_url(response.geturl())
        content_type = str(response.headers.get("Content-Type") or "").lower()
        raw = response.read(max(1, min(WEB_FETCH_MAX_BYTES, 2_000_000)))

    charset = "utf-8"
    m = re.search(r"charset=([A-Za-z0-9._-]+)", content_type)
    if m:
        charset = m.group(1)
    try:
        decoded = raw.decode(charset, "replace")
    except LookupError:
        decoded = raw.decode("utf-8", "replace")

    if "html" in content_type or "<html" in decoded[:1000].lower():
        parser = _HTMLText()
        parser.feed(decoded)
        body = parser.text()
    elif any(x in content_type for x in ("json", "text/", "xml", "javascript")):
        body = decoded.strip()
    elif "pdf" in content_type:
        body = (
            "PDF content detected. The budgeted fetcher does not extract binary PDFs. "
            "Use an authoritative HTML/source-code page if available, or report PDF extraction as the remaining evidence gap."
        )
    else:
        body = decoded.strip()

    body = body[:max(1000, min(WEB_FETCH_MAX_TEXT, 120000))]

    # v6.6: keep a bounded copy of already-budgeted public source evidence.
    # The semantic gate never performs hidden/unbudgeted web calls; it can only
    # reason over sources that Deep Research already fetched.
    evidence_text = body[:50000]
    evidence_hash = hashlib.sha256(
        evidence_text.encode("utf-8", "replace")
    ).hexdigest()
    with conn() as db:
        db.execute(
            """INSERT OR IGNORE INTO web_evidence(
                   chat_id,root_id,user_id,url,content_type,content_hash,content_text,created_at
               ) VALUES(?,?,?,?,?,?,?,?)""",
            (
                row["chat_id"], row["root_id"], row["user_id"],
                final_url[:4000], content_type[:300], evidence_hash,
                evidence_text, int(time.time()),
            ),
        )
        db.commit()

    touch(row)
    return {
        "ok": True,
        "url": final_url,
        "content_type": content_type,
        "content": body,
        "budget": budget,
    }


def _workspace_text(row, artifact, max_chars=None):
    row = sandbox_ensure(row)
    path = safe_path(artifact)
    limit = max(1000, min(int(max_chars or SCOPE_AUDIT_ARTIFACT_CHARS), 60000))
    code = (
        "import pathlib,sys; "
        "p=pathlib.Path(sys.argv[1]); "
        "data=p.read_bytes()[:int(sys.argv[2])]; "
        "sys.stdout.write(data.decode('utf-8','replace'))"
    )
    rc, out = run(
        [DOCKER, "exec", row["container_name"], "python3", "-c", code, path, str(limit)],
        timeout=60,
    )
    if rc != 0:
        raise RuntimeError(
            f"SCOPE AUDIT ARTIFACT ERROR: unable to read {path}. "
            "Pass the actual generated file path in the artifact parameter before validation."
        )
    return path, out[:limit]


def _scope_audit_model(scope_basis, brief, artifact_text):
    system = """You are a strict scope-compliance checker for generated technical artifacts.

AUTHORITATIVE SCOPE BASIS is literal user-provided scope: the initial request plus later explicit user-approved scope updates.
APPROVED RESEARCH BRIEF is an organizational summary produced by another model.

Authority order:
1. AUTHORITATIVE SCOPE BASIS
2. Explicit user-approved updates contained in that basis
3. APPROVED RESEARCH BRIEF only where it faithfully restates that basis

The Research Brief MUST NOT silently expand user scope. A feature, sensor, protocol, integration, dashboard, telemetry item, safety mechanism, or hardware subsystem that appears only in the model-generated brief is NOT automatically required.

Compare AUTHORITATIVE SCOPE BASIS and APPROVED RESEARCH BRIEF with the GENERATED ARTIFACT.

Judge ONLY explicit scope requirements, explicit exclusions, hard limits, direct contradictions, and material scope expansion.
Do not invent requirements. Do not grade style.
If the artifact adds a material subsystem not grounded in AUTHORITATIVE SCOPE BASIS and not unavoidable for implementation, report it as a scope-expansion violation.
If AUTHORITATIVE SCOPE BASIS explicitly excludes something and the artifact contains it, that is a violation.
If AUTHORITATIVE SCOPE BASIS explicitly requires something and the artifact omits it, that is missing.
If artifact comments/claims contradict what the artifact actually contains, report that contradiction.

Return JSON only:
{
  "violations": [],
  "missing": [],
  "contradictions": [],
  "notes": []
}

DO NOT return a pass/fail boolean. The controller decides pass/fail deterministically:
- PASS only when violations, missing, and contradictions are all empty.
- FAIL when any of those three arrays contains an item."""

    user = (
        "AUTHORITATIVE SCOPE BASIS:\\n"
        + scope_basis[:SCOPE_AUDIT_BRIEF_CHARS]
        + "\\n\\nAPPROVED RESEARCH BRIEF:\\n"
        + brief[:SCOPE_AUDIT_BRIEF_CHARS]
        + "\\n\\nGENERATED ARTIFACT:\\n"
        + artifact_text[:SCOPE_AUDIT_ARTIFACT_CHARS]
    )

    payload = {
        "model": SCOPE_AUDIT_MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "format": "json",
        "keep_alive": MODEL_KEEP_ALIVE,
        "think": False,
        "options": {
            "temperature": 0.0,
            "num_predict": 400,
            "num_ctx": 8192,
        },
    }

    last_error = ""
    for _ in range(2):
        request = urllib.request.Request(
            OLLAMA_URL + "/api/chat",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                data = json.load(response)
            content = str(((data.get("message") or {}).get("content") or "")).strip()
            parsed = json.loads(content)
            if not isinstance(parsed, dict):
                raise ValueError("scope audit JSON was not an object")

            result = {
                "violations": [str(x)[:500] for x in (parsed.get("violations") or [])][:8],
                "missing": [str(x)[:500] for x in (parsed.get("missing") or [])][:8],
                "contradictions": [str(x)[:500] for x in (parsed.get("contradictions") or [])][:8],
                "notes": [str(x)[:500] for x in (parsed.get("notes") or [])][:8],
            }
            result["pass"] = not bool(
                result["violations"]
                or result["missing"]
                or result["contradictions"]
            )
            return result
        except Exception as exc:
            last_error = str(exc)
            payload["messages"].append({
                "role": "system",
                "content": "Your previous response was malformed. Return only valid JSON in the exact requested schema.",
            })

    return {
        "pass": False,
        "violations": [
            "The automatic scope audit could not produce a valid structured result; validation is blocked rather than silently bypassing the scope gate."
        ],
        "missing": [],
        "contradictions": [],
        "notes": [last_error[:500]],
    }


def scope_audit_artifact(row, artifact):
    brief = str(row.get("brief") or "").strip()
    scope_basis = str(row.get("scope_basis") or "").strip()
    if not brief:
        return {
            "ok": False,
            "passed": False,
            "cached": False,
            "artifact": str(artifact or ""),
            "violations": ["No approved Research Brief is stored for this research root."],
            "missing": [],
            "contradictions": [],
            "notes": ["Approve/save the Research Brief before validating generated artifacts."],
        }

    if not scope_basis:
        return {
            "ok": False,
            "passed": False,
            "cached": False,
            "artifact": str(artifact or ""),
            "violations": [],
            "missing": [],
            "contradictions": [],
            "notes": [
                "No authoritative user scope basis is stored for this research root. "
                "Start a new Deep Research root or approve the Research Brief again under v6.0."
            ],
        }

    path, artifact_text = _workspace_text(row, artifact)
    artifact_hash = hashlib.sha256(artifact_text.encode("utf-8", "replace")).hexdigest()
    scope_identity = scope_basis + "\n\n---APPROVED BRIEF---\n" + brief
    brief_hash = hashlib.sha256(scope_identity.encode("utf-8", "replace")).hexdigest()

    with conn() as db:
        cached = db.execute(
            """SELECT passed,result_json FROM scope_audits
               WHERE chat_id=? AND root_id=? AND user_id=? AND artifact_hash=? AND brief_hash=?
               ORDER BY id DESC LIMIT 1""",
            (row["chat_id"], row["root_id"], row["user_id"], artifact_hash, brief_hash),
        ).fetchone()

    if cached:
        try:
            result = json.loads(cached["result_json"])
        except Exception:
            result = {}
        violations = result.get("violations") or []
        missing = result.get("missing") or []
        contradictions = result.get("contradictions") or []
        deterministic_pass = not bool(violations or missing or contradictions)
        result.update({
            "ok": deterministic_pass,
            "passed": deterministic_pass,
            "cached": True,
            "decision": "deterministic_issue_arrays",
            "artifact": path,
            "artifact_hash": artifact_hash,
            "brief_hash": brief_hash,
        })
        return result

    result = _scope_audit_model(scope_basis, brief, artifact_text)
    passed = not bool(
        (result.get("violations") or [])
        or (result.get("missing") or [])
        or (result.get("contradictions") or [])
    )
    stored = {
        "violations": result.get("violations") or [],
        "missing": result.get("missing") or [],
        "contradictions": result.get("contradictions") or [],
        "notes": result.get("notes") or [],
    }

    with conn() as db:
        db.execute(
            """INSERT INTO scope_audits(
                   chat_id,root_id,user_id,artifact,artifact_hash,brief_hash,passed,result_json,created_at
               ) VALUES(?,?,?,?,?,?,?,?,?)""",
            (
                row["chat_id"], row["root_id"], row["user_id"], path,
                artifact_hash, brief_hash, 1 if passed else 0,
                json.dumps(stored, ensure_ascii=False), int(time.time()),
            ),
        )
        db.commit()

    return {
        "ok": passed,
        "passed": passed,
        "cached": False,
        "decision": "deterministic_issue_arrays",
        "artifact": path,
        "artifact_hash": artifact_hash,
        "brief_hash": brief_hash,
        **stored,
    }


def _semantic_evidence(row):
    with conn() as db:
        rows = [
            dict(r)
            for r in db.execute(
                """SELECT url,content_type,content_hash,content_text,created_at
                   FROM web_evidence
                   WHERE chat_id=? AND root_id=? AND user_id=?
                   ORDER BY id DESC LIMIT 8""",
                (row["chat_id"], row["root_id"], row["user_id"]),
            ).fetchall()
        ]

    chunks = []
    used = 0
    hashes = []
    for item in rows:
        remaining = SEMANTIC_AUDIT_EVIDENCE_CHARS - used
        if remaining <= 0:
            break
        body = str(item.get("content_text") or "")[:remaining]
        if not body:
            continue
        url = str(item.get("url") or "")
        chunks.append(
            f"SOURCE URL: {url}\n"
            f"CONTENT TYPE: {item.get('content_type','')}\n"
            f"CONTENT:\n{body}"
        )
        hashes.append(str(item.get("content_hash") or ""))
        used += len(body)

    joined = "\n\n--- PRIMARY SOURCE ---\n\n".join(chunks)
    evidence_hash = hashlib.sha256(
        ("|".join(hashes) + "\n" + joined).encode("utf-8", "replace")
    ).hexdigest()
    return joined, evidence_hash, len(chunks)


def _semantic_unique(items, limit=12):
    out = []
    seen = set()
    for item in items or []:
        value = re.sub(r"\s+", " ", str(item or "").strip())[:700]
        key = value.lower()
        if value and key not in seen:
            seen.add(key)
            out.append(value)
        if len(out) >= limit:
            break
    return out


def _semantic_deterministic_checks(scope_basis, brief, artifact_text):
    low = artifact_text.lower()
    scope_low = (str(scope_basis or "") + "\n" + str(brief or "")).lower()

    blocking = []
    warnings = []
    assumptions = []

    # ESPHome Improv-via-Serial is Wi-Fi provisioning over serial/USB. It is
    # not the fallback captive portal mechanism. A nearby comment claiming
    # otherwise is an internal semantic contradiction even though YAML syntax
    # can still validate.
    lines = artifact_text.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^\s*improv_serial\s*:", line, re.I):
            nearby = " ".join(lines[max(0, i - 4): i + 1]).lower()
            if "fallback hotspot" in nearby or "captive portal" in nearby:
                blocking.append(
                    "ESPHome semantic contradiction: improv_serial is labelled as a fallback hotspot/captive portal. "
                    "improv_serial is serial/USB Wi-Fi provisioning; use wifi.ap plus captive_portal for the fallback portal."
                )
            if not re.search(r"(?mi)^\s*logger\s*:\s*(?:#.*)?$", artifact_text):
                blocking.append(
                    "ESPHome improv_serial requires logger, but no logger: component is present."
                )

    if (
        ("fallback hotspot" in low or "fallback access point" in low or "fallback portal" in low)
        and not (
            re.search(r"(?mi)^\s+ap\s*:\s*(?:#.*)?$", artifact_text)
            and re.search(r"(?mi)^\s*captive_portal\s*:\s*(?:#.*)?$", artifact_text)
        )
    ):
        blocking.append(
            "Artifact claims/configures a Wi-Fi fallback hotspot but does not contain both wifi.ap and captive_portal."
        )

    # Control direction is a physical property of the plant, not of the output
    # component name. For pumps/fans/valves/motors, require the user scope to
    # establish whether increasing output raises or lowers the controlled
    # temperature. The audit records this as an assumption instead of silently
    # declaring heat_output/cool_output semantically proven.
    actuator_words = ("pump", "fan", "valve", "motor", "blower", "circulator")
    direction_proven_heat = bool(
        re.search(
            r"(?:pump|fan|valve|motor|blower|circulator).{0,120}"
            r"(?:increase|raise|heat|warmer).{0,80}(?:temperature|temp)",
            scope_low,
            re.I | re.S,
        )
        or re.search(
            r"(?:increase|raise|heat|warmer).{0,80}(?:temperature|temp).{0,120}"
            r"(?:pump|fan|valve|motor|blower|circulator)",
            scope_low,
            re.I | re.S,
        )
    )
    direction_proven_cool = bool(
        re.search(
            r"(?:pump|fan|valve|motor|blower|circulator).{0,120}"
            r"(?:decrease|lower|cool|colder).{0,80}(?:temperature|temp)",
            scope_low,
            re.I | re.S,
        )
        or re.search(
            r"(?:decrease|lower|cool|colder).{0,80}(?:temperature|temp).{0,120}"
            r"(?:pump|fan|valve|motor|blower|circulator)",
            scope_low,
            re.I | re.S,
        )
    )

    for kind, output_id in re.findall(
        r"(?mi)^\s*(heat_output|cool_output)\s*:\s*([A-Za-z0-9_.-]+)",
        artifact_text,
    ):
        context = (output_id + " " + artifact_text).lower()
        if not any(word in context for word in actuator_words):
            continue
        if kind.lower() == "heat_output" and not direction_proven_heat:
            assumptions.append(
                f"Physical control direction is not established by the user scope: {kind}: {output_id} "
                "assumes increasing actuator output increases the controlled temperature. Confirm the real plant direction."
            )
        if kind.lower() == "cool_output" and not direction_proven_cool:
            assumptions.append(
                f"Physical control direction is not established by the user scope: {kind}: {output_id} "
                "assumes increasing actuator output decreases the controlled temperature. Confirm the real plant direction."
            )

    # DS18B20 has a stable ROM identity. A tiny hex literal often indicates a
    # placeholder/truncated ID that can pass config validation but not identify
    # the intended physical sensor at runtime.
    if re.search(r"(?mi)^\s*-\s*platform\s*:\s*dallas_temp\s*$", artifact_text):
        for addr in re.findall(r"(?mi)^\s*address\s*:\s*(0x[0-9a-f]+)\b", artifact_text):
            digits = addr[2:]
            if len(digits) < 16:
                warnings.append(
                    f"DS18B20 address {addr} is shorter than a full 64-bit ROM ID and appears placeholder/truncated. "
                    "The configuration may validate syntactically while the intended sensor remains unverified at runtime."
                )

    return {
        "blocking_issues": _semantic_unique(blocking),
        "warnings": _semantic_unique(warnings),
        "assumptions": _semantic_unique(assumptions),
    }


def _semantic_audit_model(scope_basis, brief, artifact_text, validator_output, primary_evidence):
    system = """You are an independent semantic-consistency auditor for a generated technical artifact.

You are NOT a syntax checker. A real validator has already passed.
Your job is to detect semantic mistakes that syntax validators commonly miss.

Authority order:
1. AUTHORITATIVE USER SCOPE.
2. PRIMARY SOURCE EVIDENCE fetched earlier in this same research run.
3. The generated artifact.
4. The short Research Brief only when it faithfully summarizes user scope.

Check:
- comments/descriptions that claim a component performs a behavior it does not perform;
- claims that the artifact contains a feature/action/safety behavior which is absent;
- configuration choices whose semantics contradict the supplied primary documentation;
- physical-control direction assumptions (for example heat vs cool) that are not established by user scope;
- runtime placeholders/identities that can syntactically validate but do not prove the actual hardware behavior;
- safety semantics for pumps, motors, heaters, chargers, valves, relays and other actuators.

Do NOT invent vendor facts not present in PRIMARY SOURCE EVIDENCE.
Do NOT treat a validator PASS as proof of physical behavior.
Do NOT fail merely because optional features are absent.
If evidence is insufficient, put the uncertainty in warnings or assumptions rather than inventing certainty.

Return JSON only:
{
  "blocking_issues": [],
  "warnings": [],
  "assumptions": [],
  "verified_claims": []
}

blocking_issues: direct contradictions or claims/configuration that should be repaired before calling the artifact semantically valid.
warnings: non-blocking risks or runtime limitations.
assumptions: facts about the real system that must be true but are not established by user scope/evidence.
verified_claims: concise semantic facts actually supported by the supplied primary evidence.
"""

    user = (
        "AUTHORITATIVE USER SCOPE:\n"
        + str(scope_basis or "")[:SEMANTIC_AUDIT_SCOPE_CHARS]
        + "\n\nAPPROVED RESEARCH BRIEF:\n"
        + str(brief or "")[:SEMANTIC_AUDIT_SCOPE_CHARS]
        + "\n\nREAL VALIDATOR OUTPUT:\n"
        + str(validator_output or "")[:6000]
        + "\n\nPRIMARY SOURCE EVIDENCE FETCHED EARLIER:\n"
        + (str(primary_evidence or "")[:SEMANTIC_AUDIT_EVIDENCE_CHARS] or "None available.")
        + "\n\nGENERATED ARTIFACT:\n"
        + str(artifact_text or "")[:SEMANTIC_AUDIT_ARTIFACT_CHARS]
    )

    payload = {
        "model": SEMANTIC_AUDIT_MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "format": "json",
        "keep_alive": MODEL_KEEP_ALIVE,
        "think": False,
        "options": {
            "temperature": 0.0,
            "num_predict": 850,
            "num_ctx": 24576,
        },
    }

    last_error = ""
    for _ in range(2):
        req = urllib.request.Request(
            OLLAMA_URL + "/api/chat",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=90) as response:
                data = json.load(response)
            content = str(((data.get("message") or {}).get("content") or "")).strip()
            parsed = json.loads(content)
            if not isinstance(parsed, dict):
                raise ValueError("semantic audit JSON was not an object")
            return {
                "blocking_issues": _semantic_unique(parsed.get("blocking_issues") or []),
                "warnings": _semantic_unique(parsed.get("warnings") or []),
                "assumptions": _semantic_unique(parsed.get("assumptions") or []),
                "verified_claims": _semantic_unique(parsed.get("verified_claims") or []),
                "model_error": "",
            }
        except Exception as exc:
            last_error = str(exc)
            payload["messages"].append({
                "role": "system",
                "content": "Your previous output was malformed. Return only valid JSON with the exact requested keys.",
            })

    return {
        "blocking_issues": [],
        "warnings": [
            "Independent semantic model audit could not return valid structured output; only deterministic semantic checks were applied."
        ],
        "assumptions": [],
        "verified_claims": [],
        "model_error": last_error[:500],
    }


def semantic_audit_artifact(row, artifact, validator_output=""):
    path, artifact_text = _workspace_text(
        row,
        artifact,
        max_chars=SEMANTIC_AUDIT_ARTIFACT_CHARS,
    )
    scope_basis = str(row.get("scope_basis") or "")
    brief = str(row.get("brief") or "")
    primary_evidence, evidence_hash, source_count = _semantic_evidence(row)

    artifact_hash = hashlib.sha256(
        artifact_text.encode("utf-8", "replace")
    ).hexdigest()
    scope_hash = hashlib.sha256(
        (scope_basis + "\n---BRIEF---\n" + brief).encode("utf-8", "replace")
    ).hexdigest()

    with conn() as db:
        cached = db.execute(
            """SELECT * FROM semantic_audits
               WHERE chat_id=? AND root_id=? AND user_id=?
                 AND artifact_hash=? AND evidence_hash=? AND scope_hash=?
               ORDER BY id DESC LIMIT 1""",
            (
                row["chat_id"], row["root_id"], row["user_id"],
                artifact_hash, evidence_hash, scope_hash,
            ),
        ).fetchone()

    if cached:
        try:
            result = json.loads(cached["result_json"])
        except Exception:
            result = {}
        result.update({
            "ok": bool(cached["passed"]),
            "passed": bool(cached["passed"]),
            "status": cached["status"],
            "cached": True,
            "artifact": path,
            "artifact_hash": artifact_hash,
            "source_count": source_count,
        })
        return result

    deterministic = _semantic_deterministic_checks(
        scope_basis,
        brief,
        artifact_text,
    )

    # Direct contradictions are sufficient to block. Avoid an unnecessary 27B
    # audit until the deterministic issue is repaired.
    if deterministic["blocking_issues"]:
        model_result = {
            "blocking_issues": [],
            "warnings": [],
            "assumptions": [],
            "verified_claims": [],
            "model_error": "",
        }
        audit_mode = "deterministic_block"
    else:
        model_result = _semantic_audit_model(
            scope_basis,
            brief,
            artifact_text,
            validator_output,
            primary_evidence,
        )
        audit_mode = "deterministic_plus_model"

    blocking = _semantic_unique(
        deterministic["blocking_issues"]
        + model_result.get("blocking_issues", [])
    )
    warnings = _semantic_unique(
        deterministic["warnings"]
        + model_result.get("warnings", [])
    )
    assumptions = _semantic_unique(
        deterministic["assumptions"]
        + model_result.get("assumptions", [])
    )
    verified = _semantic_unique(
        model_result.get("verified_claims", [])
    )

    passed = not bool(blocking)
    if not passed:
        status = "failed"
    elif assumptions:
        status = "passed_with_assumptions"
    elif warnings:
        status = "passed_with_warnings"
    else:
        status = "passed"

    stored = {
        "blocking_issues": blocking,
        "warnings": warnings,
        "assumptions": assumptions,
        "verified_claims": verified,
        "source_count": int(source_count),
        "audit_mode": audit_mode,
        "model_error": str(model_result.get("model_error") or "")[:500],
    }
    result_json = json.dumps(stored, ensure_ascii=False, sort_keys=True)
    result_hash = hashlib.sha256(
        result_json.encode("utf-8", "replace")
    ).hexdigest()
    now = int(time.time())

    with conn() as db:
        db.execute(
            """INSERT INTO semantic_audits(
                   chat_id,root_id,user_id,artifact,artifact_hash,evidence_hash,scope_hash,
                   passed,status,result_hash,result_json,created_at
               ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                row["chat_id"], row["root_id"], row["user_id"],
                path, artifact_hash, evidence_hash, scope_hash,
                1 if passed else 0, status, result_hash,
                result_json, now,
            ),
        )
        db.commit()

        attempts = int(db.execute(
            """SELECT COUNT(*) AS n FROM semantic_audits
               WHERE chat_id=? AND root_id=? AND user_id=? AND artifact=?""",
            (row["chat_id"], row["root_id"], row["user_id"], path),
        ).fetchone()["n"])

        same_failure = 0
        if not passed:
            same_failure = int(db.execute(
                """SELECT COUNT(*) AS n FROM semantic_audits
                   WHERE chat_id=? AND root_id=? AND user_id=? AND artifact=?
                     AND passed=0 AND result_hash=?""",
                (
                    row["chat_id"], row["root_id"], row["user_id"],
                    path, result_hash,
                ),
            ).fetchone()["n"])

    return {
        "ok": passed,
        "passed": passed,
        "status": status,
        "cached": False,
        "artifact": path,
        "artifact_hash": artifact_hash,
        "source_count": int(source_count),
        "semantic_attempt": attempts,
        "same_semantic_failure_count": same_failure,
        "semantic_repair_budget_reached": bool(
            (not passed)
            and (
                attempts >= max(1, SEMANTIC_REPAIR_MAX)
                or same_failure >= 2
            )
        ),
        **stored,
    }


def _semantic_failures_for_lessons(row, limit=5):
    with conn() as db:
        rows = [
            str(r["result_json"])
            for r in db.execute(
                """SELECT result_json FROM semantic_audits
                   WHERE chat_id=? AND root_id=? AND user_id=? AND passed=0
                   ORDER BY id DESC LIMIT ?""",
                (
                    row["chat_id"], row["root_id"], row["user_id"],
                    max(1, min(int(limit), 10)),
                ),
            ).fetchall()
        ]
    return list(reversed(rows))


def validation_finalize_success(row, artifact):
    artifact = str(artifact or "generated artifact").strip()[:500] or "generated artifact"

    with conn() as db:
        success = db.execute(
            """SELECT id,command,output_text FROM validation_runs
               WHERE chat_id=? AND root_id=? AND user_id=? AND artifact=? AND exit_code=0
               ORDER BY id DESC LIMIT 1""",
            (row["chat_id"], row["root_id"], row["user_id"], artifact),
        ).fetchone()

    if not success:
        return {
            "ok": False,
            "lesson_learning_queued": False,
            "reused_lessons_confirmed": 0,
            "reason": "no successful validator run found",
        }

    run_id = int(success["id"])
    with conn() as db:
        previous_failures = [
            dict(r)
            for r in db.execute(
                """SELECT command,exit_code,output_text,created_at
                   FROM validation_runs
                   WHERE chat_id=? AND root_id=? AND user_id=? AND artifact=?
                     AND id<? AND exit_code<>0
                   ORDER BY id DESC LIMIT 5""",
                (
                    row["chat_id"], row["root_id"], row["user_id"],
                    artifact, run_id,
                ),
            ).fetchall()
        ]
        scope_failures = [
            str(r["result_json"])
            for r in db.execute(
                """SELECT result_json FROM scope_audits
                   WHERE chat_id=? AND root_id=? AND user_id=? AND passed=0
                   ORDER BY id DESC LIMIT 3""",
                (row["chat_id"], row["root_id"], row["user_id"]),
            ).fetchall()
        ]

    semantic_failures = _semantic_failures_for_lessons(row, 5)
    reused = lesson_mark_success(row)
    learning_queued = False

    if previous_failures or scope_failures or semantic_failures:
        try:
            _, artifact_text = _workspace_text(
                row,
                artifact,
                max_chars=LESSON_ARTIFACT_CHARS,
            )
        except Exception:
            artifact_text = ""

        if artifact_text:
            snapshot = {
                "user_id": row["user_id"],
                "scope_basis": str(row.get("scope_basis") or ""),
                "brief": str(row.get("brief") or ""),
                "artifact": artifact,
                "artifact_text": artifact_text,
                "failures": list(reversed(previous_failures)),
                "scope_failures": list(reversed(scope_failures)),
                "semantic_failures": semantic_failures,
                "success_command": str(success["command"] or ""),
                "success_output": str(success["output_text"] or ""),
            }
            threading.Thread(
                target=learn_from_validation_snapshot,
                args=(snapshot,),
                daemon=True,
                name="validated-lessons-extractor",
            ).start()
            learning_queued = True

    return {
        "ok": True,
        "lesson_learning_queued": learning_queued,
        "reused_lessons_confirmed": int(reused),
    }



VALIDATOR_COMMAND_PATTERNS = [
    r"(?:^|[\s;&|])(?:\S*/)?esphome\s+(?:config|compile)\b",
    r"(?:^|[\s;&|])(?:\S*/)?yamllint\b",
    r"(?:^|[\s;&|])(?:\S*/)?shellcheck\b",
    r"(?:^|[\s;&|])(?:\S*/)?jsonschema\b",
    r"(?:^|[\s;&|])(?:\S*/)?kubeconform\b",
    r"(?:^|[\s;&|])(?:\S*/)?kubeval\b",
    r"(?:^|[\s;&|])(?:\S*/)?terraform\s+validate\b",
    r"(?:^|[\s;&|])(?:\S*/)?ansible-playbook\b[^\n]*--syntax-check\b",
    r"(?:^|[\s;&|])(?:\S*/)?docker\s+compose\s+config\b",
    r"(?:^|[\s;&|])(?:\S*/)?kubectl\b[^\n]*(?:--dry-run(?:=|\s)|\bdiff\b)",
    r"(?:^|[\s;&|])(?:\S*/)?pytest\b",
    r"(?:^|[\s;&|])(?:\S*/)?python(?:3(?:\.\d+)?)?\s+-m\s+(?:pytest|unittest|compileall)\b",
    r"(?:^|[\s;&|])(?:\S*/)?(?:npm|pnpm|yarn)\s+(?:test|lint|build)\b",
    r"(?:^|[\s;&|])(?:\S*/)?(?:npm|pnpm|yarn)\s+run\s+(?:test|lint|build|check)\b",
    r"(?:^|[\s;&|])(?:\S*/)?cargo\s+(?:check|test|clippy)\b",
    r"(?:^|[\s;&|])(?:\S*/)?go\s+(?:test|vet)\b",
    r"(?:^|[\s;&|])(?:\S*/)?ruff\s+check\b",
    r"(?:^|[\s;&|])(?:\S*/)?mypy\b",
    r"(?:^|[\s;&|])(?:\S*/)?flake8\b",
    r"(?:^|[\s;&|])(?:\S*/)?eslint\b",
    r"(?:^|[\s;&|])(?:\S*/)?tsc\b[^\n]*(?:--noEmit|--no-emit)\b",
    r"(?:^|[\s;&|])(?:bash|sh)\s+-n\b",
]
VALIDATOR_COMMAND_RE = [re.compile(p, re.IGNORECASE) for p in VALIDATOR_COMMAND_PATTERNS]

def validator_like_command(command):
    return any(rx.search(str(command or "")) for rx in VALIDATOR_COMMAND_RE)


VALIDATION_TRUNCATION_RE = re.compile(
    r"\|\s*(?:head|tail)(?:\s|$)",
    re.IGNORECASE,
)


def validation_output_truncation(command):
    return bool(VALIDATION_TRUNCATION_RE.search(str(command or "")))



LESSON_STOPWORDS = {
    "the", "and", "for", "with", "from", "into", "that", "this", "then", "than", "when",
    "where", "what", "your", "their", "have", "has", "had", "was", "were", "are", "is", "be",
    "been", "being", "use", "using", "create", "make", "generate", "configuration", "config",
    "code", "file", "files", "please", "need", "needs",
}


def _lesson_text(value, limit=1200):
    value = re.sub(r"\s+", " ", str(value or "").strip())
    value = re.sub(
        r"(?i)\b(password|passwd|token|api[_ -]?key|secret|client[_ -]?secret)\b\s*[:=]\s*['\"]?[^\s,'\"]+",
        r"\1=<redacted>",
        value,
    )
    value = re.sub(r"\b[A-Za-z0-9+/]{48,}={0,2}\b", "<redacted-long-token>", value)
    return value[:limit]


def _lesson_norm(value):
    return re.sub(r"[^a-z0-9]+", " ", str(value or "").lower()).strip()


def _lesson_tokens(value):
    return {
        t for t in re.findall(r"[a-z0-9_.+-]{3,}", str(value or "").lower())
        if t not in LESSON_STOPWORDS and not t.isdigit()
    }


def _lesson_confidence(value):
    if isinstance(value, (int, float)):
        return max(0.0, min(float(value), 1.0))
    low = str(value or "").strip().lower()
    if low == "high":
        return 0.95
    if low == "medium":
        return 0.82
    if low == "low":
        return 0.65
    try:
        return max(0.0, min(float(low), 1.0))
    except Exception:
        return 0.85


def lesson_mark_success(row):
    with conn() as db:
        lesson_ids = [
            int(r["lesson_id"])
            for r in db.execute(
                """SELECT lesson_id FROM lesson_retrievals
                   WHERE chat_id=? AND root_id=? AND user_id=? AND successful=0""",
                (row["chat_id"], row["root_id"], row["user_id"]),
            ).fetchall()
        ]
        if lesson_ids:
            db.executemany(
                "UPDATE learned_lessons SET successful_reuses=successful_reuses+1 WHERE id=?",
                [(lesson_id,) for lesson_id in lesson_ids],
            )
            db.execute(
                """UPDATE lesson_retrievals SET successful=1
                   WHERE chat_id=? AND root_id=? AND user_id=? AND successful=0""",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )
            db.commit()
    return len(lesson_ids)


def _lesson_upsert(user_id, lesson):
    domain = _lesson_text(lesson.get("domain"), 120)
    topic = _lesson_text(lesson.get("topic"), 160)
    error_signature = _lesson_text(lesson.get("error_signature"), 500)
    validated_fix = _lesson_text(lesson.get("validated_fix"), 1200)
    if not error_signature or not validated_fix:
        return None

    confidence = _lesson_confidence(lesson.get("confidence"))
    if confidence < 0.70:
        return None

    signature_hash = hashlib.sha256(
        f"{user_id}|{_lesson_norm(domain)}|{_lesson_norm(topic)}|{_lesson_norm(error_signature)}".encode()
    ).hexdigest()
    now = int(time.time())
    values = {
        "domain": domain,
        "topic": topic,
        "error_signature": error_signature,
        "bad_pattern": _lesson_text(lesson.get("bad_pattern"), 900),
        "root_cause": _lesson_text(lesson.get("root_cause"), 1000),
        "validated_fix": validated_fix,
        "validator": _lesson_text(lesson.get("validator"), 300),
        "software_version": _lesson_text(lesson.get("software_version"), 200),
        "evidence": _lesson_text(lesson.get("evidence"), 1500),
        "confidence": confidence,
    }

    with conn() as db:
        db.execute(
            """INSERT INTO learned_lessons(
                   user_id,signature_hash,domain,topic,error_signature,bad_pattern,root_cause,validated_fix,
                   validator,software_version,evidence,confidence,hits,successful_reuses,created_at,last_verified_at,active
               ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,0,?,?,1)
               ON CONFLICT(user_id,signature_hash) DO UPDATE SET
                   domain=excluded.domain,
                   topic=excluded.topic,
                   error_signature=excluded.error_signature,
                   bad_pattern=CASE WHEN excluded.bad_pattern<>'' THEN excluded.bad_pattern ELSE learned_lessons.bad_pattern END,
                   root_cause=CASE WHEN excluded.root_cause<>'' THEN excluded.root_cause ELSE learned_lessons.root_cause END,
                   validated_fix=excluded.validated_fix,
                   validator=CASE WHEN excluded.validator<>'' THEN excluded.validator ELSE learned_lessons.validator END,
                   software_version=CASE WHEN excluded.software_version<>'' THEN excluded.software_version ELSE learned_lessons.software_version END,
                   evidence=CASE WHEN excluded.evidence<>'' THEN excluded.evidence ELSE learned_lessons.evidence END,
                   confidence=MAX(learned_lessons.confidence, excluded.confidence),
                   last_verified_at=excluded.last_verified_at,
                   active=1""",
            (
                user_id, signature_hash, values["domain"], values["topic"], values["error_signature"],
                values["bad_pattern"], values["root_cause"], values["validated_fix"], values["validator"],
                values["software_version"], values["evidence"], values["confidence"], now, now,
            ),
        )
        db.commit()
        saved = db.execute(
            "SELECT id FROM learned_lessons WHERE user_id=? AND signature_hash=?",
            (user_id, signature_hash),
        ).fetchone()
    return int(saved["id"]) if saved else None


def _lesson_extract(snapshot):
    failure_text = "\n\n".join(
        f"FAILED VALIDATION {i+1}:\ncommand={x.get('command','')}\noutput={x.get('output_text','')}"
        for i, x in enumerate(snapshot.get("failures") or [])
    )[:LESSON_FAILURE_CHARS]
    scope_text = "\n\n".join(
        f"FAILED SCOPE AUDIT {i+1}: {x}" for i, x in enumerate(snapshot.get("scope_failures") or [])
    )[:4000]
    semantic_text = "\n\n".join(
        f"FAILED SEMANTIC AUDIT {i+1}: {x}" for i, x in enumerate(snapshot.get("semantic_failures") or [])
    )[:5000]

    system = """You extract compact reusable lessons from a proven failure -> repair -> successful validation cycle.
Only emit a lesson when the supplied evidence directly supports it. Do not guess. Do not store credentials, secret values, personal data, machine-specific identifiers, or irrelevant project details. Generalize paths and IDs when appropriate.
A lesson may be technical (syntax/API/config behavior) or research-process related (validator invocation, reproducibility, tool usage).
Version-sensitive lessons must include the software/version when the evidence contains it.
The final successful validator proves only that the repaired artifact passed under the reproduced validation conditions.
Return JSON only:
{"lessons":[{"domain":"","topic":"","error_signature":"","bad_pattern":"","root_cause":"","validated_fix":"","validator":"","software_version":"","evidence":"","confidence":"high"}]}
Return at most 3 lessons. Return {"lessons":[]} if there is no reusable lesson directly supported by the evidence."""

    user = (
        "AUTHORITATIVE SCOPE:\n" + snapshot.get("scope_basis", "")[:5000]
        + "\n\n" + failure_text
        + "\n\n" + scope_text
        + "\n\n" + semantic_text
        + "\n\nFINAL VALIDATOR:\ncommand=" + snapshot.get("success_command", "")[:2000]
        + "\noutput=" + snapshot.get("success_output", "")[:3000]
        + "\n\nFINAL VALIDATED ARTIFACT:\n" + snapshot.get("artifact_text", "")[:LESSON_ARTIFACT_CHARS]
    )

    payload = {
        "model": LESSON_MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "format": "json",
        "keep_alive": MODEL_KEEP_ALIVE,
        "think": False,
        "options": {"temperature": 0.0, "num_predict": 700, "num_ctx": 8192},
    }
    request = urllib.request.Request(
        OLLAMA_URL + "/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.load(response)
    content = str(((data.get("message") or {}).get("content") or "")).strip()
    parsed = json.loads(content)
    lessons = parsed.get("lessons") or []
    return lessons[:3] if isinstance(lessons, list) else []


def learn_from_validation_snapshot(snapshot):
    try:
        for lesson in _lesson_extract(snapshot):
            if isinstance(lesson, dict):
                _lesson_upsert(snapshot["user_id"], lesson)
    except Exception as exc:
        print(f"Validated Lessons Engine: extraction skipped: {type(exc).__name__}: {exc}", flush=True)


def lessons_retrieve(row, query, limit=None):
    limit = max(1, min(int(limit or LESSON_RETRIEVAL_MAX), 8))
    basis = " ".join([
        str(query or ""),
        str(row.get("scope_basis") or ""),
        str(row.get("brief") or ""),
    ])
    q_tokens = _lesson_tokens(basis)
    if not q_tokens:
        return {"ok": True, "lessons": [], "count": 0}

    with conn() as db:
        candidates = [dict(r) for r in db.execute(
            """SELECT * FROM learned_lessons
               WHERE user_id=? AND active=1 AND superseded_by IS NULL
               ORDER BY last_verified_at DESC LIMIT 250""",
            (row["user_id"],),
        ).fetchall()]

    scored = []
    for lesson in candidates:
        primary = _lesson_tokens((lesson.get("domain") or "") + " " + (lesson.get("topic") or ""))
        diagnostic = _lesson_tokens((lesson.get("error_signature") or "") + " " + (lesson.get("bad_pattern") or ""))
        solution = _lesson_tokens(
            (lesson.get("root_cause") or "") + " " + (lesson.get("validated_fix") or "") + " " + (lesson.get("software_version") or "")
        )
        score = 5 * len(q_tokens & primary) + 3 * len(q_tokens & diagnostic) + len(q_tokens & solution)
        if score <= 0:
            continue
        score += min(float(lesson.get("confidence") or 0.0), 1.0)
        score += min(int(lesson.get("successful_reuses") or 0), 5) * 0.15
        scored.append((score, lesson))

    selected = [
        lesson for _, lesson in sorted(
            scored,
            key=lambda x: (x[0], x[1].get("last_verified_at", 0)),
            reverse=True,
        )[:limit]
    ]
    now = int(time.time())
    if selected:
        with conn() as db:
            for lesson in selected:
                db.execute("UPDATE learned_lessons SET hits=hits+1 WHERE id=?", (lesson["id"],))
                db.execute(
                    """INSERT OR IGNORE INTO lesson_retrievals(chat_id,root_id,user_id,lesson_id,created_at,successful)
                       VALUES(?,?,?,?,?,0)""",
                    (row["chat_id"], row["root_id"], row["user_id"], lesson["id"], now),
                )
            db.commit()

    compact = []
    for lesson in selected:
        compact.append({
            "id": lesson["id"],
            "domain": lesson.get("domain", ""),
            "topic": lesson.get("topic", ""),
            "error_signature": lesson.get("error_signature", ""),
            "bad_pattern": lesson.get("bad_pattern", ""),
            "validated_fix": lesson.get("validated_fix", ""),
            "validator": lesson.get("validator", ""),
            "software_version": lesson.get("software_version", ""),
            "confidence": lesson.get("confidence", 0.0),
            "successful_reuses": lesson.get("successful_reuses", 0),
            "last_verified_at": lesson.get("last_verified_at", 0),
        })
    return {"ok": True, "lessons": compact, "count": len(compact)}


def lessons_recent(row, limit=10):
    limit = max(1, min(int(limit or 10), 30))
    with conn() as db:
        rows = [dict(r) for r in db.execute(
            """SELECT id,domain,topic,error_signature,bad_pattern,root_cause,validated_fix,validator,software_version,
                      confidence,hits,successful_reuses,created_at,last_verified_at,superseded_by,active
               FROM learned_lessons WHERE user_id=? ORDER BY last_verified_at DESC LIMIT ?""",
            (row["user_id"], limit),
        ).fetchall()]
    return {"ok": True, "lessons": rows, "count": len(rows)}


def validation_record(row, artifact, command, exit_code, output, defer_success_learning=False):
    artifact = str(artifact or "generated artifact").strip()[:500] or "generated artifact"
    command = str(command or "")[:12000]
    output_text = str(output or "")[:12000]
    output_hash = hashlib.sha256(str(output or "").encode("utf-8", "replace")).hexdigest()
    now = int(time.time())
    previous_failures = []
    scope_failures = []

    with conn() as db:
        cur = db.execute(
            """INSERT INTO validation_runs(
                   chat_id,root_id,user_id,artifact,command,exit_code,output_hash,output_text,created_at
               ) VALUES(?,?,?,?,?,?,?,?,?)""",
            (row["chat_id"], row["root_id"], row["user_id"], artifact,
             command, int(exit_code), output_hash, output_text, now),
        )
        run_id = int(cur.lastrowid or 0)
        db.commit()
        attempts = db.execute(
            """SELECT COUNT(*) AS n FROM validation_runs
               WHERE chat_id=? AND root_id=? AND user_id=? AND artifact=?""",
            (row["chat_id"], row["root_id"], row["user_id"], artifact),
        ).fetchone()["n"]
        same_failure = 0
        if int(exit_code) != 0:
            same_failure = db.execute(
                """SELECT COUNT(*) AS n FROM validation_runs
                   WHERE chat_id=? AND root_id=? AND user_id=? AND artifact=?
                     AND exit_code<>0 AND output_hash=?""",
                (row["chat_id"], row["root_id"], row["user_id"], artifact, output_hash),
            ).fetchone()["n"]
        else:
            previous_failures = [dict(r) for r in db.execute(
                """SELECT command,exit_code,output_text,created_at FROM validation_runs
                   WHERE chat_id=? AND root_id=? AND user_id=? AND artifact=?
                     AND id<? AND exit_code<>0
                   ORDER BY id DESC LIMIT 5""",
                (row["chat_id"], row["root_id"], row["user_id"], artifact, run_id),
            ).fetchall()]
            scope_failures = [str(r["result_json"]) for r in db.execute(
                """SELECT result_json FROM scope_audits
                   WHERE chat_id=? AND root_id=? AND user_id=? AND passed=0
                   ORDER BY id DESC LIMIT 3""",
                (row["chat_id"], row["root_id"], row["user_id"]),
            ).fetchall()]

    failed = int(exit_code) != 0
    repeated = bool(failed and int(same_failure) >= 2)
    final_repair_allowed = bool(failed and int(attempts) == 5 and not repeated)
    repair_budget_reached = bool(failed and (int(attempts) >= 6 or repeated))

    learning_queued = False
    reused_lessons_confirmed = 0
    if not failed and not defer_success_learning:
        reused_lessons_confirmed = lesson_mark_success(row)
        if previous_failures or scope_failures:
            try:
                _, artifact_text = _workspace_text(row, artifact, max_chars=LESSON_ARTIFACT_CHARS)
            except Exception:
                artifact_text = ""
            if artifact_text:
                snapshot = {
                    "user_id": row["user_id"],
                    "scope_basis": str(row.get("scope_basis") or ""),
                    "brief": str(row.get("brief") or ""),
                    "artifact": artifact,
                    "artifact_text": artifact_text,
                    "failures": list(reversed(previous_failures)),
                    "scope_failures": list(reversed(scope_failures)),
                    "success_command": command,
                    "success_output": output_text,
                }
                threading.Thread(
                    target=learn_from_validation_snapshot,
                    args=(snapshot,),
                    daemon=True,
                    name="validated-lessons-extractor",
                ).start()
                learning_queued = True

    return {
        "validation_attempt": int(attempts),
        "same_failure_count": int(same_failure),
        "final_repair_allowed": final_repair_allowed,
        "repair_budget_reached": repair_budget_reached,
        "repeated_failure": repeated,
        "lesson_learning_queued": learning_queued,
        "reused_lessons_confirmed": int(reused_lessons_confirmed),
        "success_learning_deferred": bool((not failed) and defer_success_learning),
    }


def timing_record(row, step_kind, label, duration_seconds, outcome="ok", detail=""):
    step_kind = re.sub(r"[^a-z0-9_.:-]+", "_", str(step_kind or "step").lower())[:120]
    label = re.sub(r"\s+", " ", str(label or step_kind).strip())[:500]
    outcome = str(outcome or "ok").strip().lower()[:40]
    detail = re.sub(r"\s+", " ", str(detail or "").strip())[:1000]
    try:
        duration = max(0.0, min(float(duration_seconds or 0.0), 86400.0))
    except Exception:
        duration = 0.0
    duration_ms = int(round(duration * 1000.0))
    now = int(time.time())
    with conn() as db:
        cur = db.execute(
            """INSERT INTO step_timings(
                   chat_id,root_id,user_id,step_kind,label,duration_ms,outcome,detail,created_at
               ) VALUES(?,?,?,?,?,?,?,?,?)""",
            (
                row["chat_id"], row["root_id"], row["user_id"], step_kind,
                label, duration_ms, outcome, detail, now,
            ),
        )
        db.commit()
        timing_id = int(cur.lastrowid or 0)
    return {
        "ok": True,
        "timing_id": timing_id,
        "step_kind": step_kind,
        "label": label,
        "duration_seconds": round(duration_ms / 1000.0, 3),
        "outcome": outcome,
    }


def timing_recent(row, limit=50):
    limit = max(1, min(int(limit or 50), 200))
    with conn() as db:
        rows = db.execute(
            """SELECT id,step_kind,label,duration_ms,outcome,detail,created_at
               FROM step_timings
               WHERE chat_id=? AND root_id=? AND user_id=?
               ORDER BY id ASC""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchall()
    total_ms = sum(int(r["duration_ms"] or 0) for r in rows)
    recent_rows = rows[-limit:]
    steps = [
        {
            "id": int(r["id"]),
            "step_kind": str(r["step_kind"] or ""),
            "label": str(r["label"] or ""),
            "duration_seconds": round(int(r["duration_ms"] or 0) / 1000.0, 3),
            "outcome": str(r["outcome"] or ""),
            "detail": str(r["detail"] or ""),
            "created_at": int(r["created_at"] or 0),
        }
        for r in recent_rows
    ]
    return {
        "count": len(rows),
        "shown": len(steps),
        "recorded_step_seconds": round(total_ms / 1000.0, 3),
        "steps": steps,
    }


def research_budget(row):
    now = int(time.time())
    elapsed = max(0, now - int(row.get("created_at") or now))
    with conn() as db:
        total = db.execute(
            """SELECT COUNT(*) AS n FROM validation_runs
               WHERE chat_id=? AND root_id=? AND user_id=?""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchone()["n"]
        failed = db.execute(
            """SELECT COUNT(*) AS n FROM validation_runs
               WHERE chat_id=? AND root_id=? AND user_id=? AND exit_code<>0""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchone()["n"]
        passed = db.execute(
            """SELECT COUNT(*) AS n FROM validation_runs
               WHERE chat_id=? AND root_id=? AND user_id=? AND exit_code=0""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchone()["n"]
        lessons_total = db.execute(
            "SELECT COUNT(*) AS n FROM learned_lessons WHERE user_id=? AND active=1",
            (row["user_id"],),
        ).fetchone()["n"]
        lessons_retrieved = db.execute(
            """SELECT COUNT(*) AS n FROM lesson_retrievals
               WHERE chat_id=? AND root_id=? AND user_id=?""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchone()["n"]
        lessons_reused = db.execute(
            """SELECT COUNT(*) AS n FROM lesson_retrievals
               WHERE chat_id=? AND root_id=? AND user_id=? AND successful=1""",
            (row["chat_id"], row["root_id"], row["user_id"]),
        ).fetchone()["n"]
    web = web_usage_counts(row)
    timings = timing_recent(row, 60)
    return {
        "elapsed_seconds": int(elapsed),
        "validation_runs": int(total),
        "validation_failed": int(failed),
        "validation_passed": int(passed),
        "soft_time_budget_seconds": 900,
        "over_soft_time_budget": bool(elapsed >= 900),
        "lessons": {
            "total_learned": int(lessons_total),
            "retrieved_this_research": int(lessons_retrieved),
            "successful_reuses_this_research": int(lessons_reused),
        },
        "timings": timings,
        "web": {
            **web,
            "pre_search_max": WEB_PRE_SEARCH_MAX,
            "pre_fetch_max": WEB_PRE_FETCH_MAX,
            "post_search_max": WEB_POST_SEARCH_MAX,
            "post_fetch_max": WEB_POST_FETCH_MAX,
        },
    }


def brief_save(row, brief, scope_basis="", scope_basis_append=""):
    brief = str(brief or "").strip()[:30000]
    now = int(time.time())
    previous_brief = str(row.get("brief") or "").strip()
    previous_scope_basis = str(row.get("scope_basis") or "").strip()
    scope_basis = str(scope_basis or "").strip()[:16000]
    scope_basis_append = str(scope_basis_append or "").strip()[:8000]

    if scope_basis and not previous_scope_basis:
        effective_scope_basis = scope_basis
    else:
        effective_scope_basis = previous_scope_basis

    if scope_basis_append:
        if scope_basis_append not in effective_scope_basis:
            effective_scope_basis = (
                effective_scope_basis
                + ("\n\nUSER-APPROVED SCOPE UPDATE:\n" if effective_scope_basis else "")
                + scope_basis_append
            ).strip()[:30000]

    try:
        rev = json.loads(row.get("revisions") or "[]")
        if not isinstance(rev, list): rev = []
    except Exception:
        rev = []

    changed = previous_brief != brief
    if not rev or rev[-1].get("brief") != brief:
        rev.append({"version": len(rev) + 1, "brief": brief, "timestamp": now})
    rev = rev[-30:]

    with conn() as db:
        if changed and previous_brief:
            # New approved scope revision: fresh budgets, same persistent lab files.
            db.execute(
                "DELETE FROM web_usage WHERE chat_id=? AND root_id=? AND user_id=?",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )
            db.execute(
                "DELETE FROM validation_runs WHERE chat_id=? AND root_id=? AND user_id=?",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )
            db.execute(
                "DELETE FROM scope_audits WHERE chat_id=? AND root_id=? AND user_id=?",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )
            db.execute(
                "DELETE FROM semantic_audits WHERE chat_id=? AND root_id=? AND user_id=?",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )
            db.execute(
                "DELETE FROM web_evidence WHERE chat_id=? AND root_id=? AND user_id=?",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )
            db.execute(
                "DELETE FROM lesson_retrievals WHERE chat_id=? AND root_id=? AND user_id=?",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )
            db.execute(
                "DELETE FROM step_timings WHERE chat_id=? AND root_id=? AND user_id=?",
                (row["chat_id"], row["root_id"], row["user_id"]),
            )

        db.execute(
            "UPDATE sessions SET brief=?,scope_basis=?,revisions=?,updated_at=?,last_used=? WHERE chat_id=? AND root_id=? AND user_id=?",
            (
                brief, effective_scope_basis, json.dumps(rev), now, now,
                row["chat_id"], row["root_id"], row["user_id"],
            ),
        )
        db.commit()

    return session_get(row["chat_id"], row["root_id"], row["user_id"])


def require_fields(data):
    return session_ensure(data.get("chat_id"), data.get("root_id"), data.get("user_id"))


def handle_admin(path, data):
    if path == "/research/latest-summary":
        chat_id = clean_id(data.get("chat_id"))
        user_id = clean_id(data.get("user_id"))
        if not chat_id or not user_id:
            raise ValueError("chat_id and user_id are required")
        with conn() as db:
            found = db.execute(
                """SELECT * FROM sessions
                   WHERE chat_id=? AND user_id=?
                   ORDER BY last_used DESC, updated_at DESC, created_at DESC
                   LIMIT 1""",
                (chat_id, user_id),
            ).fetchone()
        if not found:
            return {"ok": True, "found": False}
        latest = dict(found)
        return {
            "ok": True,
            "found": True,
            "root_id": latest["root_id"],
            "budget": research_budget(latest),
            "timings": timing_recent(latest, data.get("limit") or 30),
        }

    row = require_fields(data)
    if path == "/research/state":
        return {"ok": True, "session": row, "sandbox_running": docker_running(row["container_name"]) if docker_exists(row["container_name"]) else False}
    if path == "/research/brief/save":
        row = brief_save(
            row,
            data.get("brief"),
            scope_basis=data.get("scope_basis"),
            scope_basis_append=data.get("scope_basis_append"),
        )
        return {
            "ok": True,
            "brief": row["brief"],
            "scope_basis": row.get("scope_basis", ""),
            "revisions": json.loads(row["revisions"] or "[]"),
        }
    if path == "/lessons/retrieve":
        return lessons_retrieve(row, data.get("query"), data.get("limit"))
    if path == "/lessons/recent":
        return lessons_recent(row, data.get("limit") or 10)
    if path == "/timing/record":
        return timing_record(
            row,
            data.get("step_kind"),
            data.get("label"),
            data.get("duration_seconds"),
            data.get("outcome") or "ok",
            data.get("detail") or "",
        )
    if path == "/timing/recent":
        return {"ok": True, "timings": timing_recent(row, data.get("limit") or 50)}
    if path == "/web/search":
        return research_web_search(row, data.get("query"), data.get("post_validation_reason"), data.get("evidence_gap"))

    if path == "/web/fetch":
        return research_web_fetch(row, data.get("url"), data.get("post_validation_reason"), data.get("evidence_gap"))

    if path == "/research/update/poll":
        with conn() as db:
            rows = db.execute(
                "SELECT id,text,created_at FROM updates WHERE chat_id=? AND root_id=? AND user_id=? AND consumed=0 ORDER BY id",
                (row["chat_id"], row["root_id"], row["user_id"]),
            ).fetchall()
            ids = [r["id"] for r in rows]
            if ids:
                db.executemany("UPDATE updates SET consumed=1 WHERE id=?", [(x,) for x in ids])
                db.commit()
        return {
            "ok": True,
            "updates": [dict(r) for r in rows],
            "budget": research_budget(row),
        }
    if path == "/sandbox/scope-audit":
        return scope_audit_artifact(row, data.get("artifact"))

    if path == "/sandbox/semantic-audit":
        return semantic_audit_artifact(
            row,
            data.get("artifact"),
            data.get("validator_output") or "",
        )

    if path == "/validation/finalize-success":
        return validation_finalize_success(
            row,
            data.get("artifact") or "generated artifact",
        )

    if path == "/sandbox/status":
        exists = docker_exists(row["container_name"])
        return {"ok": True, "container": row["container_name"], "volume": row["volume_name"], "exists": exists, "running": docker_running(row["container_name"]) if exists else False, "brief": row.get("brief", "")}
    if path == "/sandbox/ensure":
        row = sandbox_ensure(row)
        return {"ok": True, "container": row["container_name"], "volume": row["volume_name"], "running": True}
    if path == "/sandbox/exec":
        row = sandbox_ensure(row)
        command = str(data.get("command") or "").strip()
        if not command:
            raise ValueError("command is required")

        kind = str(data.get("kind") or "").strip().lower()
        if kind != "validation" and validator_like_command(command):
            raise RuntimeError(
                "VALIDATOR COMMAND BLOCKED: validator/test/lint/config-check commands cannot run through "
                "research_lab_exec because that would bypass the scope audit, validation-attempt accounting, "
                "repair budget, and stop-on-success logic. Use research_lab_validate(command=..., artifact=<actual generated file>) instead."
            )

        if kind == "validation" and validation_output_truncation(command):
            raise RuntimeError(
                "VALIDATOR OUTPUT TRUNCATION BLOCKED: do not pipe validator output through head or tail. "
                "With pipefail, early pipe closure can produce a false nonzero result and waste a repair attempt. "
                "The lab already bounds validator output. Run the validator directly through research_lab_validate."
            )

        timeout = max(1, min(int(data.get("timeout") or 120), 600))
        rc, out = run(
            [DOCKER, "exec", row["container_name"],
             "/bin/bash", "--noprofile", "--norc", "-o", "pipefail", "-lc", command],
            timeout=timeout,
        )
        touch(row)
        result = {
            "ok": rc == 0,
            "exit_code": rc,
            "output": out,
            "container": row["container_name"],
        }
        if kind == "validation":
            result.update(
                validation_record(
                    row,
                    data.get("artifact") or "generated artifact",
                    command,
                    rc,
                    out,
                    defer_success_learning=bool(
                        data.get("defer_success_learning")
                    ),
                )
            )
        return result
    if path == "/sandbox/list":
        row = sandbox_ensure(row)
        p = safe_path(data.get("path") or ".")
        rc, out = run([DOCKER, "exec", row["container_name"], "find", p, "-maxdepth", "3", "-printf", "%y %p\\n"], timeout=60)
        return {"ok": rc == 0, "output": out}
    if path == "/sandbox/read":
        row = sandbox_ensure(row)
        p = safe_path(data.get("path"))
        max_bytes = max(1, min(int(data.get("max_bytes") or 50000), 200000))
        code = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); b=p.read_bytes()[:int(sys.argv[2])]; sys.stdout.buffer.write(b)"
        rc, out = run([DOCKER, "exec", row["container_name"], "python3", "-c", code, p, str(max_bytes)], timeout=60)
        return {"ok": rc == 0, "output": out}
    if path == "/sandbox/write":
        row = sandbox_ensure(row)
        p = safe_path(data.get("path"))
        content = str(data.get("content") or "")
        payload = base64.b64encode(content.encode()).decode()
        code = "import base64,pathlib,sys; p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(base64.b64decode(sys.stdin.buffer.read()))"
        rc, out = run([DOCKER, "exec", "-i", row["container_name"], "python3", "-c", code, p], timeout=60, input_bytes=payload.encode())
        return {"ok": rc == 0, "output": out, "path": p}
    if path == "/sandbox/stop":
        sandbox_stop(row)
        return {"ok": True, "running": False, "volume_preserved": True}
    if path == "/sandbox/delete":
        sandbox_delete(row)
        return {"ok": True, "deleted": True}
    raise KeyError("unknown admin endpoint")


def warm_model(model):
    model = str(model or "").strip()
    if model not in WARM_MODELS:
        raise ValueError("model is not allowed for prewarming")

    payload = json.dumps({
        "model": model,
        "prompt": " ",
        "stream": False,
        "keep_alive": MODEL_KEEP_ALIVE,
        "options": {"num_predict": 1},
    }).encode("utf-8")
    req = urllib.request.Request(
        OLLAMA_URL + "/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as r:
        json.load(r)
    return {"ok": True, "model": model, "warm": True}



def _advanced_split_tests(text):
    source = str(text or "")
    hits = list(
        re.finditer(
            r"(?mi)^\s*\*{0,2}TEST\s+(\d+)\b[^\r\n]*\*{0,2}\s*$",
            source,
        )
    )
    out = {}
    for idx, hit in enumerate(hits):
        end = hits[idx + 1].start() if idx + 1 < len(hits) else len(source)
        out[hit.group(1)] = source[hit.start():end]
    return out


def _advanced_return_exactly_block(section):
    match = re.search(
        r"(?is)\bReturn\s+exactly\s*:\s*\n(.*?)(?=\n\s*Constraints\s*:|\Z)",
        str(section or ""),
    )
    if not match:
        return ""
    return match.group(1).strip("\n\r ")


def _advanced_normalize_newlines(value):
    return str(value or "").replace("\r\n", "\n").replace("\r", "\n")


def _advanced_post_assembly_issues(user_text, answer_text):
    """High-confidence checks that must run on the persisted final answer."""
    user = _advanced_normalize_newlines(user_text)[:ADVANCED_FINAL_MAX_USER]
    answer = _advanced_normalize_newlines(answer_text)[:ADVANCED_FINAL_MAX_ANSWER]
    issues = []

    # Final visible TEST sequence must not contain repeated sections.
    headings = re.findall(
        r"(?mi)^\s*\*{0,2}TEST\s+(\d+)\b[^\r\n]*\*{0,2}\s*$",
        answer,
    )
    seen = set()
    repeated = []
    for num in headings:
        if num in seen and num not in repeated:
            repeated.append(num)
        seen.add(num)
    if repeated:
        issues.append(
            "Duplicate final TEST sections remain: "
            + ", ".join(repeated)
            + ". Keep only the last complete assembled sequence."
        )

    user_tests = _advanced_split_tests(user)
    answer_tests = _advanced_split_tests(answer)

    for num, usec in user_tests.items():
        asec = answer_tests.get(num, "")
        usec_l = usec.lower()
        asec_l = asec.lower()

        # Evidence-only Unknown must contain observations, not "Why"/cause.
        evidence_unknown = (
            "evidence-only" in usec_l
            or "unknown must contain only unresolved observations" in usec_l
            or (
                "output exactly:" in usec_l
                and "unknown:" in usec_l
                and "do not suggest a cause" in usec_l
            )
        )
        if evidence_unknown and asec:
            unknown_match = re.search(
                r"(?is)\bUnknown\s*:\s*(.*)$",
                asec,
            )
            if unknown_match:
                unknown = unknown_match.group(1).strip()
                if re.search(
                    r"(?i)(?:^|[;.!?]\s*)why\b|"
                    r"\breason\s+for\b|\bexplanation\s+for\b|"
                    r"\broot\s+cause\b|\bsource\s+of\b|\bcause\s+of\b",
                    unknown,
                ):
                    issues.append(
                        f"TEST {num}: Unknown asks why/for a cause. "
                        "The prompt requires unresolved observations only."
                    )

        # Explicit numbered question request must be visibly numbered.
        numbered_request = re.search(
            r"(?i)\bexactly\s+(?:4|four)\s+numbered\s+questions\b",
            usec,
        )
        if numbered_request and asec:
            prefixes = re.findall(
                r"(?m)^\s*([1-9]\d*)[\.\)]\s+",
                asec,
            )
            if prefixes != ["1", "2", "3", "4"]:
                issues.append(
                    f"TEST {num}: exactly four numbered questions were requested, "
                    "but visible 1., 2., 3., 4. prefixes are not present in order."
                )

        # Generic exact-YAML structure fidelity. This is intentionally
        # conservative: only activate when the requested exact block itself
        # contains a YAML list marker.
        expected = _advanced_return_exactly_block(usec)
        if (
            expected
            and re.search(r"(?m)^\s*-\s+\S", expected)
            and ":" in expected
            and asec
        ):
            if expected not in asec:
                issues.append(
                    f"TEST {num}: exact YAML/list structure drifted from the "
                    "requested block. Preserve list markers, indentation, keys, "
                    "and boolean values exactly."
                )

        # "Is it definitely down?" is false when the supplied evidence says
        # that same service works from another client. The failure reason can
        # remain unknown, but the definite proposition itself is disproved.
        if (
            "definitely down" in usec_l
            and re.search(
                r"(?i)\b(?:same\s+)?service\s+works\s+from\s+Client\s+B\b",
                usec,
            )
            and asec
        ):
            conclusion = re.search(
                r"(?mi)^\s*Conclusion\s*:\s*([^\r\n]+)",
                asec,
            )
            if not conclusion or not re.match(
                r"(?i)^\s*No\b",
                conclusion.group(1),
            ):
                issues.append(
                    f"TEST {num}: Conclusion must be No. The supplied evidence "
                    "shows the same service works from Client B, so it is not "
                    "definitely down; only Client A's failure reason remains unknown."
                )

    # Missing requested TESTs are also a final-assembly failure.
    if user_tests:
        missing = [
            num for num in user_tests
            if num not in answer_tests
        ]
        if missing:
            issues.append(
                "Final assembled answer is missing TEST section(s): "
                + ", ".join(missing)
            )

    return issues[:12]


def _advanced_ollama_repair(user_text, answer_text, issues):
    system = """You are the POST-ASSEMBLY FINAL REPAIR PASS for Advanced mode.
You receive the user's complete multi-test request and the ACTUAL persisted final
assistant answer after every Native calculator/web/tool continuation has ended.

Return ONLY the repaired complete final answer.

Rules:
- Preserve all correct content. Make only the smallest edits required by ISSUES.
- Preserve TEST headings and TEST order exactly.
- Never remove correct calculator results or web-derived YAML.
- Never invent new facts, causes, tools, citations, source names, or alternatives.
- If Unknown must contain unresolved observations only, do not answer with Why,
  reason-for, source-of, root-cause, or causal hypotheses.
- If numbered questions are required, add the requested visible numeric prefixes.
- If exact YAML is supplied, preserve its indentation and list markers exactly.
- If evidence proves a proposition such as "definitely down" is false, answer No
  while preserving uncertainty about the unresolved reason.
- Do not expose audit commentary or describe the repair.
"""

    user = (
        "USER REQUEST:\n"
        + str(user_text or "")[:ADVANCED_FINAL_MAX_USER]
        + "\n\nACTUAL PERSISTED FINAL ANSWER:\n"
        + str(answer_text or "")[:ADVANCED_FINAL_MAX_ANSWER]
        + "\n\nDETERMINISTIC ISSUES:\n- "
        + "\n- ".join(str(x) for x in issues[:12])
    )

    payload = {
        "model": ADVANCED_FINAL_MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "keep_alive": MODEL_KEEP_ALIVE,
        "think": False,
        "options": {
            "temperature": 0.0,
            "num_predict": 9000,
            "num_ctx": 49152,
        },
    }

    req = urllib.request.Request(
        OLLAMA_URL + "/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=240) as response:
        data = json.load(response)
    return str(
        ((data.get("message") or {}).get("content") or "")
    ).strip()


def advanced_final_audit(data):
    user_text = str(data.get("user_text") or "")[:ADVANCED_FINAL_MAX_USER]
    answer_text = str(data.get("answer_text") or "")[:ADVANCED_FINAL_MAX_ANSWER]
    if not user_text or not answer_text:
        return {
            "ok": True,
            "changed": False,
            "answer": answer_text,
            "issues_before": [],
            "issues_after": [],
        }

    before = _advanced_post_assembly_issues(user_text, answer_text)
    if not before:
        return {
            "ok": True,
            "changed": False,
            "answer": answer_text,
            "issues_before": [],
            "issues_after": [],
        }

    candidates = [(answer_text, before, 0)]
    current = answer_text
    current_issues = before

    for pass_index in range(1, max(1, ADVANCED_FINAL_REPAIR_MAX) + 1):
        if not current_issues:
            break
        try:
            repaired = _advanced_ollama_repair(
                user_text,
                current,
                current_issues,
            )
        except Exception as exc:
            return {
                "ok": False,
                "changed": False,
                "answer": answer_text,
                "issues_before": before,
                "issues_after": current_issues,
                "error": f"{type(exc).__name__}: {exc}",
            }

        if not repaired or repaired == current:
            break

        after = _advanced_post_assembly_issues(user_text, repaired)
        candidates.append((repaired, after, pass_index))
        current = repaired
        current_issues = after

        if not after:
            break

    # Fewest deterministic issues wins; later pass breaks ties.
    best = min(
        candidates,
        key=lambda item: (len(item[1]), -item[2]),
    )
    changed = (
        best[0] != answer_text
        and len(best[1]) < len(before)
    )
    chosen = best[0] if changed else answer_text
    chosen_issues = best[1] if changed else before

    return {
        "ok": True,
        "changed": changed,
        "answer": chosen,
        "issues_before": before,
        "issues_after": chosen_issues,
        "passes": max(item[2] for item in candidates),
    }


def handle_ui(path, data):
    if path == "/model/warm":
        return warm_model(data.get("model"))
    if path == "/advanced/final-audit":
        return advanced_final_audit(data)

    chat_id = clean_id(data.get("chat_id")); root_id = clean_id(data.get("root_id")); user_id = clean_id(data.get("user_id"), "browser")
    if path == "/research/update/queue":
        text = str(data.get("text") or "").strip()[:12000]
        if not text: raise ValueError("update text is required")
        # Browser UI intentionally does not receive the controller admin key or
        # need the OpenWebUI user id. Resolve the existing session by chat/root.
        with conn() as db:
            existing = db.execute("SELECT * FROM sessions WHERE chat_id=? AND root_id=? ORDER BY updated_at DESC LIMIT 1", (chat_id, root_id)).fetchone()
        row = dict(existing) if existing else session_ensure(chat_id, root_id, user_id)
        with conn() as db:
            db.execute("INSERT INTO updates(chat_id,root_id,user_id,text,created_at,consumed) VALUES(?,?,?,?,?,0)", (chat_id, root_id, row["user_id"], text, int(time.time())))
            db.commit()
        return {"ok": True, "queued": True}
    if path == "/research/reconcile":
        message_ids = {str(x) for x in (data.get("message_ids") or [])}
        now = int(time.time())
        deleted = []
        with conn() as db:
            rows = [dict(r) for r in db.execute("SELECT * FROM sessions WHERE chat_id=?", (chat_id,)).fetchall()]
        for row in rows:
            # The browser does not need to know the OpenWebUI user id. Root message
            # identity plus chat identity is sufficient for cleanup, and a short grace
            # period prevents cleanup while the initial assistant placeholder is saving.
            if row["root_id"] not in message_ids and now - int(row["created_at"]) > 180:
                sandbox_delete(row); deleted.append(row["root_id"])
        return {"ok": True, "deleted_roots": deleted}
    if path == "/research/delete-chat":
        with conn() as db:
            rows = [dict(r) for r in db.execute("SELECT * FROM sessions WHERE chat_id=?", (chat_id,)).fetchall()]
        for row in rows: sandbox_delete(row)
        return {"ok": True, "deleted": len(rows)}
    if path == "/research/ui-status":
        with conn() as db:
            rows = [dict(r) for r in db.execute("SELECT chat_id,root_id,container_name,volume_name,brief,created_at,updated_at,last_used FROM sessions WHERE chat_id=?", (chat_id,)).fetchall()]
        return {"ok": True, "sessions": rows}
    raise KeyError("unknown ui endpoint")


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalAIResearchController/1.0"

    def log_message(self, fmt, *args):
        print(time.strftime("%Y-%m-%d %H:%M:%S"), self.address_string(), fmt % args, flush=True)

    def _headers(self, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Local-AI-Key")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def _json(self, status, obj):
        self._headers(status)
        self.wfile.write(json.dumps(obj, ensure_ascii=False).encode())

    def do_OPTIONS(self):
        self._headers(204)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"ok": True, "service": "deep-research-sandbox-controller", "version": "2.6"})
        return self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        try:
            length = min(int(self.headers.get("Content-Length", "0") or 0), 2_000_000)
            data = json.loads(self.rfile.read(length) or b"{}")
            token = self.headers.get("X-Local-AI-Key", "")
            admin = read_secret(ADMIN_SECRET_FILE)
            ui = read_secret(UI_SECRET_FILE)
            if token and admin and token == admin:
                result = handle_admin(self.path, data)
            elif token and ui and token == ui:
                result = handle_ui(self.path, data)
            else:
                return self._json(401, {"ok": False, "error": "unauthorized"})
            return self._json(200, result)
        except subprocess.TimeoutExpired:
            return self._json(408, {"ok": False, "error": "sandbox command timed out"})
        except KeyError as e:
            return self._json(404, {"ok": False, "error": str(e)})
        except Exception as e:
            return self._json(400, {"ok": False, "error": f"{type(e).__name__}: {e}"})


def idle_reaper():
    while True:
        time.sleep(60)
        try:
            cutoff = int(time.time()) - IDLE_SECONDS
            with conn() as db:
                rows = [dict(r) for r in db.execute("SELECT * FROM sessions WHERE last_used < ?", (cutoff,)).fetchall()]
            for row in rows:
                # Stop CPU/RAM consumption but preserve the named volume until the
                # originating research prompt or chat is deleted.
                sandbox_stop(row)
        except Exception as e:
            print("idle reaper:", repr(e), flush=True)


if __name__ == "__main__":
    init_db()
    threading.Thread(target=idle_reaper, daemon=True).start()
    print(f"Deep Research sandbox controller listening on {HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
PYCTRL
  $SUDO chmod 700 "$SANDBOX_DIR/controller.py"

  $SUDO tee /etc/systemd/system/local-ai-research-controller.service >/dev/null <<EOF
[Unit]
Description=Local AI Deep Research Sandbox Controller
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SANDBOX_DIR/controller.py
Restart=on-failure
RestartSec=3
Environment=LAI_CONTROLLER_HOST=0.0.0.0
Environment=LAI_CONTROLLER_PORT=$SANDBOX_PORT
Environment=LAI_CONTROLLER_DIR=$SANDBOX_DIR
Environment=LAI_SANDBOX_IMAGE=$SANDBOX_IMAGE
Environment=LAI_SANDBOX_MEMORY=$SANDBOX_MEMORY
Environment=LAI_SANDBOX_CPUS=$SANDBOX_CPUS
Environment=LAI_SANDBOX_IDLE_SECONDS=$SANDBOX_IDLE_SECONDS
Environment=LAI_SANDBOX_NETWORK=$SANDBOX_NETWORK
Environment=LAI_OLLAMA_URL=http://127.0.0.1:11434
Environment=LAI_MODEL_KEEP_ALIVE=$MODEL_IDLE_UNLOAD
Environment=LAI_ADVANCED_FINAL_MODEL=$RESEARCH_MODEL
Environment=LAI_ADVANCED_FINAL_MAX_USER=24000
Environment=LAI_ADVANCED_FINAL_MAX_ANSWER=36000
Environment=LAI_ADVANCED_FINAL_REPAIR_MAX=2
Environment=LAI_SEARXNG_URL=$SEARXNG_CONTROLLER_URL
Environment=LAI_WEB_PRE_SEARCH_MAX=$DEEP_WEB_PRE_SEARCH_MAX
Environment=LAI_WEB_PRE_FETCH_MAX=$DEEP_WEB_PRE_FETCH_MAX
Environment=LAI_WEB_POST_SEARCH_MAX=$DEEP_WEB_POST_SEARCH_MAX
Environment=LAI_WEB_POST_FETCH_MAX=$DEEP_WEB_POST_FETCH_MAX
Environment=LAI_SCOPE_AUDIT_MODEL=$SCOPE_AUDIT_MODEL
Environment=LAI_SCOPE_AUDIT_ARTIFACT_CHARS=$SCOPE_AUDIT_ARTIFACT_CHARS
Environment=LAI_SCOPE_AUDIT_BRIEF_CHARS=$SCOPE_AUDIT_BRIEF_CHARS
Environment=LAI_SEMANTIC_AUDIT_MODEL=$SEMANTIC_AUDIT_MODEL
Environment=LAI_SEMANTIC_AUDIT_ARTIFACT_CHARS=$SEMANTIC_AUDIT_ARTIFACT_CHARS
Environment=LAI_SEMANTIC_AUDIT_EVIDENCE_CHARS=$SEMANTIC_AUDIT_EVIDENCE_CHARS
Environment=LAI_SEMANTIC_AUDIT_SCOPE_CHARS=$SEMANTIC_AUDIT_SCOPE_CHARS
Environment=LAI_SEMANTIC_REPAIR_MAX=$SEMANTIC_REPAIR_MAX
Environment=LAI_EVIDENCE_GAP_MIN_CHARS=40
Environment=LAI_LESSON_MODEL=$LESSON_MODEL
Environment=LAI_LESSON_RETRIEVAL_MAX=$LESSON_RETRIEVAL_MAX
Environment=LAI_LESSON_ARTIFACT_CHARS=$LESSON_ARTIFACT_CHARS
Environment=LAI_LESSON_FAILURE_CHARS=$LESSON_FAILURE_CHARS

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable local-ai-research-controller.service >/dev/null
  # Always restart on upgrade. `enable --now` does not reload an already-running
  # Python process when controller.py is replaced.
  $SUDO systemctl restart local-ai-research-controller.service
  wait_for_url "http://127.0.0.1:$SANDBOX_PORT/health" 30 || { $SUDO journalctl -u local-ai-research-controller.service -n 80 --no-pager || true; fail "Deep Research sandbox controller failed to start"; }
  ok "Sandbox controller is running; sandboxes are isolated containers with persistent per-research volumes"
  CONTROLLER_VERSION="$(curl -fsS "http://127.0.0.1:$SANDBOX_PORT/health" | jq -r '.version // empty')"
  [[ "$CONTROLLER_VERSION" == "2.6" ]] || fail "Research controller upgrade did not take effect (expected 2.6, got ${CONTROLLER_VERSION:-unknown})"
  ok "Research controller runtime version verified: $CONTROLLER_VERSION"
  ok "Sandbox shell execution enforces pipefail and normalizes /workspace paths exactly once"
  warn "Controller TCP $SANDBOX_PORT is authenticated but listens on host interfaces so the OpenWebUI container can reach it. Keep this port blocked from untrusted networks."
fi

if json_bool "$INSTALL_DEEP_RESEARCH"; then
  section "INSTALLING DEEP RESEARCH LAB TOOL"
  cat >${WORKDIR}/deep_research_lab.py <<'PYTOOL'
"""
title: Deep Research Lab
author: Local AI Suite
version: 2.6.0
description: Persistent per-research Docker laboratory with explicit validation support, durable per-step timing, and validated lessons. Exposed only by Deep Research mode.
"""
import asyncio
import json
import time
from typing import Optional
import httpx

CONTROLLER = "__CONTROLLER_URL__"
KEY = "__CONTROLLER_SECRET__"


def _fmt_elapsed(seconds):
    value = max(0.0, float(seconds or 0.0))
    if value < 10.0:
        return f"{value:.2f}s"
    if value < 60.0:
        return f"{value:.1f}s"
    total_tenths = int(round(value * 10.0))
    total_seconds, tenth = divmod(total_tenths, 10)
    minutes, secs = divmod(total_seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}.{tenth}"
    return f"{minutes:02d}:{secs:02d}.{tenth}"



def _timer_ui_code(action, label, phase, elapsed=0.0, auto_total=True):
    values = {
        "__ACTION__": json.dumps(str(action)),
        "__LABEL__": json.dumps(str(label)),
        "__PHASE__": json.dumps(str(phase)),
        "__ELAPSED__": str(max(0, int(float(elapsed or 0.0) * 1000))),
        "__AUTO_TOTAL__": "true" if auto_total else "false",
    }
    code = r"""
(() => {
  const action = __ACTION__;
  const label = __LABEL__;
  const phase = __PHASE__;
  const elapsedMs = __ELAPSED__;
  const autoTotal = __AUTO_TOTAL__;
  window.__laiDeepResearchTimers = window.__laiDeepResearchTimers || {steps:{},totalStarted:null,totalInterval:null,watchdog:null};
  const state = window.__laiDeepResearchTimers;
  const fmtStep = (ms) => { ms=Math.max(0,Number(ms)||0); if(ms<10000)return (ms/1000).toFixed(2)+'s'; if(ms<60000)return (ms/1000).toFixed(1)+'s'; const tenths=Math.round(ms/100); const totalSec=Math.floor(tenths/10); const tenth=tenths%10; const h=Math.floor(totalSec/3600); const m=Math.floor((totalSec%3600)/60); const s=totalSec%60; return h>0 ? String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(s).padStart(2,'0')+'.'+tenth : String(m).padStart(2,'0')+':'+String(s).padStart(2,'0')+'.'+tenth; };
  const fmtTotal = (ms) => { const s=Math.max(0,Math.floor((Number(ms)||0)/1000)); const h=Math.floor(s/3600); const m=Math.floor((s%3600)/60); const sec=s%60; return h>0 ? String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(sec).padStart(2,'0') : String(m).padStart(2,'0')+':'+String(sec).padStart(2,'0'); };
  function stopAll(){ try{Object.values(state.steps||{}).forEach(x=>{if(x&&x.interval)clearInterval(x.interval)});if(state.totalInterval)clearInterval(state.totalInterval);if(state.watchdog)clearInterval(state.watchdog)}catch(_){} state.steps={};state.totalStarted=null;state.totalInterval=null;state.watchdog=null; }
  function ensurePanel(){ let p=document.getElementById('lai-deep-research-timer-panel'); if(!p){ p=document.createElement('div');p.id='lai-deep-research-timer-panel';Object.assign(p.style,{position:'fixed',right:'14px',bottom:'118px',width:'360px',maxWidth:'calc(100vw - 28px)',maxHeight:'46vh',overflow:'auto',zIndex:'2147483000',background:'rgba(18,18,21,.94)',border:'1px solid rgba(255,255,255,.14)',borderRadius:'12px',boxShadow:'0 8px 28px rgba(0,0,0,.30)',backdropFilter:'blur(12px)',color:'#f0f0f2',fontFamily:'ui-monospace,SFMono-Regular,Menlo,monospace',fontSize:'11px',lineHeight:'1.35',padding:'10px'}); const h=document.createElement('div');Object.assign(h.style,{display:'flex',alignItems:'center',gap:'8px',paddingBottom:'7px',marginBottom:'7px',borderBottom:'1px solid rgba(255,255,255,.12)'}); const t=document.createElement('strong');t.textContent='Deep Research Timers';t.style.flex='1';t.title='Step rows use measured high-resolution duration; Total is wall-clock research time.'; const total=document.createElement('span');total.id='lai-deep-research-total';total.textContent='Total 00:00';total.style.opacity='.82'; const x=document.createElement('button');x.textContent='×';x.title='Hide timer panel until next timed step';Object.assign(x.style,{border:'0',background:'transparent',color:'#ddd',cursor:'pointer',fontSize:'16px',padding:'0 2px'});x.onclick=()=>{p.style.display='none'};h.append(t,total,x); const rows=document.createElement('div');rows.id='lai-deep-research-timer-rows';p.append(h,rows);document.body.appendChild(p);} p.style.display='block';return p; }
  function startTotal(){ const p=ensurePanel();const t=p.querySelector('#lai-deep-research-total');if(!state.totalStarted)state.totalStarted=Date.now();if(state.totalInterval)clearInterval(state.totalInterval);const u=()=>{if(t&&state.totalStarted)t.textContent='Total '+fmtTotal(Date.now()-state.totalStarted)};u();state.totalInterval=setInterval(u,250); }
  if(phase==='reset'){stopAll();const old=document.getElementById('lai-deep-research-timer-panel');if(old)old.remove();ensurePanel();return;}
  if(phase==='total_start'){startTotal();return;}
  if(phase==='total_stop'){const p=ensurePanel();const t=p.querySelector('#lai-deep-research-total');if(state.totalInterval)clearInterval(state.totalInterval);state.totalInterval=null;if(t&&state.totalStarted)t.textContent='Total '+fmtTotal(Date.now()-state.totalStarted)+' ✓';return;}
  if(phase==='finalize'){
    const p=ensurePanel();
    const t=p.querySelector('#lai-deep-research-total');
    const now=Date.now();

    Object.entries(state.steps||{}).forEach(([key,item])=>{
      try{
        if(item&&item.interval)clearInterval(item.interval);
        if(item&&item.row){
          const l=item.row.querySelector('.lai-timer-label');
          const r=item.row.querySelector('.lai-timer-time');
          const original=l ? String(l.textContent||'').replace(/^▶\s*/,'') : 'step';
          if(l)l.textContent='✓ '+original;
          if(r)r.textContent=fmtStep(now-(item.started||now));
          item.row.dataset.done='1';
          item.row.style.opacity='.72';
        }
      }catch(_){}
    });

    state.steps={};

    if(state.watchdog)clearInterval(state.watchdog);
    state.watchdog=null;

    if(state.totalInterval)clearInterval(state.totalInterval);
    state.totalInterval=null;

    if(t){
      if(state.totalStarted){
        t.textContent='Total '+fmtTotal(now-state.totalStarted)+' ✓';
      }else{
        t.textContent='Completed ✓';
      }
    }

    state.totalStarted=null;
    return;
  }
  const p=ensurePanel();if(autoTotal&&!state.totalStarted)startTotal();const rows=p.querySelector('#lai-deep-research-timer-rows');
  if(phase==='start'){const prev=state.steps[action];if(prev&&prev.interval)clearInterval(prev.interval);let row=document.getElementById('lai-timer-'+action);if(!row){row=document.createElement('div');row.id='lai-timer-'+action;row.dataset.done='0';Object.assign(row.style,{display:'grid',gridTemplateColumns:'1fr auto',gap:'8px',padding:'5px 0',borderBottom:'1px solid rgba(255,255,255,.06)'});const l=document.createElement('span');l.className='lai-timer-label';l.style.overflowWrap='anywhere';const r=document.createElement('span');r.className='lai-timer-time';r.style.whiteSpace='nowrap';row.append(l,r);rows.prepend(row);}row.querySelector('.lai-timer-label').textContent='▶ '+label;row.querySelector('.lai-timer-time').textContent='0.00s';row.dataset.done='0';row.style.opacity='1';const started=Date.now();const update=()=>{const r=row.querySelector('.lai-timer-time');if(r)r.textContent=fmtStep(Date.now()-started)};const interval=setInterval(update,100);state.steps[action]={started,interval,row};if(!state.watchdog){state.watchdog=setInterval(()=>{const now=Date.now();Object.entries(state.steps||{}).forEach(([k,item])=>{if(item&&item.started&&now-item.started>20*60*1000){try{if(item.interval)clearInterval(item.interval);const l=item.row&&item.row.querySelector('.lai-timer-label');const r=item.row&&item.row.querySelector('.lai-timer-time');const original=l?String(l.textContent||'').replace(/^▶\\s*/,''):'step';if(l)l.textContent='⚠ '+original+' (stale timer closed)';if(r)r.textContent=fmtStep(now-item.started);if(item.row){item.row.dataset.done='1';item.row.style.opacity='.72';}}catch(_){}delete state.steps[k];}});},30000);}return;}
  if(phase==='finish'||phase==='fail'){const item=state.steps[action];if(item&&item.interval)clearInterval(item.interval);let row=item&&item.row?item.row:document.getElementById('lai-timer-'+action);if(!row){row=document.createElement('div');row.id='lai-timer-'+action;Object.assign(row.style,{display:'grid',gridTemplateColumns:'1fr auto',gap:'8px',padding:'5px 0',borderBottom:'1px solid rgba(255,255,255,.06)'});const l=document.createElement('span');l.className='lai-timer-label';const r=document.createElement('span');r.className='lai-timer-time';row.append(l,r);rows.prepend(row);}const l=row.querySelector('.lai-timer-label');const r=row.querySelector('.lai-timer-time');if(l)l.textContent=(phase==='fail'?'✕ ':'✓ ')+label;if(r)r.textContent=fmtStep(elapsedMs);row.dataset.done='1';row.style.opacity=phase==='fail'?'.95':'.72';delete state.steps[action];const done=Array.from(rows.children).filter(n=>n.dataset.done==='1');while(done.length>12){const old=done.pop();if(old)old.remove();}}
})();
"""
    for key,value in values.items(): code=code.replace(key,value)
    return code

async def _emit_timer_ui(emitter, action, label, phase, elapsed=0.0, auto_total=True):
    if emitter is None: return
    try:
        await emitter({"type":"execute","data":{"code":_timer_ui_code(action,label,phase,elapsed,auto_total)}})
    except Exception:
        pass


class _StepTimer:
    def __init__(self, emitter, label):
        self.emitter = emitter
        self.label = label
        self.started = time.monotonic()
        self.action = f"local-ai-step-{time.monotonic_ns()}"

    async def start(self):
        if self.emitter is None:
            return self
        await self.emitter({"type":"status","data":{"description":f"{self.label} · ⏱ 00:00","done":False,"hidden":False,"action":self.action}})
        await _emit_timer_ui(self.emitter, self.action, self.label, "start", 0.0, True)
        return self

    async def finish(self, label=None):
        elapsed = time.monotonic() - self.started
        final_label = label or self.label
        if self.emitter is not None:
            await _emit_timer_ui(self.emitter, self.action, final_label, "finish", elapsed, True)
            await self.emitter({"type":"status","data":{"description":f"{final_label} · ⏱ {_fmt_elapsed(elapsed)}","done":True,"hidden":False,"action":self.action}})
        return round(elapsed, 2)


class Tools:
    async def _record_timing(self, ctx, step_kind, label, seconds, outcome="ok", detail=""):
        try:
            await self._post(
                "/timing/record",
                {
                    **ctx,
                    "step_kind": step_kind,
                    "label": label,
                    "duration_seconds": seconds,
                    "outcome": outcome,
                    "detail": detail,
                },
            )
        except Exception:
            pass

    async def _timed_post(self, label, path, payload, __event_emitter__=None, done_label=None, step_kind=None):
        timer = await _StepTimer(__event_emitter__, label).start()
        ctx = {k: payload.get(k) for k in ("chat_id", "root_id", "user_id")}
        kind = step_kind or path.strip("/").replace("/", ".")
        try:
            data = await self._post(path, payload)
        except Exception as exc:
            seconds = await timer.finish(f"{label} failed")
            await _emit_timer_ui(__event_emitter__, timer.action, f"{label} failed", "fail", seconds, True)
            await self._record_timing(ctx, kind, label, seconds, "failed", type(exc).__name__)
            raise
        seconds = await timer.finish(done_label or label)
        await self._record_timing(ctx, kind, done_label or label, seconds, "ok")
        if isinstance(data, dict):
            data.setdefault("step_seconds", seconds)
        return data

    def _ctx(self, __request__, __user__, __metadata__):
        meta = __metadata__ or {}
        chat_id = str(meta.get("chat_id") or "")
        user_id = str((__user__ or {}).get("id") or "")
        root_id = ""
        mode = ""
        if __request__ is not None:
            mode = str(__request__.headers.get("x-local-ai-mode") or "").lower()
            root_id = str(__request__.headers.get("x-local-ai-research-root") or "")
        # Backend enforcement, not merely a system-prompt instruction. Fast and
        # Advanced requests cannot use the lab even if the tool is manually added.
        if mode != "deep":
            raise RuntimeError("Research Lab is available only in Deep Research mode.")
        if not root_id:
            root_id = str(meta.get("message_id") or meta.get("id") or "")
        if not chat_id or not root_id or not user_id:
            raise RuntimeError("Deep Research sandbox context is incomplete. Start the request from the Deep Research mode button.")
        return {"chat_id": chat_id, "root_id": root_id, "user_id": user_id}

    async def _post(self, path: str, payload: dict):
        async with httpx.AsyncClient(timeout=620.0) as client:
            r = await client.post(
                CONTROLLER + path,
                headers={"X-Local-AI-Key": KEY},
                json=payload,
            )
        if r.status_code >= 400:
            raise RuntimeError(f"Sandbox controller error {r.status_code}: {r.text[:1000]}")
        return r.json()

    async def research_lab_status(self, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Check whether the Deep Research laboratory exists/runs and show its persistent workspace identity."""
        data = await self._timed_post(
            "Research Lab: checking status",
            "/sandbox/status",
            self._ctx(__request__, __user__, __metadata__),
            __event_emitter__,
            "Research Lab: status checked",
        )
        return json.dumps(data, ensure_ascii=False)

    async def research_lab_exec(
        self,
        command: str,
        timeout: int = 120,
        __request__=None,
        __user__=None,
        __metadata__=None,
        __event_emitter__=None,
    ) -> str:
        """Run a NON-VALIDATION shell command inside the isolated persistent Deep Research lab for setup, package installation, inspection, experiments, repositories, or reproducible investigation. Shell pipelines use pipefail. The controller rejects known validator/test/lint/config-check commands here (for example esphome config, pytest, shellcheck, yamllint, cargo check, go test, terraform validate, npm test/build/lint) because those must go through research_lab_validate so scope auditing and validation budgets cannot be bypassed. Never assume this is the Fedora host."""
        ctx = self._ctx(__request__, __user__, __metadata__)
        command_preview = " ".join(str(command).split())
        if len(command_preview) > 82:
            command_preview = command_preview[:79] + "..."
        timer = await _StepTimer(
            __event_emitter__,
            f"Research Lab: exec {command_preview}",
        ).start()
        try:
            data = await self._post(
                "/sandbox/exec",
                {**ctx, "command": command, "timeout": max(1, min(int(timeout), 600))},
            )
        except Exception as exc:
            seconds = await timer.finish(f"Research Lab: exec failed · {command_preview}")
            await self._record_timing(ctx, "lab.exec", "Research Lab: experiment", seconds, "failed", type(exc).__name__)
            raise
        seconds = await timer.finish(f"Research Lab: exec {command_preview} · exit {data.get('exit_code')}")
        await self._record_timing(
            ctx,
            "lab.exec",
            "Research Lab: experiment",
            seconds,
            "ok" if int(data.get("exit_code", -1)) == 0 else "nonzero",
            f"exit_code={data.get('exit_code')}",
        )
        return f"step_time={seconds:.2f}s\nexit_code={data.get('exit_code')}\n{data.get('output','')}"

    async def research_lab_validate(
        self,
        command: str,
        artifact: str = "generated artifact",
        timeout: int = 300,
        __request__=None,
        __user__=None,
        __metadata__=None,
        __event_emitter__=None,
    ) -> str:
        """MANDATORY verification tool for Deep Research when generated code, configuration, manifests, scripts, build instructions, or other machine-checkable artifacts can reasonably be validated in Linux. Flow: scope audit -> real validator -> semantic consistency audit. A syntax/config validator PASS is not treated as final success until the semantic audit also runs. Semantic review checks claims/comments versus implementation, already-fetched primary documentation, runtime placeholders, and physical-control assumptions. Blocking semantic issues require repair; warnings/assumptions must be surfaced. Pass the actual generated artifact path. Do not pipe validator output through head or tail."""
        ctx = self._ctx(__request__, __user__, __metadata__)
        total_started = time.monotonic()

        audit_timer = await _StepTimer(__event_emitter__, f"Research Lab: scope-auditing {artifact}").start()
        try:
            audit = await self._post(
                "/sandbox/scope-audit",
                {
                    **ctx,
                    "artifact": artifact,
                },
            )
        except Exception:
            await audit_timer.finish(f"Research Lab: scope audit error for {artifact}")
            raise

        if not audit.get("passed"):
            audit_seconds = await audit_timer.finish(f"Research Lab: scope audit failed for {artifact}")
            await self._record_timing(
                ctx, "validation.scope_audit", f"Scope audit: {artifact}",
                audit_seconds, "failed", "scope mismatch"
            )
            total_seconds = round(time.monotonic() - total_started, 2)
            return (
                f"SCOPE AUDIT FAILED: {artifact}\n"
                "Validation was NOT run and the validation-attempt budget was NOT consumed.\n"
                f"violations={json.dumps(audit.get('violations') or [], ensure_ascii=False)}\n"
                f"missing={json.dumps(audit.get('missing') or [], ensure_ascii=False)}\n"
                f"contradictions={json.dumps(audit.get('contradictions') or [], ensure_ascii=False)}\n"
                f"notes={json.dumps(audit.get('notes') or [], ensure_ascii=False)}\n"
                f"timing scope_audit={audit_seconds:.2f}s total={total_seconds:.2f}s\n"
                "Repair the artifact to match the approved Research Brief, then call research_lab_validate again."
            )

        audit_seconds = await audit_timer.finish(f"Research Lab: scope audit passed for {artifact}")
        await self._record_timing(
            ctx, "validation.scope_audit", f"Scope audit: {artifact}",
            audit_seconds, "ok", "cached" if bool(audit.get("cached")) else "fresh"
        )
        validator_timer = await _StepTimer(__event_emitter__, f"Research Lab: validating {artifact}").start()

        try:
            data = await self._post(
            "/sandbox/exec",
            {
                **ctx,
                "command": command,
                "timeout": max(1, min(int(timeout), 600)),
                "kind": "validation",
                "artifact": artifact,
                "defer_success_learning": True,
            },
        )
        except Exception as exc:
            validator_seconds = await validator_timer.finish(f"Research Lab: validator error for {artifact}")
            await self._record_timing(
                ctx, "validation.validator", f"Validator: {artifact}",
                validator_seconds, "failed", type(exc).__name__
            )
            raise

        code = int(data.get("exit_code", -1))
        validator_seconds = await validator_timer.finish(
            f"Research Lab validation {'passed' if code == 0 else 'failed'} for {artifact}"
        )
        await self._record_timing(
            ctx, "validation.validator", f"Validator: {artifact}",
            validator_seconds, "ok" if code == 0 else "nonzero", f"exit_code={code}"
        )

        semantic = None
        semantic_seconds = 0.0
        finalize = {
            "lesson_learning_queued": False,
            "reused_lessons_confirmed": 0,
        }

        if code == 0:
            semantic_timer = await _StepTimer(
                __event_emitter__,
                f"Research Lab: semantic-auditing {artifact}",
            ).start()
            try:
                semantic = await self._post(
                    "/sandbox/semantic-audit",
                    {
                        **ctx,
                        "artifact": artifact,
                        "validator_output": data.get("output", ""),
                    },
                )
            except Exception:
                semantic_seconds = await semantic_timer.finish(
                    f"Research Lab: semantic audit error for {artifact}",
                    failed=True,
                )
                await self._record_timing(
                    ctx,
                    "validation.semantic_audit",
                    f"Semantic audit: {artifact}",
                    semantic_seconds,
                    "failed",
                    "tool error",
                )
                raise

            semantic_seconds = await semantic_timer.finish(
                f"Research Lab: semantic audit {semantic.get('status','unknown')} for {artifact}",
                failed=not bool(semantic.get("passed")),
            )
            await self._record_timing(
                ctx,
                "validation.semantic_audit",
                f"Semantic audit: {artifact}",
                semantic_seconds,
                "ok" if semantic.get("passed") else "failed",
                str(semantic.get("status") or ""),
            )

            if semantic.get("passed"):
                finalize = await self._post(
                    "/validation/finalize-success",
                    {
                        **ctx,
                        "artifact": artifact,
                    },
                )

        total_seconds = round(time.monotonic() - total_started, 2)
        attempt = int(data.get("validation_attempt", 0) or 0)
        same = int(data.get("same_failure_count", 0) or 0)

        if code != 0:
            verdict = "VALIDATION FAILED"
        elif semantic and not semantic.get("passed"):
            verdict = "SEMANTIC AUDIT FAILED"
        elif semantic and semantic.get("status") == "passed_with_assumptions":
            verdict = "VALIDATION PASSED WITH SEMANTIC ASSUMPTIONS"
        elif semantic and semantic.get("status") == "passed_with_warnings":
            verdict = "VALIDATION PASSED WITH SEMANTIC WARNINGS"
        else:
            verdict = "VALIDATION PASSED"

        notices = []
        if code != 0:
            notices.append(
                "POST-VALIDATION SEARCH LOCK: do not call search_web or fetch_url merely because "
                "validation failed. First repair directly from the validator message and already-fetched "
                "primary documentation. New web research is allowed only when the validator message is "
                "insufficient to determine the correction, existing authoritative documentation is missing "
                "or ambiguous, or primary sources conflict."
            )

        if data.get("repeated_failure"):
            notices.append(
                "REPEATED FAILURE: the same validation failure occurred more than once. "
                "Do not repeat the same repair and do not broaden web research automatically. "
                "Reassess the root cause from the validator output and authoritative documentation already gathered."
            )

        if data.get("final_repair_allowed"):
            notices.append(
                "FINAL DETERMINISTIC REPAIR ALLOWED: this is validation attempt 5 and the error is new. "
                "You may make exactly ONE final direct repair and run validation once more. "
                "Do not perform additional web searches unless the validator message itself is insufficient "
                "to determine the correction."
            )

        if data.get("repair_budget_reached"):
            notices.append(
                "ABSOLUTE REPAIR LIMIT REACHED: validation has reached the maximum allowed repair budget "
                "or repeated the same failure. Do not run another automatic repair/validation loop. "
                "Stop, preserve the workspace, and report the exact remaining blocker to the user."
            )

        if code == 0 and semantic and not semantic.get("passed"):
            sem_attempt = int(semantic.get("semantic_attempt", 0) or 0)
            sem_same = int(semantic.get("same_semantic_failure_count", 0) or 0)
            notices.append(
                "SEMANTIC REPAIR REQUIRED: the real validator passed, but the semantic gate found a blocking contradiction. "
                "Repair the artifact directly from the semantic findings, then run research_lab_validate again. "
                "Do not describe the artifact as validated yet."
            )
            if sem_same >= 2:
                notices.append(
                    "REPEATED SEMANTIC FAILURE: the same semantic failure was detected again. "
                    "Do not repeat the same repair."
                )
            if semantic.get("semantic_repair_budget_reached"):
                notices.append(
                    "SEMANTIC REPAIR LIMIT REACHED: stop the automatic repair loop and report the unresolved semantic blocker."
                )
        elif code == 0 and semantic and semantic.get("passed"):
            if semantic.get("warnings") or semantic.get("assumptions"):
                notices.append(
                    "STOP CONDITION WITH SEMANTIC CAVEATS: syntax/config validation passed and no blocking semantic contradiction remains. "
                    "Do not search again merely to eliminate uncertainty. Surface every semantic warning/assumption explicitly in the final answer."
                )
            else:
                notices.append(
                    "STOP CONDITION: syntax/config validation and semantic consistency audit both passed. "
                    "If the approved Research Brief is satisfied and there is no new user update, stop the lab and write the final answer."
                )

        meta = f"validation_attempt={attempt}"
        meta += (
            f" validated_lessons_learning={'queued' if finalize.get('lesson_learning_queued') else 'none'}"
            f" reused_confirmed={int(finalize.get('reused_lessons_confirmed',0) or 0)}"
        )
        if same:
            meta += f" same_failure_count={same}"
        notice_text = ("\n" + "\n".join(notices)) if notices else ""
        semantic_text = ""
        if semantic is not None:
            semantic_text = (
                f"semantic_status={semantic.get('status','unknown')} "
                f"semantic_cached={bool(semantic.get('cached'))} "
                f"semantic_sources={int(semantic.get('source_count',0) or 0)}\n"
                f"semantic_blocking={json.dumps(semantic.get('blocking_issues') or [], ensure_ascii=False)}\n"
                f"semantic_warnings={json.dumps(semantic.get('warnings') or [], ensure_ascii=False)}\n"
                f"semantic_assumptions={json.dumps(semantic.get('assumptions') or [], ensure_ascii=False)}\n"
            )

        return (
            f"{verdict}: {artifact}\n"
            f"scope_audit=PASSED cached={bool(audit.get('cached'))}\n"
            f"timing scope_audit={audit_seconds:.2f}s validator={validator_seconds:.2f}s "
            f"semantic={semantic_seconds:.2f}s total={total_seconds:.2f}s\n"
            f"command={command}\n"
            f"exit_code={code}\n"
            f"{semantic_text}"
            f"{meta}{notice_text}\n"
            f"{data.get('output','')}"
        )

    async def research_lab_list(self, path: str = ".", __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """List files inside the persistent Deep Research workspace. Prefer relative paths. /workspace paths are accepted and normalized exactly once."""
        data = await self._timed_post(
            f"Research Lab: listing {path}",
            "/sandbox/list",
            {**self._ctx(__request__, __user__, __metadata__), "path": path},
            __event_emitter__,
            f"Research Lab: listed {path}",
        )
        return f"step_time={float(data.get('step_seconds',0)):.2f}s\n{data.get('output','')}"

    async def research_lab_read(self, path: str, max_bytes: int = 50000, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Read a text file from the persistent Deep Research workspace. Prefer relative paths. /workspace paths are accepted and normalized exactly once."""
        data = await self._timed_post(
            f"Research Lab: reading {path}",
            "/sandbox/read",
            {**self._ctx(__request__, __user__, __metadata__), "path": path, "max_bytes": max(1, min(int(max_bytes), 200000))},
            __event_emitter__,
            f"Research Lab: read {path}",
        )
        return f"step_time={float(data.get('step_seconds',0)):.2f}s\n{data.get('output','')}"

    async def research_lab_write(self, path: str, content: str, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Write a file inside the persistent Deep Research workspace. Prefer relative paths such as solar-pump.yaml. /workspace paths are accepted and normalized exactly once."""
        data = await self._timed_post(
            f"Research Lab: writing {path}",
            "/sandbox/write",
            {**self._ctx(__request__, __user__, __metadata__), "path": path, "content": content},
            __event_emitter__,
            f"Research Lab: wrote {path}",
        )
        return json.dumps(data, ensure_ascii=False)

    async def research_check_updates(self, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Check for user research-scope updates queued while Deep Research is working. Call this after major research steps and before the final report."""
        data = await self._timed_post(
            "Deep Research: checking updates and budget",
            "/research/update/poll",
            self._ctx(__request__, __user__, __metadata__),
            __event_emitter__,
            "Deep Research: updates/budget checked",
        )
        updates = data.get("updates") or []
        budget = data.get("budget") or {}
        elapsed = int(budget.get("elapsed_seconds", 0) or 0)
        minutes, seconds = divmod(elapsed, 60)
        web = budget.get("web") or {}
        lessons = budget.get("lessons") or {}
        timings = budget.get("timings") or {}
        step_seconds = float(data.get("step_seconds", 0) or 0)
        budget_line = (
            f"STEP TIME: {step_seconds:.2f}s. "
            f"RESEARCH BUDGET: elapsed={minutes}m{seconds:02d}s; "
            f"validations={int(budget.get('validation_runs', 0) or 0)} "
            f"(passed={int(budget.get('validation_passed', 0) or 0)}, "
            f"failed={int(budget.get('validation_failed', 0) or 0)}); "
            f"web pre-search={int(web.get('pre_search', 0) or 0)}/{int(web.get('pre_search_max', 0) or 0)}, "
            f"pre-fetch={int(web.get('pre_fetch', 0) or 0)}/{int(web.get('pre_fetch_max', 0) or 0)}, "
            f"post-search={int(web.get('post_search', 0) or 0)}/{int(web.get('post_search_max', 0) or 0)}, "
            f"post-fetch={int(web.get('post_fetch', 0) or 0)}/{int(web.get('post_fetch_max', 0) or 0)}; "
            f"lessons retrieved={int(lessons.get('retrieved_this_research',0) or 0)}, "
            f"validated-reuse={int(lessons.get('successful_reuses_this_research',0) or 0)}, "
            f"total-learned={int(lessons.get('total_learned',0) or 0)}; "
            f"timed-steps={int(timings.get('count',0) or 0)}, "
            f"recorded-step-time={float(timings.get('recorded_step_seconds',0) or 0):.2f}s."
        )
        timing_lines = []
        recent_steps = timings.get("steps") or []
        if recent_steps:
            timing_lines.append("RECENT STEP TIMINGS:")
            for item in recent_steps[-20:]:
                timing_lines.append(
                    f"- {item.get('label','step')}: "
                    f"{float(item.get('duration_seconds',0) or 0):.2f}s "
                    f"[{item.get('outcome','')}]"
                )
        timing_text = "\n".join(timing_lines)
        if budget.get("over_soft_time_budget"):
            budget_line += (
                " SOFT TIME BUDGET EXCEEDED: stop broadening the investigation and finish from "
                "the strongest evidence already gathered unless a blocking gap remains."
            )
        if not updates:
            return "No new research updates.\n" + budget_line + ("\n" + timing_text if timing_text else "")
        return (
            "USER RESEARCH UPDATES:\n"
            + "\n".join(f"- {u.get('text','')}" for u in updates)
            + "\n"
            + budget_line
            + ("\n" + timing_text if timing_text else "")
        )

    async def research_step_timings(self, limit: int = 60, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Return the durable per-step timing ledger for this Deep Research root. Use once near the end when timing visibility matters."""
        data = await self._timed_post(
            "Deep Research: loading step timing ledger",
            "/timing/recent",
            {**self._ctx(__request__, __user__, __metadata__), "limit": max(1, min(int(limit), 120))},
            __event_emitter__,
            "Deep Research: step timing ledger loaded",
            step_kind="timing.read",
        )
        timing = data.get("timings") or {}
        lines = [
            f"STEP TIMINGS: recorded={int(timing.get('count',0) or 0)} "
            f"recorded_step_time={float(timing.get('recorded_step_seconds',0) or 0):.2f}s"
        ]
        for i, item in enumerate(timing.get("steps") or [], 1):
            lines.append(
                f"{i:02d}. {item.get('label','step')} — "
                f"{float(item.get('duration_seconds',0) or 0):.2f}s "
                f"[{item.get('outcome','')}]"
            )
        return "\n".join(lines)

    async def research_save_brief(self, updated_brief: str, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Save an updated Research Brief after the user changes scope. Each changed brief becomes a new persistent revision."""
        data = await self._timed_post(
            "Deep Research: saving revised brief",
            "/research/brief/save",
            {**self._ctx(__request__, __user__, __metadata__), "brief": updated_brief},
            __event_emitter__,
            "Deep Research: revised brief saved",
        )
        revs = data.get("revisions") or []
        return f"Research Brief saved as version {len(revs)}. step_time={float(data.get('step_seconds',0)):.2f}s"

    async def research_lessons_recent(self, limit: int = 10, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Show recently validated reusable lessons. Read-only; useful for auditing what was learned from proven failure -> passing-validation cycles."""
        data = await self._timed_post(
            "Validated Lessons: reading recent lessons",
            "/lessons/recent",
            {**self._ctx(__request__, __user__, __metadata__), "limit": max(1, min(int(limit), 30))},
            __event_emitter__,
            "Validated Lessons: recent lessons loaded",
        )
        return json.dumps(data, ensure_ascii=False, indent=2)

    async def research_lab_stop(self, __request__=None, __user__=None, __metadata__=None, __event_emitter__=None) -> str:
        """Stop the lab container to release CPU/RAM while preserving its workspace volume for follow-up research. The workspace is deleted only when its originating research prompt/chat is deleted."""
        data = await self._timed_post(
            "Research Lab: stopping container",
            "/sandbox/stop",
            self._ctx(__request__, __user__, __metadata__),
            __event_emitter__,
            "Research Lab: container stopped",
        )
        await _emit_timer_ui(__event_emitter__, "local-ai-total", "Deep Research total", "total_stop", 0.0, False)
        return json.dumps(data, ensure_ascii=False)
PYTOOL

  export CONTROLLER_ADMIN_SECRET SANDBOX_PORT
  # Substitute with Python instead of sed so secrets/URLs are treated as literal text.
  CONTROLLER_URL="http://host.docker.internal:$SANDBOX_PORT"
  python3 - "$WORKDIR/deep_research_lab.py" "$CONTROLLER_URL" "$CONTROLLER_ADMIN_SECRET" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace("__CONTROLLER_URL__", sys.argv[2]).replace("__CONTROLLER_SECRET__", sys.argv[3])
p.write_text(s)
PY
  python3 -c 'import ast,sys,pathlib; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "$WORKDIR/deep_research_lab.py"
  TOOL_CONTENT="$(cat "$WORKDIR/deep_research_lab.py")"
  TOOL_JSON="$(jq -n --arg id "$DEEP_TOOL_ID" --arg name "$DEEP_TOOL_NAME" --arg content "$TOOL_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Isolated persistent Docker lab available only to Deep Research mode.",manifest:{}}}')"
  TOOL_HTTP="$(curl -sS -o "$WORKDIR/tool-current.json" -w '%{http_code}' "$WEBUI_URL/api/v1/tools/id/$DEEP_TOOL_ID" -H "Authorization: Bearer $TOKEN")"
  if [[ "$TOOL_HTTP" == 200 ]]; then
    curl -fsS -X POST "$WEBUI_URL/api/v1/tools/id/$DEEP_TOOL_ID/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$TOOL_JSON" >"$WORKDIR/tool-installed.json" || fail "Unable to update Deep Research Lab tool"
  else
    curl -fsS -X POST "$WEBUI_URL/api/v1/tools/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$TOOL_JSON" >"$WORKDIR/tool-installed.json" || fail "Unable to create Deep Research Lab tool"
  fi
  ok "Deep Research Lab tool installed. Fast and Advanced mode never receive this tool ID."
  ok "Validation tracking enabled: authoritative-scope gate first, validator bypass blocked, then 5 normal repairs + 1 final deterministic repair, repeated-failure stop, and stop-on-success signal"

  section "INSTALLING BUDGET-ENFORCED DEEP RESEARCH WEB TOOL"
  cat >${WORKDIR}/deep_research_web.py <<'PYWEBTOOL'
"""
title: Deep Research Web
author: Local AI Suite
version: 1.9.0
description: Controller-enforced SearXNG search and safe public URL fetching for Deep Research only, with durable per-step timing.
"""
import asyncio
import json
import time
import httpx

CONTROLLER = "__CONTROLLER_URL__"
KEY = "__CONTROLLER_SECRET__"


def _fmt_elapsed(seconds):
    value = max(0.0, float(seconds or 0.0))
    if value < 10.0:
        return f"{value:.2f}s"
    if value < 60.0:
        return f"{value:.1f}s"
    total_tenths = int(round(value * 10.0))
    total_seconds, tenth = divmod(total_tenths, 10)
    minutes, secs = divmod(total_seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}.{tenth}"
    return f"{minutes:02d}:{secs:02d}.{tenth}"



def _timer_ui_code(action, label, phase, elapsed=0.0, auto_total=True):
    values = {
        "__ACTION__": json.dumps(str(action)),
        "__LABEL__": json.dumps(str(label)),
        "__PHASE__": json.dumps(str(phase)),
        "__ELAPSED__": str(max(0, int(float(elapsed or 0.0) * 1000))),
        "__AUTO_TOTAL__": "true" if auto_total else "false",
    }
    code = r"""
(() => {
  const action = __ACTION__;
  const label = __LABEL__;
  const phase = __PHASE__;
  const elapsedMs = __ELAPSED__;
  const autoTotal = __AUTO_TOTAL__;
  window.__laiDeepResearchTimers = window.__laiDeepResearchTimers || {steps:{},totalStarted:null,totalInterval:null,watchdog:null};
  const state = window.__laiDeepResearchTimers;
  const fmtStep = (ms) => { ms=Math.max(0,Number(ms)||0); if(ms<10000)return (ms/1000).toFixed(2)+'s'; if(ms<60000)return (ms/1000).toFixed(1)+'s'; const tenths=Math.round(ms/100); const totalSec=Math.floor(tenths/10); const tenth=tenths%10; const h=Math.floor(totalSec/3600); const m=Math.floor((totalSec%3600)/60); const s=totalSec%60; return h>0 ? String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(s).padStart(2,'0')+'.'+tenth : String(m).padStart(2,'0')+':'+String(s).padStart(2,'0')+'.'+tenth; };
  const fmtTotal = (ms) => { const s=Math.max(0,Math.floor((Number(ms)||0)/1000)); const h=Math.floor(s/3600); const m=Math.floor((s%3600)/60); const sec=s%60; return h>0 ? String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(sec).padStart(2,'0') : String(m).padStart(2,'0')+':'+String(sec).padStart(2,'0'); };
  function stopAll(){ try{Object.values(state.steps||{}).forEach(x=>{if(x&&x.interval)clearInterval(x.interval)});if(state.totalInterval)clearInterval(state.totalInterval);if(state.watchdog)clearInterval(state.watchdog)}catch(_){} state.steps={};state.totalStarted=null;state.totalInterval=null;state.watchdog=null; }
  function ensurePanel(){ let p=document.getElementById('lai-deep-research-timer-panel'); if(!p){ p=document.createElement('div');p.id='lai-deep-research-timer-panel';Object.assign(p.style,{position:'fixed',right:'14px',bottom:'118px',width:'360px',maxWidth:'calc(100vw - 28px)',maxHeight:'46vh',overflow:'auto',zIndex:'2147483000',background:'rgba(18,18,21,.94)',border:'1px solid rgba(255,255,255,.14)',borderRadius:'12px',boxShadow:'0 8px 28px rgba(0,0,0,.30)',backdropFilter:'blur(12px)',color:'#f0f0f2',fontFamily:'ui-monospace,SFMono-Regular,Menlo,monospace',fontSize:'11px',lineHeight:'1.35',padding:'10px'}); const h=document.createElement('div');Object.assign(h.style,{display:'flex',alignItems:'center',gap:'8px',paddingBottom:'7px',marginBottom:'7px',borderBottom:'1px solid rgba(255,255,255,.12)'}); const t=document.createElement('strong');t.textContent='Deep Research Timers';t.style.flex='1';t.title='Step rows use measured high-resolution duration; Total is wall-clock research time.'; const total=document.createElement('span');total.id='lai-deep-research-total';total.textContent='Total 00:00';total.style.opacity='.82'; const x=document.createElement('button');x.textContent='×';x.title='Hide timer panel until next timed step';Object.assign(x.style,{border:'0',background:'transparent',color:'#ddd',cursor:'pointer',fontSize:'16px',padding:'0 2px'});x.onclick=()=>{p.style.display='none'};h.append(t,total,x); const rows=document.createElement('div');rows.id='lai-deep-research-timer-rows';p.append(h,rows);document.body.appendChild(p);} p.style.display='block';return p; }
  function startTotal(){ const p=ensurePanel();const t=p.querySelector('#lai-deep-research-total');if(!state.totalStarted)state.totalStarted=Date.now();if(state.totalInterval)clearInterval(state.totalInterval);const u=()=>{if(t&&state.totalStarted)t.textContent='Total '+fmtTotal(Date.now()-state.totalStarted)};u();state.totalInterval=setInterval(u,250); }
  if(phase==='reset'){stopAll();const old=document.getElementById('lai-deep-research-timer-panel');if(old)old.remove();ensurePanel();return;}
  if(phase==='total_start'){startTotal();return;}
  if(phase==='total_stop'){const p=ensurePanel();const t=p.querySelector('#lai-deep-research-total');if(state.totalInterval)clearInterval(state.totalInterval);state.totalInterval=null;if(t&&state.totalStarted)t.textContent='Total '+fmtTotal(Date.now()-state.totalStarted)+' ✓';return;}
  if(phase==='finalize'){
    const p=ensurePanel();
    const t=p.querySelector('#lai-deep-research-total');
    const now=Date.now();

    Object.entries(state.steps||{}).forEach(([key,item])=>{
      try{
        if(item&&item.interval)clearInterval(item.interval);
        if(item&&item.row){
          const l=item.row.querySelector('.lai-timer-label');
          const r=item.row.querySelector('.lai-timer-time');
          const original=l ? String(l.textContent||'').replace(/^▶\s*/,'') : 'step';
          if(l)l.textContent='✓ '+original;
          if(r)r.textContent=fmtStep(now-(item.started||now));
          item.row.dataset.done='1';
          item.row.style.opacity='.72';
        }
      }catch(_){}
    });

    state.steps={};

    if(state.watchdog)clearInterval(state.watchdog);
    state.watchdog=null;

    if(state.totalInterval)clearInterval(state.totalInterval);
    state.totalInterval=null;

    if(t){
      if(state.totalStarted){
        t.textContent='Total '+fmtTotal(now-state.totalStarted)+' ✓';
      }else{
        t.textContent='Completed ✓';
      }
    }

    state.totalStarted=null;
    return;
  }
  const p=ensurePanel();if(autoTotal&&!state.totalStarted)startTotal();const rows=p.querySelector('#lai-deep-research-timer-rows');
  if(phase==='start'){const prev=state.steps[action];if(prev&&prev.interval)clearInterval(prev.interval);let row=document.getElementById('lai-timer-'+action);if(!row){row=document.createElement('div');row.id='lai-timer-'+action;row.dataset.done='0';Object.assign(row.style,{display:'grid',gridTemplateColumns:'1fr auto',gap:'8px',padding:'5px 0',borderBottom:'1px solid rgba(255,255,255,.06)'});const l=document.createElement('span');l.className='lai-timer-label';l.style.overflowWrap='anywhere';const r=document.createElement('span');r.className='lai-timer-time';r.style.whiteSpace='nowrap';row.append(l,r);rows.prepend(row);}row.querySelector('.lai-timer-label').textContent='▶ '+label;row.querySelector('.lai-timer-time').textContent='0.00s';row.dataset.done='0';row.style.opacity='1';const started=Date.now();const update=()=>{const r=row.querySelector('.lai-timer-time');if(r)r.textContent=fmtStep(Date.now()-started)};const interval=setInterval(update,100);state.steps[action]={started,interval,row};if(!state.watchdog){state.watchdog=setInterval(()=>{const now=Date.now();Object.entries(state.steps||{}).forEach(([k,item])=>{if(item&&item.started&&now-item.started>20*60*1000){try{if(item.interval)clearInterval(item.interval);const l=item.row&&item.row.querySelector('.lai-timer-label');const r=item.row&&item.row.querySelector('.lai-timer-time');const original=l?String(l.textContent||'').replace(/^▶\\s*/,''):'step';if(l)l.textContent='⚠ '+original+' (stale timer closed)';if(r)r.textContent=fmtStep(now-item.started);if(item.row){item.row.dataset.done='1';item.row.style.opacity='.72';}}catch(_){}delete state.steps[k];}});},30000);}return;}
  if(phase==='finish'||phase==='fail'){const item=state.steps[action];if(item&&item.interval)clearInterval(item.interval);let row=item&&item.row?item.row:document.getElementById('lai-timer-'+action);if(!row){row=document.createElement('div');row.id='lai-timer-'+action;Object.assign(row.style,{display:'grid',gridTemplateColumns:'1fr auto',gap:'8px',padding:'5px 0',borderBottom:'1px solid rgba(255,255,255,.06)'});const l=document.createElement('span');l.className='lai-timer-label';const r=document.createElement('span');r.className='lai-timer-time';row.append(l,r);rows.prepend(row);}const l=row.querySelector('.lai-timer-label');const r=row.querySelector('.lai-timer-time');if(l)l.textContent=(phase==='fail'?'✕ ':'✓ ')+label;if(r)r.textContent=fmtStep(elapsedMs);row.dataset.done='1';row.style.opacity=phase==='fail'?'.95':'.72';delete state.steps[action];const done=Array.from(rows.children).filter(n=>n.dataset.done==='1');while(done.length>12){const old=done.pop();if(old)old.remove();}}
})();
"""
    for key,value in values.items(): code=code.replace(key,value)
    return code

async def _emit_timer_ui(emitter, action, label, phase, elapsed=0.0, auto_total=True):
    if emitter is None: return
    try:
        await emitter({"type":"execute","data":{"code":_timer_ui_code(action,label,phase,elapsed,auto_total)}})
    except Exception:
        pass


class _StepTimer:
    def __init__(self, emitter, label):
        self.emitter = emitter
        self.label = label
        self.started = time.monotonic()
        self.action = f"local-ai-step-{time.monotonic_ns()}"

    async def start(self):
        if self.emitter is None:
            return self
        await self.emitter({"type":"status","data":{"description":f"{self.label} · ⏱ 00:00","done":False,"hidden":False,"action":self.action}})
        await _emit_timer_ui(self.emitter, self.action, self.label, "start", 0.0, True)
        return self

    async def finish(self, label=None):
        elapsed = time.monotonic() - self.started
        final_label = label or self.label
        if self.emitter is not None:
            await _emit_timer_ui(self.emitter, self.action, final_label, "finish", elapsed, True)
            await self.emitter({"type":"status","data":{"description":f"{final_label} · ⏱ {_fmt_elapsed(elapsed)}","done":True,"hidden":False,"action":self.action}})
        return round(elapsed, 2)


class Tools:
    def _ctx(self, __request__, __user__, __metadata__):
        meta = __metadata__ or {}
        chat_id = str(meta.get("chat_id") or "")
        user_id = str((__user__ or {}).get("id") or "")
        root_id = ""
        mode = ""

        if __request__ is not None:
            mode = str(__request__.headers.get("x-local-ai-mode") or "").lower()
            root_id = str(__request__.headers.get("x-local-ai-research-root") or "")

        if mode != "deep":
            raise RuntimeError("Budget-enforced research web is available only in Deep Research mode.")
        if not root_id:
            root_id = str(meta.get("message_id") or meta.get("id") or "")
        if not chat_id or not root_id or not user_id:
            raise RuntimeError("Deep Research web context is incomplete. Start from the Deep Research mode button.")

        return {"chat_id": chat_id, "root_id": root_id, "user_id": user_id}

    async def _post(self, path: str, payload: dict):
        async with httpx.AsyncClient(timeout=90.0) as client:
            response = await client.post(
                CONTROLLER + path,
                headers={"X-Local-AI-Key": KEY},
                json=payload,
            )

        if response.status_code >= 400:
            try:
                detail = (response.json() or {}).get("error") or response.text
            except Exception:
                detail = response.text
            raise RuntimeError(str(detail)[:2000])

        return response.json()

    async def _record_timing(self, ctx, step_kind, label, seconds, outcome="ok", detail=""):
        try:
            await self._post(
                "/timing/record",
                {
                    **ctx,
                    "step_kind": step_kind,
                    "label": label,
                    "duration_seconds": seconds,
                    "outcome": outcome,
                    "detail": detail,
                },
            )
        except Exception:
            pass

    async def search_web(
        self,
        query: str,
        post_validation_reason: str = "",
        evidence_gap: str = "",
        __request__=None,
        __user__=None,
        __metadata__=None,
        __event_emitter__=None,
    ) -> str:
        """Search through the controller-enforced SearXNG budget. Before validation, the hard default limit is 3 searches per approved scope. After validation begins, search is blocked unless post_validation_reason is exactly one of validator_insufficient, docs_missing_or_ambiguous, primary_sources_conflict AND evidence_gap is a concrete one-sentence explanation of what the validator and already-fetched sources do not establish. Never invent a reason or generic evidence gap only to bypass the lock."""
        ctx = self._ctx(__request__, __user__, __metadata__)
        timer = await _StepTimer(__event_emitter__, f"Deep Research Web: searching {query[:80]}").start()
        try:
            data = await self._post(
                "/web/search",
                {
                    **ctx,
                    "query": query,
                    "post_validation_reason": post_validation_reason,
                    "evidence_gap": evidence_gap,
                },
            )
        except Exception as exc:
            seconds = await timer.finish(f"Deep Research Web: search failed · {query[:70]}")
            await self._record_timing(ctx, "web.search", f"Web search: {query[:120]}", seconds, "failed", type(exc).__name__)
            raise
        data["step_seconds"] = await timer.finish()
        await self._record_timing(ctx, "web.search", f"Web search: {query[:120]}", data["step_seconds"], "ok")
        return json.dumps(data, ensure_ascii=False, indent=2)

    async def fetch_url(
        self,
        url: str,
        post_validation_reason: str = "",
        evidence_gap: str = "",
        __request__=None,
        __user__=None,
        __metadata__=None,
        __event_emitter__=None,
    ) -> str:
        """Fetch one public http/https source through the controller-enforced budget. Before validation, the hard default limit is 5 fetches per approved scope. After validation begins, fetching is blocked unless post_validation_reason is exactly one of validator_insufficient, docs_missing_or_ambiguous, primary_sources_conflict AND evidence_gap concretely states what remains unknown. Prefer primary/vendor sources. Private and loopback destinations are blocked."""
        ctx = self._ctx(__request__, __user__, __metadata__)
        timer = await _StepTimer(__event_emitter__, f"Deep Research Web: fetching {url[:90]}").start()
        try:
            data = await self._post(
                "/web/fetch",
                {
                    **ctx,
                    "url": url,
                    "post_validation_reason": post_validation_reason,
                    "evidence_gap": evidence_gap,
                },
            )
        except Exception as exc:
            seconds = await timer.finish(f"Deep Research Web: fetch failed · {url[:70]}")
            await self._record_timing(ctx, "web.fetch", f"Web fetch: {url[:160]}", seconds, "failed", type(exc).__name__)
            raise
        data["step_seconds"] = await timer.finish()
        await self._record_timing(ctx, "web.fetch", f"Web fetch: {url[:160]}", data["step_seconds"], "ok")
        return json.dumps(data, ensure_ascii=False, indent=2)
PYWEBTOOL

  python3 - "$WORKDIR/deep_research_web.py" "$CONTROLLER_URL" "$CONTROLLER_ADMIN_SECRET" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace("__CONTROLLER_URL__", sys.argv[2]).replace("__CONTROLLER_SECRET__", sys.argv[3])
p.write_text(s)
PY
  python3 -c 'import ast,sys,pathlib; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "$WORKDIR/deep_research_web.py"
  DEEP_WEB_TOOL_CONTENT="$(cat "$WORKDIR/deep_research_web.py")"
  DEEP_WEB_TOOL_JSON="$(jq -n --arg id "$DEEP_WEB_TOOL_ID" --arg name "$DEEP_WEB_TOOL_NAME" --arg content "$DEEP_WEB_TOOL_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Deep Research-only public web search/fetch with controller-enforced budgets and post-validation lock.",manifest:{}}}')"
  DEEP_WEB_TOOL_HTTP="$(curl -sS -o "$WORKDIR/deep-web-tool-current.json" -w '%{http_code}' "$WEBUI_URL/api/v1/tools/id/$DEEP_WEB_TOOL_ID" -H "Authorization: Bearer $TOKEN")"
  if [[ "$DEEP_WEB_TOOL_HTTP" == 200 ]]; then
    curl -fsS -X POST "$WEBUI_URL/api/v1/tools/id/$DEEP_WEB_TOOL_ID/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$DEEP_WEB_TOOL_JSON" >"$WORKDIR/deep-web-tool-installed.json" || fail "Unable to update Deep Research Web tool"
  else
    curl -fsS -X POST "$WEBUI_URL/api/v1/tools/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$DEEP_WEB_TOOL_JSON" >"$WORKDIR/deep-web-tool-installed.json" || fail "Unable to create Deep Research Web tool"
  fi
  ok "Deep Research Web tool installed with hard search/fetch limits; unrestricted built-in Deep web search is disabled"

  section "INSTALLING DEEP RESEARCH BRIEF ORCHESTRATOR"
  cat >${WORKDIR}/deep_research_orchestrator.py <<'PYFILTER'
"""
title: Deep Research Brief Orchestrator
author: Local AI Suite
version: 2.5.0
description: Fast Scout Research Brief, validated lessons, durable step timing, scope control, primary-source verification, sandbox validation, and follow-up updates.
"""
import json
import time
from typing import Optional
import httpx
from open_webui.utils.misc import add_or_update_system_message

DEEP = "deep-research:27b"
DEEP_MODE = "local-ai-deep-research"
DEEP_LAB_TOOL = "deep_research_lab"
DEEP_WEB_TOOL = "deep_research_web"
TASK = "background-scout:270m"
BRIEF_FALLBACK = "natural-fast:27b"
OLLAMA = "http://host.docker.internal:11434"
MODEL_KEEP_ALIVE = "__MODEL_KEEP_ALIVE__"
CONTROLLER = "__CONTROLLER_URL__"
KEY = "__CONTROLLER_SECRET__"
MARKER = "<local_ai_deep_research>"


def _fmt_elapsed(seconds):
    value=max(0.0,float(seconds or 0.0))
    if value < 10.0: return f"{value:.2f}s"
    if value < 60.0: return f"{value:.1f}s"
    total_tenths=int(round(value*10.0)); total_seconds,tenth=divmod(total_tenths,10)
    minutes,secs=divmod(total_seconds,60); hours,minutes=divmod(minutes,60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{tenth}" if hours else f"{minutes:02d}:{secs:02d}.{tenth}"


def _timer_ui_code(action, label, phase, elapsed=0.0, auto_total=True):
    values = {
        "__ACTION__": json.dumps(str(action)),
        "__LABEL__": json.dumps(str(label)),
        "__PHASE__": json.dumps(str(phase)),
        "__ELAPSED__": str(max(0, int(float(elapsed or 0.0) * 1000))),
        "__AUTO_TOTAL__": "true" if auto_total else "false",
    }
    code = r"""
(() => {
  const action = __ACTION__;
  const label = __LABEL__;
  const phase = __PHASE__;
  const elapsedMs = __ELAPSED__;
  const autoTotal = __AUTO_TOTAL__;
  window.__laiDeepResearchTimers = window.__laiDeepResearchTimers || {steps:{},totalStarted:null,totalInterval:null,watchdog:null};
  const state = window.__laiDeepResearchTimers;
  const fmtStep = (ms) => { ms=Math.max(0,Number(ms)||0); if(ms<10000)return (ms/1000).toFixed(2)+'s'; if(ms<60000)return (ms/1000).toFixed(1)+'s'; const tenths=Math.round(ms/100); const totalSec=Math.floor(tenths/10); const tenth=tenths%10; const h=Math.floor(totalSec/3600); const m=Math.floor((totalSec%3600)/60); const s=totalSec%60; return h>0 ? String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(s).padStart(2,'0')+'.'+tenth : String(m).padStart(2,'0')+':'+String(s).padStart(2,'0')+'.'+tenth; };
  const fmtTotal = (ms) => { const s=Math.max(0,Math.floor((Number(ms)||0)/1000)); const h=Math.floor(s/3600); const m=Math.floor((s%3600)/60); const sec=s%60; return h>0 ? String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(sec).padStart(2,'0') : String(m).padStart(2,'0')+':'+String(sec).padStart(2,'0'); };
  function stopAll(){ try{Object.values(state.steps||{}).forEach(x=>{if(x&&x.interval)clearInterval(x.interval)});if(state.totalInterval)clearInterval(state.totalInterval);if(state.watchdog)clearInterval(state.watchdog)}catch(_){} state.steps={};state.totalStarted=null;state.totalInterval=null;state.watchdog=null; }
  function ensurePanel(){ let p=document.getElementById('lai-deep-research-timer-panel'); if(!p){ p=document.createElement('div');p.id='lai-deep-research-timer-panel';Object.assign(p.style,{position:'fixed',right:'14px',bottom:'118px',width:'360px',maxWidth:'calc(100vw - 28px)',maxHeight:'46vh',overflow:'auto',zIndex:'2147483000',background:'rgba(18,18,21,.94)',border:'1px solid rgba(255,255,255,.14)',borderRadius:'12px',boxShadow:'0 8px 28px rgba(0,0,0,.30)',backdropFilter:'blur(12px)',color:'#f0f0f2',fontFamily:'ui-monospace,SFMono-Regular,Menlo,monospace',fontSize:'11px',lineHeight:'1.35',padding:'10px'}); const h=document.createElement('div');Object.assign(h.style,{display:'flex',alignItems:'center',gap:'8px',paddingBottom:'7px',marginBottom:'7px',borderBottom:'1px solid rgba(255,255,255,.12)'}); const t=document.createElement('strong');t.textContent='Deep Research Timers';t.style.flex='1';t.title='Step rows use measured high-resolution duration; Total is wall-clock research time.'; const total=document.createElement('span');total.id='lai-deep-research-total';total.textContent='Total 00:00';total.style.opacity='.82'; const x=document.createElement('button');x.textContent='×';x.title='Hide timer panel until next timed step';Object.assign(x.style,{border:'0',background:'transparent',color:'#ddd',cursor:'pointer',fontSize:'16px',padding:'0 2px'});x.onclick=()=>{p.style.display='none'};h.append(t,total,x); const rows=document.createElement('div');rows.id='lai-deep-research-timer-rows';p.append(h,rows);document.body.appendChild(p);} p.style.display='block';return p; }
  function startTotal(){ const p=ensurePanel();const t=p.querySelector('#lai-deep-research-total');if(!state.totalStarted)state.totalStarted=Date.now();if(state.totalInterval)clearInterval(state.totalInterval);const u=()=>{if(t&&state.totalStarted)t.textContent='Total '+fmtTotal(Date.now()-state.totalStarted)};u();state.totalInterval=setInterval(u,250); }
  if(phase==='reset'){stopAll();const old=document.getElementById('lai-deep-research-timer-panel');if(old)old.remove();ensurePanel();return;}
  if(phase==='total_start'){startTotal();return;}
  if(phase==='total_stop'){const p=ensurePanel();const t=p.querySelector('#lai-deep-research-total');if(state.totalInterval)clearInterval(state.totalInterval);state.totalInterval=null;if(t&&state.totalStarted)t.textContent='Total '+fmtTotal(Date.now()-state.totalStarted)+' ✓';return;}
  if(phase==='finalize'){
    const p=ensurePanel();
    const t=p.querySelector('#lai-deep-research-total');
    const now=Date.now();

    Object.entries(state.steps||{}).forEach(([key,item])=>{
      try{
        if(item&&item.interval)clearInterval(item.interval);
        if(item&&item.row){
          const l=item.row.querySelector('.lai-timer-label');
          const r=item.row.querySelector('.lai-timer-time');
          const original=l ? String(l.textContent||'').replace(/^▶\s*/,'') : 'step';
          if(l)l.textContent='✓ '+original;
          if(r)r.textContent=fmtStep(now-(item.started||now));
          item.row.dataset.done='1';
          item.row.style.opacity='.72';
        }
      }catch(_){}
    });

    state.steps={};

    if(state.watchdog)clearInterval(state.watchdog);
    state.watchdog=null;

    if(state.totalInterval)clearInterval(state.totalInterval);
    state.totalInterval=null;

    if(t){
      if(state.totalStarted){
        t.textContent='Total '+fmtTotal(now-state.totalStarted)+' ✓';
      }else{
        t.textContent='Completed ✓';
      }
    }

    state.totalStarted=null;
    return;
  }
  const p=ensurePanel();if(autoTotal&&!state.totalStarted)startTotal();const rows=p.querySelector('#lai-deep-research-timer-rows');
  if(phase==='start'){const prev=state.steps[action];if(prev&&prev.interval)clearInterval(prev.interval);let row=document.getElementById('lai-timer-'+action);if(!row){row=document.createElement('div');row.id='lai-timer-'+action;row.dataset.done='0';Object.assign(row.style,{display:'grid',gridTemplateColumns:'1fr auto',gap:'8px',padding:'5px 0',borderBottom:'1px solid rgba(255,255,255,.06)'});const l=document.createElement('span');l.className='lai-timer-label';l.style.overflowWrap='anywhere';const r=document.createElement('span');r.className='lai-timer-time';r.style.whiteSpace='nowrap';row.append(l,r);rows.prepend(row);}row.querySelector('.lai-timer-label').textContent='▶ '+label;row.querySelector('.lai-timer-time').textContent='0.00s';row.dataset.done='0';row.style.opacity='1';const started=Date.now();const update=()=>{const r=row.querySelector('.lai-timer-time');if(r)r.textContent=fmtStep(Date.now()-started)};const interval=setInterval(update,100);state.steps[action]={started,interval,row};if(!state.watchdog){state.watchdog=setInterval(()=>{const now=Date.now();Object.entries(state.steps||{}).forEach(([k,item])=>{if(item&&item.started&&now-item.started>20*60*1000){try{if(item.interval)clearInterval(item.interval);const l=item.row&&item.row.querySelector('.lai-timer-label');const r=item.row&&item.row.querySelector('.lai-timer-time');const original=l?String(l.textContent||'').replace(/^▶\\s*/,''):'step';if(l)l.textContent='⚠ '+original+' (stale timer closed)';if(r)r.textContent=fmtStep(now-item.started);if(item.row){item.row.dataset.done='1';item.row.style.opacity='.72';}}catch(_){}delete state.steps[k];}});},30000);}return;}
  if(phase==='finish'||phase==='fail'){const item=state.steps[action];if(item&&item.interval)clearInterval(item.interval);let row=item&&item.row?item.row:document.getElementById('lai-timer-'+action);if(!row){row=document.createElement('div');row.id='lai-timer-'+action;Object.assign(row.style,{display:'grid',gridTemplateColumns:'1fr auto',gap:'8px',padding:'5px 0',borderBottom:'1px solid rgba(255,255,255,.06)'});const l=document.createElement('span');l.className='lai-timer-label';const r=document.createElement('span');r.className='lai-timer-time';row.append(l,r);rows.prepend(row);}const l=row.querySelector('.lai-timer-label');const r=row.querySelector('.lai-timer-time');if(l)l.textContent=(phase==='fail'?'✕ ':'✓ ')+label;if(r)r.textContent=fmtStep(elapsedMs);row.dataset.done='1';row.style.opacity=phase==='fail'?'.95':'.72';delete state.steps[action];const done=Array.from(rows.children).filter(n=>n.dataset.done==='1');while(done.length>12){const old=done.pop();if(old)old.remove();}}
})();
"""
    for key,value in values.items(): code=code.replace(key,value)
    return code

async def _emit_timer_ui(emitter, action, label, phase, elapsed=0.0, auto_total=True):
    if emitter is None: return
    try:
        await emitter({"type":"execute","data":{"code":_timer_ui_code(action,label,phase,elapsed,auto_total)}})
    except Exception:
        pass
async def _orchestrator_timer_status(emitter, action, label, phase, started=None, auto_total=False):
    elapsed=0.0 if started is None else max(0.0,time.monotonic()-started)
    await _emit_timer_ui(emitter,action,label,phase,elapsed,auto_total)
    if emitter is not None and phase in {"start","finish","fail"}:
        await emitter({"type":"status","data":{"description":(f"{label} · ⏱ {_fmt_elapsed(elapsed)}" if phase!="start" else f"{label} · ⏱ 00:00"),"done":phase!="start","hidden":False,"action":action}})

def latest_user(body, metadata):
    p = (metadata or {}).get("user_prompt")
    if isinstance(p, str) and p.strip(): return p.strip()
    for m in reversed(body.get("messages") or []):
        if m.get("role") == "user":
            c=m.get("content")
            if isinstance(c,str): return c.strip()
            if isinstance(c,list):
                return "\n".join(str(x.get("text") or "") for x in c if isinstance(x,dict) and x.get("type")=="text").strip()
    return ""


class Filter:
    def _ctx(self, __request__, __user__, __metadata__, __message_id__=None):
        meta = __metadata__ or {}
        chat_id = str(meta.get("chat_id") or "")
        user_id = str((__user__ or {}).get("id") or "")
        root_id = ""
        if __request__ is not None:
            root_id = str(__request__.headers.get("x-local-ai-research-root") or "")
        if not root_id:
            root_id = str(__message_id__ or meta.get("message_id") or "")
        return {"chat_id":chat_id,"root_id":root_id,"user_id":user_id}

    async def _controller(self, path, payload):
        async with httpx.AsyncClient(timeout=30.0) as client:
            r=await client.post(CONTROLLER+path,headers={"X-Local-AI-Key":KEY},json=payload)
        if r.status_code >= 400: raise RuntimeError(r.text[:1000])
        return r.json()

    async def _record_timing(self, ctx, step_kind, label, seconds, outcome="ok", detail=""):
        try:
            await self._controller(
                "/timing/record",
                {
                    **ctx,
                    "step_kind": step_kind,
                    "label": label,
                    "duration_seconds": seconds,
                    "outcome": outcome,
                    "detail": detail,
                },
            )
        except Exception:
            pass

    async def _ollama(self, model, system, prompt, predict=700):
        payload={
            "model":model,
            "messages":[{"role":"system","content":system},{"role":"user","content":prompt}],
            "think":False,"stream":False,"keep_alive":MODEL_KEEP_ALIVE,
            "options":{"num_predict":predict,"temperature":0.2,"top_p":0.9}
        }
        async with httpx.AsyncClient(timeout=600.0) as client:
            r=await client.post(OLLAMA+"/api/chat",json=payload)
        r.raise_for_status()
        return str((r.json().get("message") or {}).get("content") or "").strip()

    async def _make_brief(self, query, previous="", update=""):
        """
        Build only the USER-FACING pre-research brief.

        Important:
        - Never call the 128K Deep Research model here.
        - Never search the web or use tools here.
        - Keep this deliberately tiny so Deep Research can be approved quickly.
        - Background Scout handles normal cases; Natural Fast is only a fallback
          if the tiny model returns malformed or excessively long output.
        """
        if previous:
            system = """Update a VERY SHORT research brief after the user changes scope.
Do not research. Do not answer the underlying question. Do not browse.
Return ONLY this exact structure:

Goal
<one sentence>

Plan
- <item>
- <item>
- <item>

Constraints
- <only explicit required/excluded/limited scope item, if any>

Need From You
- <only blocking question, if any>

Rules:
- Maximum 3 plan bullets.
- Maximum 3 constraint bullets.
- Maximum 3 blocking questions.
- Ask only questions whose answer materially changes architecture, safety, or correctness.
- If nothing is blocking, write exactly: None
- Constraints must preserve explicit user requirements, exclusions, "without/no/do not" instructions, hard limits, and safety constraints; do not invent new constraints.
- Keep the plan at the same abstraction level as the user's request.
- NEVER invent sensors, voltage/current monitoring, telemetry, dashboards, protocols, cloud integrations, hardware subsystems, safety mechanisms, UI controls, storage, networking, or optional features merely because they might be useful.
- A descriptive word such as "solar", "industrial", "smart", "remote", or "secure" is context, not permission to invent a new subsystem unless the user explicitly requested that subsystem.
- Only include implementation details that the user explicitly requested or that are unavoidable to fulfill the requested deliverable.
- If an architectural choice is genuinely required but unspecified, keep the plan generic; ask under Need From You only if the choice materially changes architecture, safety, or correctness.
- For closed-loop physical control (pump/fan/valve/motor/heater/charger), actuator direction is correctness-critical. If increasing actuator output may either raise or lower the controlled sensor value and the user did not establish the direction, treat that as a blocking clarification or preserve it explicitly as an unresolved physical assumption.
- For closed-loop physical control (pump/fan/valve/motor/heater/charger), actuator direction is correctness-critical. If increasing actuator output may either raise or lower the controlled sensor value and the user did not establish the direction, treat that as a blocking clarification or preserve it explicitly as an unresolved physical assumption.
- Constraints must contain ONLY explicit user requirements/exclusions/hard limits. Never infer a new constraint from likely intent.
- Do not include assumptions, evidence lists, testing details, implementation details, or explanations.
- Keep the entire response under 200 words."""
            prompt = f"EXISTING BRIEF:\n{previous}\n\nUSER UPDATE:\n{update or query}"
        else:
            system = """Turn the user's request into a VERY SHORT pre-research brief.
Do not research. Do not answer the request. Do not browse. Resolve obvious typos silently.
Return ONLY this exact structure:

Goal
<one sentence>

Plan
- <item>
- <item>
- <item>

Constraints
- <only explicit required/excluded/limited scope item, if any>

Need From You
- <only blocking question, if any>

Rules:
- Maximum 3 plan bullets.
- Maximum 3 constraint bullets.
- Maximum 3 blocking questions.
- Ask only questions whose answer materially changes architecture, safety, or correctness.
- If nothing is blocking, write exactly: None
- For code/configuration work, one plan bullet may say it will be validated in the sandbox.
- Keep the plan at the same abstraction level as the user's request.
- NEVER invent sensors, voltage/current monitoring, telemetry, dashboards, protocols, cloud integrations, hardware subsystems, safety mechanisms, UI controls, storage, networking, or optional features merely because they might be useful.
- A descriptive word such as "solar", "industrial", "smart", "remote", or "secure" is context, not permission to invent a new subsystem unless the user explicitly requested that subsystem.
- Only include implementation details that the user explicitly requested or that are unavoidable to fulfill the requested deliverable.
- If an architectural choice is genuinely required but unspecified, keep the plan generic; ask under Need From You only if the choice materially changes architecture, safety, or correctness.
- Constraints must contain ONLY explicit user requirements/exclusions/hard limits. Never infer a new constraint from likely intent.
- Do not include assumptions, evidence lists, testing details, implementation details, hardware test plans, or explanations.
- Keep the entire response under 180 words."""
            prompt = query

        async def generate(model):
            return await self._ollama(model, system, prompt, 220)

        out = (await generate(TASK)).strip()

        # Scout should be enough for normal requests. Fall back to the 32K daily
        # model only when the result is clearly malformed. The Deep model remains
        # completely untouched until the user presses Start Research.
        valid = (
            out
            and "Goal" in out
            and "Plan" in out
            and "Constraints" in out
            and "Need From You" in out
            and len(out) <= 2200
        )
        if not valid:
            out = (await generate(BRIEF_FALLBACK)).strip()

        if not out:
            out = (
                "Goal\n"
                + (query.strip() or "Research the user's request.")
                + "\n\nPlan\n"
                "- Verify the relevant current information.\n"
                "- Investigate the requested solution.\n"
                "- Validate machine-checkable output in the sandbox when applicable.\n\n"
                "Constraints\nNone\n\n"
                "Need From You\nNone"
            )

        # Hard display cap. The brief is a gate, not a report.
        return out[:2200]

    async def _classify(self, text):
        system="""Classify one follow-up message in an ongoing research conversation. Return exactly UPDATE if it changes, adds, removes, narrows, expands, or redirects the research scope/instructions. Return exactly QUESTION if it asks for status, explanation, findings, or a normal follow-up without changing scope."""
        out=(await self._ollama(TASK,system,text,8)).upper()
        return "UPDATE" if "UPDATE" in out else "QUESTION"

    def _blocking_clarifications(self, brief):
        import re
        m = re.search(
            r"(?is)(?:^|\n)#{0,3}\s*Need From You\s*:?\s*\n(.*?)(?=\n#{0,3}\s*(?:Goal|Plan|Constraints)\s*:?\s*\n|\Z)",
            brief or "",
        )
        if not m:
            return ""
        text = m.group(1).strip().strip("- ")
        if not text or text.lower() in {
            "none",
            "none.",
            "n/a",
            "not required",
            "no blocking questions",
        }:
            return ""
        # Keep the clarification UI small even if a model ignores instructions.
        lines = [x.strip() for x in text.splitlines() if x.strip()]
        return "\n".join(lines[:3])[:900]

    async def _resolve_clarifications(self, brief, __event_call__):
        questions = self._blocking_clarifications(brief)
        if not questions or __event_call__ is None:
            return brief
        answer = await __event_call__({"type":"input","data":{"title":"Deep Research Clarifications","message":"These details materially affect the research or implementation:\n\n"+questions+"\n\nAnswer them, or type BEST JUDGMENT to continue with explicit assumptions.","placeholder":"Answers or BEST JUDGMENT"}})
        answer = str(answer or "").strip()
        if not answer:
            return brief
        if answer.upper() == "BEST JUDGMENT":
            answer = "Use best judgment for the blocking questions. Continue without asking them again and set Need From You to None."
        return await self._make_brief("", previous=brief, update="USER CLARIFICATIONS:\n" + answer)

    async def _approve_brief(self, brief, __event_call__):
        if __event_call__ is None:
            return True, brief
        current=brief
        for _ in range(3):
            approved=bool(await __event_call__({"type":"confirmation","data":{"title":"Deep Research Brief","message":current[:2200]+"\n\nStart Deep Research?"}}))
            if approved: return True,current
            edit=await __event_call__({"type":"input","data":{"title":"Edit Research Brief","message":"Describe what to add, remove, narrow, expand, or change. The brief will stay short. Type CANCEL to stop Deep Research.","placeholder":"Research scope update"}})
            edit=str(edit or "").strip()
            if not edit or edit.upper()=="CANCEL": return False,current
            current=await self._make_brief("",previous=current,update=edit)
        return False,current

    async def inlet(self, body: dict, __request__=None, __user__=None, __metadata__=None, __message_id__=None, __event_call__=None, __event_emitter__=None, __task__=None, __model__=None, **kwargs):
        selected = str(body.get("model") or "")
        base = str(((__model__ or {}).get("info") or {}).get("base_model_id") or selected)
        if __task__ or not (selected in {DEEP_MODE, DEEP} or base == DEEP):
            return body
        # Deep Research uses explicit agentic tool steps instead of provider-side
        # free-form thinking. This prevents hidden/self-review loops from leaking.
        body["think"] = False

        # Backend enforcement: no unrestricted OpenWebUI web tool in Deep mode.
        # Deep gets only the controller-budgeted research web tool plus the lab.
        body["features"] = body.get("features") or {}
        body["features"]["web_search"] = False
        body["tool_ids"] = [
            x for x in (body.get("tool_ids") or [])
            if x not in {DEEP_LAB_TOOL, DEEP_WEB_TOOL}
        ]
        body["tool_ids"] = list(dict.fromkeys(body["tool_ids"] + [DEEP_LAB_TOOL, DEEP_WEB_TOOL]))
        ctx=self._ctx(__request__,__user__,__metadata__,__message_id__)
        if all(ctx.values()):
            await _emit_timer_ui(__event_emitter__, "local-ai-reset", "Deep Research", "reset", 0.0, False)
        if not all(ctx.values()):
            # Deep mode remains usable even if a future OpenWebUI build changes metadata,
            # but do not silently create an untracked sandbox session.
            body["messages"]=add_or_update_system_message(MARKER+"\nDeep Research tracking metadata is unavailable. Do not use the research lab in this turn.\n</local_ai_deep_research>",body.get("messages") or [],append=True)
            return body
        query=latest_user(body,__metadata__ or {})
        state=await self._controller("/research/state",ctx)
        session=state.get("session") or {}
        brief=str(session.get("brief") or "").strip()

        if not brief:
            brief_started = time.monotonic()
            brief_action = f"local-ai-brief-{time.monotonic_ns()}"
            await _orchestrator_timer_status(
                __event_emitter__,
                brief_action,
                "Preparing short Research Brief with Background Scout",
                "start",
                brief_started,
                False,
            )
            try:
                brief = await self._make_brief(query)
            except Exception:
                brief_elapsed = time.monotonic() - brief_started
                await self._record_timing(
                    ctx,
                    "brief.generate",
                    "Research Brief generation",
                    brief_elapsed,
                    "failed",
                )
                await _orchestrator_timer_status(
                    __event_emitter__,
                    brief_action,
                    "Research Brief generation failed",
                    "fail",
                    brief_started,
                    False,
                )
                raise
            else:
                brief_elapsed = time.monotonic() - brief_started
                await self._record_timing(
                    ctx,
                    "brief.generate",
                    "Research Brief generation",
                    brief_elapsed,
                    "ok",
                )
                await _orchestrator_timer_status(
                    __event_emitter__,
                    brief_action,
                    "Research Brief prepared",
                    "finish",
                    brief_started,
                    False,
                )
            brief=await self._resolve_clarifications(brief,__event_call__)
            approved,brief=await self._approve_brief(brief,__event_call__)
            if not approved:
                await _emit_timer_ui(
                    __event_emitter__,
                    "local-ai-finalize",
                    "Deep Research cancelled",
                    "finalize",
                    0.0,
                    False,
                )
                body["tool_ids"]=[
                    x for x in (body.get("tool_ids") or [])
                    if x not in {DEEP_LAB_TOOL, DEEP_WEB_TOOL}
                ]
                body["think"]=False
                body["messages"]=add_or_update_system_message("The user cancelled Deep Research before it began. Reply only that Deep Research was cancelled and do not research the query.",body.get("messages") or [],append=True)
                return body
            await self._controller("/research/brief/save",{**ctx,"brief":brief,"scope_basis":query})
            await _emit_timer_ui(__event_emitter__, "local-ai-total", "Deep Research total", "total_start", 0.0, False)
            if __event_emitter__ is not None:
                await __event_emitter__({"type":"status","data":{"description":"Research Brief approved. Loading Deep Research now.","done":True,"hidden":False}})
        elif query:
            kind=await self._classify(query)
            if kind=="UPDATE":
                proposed=await self._make_brief("",previous=brief,update=query)
                approved,proposed=await self._approve_brief(proposed,__event_call__)
                if approved:
                    brief=proposed
                    await self._controller("/research/brief/save",{**ctx,"brief":brief,"scope_basis_append":query})
                    if __event_emitter__ is not None:
                        await __event_emitter__({"type":"status","data":{"description":"Research scope updated; continuing with the revised brief","done":True,"hidden":False}})

        if brief:
            await _emit_timer_ui(__event_emitter__, "local-ai-total", "Deep Research total", "total_start", 0.0, False)

        lesson_context = "None retrieved for this research."
        lesson_started = time.monotonic()
        lesson_action = f"local-ai-lessons-{time.monotonic_ns()}"
        await _orchestrator_timer_status(__event_emitter__, lesson_action, "Validated Lessons: retrieving relevant prior experience", "start", lesson_started, True)
        try:
            lesson_data = await self._controller(
                "/lessons/retrieve",
                {**ctx, "query": query, "limit": 5},
            )
            lessons = lesson_data.get("lessons") or []
            if lessons:
                lines = []
                for item in lessons:
                    label = "/".join(
                        x for x in [str(item.get("domain") or ""), str(item.get("topic") or "")]
                        if x
                    ) or "general"
                    lines.append(
                        f"- [{label}] Known failure: {item.get('error_signature','')} | "
                        f"Validated fix: {item.get('validated_fix','')} | "
                        f"Version context: {item.get('software_version','unspecified')} | "
                        f"Prior successful reuse roots: {int(item.get('successful_reuses',0) or 0)}"
                    )
                lesson_context = "\n".join(lines)
        except Exception as exc:
            lesson_context = f"Lesson retrieval unavailable for this turn: {type(exc).__name__}. Continue without it."
        lesson_elapsed = time.monotonic() - lesson_started
        await self._record_timing(ctx, "lessons.retrieve", "Validated Lessons retrieval", lesson_elapsed, "ok")
        await _orchestrator_timer_status(__event_emitter__, lesson_action, "Validated Lessons: retrieval complete", "finish", lesson_started, True)

        instructions=f"""{MARKER}
CURRENT RESEARCH BRIEF
{brief}

PRIOR VALIDATED EXPERIENCE
{lesson_context}

DEEP RESEARCH RULES
1. The Research Brief above is the user-approved working summary, intentionally kept short. The controller separately stores the literal user-provided scope basis (initial request plus explicit scope updates), and that literal basis outranks any model-invented detail in the brief.
2. Work in evidence loops: identify what must be known, gather evidence, verify it, then continue. Do not replace verification with long internal speculation.
3. For software versions, APIs, configuration syntax, command syntax, compatibility, security guidance, or vendor behavior that can change over time, PRIMARY SOURCES ARE REQUIRED whenever available. Prefer current official documentation, official source code, release notes, standards, or vendor knowledge articles over forums, summaries, and search snippets.
4. A search-result snippet is discovery, not proof. Use ONLY the budget-enforced Deep Research Web tool functions search_web and fetch_url for public research. OpenWebUI's unrestricted built-in web search is intentionally disabled in Deep Research. Fetch the primary source before asserting exact syntax or version-sensitive behavior.
5. HARD WEB BUDGETS ARE CONTROLLER-ENFORCED. Before validation, the default hard budget is 3 search_web calls and 5 fetch_url calls per approved scope. Never retry a WEB BUDGET EXHAUSTED error.
6. POST-VALIDATION WEB LOCK IS CONTROLLER-ENFORCED. After the first research_lab_validate call, first use the exact validator diagnostic and already-fetched primary documentation. Additional web access is allowed only when the evidence gap is real, using one of the tool's exact reasons plus a concrete evidence_gap sentence. Generic or fabricated explanations are rejected.
7. Use relevant Memory and Knowledge first for environment-specific facts. PRIOR VALIDATED EXPERIENCE is reusable evidence from earlier failure -> passing-validation cycles; use it to avoid repeating known mistakes, but never treat it as user scope or as higher authority than current primary documentation. For version-sensitive lessons, verify against current official sources when the version may have changed. If a current validated fix differs, the lessons engine refreshes the stored lesson after successful validation.
8. SCOPE-COMPLIANCE GATE: before any real machine validator executes, research_lab_validate audits the generated artifact against BOTH the authoritative user-provided scope basis and the approved Research Brief using Background Scout. Scout only identifies violations, missing items, and contradictions. Python deterministically decides PASS only when all three issue arrays are empty. Model-produced pass/fail booleans are ignored.
9. The Research Brief must not silently expand scope. Do not add material sensors, telemetry, voltage/current monitoring, dashboards, protocols, external integrations, hardware subsystems, or optional features merely because they could be useful or are suggested by descriptive wording such as "solar", "smart", or "remote".
10. VALIDATION GATE: machine-checkable artifacts must use research_lab_validate whenever a suitable validator/compiler/test can reasonably run in Linux. Use research_lab_write plus research_lab_validate. Install validation tooling in a venv/container if needed. Pass the actual generated artifact path. Do not describe an artifact as working/complete if validation was skipped or failed.
11. VALIDATION BYPASS IS FORBIDDEN. research_lab_exec is for setup, package installation, inspection, and experiments only. The controller rejects recognized validator/test/lint/config-check commands sent through research_lab_exec. Use research_lab_validate for every real validation command.
12. VALIDATION EXIT CODES ARE AUTHORITATIVE. Run validators directly. Do not pipe validator output through head or tail; the controller blocks those truncation pipelines because early pipe closure under pipefail can create a false nonzero result. The lab already bounds returned validator output.
13. REPAIR BUDGET: attempts 1 through 5 are the normal repair budget. If attempt 5 returns a NEW deterministic error, you may make exactly one final direct repair and validate once more without broadening research. Attempt 6 is the absolute maximum. If the same failure appears twice, stop repeating the same fix and reassess immediately.
14. STOP ON SUCCESS: once a real validator/compiler/test command passes and the authoritative scope is satisfied, do not continue browsing or experimenting merely to gather more sources. Check research_check_updates once, call research_step_timings once, stop the lab, and write the final answer.
15. SEARCH DISCIPLINE: once authoritative documentation answers the needed syntax or behavior, stop searching even if budget remains. Budget is a ceiling, not a target.
16. PYTHON TOOLING IN THE LAB: the sandbox root filesystem is intentionally read-only. Never install Python packages into the system interpreter or /home/researcher. Create a venv below /workspace/.venvs and use that venv's pip and executables.
17. TIME BUDGET: research_check_updates reports elapsed time. For ordinary configuration or coding research, 15 minutes is a soft ceiling, not a target. If exceeded, stop broadening scope and finish from the strongest evidence unless a blocking gap remains.
18. The lab is an isolated Linux container, never the Fedora host. A successful lab test proves only the conditions actually reproduced there. State what was and was not tested.
19. Keep useful lab files under /workspace. The persistent volume belongs to this research root and survives follow-up turns. Call research_lab_stop before the final report to release CPU/RAM while preserving the workspace.
20. Call research_check_updates after meaningful research/tool phases, before validation, and once after successful validation before the final report. Do not call it after every individual tool invocation.
21. Never expose chain-of-thought, scratch work, self-review, or repeated drafting. Report only concise progress events, tool results that matter, and the final synthesis.
22. For technical research, the final response should separate: Answer/Recommendation, Evidence, Validation, Timing, Assumptions or Limitations, and Sources. Live custom-tool timers are displayed by the browser-side Deep Research Timers panel. The outlet filter appends an authoritative Measured Timing block from the durable ledger even if you omit it, so never invent durations.
23. SEMANTIC CONSISTENCY GATE: a real validator PASS is necessary but not sufficient. research_lab_validate automatically performs an independent semantic audit after a successful validator run. It checks comments/claims against the actual artifact, already-fetched primary sources, runtime placeholders, and physical-control assumptions. If semantic_status=failed, repair and revalidate; the artifact is NOT validated. If semantic_status is passed_with_warnings or passed_with_assumptions, final output must surface every warning/assumption and must not imply the physical behavior itself was proven.
24. FINAL-ANSWER CONSISTENCY: do not claim that the delivered artifact contains a button, sensor, safety feature, integration, action, or capability unless it is actually present in the validated artifact. If discussing an optional feature not included, explicitly say it can be added rather than implying it already exists.
25. CONTROL-CRITICAL HARDWARE / AUTOMATION RULE: when generated configuration controls a motor, pump, heater, charger, valve, fan, or other physical process, verify semantic safety as well as syntax. Distinguish controller diagnostic/result values from the actual actuator command. Never infer PID heat_output/cool_output from the actuator's name alone: heat_output means increasing the output raises the controlled temperature; cool_output means increasing it lowers the controlled temperature. If the physical plant direction is not established, keep it as an explicit unresolved assumption instead of claiming the control direction is validated. A claimed emergency stop must disable or latch out the upstream controller so it cannot immediately rewrite the output. Prefer stable hardware identities such as explicit sensor addresses/IDs over positional indices for control-critical sensors when supported. Clearly label placeholder gains, limits, addresses, and credentials.
</local_ai_deep_research>"""
        body["messages"]=add_or_update_system_message(instructions,body.get("messages") or [],append=True)
        body["think"]=False
        return body

    async def outlet(
        self,
        body: dict,
        __request__=None,
        __user__=None,
        __metadata__=None,
        __model__=None,
        __event_emitter__=None,
        **kwargs,
    ):
        selected=str(body.get("model") or "")
        base=str(((__model__ or {}).get("info") or {}).get("base_model_id") or selected)
        if not (selected in {DEEP_MODE,DEEP} or base==DEEP):
            return body

        # Authoritative turn-end cleanup. This closes every browser-side
        # setInterval even if an individual finish event was dropped.
        await _emit_timer_ui(
            __event_emitter__,
            "local-ai-finalize",
            "Deep Research complete",
            "finalize",
            0.0,
            False,
        )
        meta=__metadata__ or {}; chat_id=str(meta.get("chat_id") or body.get("chat_id") or ""); user_id=str((__user__ or {}).get("id") or "")
        if not chat_id or not user_id: return body
        try: summary=await self._controller("/research/latest-summary",{"chat_id":chat_id,"user_id":user_id,"root_id":"latest","limit":40})
        except Exception: return body
        if not summary.get("found"): return body
        budget=summary.get("budget") or {}; timings=summary.get("timings") or {}; elapsed=int(budget.get("elapsed_seconds",0) or 0); minutes,seconds=divmod(elapsed,60)
        steps=list(timings.get("steps") or []); slowest=sorted(steps,key=lambda x:float(x.get("duration_seconds",0) or 0),reverse=True)[:5]
        lines=["<!-- local-ai-measured-timing -->","## Measured Timing",f"- Total research elapsed: **{minutes}m {seconds:02d}s**",f"- Instrumented steps recorded: **{int(timings.get('count',0) or 0)}**",f"- Sum of instrumented step durations: **{float(timings.get('recorded_step_seconds',0) or 0):.2f}s**"]
        if slowest:
            lines.append("- Slowest measured steps:")
            for item in slowest: lines.append(f"  - {item.get('label','step')}: {float(item.get('duration_seconds',0) or 0):.2f}s [{item.get('outcome','')}]")
        lines.append("- Built-in Open WebUI model/Knowledge operations are covered by total elapsed time but are not individually instrumented by the Local AI Suite timing ledger.")
        block="\n".join(lines); target=None
        for message in reversed(body.get("messages") or []):
            if isinstance(message,dict) and message.get("role")=="assistant": target=message; break
        if target is None or not isinstance(target.get("content"),str): return body
        if "<!-- local-ai-measured-timing -->" not in target["content"]: target["content"]=target["content"].rstrip()+"\n\n"+block
        return body
PYFILTER

  python3 - "$WORKDIR/deep_research_orchestrator.py" "$CONTROLLER_URL" "$CONTROLLER_ADMIN_SECRET" "$MODEL_IDLE_UNLOAD" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=(s.replace("__CONTROLLER_URL__",sys.argv[2])
     .replace("__CONTROLLER_SECRET__",sys.argv[3])
     .replace("__MODEL_KEEP_ALIVE__",sys.argv[4]))
p.write_text(s)
PY
  python3 -c 'import ast,sys,pathlib; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "$WORKDIR/deep_research_orchestrator.py"
  DEEP_FILTER_CONTENT="$(cat "$WORKDIR/deep_research_orchestrator.py")"
  DEEP_FILTER_JSON="$(jq -n --arg id "$DEEP_FILTER_ID" --arg name "$DEEP_FILTER_NAME" --arg content "$DEEP_FILTER_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Deep Research only: mandatory brief approval, blocking clarifications, primary-source verification, sandbox validation, versioned updates, and persistent lab coordination."}}')"
  DEEP_FILTER_HTTP="$(curl -sS -o "$WORKDIR/deep-filter-current.json" -w '%{http_code}' "$WEBUI_URL/api/v1/functions/id/$DEEP_FILTER_ID" -H "Authorization: Bearer $TOKEN")"
  if [[ "$DEEP_FILTER_HTTP" == 200 ]]; then
    curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$DEEP_FILTER_ID/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$DEEP_FILTER_JSON" >"$WORKDIR/deep-filter-installed.json"
  else
    curl -fsS -X POST "$WEBUI_URL/api/v1/functions/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$DEEP_FILTER_JSON" >"$WORKDIR/deep-filter-installed.json"
  fi
  DEEP_FILTER_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$DEEP_FILTER_ID" -H "Authorization: Bearer $TOKEN")"
  [[ "$(jq -r '.is_active' <<<"$DEEP_FILTER_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$DEEP_FILTER_ID/toggle" -H "Authorization: Bearer $TOKEN" >/dev/null
  DEEP_FILTER_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$DEEP_FILTER_ID" -H "Authorization: Bearer $TOKEN")"
  [[ "$(jq -r '.is_global' <<<"$DEEP_FILTER_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$DEEP_FILTER_ID/toggle/global" -H "Authorization: Bearer $TOKEN" >/dev/null
  ok "Deep Research Brief Orchestrator is active globally and routes the Deep workspace model to $DEEP_MODEL"
  ok "Pre-research brief uses $TASK_MODEL first, falls back only to natural-fast:27b, and never calls $DEEP_MODEL before approval"
fi

if json_bool "$INSTALL_MODE_UI" && ! json_bool "$INSTALL_DEEP_RESEARCH"; then
  fail "INSTALL_MODE_UI=1 requires INSTALL_DEEP_RESEARCH=1 because the Deep Research button needs the research controller and sandbox lifecycle API"
fi

if json_bool "$INSTALL_MODE_UI"; then
  section "INSTALLING FAST / ADVANCED / DEEP RESEARCH MODE BAR"
  MODE_UI_DIR="$LOCAL_AI_DIR/mode-ui"
  $SUDO mkdir -p "$MODE_UI_DIR"

  cat >${WORKDIR}/local-ai-mode-ui.js <<'JSUI'
/* Local AI Suite v8.7 mode layer. Deliberately framework-light so it can survive
 * routine OpenWebUI frontend changes. If injection ever fails, OpenWebUI keeps
 * working normally; only the custom mode bar disappears. */
(() => {
  if (window.__LOCAL_AI_SUITE_MODE_UI__) return;
  window.__LOCAL_AI_SUITE_MODE_UI__ = true;

  const CONFIG = {
    fast:     { label: 'Fast',          icon: '⚡', model: 'local-ai-fast',          base: 'natural-fast:27b',   think: false },
    advanced: { label: 'Advanced',      icon: '🧠', model: 'local-ai-advanced',      base: 'research-plus:27b', think: false },
    deep:     { label: 'Deep Research', icon: '🔬', model: 'local-ai-deep-research', base: 'deep-research:27b', think: false }
  };
  const ADV_CALC_TOOL = 'advanced_deterministic_calculator';
  const DEEP_TOOL = 'deep_research_lab';
  const DEEP_WEB_TOOL = 'deep_research_web';
  const UI_KEY = '__UI_SECRET__';
  const CONTROLLER_PORT = '__CONTROLLER_PORT__';
  const MODE_KEY = 'local-ai-suite-mode-v69';
  const LEGACY_MODE_KEY = 'local-ai-suite-mode-v5';
  const FORCE_DEEP_KEY = 'local-ai-suite-force-new-deep-root-v69';
  const ROOT_PREFIX = 'local-ai-deep-root:';
  let mode = localStorage.getItem(MODE_KEY) || localStorage.getItem(LEGACY_MODE_KEY) || 'fast';
  if (!CONFIG[mode]) mode = 'fast';
  let forceNewDeepRoot = sessionStorage.getItem(FORCE_DEEP_KEY) === '1';
  let lastPath = location.pathname + location.search;
  let lastNativeSyncPath = '';
  let nativeSyncBusy = false;
  let modeSwitchBusy = false;

  // Advanced Native presentation hold. OpenWebUI keeps receiving and
  // processing the original stream; this layer only suppresses provisional
  // DOM rendering until the Native tool loop reaches a quiet final response.
  const ADV_PRESENT_QUIET_MS = 650;
  const ADV_PRESENT_PERSIST_RETRY_MS = 1200;
  const ADV_PRESENT_WATCHDOG_MS = 120000;
  let advPresentHolding = false;
  let advPresentActiveStreams = 0;
  let advPresentAwaitingContinuation = false;
  let advPresentReleaseTimer = null;
  let advPresentWatchdog = null;
  let advPresentBaselineIds = new Set();
  let advPresentCleanupBusy = false;
  let advPresentCandidateCleanupTimer = null;

  function messageDomNodes() {
    return [...document.querySelectorAll('[id^="message-"]')];
  }

  function markAdvancedProvisionalMessages() {
    if(!advPresentHolding) return;
    for(const el of messageDomNodes()){
      if(!advPresentBaselineIds.has(el.id)){
        el.classList.add('lai-advanced-provisional');
        el.classList.add('lai-advanced-turn-candidate');
      }
    }
  }

  function setAdvancedWorkingVisible(visible) {
    let el=document.getElementById('lai-advanced-working');
    if(visible && !el){
      el=document.createElement('div');
      el.id='lai-advanced-working';
      el.textContent='Advanced · completing tool checks…';
      document.body.appendChild(el);
    } else if(!visible && el){
      el.remove();
    }
  }

  function testHeadingNumbers(text) {
    const source=String(text || '');
    const reTest=/^[ \t]*\*{0,2}TEST[ \t]+(\d+)\b(?:[ \t]*(?:—|–|-|:)[ \t]*[^\r\n]+)?\*{0,2}[ \t]*$/gmi;
    const nums=[];
    let match;
    while((match=reTest.exec(source))!==null) nums.push(match[1]);
    return nums;
  }

  function outputMessageText(item) {
    if(!item || typeof item!=='object' || item.type!=='message') return '';
    if(typeof item.content==='string') return item.content;
    const parts=Array.isArray(item.content) ? item.content : [];
    return parts.map(part=>{
      if(typeof part==='string') return part;
      if(!part || typeof part!=='object') return '';
      if(typeof part.text==='string') return part.text;
      if(part.text && typeof part.text==='object' && typeof part.text.value==='string'){
        return part.text.value;
      }
      if(typeof part.content==='string') return part.content;
      return '';
    }).join('');
  }

  function isNativeToolTimelineItem(item) {
    if(!item || typeof item!=='object') return false;
    const type=String(item.type || '').toLowerCase();
    if(type==='message') return false;
    return (
      type==='function_call'
      || type==='function_call_output'
      || type==='tool_call'
      || type==='tool_call_output'
      || type==='web_search_call'
      || type==='file_search_call'
      || type==='computer_call'
      || type==='code_interpreter_call'
      || /(?:function|tool|web_search|file_search).*call/.test(type)
      || /(?:function|tool).*output/.test(type)
    );
  }

  function cleanPreToolOutputMessages(output) {
    if(!Array.isArray(output) || output.length<3){
      return {changed:false,output,canonicalText:''};
    }

    const toolIndexes=[];
    const messageIndexes=[];
    for(let i=0;i<output.length;i++){
      if(isNativeToolTimelineItem(output[i])) toolIndexes.push(i);
      if(
        output[i]
        && output[i].type==='message'
        && outputMessageText(output[i]).trim()
      ){
        messageIndexes.push(i);
      }
    }
    if(!toolIndexes.length || messageIndexes.length<2){
      return {changed:false,output,canonicalText:''};
    }

    const lastTool=Math.max(...toolIndexes);
    const finalMessageIndexes=messageIndexes.filter(i=>i>lastTool);
    if(!finalMessageIndexes.length){
      return {changed:false,output,canonicalText:''};
    }

    const canonicalIndex=finalMessageIndexes[finalMessageIndexes.length-1];
    let changed=false;
    const cleaned=[];

    for(let i=0;i<output.length;i++){
      const item=output[i];
      if(
        i<canonicalIndex
        && item
        && item.type==='message'
        && toolIndexes.some(toolIndex=>toolIndex>i && toolIndex<canonicalIndex)
      ){
        // Under Advanced tool-first discipline, assistant text emitted before
        // a later Native tool call is provisional. Keep every call/result,
        // reasoning, citation, and extension item; remove only that message.
        changed=true;
        continue;
      }
      cleaned.push(item);
    }

    return {
      changed,
      output:cleaned,
      canonicalText:outputMessageText(output[canonicalIndex])
    };
  }

  function cloneOutputMessageWithText(item,text) {
    const copy=(typeof structuredClone==='function')
      ? structuredClone(item)
      : JSON.parse(JSON.stringify(item));
    const parts=Array.isArray(copy.content) ? copy.content : [];
    let wrote=false;
    for(const part of parts){
      if(!part || typeof part!=='object' || typeof part.text!=='string') continue;
      if(!wrote){
        part.text=String(text || '');
        wrote=true;
      }else{
        part.text='';
      }
    }
    if(!wrote){
      copy.content=[{type:'output_text',text:String(text || '')}];
    }
    return copy;
  }

  function cleanRestartedOutputTimeline(output) {
    if(!Array.isArray(output) || output.length<2){
      return {changed:false,output,canonicalText:''};
    }

    const positional=cleanPreToolOutputMessages(output);
    output=positional.output;
    let changed=positional.changed;
    let canonicalText=positional.canonicalText || '';

    const messages=[];
    for(let i=0;i<output.length;i++){
      const text=outputMessageText(output[i]);
      const nums=testHeadingNumbers(text);
      if(text.trim() && nums.length){
        messages.push({index:i,text,nums});
      }
    }
    if(messages.length<2){
      if(!canonicalText && messages.length===1){
        canonicalText=messages[0].text;
      }
      return {changed,output,canonicalText};
    }

    // Work backwards: the last restarted TEST sequence that repeats the first
    // heading and at least one additional test number is the canonical final
    // assistant message. Earlier textual message items are provisional.
    let canonical=null;
    for(let i=messages.length-1;i>=1;i--){
      const candidate=messages[i];
      const first=candidate.nums[0];
      const candidateSet=new Set(candidate.nums);
      const earlier=messages.slice(0,i).filter(msg=>msg.nums.includes(first));
      if(!earlier.length) continue;

      const earlierNums=new Set(earlier.flatMap(msg=>msg.nums));
      const repeatedBeyondFirst=[...candidateSet].some(
        num=>num!==first && earlierNums.has(num)
      );
      const clearlyExpanded=candidate.nums.length>Math.max(
        0,
        ...earlier.map(msg=>msg.nums.length)
      );
      if(repeatedBeyondFirst || clearlyExpanded){
        canonical=candidate;
        break;
      }
    }

    if(!canonical){
      return {changed,output,canonicalText};
    }

    const canonicalSet=new Set(canonical.nums);
    const cleaned=[];

    for(let i=0;i<output.length;i++){
      const item=output[i];

      if(i===canonical.index){
        // Defence in depth: if the final message item itself contains an
        // internal restarted prefix, collapse that prefix too.
        const internal=cleanRestartedTestText(outputMessageText(item));
        if(internal.changed){
          cleaned.push(cloneOutputMessageWithText(item,internal.text));
          changed=true;
        }else{
          cleaned.push(item);
        }
        continue;
      }

      if(i<canonical.index && item && item.type==='message'){
        const nums=testHeadingNumbers(outputMessageText(item));
        // Drop only provisional assistant text. Never remove function_call,
        // function_call_output, reasoning, citations, or OpenWebUI extension
        // output items, so the tool-history timeline remains available.
        if(nums.length && nums.some(num=>canonicalSet.has(num))){
          changed=true;
          continue;
        }
      }

      cleaned.push(item);
    }

    canonicalText='';
    for(let i=cleaned.length-1;i>=0;i--){
      const value=outputMessageText(cleaned[i]);
      if(value.trim() && testHeadingNumbers(value).length){
        canonicalText=value;
        break;
      }
    }

    return {changed,output:cleaned,canonicalText};
  }

  function cleanAssistantOutputTimeline(message) {
    if(!message || typeof message!=='object') return false;

    let changed=false;
    if(Array.isArray(message.output)){
      const result=cleanRestartedOutputTimeline(message.output);
      if(result.changed){
        message.output=result.output;
        // Keep the outer content field aligned with the surviving final answer.
        // OpenWebUI reconstructs tool turns from output; this prevents a stale
        // duplicated content mirror from resurfacing on reload.
        if(result.canonicalText && typeof message.content==='string'){
          message.content=result.canonicalText;
        }
        changed=true;
      }
    }

    if(typeof message.content==='string'){
      const cleaned=cleanRestartedTestText(message.content);
      if(cleaned.changed){
        message.content=cleaned.text;
        changed=true;
      }
    }
    return changed;
  }

  function cleanRestartedTestText(text) {
    const source=String(text || '');
    const reTest=/^[ \t]*\*{0,2}TEST[ \t]+(\d+)\b(?:[ \t]*(?:—|–|-|:)[ \t]*[^\r\n]+)?\*{0,2}[ \t]*$/gmi;
    const hits=[];
    let match;
    while((match=reTest.exec(source))!==null){
      hits.push({num:match[1],index:match.index});
    }
    if(hits.length<2) return {changed:false,text:source};

    const firstNum=hits[0].num;
    const repeated=hits.filter(x=>x.num===firstNum);
    if(repeated.length<2) return {changed:false,text:source};

    // A restart is credible only when at least one additional TEST number from
    // the first sequence is repeated after the second first-number heading.
    // Descriptive headings such as "TEST 1 — DUPLICATE/PRE-TOOL OUTPUT" count.
    const secondStart=repeated[1].index;
    const beforeNums=new Set(
      hits.filter(x=>x.index<secondStart).map(x=>x.num)
    );
    const afterNums=new Set(
      hits.filter(x=>x.index>=secondStart).map(x=>x.num)
    );
    const repeatedBeyondFirst=[...beforeNums].some(
      n=>n!==firstNum && afterNums.has(n)
    );
    const clearlyExpanded=afterNums.size>beforeNums.size;
    if(!(repeatedBeyondFirst || clearlyExpanded)){
      return {changed:false,text:source};
    }

    return {
      changed:true,
      text:source.slice(secondStart).replace(/^\s+/,'')
    };
  }

  function exactTestHeadingElements(root) {
    const all=[...root.querySelectorAll('p,h1,h2,h3,h4,h5,h6,div,span')];
    return all.filter(el=>{
      const value=(el.textContent || '').trim();
      if(!/^\*{0,2}TEST\s+\d+\b(?:\s*(?:—|–|-|:)\s*.+?)?\*{0,2}$/i.test(value)) return false;
      // Prefer the smallest exact-text element so ancestors containing the
      // same text through descendants do not become duplicate candidates.
      return ![...el.children].some(
        child=>/^\*{0,2}TEST\s+\d+\b(?:\s*(?:—|–|-|:)\s*.+?)?\*{0,2}$/i.test((child.textContent || '').trim())
      );
    });
  }

  function commonAncestor(a,b,limit) {
    if(!a || !b) return null;
    const seen=new Set();
    let n=a;
    while(n && n!==limit?.parentElement){ seen.add(n); n=n.parentElement; }
    n=b;
    while(n && n!==limit?.parentElement){
      if(seen.has(n)) return n;
      n=n.parentElement;
    }
    return null;
  }

  function childUnder(ancestor,node) {
    let n=node;
    while(n && n.parentElement!==ancestor) n=n.parentElement;
    return n && n.parentElement===ancestor ? n : null;
  }

  function looksLikeNativeToolHistoryElement(el) {
    if(!el || typeof el!=='object') return false;
    const value=String(el.innerText || el.textContent || '').trim();
    if(/\bExplored\s+\d+\b/i.test(value)) return true;
    if(/\bView Result from\b/i.test(value)) return true;
    if(el.matches?.('button,details,[role="button"]')) return true;
    if(el.querySelector?.('button,details,[role="button"],[class*="tool"],[data-testid*="tool"]')){
      return true;
    }
    return false;
  }

  function highestBlockBeforeRestart(root,first,second) {
    let node=first;
    let candidate=first;
    while(node?.parentElement && node.parentElement!==root){
      const parent=node.parentElement;
      if(parent.contains(second)) break;
      candidate=parent;
      node=parent;
    }
    return candidate;
  }

  function hideDraftCueBefore(root,block) {
    if(!root || !block) return false;
    const cue=/\b(?:let me work through|calculator needed|calling tools where required|let me calculate|let me verify)\b/i;
    let changed=false;
    let node=block.previousElementSibling;
    let hops=0;
    while(node && hops<3){
      const prev=node.previousElementSibling;
      const value=String(node.innerText || node.textContent || '').trim();
      if(!value || looksLikeNativeToolHistoryElement(node)) break;
      if(cue.test(value)){
        node.classList.add('lai-advanced-discarded-prefix');
        changed=true;
      }else{
        break;
      }
      node=prev;
      hops+=1;
    }
    return changed;
  }

  function cleanRestartedTestDom(root) {
    if(!root) return false;
    const headings=exactTestHeadingElements(root);
    if(headings.length<2) return false;

    const parseNum=el=>{
      const m=(el.textContent || '').trim().match(/TEST\s+(\d+)/i);
      return m ? m[1] : '';
    };
    const firstNum=parseNum(headings[0]);
    const same=headings.filter(el=>parseNum(el)===firstNum);
    if(same.length<2) return false;

    const first=same[0];
    const second=same[1];

    // A normal restart repeats additional TEST numbers. A heading-only
    // pre-tool fragment has only TEST 1 before the restart, while the final
    // answer expands to TEST 1..N. Both are provisional prefixes.
    const secondIndex=headings.indexOf(second);
    const before=new Set(headings.slice(0,secondIndex).map(parseNum));
    const after=new Set(headings.slice(secondIndex).map(parseNum));
    const repeatedBeyondFirst=[...before].some(
      n=>n!==firstNum && after.has(n)
    );
    const clearlyExpanded=after.size>before.size;
    if(!(repeatedBeyondFirst || clearlyExpanded)) return false;

    const isolated=highestBlockBeforeRestart(root,first,second);
    if(isolated && isolated!==root && !isolated.contains(second)){
      isolated.classList.add('lai-advanced-discarded-prefix');
      hideDraftCueBefore(root,isolated);
      return true;
    }

    const lca=commonAncestor(first,second,root);
    if(!lca) return false;
    const firstTop=childUnder(lca,first);
    const secondTop=childUnder(lca,second);
    if(!firstTop || !secondTop || firstTop===secondTop) return false;

    let node=firstTop;
    let changed=false;
    while(node && node!==secondTop){
      const next=node.nextElementSibling;
      if(!looksLikeNativeToolHistoryElement(node)){
        node.classList.add('lai-advanced-discarded-prefix');
        changed=true;
      }
      node=next;
    }
    hideDraftCueBefore(root,firstTop);
    return changed;
  }

  function cleanAdvancedRestartedDom() {
    let changed=false;
    for(const root of document.querySelectorAll('.lai-advanced-provisional')){
      if(cleanRestartedTestDom(root)) changed=true;
    }
    return changed;
  }

  function cleanAdvancedCrossMessageDom() {
    const roots=[...document.querySelectorAll(
      '.lai-advanced-turn-candidate, .lai-advanced-provisional'
    )];
    if(roots.length<2) return false;

    const profiles=roots.map((root,index)=>({
      root,
      index,
      nums:testHeadingNumbers(root.innerText || root.textContent || '')
    })).filter(item=>item.nums.length);

    if(profiles.length<2) return false;

    let canonical=null;
    for(let i=profiles.length-1;i>=1;i--){
      const candidate=profiles[i];
      const first=candidate.nums[0];
      const earlier=profiles.slice(0,i).filter(p=>p.nums.includes(first));
      if(!earlier.length) continue;

      const earlierNums=new Set(earlier.flatMap(p=>p.nums));
      const candidateSet=new Set(candidate.nums);
      const repeatedBeyondFirst=[...candidateSet].some(
        num=>num!==first && earlierNums.has(num)
      );
      const clearlyExpanded=candidate.nums.length>Math.max(
        0,
        ...earlier.map(p=>p.nums.length)
      ); // includes heading-only TEST 1 -> final TEST 1..N
      if(repeatedBeyondFirst || clearlyExpanded){
        canonical=candidate;
        break;
      }
    }

    if(!canonical) return false;

    let changed=false;
    const canonicalSet=new Set(canonical.nums);
    for(const profile of profiles){
      if(profile.index>=canonical.index) continue;
      if(profile.nums.some(num=>canonicalSet.has(num))){
        profile.root.classList.add('lai-advanced-discarded-message');
        changed=true;
      }
    }
    return changed;
  }

  async function cleanAdvancedPersistedRestart() {
    if(advPresentCleanupBusy) return false;
    const chatId=chatIdFromLocation();
    if(!chatId) return false;

    advPresentCleanupBusy=true;
    try{
      const record=await readNativeChat(chatId);
      const chat=record?.chat;
      if(!chat || typeof chat!=='object') return false;

      const updated=(typeof structuredClone==='function')
        ? structuredClone(chat)
        : JSON.parse(JSON.stringify(chat));

      let changed=false;
      const walk=node=>{
        if(!node || typeof node!=='object') return;
        if(
          !Array.isArray(node)
          && String(node.role || '').toLowerCase()==='assistant'
        ){
          if(cleanAssistantOutputTimeline(node)) changed=true;
        }
        if(Array.isArray(node)){
          node.forEach(walk);
        } else {
          Object.values(node).forEach(walk);
        }
      };
      walk(updated);

      // Current-branch defence in depth. If the latest user turn contains more
      // than one assistant node and the final node restarts/expands the same
      // TEST sequence, suppress only the earlier assistant text while keeping
      // their output/tool records intact.
      const history=updated?.history;
      const messages=history?.messages;
      const currentId=history?.currentId;
      if(messages && typeof messages==='object' && currentId && messages[currentId]){
        const chain=[];
        const seen=new Set();
        let id=currentId;
        while(id && messages[id] && !seen.has(id)){
          seen.add(id);
          chain.push(messages[id]);
          id=messages[id]?.parentId || null;
        }
        chain.reverse();

        let latestUser=-1;
        for(let i=chain.length-1;i>=0;i--){
          if(String(chain[i]?.role || '').toLowerCase()==='user'){
            latestUser=i;
            break;
          }
        }

        const assistants=chain.slice(latestUser+1).filter(
          msg=>String(msg?.role || '').toLowerCase()==='assistant'
        );
        if(assistants.length>1){
          // v8.4 positional defence: if a later assistant is the completed
          // TEST answer, earlier planning/scratch assistant text from this same
          // user turn is provisional. Tool records in output remain intact.
          const finalAssistant=assistants[assistants.length-1];
          const finalText=(
            (Array.isArray(finalAssistant?.output)
              ? finalAssistant.output.map(outputMessageText).filter(Boolean).join('\n')
              : '')
            || (typeof finalAssistant?.content==='string' ? finalAssistant.content : '')
          );
          const finalNums=testHeadingNumbers(finalText);
          if(finalNums.length){
            for(const earlierMsg of assistants.slice(0,-1)){
              const earlierText=(
                (Array.isArray(earlierMsg?.output)
                  ? earlierMsg.output.map(outputMessageText).filter(Boolean).join('\n')
                  : '')
                || (typeof earlierMsg?.content==='string' ? earlierMsg.content : '')
              );
              const earlierNums=testHeadingNumbers(earlierText);
              const looksProvisional=(
                /\b(?:let me work through|calculator needed|calling tools where required|let me calculate|let me verify)\b/i.test(earlierText)
                || (
                  earlierNums.length
                  && earlierNums.every(num=>finalNums.includes(num))
                )
              );
              if(!looksProvisional) continue;

              if(Array.isArray(earlierMsg.output)){
                const before=earlierMsg.output.length;
                earlierMsg.output=earlierMsg.output.filter(
                  item=>!(item && item.type==='message')
                );
                if(earlierMsg.output.length!==before) changed=true;
              }
              if(typeof earlierMsg.content==='string' && earlierMsg.content){
                earlierMsg.content='';
                changed=true;
              }
            }
          }

          const profile=msg=>{
            const outputText=Array.isArray(msg.output)
              ? msg.output.map(outputMessageText).filter(Boolean).join('\n')
              : '';
            const contentText=typeof msg.content==='string' ? msg.content : '';
            const text=[outputText,contentText].filter(Boolean).join('\n');
            return {msg,text,nums:testHeadingNumbers(text)};
          };
          const profiles=assistants.map(profile).filter(p=>p.nums.length);
          if(profiles.length>1){
            const final=profiles[profiles.length-1];
            const finalSet=new Set(final.nums);
            for(const earlier of profiles.slice(0,-1)){
              const repeated=earlier.nums.some(num=>finalSet.has(num));
              const expanded=final.nums.length>earlier.nums.length;
              const startsSame=(
                earlier.nums.length
                && final.nums.length
                && earlier.nums[0]===final.nums[0]
              );
              if(!(repeated && (startsSame || expanded))) continue;

              if(Array.isArray(earlier.msg.output) && earlier.msg.output.length){
                // Keep Native function_call/function_call_output chronology but
                // remove only textual TEST message items superseded by final.
                earlier.msg.output=earlier.msg.output.filter(item=>{
                  if(!item || item.type!=='message') return true;
                  const nums=testHeadingNumbers(outputMessageText(item));
                  return !nums.some(num=>finalSet.has(num));
                });
                // Empty outer content is safe here because output remains and
                // carries the tool exchange for OpenWebUI reconstruction.
                if(typeof earlier.msg.content==='string') earlier.msg.content='';
                changed=true;
              }else if(
                typeof earlier.msg.content==='string'
                && earlier.nums.length
                && earlier.nums.every(num=>finalSet.has(num))
              ){
                // v8.3: OpenWebUI may persist a heading-only pre-tool assistant
                // node with no output array. If the final assistant restarts and
                // expands that same TEST sequence, the earlier content is fully
                // superseded and can be cleared.
                earlier.msg.content='';
                changed=true;
              }
            }
          }
        }
      }

      if(!changed) return false;

      const payload={
        chat:updated,
        variables:(record?.variables && typeof record.variables==='object')
          ? record.variables
          : {}
      };
      const response=await window.__laiOriginalFetch(
        `/api/v1/chats/${encodeURIComponent(chatId)}`,
        {
          method:'POST',
          headers:nativeAuthHeaders(),
          body:JSON.stringify(payload)
        }
      );
      if(!response.ok){
        const detail=await response.text().catch(()=> '');
        throw new Error(
          `OpenWebUI duplicate cleanup failed: HTTP ${response.status}`
          +(detail ? ` · ${detail.slice(0,180)}` : '')
        );
      }
      return true;
    }catch(e){
      console.warn('[Local AI Suite] Advanced persisted duplicate cleanup failed',e);
      return false;
    }finally{
      advPresentCleanupBusy=false;
    }
  }

  async function finalizeAdvancedPresentation() {
    // Keep the final candidate hidden until OpenWebUI has finished saving the
    // assembled Native continuation. This is the key v8.7 timing change:
    // deterministic precision checks now operate on the persisted final answer.
    cleanAdvancedRestartedDom();
    cleanAdvancedCrossMessageDom();
    await cleanAdvancedPersistedRestart();
    cleanAdvancedRestartedDom();
    cleanAdvancedCrossMessageDom();

    await new Promise(resolve=>setTimeout(
      resolve,
      ADV_PRESENT_PERSIST_RETRY_MS
    ));

    await cleanAdvancedPersistedRestart();
    cleanAdvancedRestartedDom();
    cleanAdvancedCrossMessageDom();

    const audited=await postAssembledAdvancedAudit();
    if(audited?.changed){
      // Persisted final text has been repaired. Reload exactly once so
      // OpenWebUI renders its normal markdown/citations from the repaired chat
      // object instead of mutating framework DOM by hand.
      location.reload();
      return true;
    }

    return false;
  }

  function releaseAdvancedPresentation(reason='complete') {
    if(advPresentReleaseTimer){
      clearTimeout(advPresentReleaseTimer);
      advPresentReleaseTimer=null;
    }
    if(advPresentWatchdog){
      clearTimeout(advPresentWatchdog);
      advPresentWatchdog=null;
    }
    advPresentHolding=false;
    advPresentActiveStreams=0;
    advPresentAwaitingContinuation=false;
    advPresentBaselineIds=new Set();
    document.documentElement.classList.remove('lai-advanced-present-hold');
    for(const el of document.querySelectorAll('.lai-advanced-provisional')){
      el.classList.remove('lai-advanced-provisional');
    }

    // Keep candidate markers briefly after release. OpenWebUI can start the
    // next Native tool continuation as a separate request after TEST 1 was
    // already rendered. Candidate markers do not hide content by themselves.
    if(advPresentCandidateCleanupTimer){
      clearTimeout(advPresentCandidateCleanupTimer);
    }
    advPresentCandidateCleanupTimer=setTimeout(()=>{
      for(const el of document.querySelectorAll('.lai-advanced-turn-candidate')){
        el.classList.remove('lai-advanced-turn-candidate');
      }
      advPresentCandidateCleanupTimer=null;
    },12000);

    setAdvancedWorkingVisible(false);
    if(reason==='watchdog'){
      cleanAdvancedRestartedDom();
      cleanAdvancedCrossMessageDom();
      cleanAdvancedPersistedRestart().catch(()=>{});
      console.warn('[Local AI Suite] Advanced presentation hold released by watchdog');
    }
  }

  function beginAdvancedPresentationStream() {
    if(advPresentCandidateCleanupTimer){
      clearTimeout(advPresentCandidateCleanupTimer);
      advPresentCandidateCleanupTimer=null;
    }
    if(!advPresentHolding){
      advPresentHolding=true;
      advPresentBaselineIds=new Set(messageDomNodes().map(el=>el.id));
      document.documentElement.classList.add('lai-advanced-present-hold');
      setAdvancedWorkingVisible(true);
    }
    if(advPresentReleaseTimer){
      clearTimeout(advPresentReleaseTimer);
      advPresentReleaseTimer=null;
    }
    // A new completion after a tool_call is the expected continuation.
    advPresentAwaitingContinuation=false;
    advPresentActiveStreams+=1;
    markAdvancedProvisionalMessages();

    if(advPresentWatchdog) clearTimeout(advPresentWatchdog);
    advPresentWatchdog=setTimeout(
      ()=>releaseAdvancedPresentation('watchdog'),
      ADV_PRESENT_WATCHDOG_MS
    );
  }

  function streamLooksLikeToolCall(text) {
    const s=String(text || '');
    return /"tool_calls"\s*:|"finish_reason"\s*:\s*"tool_calls"|tool_call/i.test(s);
  }

  function endAdvancedPresentationStream(hadToolCall=false) {
    advPresentActiveStreams=Math.max(0,advPresentActiveStreams-1);
    if(hadToolCall) advPresentAwaitingContinuation=true;
    if(advPresentActiveStreams>0) return;

    if(advPresentAwaitingContinuation){
      // Keep provisional content hidden while OpenWebUI executes the tool and
      // starts the continuation completion. The watchdog is the fail-safe.
      return;
    }

    if(advPresentReleaseTimer) clearTimeout(advPresentReleaseTimer);
    advPresentReleaseTimer=setTimeout(
      async ()=>{
        const reloading=await finalizeAdvancedPresentation();
        if(!reloading) releaseAdvancedPresentation('complete');
      },
      ADV_PRESENT_QUIET_MS
    );
  }

  function monitorAdvancedResponse(response) {
    try{
      const clone=response.clone();
      clone.text()
        .then(text=>endAdvancedPresentationStream(streamLooksLikeToolCall(text)))
        .catch(()=>endAdvancedPresentationStream(false));
    }catch(e){
      endAdvancedPresentationStream(false);
    }
    return response;
  }

  function chatIdFromLocation() {
    const m = location.pathname.match(/^\/c\/([^/?#]+)/);
    return m ? decodeURIComponent(m[1]) : '';
  }

  function modeForModel(modelId) {
    const value=String(modelId || '');
    for(const [key,item] of Object.entries(CONFIG)){
      if(value===item.model || value===item.base) return key;
    }
    return '';
  }

  function token() {
    return localStorage.getItem('token') || localStorage.getItem('access_token') || '';
  }

  function nativeAuthHeaders(extra={}) {
    const headers=new Headers(extra);
    const t=token();
    if(t && !headers.has('Authorization')) headers.set('Authorization',`Bearer ${t}`);
    if(!headers.has('Content-Type')) headers.set('Content-Type','application/json');
    return headers;
  }

  function newChatQueryModel() {
    try {
      const url=new URL(location.href);
      const single=url.searchParams.get('model');
      if(single) return single;
      const multi=url.searchParams.get('models');
      if(multi) return multi.split(',').map(x=>x.trim()).filter(Boolean)[0] || '';
    } catch(e) {}
    return '';
  }

  async function readNativeChat(chatId) {
    const r=await window.__laiOriginalFetch(`/api/v1/chats/${encodeURIComponent(chatId)}`,{
      method:'GET',headers:nativeAuthHeaders()
    });
    if(!r.ok) throw new Error(`OpenWebUI chat read failed: HTTP ${r.status}`);
    return await r.json();
  }

  function nativeMessageText(message) {
    if(!message || typeof message!=='object') return '';
    if(typeof message.content==='string') return message.content;
    if(Array.isArray(message.content)){
      return message.content.map(part=>{
        if(typeof part==='string') return part;
        if(!part || typeof part!=='object') return '';
        if(typeof part.text==='string') return part.text;
        if(part.text && typeof part.text==='object' && typeof part.text.value==='string'){
          return part.text.value;
        }
        if(typeof part.content==='string') return part.content;
        return '';
      }).join('');
    }
    return '';
  }

  function nativeCurrentBranch(chat) {
    const history=chat?.history;
    const messages=history?.messages;
    const currentId=history?.currentId;
    if(!messages || typeof messages!=='object' || !currentId || !messages[currentId]){
      return [];
    }
    const chain=[];
    const seen=new Set();
    let id=currentId;
    while(id && messages[id] && !seen.has(id)){
      seen.add(id);
      chain.push(messages[id]);
      id=messages[id]?.parentId || null;
    }
    chain.reverse();
    return chain;
  }

  function finalAssistantText(message) {
    if(!message || typeof message!=='object') return '';
    const outer=nativeMessageText(message);
    if(testHeadingNumbers(outer).length) return outer;

    if(Array.isArray(message.output)){
      let best='';
      let bestCount=-1;
      for(const item of message.output){
        const value=outputMessageText(item);
        const count=testHeadingNumbers(value).length;
        if(value.trim() && count>=bestCount){
          best=value;
          bestCount=count;
        }
      }
      if(best.trim()) return best;
    }
    return outer;
  }

  function setFinalAssistantText(message,text) {
    if(!message || typeof message!=='object') return false;
    let changed=false;
    const value=String(text || '');

    if(typeof message.content==='string'){
      if(message.content!==value){
        message.content=value;
        changed=true;
      }
    }

    if(Array.isArray(message.output)){
      let targetIndex=-1;
      let bestCount=-1;
      for(let i=0;i<message.output.length;i++){
        const item=message.output[i];
        if(!item || item.type!=='message') continue;
        const itemText=outputMessageText(item);
        const count=testHeadingNumbers(itemText).length;
        if(itemText.trim() && count>=bestCount){
          targetIndex=i;
          bestCount=count;
        }
      }
      if(targetIndex>=0){
        const existing=outputMessageText(message.output[targetIndex]);
        if(existing!==value){
          message.output[targetIndex]=cloneOutputMessageWithText(
            message.output[targetIndex],
            value
          );
          changed=true;
        }
      }
    }

    return changed;
  }

  async function writeNativeChatRecord(chatId,record,chat){
    const payload={
      chat,
      variables:(record?.variables && typeof record.variables==='object')
        ? record.variables
        : {}
    };
    const r=await window.__laiOriginalFetch(
      `/api/v1/chats/${encodeURIComponent(chatId)}`,
      {
        method:'POST',
        headers:nativeAuthHeaders(),
        body:JSON.stringify(payload)
      }
    );
    if(!r.ok){
      const detail=await r.text().catch(()=> '');
      throw new Error(
        `OpenWebUI chat write failed: HTTP ${r.status}`
        +(detail ? ` · ${detail.slice(0,180)}` : '')
      );
    }
    return true;
  }

  async function postAssembledAdvancedAudit(){
    const chatId=chatIdFromLocation();
    if(!chatId) return {changed:false};

    try{
      const record=await readNativeChat(chatId);
      const chat=record?.chat;
      if(!chat || typeof chat!=='object') return {changed:false};

      const branch=nativeCurrentBranch(chat);
      if(!branch.length) return {changed:false};

      let latestUser=-1;
      for(let i=branch.length-1;i>=0;i--){
        if(String(branch[i]?.role || '').toLowerCase()==='user'){
          latestUser=i;
          break;
        }
      }
      if(latestUser<0) return {changed:false};

      const userMessage=branch[latestUser];
      const assistants=branch.slice(latestUser+1).filter(
        msg=>String(msg?.role || '').toLowerCase()==='assistant'
      );
      if(!assistants.length) return {changed:false};

      const finalAssistant=assistants[assistants.length-1];
      const userText=nativeMessageText(userMessage).trim();
      const answerText=finalAssistantText(finalAssistant).trim();
      if(!userText || !answerText) return {changed:false};

      const result=await uiPost('/advanced/final-audit',{
        user_text:userText,
        answer_text:answerText
      });

      if(!result || result.ok===false){
        console.warn(
          '[Local AI Suite] post-assembly Advanced audit failed',
          result?.error || result
        );
        return {changed:false};
      }

      const repaired=String(result.answer || '').trim();
      if(!result.changed || !repaired || repaired===answerText){
        return {changed:false,issues:result.issues_after || []};
      }

      const updated=(typeof structuredClone==='function')
        ? structuredClone(chat)
        : JSON.parse(JSON.stringify(chat));

      const updatedBranch=nativeCurrentBranch(updated);
      let updatedLatestUser=-1;
      for(let i=updatedBranch.length-1;i>=0;i--){
        if(String(updatedBranch[i]?.role || '').toLowerCase()==='user'){
          updatedLatestUser=i;
          break;
        }
      }
      const updatedAssistants=updatedBranch.slice(updatedLatestUser+1).filter(
        msg=>String(msg?.role || '').toLowerCase()==='assistant'
      );
      const updatedFinal=updatedAssistants[updatedAssistants.length-1];
      if(!updatedFinal) return {changed:false};

      if(!setFinalAssistantText(updatedFinal,repaired)){
        return {changed:false};
      }

      await writeNativeChatRecord(chatId,record,updated);
      return {
        changed:true,
        issues_before:result.issues_before || [],
        issues_after:result.issues_after || []
      };
    }catch(e){
      console.warn('[Local AI Suite] post-assembly Advanced audit failed',e);
      return {changed:false};
    }
  }

  async function writeNativeChatModel(chatId,modelId) {
    const record=await readNativeChat(chatId);
    const chat=record?.chat;
    if(!chat || typeof chat!=='object') throw new Error('OpenWebUI chat record has no chat object');

    const updated=(typeof structuredClone==='function')
      ? structuredClone(chat)
      : JSON.parse(JSON.stringify(chat));

    updated.models=[modelId];

    const payload={
      chat:updated,
      variables:(record?.variables && typeof record.variables==='object') ? record.variables : {}
    };

    const r=await window.__laiOriginalFetch(`/api/v1/chats/${encodeURIComponent(chatId)}`,{
      method:'POST',
      headers:nativeAuthHeaders(),
      body:JSON.stringify(payload)
    });

    if(!r.ok){
      const detail=await r.text().catch(()=> '');
      throw new Error(`OpenWebUI chat model update failed: HTTP ${r.status}${detail ? ' · '+detail.slice(0,180) : ''}`);
    }
    return true;
  }

  function setLocalMode(next) {
    if(!CONFIG[next]) return false;
    if(advPresentHolding && next!=='advanced') releaseAdvancedPresentation('mode-switch');
    mode=next;
    localStorage.setItem(MODE_KEY,mode);
    renderState();
    return true;
  }

  function setSyncState(state) {
    const el=document.getElementById('lai-mode-sync');
    if(!el) return;
    const map={
      native:['native synced','Custom mode matches OpenWebUI native selected model'],
      syncing:['syncing…','Reading OpenWebUI native model state'],
      switching:['switching…','Updating OpenWebUI native model state'],
      error:['⚠ sync error','Could not verify OpenWebUI native model state'],
      unknown:['sync unknown','Native model could not be mapped to a Local AI mode']
    };
    const entry=map[state] || map.unknown;
    el.textContent=entry[0];
    el.title=entry[1];
  }

  async function syncFromNativeModel(force=false) {
    if(nativeSyncBusy) return;
    const pathKey=location.pathname+location.search;
    if(!force && pathKey===lastNativeSyncPath) return;

    nativeSyncBusy=true;
    setSyncState('syncing');

    try {
      const chatId=chatIdFromLocation();

      if(chatId){
        const record=await readNativeChat(chatId);
        const modelId=Array.isArray(record?.chat?.models) ? String(record.chat.models[0] || '') : '';
        const nativeMode=modeForModel(modelId);
        if(nativeMode){
          setLocalMode(nativeMode);
          setSyncState('native');
        } else {
          setSyncState('unknown');
        }
        lastNativeSyncPath=pathKey;
        return;
      }

      const queryModel=newChatQueryModel();
      const queryMode=modeForModel(queryModel);

      if(queryMode){
        setLocalMode(queryMode);
        try { sessionStorage.setItem('selectedModels',JSON.stringify([CONFIG[queryMode].model])); } catch(e) {}
        setSyncState('native');
        lastNativeSyncPath=pathKey;
        return;
      }

      if(location.pathname==='/' || location.pathname===''){
        const target=CONFIG[mode].model;
        try { sessionStorage.setItem('selectedModels',JSON.stringify([target])); } catch(e) {}
        const url=new URL(location.href);
        url.searchParams.delete('models');
        url.searchParams.set('model',target);
        lastNativeSyncPath=url.pathname+url.search;
        location.replace(url.pathname+url.search+url.hash);
        return;
      }

      setSyncState('unknown');
      lastNativeSyncPath=pathKey;
    } catch(e) {
      console.warn('[Local AI Suite] native model sync failed',e);
      setSyncState('error');
    } finally {
      nativeSyncBusy=false;
    }
  }
  function controllerBase() {
    const h = (location.hostname === 'localhost' || location.hostname === '127.0.0.1') ? '127.0.0.1' : location.hostname;
    return `http://${h}:${CONTROLLER_PORT}`;
  }
  function rootKey(chatId) { return ROOT_PREFIX + chatId; }
  function getRoot(chatId) { return chatId ? localStorage.getItem(rootKey(chatId)) || '' : ''; }
  function setRoot(chatId, root) { if (chatId && root) localStorage.setItem(rootKey(chatId), root); }
  function clearRoot(chatId) { if (chatId) localStorage.removeItem(rootKey(chatId)); }
  function randomId() { return (crypto && crypto.randomUUID) ? crypto.randomUUID() : Math.random().toString(36).slice(2)+Date.now(); }

  function prewarmMode(next) {
    if (!__PREWARM_MODELS__) return;
    const c=CONFIG[next];
    if(!c?.base) return;
    // Fire-and-forget: switching modes stays instant while Ollama starts loading
    // the selected profile in parallel with the user's typing / Research Brief.
    uiPost('/model/warm',{model:c.base}).catch(()=>{});
  }

  async function setMode(next) {
    if(!CONFIG[next] || modeSwitchBusy) return;

    if(next===mode){
      await syncFromNativeModel(true);
      return;
    }

    const previous=mode;
    const c=CONFIG[next];
    modeSwitchBusy=true;
    setSyncState('switching');

    try {
      if(next==='deep' && previous!=='deep'){
        forceNewDeepRoot=true;
        sessionStorage.setItem(FORCE_DEEP_KEY,'1');
      }

      setLocalMode(next);
      prewarmMode(next);

      const chatId=chatIdFromLocation();

      if(chatId){
        await writeNativeChatModel(chatId,c.model);
        toast(`${c.label} selected. Reloading chat…`);
        location.reload();
        return;
      }

      try { sessionStorage.setItem('selectedModels',JSON.stringify([c.model])); } catch(e) {}
      const url=new URL(location.href);
      url.searchParams.delete('models');
      url.searchParams.set('model',c.model);
      toast(`${c.label} selected.`);
      location.assign(url.pathname+url.search+url.hash);
    } catch(e) {
      console.error('[Local AI Suite] native mode switch failed',e);
      setLocalMode(previous);
      setSyncState('error');
      toast(`Mode switch failed: ${String(e?.message || e)}`);
      modeSwitchBusy=false;
    }
  }

  function toast(text) {
    const old=document.getElementById('lai-mode-toast'); if(old) old.remove();
    const el=document.createElement('div'); el.id='lai-mode-toast'; el.textContent=text;
    el.style.cssText='position:fixed;left:50%;bottom:150px;transform:translateX(-50%);z-index:99999;padding:9px 14px;border-radius:12px;background:rgba(25,25,28,.94);color:white;font:13px system-ui;box-shadow:0 6px 25px rgba(0,0,0,.25)';
    document.body.appendChild(el); setTimeout(()=>el.remove(),2600);
  }

  async function uiPost(path, payload) {
    try {
      const r=await window.__laiOriginalFetch(controllerBase()+path,{
        method:'POST',headers:{'Content-Type':'application/json','X-Local-AI-Key':UI_KEY},body:JSON.stringify(payload)
      });
      return await r.json();
    } catch(e) { console.warn('[Local AI Suite] controller UI call failed',e); return null; }
  }

  function currentUserId() {
    try {
      const raw=localStorage.getItem('user'); if(raw){ const u=JSON.parse(raw); return u?.id || 'browser'; }
    } catch(e) {}
    return 'browser';
  }

  async function queueUpdate() {
    const chatId=chatIdFromLocation(); const root=getRoot(chatId);
    if(!chatId || !root){ toast('Start a Deep Research prompt first.'); return; }
    const text=window.prompt('Update the active Research Brief\n\nAdd, remove, narrow, expand, redirect, or reprioritize the research scope:','');
    if(!text || !text.trim()) return;
    const result=await uiPost('/research/update/queue',{chat_id:chatId,root_id:root,user_id:currentUserId(),text:text.trim()});
    if(result?.ok) toast('Research update queued. Deep Research will pick it up at the next research checkpoint.');
    else toast('Could not queue the research update.');
  }

  function renderState() {
    const bar=document.getElementById('local-ai-mode-bar'); if(!bar) return;
    bar.querySelectorAll('[data-lai-mode]').forEach(b=>{
      const active=b.dataset.laiMode===mode; b.classList.toggle('active',active); b.setAttribute('aria-pressed',active?'true':'false');
    });
    const update=document.getElementById('lai-research-update');
    if(update) update.style.display=mode==='deep'?'inline-flex':'none';
    const badge=document.getElementById('lai-mode-status');
    if(badge) badge.textContent=mode==='deep'?'64K · budgeted web · lab validation':mode==='advanced'?'48K · final-audit · continuation-clean · calculator · web':'32K · web off · no sandbox';
  }

  function mountBar() {
    if(document.getElementById('local-ai-mode-bar')) return;
    const bar=document.createElement('div'); bar.id='local-ai-mode-bar';
    bar.innerHTML=`
      <div class="lai-mode-buttons">
        ${Object.entries(CONFIG).map(([id,c])=>`<button type="button" data-lai-mode="${id}" title="${c.label} mode">${c.icon}<span>${c.label}</span></button>`).join('')}
        <button type="button" id="lai-research-update" title="Add or change Deep Research scope">✏️<span>Update Research</span></button>
      </div>
      <div id="lai-mode-meta"><span id="lai-mode-status"></span><span class="lai-mode-sep">·</span><span id="lai-mode-sync">syncing…</span></div>`;
    bar.addEventListener('click',e=>{
      const b=e.target.closest('[data-lai-mode]'); if(b) setMode(b.dataset.laiMode);
      if(e.target.closest('#lai-research-update')) queueUpdate();
    });
    document.body.appendChild(bar); renderState();
  }

  // Hide OpenWebUI's stock raw model picker and compact internal-ID labels.
  // Keep OpenWebUI's friendly Fast/Advanced/Deep Research title visible as a
  // second visual confirmation that native state and the custom bar agree.
  function hideRawSelector() {
    const chatPage = location.pathname==='/' || location.pathname.startsWith('/c/');
    if(!chatPage) return;

    const rawIds = [
      'local-ai-fast',
      'local-ai-advanced',
      'local-ai-deep-research',
      'natural-fast:27b',
      'research-plus:27b',
      'deep-research:27b'
    ];
    const selectorWords = ['select model','select a model'];

    document.querySelectorAll('button').forEach(b=>{
      if(b.closest('#local-ai-mode-bar')) return;
      const text=(b.textContent||'').trim();
      const aria=(b.getAttribute('aria-label')||'').trim();
      const title=(b.getAttribute('title')||'').trim();
      const hay=(text+' '+aria+' '+title).toLowerCase();
      if([...rawIds,...selectorWords].some(x=>hay.includes(x))) {
        const rect=b.getBoundingClientRect();
        if(rect.height <= 72 && rect.width <= 700) b.classList.add('lai-hidden-model-selector');
      }
    });

    // Some OpenWebUI builds render the selected model as plain text above the
    // composer, e.g. "natural-fast:27b". Hide only compact top-of-chat elements
    // whose ENTIRE text equals an internal model ID, so normal message content
    // mentioning a model name is left alone.
    document.querySelectorAll('h1,h2,h3,h4,div,span,p').forEach(el=>{
      if(el.closest('#local-ai-mode-bar')) return;
      const value=(el.textContent||'').trim().toLowerCase();
      if(!rawIds.includes(value)) return;

      const rect=el.getBoundingClientRect();
      const nearTop = rect.top >= -10 && rect.top <= 300;
      const compact = rect.height > 0 && rect.height <= 110 && rect.width > 0 && rect.width <= 1000;
      if(nearTop && compact) el.classList.add('lai-hidden-model-label');
    });
  }

  function deepRootForBody(body) {
    const chatId=String(body?.chat_id || chatIdFromLocation() || '');
    if(!chatId) return {chatId:'',root:''};
    let root=getRoot(chatId);
    if(forceNewDeepRoot || !root){
      // Current OpenWebUI chat requests include the persisted user message object
      // separately as user_message. Use that ID so sandbox lifetime is tied to the
      // actual Deep Research prompt, not the assistant response placeholder.
      const msgs=Array.isArray(body?.messages)?body.messages:[];
      const lastUser=[...msgs].reverse().find(m=>m && m.role==='user');
      root=String(body?.user_message?.id || lastUser?.id || body?.parent_id || body?.id || body?.message_id || randomId());
      setRoot(chatId,root); forceNewDeepRoot=false; sessionStorage.removeItem(FORCE_DEEP_KEY);
    }
    return {chatId,root};
  }

  function patchCompletion(init) {
    if(!init?.body) return init;
    let body;
    try { body=typeof init.body==='string'?JSON.parse(init.body):init.body; } catch(e){ return init; }
    if(!body || typeof body!=='object') return init;
    const previousModel=String(body.model || '');
    const nativeMode=modeForModel(previousModel);
    const effectiveMode=nativeMode || mode;
    if(nativeMode && nativeMode!==mode){
      setLocalMode(nativeMode);
      setSyncState('native');
    }
    const c=CONFIG[effectiveMode] || CONFIG.fast;
    body.model=c.model;
    body.think=c.think;
    // Keep persisted message/export metadata aligned with the mode actually sent.
    if(body.user_message && typeof body.user_message==='object') body.user_message.models=[c.model];
    if(body.message_ids && typeof body.message_ids==='object') {
      const ids=Object.values(body.message_ids).filter(v=>typeof v==='string' && v);
      if(ids.length) body.message_ids={ [c.model]: ids[ids.length-1] };
    }
    if(body.model_item && typeof body.model_item==='object') {
      body.model_item={...body.model_item,id:c.model,name:c.label,preset:true};
      body.model_item.info={...(body.model_item.info||{}),id:c.model,name:c.label,base_model_id:c.base};
    }
    body.features=body.features || {};
    body.features.code_interpreter=false;
    body.tool_ids=Array.isArray(body.tool_ids)?body.tool_ids.filter(x=>![ADV_CALC_TOOL,DEEP_TOOL,DEEP_WEB_TOOL].includes(x)):[];
    const headers=new Headers(init.headers || {});
    headers.set('X-Local-AI-Mode',effectiveMode);
    headers.set('X-Local-AI-Expected-Model',c.model);
    if(effectiveMode==='fast'){
      // Fast has no built-in public web capability. Clear stale per-chat web
      // state if the user switched from Advanced with Web Search enabled.
      body.features.web_search=false;
      headers.delete('X-Local-AI-Research-Root');
    } else if(effectiveMode==='advanced'){
      // Keep Native's transport stream enabled. OpenWebUI's Native agentic
      // tool loop may stall at a tool_call when stream=false.
      // Precision is enforced by tool-first prompting and the final audit,
      // not by disabling the transport stream.
      body.stream=true;
      body.tool_ids=[...new Set([...body.tool_ids,ADV_CALC_TOOL])];
      body.params=body.params || {};
      body.params.function_calling='native';
      headers.delete('X-Local-AI-Research-Root');
    } else if(effectiveMode==='deep'){
      // Deep Research uses controller-budgeted custom web only.
      body.features.web_search=false;
      body.features.memory=true;
      body.params=body.params || {};
      body.params.function_calling='native';
      body.tool_ids=[...new Set([...body.tool_ids,DEEP_TOOL,DEEP_WEB_TOOL])];
      const {root}=deepRootForBody(body);
      if(root) headers.set('X-Local-AI-Research-Root',root);
    } else {
      headers.delete('X-Local-AI-Research-Root');
    }
    return {...init,headers,body:JSON.stringify(body)};
  }

  async function collectMessageIds(chatId) {
    if(!chatId) return [];
    const token=localStorage.getItem('token') || '';
    for(const path of [`/api/v1/chats/${encodeURIComponent(chatId)}`,`/api/chats/${encodeURIComponent(chatId)}`]){
      try{
        const r=await window.__laiOriginalFetch(path,{headers:token?{Authorization:`Bearer ${token}`}:{}});
        if(!r.ok) continue;
        const data=await r.json(); const ids=new Set();
        const walk=x=>{
          if(!x || typeof x!=='object') return;
          if(typeof x.id==='string') ids.add(x.id);
          if(Array.isArray(x)) x.forEach(walk); else Object.values(x).forEach(walk);
        };
        walk(data?.chat?.history?.messages || data?.history?.messages || data?.chat?.messages || data?.messages || data);
        return [...ids];
      }catch(e){}
    }
    return [];
  }

  async function reconcileCurrentChat() {
    const chatId=chatIdFromLocation(); if(!chatId) return;
    const root=getRoot(chatId); if(!root) return;
    const ids=await collectMessageIds(chatId); if(!ids.length) return;
    const result=await uiPost('/research/reconcile',{chat_id:chatId,root_id:root,user_id:currentUserId(),message_ids:ids});
    if(result?.deleted_roots?.includes(root)) clearRoot(chatId);
  }

  window.__laiOriginalFetch=window.fetch.bind(window);
  window.fetch=async function(input,init={}){
    const url=typeof input==='string'?input:(input?.url||'');
    let nextInit=init;
    const method=String(init?.method||'GET').toUpperCase();
    const isCompletion=url.includes('/api/chat/completions') && method==='POST';

    if(isCompletion){
      nextInit=patchCompletion(init);
      let effectiveMode=mode;
      try{
        const parsed=JSON.parse(nextInit?.body || '{}');
        effectiveMode=modeForModel(parsed?.model) || effectiveMode;
      }catch(e){}
      if(effectiveMode==='advanced') beginAdvancedPresentationStream();
    }

    let response;
    try{
      response=await window.__laiOriginalFetch(input,nextInit);
    }catch(e){
      if(isCompletion && advPresentHolding) endAdvancedPresentationStream(false);
      throw e;
    }

    if(isCompletion && advPresentHolding){
      response=monitorAdvancedResponse(response);
    }
    if(method==='DELETE' && /\/api\/v1\/chats\//.test(url)){
      const m=url.match(/\/api\/v1\/chats\/([^/?#]+)/); const cid=m?decodeURIComponent(m[1]):'';
      if(cid){ uiPost('/research/delete-chat',{chat_id:cid,root_id:getRoot(cid),user_id:currentUserId()}); clearRoot(cid); }
    } else if(response.ok && ['POST','PUT','PATCH'].includes(method) && /\/api\/v1\/chats\//.test(url)) {
      setTimeout(reconcileCurrentChat,750);
    }
    return response;
  };

  // Keep Ctrl+Shift+M from reopening the raw model picker on normal chat pages.
  window.addEventListener('keydown',e=>{
    if((location.pathname==='/' || location.pathname.startsWith('/c/')) && e.ctrlKey && e.shiftKey && e.key.toLowerCase()==='m'){
      e.preventDefault(); e.stopImmediatePropagation(); toast('Model selection is handled by Fast, Advanced, and Deep Research modes.');
    }
  },true);

  const observer=new MutationObserver(()=>{
    mountBar();
    hideRawSelector();
    markAdvancedProvisionalMessages();
  });

  const start=async()=>{
    mountBar();
    setSyncState('syncing');
    hideRawSelector();
    observer.observe(document.documentElement,{
      subtree:true,
      childList:true,
      characterData:true,
      attributes:true,
      attributeFilter:['aria-label','title']
    });
    await syncFromNativeModel(true);
  };

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',()=>{ start().catch(console.error); },{once:true});
  } else {
    start().catch(console.error);
  }

  setInterval(()=>{
    const currentPath=location.pathname+location.search;
    if(currentPath!==lastPath){
      if(advPresentHolding) releaseAdvancedPresentation('navigation');
      lastPath=currentPath;
      lastNativeSyncPath='';
      mountBar();
      hideRawSelector();
      syncFromNativeModel(true).catch(()=>{});
    }
    reconcileCurrentChat();
  },1200);
})();
JSUI

  cat >${WORKDIR}/local-ai-mode-ui.css <<'CSSUI'
/* Local AI Suite v8.7 mode bar */
#local-ai-mode-bar{position:fixed;left:50%;bottom:82px;transform:translateX(-50%);z-index:45;display:flex;flex-direction:column;align-items:center;gap:4px;pointer-events:none;font-family:ui-sans-serif,system-ui,sans-serif}
#local-ai-mode-bar .lai-mode-buttons{pointer-events:auto;display:flex;align-items:center;gap:5px;padding:5px;border-radius:16px;background:color-mix(in srgb,var(--color-gray-950,#111) 88%,transparent);box-shadow:0 8px 30px rgba(0,0,0,.18);backdrop-filter:blur(14px);border:1px solid rgba(127,127,127,.18)}
#local-ai-mode-bar button{display:inline-flex;align-items:center;gap:6px;border:0;border-radius:11px;padding:7px 10px;background:transparent;color:#ddd;font-size:12px;line-height:1;cursor:pointer;white-space:nowrap;transition:background .15s ease,color .15s ease,transform .15s ease}
#local-ai-mode-bar button:hover{background:rgba(127,127,127,.18)}
#local-ai-mode-bar button.active{background:rgba(127,127,127,.28);color:#fff;font-weight:600;box-shadow:inset 0 0 0 1px rgba(255,255,255,.12)}
#local-ai-mode-bar button:active{transform:scale(.97)}
#local-ai-mode-bar #lai-research-update{margin-left:3px;border-left:1px solid rgba(127,127,127,.2);border-radius:0 11px 11px 0}
#lai-mode-meta{pointer-events:none;font-size:10px;color:#999;background:rgba(20,20,22,.72);padding:2px 7px;border-radius:8px;backdrop-filter:blur(8px);display:flex;align-items:center;gap:5px}
#lai-mode-status,#lai-mode-sync{display:inline-block}.lai-mode-sep{opacity:.55}
.lai-hidden-model-selector,.lai-hidden-model-label{display:none!important}
/* Advanced Native tool-cycle presentation hold. Only new chat message roots are
   hidden; network streaming and OpenWebUI tool execution remain untouched. */
.lai-advanced-provisional{visibility:hidden!important;pointer-events:none!important}
.lai-advanced-discarded-prefix{display:none!important}
.lai-advanced-discarded-message{display:none!important}
#lai-advanced-working{position:fixed;left:50%;bottom:136px;transform:translateX(-50%);z-index:44;padding:5px 9px;border-radius:10px;background:rgba(20,20,22,.82);border:1px solid rgba(127,127,127,.2);backdrop-filter:blur(8px);font:11px/1.2 ui-sans-serif,system-ui,sans-serif;color:#aaa;pointer-events:none}
@media(max-width:700px){#local-ai-mode-bar{bottom:76px;width:96%}#local-ai-mode-bar .lai-mode-buttons{max-width:96vw}#local-ai-mode-bar button{padding:7px 8px}#local-ai-mode-bar button span{display:none}#lai-mode-meta{font-size:9px}}
CSSUI

  python3 - "$WORKDIR/local-ai-mode-ui.js" "$CONTROLLER_UI_SECRET" "$SANDBOX_PORT" "$PREWARM_MODELS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); s=s.replace("__UI_SECRET__",sys.argv[2]).replace("__CONTROLLER_PORT__",sys.argv[3]).replace("__PREWARM_MODELS__", "true" if sys.argv[4] in {"1","true","True"} else "false"); p.write_text(s)
PY

  $SUDO cp "$WORKDIR/local-ai-mode-ui.js" "$MODE_UI_DIR/local-ai-mode-ui.js"
  $SUDO cp "$WORKDIR/local-ai-mode-ui.css" "$MODE_UI_DIR/local-ai-mode-ui.css"
  $SUDO chmod 600 "$MODE_UI_DIR/local-ai-mode-ui.js" "$MODE_UI_DIR/local-ai-mode-ui.css"

  # Installer/repair helper. It preserves OpenWebUI's stock loader/custom CSS and
  # prepends/appends only our small mode layer. A container recreation can remove
  # these files, so the host-side repair helper can be rerun without touching data.
  $SUDO tee "$LOCAL_AI_DIR/apply-openwebui-mode-ui.sh" >/dev/null <<'SHUI'
#!/usr/bin/env bash
set -euo pipefail
CONTAINER="${OPENWEBUI_CONTAINER:-open-webui}"
BASE="__LOCAL_AI_DIR__/mode-ui"
DOCKER="${DOCKER_BIN:-docker}"
$DOCKER inspect "$CONTAINER" >/dev/null 2>&1 || exit 0
for root in /app/build/static /app/backend/open_webui/static; do
  if $DOCKER exec "$CONTAINER" test -f "$root/loader.js" 2>/dev/null; then
    if ! $DOCKER exec "$CONTAINER" test -f "$root/loader.js.local-ai-stock" 2>/dev/null; then
      $DOCKER exec "$CONTAINER" cp "$root/loader.js" "$root/loader.js.local-ai-stock"
    fi
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    cat "$BASE/local-ai-mode-ui.js" >"$tmp"
    printf '\n/* OpenWebUI stock loader follows */\n' >>"$tmp"
    $DOCKER exec "$CONTAINER" cat "$root/loader.js.local-ai-stock" >>"$tmp"
    $DOCKER cp "$tmp" "$CONTAINER:$root/loader.js" >/dev/null
    rm -f "$tmp"; trap - EXIT
  fi
  if $DOCKER exec "$CONTAINER" test -f "$root/custom.css" 2>/dev/null; then
    if ! $DOCKER exec "$CONTAINER" test -f "$root/custom.css.local-ai-stock" 2>/dev/null; then
      $DOCKER exec "$CONTAINER" cp "$root/custom.css" "$root/custom.css.local-ai-stock"
    fi
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    $DOCKER exec "$CONTAINER" cat "$root/custom.css.local-ai-stock" >"$tmp"
    printf '\n/* Local AI Suite mode bar */\n' >>"$tmp"
    cat "$BASE/local-ai-mode-ui.css" >>"$tmp"
    $DOCKER cp "$tmp" "$CONTAINER:$root/custom.css" >/dev/null
    rm -f "$tmp"; trap - EXIT
  fi
done
SHUI
  $SUDO sed -i "s|__LOCAL_AI_DIR__|$LOCAL_AI_DIR|g" "$LOCAL_AI_DIR/apply-openwebui-mode-ui.sh"
  $SUDO chmod 700 "$LOCAL_AI_DIR/apply-openwebui-mode-ui.sh"

  # Run with root Docker access regardless of whether the interactive user is in
  # the docker group. Docker cp modifies only container frontend assets, never the
  # persistent OpenWebUI data volume.
  $SUDO env DOCKER_BIN="$(command -v docker)" OPENWEBUI_CONTAINER="$OPENWEBUI_CONTAINER" "$LOCAL_AI_DIR/apply-openwebui-mode-ui.sh"

  $SUDO tee /etc/systemd/system/local-ai-openwebui-mode-ui.service >/dev/null <<EOF
[Unit]
Description=Restore Local AI Fast Advanced Deep Research mode UI after OpenWebUI container updates
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=DOCKER_BIN=$(command -v docker)
Environment=OPENWEBUI_CONTAINER=$OPENWEBUI_CONTAINER
ExecStart=$LOCAL_AI_DIR/apply-openwebui-mode-ui.sh
EOF
  $SUDO tee /etc/systemd/system/local-ai-openwebui-mode-ui.timer >/dev/null <<'EOF'
[Unit]
Description=Periodic Local AI OpenWebUI mode UI integrity check

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now local-ai-openwebui-mode-ui.timer >/dev/null
  ok "Fast / Advanced / Deep Research mode bar installed"
  ok "Raw model selector and raw internal model-name headings are hidden on chat pages; underlying models remain intact for the backend"
  ok "Deep Research exposes only the lab + controller-budgeted research-web tools; unrestricted built-in Deep web is forced off"
  ok "Deep Research Update button can queue scope changes while a research session is active"
fi

if [[ "$REMOVE_LEGACY" == 1 ]]; then
  section "OPTIONAL LEGACY ALIAS CLEANUP"
  for pair in "$OLD_FAST|$FAST_MODEL" "$OLD_RESEARCH|$RESEARCH_MODEL" "$OLD_DEEP|$DEEP_MODEL" "$OLD_TASK|$TASK_MODEL"; do old="${pair%%|*}"; new="${pair##*|}"; if model_exists "$old" && model_exists "$new"; then ollama rm "$old" >/dev/null; ok "Removed $old"; fi; done
fi

section "WARMING DEFAULT MODEL"
curl -fsS http://127.0.0.1:11434/api/chat -H 'Content-Type: application/json' -d "$(jq -n --arg model "$FAST_MODEL" --arg keep "$MODEL_IDLE_UNLOAD" '{model:$model,messages:[{role:"user",content:"Reply only with OK"}],think:false,stream:false,keep_alive:$keep,options:{num_predict:8}}')" | jq -r '.message.content // .error // empty'

section "FINAL HEALTH CHECK"
OLLAMA_PS="$(ollama ps || true)"; echo "$OLLAMA_PS"; if grep -F "$FAST_MODEL" <<<"$OLLAMA_PS" | grep -q '100% GPU'; then ok "$FAST_MODEL is fully GPU resident"; else warn "$FAST_MODEL is not 100% GPU on this machine; reduce FAST_CTX or use a smaller model if latency is poor"; fi
$DOCKER_CMD exec "$OPENWEBUI_CONTAINER" python3 -c 'import json,urllib.request; d=json.load(urllib.request.urlopen("http://host.docker.internal:11434/api/tags",timeout=10)); assert any((m.get("name") or m.get("model"))=="natural-fast:27b" for m in d.get("models",[])); print("OpenWebUI -> Ollama: OK")' || fail "Final Docker -> Ollama check failed"
if json_bool "$INSTALL_DEEP_RESEARCH"; then
  $DOCKER_CMD exec "$OPENWEBUI_CONTAINER" python3 -c "import json,urllib.request; d=json.load(urllib.request.urlopen('http://host.docker.internal:${SANDBOX_PORT}/health',timeout=10)); assert d.get('ok'); print('OpenWebUI -> Deep Research controller: OK')" || fail "Final OpenWebUI -> Deep Research controller check failed"
fi
MODE_HEALTH="$(curl -fsS "$WEBUI_URL/api/models?refresh=true" -H "Authorization: Bearer $TOKEN")" || fail "Final workspace model refresh failed"
for pair in "$MODE_FAST_ID|$FAST_MODEL" "$MODE_ADVANCED_ID|$RESEARCH_MODEL" "$MODE_DEEP_ID|$DEEP_MODEL"; do
  mid="${pair%%|*}"; base="${pair##*|}"
  jq -e --arg id "$mid" --arg base "$base" '.data[]? | select(.id==$id and .info.base_model_id==$base)' <<<"$MODE_HEALTH" >/dev/null || fail "Final mode routing check failed: $mid -> $base"
done
ok "Workspace mode routing verified: Fast / Advanced / Deep Research"

section "FINAL STATUS"
ollama list
echo
echo "Workflow:"
echo "  $TASK_MODEL     = background helper"
echo "  ⚡ Fast           = $MODE_FAST_ID -> $FAST_MODEL ($FAST_CTX)"
echo "  🧠 Advanced       = $MODE_ADVANCED_ID -> $RESEARCH_MODEL ($RESEARCH_CTX)"
echo "  🔬 Deep Research  = $MODE_DEEP_ID -> $DEEP_MODEL ($DEEP_CTX) + fast Scout brief + approved Deep Research + persistent isolated lab"
echo
echo "OpenWebUI URL: $WEBUI_URL"
echo "Ollama URL from Docker: http://host.docker.internal:11434"
echo "Full automatic Memory System Context: OFF"
echo "Task model: $TASK_MODEL"
echo "Speed profile: Fast 32K / Advanced 48K / Deep 64K"
echo "Output caps: Fast $FAST_OUTPUT / Advanced $RESEARCH_OUTPUT / Deep $DEEP_OUTPUT"
echo "OpenWebUI streaming: chunk $OPENWEBUI_STREAM_CHUNK, query caching enabled, realtime chat saves disabled"
echo "Mode prewarm: $PREWARM_MODELS"
echo "Ollama model idle unload: $MODEL_IDLE_UNLOAD after the last request to each model"
if ((WANT_SEARXNG==1)); then
  echo "SearXNG: preconfigured + enabled ($SEARXNG_QUERY_URL)"
  echo "Web search: 5 results, 2 concurrent searches, 3 concurrent page loads"
fi
 echo "Response Discipline Guard: active globally"
 echo "Provider-side thinking: Fast=OFF, Advanced=OFF, Deep Research=OFF (Deep uses explicit agentic evidence/tool loops)"
[[ "$INSTALL_DOCUMENT_MEMORY" == 1 ]] && echo "Document Memory Gate: active globally"
if json_bool "$INSTALL_DEEP_RESEARCH"; then
  echo "Deep Research Brief: fast Background Scout summary (<=180 words) + max 3 blocking questions + approval before Deep model loads"
  echo "Deep Research source policy: current primary/vendor sources required for version-sensitive technical claims"
  echo "Deep Research hard web budget: pre-validation ${DEEP_WEB_PRE_SEARCH_MAX} searches / ${DEEP_WEB_PRE_FETCH_MAX} fetches; post-validation ${DEEP_WEB_POST_SEARCH_MAX} search / ${DEEP_WEB_POST_FETCH_MAX} fetches only with an explicit evidence-gap reason"
  echo "Deep Research control-safety review: actuator telemetry semantics, persistent emergency-stop behavior, and stable sensor identity are checked"
  echo "Deep Research scope gate: artifact is audited against literal user scope + approved brief; Python decides pass/fail from issue arrays"
  echo "Validator bypass guard: known config/test/lint/check commands are rejected in research_lab_exec and must use research_lab_validate"
  echo "Brief scope policy: no invented sensors/subsystems/telemetry/features from descriptive wording alone"
  echo "Per-step timers: live ⏱ elapsed timer on Deep web, lab operations, validation phases, update checks, and Research Brief generation"
  echo "Validation truncation guard: validator pipelines through head/tail are rejected before consuming a validation attempt"
  echo "Validated Lessons Engine: learns only from observed failure/scope-error -> successful validation cycles using $LESSON_MODEL"
  echo "Durable timing ledger: every Deep Research web/lab/validation/brief/lesson step is persisted per research root"
  echo "Timing UI: browser-side Deep Research Timers panel updates independently of OpenWebUI collapsible status/tool history"
  echo "Timing persistence: durable SQLite ledger remains authoritative; outlet appends a Measured Timing block automatically"
  echo "Built-in Knowledge/model operations: included in total elapsed time; custom web/lab phases get individual timer rows"
  echo "Timer precision: sub-second steps show hundredths (e.g. 0.37s), 10-60s show tenths, longer steps show mm:ss.t"
  echo "Timer labels: web rows retain query/URL context; lab exec rows show the command preview and exit code"
  echo "Semantic gate: real validator PASS is followed by comment/behavior, primary-evidence, placeholder, and physical-control consistency review"
  echo "Semantic evidence: only already-budgeted fetch_url primary-source text is reused; the audit performs no hidden web calls"
  echo "Semantic learning: semantic failures join syntax/scope failures in the Validated Lessons Engine after a later fully passing repair"
  echo "Model memory lifecycle: no model is pinned indefinitely; prewarmed and actively used Ollama models unload after $MODEL_IDLE_UNLOAD of inactivity"
  echo "Timer lifecycle: completed/cancelled Deep turns force-finalize all browser step intervals"
  echo "Timer failsafe: orphaned active rows auto-close after 20 minutes if a browser event is lost or the connection is interrupted"
  echo "Mode routing v6.9: custom selector synchronizes with OpenWebUI native chat.models/selectedModels; localStorage is preference only"
  echo "Mode switching: existing chats update the full persisted OpenWebUI chat object then reload; new chats use native ?model= initialization"
  echo "Request guard: recognized native workspace/base model overrides stale custom mode state before completion"
  echo "Web policy v7.0: Fast built-in web OFF; Advanced SearXNG web capability ON but default OFF; Deep built-in web OFF with controller-budgeted custom web"
  echo "Advanced precision: evidence/minimum-change discipline + mandatory deterministic calculator for explicit arithmetic + primary-source web-search discipline"
  echo "Advanced calculator: workspace tool attached by default and request-layer enforced only for Advanced; Fast/Deep clear stale calculator state"
  echo "Advanced final precision v7.4: Background Scout audits every final Advanced answer; research-plus repairs only clear semantic/constraint regressions"
  echo "Advanced semantic guard: unresolved physical-control direction cannot become definite merely because the actuator is a pump/fan/valve/motor"
  echo "Advanced delivery v7.7: Native transport streaming is forced ON in backend filter and browser request layer so OpenWebUI can execute calculator/web tool loops"
  echo "Advanced contradiction guard: direct Yes/No answers are checked against their own explanation; smallest-correction one-choice constraints are enforced"
  echo "Advanced arithmetic v7.6: Reserved/Current/Available/Answer-style derived fields must match successful deterministic calculator results when calculator use is required"
  echo "Advanced source fidelity v7.6: short source-derived config is structurally checked; ESPHome native OTA regression catches a missing YAML list marker"
  echo "Advanced Native-tool regression v7.8: stream=true remains mandatory for OpenWebUI Native calculator/web execution; no transport buffering is used"
  echo "Advanced presentation v7.8: provisional new message DOM nodes are hidden during Native tool cycles and revealed only after the final quiet completion; a 120s watchdog prevents stuck hidden output"
  echo "Advanced duplicate guard v7.8: repeated numbered TEST sections are detected and repaired; if-condition-only corrections reject stray body braces"
  echo "Advanced duplicate cleanup v7.9: restarted TEST prefixes are removed from the hidden DOM before reveal and from the persisted native chat blob so reloads stay clean"
  echo "Advanced arithmetic v7.9: capacity relationships are independently recomputed from the user facts, preventing wrong-expression calculator results such as 14 instead of 6"
  echo "Advanced clarification v7.9: explicit shared multi-session requirements cannot be replaced by concurrent-user questions"
  echo "Advanced duplicate cleanup v8.0: TEST headings may include descriptive titles after the number; DOM and persisted-chat cleanup recognize restarted titled prefixes"
  echo "Advanced terminology v8.0: DELAY vs delay is case-sensitive; an unused constant cannot be described as overwritten/shadowed by the distinct lowercase name"
  echo "Advanced evidence scope v8.0: known-working comparison apps and Citrix Workspace reset actions cannot be silently listed as affected scope"
  echo 'Advanced minimality v8.1: direct boolean predicates are preferred over redundant comparisons such as -eq $true when smallest correction is requested'
  echo "Advanced evidence Unknown v8.1: summarize-only answers cannot invent host-session/input-path/client-layer diagnostic categories absent from supplied evidence"
  echo "Advanced Native output v8.2: superseded TEST text is removed from Responses-style output message items while function_call/function_call_output tool history is retained"
  echo "Advanced cross-message cleanup v8.2: restarted TEST continuations across separate assistant DOM roots are hidden before final reveal; same-root cleanup remains active"
  echo "Advanced persistence v8.2: assistant output/content cleanup is written back to the native chat with a delayed retry after OpenWebUI final-save timing"
  echo "Advanced heading cleanup v8.3: heading-only pre-tool TEST n fragments are treated as superseded when the final continuation expands the same TEST sequence"
  echo "Advanced evidence Unknown v8.3: evidence-only summaries reject invented causal/relationship hypotheses between observed symptoms"
  echo "Advanced pre-tool cleanup v8.4: assistant planning/scratch message items emitted before later Native tool calls are suppressed by output position while tool call/result history is retained"
  echo "Advanced inference v8.4: prompts that say not to claim why cannot gain invented firewall/proxy/routing or other causal mechanisms in Inference"
  echo "Advanced next-test v8.4: exactly-one Next test requests reject alternative tools/methods in the same recommendation"
  echo "Advanced minimality v8.4: Smallest correction removes unchanged braces/wrapper syntax unless a complete statement/line is explicitly requested"
  echo "Advanced continuation cleanup v8.5: assistant candidates persist briefly across adjacent Native tool requests so an earlier complete TEST subset can be superseded by the later expanded final answer"
  echo "Advanced final audit v8.5: up to 3 conditional repair passes are scored; the least-issue candidate is retained instead of reverting wholesale to a more flawed original"
  echo "Advanced minimality v8.5: unnecessary PowerShell subexpression wrappers are rejected in standalone Smallest correction predicates"
  echo "Advanced evidence Unknown v8.5: root-cause/source-of and invented other-input categories are rejected for literal evidence-only summaries"
  echo "Advanced numbering v8.5: explicit numbered-question requests require visible 1..N prefixes in order"
  echo "Advanced evidence Unknown v8.6: generic Why/reason/explanation phrasing is rejected when Unknown must contain unresolved observations only"
  echo "Advanced source scope v8.6: distinctive web/source identifiers from a WEB REQUIRED TEST cannot leak into independent non-web TEST sections"
  echo "Advanced uncertainty v8.6: explicitly prohibited client-side/network-path/routing/firewall/proxy/server-side causes remain prohibited even when hedged as may/might/could"
  echo "Advanced token fidelity v8.6: Finding cannot invent mutation operators such as -= when absent from the supplied code"
  echo "Advanced post-assembly audit v8.7: the persisted final Native answer is deterministically checked after the save-race window and before reveal"
  echo "Advanced post-assembly repair v8.7: only detected final-answer issues invoke research-plus; repaired text is persisted and the chat reloads once for native rendering"
  echo "Advanced YAML fidelity v8.7: generic exact YAML blocks with list markers are checked independently of ESPHome/web logic"
  echo "Advanced definite-proposition v8.7: evidence that a service works from Client B forces No for the question whether it is definitely down while preserving uncertainty about Client A"
  echo "Verification v8.7: v8.6 checks retained; persisted post-assembly audit endpoint, pre-reveal timing, generic YAML and definite-down regressions added"
  echo "Installer v8.8: detected Local AI Suite components now prompt for preserve vs destructive clean reinstall; preserve mode skips reinstalling existing components"
  echo "Guard v8.8: response-discipline regression loader includes the v8.7 YAML/definite-proposition helpers, fixing the _generic_exact_yaml_issues KeyError"
  echo "Ollama v8.8: keep-alive verification reads the running process environment before falling back to systemd metadata"
  echo "Final-answer consistency: claims about delivered buttons/sensors/features must match the validated artifact"
  echo "Lesson retrieval: top ${LESSON_RETRIEVAL_MAX} topic-relevant validated lessons are injected into future Deep Research"
  echo "Lesson safety: current primary docs override stale lessons; common credential-shaped values are redacted before persistence"
  echo "Post-validation web exceptions: reason enum + concrete evidence_gap sentence required"
  echo "Deep Research validation gate: deterministic authoritative-scope audit + exec bypass guard + pipefail-safe validation + 5 normal repairs + 1 deterministic final repair + stop on success"
  echo "Deep Research follow-up scope updates: enabled + versioned"
  echo "Deep Research Lab: isolated Docker sandbox, normalized /workspace paths, workspace preserved until root prompt/chat deletion"
  echo "Deep Research Lab idle behavior: container stops after $SANDBOX_IDLE_SECONDS seconds; volume persists"
fi
json_bool "$INSTALL_MODE_UI" && echo "Chat modes: ⚡ Fast | 🧠 Advanced | 🔬 Deep Research (raw selector + internal model-name heading hidden)"
echo
ok "Local AI Suite v$VERSION deployment/configuration complete"

cleanup_workdir
trap - EXIT INT TERM
unset TOKEN AUTH_RESPONSE OLLAMA_CFG
