#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_INSTALLER_PS1="$ROOT_DIR/install.win.ps1"

print_usage() {
  cat <<'USAGE'
用法:
  ./install.sh

说明:
  这是 WSL 兼容入口。
  它会直接复用 Windows 安装主脚本，和 cmd / PowerShell 的安装结果保持一致。
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
    echo "未找到 powershell.exe，WSL 兼容入口无法调用 Windows 安装器。"
    exit 1
  fi
  if [[ ! -f "$WIN_INSTALLER_PS1" ]]; then
    echo "缺少安装脚本: $WIN_INSTALLER_PS1"
    exit 1
  fi
}

build_env_overrides() {
  local -n out_ref=$1
  out_ref=()

  for key in PYTHON_BIN LLAMA_WIN_CUDA_URL LLAMA_WIN_CUDART_URL MODEL_GGUF_URL MODEL_MMPROJ_URL MODEL_GGUF_SHA256 MODEL_MMPROJ_SHA256; do
    if [[ -z "${!key-}" ]]; then
      continue
    fi
    local value="${!key}"
    if [[ "$key" == "PYTHON_BIN" ]]; then
      value="$(to_win_path_if_needed "$value")"
    fi
    out_ref+=("$key=$value")
  done
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
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_usage
    exit 0
  fi

  require_windows_power_shell

  local installer_win
  installer_win="$(wslpath -w "$WIN_INSTALLER_PS1")"

  local env_overrides=()
  build_env_overrides env_overrides

  local ps_command
  local ps_env_setup
  ps_env_setup="$(build_ps_env_setup env_overrides)"
  ps_command="[Console]::InputEncoding = [System.Text.UTF8Encoding]::new(\$false); [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(\$false); chcp 65001 > \$null; ${ps_env_setup}& '$installer_win'"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps_command"
}

main "$@"
