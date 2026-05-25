# GC 交付安装包开发说明

本文档面向开发人员，说明当前交付包的结构、主流程、各软件安装逻辑，以及内部构建脚本的用途。

客户侧使用说明请查看同目录下的 [安装说明.md](/E:/软件安装/gc-delivery-bundle/安装说明.md)。

## 1. 目录结构

```text
gc-delivery-bundle/
  README.md
  安装说明.md
  install.sh
  customer.conf
  packages/
    install_runtime.zip
    ethcat_aarch64_<uname-r>.tar.gz
    chromium_installer_rpm.zip
    sunloginenterprise-5.4.3.rpm
    qt-creator-opensource-src-4.15.2.tar.gz
    qt-creator-4.15.2-openeuler-aarch64.tar.gz
  .internal/
    common.sh
    installers.sh
    build-runtime-igh-package.sh
    build-qt-package.sh
```

说明：

- `install.sh`
  - 客户唯一入口脚本
  - 负责参数解析、日志初始化、读取配置、执行基础环境准备、调度安装器、统一处理重启
- `customer.conf`
  - 客户安装清单
  - 客户通常只需要修改这一个文件
- `packages/`
  - 离线安装包目录
  - 当前采用平铺结构，减少层级
- `.internal/common.sh`
  - 公共能力
  - 包括日志、配置加载、校验、基础环境准备、重启策略
- `.internal/installers.sh`
  - 各软件安装函数
  - 当前包含 `runtime`、`chromium`、`sunlogin`、`qt`
- `.internal/build-runtime-igh-package.sh`
  - 内部使用
  - 用于提前构建 IGH EtherCAT 预编译安装包
- `.internal/build-qt-package.sh`
  - 内部使用
  - 用于构建 Qt Creator 预编译安装包

## 2. 主流程说明

`install.sh` 的执行顺序如下：

```text
解析参数
  -> 初始化上下文
  -> 初始化日志
  -> 读取 customer.conf
  -> 执行基础环境准备
  -> 按 SOFTWARES 顺序执行安装器
  -> 汇总是否需要重启
  -> 根据 REBOOT_POLICY 处理重启
```

支持参数：

- `--config <path>`
- `--dry-run`
- `-h` / `--help`

## 3. 各软件安装逻辑

### 3.1 runtime

当前 `runtime` 安装器支持两条路径：

1. 预编译 IGH 优先路径
   - 运行时先查找：
     `packages/ethcat_$(uname -m)_$(uname -r).tar.gz`
   - 如果存在，则复制到万昇安装器同级目录
   - 直接调用 `wasom_codex_install_arm64.sh`
   - 不再输入 `b`
   - 不再现场编译 IGH

2. 源码编译回退路径
   - 如果未找到预编译 IGH 包
   - 则继续沿用原有逻辑
   - 准备 `kernel_5.10.226_src.tar`
   - 准备 `/tmp/build_igh/ethercat-1.6.0.zip`
   - 自动输入 `b`
   - 触发万昇内层安装器源码编译 IGH

共同行为：

- 调用万昇安装器时会显式传入：
  - `-p "${RUNTIME_INSTALL_PATH}"`
  - `-d "${RUNTIME_DATA_PATH}"`
- 安装完成后调用 `setECAT.sh <iface> <driver>`
- 执行 `systemctl enable ethercat`
- 登记重启需求，由主流程统一决定是否重启

为什么可以提前编译：

- GCRuntime 本体已经是万昇预编译应用
- 7 分钟中的主要耗时来自 IGH EtherCAT 编译
- 万昇内层安装器本身就支持优先安装预编译 EtherCAT 包

为什么不能做成通用单包：

- IGH 产物里包含 `.ko` 内核模块
- 安装脚本会强校验 `ETHERCAT_TARGET == $(uname -m)_$(uname -r)`
- 模块实际安装路径也写死在 `/lib/modules/$(uname -r)/...`
- 因此必须与目标机内核版本匹配

### 3.2 chromium

当前流程：

- 解压 `chromium_installer_rpm.zip`
- 安装依赖：
  - `policycoreutils`
  - `policycoreutils-python-utils`
  - `double-conversion`
  - `libffi`
- 修复 `libffi.so.6`
- 安装 `libXNVCtrl`、`chromium-common`、`chromium`
- 创建或复用 `gcuser`
- 将 `gcuser` 加入 `wheel`
- 将密码固定设置为与用户名相同
- 按配置修改 `/etc/lightdm/lightdm.conf`

默认口径：

```text
用户名: gcuser
密码: gcuser
```

### 3.3 sunlogin

当前流程：

- 校验 `sunloginenterprise-5.4.3.rpm`
- 读取 RPM 包名
- 如果未安装则执行 `rpm -ivh`

### 3.4 qt

当前 Qt 采用客户侧零编译方案：

- 客户侧真正安装的是：
  `packages/qt-creator-4.15.2-openeuler-aarch64.tar.gz`
- 安装时自动读取 `.qt-package-meta/runtime-packages.conf`
- 自动安装运行依赖
- 解压到 `QT_INSTALL_DIR`
- 创建 `QT_BIN_LINK`
- 如有桌面文件则安装到 `/usr/share/applications/`

## 4. 内部构建脚本

### 4.1 IGH 预编译包构建

入口脚本：

```bash
bash .internal/build-runtime-igh-package.sh
```

作用：

- 解压 `install_runtime.zip`
- 提取万昇安装器内嵌 payload
- 取出万昇提供的 IGH patch
- 准备目标内核目录
- 编译 `ethercat-1.6.0`
- 重新打包为万昇内层安装器可直接识别的结构

默认输出：

```text
packages/ethcat_aarch64_<uname-r>.tar.gz
```

常用参数：

```bash
bash .internal/build-runtime-igh-package.sh \
  --kernel-dir /lib/modules/$(uname -r)/build \
  --kernel-release $(uname -r)
```

说明：

- 如果目标设备内核固定，建议直接在同内核版本的构建机上生成该包
- 如果目标设备 `uname -r` 与源码目录识别出的版本不同，请显式传 `--kernel-release`

### 4.2 Qt 预编译包构建

入口脚本：

```bash
bash .internal/build-qt-package.sh
```

作用：

- 构建 Qt Creator
- 自动分析运行依赖
- 重新打包为客户可直接解压安装的预编译包

## 5. 验证方式

### 5.1 语法检查

```bash
bash -n install.sh \
  .internal/common.sh \
  .internal/installers.sh \
  .internal/build-runtime-igh-package.sh \
  .internal/build-qt-package.sh
```

### 5.2 runtime 预编译 IGH 验证

先构建：

```bash
bash .internal/build-runtime-igh-package.sh
```

检查产物：

```bash
tar -tzf packages/ethcat_aarch64_$(uname -r).tar.gz | head -n 50
```

目标机安装验证：

```bash
SOFTWARES=("runtime")
bash install.sh
```

验收重点：

- 日志中应出现“检测到预编译 IGH 包”
- 日志中不应再出现“输入 b 编译 IGH”
- `systemctl status ethercat` 正常
- `ps aux | grep runtime` 可看到运行进程

### 5.3 Qt 验证

```bash
bash .internal/build-qt-package.sh
tar -tzf packages/qt-creator-4.15.2-openeuler-aarch64.tar.gz
```

## 6. 打包交付建议

面向客户打包时，建议只交付：

- `install.sh`
- `customer.conf`
- `安装说明.md`
- `packages/`
- `.internal/`

不要交付：

- `.git/`
- 构建中间目录
- 本地测试日志

如果从当前仓库目录直接压缩，请排除：

- `.git`
- `logs`
- 临时测试文件
