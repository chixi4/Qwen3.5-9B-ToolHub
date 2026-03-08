#!/usr/bin/env bash
set -euo pipefail

DEFAULT_GGUF_URL="https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"
DEFAULT_MMPROJ_URL="https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/mmproj-Qwen3.5-9B-BF16.gguf"
BACKEND_READY_TIMEOUT_SEC=180
RECENT_LOG_LINE_COUNT=80

. /usr/local/bin/toolhub-backend-helpers.sh

log_step() {
  printf '[toolhub-backend] %s\n' "$1"
}

log_stage() {
  log_step "$1"
}

resolve_llama_server_bin() {
  local candidate=""
  if candidate="$(command -v llama-server 2>/dev/null)"; then
    printf '%s\n' "$candidate"
    return
  fi

  candidate="/app/llama-server"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  printf '未找到 llama-server，可执行文件既不在 PATH 中，也不在 /app/llama-server\n' >&2
  exit 1
}

require_positive_integer() {
  local key="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    printf '%s 必须是正整数，收到: %s\n' "$key" "$value" >&2
    exit 1
  fi
}

verify_sha256() {
  local path="$1"
  local expected="$2"
  if [[ -z "$expected" ]]; then
    return
  fi

  local actual
  actual="$(sha256sum "$path" | awk '{print $1}')"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    printf 'SHA256 校验失败: %s\n' "$path" >&2
    printf '期望: %s\n' "$expected" >&2
    printf '实际: %s\n' "$actual" >&2
    exit 1
  fi
}

resolve_runtime_profile() {
  case "${THINK_MODE:-think-on}" in
    think-on)
      REASONING_BUDGET="-1"
      MAX_TOKENS="-1"
      ;;
    think-off)
      REASONING_BUDGET="0"
      MAX_TOKENS="2048"
      ;;
    *)
      printf '不支持的 THINK_MODE: %s\n' "${THINK_MODE:-}" >&2
      exit 1
      ;;
  esac
}

main() {
  local host_addr="${HOST:-0.0.0.0}"
  local port_num="${PORT:-8081}"
  local model_path="${MODEL_PATH:-/models/model.gguf}"
  local mmproj_path="${MMPROJ_PATH:-/models/mmproj.gguf}"
  local gguf_url="${MODEL_GGUF_URL:-$DEFAULT_GGUF_URL}"
  local mmproj_url="${MODEL_MMPROJ_URL:-$DEFAULT_MMPROJ_URL}"
  local ctx_size="${CTX_SIZE:-16384}"
  local image_min_tokens="${IMAGE_MIN_TOKENS:-256}"
  local image_max_tokens="${IMAGE_MAX_TOKENS:-1024}"
  local mmproj_offload="${MMPROJ_OFFLOAD:-off}"
  local backend_ready_timeout_sec="$BACKEND_READY_TIMEOUT_SEC"
  local llama_server_bin
  local runtime_dir="/tmp/toolhub-backend"
  local stdout_log="${runtime_dir}/llama-server.stdout.log"
  local stderr_log="${runtime_dir}/llama-server.stderr.log"
  local llama_pid

  log_stage '阶段 1/6: 检查运行参数'
  require_positive_integer "PORT" "$port_num"
  require_positive_integer "CTX_SIZE" "$ctx_size"
  require_positive_integer "IMAGE_MIN_TOKENS" "$image_min_tokens"
  require_positive_integer "IMAGE_MAX_TOKENS" "$image_max_tokens"
  require_positive_integer "BACKEND_READY_TIMEOUT_SEC" "$backend_ready_timeout_sec"

  if (( image_min_tokens > image_max_tokens )); then
    printf 'IMAGE_MIN_TOKENS 不能大于 IMAGE_MAX_TOKENS\n' >&2
    exit 1
  fi

  if [[ "$mmproj_offload" != "on" && "$mmproj_offload" != "off" ]]; then
    printf 'MMPROJ_OFFLOAD 仅支持 on 或 off，收到: %s\n' "$mmproj_offload" >&2
    exit 1
  fi

  resolve_runtime_profile
  llama_server_bin="$(resolve_llama_server_bin)"
  mkdir -p "$runtime_dir"
  : > "$stdout_log"
  : > "$stderr_log"

  log_stage '阶段 2/6: 检查或下载主模型'
  download_if_missing "$model_path" "$gguf_url" "主模型"
  log_stage '阶段 3/6: 检查或下载视觉模型'
  download_if_missing "$mmproj_path" "$mmproj_url" "视觉模型"

  log_stage '阶段 4/6: 校验模型文件'
  verify_sha256 "$model_path" "${MODEL_GGUF_SHA256:-}"
  verify_sha256 "$mmproj_path" "${MODEL_MMPROJ_SHA256:-}"

  local args=(
    -m "$model_path"
    -mm "$mmproj_path"
    --n-gpu-layers all
    --flash-attn on
    --fit on
    --fit-target 256
    --temp 1.0
    --top-p 0.95
    --top-k 20
    --min-p 0.1
    --presence-penalty 1.5
    --repeat-penalty 1.05
    -n "$MAX_TOKENS"
    --reasoning-budget "$REASONING_BUDGET"
    -c "$ctx_size"
    --image-min-tokens "$image_min_tokens"
    --image-max-tokens "$image_max_tokens"
    --host "$host_addr"
    --port "$port_num"
    --webui
  )

  if [[ "$mmproj_offload" == "off" ]]; then
    args+=(--no-mmproj-offload)
  else
    args+=(--mmproj-offload)
  fi

  log_stage '阶段 5/6: 启动 llama-server'
  log_step "启动参数: host=$host_addr port=$port_num think=${THINK_MODE:-think-on}"
  "$llama_server_bin" "${args[@]}" >"$stdout_log" 2>"$stderr_log" &
  llama_pid=$!
  log_step "llama-server 已启动: PID ${llama_pid}"

  log_stage '阶段 6/6: 等待模型加载到 GPU'
  if ! wait_for_backend_ready "$port_num" "$backend_ready_timeout_sec" "$llama_pid" "$stdout_log" "$stderr_log"; then
    if kill -0 "$llama_pid" 2>/dev/null; then
      kill "$llama_pid" 2>/dev/null || true
      wait "$llama_pid" 2>/dev/null || true
    fi
    exit 1
  fi

  wait "$llama_pid"
}

main "$@"
