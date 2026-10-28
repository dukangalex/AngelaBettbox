# Angela Mihomo 正式版本发布 / Stable Release

> **Angela Mihomo** is a customized build based on [appshubcc/Bettbox](https://github.com/appshubcc/Bettbox) (GPL-3.0),
> with per-profile chain proxy, leak protection and failover enhancements.
> 本版本基于上游 Bettbox 定制，加入按配置文件链式代理、泄漏防护与故障转移等功能。

### ✨ 本版定制 / What's new in this build

- **按配置文件链式代理 / Per-profile chain proxy**：每个订阅配置可独立设置链式代理
  (Chain proxy can be configured independently for each profile)
- **泄漏防护 / Leak protection**：防 DNS 泄漏、严格路由策略
  (DNS leak protection and strict routing policy)
- **故障转移 / Failover**：死节点双地址确认、只修复承载流量的分组、故障节点不回落直连
  (Dead-node confirmation, heal only the group carrying traffic, never fall back to direct)
- **导入增强 / Import**：订阅导入归一化转换
  (Subscription import normalization)

### ✍️ 签名说明 / Signing

- Windows 安装包暂未签名，安装时 Windows SmartScreen 会提示，请点击"更多信息" → "仍要运行"。
  (Windows installer is currently unsigned. Click "More info" → "Run anyway" on SmartScreen.)
- 安装包附带 SHA-256 校验文件，请核对后安装。

---
### ⬇️ Download / 下载链接

**Note: For desktop CPUs from 2012 or earlier, please download the Compatible version**
<br>**注意：桌面端2012年同期及之前的CPU，需要使用Compatible兼容版本**

**常用设备平台，android-arm64-v8a, windows-amd64, macos-arm64**

---

<div align="left">

| **OS/ 系统** | **Requirements / 版本要求** | **Direct Links / 点击直链下载** |
|:---:|:---|:---|
| <img src="https://cdn.jsdelivr.net/gh/devicons/devicon/icons/apple/apple-original.svg" alt="macOS" width="28"/> | macOS 12.0+ | <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-macos-arm64.dmg"><img src="https://img.shields.io/badge/DMG-Apple%20Silicon-000000?logo=apple&logoColor=white&style=flat-square&labelColor=222222"></a> <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-macos-amd64.dmg"><img src="https://img.shields.io/badge/DMG-Intel%20x64-00A9E0?logo=apple&logoColor=white&style=flat-square&labelColor=222222"></a> |
| <img src="https://cdn.jsdelivr.net/gh/devicons/devicon/icons/android/android-original.svg" alt="Android" width="28"/> | Android 8.0+<br>*(Compatible with Android TV)* |<a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-android-arm64-v8a.apk"><img src="https://img.shields.io/badge/APK-ARMv8-32AF6A?logo=android&logoColor=white&style=flat-square&labelColor=222222"></a> <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-android-x86_64.apk"><img src="https://img.shields.io/badge/APK-x64-32AF6A?logo=android&logoColor=white&style=flat-square&labelColor=222222"></a><br><a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-android-armeabi-v7a.apk"><img src="https://img.shields.io/badge/APK-ARMv7-32AF6A?logo=android&logoColor=white&style=flat-square&labelColor=222222"></a> <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-android-universal.apk"><img src="https://img.shields.io/badge/APK-Universal-32AF6A?logo=android&logoColor=white&style=flat-square&labelColor=222222"></a> |
| <img src="https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/windows11/windows11-original.svg" alt="Windows" width="28"/> | Windows 8.1+<br>*(Compatible for Older CPU)* | <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-windows-amd64-setup.exe"><img src="https://img.shields.io/badge/Setup-x64-0078D7?logo=windows&logoColor=white&style=flat-square&labelColor=222222"></a> <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-windows-arm64-setup.exe"><img src="https://img.shields.io/badge/Setup-ARM64-0078D7?logo=windows&logoColor=white&style=flat-square&labelColor=222222"></a><br><a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-windows-amd64-compatible-setup.exe"><img src="https://img.shields.io/badge/Setup-Compatible%20x64-555555?logo=windows&logoColor=white&style=flat-square&labelColor=222222"></a> |
| <img src="https://cdn.jsdelivr.net/gh/devicons/devicon/icons/linux/linux-original.svg" alt="Linux" width="28"/> | Linux Kernel 5.4+<br>*(Compatible for Older CPU)* | <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-linux-amd64.AppImage"><img src="https://img.shields.io/badge/AppImage-x64-f84e29?logo=linux&logoColor=white&style=flat-square&labelColor=222222"></a> <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-linux-amd64.deb"><img src="https://img.shields.io/badge/DEB-x64-A81D33?logo=debian&logoColor=white&style=flat-square&labelColor=222222"></a><br><a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-linux-arm64.deb"><img src="https://img.shields.io/badge/DEB-ARM64-A81D33?logo=debian&logoColor=white&style=flat-square&labelColor=222222"> <a href="https://github.com/dukangalex/AngelaMihomo/releases/download/vVERSION/Bettbox-VERSION-linux-amd64-compatible.deb"><img src="https://img.shields.io/badge/DEB-Compatible%20x64-555555?logo=debian&logoColor=white&style=flat-square&labelColor=222222"></a> |
---
</div>

### 🐛 Feedback / 问题反馈

> **Note / 提示：**
> Detailed and well-structured issues will be prioritized(logs / reproduction steps)<br>
> 书写认真、信息完整（包含必要的复现步骤和日志）的 issues 会被优先处理和对待

**Bug Report / 提交故障**: [Click Here / 点击这里](https://github.com/dukangalex/AngelaMihomo/issues/new?template=bug_report.yml)
**Feature Request / 需求建议**: [Click Here / 点击这里](https://github.com/dukangalex/AngelaMihomo/issues/new?template=feature_request.yml)

<br>
