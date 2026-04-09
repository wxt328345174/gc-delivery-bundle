# GC 交付安装包开发说明

本文档面向开发人员，说明当前交付包的设计原则、执行流程、现有软件安装逻辑，以及 Qt 无编译交付方案的接入方式。

客户侧使用说明请查看同目录下的 [安装说明.md](/E:/软件安装/gc-delivery-bundle/安装说明.md)。

## 1. 项目目标

当前这套交付包的目标不是做成通用运维框架，而是做成一份适合直接交付客户的离线安装包，满足以下要求：

- 客户可见结构尽量简单
- 客户只需要执行一个入口脚本
- 客户只需要修改一个配置文件
- 每个软件的安装逻辑仍保持模块化，便于后续维护
- 支持离线交付，不依赖完整开发仓库结构

因此，当前结构采用“对客户极简、对开发保留必要模块化”的轻量方案。

## 2. 当前目录结构

```text
gc-delivery-bundle/
  README.md
  安装说明.md
  install.sh
  customer.conf
  packages/
    install_runtime.zip
    chromium_installer_rpm.zip
    sunloginenterprise-5.4.3.rpm
    qt-creator-opensource-src-4.15.2.tar.gz
    qt-creator-4.15.2-openeuler-aarch64.tar.gz
  .internal/
    common.sh
    installers.sh
    build-qt-package.sh
```

说明：

- `install.sh`
  - 客户唯一入口脚本。
  - 负责参数解析、上下文初始化、读取配置、执行基础准备、调度各软件安装函数、统一处理重启。
- `customer.conf`
  - 客户安装清单。
  - 客户通常只修改这一个文件。
- `安装说明.md`
  - 面向客户的中文简版说明。
- `packages/`
  - 离线安装包目录，采用平铺方式减少层级。
- `.internal/common.sh`
  - 公共能力集合。
  - 包含日志、配置加载、校验、基础环境准备、重启策略等逻辑。
- `.internal/installers.sh`
  - 各软件安装函数。
  - 当前包含 `runtime`、`chromium`、`sunlogin`、`qt`。
- `.internal/build-qt-package.sh`
  - 仅供内部使用。
  - 用于在 openEuler aarch64 构建机上把 Qt Creator 源码包制作成客户可直接安装的预编译压缩包。

## 3. 设计原则

### 3.1 对外只保留一个入口

客户侧统一执行：

```bash
bash install.sh
```

不再要求客户理解多个子脚本的区别，也不暴露内部调度结构。

### 3.2 内部保留最小模块化

安装逻辑没有全部塞进 `install.sh`，而是收敛为两个内部模块：

- `common.sh` 处理跨软件通用能力
- `installers.sh` 处理软件安装逻辑

这样可以减少客户可见复杂度，同时避免维护时所有逻辑都混在一个超大脚本中。

### 3.3 安装包平铺

`packages/` 目录下的安装包不再按软件分子目录，而是统一平铺，原因是：

- 客户更容易核对交付文件是否齐全
- 顶层层级更少
- 主脚本可以按固定文件名直接引用

## 4. 主流程说明

`install.sh` 的执行顺序如下：

```text
解析参数
  -> 初始化路径和上下文
  -> 初始化日志
  -> 读取 customer.conf
  -> 执行基础环境准备
  -> 按 SOFTWARES 顺序执行安装器
  -> 汇总是否需要重启
  -> 根据 REBOOT_POLICY 处理重启
```

支持参数：

- `--config <path>`
  - 指定配置文件路径
- `--dry-run`
  - 只做预演，不真正安装
- `-h` / `--help`
  - 显示帮助

## 5. 各脚本职责

### 5.1 install.sh

职责：

- 解析命令行参数
- 加载 `.internal/common.sh`
- 加载 `.internal/installers.sh`
- 初始化上下文和日志
- 读取配置
- 调度主流程

约束：

- 不在这里写具体软件安装细节
- 保持入口简单稳定

### 5.2 .internal/common.sh

职责：

- 初始化目录和固定文件名
- 统一日志输出
- 配置加载与默认值填充
- 软件 ID 合法性校验
- 目标平台检查
- 基础依赖安装
- 通用配置文件备份和修改
- 重启策略统一处理

开发原则：

- 这里放跨软件通用逻辑
- 不要把某个软件专属流程塞进这里

### 5.3 .internal/installers.sh

职责：

- 根据 `SOFTWARES` 调度软件安装函数
- 定义每个软件的独立安装函数

当前函数：

- `gc_install_runtime`
- `gc_install_chromium`
- `gc_install_sunlogin`
- `gc_install_qt`

开发原则：

- 新软件优先新增独立函数
- 公共逻辑继续抽到 `common.sh`

## 6. 当前软件安装逻辑

### 6.1 runtime

当前流程：

- 校验 `packages/install_runtime.zip`
- 检查是否已有 runtime 或 EtherCAT 安装痕迹
- 解压到临时目录
- 处理 `/usr/bin/python -> /usr/bin/python3`
- 解压内核源码到 `/lib/modules/5.10.226/build`
- 准备 `/tmp/build_igh/ethercat-1.6.0.zip`
- 直接调用包内真正安装器 `wasom_codex_install_arm64.sh`
- 自动传入：
  - `-p "${RUNTIME_INSTALL_PATH}"`
  - `-d "${RUNTIME_DATA_PATH}"`
- 自动向安装器输入 `b`，触发 EtherCAT 源码编译路径
- 安装完成后执行 `setECAT.sh <iface> <driver>`
- 执行 `systemctl enable ethercat`
- 登记重启需求，由主流程统一决定是否重启

注意：

- 当前实现不再走外层包装脚本 `install_runtime_20260324.sh`，因为该脚本会吞掉路径参数并导致交互错位。
- 默认安装路径 `/wa-edge` 不是猜测，而是来自包内真实安装器的默认逻辑。

### 6.2 chromium

当前流程：

- 校验 `packages/chromium_installer_rpm.zip`
- 安装依赖：
  - `policycoreutils`
  - `policycoreutils-python-utils`
  - `double-conversion`
  - `libffi`
- 修复 `libffi.so.6` 兼容软链接
- 解压 RPM 包
- 安装：
  - `libXNVCtrl`
  - `chromium-common`
  - `chromium`
- 创建或复用普通用户
- 将用户加入 `wheel`
- 如密码为空则交互提示输入
- 更新 `/etc/lightdm/lightdm.conf`
- 登记重启需求

### 6.3 sunlogin

当前流程：

- 校验 `packages/sunloginenterprise-5.4.3.rpm`
- 读取 RPM 包名
- 若未安装则执行 `rpm -ivh`

这是当前最简单的安装器，适合作为新增软件时的最小模板参考。

### 6.4 qt

当前方案已经切换为“客户侧零编译”：

- 客户侧不再直接使用 `qt-creator-opensource-src-4.15.2.tar.gz`
- 该源码包只作为内部构建输入
- 客户侧真正安装的是预编译压缩包：

```text
packages/qt-creator-4.15.2-openeuler-aarch64.tar.gz
```

`gc_install_qt` 当前流程：

- 校验预编译压缩包是否存在
- dry-run 时检查包结构是否合法
- 解压到临时目录
- 读取 `.qt-package-meta/runtime-packages.conf`
- 自动安装 Qt Creator 运行依赖
- 部署到 `QT_INSTALL_DIR`
- 创建 `QT_BIN_LINK -> <install dir>/bin/qtcreator`
- 如压缩包内包含桌面文件，则安装到 `/usr/share/applications/`

默认配置：

```bash
QT_INSTALL_DIR="/opt/qtcreator-4.15.2"
QT_BIN_LINK="/usr/local/bin/qtcreator"
```

## 7. Qt 预编译包内部构建流程

### 7.1 为什么要内部预编译

原始文档中的 Qt 安装方式要求客户机现场编译，存在以下问题：

- 安装耗时长
- 需要完整编译依赖
- 客户侧失败点多
- 现场问题排查成本高

因此改为：

- 内部先在匹配环境编译一次
- 产出标准预编译压缩包
- 客户侧只做依赖安装和解压部署

### 7.2 构建环境要求

`.internal/build-qt-package.sh` 需要在以下环境运行：

- `openEuler aarch64`
- root 用户
- 能访问 `dnf`

### 7.3 内部构建命令

在内部 Linux 构建机上执行：

```bash
bash .internal/build-qt-package.sh
```

常用可选参数：

```bash
bash .internal/build-qt-package.sh \
  --source ./packages/qt-creator-opensource-src-4.15.2.tar.gz \
  --output ./packages/qt-creator-4.15.2-openeuler-aarch64.tar.gz \
  --prefix /opt/qtcreator-4.15.2
```

### 7.4 构建脚本做什么

构建脚本会自动：

- 安装 Qt Creator 编译依赖
- 解压源码包
- 执行 `qmake-qt5`
- 执行 `make -j$(nproc)`
- 执行 `make install`
- 生成 staging 目录
- 抽取 Qt Creator 安装结果
- 根据 `ldd` 和 `rpm -qf` 生成运行依赖清单
- 写入 `.qt-package-meta/runtime-packages.conf`
- 写入 `.qt-package-meta/build-info.txt`
- 打包输出预编译压缩包

### 7.5 预编译包结构约定

当前 `gc_install_qt` 假定预编译包内部结构如下：

```text
qtcreator/
.qt-package-meta/
  runtime-packages.conf
  build-info.txt
  org.qt-project.qtcreator.desktop
```

其中：

- `qtcreator/`
  - 对应最终要复制到 `QT_INSTALL_DIR` 下的目录内容
- `runtime-packages.conf`
  - 由构建脚本生成，声明需要通过 `dnf` 安装的运行依赖
- `org.qt-project.qtcreator.desktop`
  - 可选，用于桌面菜单集成

## 8. 如何新增一个软件

假设后续需要新增 `xxx` 软件，建议按以下顺序处理：

1. 将安装包放入 `packages/xxx-installer.xxx`
2. 在 `.internal/installers.sh` 中新增 `gc_install_xxx`
3. 在 `gc_run_selected_installers` 中接入 `xxx`
4. 在 `.internal/common.sh` 的 `GC_SUPPORTED_SOFTWARES` 中加入 `xxx`
5. 如需参数，则补充：
   - `customer.conf`
   - `gc_load_config`
6. 更新：
   - `安装说明.md`
   - `README.md`

## 9. 验证方式

### 9.1 语法检查

在具备 Bash 的环境中执行：

```bash
bash -n install.sh .internal/common.sh .internal/installers.sh .internal/build-qt-package.sh
```

### 9.2 帮助检查

```bash
bash install.sh --help
```

### 9.3 dry-run 检查

在目标 Linux 设备上执行：

```bash
bash install.sh --dry-run
```

重点关注：

- 配置文件能否正常读取
- 软件 ID 是否识别正确
- 安装包是否齐全
- 基础依赖检查是否正常
- 重启提示是否符合预期

### 9.4 Qt 相关验证

内部构建完成后，应至少验证：

```bash
tar -tzf packages/qt-creator-4.15.2-openeuler-aarch64.tar.gz
bash install.sh --dry-run
```

实机安装验证：

```bash
# customer.conf 中仅安装 qt
SOFTWARES=("qt")

bash install.sh
qtcreator --help
```

如有桌面环境，再确认菜单项是否可见、是否可正常启动。

## 10. 打包交付建议

面向客户打包时，建议仅交付以下内容：

- `install.sh`
- `customer.conf`
- `安装说明.md`
- `packages/`
- `.internal/`

不要交付：

- `.git/`
- 本地 IDE 配置
- 开发过程日志
- 构建中间目录

如果从当前仓库目录直接压缩，请明确排除：

- `.git`
- `logs`
- 临时测试文件

## 11. 已知限制

### 11.1 当前无法在 Windows 主机直接产出 Qt Linux 预编译包

本仓库已经具备 Qt 客户侧安装支持和内部构建脚本，但真正的 Qt 预编译包仍需在 `openEuler aarch64` 构建机上执行 `.internal/build-qt-package.sh` 才能生成。

### 11.2 runtime 仍依赖外部交付包内部脚本行为

当前 `runtime` 集成方式依赖 `install_runtime.zip` 内部已有文件名和交互逻辑。如果包内脚本将来变更，需要重点回归：

- 安装路径参数是否仍有效
- 输入 `b` 的 EtherCAT 编译流程是否仍成立
- `setECAT.sh` 是否仍保持当前接口

### 11.3 版本治理仍较轻

当前主要依赖固定文件名和 RPM 查询，不包含更严格的：

- SHA256 校验
- 发布清单
- 包版本矩阵

后续如交付规模扩大，可再补强。

## 12. 维护原则总结

维护这个项目时，优先遵守以下原则：

1. 客户入口永远保持只有一个：`install.sh`
2. 客户配置尽量只保留一个：`customer.conf`
3. 对客户隐藏内部实现细节，但内部保留必要模块化
4. 所有通用逻辑进入 `common.sh`
5. 软件特有逻辑进入 `installers.sh`
6. 文档分层：
   - 客户看 `安装说明.md`
   - 开发看 `README.md`
