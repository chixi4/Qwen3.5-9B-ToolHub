#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_PATH="$ROOT_DIR/start_8080_toolhub_stack.ps1"

print_usage() {
  cat <<'USAGE'
用法:
  ./start_8080_toolhub_stack.sh {start|stop|restart|status|logs}

说明:
  WSL 入口会直接复用 Windows 主脚本的完整启动链路。
  包括后端 GPU 强校验与网关管理，行为与 cmd / PowerShell 保持一致。
USAGE
}

to_win_path_if_needed() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf ''
    return
  fi
  if [[ "$raw" == /* ]]; then
    wslpath -w "$raw"
    return
  fi
  printf '%s' "$raw"
}

ps_escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/''/g"
}

require_windows_power_shell() {
  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "未找到 powershell.exe，无法从 WSL 调用 Windows 栈脚本。"
    exit 1
  fi
  if [[ ! -f "$PS1_PATH" ]]; then
    echo "缺少栈脚本: $PS1_PATH"
    exit 1
  fi
}

build_env_overrides() {
  local -n out_ref=$1
  out_ref=()

  for key in GATEWAY_HOST GATEWAY_PORT BACKEND_HOST BACKEND_PORT THINK_MODE HOST PORT CTX_SIZE IMAGE_MIN_TOKENS IMAGE_MAX_TOKENS MMPROJ_OFFLOAD GPU_MEMORY_DELTA_MIN_MIB; do
    if [[ -n "${!key-}" ]]; then
      out_ref+=("$key=${!key}")
    fi
  done

  if [[ -n "${BIN_PATH-}" ]]; then
    out_ref+=("BIN_PATH=$(to_win_path_if_needed "$BIN_PATH")")
  fi
  if [[ -n "${MODEL_PATH-}" ]]; then
    out_ref+=("MODEL_PATH=$(to_win_path_if_needed "$MODEL_PATH")")
  fi
  if [[ -n "${MMPROJ_PATH-}" ]]; then
    out_ref+=("MMPROJ_PATH=$(to_win_path_if_needed "$MMPROJ_PATH")")
  fi
}

build_ps_env_setup() {
  local -n env_ref=$1
  local lines=()
  local item key value escaped_value
  for item in "${env_ref[@]}"; do
    key="${item%%=*}"
    value="${item#*=}"
    escaped_value="$(ps_escape_single_quotes "$value")"
    lines+=("[Environment]::SetEnvironmentVariable('$key', '$escaped_value', 'Process')")
  done
  printf '%s; ' "${lines[@]}"
}

main() {
  local command="${1:-status}"
  case "$command" in
    start|stop|restart|status|logs) ;;
    *)
      print_usage
      exit 1
      ;;
  esac

  require_windows_power_shell

  local ps1_win
  ps1_win="$(wslpath -w "$PS1_PATH")"

  local env_overrides=()
  build_env_overrides env_overrides

  local ps_command
  local ps_env_setup
  ps_env_setup="$(build_ps_env_setup env_overrides)"
  ps_command="[Console]::InputEncoding = [System.Text.UTF8Encoding]::new(\$false); [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(\$false); chcp 65001 > \$null; ${ps_env_setup}& '$ps1_win' '$command'"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps_command"
}

main "${1:-status}"
