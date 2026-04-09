#!/usr/bin/env bash

if [[ -n "${GC_INTERNAL_INSTALLERS_LOADED:-}" ]]; then
  return 0
fi
GC_INTERNAL_INSTALLERS_LOADED=1

gc_run_selected_installers() {
  local software_id=""

  if [[ "${#SOFTWARES[@]}" -eq 0 ]]; then
    gc_log_warn "SOFTWARES 为空，本次只执行基础环境准备。"
    return 0
  fi

  gc_log_info "本次客户安装清单: ${SOFTWARES[*]}"
  for software_id in "${SOFTWARES[@]}"; do
    gc_log_info "开始执行安装器: ${software_id}"
    case "${software_id}" in
      runtime) gc_install_runtime ;;
      chromium) gc_install_chromium ;;
      sunlogin) gc_install_sunlogin ;;
      qt) gc_install_qt ;;
      *) gc_die "未知软件 ID: ${software_id}" ;;
    esac
    gc_log_success "安装器执行完成: ${software_id}"
  done
}

gc_install_runtime() {
  local package_zip="${GC_PACKAGES_DIR}/${GC_RUNTIME_PACKAGE_FILE}"
  local tmp_dir=""
  local current_python_target=""
  local existing_markers=()
  local kernel_version="5.10.226"
  local kernel_tar="kernel_5.10.226_src.tar"
  local build_path="/lib/modules/${kernel_version}/build"
  local ethercat_zip="ethercat-1.6.0.zip"
  local ethercat_tmp="/tmp/build_igh"
  local runtime_runner=""
  local set_ecat_script=""

  gc_require_file "${package_zip}"
  gc_require_command readlink

  [[ -d "${RUNTIME_INSTALL_PATH}/board" ]] && existing_markers+=("${RUNTIME_INSTALL_PATH}/board")
  [[ -f /etc/ethercat.conf ]] && existing_markers+=("/etc/ethercat.conf")
  if systemctl list-unit-files 2>/dev/null | grep -q '^ethercat'; then
    existing_markers+=("ethercat.service")
  fi

  if [[ "${#existing_markers[@]}" -gt 0 ]]; then
    gc_log_warn "检测到已有 runtime / EtherCAT 痕迹: ${existing_markers[*]}"
    if ! gc_prompt_confirm "是否继续执行 runtime 安装并复用当前环境？" "no"; then
      gc_log_warn "按用户选择跳过 runtime 安装。"
      return 0
    fi
  fi

  if [[ "${GC_DRY_RUN}" == "1" ]]; then
    unzip -l "${package_zip}" >/dev/null
    gc_log_info "dry-run: 将解压 ${package_zip}"
    gc_log_info "dry-run: 将准备内核目录 ${build_path}"
    gc_log_info "dry-run: 将调用 wasom_codex_install_arm64.sh -p ${RUNTIME_INSTALL_PATH} -d ${RUNTIME_DATA_PATH}"
    gc_log_info "dry-run: 将自动输入 b 以源码编译 EtherCAT"
    gc_log_info "dry-run: 将配置 EtherCAT 网卡 ${RUNTIME_ETHERCAT_IFACE} / 驱动 ${RUNTIME_ETHERCAT_DRIVER}"
    gc_request_reboot "runtime 安装后通常需要重启，使 EtherCAT 和 plc-runtime 生效。"
    return 0
  fi

  gc_run mkdir -p "${GC_DEFAULT_TMP_ROOT}"
  tmp_dir="$(mktemp -d "${GC_DEFAULT_TMP_ROOT%/}/runtime.XXXXXX")"
  trap 'rm -rf "${tmp_dir}"' RETURN

  gc_run unzip -oq "${package_zip}" -d "${tmp_dir}"
  runtime_runner="${tmp_dir}/wasom_codex_install_arm64.sh"
  set_ecat_script="${tmp_dir}/setECAT.sh"

  gc_require_file "${tmp_dir}/${kernel_tar}"
  gc_require_file "${tmp_dir}/${ethercat_zip}"
  gc_require_file "${runtime_runner}"
  gc_require_file "${set_ecat_script}"
  gc_run chmod +x "${runtime_runner}" "${set_ecat_script}"

  if [[ -L "${build_path}" ]]; then
    gc_run rm -f "${build_path}"
  fi
  gc_run mkdir -p "${build_path}"
  gc_run tar -xf "${tmp_dir}/${kernel_tar}" -C "${build_path}"
  gc_run mkdir -p "${ethercat_tmp}"
  gc_run cp -f "${tmp_dir}/${ethercat_zip}" "${ethercat_tmp}/"

  if [[ ! -e /usr/bin/python ]]; then
    gc_run ln -s /usr/bin/python3 /usr/bin/python
  elif [[ -L /usr/bin/python ]]; then
    current_python_target="$(readlink -f /usr/bin/python || true)"
    if [[ "${current_python_target}" != "/usr/bin/python3" ]]; then
      gc_log_warn "/usr/bin/python 当前指向 ${current_python_target}，未自动修改。"
    fi
  else
    gc_log_warn "/usr/bin/python 已存在且不是软链接，未自动覆盖。"
  fi

  gc_log_run "cd ${tmp_dir} && printf 'b\\n' | env reboot_now=no ./wasom_codex_install_arm64.sh -p ${RUNTIME_INSTALL_PATH} -d ${RUNTIME_DATA_PATH}"
  (
    cd "${tmp_dir}"
    printf 'b\n' | env reboot_now=no ./wasom_codex_install_arm64.sh -p "${RUNTIME_INSTALL_PATH}" -d "${RUNTIME_DATA_PATH}"
  )

  gc_run "${set_ecat_script}" "${RUNTIME_ETHERCAT_IFACE}" "${RUNTIME_ETHERCAT_DRIVER}"
  gc_run systemctl enable ethercat
  gc_request_reboot "runtime 安装完成后需要重启，使 EtherCAT 和 plc-runtime 生效。"
}

gc_install_chromium() {
  local package_zip="${GC_PACKAGES_DIR}/${GC_CHROMIUM_PACKAGE_FILE}"
  local tmp_dir=""
  local libxnvctrl_rpm=""
  local chromium_common_rpm=""
  local chromium_rpm=""
  local user_created=0
  local lightdm_conf="/etc/lightdm/lightdm.conf"

  gc_require_file "${package_zip}"
  gc_require_command ldconfig
  gc_require_command useradd
  gc_require_command usermod
  gc_require_command chpasswd
  gc_require_command touch

  if [[ "${GC_DRY_RUN}" == "1" ]]; then
    unzip -l "${package_zip}" >/dev/null
    gc_log_info "dry-run: 将安装依赖 policycoreutils policycoreutils-python-utils double-conversion libffi"
    gc_log_info "dry-run: 将创建或复用用户 ${CHROMIUM_USER}"
    if gc_is_true "${CHROMIUM_ENABLE_AUTOLOGIN}"; then
      gc_log_info "dry-run: 将更新 /etc/lightdm/lightdm.conf，配置 ${CHROMIUM_USER}/${CHROMIUM_SESSION} 自动登录"
    fi
    gc_request_reboot "chromium 安装完成后建议重启或重新登录图形会话。"
    return 0
  fi

  gc_install_dnf_packages_if_missing policycoreutils policycoreutils-python-utils double-conversion libffi
  [[ -e /usr/lib64/libffi.so.8 ]] || gc_die "未找到 /usr/lib64/libffi.so.8，无法创建兼容软链接。"
  gc_run ln -sfn /usr/lib64/libffi.so.8 /usr/lib64/libffi.so.6
  gc_run ldconfig

  gc_run mkdir -p "${GC_DEFAULT_TMP_ROOT}"
  tmp_dir="$(mktemp -d "${GC_DEFAULT_TMP_ROOT%/}/chromium.XXXXXX")"
  trap 'rm -rf "${tmp_dir}"' RETURN

  gc_run unzip -oq "${package_zip}" -d "${tmp_dir}"
  libxnvctrl_rpm="${tmp_dir}/libXNVCtrl-352.21-9.el8.aarch64.rpm"
  chromium_common_rpm="${tmp_dir}/chromium-common-133.0.6943.141-1.el8.aarch64.rpm"
  chromium_rpm="${tmp_dir}/chromium-133.0.6943.141-1.el8.aarch64.rpm"

  gc_require_file "${libxnvctrl_rpm}"
  gc_require_file "${chromium_common_rpm}"
  gc_require_file "${chromium_rpm}"

  if ! rpm -q libXNVCtrl >/dev/null 2>&1; then
    gc_run rpm -ivh "${libxnvctrl_rpm}"
  else
    gc_log_info "libXNVCtrl 已安装，跳过。"
  fi

  if ! rpm -q chromium-common >/dev/null 2>&1; then
    gc_run rpm -ivh "${chromium_common_rpm}"
  else
    gc_log_info "chromium-common 已安装，跳过。"
  fi

  if ! rpm -q chromium >/dev/null 2>&1; then
    gc_run rpm -ivh --nodeps "${chromium_rpm}"
  else
    gc_log_info "chromium 已安装，跳过。"
  fi

  if id -u "${CHROMIUM_USER}" >/dev/null 2>&1; then
    gc_log_info "用户 ${CHROMIUM_USER} 已存在，复用现有账号。"
  else
    gc_run useradd -m "${CHROMIUM_USER}"
    user_created=1
  fi

  if ! id -nG "${CHROMIUM_USER}" | grep -qw wheel; then
    gc_run usermod -aG wheel "${CHROMIUM_USER}"
  fi

  if [[ -z "${CHROMIUM_PASSWORD}" && "${user_created}" == "1" ]]; then
    CHROMIUM_PASSWORD="$(gc_prompt_secret "请输入 ${CHROMIUM_USER} 的登录密码")"
  fi

  if [[ -n "${CHROMIUM_PASSWORD}" ]]; then
    gc_log_run "printf '<hidden>' | chpasswd"
    printf '%s:%s\n' "${CHROMIUM_USER}" "${CHROMIUM_PASSWORD}" | chpasswd
  else
    gc_log_warn "未设置 ${CHROMIUM_USER} 密码；如需密码登录，请后续手动执行 passwd ${CHROMIUM_USER}。"
  fi

  if gc_is_true "${CHROMIUM_ENABLE_AUTOLOGIN}"; then
    if [[ ! -f "${lightdm_conf}" ]]; then
      gc_run mkdir -p /etc/lightdm
      gc_run touch "${lightdm_conf}"
    fi
    gc_backup_once "${lightdm_conf}"
    gc_upsert_ini_key "${lightdm_conf}" "[Seat:*]" "autologin-user" "${CHROMIUM_USER}"
    gc_upsert_ini_key "${lightdm_conf}" "[Seat:*]" "autologin-session" "${CHROMIUM_SESSION}"
    gc_upsert_ini_key "${lightdm_conf}" "[Seat:*]" "autologin-user-timeout" "0"
    gc_log_success "已更新 LightDM 自动登录配置。"
  else
    gc_log_info "CHROMIUM_ENABLE_AUTOLOGIN=false，跳过 LightDM 自动登录配置。"
  fi

  gc_request_reboot "chromium 安装完成后建议重启或重新登录图形会话。"
}

gc_install_sunlogin() {
  local package_rpm="${GC_PACKAGES_DIR}/${GC_SUNLOGIN_PACKAGE_FILE}"
  local package_name=""

  gc_require_file "${package_rpm}"
  package_name="$(rpm -qp --queryformat '%{NAME}\n' "${package_rpm}")"

  if [[ "${GC_DRY_RUN}" == "1" ]]; then
    gc_log_info "dry-run: 将安装 RPM ${package_rpm} (${package_name})"
    return 0
  fi

  if rpm -q "${package_name}" >/dev/null 2>&1; then
    gc_log_info "${package_name} 已安装，跳过。"
    return 0
  fi

  gc_run rpm -ivh "${package_rpm}"
}

gc_install_qt() {
  local package_tar="${GC_PACKAGES_DIR}/${GC_QT_BINARY_PACKAGE_FILE}"
  local tmp_dir=""
  local qt_payload_dir=""
  local qt_binary_source=""
  local meta_dir=""
  local runtime_packages_file=""
  local desktop_file_source=""
  local desktop_file_target="/usr/share/applications/org.qt-project.qtcreator.desktop"
  local qt_binary=""
  local package_list_decl=""
  local -a qt_runtime_packages=()

  gc_require_file "${package_tar}"

  if [[ "${GC_DRY_RUN}" == "1" ]]; then
    tar -tzf "${package_tar}" >/dev/null
    gc_log_info "dry-run: 将解压 ${package_tar} 到 ${QT_INSTALL_DIR}"
    gc_log_info "dry-run: 将创建命令链接 ${QT_BIN_LINK}"
    gc_log_info "dry-run: 如包内带有依赖元数据，将自动安装 Qt Creator 运行依赖"
    return 0
  fi

  gc_run mkdir -p "${GC_DEFAULT_TMP_ROOT}"
  tmp_dir="$(mktemp -d "${GC_DEFAULT_TMP_ROOT%/}/qt.XXXXXX")"

  gc_run tar -xzf "${package_tar}" -C "${tmp_dir}"
  meta_dir="${tmp_dir}/.qt-package-meta"
  runtime_packages_file="${meta_dir}/runtime-packages.conf"

  if [[ -d "${tmp_dir}/qtcreator" ]]; then
    qt_payload_dir="${tmp_dir}/qtcreator"
  else
    qt_binary_source="$(find "${tmp_dir}" -type f -path '*/bin/qtcreator' | head -n 1 || true)"
    if [[ -n "${qt_binary_source}" ]]; then
      qt_payload_dir="$(cd "$(dirname "${qt_binary_source}")/.." && pwd)"
      gc_log_warn "Qt 压缩包未使用标准 qtcreator/ 顶层目录，自动识别为: ${qt_payload_dir}"
    fi
  fi

  [[ -n "${qt_payload_dir}" && -d "${qt_payload_dir}" ]] || gc_die "未在压缩包中找到 Qt Creator 安装目录，请检查 ${package_tar} 的内部结构。"

  if [[ -f "${runtime_packages_file}" ]]; then
    # shellcheck disable=SC1090
    source "${runtime_packages_file}"
    if declare -p QT_RUNTIME_PACKAGES >/dev/null 2>&1; then
      package_list_decl="$(declare -p QT_RUNTIME_PACKAGES 2>/dev/null)"
      if [[ "${package_list_decl}" == declare\ -a* ]]; then
        qt_runtime_packages=("${QT_RUNTIME_PACKAGES[@]}")
      fi
    fi
  else
    gc_log_warn "未找到 Qt 运行依赖元数据，将跳过依赖自动安装。"
  fi

  trap 'rm -rf "${tmp_dir}"' RETURN

  if [[ "${#qt_runtime_packages[@]}" -gt 0 ]]; then
    gc_install_dnf_packages_if_missing "${qt_runtime_packages[@]}"
  fi

  qt_binary="${QT_INSTALL_DIR}/bin/qtcreator"
  if [[ -d "${QT_INSTALL_DIR}" ]]; then
    if ! gc_prompt_confirm "检测到 ${QT_INSTALL_DIR} 已存在，是否覆盖安装？" "no"; then
      gc_log_warn "按用户选择跳过 qt 安装。"
      return 0
    fi
    gc_log_run "rm -rf ${QT_INSTALL_DIR}"
    rm -rf "${QT_INSTALL_DIR}"
  fi

  gc_run mkdir -p "${QT_INSTALL_DIR}"
  gc_log_run "cp -a ${qt_payload_dir}/. ${QT_INSTALL_DIR}/"
  cp -a "${qt_payload_dir}/." "${QT_INSTALL_DIR}/"

  [[ -f "${qt_binary}" ]] || gc_die "Qt Creator 主程序不存在: ${qt_binary}"

  gc_run mkdir -p "$(dirname "${QT_BIN_LINK}")"
  gc_run ln -sfn "${qt_binary}" "${QT_BIN_LINK}"

  desktop_file_source="${meta_dir}/org.qt-project.qtcreator.desktop"
  if [[ ! -f "${desktop_file_source}" && -f "${QT_INSTALL_DIR}/share/applications/org.qt-project.qtcreator.desktop" ]]; then
    desktop_file_source="${QT_INSTALL_DIR}/share/applications/org.qt-project.qtcreator.desktop"
  fi

  if [[ -f "${desktop_file_source}" ]]; then
    gc_run mkdir -p /usr/share/applications
    gc_log_run "cp ${desktop_file_source} ${desktop_file_target}"
    cp "${desktop_file_source}" "${desktop_file_target}"
    if [[ -w "${desktop_file_target}" ]]; then
      sed -i "s|^Exec=.*|Exec=${QT_BIN_LINK} %F|" "${desktop_file_target}"
      sed -i "s|^TryExec=.*|TryExec=${QT_BIN_LINK}|" "${desktop_file_target}"
    fi
  else
    gc_log_warn "未找到 Qt Creator 桌面启动文件，命令行入口仍可通过 ${QT_BIN_LINK} 使用。"
  fi
}
