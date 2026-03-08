#!/usr/bin/env bash

show_recent_server_logs() {
  local stdout_log="$1"
  local stderr_log="$2"

  log_step '后端启动失败，最近日志如下'
  if [[ -s "$stdout_log" ]]; then
    log_step '=== 最近标准输出 ==='
    tail -n "$RECENT_LOG_LINE_COUNT" "$stdout_log"
  fi
  if [[ -s "$stderr_log" ]]; then
    log_step '=== 最近标准错误 ==='
    tail -n "$RECENT_LOG_LINE_COUNT" "$stderr_log" >&2
  fi
}

probe_backend_ready() {
  local port_num="$1"
  curl -fsS "http://127.0.0.1:${port_num}/health" >/dev/null 2>&1
}

wait_for_backend_ready() {
  local port_num="$1"
  local timeout_sec="$2"
  local llama_pid="$3"
  local stdout_log="$4"
  local stderr_log="$5"
  local elapsed_sec=0

  while (( elapsed_sec < timeout_sec )); do
    if ! kill -0 "$llama_pid" 2>/dev/null; then
      log_step '后端启动失败: llama-server 进程已提前退出'
      show_recent_server_logs "$stdout_log" "$stderr_log"
      return 1
    fi
    if probe_backend_ready "$port_num"; then
      log_step '后端健康检查已通过，网关会继续完成预热'
      return 0
    fi
    log_step "等待模型加载到 GPU... ${elapsed_sec}/${timeout_sec} 秒"
    sleep 1
    elapsed_sec=$((elapsed_sec + 1))
  done

  log_step "后端在 ${timeout_sec} 秒内未就绪"
  show_recent_server_logs "$stdout_log" "$stderr_log"
  return 1
}

format_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" '
    BEGIN {
      split("B KiB MiB GiB TiB", units, " ")
      value = bytes + 0
      idx = 1
      while (value >= 1024 && idx < 5) {
        value /= 1024
        idx++
      }
      printf "%.1f %s", value, units[idx]
    }
  '
}

resolve_content_length() {
  local url="$1"
  curl -fsSLI "$url" \
    | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { print $2 }' \
    | tail -n 1
}

read_file_size() {
  local path="$1"
  if [[ -f "$path" ]]; then
    stat -c '%s' "$path"
    return
  fi
  printf '0\n'
}

render_progress_message() {
  local label="$1"
  local current_bytes="$2"
  local total_bytes="$3"
  local speed_bytes="$4"
  local current_text
  local total_text
  local speed_text

  current_text="$(format_bytes "$current_bytes")"
  speed_text="$(format_bytes "$speed_bytes")"
  total_text="$(format_bytes "${total_bytes:-0}")"

  if [[ -n "$total_bytes" && "$total_bytes" =~ ^[0-9]+$ && "$total_bytes" -gt 0 ]]; then
    awk -v label="$label" -v current="$current_bytes" -v total="$total_bytes" \
      -v current_text="$current_text" -v total_text="$total_text" -v speed_text="$speed_text" '
      BEGIN {
        pct = (current / total) * 100
        printf "下载%s: %.1f%%  %s / %s  %s/s\n",
          label, pct, current_text, total_text, speed_text
      }
    '
    return
  fi

  printf '下载%s: 已下载 %s  %s/s\n' "$label" "$current_text" "$speed_text"
}

download_if_missing() {
  local path="$1"
  local url="$2"
  local label="$3"
  local temp_path="${path}.part"
  local total_bytes=""
  local previous_bytes=0
  local current_bytes=0
  local speed_bytes=0
  local curl_pid

  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    log_step "检测到现有${label}，跳过下载"
    return
  fi

  log_step "下载${label}: $url"
  total_bytes="$(resolve_content_length "$url" || true)"
  previous_bytes="$(read_file_size "$temp_path")"

  curl --fail --location --retry 5 --retry-delay 2 --retry-connrefused \
    --continue-at - --output "$temp_path" --silent --show-error "$url" &
  curl_pid=$!

  while kill -0 "$curl_pid" 2>/dev/null; do
    sleep 2
    current_bytes="$(read_file_size "$temp_path")"
    speed_bytes=$(( (current_bytes - previous_bytes) / 2 ))
    if (( speed_bytes < 0 )); then
      speed_bytes=0
    fi
    log_step "$(render_progress_message "$label" "$current_bytes" "$total_bytes" "$speed_bytes")"
    previous_bytes="$current_bytes"
  done

  if ! wait "$curl_pid"; then
    printf '下载失败: %s\n' "$url" >&2
    exit 1
  fi

  current_bytes="$(read_file_size "$temp_path")"
  log_step "下载${label}完成: $(format_bytes "$current_bytes")"
  mv "$temp_path" "$path"
}
