# AngelaBettbox 开发与回归验证

本仓库是 Bettbox 的 Flutter / Go Mihomo 客户端分支，不是服务端或网页应用。
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

- 更新来源固定为本 fork `dukangalex/AngelaBettbox`，不向上游安装包跳转。
- 先读取 GitHub 最新正式 Release 的元信息与实际资产；API 受限时回退到同仓库的正式版本跳转地址。请求有连接、发送和接收超时，不把预发布当成正式版。
- 下载按钮只选择对应版本、对应平台后缀的唯一实际资产（兼容现有 `Bettbox-` 及 `AngelaBettbox-` 名称）。没有匹配、匹配不唯一、API 回退或只有 debug-preview 时打开该版本页面，不猜测下载地址或换架构。
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
- 该保护仅是进程内的文件恢复事务，不是 profiles 与应用配置的跨文件断电事务，也未验证 Android/Windows/macOS 真机恢复。若进程在重命名之间被强行终止，旧目录可能保留在应用数据目录 `.profile-restore-*/previous`；不要把它当作垃圾直接清除，先在应用停止时保留副本并核对内容。
