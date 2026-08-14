#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Local AI Suite v4.1
# Fedora + native Ollama + Docker Open WebUI + preconfigured SearXNG
#
# Idempotent deployment/configuration for an evidence-first local assistant.
# Existing systems are preserved; missing components are installed only when
# needed. Friendly model aliases reuse existing Ollama layers whenever possible.
###############################################################################

VERSION="4.1"

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

TASK_MODEL="background-scout:270m"
FAST_MODEL="natural-fast:27b"
RESEARCH_MODEL="research-plus:27b"
DEEP_MODEL="deep-research:27b"

OLD_TASK="owui-task:270m"
OLD_FAST="evidence-assistant-32k:qwen3.6-27b-iq3m"
OLD_RESEARCH="evidence-assistant-fast:qwen3.6-27b-iq3m"
OLD_DEEP="evidence-assistant:qwen3.6-27b-iq3m"

BASE_MODEL="hf.co/HauhauCS/Qwen3.6-27B-Uncensored-HauhauCS-Balanced:IQ3_M"
TASK_BASE="gemma3:270m"

FAST_CTX="${FAST_CTX:-32768}"
RESEARCH_CTX="${RESEARCH_CTX:-65536}"
DEEP_CTX="${DEEP_CTX:-131072}"
FAST_OUTPUT="${FAST_OUTPUT:-8192}"
RESEARCH_OUTPUT="${RESEARCH_OUTPUT:-8192}"
DEEP_OUTPUT="${DEEP_OUTPUT:-16384}"

FILTER_ID="document_memory_gate"
FILTER_NAME="Persistent Document Memory Gate"
GUARD_ID="response_discipline_guard"
GUARD_NAME="Response Discipline Guard"
SEARXNG_QUERY_URL="http://searxng:8080/search?q=<query>&format=json"

section(){ echo; echo "======================================================================"; echo "$1"; echo "======================================================================"; }
info(){ echo "==> $*"; }
ok(){ echo " ✓ $*"; }
warn(){ echo " ! $*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then SUDO=""; else need_cmd sudo || fail "sudo is required"; SUDO="sudo"; fi

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
cat >/tmp/Modelfile.background-scout <<EOF
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
ollama create "$TASK_MODEL" -f /tmp/Modelfile.background-scout >/dev/null
ollama stop "$TASK_MODEL" >/dev/null 2>&1 || true
ok "$TASK_MODEL profile ready"

# Shared evidence-first prompt. The typo/repetition rules are deliberate: this
# model family can otherwise spiral into visible self-review when thinking.
cat >/tmp/evidence-system-prompt.txt <<'PROMPT'
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
  local name="$1" ctx="$2" predict="$3" mf="/tmp/Modelfile.${1//[:\/]/_}"
  {
    echo "FROM $BASE_MODEL"
    echo "PARAMETER num_ctx $ctx"
    echo "PARAMETER num_predict $predict"
    echo "PARAMETER temperature 0.6"
    echo "PARAMETER top_p 0.95"
    echo "PARAMETER top_k 20"
    echo "PARAMETER repeat_last_n 256"
    echo "PARAMETER repeat_penalty 1.05"
    echo 'SYSTEM """'
    cat /tmp/evidence-system-prompt.txt
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
    create_model_profile "$FAST_MODEL" "$FAST_CTX" "$FAST_OUTPUT"
    create_model_profile "$RESEARCH_MODEL" "$RESEARCH_CTX" "$RESEARCH_OUTPUT"
    create_model_profile "$DEEP_MODEL" "$DEEP_CTX" "$DEEP_OUTPUT"
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
    -e ENABLE_BASE_MODELS_CACHE=False -e MODELS_CACHE_TTL=1 \
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
    | .web.WEB_SEARCH_CONCURRENT_REQUESTS = 2
    | .web.WEB_LOADER_CONCURRENT_REQUESTS = 3
    | .web.SEARXNG_QUERY_URL = $url
    | .web.SEARXNG_LANGUAGE = "all"
  ' <<<"$RAG_CFG")"
  curl -fsS -X POST "$WEBUI_URL/api/v1/retrieval/config/update" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "$UPDATED_RAG_CFG" >/tmp/retrieval-config-updated.json || fail "Unable to configure OpenWebUI SearXNG web search"
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
    curl -fsS -X POST "$WEBUI_URL/ollama/config/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$PATCHED_OLLAMA_CFG" >/tmp/ollama-config-updated.json || fail "Unable to update Ollama connection"
    ok "Local Ollama URL + friendly-model allowlist configured"
  fi
else warn "Model allowlist management disabled"; fi

MODELS_JSON="$(curl -fsS "$WEBUI_URL/api/models?refresh=true" -H "Authorization: Bearer $TOKEN")" || fail "Unable to refresh OpenWebUI models"
for m in "$TASK_MODEL" "$FAST_MODEL" "$RESEARCH_MODEL" "$DEEP_MODEL"; do grep -Fq "$m" <<<"$MODELS_JSON" || fail "OpenWebUI refresh did not include $m"; ok "OpenWebUI sees $m"; done

section "OPENWEBUI TASK / MEMORY CONFIG"
TASK_CFG="$(curl -fsS "$WEBUI_URL/api/v1/tasks/config" -H "Authorization: Bearer $TOKEN")" || fail "Unable to read task config"
TASK_CFG="$(jq --arg m "$TASK_MODEL" '.TASK_MODEL=$m | .ENABLE_AUTOCOMPLETE_GENERATION=false | .ENABLE_FOLLOW_UP_GENERATION=false | .ENABLE_TITLE_GENERATION=true | .ENABLE_TAGS_GENERATION=true | .ENABLE_SEARCH_QUERY_GENERATION=true | .ENABLE_RETRIEVAL_QUERY_GENERATION=true' <<<"$TASK_CFG")"
curl -fsS -X POST "$WEBUI_URL/api/v1/tasks/config/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$TASK_CFG" >/tmp/task-config-updated.json || fail "Unable to update task config"
MEMORY_CFG="$(jq -n '{config:{"memories.enable":true,"memories.system_context.enable":false}}')"
curl -fsS -X POST "$WEBUI_URL/api/v1/configs/import" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$MEMORY_CFG" >/tmp/memory-config-updated.json || fail "Unable to update memory config"
VERIFY_TASK="$(curl -fsS "$WEBUI_URL/api/v1/tasks/config" -H "Authorization: Bearer $TOKEN")"; VERIFY_MEMORY="$(curl -fsS "$WEBUI_URL/api/v1/configs/namespace/memories" -H "Authorization: Bearer $TOKEN")"
[[ "$(jq -r '.TASK_MODEL // empty' <<<"$VERIFY_TASK")" == "$TASK_MODEL" ]] || fail "Task model verification failed"
[[ "$(jq -r 'if has("memories.enable") then (.["memories.enable"]|tostring) else "missing" end' <<<"$VERIFY_MEMORY")" == true ]] || fail "Memory enable verification failed"
[[ "$(jq -r 'if has("memories.system_context.enable") then (.["memories.system_context.enable"]|tostring) else "missing" end' <<<"$VERIFY_MEMORY")" == false ]] || fail "Memory system-context verification failed"
BG_REVIEW_ENV="$($DOCKER_CMD inspect "$OPENWEBUI_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '$1=="ENABLE_MEMORY_BACKGROUND_REVIEW"{print tolower($2);exit}')"
[[ "$BG_REVIEW_ENV" == true ]] && warn "Background memory review is enabled in this existing container and may add hidden LLM work" || ok "Background memory review is disabled/default-off"
ok "Background Scout + selective memory configuration verified"

section "INSTALLING RESPONSE DISCIPLINE GUARD"
cat >/tmp/response_discipline_guard.py <<'PYGUARD'
"""
title: Response Discipline Guard
author: Local AI Suite
version: 1.1.0
description: Prevent reasoning/self-review loops, silently normalize obvious typos, and keep fast/research models non-thinking by default.
"""
from pydantic import BaseModel, Field
from open_webui.utils.misc import add_or_update_system_message

FAST = "natural-fast:27b"
RESEARCH = "research-plus:27b"
DEEP = "deep-research:27b"
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

    def __init__(self):
        self.valves = self.Valves()

    async def inlet(self, body: dict, __model__=None, **kwargs):
        model = str(body.get("model") or "")
        if self.valves.force_fast_thinking_off and model == FAST:
            body["think"] = False
        elif self.valves.force_research_thinking_off and model == RESEARCH:
            body["think"] = False
        elif self.valves.force_task_thinking_off and model == TASK:
            body["think"] = False

        if model in {FAST, RESEARCH, DEEP}:
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
python3 -m py_compile /tmp/response_discipline_guard.py
GUARD_CONTENT="$(cat /tmp/response_discipline_guard.py)"
GUARD_JSON="$(jq -n --arg id "$GUARD_ID" --arg name "$GUARD_NAME" --arg content "$GUARD_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Silently handles obvious typos, suppresses visible self-review/repetition loops, and keeps Natural Fast / Research Plus non-thinking by default."}}')"
GUARD_HTTP="$(curl -sS -o /tmp/guard-current.json -w '%{http_code}' "$WEBUI_URL/api/v1/functions/id/$GUARD_ID" -H "Authorization: Bearer $TOKEN")"
if [[ "$GUARD_HTTP" == 200 ]]; then
  curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$GUARD_ID/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$GUARD_JSON" >/tmp/guard-installed.json
else
  curl -fsS -X POST "$WEBUI_URL/api/v1/functions/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$GUARD_JSON" >/tmp/guard-installed.json
fi
GUARD_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$GUARD_ID" -H "Authorization: Bearer $TOKEN")"
[[ "$(jq -r '.is_active' <<<"$GUARD_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$GUARD_ID/toggle" -H "Authorization: Bearer $TOKEN" >/dev/null
GUARD_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$GUARD_ID" -H "Authorization: Bearer $TOKEN")"
[[ "$(jq -r '.is_global' <<<"$GUARD_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$GUARD_ID/toggle/global" -H "Authorization: Bearer $TOKEN" >/dev/null
ok "Response Discipline Guard is active globally; Natural Fast / Research Plus default to think=false"

if [[ "$INSTALL_DOCUMENT_MEMORY" == 1 ]]; then
  section "INSTALLING PERSISTENT DOCUMENT MEMORY GATE"
  cat >/tmp/document_memory_gate.py <<'PYFUNC'
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
  python3 -m py_compile /tmp/document_memory_gate.py
  FUNCTION_CONTENT="$(cat /tmp/document_memory_gate.py)"
  FUNCTION_JSON="$(jq -n --arg id "$FILTER_ID" --arg name "$FILTER_NAME" --arg content "$FUNCTION_CONTENT" '{id:$id,name:$name,content:$content,meta:{description:"Ask before persisting uploads; approved documents are stored in Knowledge plus a compact Memory index and recalled only on topic/keyword matches."}}')"
  HTTP_CODE="$(curl -sS -o /tmp/function-current.json -w '%{http_code}' "$WEBUI_URL/api/v1/functions/id/$FILTER_ID" -H "Authorization: Bearer $TOKEN")"
  if [[ "$HTTP_CODE" == 200 ]]; then curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$FILTER_ID/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$FUNCTION_JSON" >/tmp/function-installed.json; else curl -fsS -X POST "$WEBUI_URL/api/v1/functions/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$FUNCTION_JSON" >/tmp/function-installed.json; fi
  FUNC_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$FILTER_ID" -H "Authorization: Bearer $TOKEN")"; [[ "$(jq -r '.is_active' <<<"$FUNC_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$FILTER_ID/toggle" -H "Authorization: Bearer $TOKEN" >/dev/null
  FUNC_STATE="$(curl -fsS "$WEBUI_URL/api/v1/functions/id/$FILTER_ID" -H "Authorization: Bearer $TOKEN")"; [[ "$(jq -r '.is_global' <<<"$FUNC_STATE")" == true ]] || curl -fsS -X POST "$WEBUI_URL/api/v1/functions/id/$FILTER_ID/toggle/global" -H "Authorization: Bearer $TOKEN" >/dev/null
  ok "Persistent Document Memory Gate is active globally"
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

section "FINAL STATUS"
ollama list
echo
echo "Workflow:"
echo "  $TASK_MODEL     = background helper"
echo "  $FAST_MODEL      = DEFAULT / fast / troubleshooting / coding ($FAST_CTX)"
echo "  $RESEARCH_MODEL  = extended research / larger documents ($RESEARCH_CTX)"
echo "  $DEEP_MODEL      = deep research / maximum context ($DEEP_CTX)"
echo
echo "OpenWebUI URL: $WEBUI_URL"
echo "Ollama URL from Docker: http://host.docker.internal:11434"
echo "Full automatic Memory System Context: OFF"
echo "Task model: $TASK_MODEL"
if ((WANT_SEARXNG==1)); then
  echo "SearXNG: preconfigured + enabled ($SEARXNG_QUERY_URL)"
  echo "Web search: 5 results, 2 concurrent searches, 3 concurrent page loads"
fi
 echo "Response Discipline Guard: active globally"
 echo "Thinking defaults: Natural Fast=OFF, Research Plus=OFF, Deep Research=user-controlled"
[[ "$INSTALL_DOCUMENT_MEMORY" == 1 ]] && echo "Document Memory Gate: active globally"
echo
ok "Local AI Suite v$VERSION deployment/configuration complete"

rm -f /tmp/Modelfile.background-scout /tmp/Modelfile.natural-fast_27b /tmp/Modelfile.research-plus_27b /tmp/Modelfile.deep-research_27b /tmp/evidence-system-prompt.txt /tmp/document_memory_gate.py /tmp/response_discipline_guard.py /tmp/function-current.json /tmp/guard-current.json /tmp/guard-installed.json /tmp/retrieval-config-updated.json /tmp/function-installed.json /tmp/task-config-updated.json /tmp/memory-config-updated.json /tmp/ollama-config-updated.json /tmp/searxng-from-webui.txt 2>/dev/null || true
unset TOKEN AUTH_RESPONSE OLLAMA_CFG
