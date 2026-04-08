#!/usr/bin/env bash

if [[ -n "${GC_INTERNAL_COMMON_LOADED:-}" ]]; then
  return 0
fi
GC_INTERNAL_COMMON_LOADED=1

gc_init_context() {
  GC_ROOT_DIR="$1"
  GC_PACKAGES_DIR="${GC_ROOT_DIR}/packages"
  GC_INTERNAL_DIR="${GC_ROOT_DIR}/.internal"
  GC_DEFAULT_LOG_DIR="${GC_ROOT_DIR}/logs"
  GC_DEFAULT_TMP_ROOT="/tmp/gc-delivery-bundle"
  GC_SUPPORTED_SOFTWARES=("runtime" "chromium" "sunlogin")
  GC_REBOOT_REASONS=()
  export GC_ROOT_DIR GC_PACKAGES_DIR GC_INTERNAL_DIR GC_DEFAULT_LOG_DIR GC_DEFAULT_TMP_ROOT
}

gc_resolve_path() {
  local input_path="$1"

  if [[ "${input_path}" = /* ]]; then
    printf '%s\n' "${input_path}"
    return 0
  fi

  printf '%s\n' "$(cd "${GC_ROOT_DIR}" && cd "$(dirname "${input_path}")" && pwd)/$(basename "${input_path}")"
}

gc_log_timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

gc_log_write() {
  local level="$1"
  shift
  local message="$*"
  local line

  line="$(gc_log_timestamp) [${level}] ${message}"
  printf '%s\n' "${line}"
  if [[ -n "${GC_LOG_FILE:-}" ]]; then
    printf '%s\n' "${line}" >> "${GC_LOG_FILE}"
  fi
}

gc_log_info() {
  gc_log_write "INFO" "$@"
}

gc_log_warn() {
  gc_log_write "WARN" "$@"
}

gc_log_error() {
  gc_log_write "ERROR" "$@"
}

gc_log_success() {
  gc_log_write "OK" "$@"
}

gc_log_run() {
  gc_log_write "RUN" "$@"
}

gc_init_log() {
  local run_id
  run_id="$(date '+%Y%m%d_%H%M%S')"
  GC_LOG_DIR="${GC_DEFAULT_LOG_DIR}"
  mkdir -p "${GC_LOG_DIR}"
  GC_LOG_FILE="${GC_LOG_DIR}/install-${run_id}.log"
  : > "${GC_LOG_FILE}"
  export GC_LOG_DIR GC_LOG_FILE
  gc_log_info "日志文件: ${GC_LOG_FILE}"
}

gc_die() {
  gc_log_error "$@"
  exit 1
}

gc_require_file() {
  [[ -f "$1" ]] || gc_die "缺少文件: $1"
}

gc_require_command() {
  command -v "$1" >/dev/null 2>&1 || gc_die "缺少命令: $1"
}

gc_require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || gc_die "请使用 root 权限执行该脚本。"
}

gc_require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || gc_die "该安装包必须在目标 Linux 设备上执行。"
}

gc_validate_reboot_policy() {
  case "${1:-}" in
    prompt|always|never) ;;
    *) gc_die "REBOOT_POLICY 仅支持 prompt|always|never，当前值: ${1:-<empty>}" ;;
  esac
}

gc_validate_bool_string() {
  case "${1:-}" in
    true|false|yes|no|1|0|TRUE|FALSE|YES|NO) ;;
    *) gc_die "布尔配置值非法: ${1:-<empty>}" ;;
  esac
}

gc_is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

gc_prompt_confirm() {
  local prompt_text="$1"
  local default_answer="${2:-no}"
  local answer=""

  if [[ "${GC_DRY_RUN:-0}" == "1" ]]; then
    gc_log_warn "dry-run 模式按默认值处理确认项: ${prompt_text} -> ${default_answer}"
    [[ "${default_answer}" == "yes" ]]
    return
  fi

  if [[ "${default_answer}" == "yes" ]]; then
    read -r -p "${prompt_text} [Y/n]: " answer
    answer="${answer:-yes}"
  else
    read -r -p "${prompt_text} [y/N]: " answer
    answer="${answer:-no}"
  fi

  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

gc_prompt_secret() {
  local prompt_text="$1"
  local answer=""

  if [[ "${GC_DRY_RUN:-0}" == "1" ]]; then
    gc_log_warn "dry-run 模式跳过密文输入: ${prompt_text}"
    printf '%s\n' ""
    return 0
  fi

  read -r -s -p "${prompt_text}: " answer
  printf '\n' >&2
  printf '%s\n' "${answer}"
}

gc_quote_cmd() {
  printf '%q ' "$@"
}

gc_run() {
  local quoted
  quoted="$(gc_quote_cmd "$@")"
  gc_log_run "${quoted% }"
  if [[ "${GC_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  "$@"
}

gc_backup_once() {
  local target="$1"
  local backup_path="${target}.bak.gc-delivery"

  if [[ -e "${backup_path}" ]]; then
    return 0
  fi

  if [[ "${GC_DRY_RUN:-0}" == "1" ]]; then
    gc_log_info "将备份文件: ${target} -> ${backup_path}"
    return 0
  fi

  [[ -e "${target}" ]] || return 0
  cp -a "${target}" "${backup_path}"
  gc_log_info "已备份: ${backup_path}"
}

gc_upsert_ini_key() {
  local file_path="$1"
  local section_name="$2"
  local key_name="$3"
  local key_value="$4"
  local temp_file=""

  if [[ "${GC_DRY_RUN:-0}" == "1" ]]; then
    gc_log_info "将更新 ${file_path}: ${section_name} ${key_name}=${key_value}"
    return 0
  fi

  temp_file="$(mktemp)"
  awk -v section="${section_name}" -v key="${key_name}" -v value="${key_value}" '
    BEGIN {
      in_section = 0
      section_found = 0
      key_written = 0
      key_regex = "^[[:space:]]*[#;]?[[:space:]]*" key "="
    }
    /^\[.*\]$/ {
      if (in_section && !key_written) {
        print key "=" value
        key_written = 1
      }
      if ($0 == section) {
        in_section = 1
        section_found = 1
      } else {
        in_section = 0
      }
      print
      next
    }
    {
      if (in_section && $0 ~ key_regex) {
        if (!key_written) {
          print key "=" value
          key_written = 1
        }
        next
      }
      print
    }
    END {
      if (!section_found) {
        print ""
        print section
        print key "=" value
      } else if (in_section && !key_written) {
        print key "=" value
      }
    }
  ' "${file_path}" > "${temp_file}"
  mv "${temp_file}" "${file_path}"
}

gc_load_config() {
  gc_require_file "${GC_CONFIG_PATH}"
  # shellcheck disable=SC1090
  source "${GC_CONFIG_PATH}"

  if declare -p SOFTWARES >/dev/null 2>&1; then
    case "$(declare -p SOFTWARES 2>/dev/null)" in
      "declare -a"*)
        SOFTWARES=("${SOFTWARES[@]}")
        ;;
      *)
        SOFTWARES=("${SOFTWARES:-}")
        ;;
    esac
  else
    SOFTWARES=()
  fi

  if [[ "${#SOFTWARES[@]}" -eq 1 && -z "${SOFTWARES[0]}" ]]; then
    SOFTWARES=()
  fi

  REBOOT_POLICY="${REBOOT_POLICY:-prompt}"
  RUNTIME_INSTALL_PATH="${RUNTIME_INSTALL_PATH:-/wa-edge}"
  RUNTIME_DATA_PATH="${RUNTIME_DATA_PATH:-${RUNTIME_INSTALL_PATH}/data}"
  RUNTIME_ETHERCAT_IFACE="${RUNTIME_ETHERCAT_IFACE:-en3}"
  RUNTIME_ETHERCAT_DRIVER="${RUNTIME_ETHERCAT_DRIVER:-generic}"
  CHROMIUM_USER="${CHROMIUM_USER:-gcuser}"
  CHROMIUM_ENABLE_AUTOLOGIN="${CHROMIUM_ENABLE_AUTOLOGIN:-true}"
  CHROMIUM_SESSION="${CHROMIUM_SESSION:-xfce}"
  CHROMIUM_PASSWORD="${CHROMIUM_PASSWORD:-}"

  export REBOOT_POLICY
  export RUNTIME_INSTALL_PATH RUNTIME_DATA_PATH RUNTIME_ETHERCAT_IFACE RUNTIME_ETHERCAT_DRIVER
  export CHROMIUM_USER CHROMIUM_ENABLE_AUTOLOGIN CHROMIUM_SESSION CHROMIUM_PASSWORD

  gc_validate_reboot_policy "${REBOOT_POLICY}"
  gc_validate_bool_string "${CHROMIUM_ENABLE_AUTOLOGIN}"
  gc_validate_softwares
}

gc_validate_softwares() {
  local item=""
  local supported=""
  local found=""
  local -A seen=()

  for item in "${SOFTWARES[@]}"; do
    found="no"
    for supported in "${GC_SUPPORTED_SOFTWARES[@]}"; do
      if [[ "${item}" == "${supported}" ]]; then
        found="yes"
        break
      fi
    done
    [[ "${found}" == "yes" ]] || gc_die "客户清单中存在不支持的软件 ID: ${item}"
    [[ -z "${seen[${item}]:-}" ]] || gc_die "客户清单中存在重复的软件 ID: ${item}"
    seen["${item}"]=1
  done
}

gc_check_target_platform() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "openEuler" && "${ID:-}" != "openeuler" ]]; then
      gc_log_warn "当前系统 ID=${ID:-unknown}，脚本按 openEuler 22.04 设计。"
    fi
    if [[ -n "${VERSION_ID:-}" ]]; then
      gc_log_info "目标系统版本: ${VERSION_ID}"
    fi
  else
    gc_log_warn "未找到 /etc/os-release，跳过发行版校验。"
  fi

  if [[ "$(uname -m)" != "aarch64" ]]; then
    gc_log_warn "当前架构为 $(uname -m)，安装包按 aarch64 准备。"
  fi
}

gc_request_reboot() {
  GC_REBOOT_REASONS+=("$1")
  gc_log_warn "已登记重启需求: $1"
}

gc_run_base_setup() {
  gc_log_info "开始执行基础环境准备。"
  gc_require_root
  gc_require_linux
  gc_require_command bash
  gc_require_command dnf
  gc_require_command rpm
  gc_require_command systemctl
  gc_require_command tar
  gc_require_command unzip
  gc_require_command grep
  gc_require_command sed
  gc_require_command mktemp
  gc_require_command reboot
  gc_check_target_platform

  missing_packages=()
  for package_name in sudo wget unzip; do
    if ! command -v "${package_name}" >/dev/null 2>&1; then
      missing_packages+=("${package_name}")
    fi
  done

  if [[ "${#missing_packages[@]}" -gt 0 ]]; then
    gc_log_info "待安装通用工具: ${missing_packages[*]}"
    gc_run dnf install -y "${missing_packages[@]}"
  else
    gc_log_info "通用工具已就绪，无需安装。"
  fi

  gc_log_success "基础环境准备完成。"
}

gc_handle_reboot_policy() {
  local reason="$1"

  case "${REBOOT_POLICY}" in
    always)
      gc_log_warn "${reason}"
      gc_run reboot
      ;;
    prompt)
      gc_log_warn "${reason}"
      if gc_prompt_confirm "是否现在重启系统？" "no"; then
        gc_run reboot
      else
        gc_log_warn "已跳过重启，请在安装完成后手动重启。"
      fi
      ;;
    never)
      gc_log_warn "当前策略禁止自动重启，请稍后手动重启。原因: ${reason}"
      ;;
  esac
}

gc_finish_reboot_flow() {
  local reboot_reason=""

  if [[ "${#GC_REBOOT_REASONS[@]}" -eq 0 ]]; then
    gc_log_info "本轮安装未登记重启需求。"
    return 0
  fi

  reboot_reason="$(printf '%s; ' "${GC_REBOOT_REASONS[@]}")"
  reboot_reason="${reboot_reason%; }"
  gc_handle_reboot_policy "${reboot_reason}"
}
