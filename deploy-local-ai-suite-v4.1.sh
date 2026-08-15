#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Local AI Suite v5.8
# Fedora + native Ollama + Docker Open WebUI + SearXNG + mode UI + Deep Research lab
#
# Idempotent deployment/configuration for an evidence-first local assistant.
# Existing systems are preserved; missing components are installed only when
# needed. Friendly model aliases reuse existing Ollama layers whenever possible.
###############################################################################

VERSION="5.8"

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

section "BASIC DEPENDENCIES"
if need_cmd dnf; then
  PKGS=(); need_cmd curl || PKGS+=(curl); need_cmd jq || PKGS+=(jq); need_cmd python3 || PKGS+=(python3); need_cmd openssl || PKGS+=(openssl); need_cmd ss || PKGS+=(iproute)
  ((${#PKGS[@]})) && $SUDO dnf install -y "${PKGS[@]}"
fi
for c in curl jq python3 openssl; do need_cmd "$c" || fail "$c is required"; done

section "OLLAMA"
if ! need_cmd ollama; then info "Installing Ollama"; curl -fsSL https://ollama.com/install.sh | sh; fi
if need_cmd systemctl; then
  $SUDO systemctl enable --now ollama >/dev/null 2>&1 || true
  $SUDO mkdir -p /etc/systemd/system/ollama.service.d
  $SUDO tee /etc/systemd/system/ollama.service.d/99-local-ai-suite.conf >/dev/null <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_NUM_PARALLEL=1"
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl restart ollama
fi
wait_for_url "http://127.0.0.1:11434" 90 || fail "Ollama did not start"
ok "Ollama is running"
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

section "OPENWEBUI MODE WORKSPACE MODELS"
# Use first-class OpenWebUI workspace models instead of only rewriting the raw
# provider model ID in browser fetches. This keeps model routing, capabilities,
# chat metadata, exports, and filter __model__.info.base_model_id consistent.
MODE_MODELS_PAYLOAD="$(jq -n \
  --arg fast_id "$MODE_FAST_ID" --arg fast_base "$FAST_MODEL" \
  --arg adv_id "$MODE_ADVANCED_ID" --arg adv_base "$RESEARCH_MODEL" \
  --arg deep_id "$MODE_DEEP_ID" --arg deep_base "$DEEP_MODEL" '
{models:[
  {id:$fast_id,base_model_id:$fast_base,name:"Fast",is_active:true,params:{function_calling:"native",think:false},access_grants:[],meta:{description:"Fast 32K local assistant",capabilities:{file_context:true,file_upload:true,web_search:true,memory:true,citations:true,status_updates:true,code_interpreter:false},builtinTools:{knowledge:true,memory:true,web_search:true,code_interpreter:false},tags:[{name:"Local AI Suite"}]}},
  {id:$adv_id,base_model_id:$adv_base,name:"Advanced",is_active:true,params:{function_calling:"native",think:false},access_grants:[],meta:{description:"Advanced 48K local assistant",capabilities:{file_context:true,file_upload:true,web_search:true,memory:true,citations:true,status_updates:true,code_interpreter:false},builtinTools:{knowledge:true,memory:true,web_search:true,code_interpreter:false},tags:[{name:"Local AI Suite"}]}},
  {id:$deep_id,base_model_id:$deep_base,name:"Deep Research",is_active:true,params:{function_calling:"native",think:false},access_grants:[],meta:{description:"Deep Research 64K agent with budget-enforced web, knowledge, memory, research brief and isolated lab",capabilities:{file_context:true,file_upload:true,web_search:false,memory:true,citations:true,status_updates:true,code_interpreter:false},builtinTools:{knowledge:true,memory:true,web_search:false,code_interpreter:false},defaultFeatureIds:[],tags:[{name:"Local AI Suite"},{name:"Deep Research"}]}}
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
version: 1.3.0
description: Prevent reasoning/self-review loops, silently normalize obvious typos, and force all three local modes to use concise non-thinking output.
"""
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

class Filter:
    class Valves(BaseModel):
        force_fast_thinking_off: bool = Field(default=True)
        force_research_thinking_off: bool = Field(default=True)
        force_task_thinking_off: bool = Field(default=True)
        force_deep_thinking_off: bool = Field(default=True)

    def __init__(self):
        self.valves = self.Valves()

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
                body["messages"] = add_or_update_system_message(
                    DISCIPLINE, messages, append=True
                )
        return body
PYGUARD
python3 -c 'import ast,sys,pathlib; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "${WORKDIR}/response_discipline_guard.py"
GUARD_CONTENT="$(cat ${WORKDIR}/response_discipline_guard.py)"
GUARD_JSON="$(jq -n --arg id "$GUARD_ID" --arg name "$GUARD_NAME" --arg content "$GUARD_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Silently handles obvious typos, suppresses visible self-review/repetition loops, and keeps Natural Fast / Research Plus non-thinking by default."}}')"
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
WARM_MODELS = {
    "natural-fast:27b",
    "research-plus:27b",
    "deep-research:27b",
}

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


def reserve_web_slot(row, kind, target, reason=""):
    kind = str(kind or "").strip().lower()
    if kind not in {"search", "fetch"}:
        raise ValueError("invalid web operation")

    post = validation_has_started(row)
    phase = "post" if post else "pre"
    reason = str(reason or "").strip().lower()

    if post and reason not in POST_VALIDATION_REASONS:
        raise RuntimeError(
            "POST-VALIDATION WEB LOCK: web access is blocked after validation begins. "
            "If the validator output is genuinely insufficient, retry once with post_validation_reason set to exactly one of: "
            "validator_insufficient, docs_missing_or_ambiguous, primary_sources_conflict."
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
            """INSERT INTO web_usage(chat_id,root_id,user_id,kind,target,phase,reason,created_at)
               VALUES(?,?,?,?,?,?,?,?)""",
            (
                row["chat_id"], row["root_id"], row["user_id"], kind,
                str(target or "")[:4000], phase, reason, int(time.time()),
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


def research_web_search(row, query, reason=""):
    query = str(query or "").strip()
    if not query:
        raise ValueError("query is required")

    budget = reserve_web_slot(row, "search", query, reason)
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


def research_web_fetch(row, url, reason=""):
    url = validate_public_url(url)
    budget = reserve_web_slot(row, "fetch", url, reason)

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
    touch(row)
    return {
        "ok": True,
        "url": final_url,
        "content_type": content_type,
        "content": body,
        "budget": budget,
    }


def validation_record(row, artifact, command, exit_code, output):
    artifact = str(artifact or "generated artifact").strip()[:500] or "generated artifact"
    command = str(command or "")[:12000]
    output_hash = hashlib.sha256(str(output or "").encode("utf-8", "replace")).hexdigest()
    now = int(time.time())
    with conn() as db:
        db.execute(
            """INSERT INTO validation_runs(
                   chat_id,root_id,user_id,artifact,command,exit_code,output_hash,created_at
               ) VALUES(?,?,?,?,?,?,?,?)""",
            (row["chat_id"], row["root_id"], row["user_id"], artifact,
             command, int(exit_code), output_hash, now),
        )
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
    failed = int(exit_code) != 0
    repeated = bool(failed and int(same_failure) >= 2)

    # Five normal repair attempts are allowed. If attempt 5 reveals a NEW,
    # deterministic validator error, the model may make exactly one final
    # direct repair without broadening research. Attempt 6 is the absolute cap.
    final_repair_allowed = bool(
        failed
        and int(attempts) == 5
        and not repeated
    )
    repair_budget_reached = bool(
        failed
        and (
            int(attempts) >= 6
            or repeated
        )
    )

    return {
        "validation_attempt": int(attempts),
        "same_failure_count": int(same_failure),
        "final_repair_allowed": final_repair_allowed,
        "repair_budget_reached": repair_budget_reached,
        "repeated_failure": repeated,
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
    web = web_usage_counts(row)
    return {
        "elapsed_seconds": int(elapsed),
        "validation_runs": int(total),
        "validation_failed": int(failed),
        "validation_passed": int(passed),
        "soft_time_budget_seconds": 900,
        "over_soft_time_budget": bool(elapsed >= 900),
        "web": {
            **web,
            "pre_search_max": WEB_PRE_SEARCH_MAX,
            "pre_fetch_max": WEB_PRE_FETCH_MAX,
            "post_search_max": WEB_POST_SEARCH_MAX,
            "post_fetch_max": WEB_POST_FETCH_MAX,
        },
    }


def brief_save(row, brief):
    brief = str(brief or "").strip()[:30000]
    now = int(time.time())
    previous_brief = str(row.get("brief") or "").strip()

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
            "UPDATE sessions SET brief=?,revisions=?,updated_at=?,last_used=? WHERE chat_id=? AND root_id=? AND user_id=?",
            (brief, json.dumps(rev), now, now, row["chat_id"], row["root_id"], row["user_id"]),
        )
        db.commit()

    return session_get(row["chat_id"], row["root_id"], row["user_id"])


def require_fields(data):
    return session_ensure(data.get("chat_id"), data.get("root_id"), data.get("user_id"))


def handle_admin(path, data):
    row = require_fields(data)
    if path == "/research/state":
        return {"ok": True, "session": row, "sandbox_running": docker_running(row["container_name"]) if docker_exists(row["container_name"]) else False}
    if path == "/research/brief/save":
        row = brief_save(row, data.get("brief"))
        return {"ok": True, "brief": row["brief"], "revisions": json.loads(row["revisions"] or "[]")}
    if path == "/web/search":
        return research_web_search(row, data.get("query"), data.get("post_validation_reason"))

    if path == "/web/fetch":
        return research_web_fetch(row, data.get("url"), data.get("post_validation_reason"))

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
        if str(data.get("kind") or "").lower() == "validation":
            result.update(
                validation_record(
                    row,
                    data.get("artifact") or "generated artifact",
                    command,
                    rc,
                    out,
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
        "keep_alive": -1,
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


def handle_ui(path, data):
    if path == "/model/warm":
        return warm_model(data.get("model"))

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
            return self._json(200, {"ok": True, "service": "deep-research-sandbox-controller", "version": "1.5"})
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
Environment=LAI_SEARXNG_URL=$SEARXNG_CONTROLLER_URL
Environment=LAI_WEB_PRE_SEARCH_MAX=$DEEP_WEB_PRE_SEARCH_MAX
Environment=LAI_WEB_PRE_FETCH_MAX=$DEEP_WEB_PRE_FETCH_MAX
Environment=LAI_WEB_POST_SEARCH_MAX=$DEEP_WEB_POST_SEARCH_MAX
Environment=LAI_WEB_POST_FETCH_MAX=$DEEP_WEB_POST_FETCH_MAX

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
  [[ "$CONTROLLER_VERSION" == "1.5" ]] || fail "Research controller upgrade did not take effect (expected 1.5, got ${CONTROLLER_VERSION:-unknown})"
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
version: 1.6.0
description: Persistent per-research Docker laboratory with explicit validation support. Exposed only by Deep Research mode.
"""
import json
from typing import Optional
import httpx

CONTROLLER = "__CONTROLLER_URL__"
KEY = "__CONTROLLER_SECRET__"


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

    async def research_lab_status(self, __request__=None, __user__=None, __metadata__=None) -> str:
        """Check whether the Deep Research laboratory exists/runs and show its persistent workspace identity."""
        data = await self._post("/sandbox/status", self._ctx(__request__, __user__, __metadata__))
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
        """Run a shell command inside the isolated persistent Deep Research lab for empirical testing, builds, scripts, repositories, or reproducible experiments. Shell pipelines use pipefail, so a failed command inside a pipeline is reported as a failure. For generated code or configuration, use research_lab_validate before the final answer whenever practical. Never assume this is the Fedora host."""
        ctx = self._ctx(__request__, __user__, __metadata__)
        if __event_emitter__ is not None:
            await __event_emitter__({"type":"status","data":{"description":"Research Lab: running experiment","done":False,"hidden":False}})
        data = await self._post("/sandbox/exec", {**ctx, "command": command, "timeout": max(1, min(int(timeout), 600))})
        if __event_emitter__ is not None:
            await __event_emitter__({"type":"status","data":{"description":f"Research Lab: command finished with exit code {data.get('exit_code')}","done":True,"hidden":False}})
        return f"exit_code={data.get('exit_code')}\n{data.get('output','')}"

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
        """MANDATORY verification tool for Deep Research when generated code, configuration, manifests, scripts, build instructions, or other machine-checkable artifacts can reasonably be validated in Linux. Run the real validator/compiler/test command, inspect failures, repair the artifact, and validate again before presenting it as working. Do not pipe validator output through tail or grep merely to shorten it because output is already bounded and pipefail is enforced."""
        ctx = self._ctx(__request__, __user__, __metadata__)
        if __event_emitter__ is not None:
            await __event_emitter__({"type":"status","data":{"description":f"Research Lab: validating {artifact}","done":False,"hidden":False}})
        data = await self._post(
            "/sandbox/exec",
            {
                **ctx,
                "command": command,
                "timeout": max(1, min(int(timeout), 600)),
                "kind": "validation",
                "artifact": artifact,
            },
        )
        code = int(data.get("exit_code", -1))
        if __event_emitter__ is not None:
            await __event_emitter__({"type":"status","data":{"description":f"Research Lab validation {'passed' if code == 0 else 'failed'} for {artifact}","done":True,"hidden":False}})
        verdict = "VALIDATION PASSED" if code == 0 else "VALIDATION FAILED"
        attempt = int(data.get("validation_attempt", 0) or 0)
        same = int(data.get("same_failure_count", 0) or 0)
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

        if code == 0:
            notices.append(
                "STOP CONDITION: validation passed. If the approved Research Brief is satisfied and "
                "there is no new user update, do not search again. Stop the lab and write the final answer."
            )
        meta = f"validation_attempt={attempt}"
        if same:
            meta += f" same_failure_count={same}"
        notice_text = ("\n" + "\n".join(notices)) if notices else ""
        return (
            f"{verdict}: {artifact}\n"
            f"command={command}\n"
            f"exit_code={code}\n"
            f"{meta}{notice_text}\n"
            f"{data.get('output','')}"
        )

    async def research_lab_list(self, path: str = ".", __request__=None, __user__=None, __metadata__=None) -> str:
        """List files inside the persistent Deep Research workspace. Prefer relative paths. /workspace paths are accepted and normalized exactly once."""
        data = await self._post("/sandbox/list", {**self._ctx(__request__, __user__, __metadata__), "path": path})
        return data.get("output", "")

    async def research_lab_read(self, path: str, max_bytes: int = 50000, __request__=None, __user__=None, __metadata__=None) -> str:
        """Read a text file from the persistent Deep Research workspace. Prefer relative paths. /workspace paths are accepted and normalized exactly once."""
        data = await self._post("/sandbox/read", {**self._ctx(__request__, __user__, __metadata__), "path": path, "max_bytes": max(1, min(int(max_bytes), 200000))})
        return data.get("output", "")

    async def research_lab_write(self, path: str, content: str, __request__=None, __user__=None, __metadata__=None) -> str:
        """Write a file inside the persistent Deep Research workspace. Prefer relative paths such as solar-pump.yaml. /workspace paths are accepted and normalized exactly once."""
        data = await self._post("/sandbox/write", {**self._ctx(__request__, __user__, __metadata__), "path": path, "content": content})
        return json.dumps(data, ensure_ascii=False)

    async def research_check_updates(self, __request__=None, __user__=None, __metadata__=None) -> str:
        """Check for user research-scope updates queued while Deep Research is working. Call this after major research steps and before the final report."""
        data = await self._post("/research/update/poll", self._ctx(__request__, __user__, __metadata__))
        updates = data.get("updates") or []
        budget = data.get("budget") or {}
        elapsed = int(budget.get("elapsed_seconds", 0) or 0)
        minutes, seconds = divmod(elapsed, 60)
        web = budget.get("web") or {}
        budget_line = (
            f"RESEARCH BUDGET: elapsed={minutes}m{seconds:02d}s; "
            f"validations={int(budget.get('validation_runs', 0) or 0)} "
            f"(passed={int(budget.get('validation_passed', 0) or 0)}, "
            f"failed={int(budget.get('validation_failed', 0) or 0)}); "
            f"web pre-search={int(web.get('pre_search', 0) or 0)}/{int(web.get('pre_search_max', 0) or 0)}, "
            f"pre-fetch={int(web.get('pre_fetch', 0) or 0)}/{int(web.get('pre_fetch_max', 0) or 0)}, "
            f"post-search={int(web.get('post_search', 0) or 0)}/{int(web.get('post_search_max', 0) or 0)}, "
            f"post-fetch={int(web.get('post_fetch', 0) or 0)}/{int(web.get('post_fetch_max', 0) or 0)}."
        )
        if budget.get("over_soft_time_budget"):
            budget_line += (
                " SOFT TIME BUDGET EXCEEDED: stop broadening the investigation and finish from "
                "the strongest evidence already gathered unless a blocking gap remains."
            )
        if not updates:
            return "No new research updates.\n" + budget_line
        return (
            "USER RESEARCH UPDATES:\n"
            + "\n".join(f"- {u.get('text','')}" for u in updates)
            + "\n"
            + budget_line
        )

    async def research_save_brief(self, updated_brief: str, __request__=None, __user__=None, __metadata__=None) -> str:
        """Save an updated Research Brief after the user changes scope. Each changed brief becomes a new persistent revision."""
        data = await self._post("/research/brief/save", {**self._ctx(__request__, __user__, __metadata__), "brief": updated_brief})
        revs = data.get("revisions") or []
        return f"Research Brief saved as version {len(revs)}."

    async def research_lab_stop(self, __request__=None, __user__=None, __metadata__=None) -> str:
        """Stop the lab container to release CPU/RAM while preserving its workspace volume for follow-up research. The workspace is deleted only when its originating research prompt/chat is deleted."""
        data = await self._post("/sandbox/stop", self._ctx(__request__, __user__, __metadata__))
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
  ok "Validation tracking enabled: 5 normal repairs + 1 final deterministic repair, repeated-failure stop, and stop-on-success signal"

  section "INSTALLING BUDGET-ENFORCED DEEP RESEARCH WEB TOOL"
  cat >${WORKDIR}/deep_research_web.py <<'PYWEBTOOL'
"""
title: Deep Research Web
author: Local AI Suite
version: 1.0.0
description: Controller-enforced SearXNG search and safe public URL fetching for Deep Research only.
"""
import json
import httpx

CONTROLLER = "__CONTROLLER_URL__"
KEY = "__CONTROLLER_SECRET__"


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

    async def search_web(
        self,
        query: str,
        post_validation_reason: str = "",
        __request__=None,
        __user__=None,
        __metadata__=None,
    ) -> str:
        """Search through the controller-enforced SearXNG budget. Before validation, the hard default limit is 3 searches per approved scope. After validation begins, search is blocked unless post_validation_reason is exactly one of validator_insufficient, docs_missing_or_ambiguous, primary_sources_conflict. Never invent a reason only to bypass the lock."""
        data = await self._post(
            "/web/search",
            {
                **self._ctx(__request__, __user__, __metadata__),
                "query": query,
                "post_validation_reason": post_validation_reason,
            },
        )
        return json.dumps(data, ensure_ascii=False, indent=2)

    async def fetch_url(
        self,
        url: str,
        post_validation_reason: str = "",
        __request__=None,
        __user__=None,
        __metadata__=None,
    ) -> str:
        """Fetch one public http/https source through the controller-enforced budget. Before validation, the hard default limit is 5 fetches per approved scope. After validation begins, fetching is blocked unless post_validation_reason is exactly one of validator_insufficient, docs_missing_or_ambiguous, primary_sources_conflict. Prefer primary/vendor sources. Private and loopback destinations are blocked."""
        data = await self._post(
            "/web/fetch",
            {
                **self._ctx(__request__, __user__, __metadata__),
                "url": url,
                "post_validation_reason": post_validation_reason,
            },
        )
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
version: 1.5.0
description: Fast Scout-generated Research Brief approval, blocking clarifications, primary-source verification, sandbox validation, persistent revisions, and follow-up scope updates.
"""
import json
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
CONTROLLER = "__CONTROLLER_URL__"
KEY = "__CONTROLLER_SECRET__"
MARKER = "<local_ai_deep_research>"


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

    async def _ollama(self, model, system, prompt, predict=700):
        payload={
            "model":model,
            "messages":[{"role":"system","content":system},{"role":"user","content":prompt}],
            "think":False,"stream":False,"keep_alive":-1,
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

Need From You
- <only blocking question, if any>

Rules:
- Maximum 3 plan bullets.
- Maximum 3 blocking questions.
- Ask only questions whose answer materially changes architecture, safety, or correctness.
- If nothing is blocking, write exactly: None
- Do not include assumptions, evidence lists, testing details, implementation details, or explanations.
- Keep the entire response under 180 words."""
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

Need From You
- <only blocking question, if any>

Rules:
- Maximum 3 plan bullets.
- Maximum 3 blocking questions.
- Ask only questions whose answer materially changes architecture, safety, or correctness.
- If nothing is blocking, write exactly: None
- For code/configuration work, one plan bullet may say it will be validated in the sandbox.
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
            r"(?is)(?:^|\n)#{0,3}\s*Need From You\s*:?\s*\n(.*?)(?=\n#{0,3}\s*(?:Goal|Plan)\s*:?\s*\n|\Z)",
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
            if __event_emitter__ is not None:
                await __event_emitter__({"type":"status","data":{"description":"Preparing short Research Brief with Background Scout","done":False,"hidden":False}})
            brief=await self._make_brief(query)
            brief=await self._resolve_clarifications(brief,__event_call__)
            approved,brief=await self._approve_brief(brief,__event_call__)
            if not approved:
                body["tool_ids"]=[
                    x for x in (body.get("tool_ids") or [])
                    if x not in {DEEP_LAB_TOOL, DEEP_WEB_TOOL}
                ]
                body["think"]=False
                body["messages"]=add_or_update_system_message("The user cancelled Deep Research before it began. Reply only that Deep Research was cancelled and do not research the query.",body.get("messages") or [],append=True)
                return body
            await self._controller("/research/brief/save",{**ctx,"brief":brief})
            if __event_emitter__ is not None:
                await __event_emitter__({"type":"status","data":{"description":"Research Brief approved. Loading Deep Research now.","done":True,"hidden":False}})
        elif query:
            kind=await self._classify(query)
            if kind=="UPDATE":
                proposed=await self._make_brief("",previous=brief,update=query)
                approved,proposed=await self._approve_brief(proposed,__event_call__)
                if approved:
                    brief=proposed
                    await self._controller("/research/brief/save",{**ctx,"brief":brief})
                    if __event_emitter__ is not None:
                        await __event_emitter__({"type":"status","data":{"description":"Research scope updated; continuing with the revised brief","done":True,"hidden":False}})

        instructions=f"""{MARKER}
CURRENT RESEARCH BRIEF
{brief}

DEEP RESEARCH RULES
1. The Research Brief above is the user-approved scope, intentionally kept short. Treat it as the source of truth. After approval, develop whatever detailed internal execution plan is needed through tool use and evidence gathering, but do not dump that plan or chain-of-thought into the chat. Explicitly identify unresolved objectives in the final report.
2. Work in evidence loops: identify what must be known, gather evidence, verify it, then continue. Do not replace verification with long internal speculation.
3. For software versions, APIs, configuration syntax, command syntax, compatibility, security guidance, or vendor behavior that can change over time, PRIMARY SOURCES ARE REQUIRED whenever available. Prefer current official documentation, official source code, release notes, standards, or vendor knowledge articles over forums, summaries, and search snippets.
4. A search-result snippet is discovery, not proof. Use ONLY the budget-enforced Deep Research Web tool functions search_web and fetch_url for public research. OpenWebUI's unrestricted built-in web search is intentionally disabled in Deep Research. Fetch the primary source before asserting exact syntax or version-sensitive behavior.
5. HARD WEB BUDGETS ARE CONTROLLER-ENFORCED. Before validation, the default hard budget is 3 search_web calls and 5 fetch_url calls per approved scope. Never retry a WEB BUDGET EXHAUSTED error.
6. POST-VALIDATION WEB LOCK IS CONTROLLER-ENFORCED. After the first research_lab_validate call, first use the exact validator diagnostic and already-fetched primary documentation. Additional web access is allowed only when the evidence gap is real, using one of the tool's exact reasons: validator_insufficient, docs_missing_or_ambiguous, primary_sources_conflict. Never fabricate a reason merely to bypass the lock.
7. Use relevant Memory and Knowledge first for environment-specific facts, but never let remembered technical syntax override newer primary documentation. Clearly distinguish user-environment facts from public/vendor facts.
8. VALIDATION GATE: if the requested deliverable contains executable code, YAML/JSON/XML configuration, manifests, scripts, build instructions, queries, regexes, or another machine-checkable artifact, you MUST use the Deep Research Lab to validate it whenever a suitable validator/compiler/test tool can reasonably run in Linux. Use research_lab_write plus research_lab_validate or research_lab_exec. Install validation tooling in a venv/container if needed. Prefer relative workspace paths; absolute /workspace paths are also accepted. Do not pipe validator output through tail or grep merely to shorten it because lab output is already bounded. On failure, fix the artifact and validate again. Do not describe an artifact as working or complete if validation was skipped or failed.
9. VALIDATION EXIT CODES ARE AUTHORITATIVE. The lab enforces shell pipefail. If a validator in a pipeline fails, validation failed even if tail, tee, grep, or another later command succeeds.
10. REPAIR BUDGET: attempts 1 through 5 are the normal repair budget. If attempt 5 returns a NEW deterministic error, you may make exactly one final direct repair and validate once more without broadening the research. Attempt 6 is the absolute maximum. If the same failure appears twice, stop repeating the same fix and reassess immediately.
11. STOP ON SUCCESS: once a real validator/compiler/test command passes and the approved Research Brief is satisfied, do not continue browsing or experimenting merely to gather more sources. Check research_check_updates once, stop the lab, and write the final answer. Continue only for an unresolved brief objective, conflicting primary evidence, or a new user update.
12. SEARCH DISCIPLINE: once authoritative documentation answers the needed syntax or behavior, stop searching even if budget remains. Budget is a ceiling, not a target.
13. PYTHON TOOLING IN THE LAB: the sandbox root filesystem is intentionally read-only. Never install Python packages into the system interpreter or /home/researcher. Create a venv below /workspace/.venvs and use that venv's pip and executables. Example: python3 -m venv /workspace/.venvs/test && /workspace/.venvs/test/bin/pip install esphome. HOME and package caches already point into /workspace.
14. TIME BUDGET: research_check_updates reports elapsed time. For ordinary configuration or coding research, 15 minutes is a soft ceiling, not a target. If the soft budget is exceeded, stop broadening scope and finish from the strongest evidence unless a blocking gap remains.
15. The lab is an isolated Linux container, never the Fedora host. A successful lab test proves only the conditions actually reproduced there. State what was and was not tested.
16. Keep useful lab files under /workspace. The persistent volume belongs to this research root and survives follow-up turns. Call research_lab_stop before the final report to release CPU/RAM while preserving the workspace.
17. Call research_check_updates after meaningful research/tool phases, before validation, and once after successful validation before the final report. Do not call it after every individual tool invocation. If it returns a user update, incorporate it, revise the brief, and call research_save_brief.
18. Never expose chain-of-thought, scratch work, self-review, or repeated drafting. Provider-side thinking is disabled intentionally. Report only concise progress events, tool results that matter, and the final synthesis.
19. For technical research, the final response must separate: Answer/Recommendation, Evidence, Validation, Assumptions or Limitations, and Sources. Cite the primary sources actually used. If no sandbox validation was applicable, say why in Validation.
20. Do not end early because one merely plausible explanation was found, but do not research for its own sake. Check important alternatives and conflicting evidence within the approved scope, then stop when evidence is sufficient.
21. CONTROL-CRITICAL HARDWARE / AUTOMATION RULE: when generated configuration controls a motor, pump, heater, charger, actuator, or other physical process, verify semantic safety as well as syntax. Distinguish controller diagnostic/result values from the actual actuator command. A claimed emergency stop must disable or latch out the upstream controller so it cannot immediately rewrite the output. Prefer stable hardware identities such as explicit sensor addresses/IDs over positional indices for control-critical sensors when the platform supports them. Clearly label placeholder gains, limits, addresses, and credentials.
</local_ai_deep_research>"""
        body["messages"]=add_or_update_system_message(instructions,body.get("messages") or [],append=True)
        body["think"]=False
        return body
PYFILTER

  python3 - "$WORKDIR/deep_research_orchestrator.py" "$CONTROLLER_URL" "$CONTROLLER_ADMIN_SECRET" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace("__CONTROLLER_URL__",sys.argv[2]).replace("__CONTROLLER_SECRET__",sys.argv[3]); p.write_text(s)
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
/* Local AI Suite v5 mode layer. Deliberately framework-light so it can survive
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
  const DEEP_TOOL = 'deep_research_lab';
  const DEEP_WEB_TOOL = 'deep_research_web';
  const UI_KEY = '__UI_SECRET__';
  const CONTROLLER_PORT = '__CONTROLLER_PORT__';
  const MODE_KEY = 'local-ai-suite-mode-v5';
  const ROOT_PREFIX = 'local-ai-deep-root:';
  let mode = localStorage.getItem(MODE_KEY) || 'fast';
  if (!CONFIG[mode]) mode = 'fast';
  let forceNewDeepRoot = false;
  let lastPath = location.pathname;

  function chatIdFromLocation() {
    const m = location.pathname.match(/^\/c\/([^/?#]+)/);
    return m ? decodeURIComponent(m[1]) : '';
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

  function setMode(next) {
    if (!CONFIG[next]) return;
    const previous = mode;
    mode = next;
    localStorage.setItem(MODE_KEY, mode);
    if (next === 'deep' && previous !== 'deep') forceNewDeepRoot = true;
    renderState();
    if(next !== previous) prewarmMode(next);
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
    if(badge) badge.textContent=mode==='deep'?'64K · hard web budget · lab validation':mode==='advanced'?'48K · no sandbox':'32K · no sandbox';
  }

  function mountBar() {
    if(document.getElementById('local-ai-mode-bar')) return;
    const bar=document.createElement('div'); bar.id='local-ai-mode-bar';
    bar.innerHTML=`
      <div class="lai-mode-buttons">
        ${Object.entries(CONFIG).map(([id,c])=>`<button type="button" data-lai-mode="${id}" title="${c.label} mode">${c.icon}<span>${c.label}</span></button>`).join('')}
        <button type="button" id="lai-research-update" title="Add or change Deep Research scope">✏️<span>Update Research</span></button>
      </div>
      <div id="lai-mode-status"></div>`;
    bar.addEventListener('click',e=>{
      const b=e.target.closest('[data-lai-mode]'); if(b) setMode(b.dataset.laiMode);
      if(e.target.closest('#lai-research-update')) queueUpdate();
    });
    document.body.appendChild(bar); renderState();
  }

  // Hide OpenWebUI's stock model selector AND any raw/internal model-name header.
  // Only the Fast / Advanced / Deep Research controls should be user-facing.
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
      setRoot(chatId,root); forceNewDeepRoot=false;
    }
    return {chatId,root};
  }

  function patchCompletion(init) {
    if(!init?.body) return init;
    let body;
    try { body=typeof init.body==='string'?JSON.parse(init.body):init.body; } catch(e){ return init; }
    if(!body || typeof body!=='object') return init;
    const c=CONFIG[mode] || CONFIG.fast;
    const previousModel=String(body.model || '');
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
    body.tool_ids=Array.isArray(body.tool_ids)?body.tool_ids.filter(x=>![DEEP_TOOL,DEEP_WEB_TOOL].includes(x)):[];
    const headers=new Headers(init.headers || {});
    headers.set('X-Local-AI-Mode',mode);
    if(mode==='deep'){
      // Deep Research uses the controller-budgeted web tool, never the
      // unrestricted OpenWebUI built-in web feature.
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
    if(url.includes('/api/chat/completions') && String(init?.method||'POST').toUpperCase()==='POST') nextInit=patchCompletion(init);
    const response=await window.__laiOriginalFetch(input,nextInit);
    const method=String(init?.method||'GET').toUpperCase();
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

  const observer=new MutationObserver(()=>{ mountBar(); hideRawSelector(); });
  const start=()=>{ mountBar(); hideRawSelector(); observer.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['aria-label','title']}); };
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',start,{once:true}); else start();

  setInterval(()=>{
    if(location.pathname!==lastPath){ lastPath=location.pathname; mountBar(); hideRawSelector(); }
    reconcileCurrentChat();
  },10000);
})();
JSUI

  cat >${WORKDIR}/local-ai-mode-ui.css <<'CSSUI'
/* Local AI Suite v5 mode bar */
#local-ai-mode-bar{position:fixed;left:50%;bottom:82px;transform:translateX(-50%);z-index:45;display:flex;flex-direction:column;align-items:center;gap:4px;pointer-events:none;font-family:ui-sans-serif,system-ui,sans-serif}
#local-ai-mode-bar .lai-mode-buttons{pointer-events:auto;display:flex;align-items:center;gap:5px;padding:5px;border-radius:16px;background:color-mix(in srgb,var(--color-gray-950,#111) 88%,transparent);box-shadow:0 8px 30px rgba(0,0,0,.18);backdrop-filter:blur(14px);border:1px solid rgba(127,127,127,.18)}
#local-ai-mode-bar button{display:inline-flex;align-items:center;gap:6px;border:0;border-radius:11px;padding:7px 10px;background:transparent;color:#ddd;font-size:12px;line-height:1;cursor:pointer;white-space:nowrap;transition:background .15s ease,color .15s ease,transform .15s ease}
#local-ai-mode-bar button:hover{background:rgba(127,127,127,.18)}
#local-ai-mode-bar button.active{background:rgba(127,127,127,.28);color:#fff;font-weight:600;box-shadow:inset 0 0 0 1px rgba(255,255,255,.12)}
#local-ai-mode-bar button:active{transform:scale(.97)}
#local-ai-mode-bar #lai-research-update{margin-left:3px;border-left:1px solid rgba(127,127,127,.2);border-radius:0 11px 11px 0}
#lai-mode-status{pointer-events:none;font-size:10px;color:#999;background:rgba(20,20,22,.72);padding:2px 7px;border-radius:8px;backdrop-filter:blur(8px)}
.lai-hidden-model-selector,.lai-hidden-model-label{display:none!important}
@media(max-width:700px){#local-ai-mode-bar{bottom:76px;width:96%}#local-ai-mode-bar .lai-mode-buttons{max-width:96vw}#local-ai-mode-bar button{padding:7px 8px}#local-ai-mode-bar button span{display:none}#lai-mode-status{font-size:9px}}
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
curl -fsS http://127.0.0.1:11434/api/chat -H 'Content-Type: application/json' -d "$(jq -n --arg model "$FAST_MODEL" '{model:$model,messages:[{role:"user",content:"Reply only with OK"}],think:false,stream:false,keep_alive:-1,options:{num_predict:8}}')" | jq -r '.message.content // .error // empty'

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
  echo "Deep Research validation gate: pipefail-safe validation + 5 normal repairs + 1 deterministic final repair + stop on success"
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
