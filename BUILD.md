# 构建与自签安装

> 目标：个人自签安装，不使用 TestFlight。  
> 需要 macOS + Xcode 16+。

## 1. 生成工程

```bash
brew install xcodegen
cd LxPlayer
xcodegen generate
open LxPlayer.xcodeproj
```

如果 XcodeGen 未安装，也可以手动把 `App/Core/Features/Resources` 拖进一个新的 iOS App 工程；但推荐用 `project.yml`，后续加文件不用手改 `.xcodeproj`。

`Resources/user-api-preload.js` 来自 lx-music-mobile（Apache-2.0），是自定义音源脚本的唯一 JS 运行时垫片；不需要再生成或打包 Ceru 宿主。

## 2. 设置签名

在 Xcode：

1. 选中 `LxPlayer` target → `Signing & Capabilities`。
2. 勾选 `Automatically manage signing`。
3. Team 选你的 Apple ID（免费账号会生成 7 天有效的开发证书）。
4. Bundle Identifier 改成你自己的，例如 `com.yourname.lxplayer`。
5. 连接 iPhone，选择真机运行。

免费 Apple ID 的限制：

- 证书 7 天有效，到期需要用 AltStore/SideStore 或 Xcode 重新签名。
- 不能使用需要付费账号的 capability（CarPlay 等）。

付费个人开发者证书：1 年有效，仍然不需要 TestFlight。

## 3. 安装到 iPhone

任选其一：

- Xcode 直接 Run 到已信任的 iPhone。
- 导出 Release `.ipa` 后，用 AltStore/SideStore 自签安装。
- 用个人开发者证书 + `codesign`/`ios-deploy` 安装。

首次运行如果提示“未受信任的开发者”，去 `设置 → 通用 → VPN与设备管理` 信任证书。

## 4. 首次使用

1. 搜索/发现页可直接使用，内置五平台接口，不需要导入任何插件。
2. 设置 → 洛雪音源 → 导入你的音源 `.js`，选中它；点“检测音源脚本”确认支持平台。
3. 设置 → 洛雪数据同步 → 输入桌面版“服务端模式”的地址和连接码 → 连接并同步。
4. 搜索页搜索歌曲并播放；或从音乐库播放同步来的歌单。

## 5. 当前代码状态

- App shell、搜索/发现/歌单/排行榜 UI、音乐库 UI、播放器、设置页已落。
- 搜索/歌单/排行榜由 `Core/Music` 的 Swift 客户端直接请求平台接口，参考 `lx-music-mobile/src/utils/musicSdk`。
- 自定义音源由 `LXSourceRuntime` 用 JavaScriptCore 执行官方 `user-api-preload.js`；不再依赖 Ceru 插件或 `ceru-host.js`。
- 同步客户端已实现鉴权、WebSocket、message2call、gzip、全量/部分增量动作、首次同步模式选择和本地库整库上报；尚未与真实桌面版做真机联调。
- 本地库当前用 JSON 文件存储（`Application Support/LxPlayer/library.json`），后续迁移 SQLite/GRDB。
- 不建议直接提交 App Store。

## 6. 常见问题

### `user-api-preload.js` 找不到

确认 `Resources/user-api-preload.js` 被加入 target 的 Copy Bundle Resources；`project.yml` 已包含 `Resources` 目录。重新运行 `xcodegen generate`。

### 音源导入失败

- 确认脚本开头有 `@name` 等头部注释。
- 确认文件是 UTF-8、大小不超过 2MB。
- 当前运行时按洛雪移动版 `user-api-preload.js` v2.0.0 接口实现，支持 `musicUrl`、`lyric`、`pic` 能力声明。

### 音源能导入但播放失败

- 在设置里点“检测音源脚本”，确认脚本声明了当前平台和音质。
- 音源必须实现 `lx.on(lx.EVENT_NAMES.request, ...)` 并返回 `musicUrl`。
- 查看播放器错误信息和 Xcode 控制台 `[LXSource]` 日志。

### 搜索/歌单/排行榜失败

- 内置接口直接请求平台公开 API，可能因平台改版、地区或网络而失效。
- 先切换平台或稍后重试；如果所有平台都失败，检查网络/代理。
- 酷狗歌单、QQ 排行榜详情目前仍是迁移中的接口，会显示“暂不支持”。

### 同步连接失败

- 桌面版需开启「服务端模式」，手机与电脑在同一局域网。
- iOS 首次会询问本地网络权限。
- 公网必须用 HTTPS/WSS 反向代理，不能直接暴露 23332。

## 7. 编译 IPA

### 7.1 先改 Bundle ID / Team

编辑 `project.yml`（推荐，重新生成工程不会丢）：

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: "你的 Team ID"
targets:
  LxPlayer:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yourname.lxplayer
```

Team ID 可以在 Xcode → Settings → Accounts 里看，也可以：

```bash
security find-identity -v -p codesigning
```

改完重新生成：

```bash
xcodegen generate
```

### 7.2 方式 A：Xcode 直接装到 iPhone（最简单，不生成 IPA）

1. 连接 iPhone，信任电脑。
2. Xcode 选择 `LxPlayer` scheme 和你的 iPhone。
3. `Signing & Capabilities` 勾选 `Automatically manage signing`，选 Team。
4. 按 `⌘R`。
5. 首次运行去 iPhone `设置 → 通用 → VPN与设备管理` 信任开发者证书。

这种方式不需要 IPA，但免费 Apple ID 的签名 7 天后过期。

### 7.3 方式 B：Archive 导出已签名 IPA

Xcode 菜单：

```text
Product → Archive
→ Organizer → Distribute App
→ Development → Export
```

导出目录里就是 `LxPlayer.ipa`。

命令行等价：

```bash
xcodebuild \
  -project LxPlayer.xcodeproj \
  -scheme LxPlayer \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/LxPlayer.xcarchive \
  archive \
  -allowProvisioningUpdates
```

新建 `ExportOptions.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
    <key>teamID</key>
    <string>你的 Team ID</string>
</dict>
</plist>
```

导出：

```bash
xcodebuild \
  -exportArchive \
  -archivePath build/LxPlayer.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates
```

### 7.4 方式 C：生成未签名 IPA，用 AltStore/SideStore 签名

如果免费账号导出 IPA 报错，先生成未签名包：

```bash
xcodebuild \
  -project LxPlayer.xcodeproj \
  -scheme LxPlayer \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build
```

找到产物并打包：

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*Build/Products/Release-iphoneos/LxPlayer.app' | head -1)
mkdir -p build/Payload
cp -R "$APP" build/Payload/
cd build
zip -r LxPlayer-unsigned.ipa Payload
```

然后用 AltStore/SideStore 打开 `LxPlayer-unsigned.ipa`，用你的 Apple ID 签名安装。免费账号 7 天有效，需要 AltStore 定期刷新。

### 7.5 检查资源

编译前确认：

- `Resources/user-api-preload.js` 在 target 的 `Copy Bundle Resources` 里。
- `Info.plist` 的 `UIBackgroundModes` 包含 `audio`。
- 真机系统版本 ≥ iOS 16。

如果 App 能启动但导入音源后报“缺少 user-api-preload.js”，就是资源没进 bundle。

## 8. 用 GitHub Actions 编译 IPA（不需要 Mac）

仓库里已带 `.github/workflows/build-ipa.yml`。它会在 GitHub 的 macOS runner 上生成工程、编译并上传**未签名 IPA**。

### 8.1 推到 GitHub

```bash
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/你的用户名/LxPlayer.git
git push -u origin main
```

### 8.2 运行

GitHub 仓库 → `Actions` → `Build unsigned IPA` → `Run workflow`。

首次运行会自动安装 XcodeGen、执行 `xcodegen generate`，然后编译。

### 8.3 下载

运行完成后进入该次 run，页面底部 `Artifacts` 下载：

```text
LxPlayer-unsigned-ipa
```

解压后得到 `LxPlayer-unsigned.ipa`。

### 8.4 安装

用 AltStore / SideStore 打开这个 IPA，登录你的 Apple ID 签名安装。免费账号 7 天有效，需要 AltStore 定期刷新。

### 8.5 想要已签名 IPA

GitHub runner 没有你的 Apple 证书，默认只能产出未签名包。要产出已签名 IPA，需要在仓库 Secrets 里配置：

- `BUILD_CERTIFICATE_BASE64`
- `P12_PASSWORD`
- `PROVISIONING_PROFILE_BASE64`
- `TEAM_ID`
- `BUNDLE_ID`

然后在 workflow 里导入证书、安装 profile，并用 `xcodebuild -exportArchive` 导出。个人使用不建议折腾，未签名 IPA + AltStore 更简单。

> 注意：macOS runner 消耗的 GitHub Actions 分钟数按 10 倍计算。私有仓库免费额度有限，公开仓库一般够用。
