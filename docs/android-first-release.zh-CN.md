# Android 首次正式签名

这是首次正式发布，无需寻找历史正式 APK 或原签名。现有预览 APK 使用 Android Debug 证书，不能当作正式版；若已安装该预览包，正式签名不同，通常需先备份应用内配置，再卸载预览包后安装正式包（卸载可能清除数据）。包名保持 `com.appshub.bettbox` 不变。正式发布后请永久保留同一签名密钥，以支持后续覆盖升级。

## 只需在自己的电脑完成一次

要求：JDK 17（提供 keytool）、Python 3、GitHub CLI（gh），并以仓库管理员身份 `gh auth login`。以下操作在你的电脑执行，不在聊天中输入密钥或密码，不把 keystore 提交到仓库。

1. 在仓库目录之外建立仅自己可访问的私人目录（macOS/Linux 可先执行 `umask 077`，Windows 请限制目录访问权限）。在此目录运行下列命令；keytool 会交互询问密码和证书信息，密码不会出现在命令历史中：

   ```sh
   keytool -genkeypair -v -storetype PKCS12 -keystore bettbox-release.p12 -alias bettbox-release -keyalg RSA -keysize 3072 -validity 10000
   ```

   请使用强密码。PKCS12 的密钥密码与仓库密码保持一致。不要覆盖已有密钥文件；若已生成密钥，请直接使用它而不是再次生成。

2. 在配置 GitHub 之前，将 `.p12` 文件和密码分别存入可靠的加密备份/密码管理器，至少保留一份离线备份。GitHub Actions secret 不是可恢复的密钥备份。丢失密钥会影响未来更新（独立分发 APK 无法仅凭现有 APK 重新取得密钥）。
3. 从项目仓库运行辅助脚本（把路径替换为自己电脑上真实路径）：

   ```sh
   python3 tools/configure-android-signing.py /private/path/bettbox-release.p12
   ```

   脚本不会生成密钥；会隐蔽询问密码、检查 keystore/alias，并在你输入 `UPLOAD` 后通过当前 `gh` 登录向 `dukangalex/AngelaMihomo` 配置四项 Actions secrets：`KEYSTORE`（整个文件的 base64）、`KEY_ALIAS`、`STORE_PASSWORD`、`KEY_PASSWORD`。不会将秘密写入脚本或输出到终端。若中途失败，部分 secret 可能已保存；使用同一密钥重新运行即可补齐，不要换密钥。

   也可以自行到仓库 Settings → Secrets and variables → Actions → New repository secret 配置同名四项。不要把 base64 或密码粘贴进聊天、Issue 或 PR。辅助脚本可避免复制 base64 和平台命令差异。
4. 查看公开证书指纹（不是私钥）：

   ```sh
   keytool -list -v -keystore bettbox-release.p12 -alias bettbox-release
   ```

   记录证书 SHA-256 指纹即可；不要发送 `.p12` 或密码。

## 配置之后由开发流程完成

维护者可以核查 secret 名称是否齐备（不能读取其值），构建正式 APK，使用 apksigner 核对实际证书和包元信息，完成回归及公开下载校验，再使用新稳定版本号/tag 发布。没有上述正式签名时，稳定构建会明确失败，不会自动用 debug 签名冒充正式版。独立 APK 手动流程也默认禁止 debug fallback，只有显式选择 debug_preview 时才允许测试预览。

正式版候选使用高于现有预览的 versionCode，发布前检查最终 APK 的 versionName/versionCode、包名、minSdk 和证书，并明确实机测试范围；不会仅把现有 prerelease 改为 stable。Windows/macOS 的代码签名不属于这份 Android 密钥配置。
