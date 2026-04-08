# GC 交付安装包开发说明

本文档面向开发人员，说明当前交付包的设计思路、目录约定、执行流程、扩展方式和维护注意事项。

客户侧使用说明请看同目录下的 [安装说明.md](./安装说明.md)。

## 1. 项目目标

当前这套安装包的目标不是做成通用运维框架，而是做成一份适合直接交付客户的离线安装包，满足以下要求：

- 客户可见结构尽量简单
- 客户只需要执行一个入口脚本
- 客户只需要修改一个配置文件
- 每个软件的安装逻辑仍然保持模块化，方便后续维护
- 支持离线交付，不依赖额外代码仓库结构

因此，当前结构是“对客户极简，对开发保留最少必要模块化”的折中方案。

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
  .internal/
    common.sh
    installers.sh
```

说明：

- `install.sh`
  - 客户唯一入口脚本
  - 负责参数解析、加载配置、执行基础准备、调度各软件安装器、统一处理重启
- `customer.conf`
  - 客户安装清单
  - 客户通常只改这个文件
- `安装说明.md`
  - 面向客户的简版中文说明
- `packages/`
  - 离线安装包目录
  - 当前采用平铺方式，减少目录层级
- `.internal/common.sh`
  - 公共函数
  - 包含日志、配置加载、校验、基础环境准备、重启处理等逻辑
- `.internal/installers.sh`
  - 各软件安装函数
  - 当前包含 `runtime`、`chromium`、`sunlogin`

## 3. 设计原则

### 3.1 为什么只保留一个入口脚本

客户交付场景下，文件和目录越多，越容易出现以下问题：

- 客户不知道应该运行哪个脚本
- 客户误修改内部脚本
- 交付说明需要解释大量内部结构
- 现场人员执行路径不统一

因此对外统一为：

```bash
bash install.sh
```

### 3.2 为什么内部不完全写成一个超大脚本

如果把所有逻辑完全塞进 `install.sh`，短期文件数量最少，但后续维护成本会明显升高：

- 不同软件安装逻辑相互污染
- 调试时难以定位
- 后续新增软件时更容易引入回归
- 公共能力和业务逻辑耦合过深

所以内部保留两个模块文件：

- `common.sh` 处理公共能力
- `installers.sh` 处理软件安装逻辑

这已经是面向交付场景下比较轻量的平衡点。

### 3.3 为什么 packages 采用平铺

当前 `packages/` 不再按软件建子目录，原因是：

- 客户更容易核对交付文件是否齐全
- 目录结构更少
- 主脚本引用固定文件名即可

代价是如果未来软件数量很多，文件名管理会变得更依赖命名规范。当前规模下这是可接受的。

## 4. 执行流程

`install.sh` 的主流程如下：

```text
解析参数
  -> 初始化上下文
  -> 初始化日志
  -> 加载 customer.conf
  -> 执行基础环境准备
  -> 按 SOFTWARES 顺序执行安装函数
  -> 汇总重启需求
  -> 根据 REBOOT_POLICY 处理重启
```

### 4.1 参数解析

当前支持：

- `--config <path>`：指定配置文件
- `--dry-run`：只做预演，不真正安装
- `-h` / `--help`：显示帮助

### 4.2 配置加载

配置由 `customer.conf` 提供，脚本会在加载后填充默认值并做校验。

当前关键配置包括：

- `SOFTWARES`
- `REBOOT_POLICY`
- `RUNTIME_INSTALL_PATH`
- `RUNTIME_DATA_PATH`
- `RUNTIME_ETHERCAT_IFACE`
- `RUNTIME_ETHERCAT_DRIVER`
- `CHROMIUM_USER`
- `CHROMIUM_ENABLE_AUTOLOGIN`
- `CHROMIUM_SESSION`
- `CHROMIUM_PASSWORD`

### 4.3 基础环境准备

基础环境准备由 `gc_run_base_setup` 负责，主要做：

- root 校验
- Linux 校验
- `openEuler` / 架构提示
- 核心命令存在性检查
- 缺失工具安装：`sudo`、`wget`、`unzip`

原则是：

- 所有客户都需要的能力放在这里
- 某个软件特有的依赖放到对应安装函数里

### 4.4 软件安装调度

`gc_run_selected_installers` 会按 `SOFTWARES` 的顺序执行安装函数。

例如：

```bash
SOFTWARES=("runtime" "chromium" "sunlogin")
```

则执行顺序为：

1. `gc_install_runtime`
2. `gc_install_chromium`
3. `gc_install_sunlogin`

如果某一步失败，脚本会立即退出，避免后续步骤在不一致环境下继续执行。

### 4.5 重启处理

各安装函数内部不直接最终决定是否重启，而是通过 `gc_request_reboot` 登记重启需求。

最后由 `gc_finish_reboot_flow` 统一处理，这样可以避免：

- `runtime` 装完立刻重启，导致后面的软件没执行
- 多个软件各自重复提示是否重启

这是当前结构里一个比较关键的设计点。

## 5. 各文件职责

### 5.1 install.sh

职责：

- 解析命令行参数
- 加载内部模块
- 初始化上下文和日志
- 读取 `customer.conf`
- 调度主流程

约束：

- 不在这里写大量具体软件安装细节
- 入口尽量保持短和稳定

### 5.2 .internal/common.sh

职责：

- 上下文初始化
- 路径解析
- 日志输出
- 配置加载
- 参数和环境校验
- dry-run 支持
- 备份配置文件
- 更新 ini 风格配置
- 基础环境安装
- 重启策略处理

维护建议：

- 这里放“跨软件通用”的能力
- 不要把某个软件的专用逻辑塞进来

### 5.3 .internal/installers.sh

职责：

- 调度软件安装
- 定义各软件安装函数

当前包含：

- `gc_install_runtime`
- `gc_install_chromium`
- `gc_install_sunlogin`

维护建议：

- 新软件优先以新增函数的方式扩展
- 公共逻辑抽到 `common.sh`
- 保持每个安装函数的输入只依赖配置和固定包文件

## 6. 当前软件安装逻辑说明

### 6.1 runtime

当前逻辑：

- 校验 `packages/install_runtime.zip`
- 检查是否已有 runtime / EtherCAT 安装痕迹
- 解压到临时目录
- 为包内脚本增加执行权限
- 按需创建 `/usr/bin/python -> /usr/bin/python3`
- 调用 `install_runtime_20260324.sh`
- 调用 `setECAT.sh`
- `systemctl enable ethercat`
- 登记重启需求

当前实现特点：

- 默认自动向包内脚本输入 `b`，走 EtherCAT 源码构建路径
- 默认通过环境变量和输入，避免包内脚本在中途自己重启

注意：

- 这里对包内脚本的交互行为有依赖
- 如果 `install_runtime.zip` 内部脚本将来变化，需重新验证交互方式

### 6.2 chromium

当前逻辑：

- 校验 `packages/chromium_installer_rpm.zip`
- 安装依赖：
  - `policycoreutils`
  - `policycoreutils-python-utils`
  - `double-conversion`
  - `libffi`
- 修复 `libffi.so.6` 兼容软链接
- 解压 zip 中的 RPM
- 安装：
  - `libXNVCtrl`
  - `chromium-common`
  - `chromium`
- 创建或复用普通用户
- 将用户加入 `wheel`
- 按需设置密码
- 按配置更新 `/etc/lightdm/lightdm.conf`
- 登记重启需求

注意：

- `CHROMIUM_PASSWORD=""` 时，会在执行时提示输入
- 自动登录通过写 `LightDM` 配置实现

### 6.3 sunlogin

当前逻辑：

- 校验 `packages/sunloginenterprise-5.4.3.rpm`
- 读取 RPM 包名
- 若未安装则执行 `rpm -ivh`

特点：

- 逻辑最简单
- 适合作为后续新增软件安装器的最小参考模板

### 6.4 qt

当前状态：

- 仅保留安装包 `qt-creator-opensource-src-4.15.2.tar.gz`
- 未接入配置、未接入安装流程

原因：

- QT 当前不是简单安装包，而是源码编译场景
- 后续需要单独设计编译依赖、构建过程、安装路径和校验方式

## 7. 如何新增一个软件

假设后续要新增 `xxx` 软件，建议按下面步骤处理。

### 第一步：补安装包

将安装包放到：

```text
packages/xxx-installer.xxx
```

要求：

- 文件名尽量固定、稳定、可读
- 后续脚本直接按固定文件名引用

### 第二步：在 .internal/installers.sh 中新增安装函数

例如：

```bash
gc_install_xxx() {
  local package_file="${GC_PACKAGES_DIR}/xxx-installer.xxx"

  gc_require_file "${package_file}"

  if [[ "${GC_DRY_RUN}" == "1" ]]; then
    gc_log_info "dry-run: 将安装 xxx"
    return 0
  fi

  # 具体安装逻辑
}
```

### 第三步：接入调度入口

在 `gc_run_selected_installers` 的 `case` 中增加：

```bash
xxx) gc_install_xxx ;;
```

### 第四步：更新支持的软件列表

在 `.internal/common.sh` 的 `GC_SUPPORTED_SOFTWARES` 中增加：

```bash
GC_SUPPORTED_SOFTWARES=("runtime" "chromium" "sunlogin" "xxx")
```

### 第五步：补充 customer.conf 注释

如果新软件需要参数，补充到：

- `customer.conf`
- `gc_load_config`

保持“客户只改一个配置文件”的原则。

### 第六步：更新文档

至少同步更新：

- `安装说明.md`
- `README.md`

## 8. 配置约定

### 8.1 SOFTWARES

这是最核心的控制项，决定：

- 安装哪些软件
- 安装顺序是什么

示例：

```bash
SOFTWARES=("runtime")
SOFTWARES=("chromium" "sunlogin")
SOFTWARES=()
```

### 8.2 REBOOT_POLICY

支持：

- `prompt`
- `always`
- `never`

建议：

- 开发调试时优先用 `prompt`
- 无人值守交付时可考虑 `always`
- 如果要连装多轮并由现场统一操作，可用 `never`

### 8.3 密码类参数

当前只有：

- `CHROMIUM_PASSWORD`

原则：

- 配置中可留空
- 留空时运行时交互输入
- 不建议把客户正式密码长期写进版本库

## 9. 日志和临时目录

### 9.1 日志

当前日志目录固定为：

```text
logs/
```

日志文件示例：

```text
logs/install-20260408_143000.log
```

设计考虑：

- 日志不暴露给客户主视角
- 但保留在交付目录中，方便现场排障

### 9.2 临时目录

运行时会使用：

```text
/tmp/gc-delivery-bundle
```

其中主要存放：

- 解压后的 runtime 临时文件
- 解压后的 chromium 临时 RPM

## 10. 打包交付建议

面向客户打包时，建议只交付以下内容：

- `install.sh`
- `customer.conf`
- `安装说明.md`
- `packages/`
- `.internal/`

不要交付：

- `.git/`
- 本地 IDE 配置
- 临时日志
- 开发测试文件

如果从当前仓库目录直接压缩，请先确认：

- 不包含 `.git`
- 不包含 `logs/`
- 不包含无关测试文件

## 11. 验证方法

### 11.1 语法检查

在具备 bash 的环境下执行：

```bash
bash -n install.sh .internal/common.sh .internal/installers.sh
```

### 11.2 帮助检查

```bash
bash install.sh --help
```

### 11.3 预演检查

在目标 Linux 设备上执行：

```bash
bash install.sh --dry-run
```

重点关注：

- 配置文件能否正常读取
- 软件 ID 是否识别正确
- 安装包是否都存在
- 基础依赖检查是否正常
- 重启提示是否符合预期

### 11.4 单软件验证

通过修改 `customer.conf` 中的 `SOFTWARES`，分别验证：

- 仅 runtime
- 仅 chromium
- 仅 sunlogin
- runtime + chromium
- chromium + sunlogin

## 12. 已知限制

### 12.1 当前中文文件在某些 Windows 终端里可能乱码

这是终端编码显示问题，不代表文件内容本身错误。建议开发时优先使用：

- VS Code
- Notepad++
- 支持 UTF-8 的终端或编辑器

### 12.2 runtime 依赖外部包内脚本行为

当前对 `install_runtime.zip` 中脚本的调用方式是基于现有版本实现的。

如果包内脚本更新，重点回归：

- 安装路径参数是否仍然有效
- 输入 `b` 的 EtherCAT 构建流程是否仍然成立
- 是否仍可通过当前方式抑制即时重启

### 12.3 当前尚未实现更严格的包版本校验

目前主要依赖固定文件名和 RPM 查询，不做更复杂的版本治理。

如果后续版本管理变复杂，可以考虑增加：

- 包版本号校验
- sha256 校验
- 交付清单文件

## 13. 后续建议

后续如果继续迭代，建议优先考虑以下方向：

1. 修复并统一脚本文件编码，确保中文在目标环境下显示稳定。
2. 增加“打包发布脚本”，自动生成一份干净的客户交付目录。
3. 为新增软件建立统一模板，避免安装函数风格分散。
4. 单独设计 QT 安装方案，不要直接塞进当前简单安装流。

## 14. 维护原则总结

维护这个项目时，优先遵循下面几条：

1. 客户入口永远保持只有一个：`install.sh`
2. 客户配置尽量只保留一个：`customer.conf`
3. 对客户隐藏内部实现细节，但内部仍保留最少必要模块化
4. 所有客户通用逻辑进 `common.sh`
5. 软件特有逻辑进 `installers.sh`
6. 文档分层：
   - 客户看 `安装说明.md`
   - 开发看 `README.md`
