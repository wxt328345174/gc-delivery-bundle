#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOURCE_PACKAGE="${ROOT_DIR}/packages/qt-creator-opensource-src-4.15.2.tar.gz"
OUTPUT_PACKAGE="${ROOT_DIR}/packages/qt-creator-4.15.2-openeuler-aarch64.tar.gz"
BUILD_ROOT="/tmp/gc-qt-build"
INSTALL_PREFIX="/opt/qtcreator-4.15.2"
BUILD_JOBS="$(nproc)"

usage() {
  cat <<'EOF'
用法：
  bash .internal/build-qt-package.sh [选项]

选项：
  --source <path>   指定 Qt Creator 源码包路径
  --output <path>   指定预编译压缩包输出路径
  --prefix <path>   指定安装前缀，默认 /opt/qtcreator-4.15.2
  --build-root <p>  指定临时构建目录，默认 /tmp/gc-qt-build
  --jobs <n>        指定 make 并行度，默认使用 nproc
  -h, --help        显示帮助

说明：
  该脚本仅供内部构建使用，必须在 openEuler aarch64 上执行。
  产物为客户可直接安装的预编译压缩包，客户侧无需编译。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_PACKAGE="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PACKAGE="$2"
      shift 2
      ;;
    --prefix)
      INSTALL_PREFIX="$2"
      shift 2
      ;;
    --build-root)
      BUILD_ROOT="$2"
      shift 2
      ;;
    --jobs)
      BUILD_JOBS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log() {
  printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "请使用 root 执行该脚本。"
  fi
}

check_platform() {
  [[ "$(uname -s)" == "Linux" ]] || fail "仅支持在 Linux 上执行。"
  [[ "$(uname -m)" == "aarch64" ]] || fail "仅支持在 aarch64 上执行。"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "openEuler" ]]; then
      fail "当前系统不是 openEuler，实际为: ${ID:-unknown}"
    fi
  fi
}

install_build_deps() {
  local required_packages=(
    gcc
    gcc-c++
    make
    cmake
    gdb
    qt5-devel
    qt5-qtbase-private-devel
    qt5-qtdeclarative-private-devel
    mesa-libGL-devel
    libX11-devel
  )
  local optional_packages=(
    qt5-qtxmlpatterns-private-devel
  )
  local available_optional_packages=()
  local pkg

  log "安装 Qt 构建必需依赖。"
  dnf install -y "${required_packages[@]}"

  for pkg in "${optional_packages[@]}"; do
    if dnf list --available "${pkg}" >/dev/null 2>&1 || rpm -q "${pkg}" >/dev/null 2>&1; then
      available_optional_packages+=("${pkg}")
    else
      log "可选依赖不存在，跳过: ${pkg}"
    fi
  done

  if [[ ${#available_optional_packages[@]} -gt 0 ]]; then
    log "安装 Qt 可选依赖。"
    dnf install -y "${available_optional_packages[@]}"
  fi
}

prepare_dirs() {
  SRC_ROOT="${BUILD_ROOT}/src"
  BUILD_DIR="${BUILD_ROOT}/build"
  STAGE_DIR="${BUILD_ROOT}/stage"
  PAYLOAD_DIR="${BUILD_ROOT}/payload"
  META_DIR="${PAYLOAD_DIR}/.qt-package-meta"
  APP_DIR="${PAYLOAD_DIR}/qtcreator"

  rm -rf "${BUILD_ROOT}"
  mkdir -p "${SRC_ROOT}" "${BUILD_DIR}" "${STAGE_DIR}" "${APP_DIR}" "${META_DIR}"
}

extract_source() {
  [[ -f "${SOURCE_PACKAGE}" ]] || fail "源码包不存在: ${SOURCE_PACKAGE}"
  log "解压源码包: ${SOURCE_PACKAGE}"
  tar -xzf "${SOURCE_PACKAGE}" -C "${SRC_ROOT}"

  SOURCE_DIR="$(find "${SRC_ROOT}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${SOURCE_DIR}" ]] || fail "未找到解压后的源码目录。"
}

build_qt_creator() {
  command -v qmake-qt5 >/dev/null 2>&1 || fail "未找到 qmake-qt5，请检查 qt5-devel 是否安装。"

  log "开始执行 qmake-qt5。"
  (
    cd "${BUILD_DIR}"
    qmake-qt5 "${SOURCE_DIR}/qtcreator.pro" "QTC_PREFIX=${INSTALL_PREFIX}"
  )

  log "开始编译 Qt Creator。"
  make -C "${BUILD_DIR}" -j"${BUILD_JOBS}"

  log "开始安装到 staging 目录。"
  make -C "${BUILD_DIR}" install INSTALL_ROOT="${STAGE_DIR}"
}

collect_payload() {
  STAGED_PREFIX="${STAGE_DIR}${INSTALL_PREFIX}"
  [[ -d "${STAGED_PREFIX}" ]] || fail "staging 目录不存在: ${STAGED_PREFIX}"

  log "整理 Qt Creator 预编译目录。"
  cp -a "${STAGED_PREFIX}/." "${APP_DIR}/"

  local desktop_file
  desktop_file="$(find "${STAGED_PREFIX}" -type f -name 'org.qt-project.qtcreator.desktop' | head -n 1 || true)"
  if [[ -n "${desktop_file}" ]]; then
    cp -a "${desktop_file}" "${META_DIR}/org.qt-project.qtcreator.desktop"
  fi
}

write_runtime_packages() {
  local qtcreator_bin
  qtcreator_bin="${APP_DIR}/bin/qtcreator"
  [[ -x "${qtcreator_bin}" ]] || fail "未找到 Qt Creator 主程序: ${qtcreator_bin}"

  log "分析 Qt Creator 运行依赖。"

  mapfile -t runtime_packages < <(
    ldd "${qtcreator_bin}" \
      | awk '/=> \// { print $3 }' \
      | sort -u \
      | while read -r lib_path; do
          rpm -qf "${lib_path}" 2>/dev/null || true
        done \
      | sed '/not owned/d' \
      | sort -u
  )

  cat > "${META_DIR}/runtime-packages.conf" <<EOF
# 由 .internal/build-qt-package.sh 自动生成
QT_RUNTIME_PACKAGES=(
$(for pkg in "${runtime_packages[@]}"; do printf '  "%s"\n' "${pkg}"; done)
)
EOF
}

write_build_info() {
  cat > "${META_DIR}/build-info.txt" <<EOF
build_time=$(date '+%F %T %z')
build_host=$(hostname)
install_prefix=${INSTALL_PREFIX}
source_package=${SOURCE_PACKAGE}
output_package=${OUTPUT_PACKAGE}
build_jobs=${BUILD_JOBS}
EOF
}

pack_output() {
  mkdir -p "$(dirname "${OUTPUT_PACKAGE}")"
  rm -f "${OUTPUT_PACKAGE}"

  log "打包输出文件: ${OUTPUT_PACKAGE}"
  (
    cd "${PAYLOAD_DIR}"
    tar -czf "${OUTPUT_PACKAGE}" qtcreator .qt-package-meta
  )
}

main() {
  require_root
  check_platform
  install_build_deps
  prepare_dirs
  extract_source
  build_qt_creator
  collect_payload
  write_runtime_packages
  write_build_info
  pack_output
  log "Qt 预编译包已生成完成。"
}

main "$@"
