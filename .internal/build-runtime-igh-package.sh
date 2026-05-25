#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNTIME_PACKAGE="${ROOT_DIR}/packages/install_runtime.zip"
BUILD_ROOT="/tmp/gc-runtime-igh-build"
KERNEL_DIR=""
KERNEL_RELEASE=""
OUTPUT_PACKAGE=""
KEEP_BUILD_ROOT="no"
ARCH="$(uname -m)"

usage() {
  cat <<'EOF'
用法：
  bash .internal/build-runtime-igh-package.sh [选项]

选项：
  --runtime-package <path>  指定 install_runtime.zip 路径
  --kernel-dir <path>       指定目标内核头文件或源码目录
  --kernel-release <ver>    指定目标设备的 uname -r
  --output <path>           指定输出包路径
  --build-root <path>       指定临时构建目录
  --keep-build-root         构建成功后保留临时目录
  -h, --help                显示帮助

说明：
  该脚本用于提前构建 IGH EtherCAT 预编译安装包，产物命名为：
  ethcat_<arch>_<uname-r>.tar.gz

  推荐在与目标设备相同的 openEuler aarch64 环境中执行。
  如果当前系统存在 /lib/modules/$(uname -r)/build，则默认优先使用该内核目录；
  否则会回退到 install_runtime.zip 中自带的 kernel_*_src.tar。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-package)
      RUNTIME_PACKAGE="$2"
      shift 2
      ;;
    --kernel-dir)
      KERNEL_DIR="$2"
      shift 2
      ;;
    --kernel-release)
      KERNEL_RELEASE="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PACKAGE="$2"
      shift 2
      ;;
    --build-root)
      BUILD_ROOT="$2"
      shift 2
      ;;
    --keep-build-root)
      KEEP_BUILD_ROOT="yes"
      shift
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

warn() {
  printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ "${KEEP_BUILD_ROOT}" == "yes" || "${exit_code}" -ne 0 ]]; then
    return 0
  fi
  rm -rf "${BUILD_ROOT}"
}

trap cleanup EXIT

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "请使用 root 执行该脚本。"
}

check_platform() {
  [[ "$(uname -s)" == "Linux" ]] || fail "仅支持在 Linux 上执行。"
  [[ "${ARCH}" == "aarch64" ]] || fail "仅支持在 aarch64 上执行，当前为 ${ARCH}。"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "openEuler" && "${ID:-}" != "openeuler" ]]; then
      warn "当前系统不是 openEuler，实际为 ${ID:-unknown}。仍将继续，但请自行确认兼容性。"
    fi
  fi
}

install_build_deps() {
  local packages=(
    autoconf
    automake
    libtool
    pkgconf-pkg-config
    gcc
    gcc-c++
    make
    patch
    python3
    unzip
    tar
    wget
    bison
    flex
  )

  log "安装 IGH 构建依赖。"
  dnf install -y "${packages[@]}"
}

ensure_python_compat() {
  if [[ -x /usr/bin/python ]]; then
    return 0
  fi

  [[ -x /usr/bin/python3 ]] || fail "未找到 /usr/bin/python3，无法为内核构建创建 python 兼容入口。"
  log "创建 /usr/bin/python -> /usr/bin/python3 兼容链接"
  ln -s /usr/bin/python3 /usr/bin/python
}

prepare_dirs() {
  RUNTIME_DIR="${BUILD_ROOT}/runtime"
  PAYLOAD_DIR="${BUILD_ROOT}/payload"
  SOURCE_DIR="${BUILD_ROOT}/source"
  EXTRACTED_KERNEL_DIR="${BUILD_ROOT}/kernel"
  OUT_DIR="${BUILD_ROOT}/out"
  ETHCAT_OUT_DIR="${OUT_DIR}/ethcat"

  rm -rf "${BUILD_ROOT}"
  mkdir -p "${RUNTIME_DIR}" "${PAYLOAD_DIR}" "${SOURCE_DIR}" "${EXTRACTED_KERNEL_DIR}" "${ETHCAT_OUT_DIR}"
}

extract_runtime_package() {
  [[ -f "${RUNTIME_PACKAGE}" ]] || fail "未找到 runtime 安装包: ${RUNTIME_PACKAGE}"

  log "解压 runtime 安装包。"
  unzip -oq "${RUNTIME_PACKAGE}" -d "${RUNTIME_DIR}"

  WASOM_RUNNER="${RUNTIME_DIR}/wasom_codex_install_arm64.sh"
  ETHERCAT_SOURCE_ZIP="${RUNTIME_DIR}/ethercat-1.6.0.zip"
  KERNEL_TAR="$(find "${RUNTIME_DIR}" -maxdepth 1 -type f -name 'kernel_*_src.tar' | head -n 1)"

  [[ -f "${WASOM_RUNNER}" ]] || fail "未找到 wasom_codex_install_arm64.sh"
  [[ -f "${ETHERCAT_SOURCE_ZIP}" ]] || fail "未找到 ethercat-1.6.0.zip"
}

extract_runtime_payload() {
  local payload_start=""
  local payload_tar="${BUILD_ROOT}/runtime-payload.tar.gz"

  payload_start="$(awk '/^PAYLOAD:$/ { print NR + 1; exit }' "${WASOM_RUNNER}")"
  [[ -n "${payload_start}" ]] || fail "未能在 ${WASOM_RUNNER} 中定位 PAYLOAD 段。"

  log "提取万昇安装器内嵌 payload。"
  tail -n +"${payload_start}" "${WASOM_RUNNER}" > "${payload_tar}"
  tar -xzf "${payload_tar}" -C "${PAYLOAD_DIR}"

  PATCH_FILE="${PAYLOAD_DIR}/scripts/ethercat-patch-1.6.0.diff"
  [[ -f "${PATCH_FILE}" ]] || fail "未找到 IGH patch 文件: ${PATCH_FILE}"
}

prepare_kernel_dir() {
  if [[ -n "${KERNEL_DIR}" ]]; then
    [[ -d "${KERNEL_DIR}" ]] || fail "指定的内核目录不存在: ${KERNEL_DIR}"
    log "使用指定内核目录: ${KERNEL_DIR}"
    return 0
  fi

  if [[ -d "/lib/modules/$(uname -r)/build" ]]; then
    KERNEL_DIR="/lib/modules/$(uname -r)/build"
    log "使用当前系统内核目录: ${KERNEL_DIR}"
    return 0
  fi

  [[ -n "${KERNEL_TAR:-}" && -f "${KERNEL_TAR}" ]] || fail "未找到可用的内核源码目录，也未在 runtime 包中找到 kernel_*_src.tar"

  log "回退到 runtime 包内自带内核源码: ${KERNEL_TAR}"
  tar -xf "${KERNEL_TAR}" -C "${EXTRACTED_KERNEL_DIR}"
  KERNEL_DIR="${EXTRACTED_KERNEL_DIR}"
}

detect_kernel_release() {
  local version=""
  local patchlevel=""
  local sublevel=""
  local extraversion=""
  local kernel_tar_name=""

  if [[ -n "${KERNEL_RELEASE}" ]]; then
    log "使用指定内核版本: ${KERNEL_RELEASE}"
    return 0
  fi

  if [[ -f "${KERNEL_DIR}/include/config/kernel.release" ]]; then
    KERNEL_RELEASE="$(tr -d '\r\n' < "${KERNEL_DIR}/include/config/kernel.release")"
  elif [[ -f "${KERNEL_DIR}/Makefile" ]]; then
    version="$(awk '/^VERSION =/ { print $3; exit }' "${KERNEL_DIR}/Makefile")"
    patchlevel="$(awk '/^PATCHLEVEL =/ { print $3; exit }' "${KERNEL_DIR}/Makefile")"
    sublevel="$(awk '/^SUBLEVEL =/ { print $3; exit }' "${KERNEL_DIR}/Makefile")"
    extraversion="$(awk -F'= ' '/^EXTRAVERSION =/ { print $2; exit }' "${KERNEL_DIR}/Makefile")"
    KERNEL_RELEASE="${version}.${patchlevel}.${sublevel}${extraversion}"
  elif [[ -n "${KERNEL_TAR:-}" ]]; then
    kernel_tar_name="$(basename "${KERNEL_TAR}")"
    if [[ "${kernel_tar_name}" =~ ^kernel_(.+)_src\.tar$ ]]; then
      KERNEL_RELEASE="${BASH_REMATCH[1]}"
    fi
  fi

  [[ -n "${KERNEL_RELEASE}" ]] || fail "无法识别目标内核版本，请使用 --kernel-release 显式指定。"
  log "目标内核版本: ${KERNEL_RELEASE}"
}

build_igh() {
  local source_extract_dir=""

  log "解压 IGH 源码。"
  unzip -oq "${ETHERCAT_SOURCE_ZIP}" -d "${SOURCE_DIR}"
  source_extract_dir="$(find "${SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'ethercat-1.6.0*' | head -n 1)"
  [[ -n "${source_extract_dir}" ]] || fail "未找到解压后的 IGH 源码目录。"
  IGH_DIR="${source_extract_dir}"

  cp "${PATCH_FILE}" "${IGH_DIR}/patch.diff"

  log "应用万昇提供的 IGH patch。"
  (
    cd "${IGH_DIR}"
    patch -p1 --dry-run < patch.diff >/dev/null
    patch -p1 < patch.diff
  )

  log "执行 bootstrap。"
  (
    cd "${IGH_DIR}"
    ./bootstrap
  )

  log "执行 configure。"
  (
    cd "${IGH_DIR}"
    ./configure --sysconfdir=/etc --enable-8139too=no --enable-generic --enable-kernel --with-linux-dir="${KERNEL_DIR}"
  )

  log "编译 IGH EtherCAT。"
  (
    cd "${IGH_DIR}"
    make -j"$(nproc)" all modules
  )
}

package_igh() {
  [[ -x "${IGH_DIR}/tool/ethercat" ]] || fail "未生成 ethercat 工具。"
  [[ -f "${IGH_DIR}/master/ec_master.ko" ]] || fail "未生成 ec_master.ko。"
  [[ -d "${IGH_DIR}/script" ]] || fail "未生成 script 目录。"

  mkdir -p "${ETHCAT_OUT_DIR}/tool" "${ETHCAT_OUT_DIR}/include" "${ETHCAT_OUT_DIR}/lib" "${OUT_DIR}/modules/devices"

  cp -a "${IGH_DIR}/tool/ethercat" "${ETHCAT_OUT_DIR}/tool/"
  cp -a "${IGH_DIR}/include/ecrt.h" "${ETHCAT_OUT_DIR}/include/"
  cp -a "${IGH_DIR}/include/ectty.h" "${ETHCAT_OUT_DIR}/include/"
  cp -a "${IGH_DIR}/lib/.libs/libethercat.so"* "${ETHCAT_OUT_DIR}/lib/"
  cp -a "${IGH_DIR}/script" "${ETHCAT_OUT_DIR}/"
  cp -a "${IGH_DIR}/master/ec_master.ko" "${OUT_DIR}/modules/"
  cp -a "${IGH_DIR}/devices/"*.ko "${OUT_DIR}/modules/devices/"

  printf 'export ETHERCAT_TARGET=%s_%s\n' "${ARCH}" "${KERNEL_RELEASE}" > "${ETHCAT_OUT_DIR}/install_env.sh"
  chmod +x "${ETHCAT_OUT_DIR}/install_env.sh"

  [[ -n "${OUTPUT_PACKAGE}" ]] || OUTPUT_PACKAGE="${ROOT_DIR}/packages/ethcat_${ARCH}_${KERNEL_RELEASE}.tar.gz"
  mkdir -p "$(dirname "${OUTPUT_PACKAGE}")"
  rm -f "${OUTPUT_PACKAGE}"

  log "打包预编译 IGH 安装包: ${OUTPUT_PACKAGE}"
  (
    cd "${OUT_DIR}"
    tar -zcf "${OUTPUT_PACKAGE}" ethcat modules
  )
}

main() {
  require_root
  check_platform
  install_build_deps
  ensure_python_compat
  prepare_dirs
  extract_runtime_package
  extract_runtime_payload
  prepare_kernel_dir
  detect_kernel_release
  build_igh
  package_igh
  log "IGH 预编译包构建完成。"
}

main "$@"
