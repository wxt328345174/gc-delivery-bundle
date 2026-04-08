#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=.internal/common.sh
source "${ROOT_DIR}/.internal/common.sh"
# shellcheck source=.internal/installers.sh
source "${ROOT_DIR}/.internal/installers.sh"

GC_DRY_RUN=0
GC_CONFIG_PATH="${ROOT_DIR}/customer.conf"

gc_usage() {
  cat <<'EOF'
用法:
  bash install.sh [--config <path>] [--dry-run]

参数:
  --config <path>  指定客户配置文件，默认读取同目录 customer.conf
  --dry-run        只做检查和预演，不真正安装
  -h, --help       显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      GC_CONFIG_PATH="$2"
      shift 2
      ;;
    --dry-run)
      GC_DRY_RUN=1
      shift
      ;;
    -h|--help)
      gc_usage
      exit 0
      ;;
    *)
      gc_die "未知参数: $1"
      ;;
  esac
done

GC_CONFIG_PATH="$(gc_resolve_path "${GC_CONFIG_PATH}")"
export GC_DRY_RUN GC_CONFIG_PATH

gc_init_context "${ROOT_DIR}"
gc_init_log
gc_load_config "${GC_CONFIG_PATH}"

gc_log_info "开始执行整包安装流程。"
gc_run_base_setup
gc_run_selected_installers
gc_finish_reboot_flow
gc_log_success "整包安装流程完成。"
