# AngelaMihomo 开发与回归验证

本仓库是 AngelaMihomo（Flutter / Go Mihomo 客户端），不是服务端或网页应用。
先在独立分支开发；以下命令只构建和测试，不执行发布、签名或生产部署。

## 环境与初始化

- Flutter 3.47.7（与仓库工作流一致，包含 Dart 3.13.5）。
- Go：本次使用 1.25.1，Mihomo 源码随仓库保存在 `core/Clash.Meta`，由 `core/go.mod` 的本地 replace 引用。
- Rust / Cargo：本次使用 rustc 1.99.1，供 Code Forge 原生编辑器使用。
- Linux 桌面编译需要 C/C++ 工具链及 GTK、托盘和快捷键开发库。

```sh
flutter pub get
cargo build --manifest-path plugins/code_forge/rust/Cargo.toml --release
```

Code Forge 的 Flutter 测试需要先编译 Rust 动态库。缺少动态库时，编辑器测试报错并不等于 Dart 实现有问题。
本地工具链的 `flutter`、`dart`、`go`、`cargo` 必须在 `PATH` 中。

## 回归验证

在仓库根目录执行：

```sh
flutter analyze --no-pub
flutter test --no-pub --concurrency=1 --reporter expanded
cargo test --manifest-path plugins/code_forge/rust/Cargo.toml
(cd core && go test ./... -count=1)
(cd core && go test -race ./... -count=1)
(cd core && go vet ./...)
```

链式代理专项：

```sh
(cd core && go test -run TestApplyPatchChain -v -count=1)
```

该组测试直接使用随项目提供的 Mihomo 配置解析器，覆盖内联节点、订阅节点及两者混合、原有 provider override 保留、名称转义和碰撞、缺失节点拒绝回落。
其中 `TestApplyPatchChainProviderConnect` 在回环地址启动入口代理、出口代理与 HTTP 目标，验证请求确实依次经过两个 CONNECT 代理；不需要真实订阅、账号或外部代理服务。

## Linux 本地构建

Debian / Ubuntu 依赖示例：

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libayatana-appindicator3-dev libkeybinder-3.0-dev
dart setup.dart linux --arch amd64 --out core
flutter build linux --release --no-pub
```

`setup.dart` 会联网下载规则与 Dashboard 资源。桌面 bundle 位于 `build/linux/x64/release/bundle/`；启动它而不是中间编译目录中的可执行文件。本次 Linux 核心使用 GOAMD64=v3（需要对应的 x86-64-v3 指令集）；旧 CPU 使用 `--compatible` 构建核心。
测试通过不代表 Windows、macOS、Android、签名安装包、系统 TUN 权限或真实供应商网络均已验证；这些需要对应平台的构建与运行环境。

## 此次修复的边界

- 链式代理不再生成已被当前 Mihomo 移除的 `relay` 类型，改为 `dialer-proxy`，并处理订阅 provider 节点。
- 缺失 provider 节点时的辅助选择组使用 `REJECT`，不静默回落直连；不会修改自动测速组的选择列表。
- 系统没有可用 Downloads 目录时，文件选择器改用应用数据目录，不再留下未完成的目录 Future。
- 矮行内放大字体的 chip 保留自然文字高度，避免错误淡出；沿用现有明暗主题与密度的像素比较测试。
- 桌面进程图标测试等待真实文件 / isolate 任务完成，不再靠虚拟时钟帧数猜测完成时间。

首次正式 Android 签名的安全配置见 [中文操作说明](docs/android-first-release.zh-CN.md)。正式版本禁止缺少密钥时退回 debug 签名；密钥由项目所有者在自己电脑生成、备份和配置。

## Fork 更新检查回归

```sh
flutter test test/common/version_test.dart test/common/release_updates_test.dart
```

- 更新来源固定为本 fork `dukangalex/AngelaMihomo`，不向上游安装包跳转。
- 先读取 GitHub 最新正式 Release 的元信息与实际资产；API 受限时回退到同仓库的正式版本跳转地址。请求有连接、发送和接收超时，不把预发布当成正式版。
- 下载按钮只选择对应版本、对应平台后缀的唯一实际资产（现行 `AngelaMihomo-` 名称（兼容旧版 `Bettbox-`、`AngelaBettbox-` 名称））。没有匹配、匹配不唯一、API 回退或只有 debug-preview 时打开该版本页面，不猜测下载地址或换架构。
- 同一 fork 修订号的正式版本高于其预览版本：`chain.2 > chain.2-pre.1`；修订号和预览序号继续按数字比较。
- 测试使用注入的 HTTP adapter，不访问真实订阅、不启动 TUN，也不创建 Release。公开正式 Release 不存在时，不应误报上游有更新。

## 备份恢复的数据保留回归

```sh
flutter test --no-pub test/common/archive_test.dart --reporter expanded
```

- 恢复前检查配置与文件的实际长度和 ZIP CRC（存在时），并拒绝越界路径、重复路径和符号链接。
- 配置元信息只认根目录 `config.json`；订阅 provider 的 JSON 缓存与 YAML 一样参与恢复。
- 合并恢复先复制当前 profiles，再写入备份内容；覆盖恢复先写入完整替代目录。全部文件准备成功后，才用同一文件系统上的目录重命名安装，安装失败时尝试还原旧目录。不再提前清空现有订阅。
- 暂存需要额外磁盘空间。测试覆盖中途文件/目录冲突、损坏 CRC、合并/覆盖、中文 UTF-8 及已有符号链接，不启用真实订阅或系统代理。
- 文件暂存本身仅负责进程内安装失败回滚；完整备份导入现在另用下述重启恢复日志保护。旧版本遗留的 `.profile-restore-*/previous` 不会自动清除，手工处理前应先保留副本并核对内容。

## 备份导入被强杀后的重启恢复

```sh
flutter test --no-pub test/common/backup_recovery_test.dart test/common/preferences_backup_recovery_test.dart --reporter expanded
```

- 在写入脚本、profiles 或配置前，将当前 `profiles/`、`scripts/`、`config.json` 和配置的 shared-preferences 镜像保存在同一数据目录的私有恢复日志 `.backup-recovery`。拒绝符号链接，快照未完成不会执行导入；需要额外磁盘空间。
- 只有脚本处理、订阅安装和配置保存成功后才以原子重命名公布提交标记；核心运行时配置重载在持久化提交后进行，重载报错不撤销已保存的导入。
- 启动读取配置前检查日志。未提交则恢复旧文件及旧配置镜像，再继续启动；已提交只清理日志，不回退新数据。恢复过程再次被强杀可在下次启动重试，因为原快照不被移动或覆盖。
- 导入失败会保留日志并拒绝继续导入，需要重启恢复。日志损坏、权限/空间不足或恢复镜像失败会停止配置加载，避免悄悄以混合状态启动；不要直接删除日志。此路径不承诺失败后的当前进程内状态完整回滚。
- Linux 隔离子进程在脚本写入、profiles 重命名空窗、安装后、偏好镜像写入、半写配置、配置保存完成及恢复重放期间被 SIGKILL，覆盖真实缺陷及恢复结果。提交标记到清理之间的状态另用故障夹具验证；启动测试调用实际 `Preferences.getConfig`，验证文件和偏好回退顺序。
- `flush: true` 用于快照、配置回滚和提交标记，但 Dart 目录重命名未做目录 fsync。SIGKILL 不是断电测试，不保证突然断电、文件系统损坏或硬件故障的一致性；Android/Windows/macOS 真机未验收。它也不是一般存储系统的多进程事务或所有后台写入的隔离方案。
- 中断可能留下 `.backup-snapshot-*`、`.backup-recovery.retired-*` 或旧的 profile 临时目录。为避免误删唯一旧副本，不在启动时自动扫除；确认没有待恢复日志、完成恢复并备份之后再人工检查。

## PR 自动回归（无签名、无发布）

`.github/workflows/regression.yml` 对发往 `main` 和 `release/**` 的 PR 自动运行两项独立检查，也保留手动运行入口。标准公开仓库 Linux runner、只读 `contents` 权限、checkout 不保留凭据；不使用仓库 secrets、`pull_request_target`、发布或签名流程，也不更改分支保护。第三方 actions 固定到提交 SHA，PR 检查不保存或恢复跨 PR 缓存。

本地与 CI 使用同一入口（先将上述工具链加入 `PATH`）：

```sh
bash tools/check-regressions.sh          # 两组全部运行
bash tools/check-regressions.sh flutter  # 锁定依赖、Rust 测试/动态库、analyze、全套 Flutter、Python 夹具
bash tools/check-regressions.sh core     # Go 普通/race/vet/with_gvisor
```

- Flutter 3.47.7、Rust 1.99.1、Go 1.25.1 与已验证工具链一致；更新工具链应另作独立变更并实际验证。锁文件不允许在检查中静默更新。
- 全套 Flutter 自动包含配置导入、更新来源/版本比较、备份预检、SIGKILL 后重启恢复和偏好镜像回滚；先构建 Code Forge Rust release 动态库，再运行编辑器测试，不跳过原生依赖测试。
- Go 组覆盖链式配置与回环双 CONNECT 测试、竞态检测、静态检查及 `with_gvisor` 构建标签。Python 组包含签名工具的假 `gh` 夹具（不会上传 secret）与回归入口的失败传播/分组测试。
- 任一步失败会使该组失败；PR 更新取消同一 PR 的旧检查。无路径过滤，因此只改工作流或文档也不会留下未触发的检查。
- 本检查不是打包或跨平台验收，不启用系统代理/TUN，不使用真实订阅。保留原有平台限定跳过；Linux 强杀回归不等于真实断电可靠性。分支保护未启用强制检查时，绿灯仍需合并者核对，不把工作流存在等同于合并门禁。
