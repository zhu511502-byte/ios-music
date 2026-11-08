# 04 · 实施计划、工程结构与测试

> 前提：你已有 Mac + Xcode；目标是个人侧载（自签），不按 App Store 上架设计。

## 1. 已确认的产品决策

| 项 | 决策 |
| --- | --- |
| 客户端 | iOS 原生 SwiftUI |
| 最低版本 | iOS 16（建议；可按你的设备调整） |
| 音频 | AVPlayer + AVAudioSession |
| JS 运行时 | JavaScriptCore（仅洛雪音源；官方 preload） |
| 元数据 | `Core/Music` 原生平台客户端 |
| 同步 | 原生实现洛雪 v4 协议 |
| 分发 | 个人侧载（自签） |
| 搜索 | 内置五平台原生接口 |

## 2. 工程结构

建议用 **XcodeGen** 管理工程，避免手改 `.xcodeproj`：

```text
LxPlayer/
├─ project.yml
├─ README.md
├─ docs/
├─ App/
│  ├─ LxPlayerApp.swift
│  ├─ AppDelegate.swift
│  ├─ Info.plist
├─ Features/
│  ├─ Search/
│  ├─ Playlists/
│  ├─ Rankings/
│  ├─ Library/
│  ├─ Player/
│  ├─ Lyrics/
│  └─ Settings/
├─ Core/
│  ├─ Models/
│  │  ├─ Track.swift
│  │  ├─ Playlist.swift
│  │  ├─ LXMusicInfo.swift
│  │  └─ SyncModels.swift
│  ├─ Library/
│  │  ├─ LibraryStore.swift
│  │  ├─ LibraryDatabase.swift
│  │  └─ TrackMapper.swift
│  ├─ Player/
│  │  ├─ PlaybackCoordinator.swift
│  │  ├─ PlaybackQueue.swift
│  │  ├─ NowPlayingCenter.swift
│  │  └─ AudioSessionController.swift
│  ├─ Music/
│  │  ├─ NativeMusicAPI.swift
│  │  ├─ NativeSearchClients.swift
│  │  ├─ NativeDiscoveryClients.swift
│  │  ├─ MusicCrypto.swift
│  │  └─ OnlineMusicModels.swift
│  ├─ JS/
│  │  ├─ JSError.swift
│  │  └─ LXSourceRuntime.swift
│  ├─ Sync/
│  │  ├─ SyncClient.swift
│  │  ├─ SyncAuth.swift
│  │  ├─ Message2Call.swift
│  │  ├─ SyncCrypto.swift
│  │  ├─ Gzip.swift
│  │  └─ SyncModels.swift
│  └─ Storage/
│     ├─ Database.swift
│     ├─ Migrations.swift
│     └─ KeychainStore.swift
├─ Resources/
│  ├─ user-api-preload.js   // lx-music-mobile Apache-2.0
│  └─ Assets.xcassets
└─ Tests/
   ├─ SyncProtocolTests/
   ├─ TrackMapperTests/
   ├─ Message2CallTests/
   └─ GzipTests/
```

### 2.1 依赖

- **GRDB.swift**（SQLite；MIT）。
- 可选：`swift-collections`（不需要，系统足够）。
- 不再需要 esbuild 宿主包；`Resources/user-api-preload.js` 直接使用官方文件。

### 2.2 XcodeGen `project.yml` 要点

- `deploymentTarget: "16.0"`
- `INFOPLIST_FILE: App/Info.plist`
- `UIBackgroundModes`: `audio`
- `NSAppTransportSecurity`: 个人构建允许任意加载
- `NSLocalNetworkUsageDescription`
- `SWIFT_VERSION: 5.10`（或 Xcode 16 默认）
- 测试 target 使用 `XCTest`

## 3. 分阶段实施

### M0 · 协议与接口验证（已完成）

- 阅读洛雪移动版源码：`src/plugins/sync`、`src/core/init/userApi`、`src/utils/musicSdk`、`src/utils/index.ts`。
- Node 侧验证五平台搜索接口、QQ zzc、网易 eapi、咪咕签名、歌单/排行榜接口。
- Node 侧验证官方 `user-api-preload.js` + mock 音源可完成 `musicUrl`。
- 本地 `lx-music-sync-server` 2.1.2：鉴权、WebSocket、空库同步、非空库下发、gzip 消息通过。

**产出**：本目录 01–04 文档。

### M1 · 工程骨架

- XcodeGen 工程、App 入口、设计系统、Tab 导航。
- JSON 文件存储（MVP）；SQLite/GRDB schema + 迁移留到 M2。
- `Track`/`Playlist`/`MusicInfo` 模型。
- 设置页（空壳）。
- 本地音频文件导入 + AVPlayer 播放（先不接音源）。
- 后台音频/锁屏控制。

**验收**：

- 真机可安装启动。
- 导入本地 mp3 可播放；锁屏显示标题/封面；耳机暂停/播放。
- App 退到后台继续播放。

### M2 · 原生平台接口 + 搜索

- `NativeMusicAPI`：五平台搜索、歌单、排行榜。
- `MusicCrypto`：QQ zzc、网易 eapi、咪咕签名。
- `OnlineTrackRow` / `OnlinePlaylistRow` / `OnlineTrackListPage`。
- 搜索 UI：平台切换、加载/错误态。
- 发现 UI：歌单/排行榜。

**验收**：

- 五个平台至少各能返回一页搜索结果。
- 搜索「周杰伦」不崩溃；弱网 10 秒超时后显示重试。
- 点开歌单能看到歌曲列表；分页不重复。
- 歌词页显示时间轴歌词。

### M3 · LXSourceRuntime + 播放

- 导入音源 `.js`，解析元数据，展示平台/音质。
- `LXSourceRuntime` 加载官方 `user-api-preload.js`。
- `music.resolve` → `LXSourceRuntime.musicURL` 链路。
- `MusicInfo` 两种形状（meta / 顶层）兼容。
- 播放队列、下一首预解析、URL 缓存/失效重试。
- 音质选择。

**验收**：

- 导入一个真实洛雪音源，搜索一首歌并成功播放 320k。
- 换一首歌、切音质、切音源都能工作。
- 播放失败显示具体原因（未导入/无版权/URL 失效），不是笼统“失败”。
- 同一首歌从搜索结果和同步库进入播放都能解析。

### M4 · 洛雪同步

- `SyncAuth`：RSA 密钥对、SPKI、AES、MD5。
- `SyncClient`：WebSocket、message2call、gzip、心跳/重连。
- 列表全量同步 + 首次同步模式弹窗。
- 增量动作（12 种）双向处理。
- 不喜欢同步（可选）。
- 同步状态 UI、设备信息、断开/重连。

**验收**：

- 与桌面版服务端模式首次同步空库成功。
- 桌面端加歌 → iOS 增量出现；iOS 删歌 → 桌面端消失。
- 两个客户端同时在线时，变更能广播。
- 断网 30 秒后恢复，自动重连并完成同步。
- 10,000 首歌的列表能同步（重点测试 gzip）。

### M5 · 打磨

- 播放器全屏页/歌词滚动/队列管理。
- 封面缓存、列表性能、骨架屏。
- 错误诊断页：导出日志、查看插件/音源状态。
- 设置：音质、网络、缓存、备份/恢复。
- 安装包：Debug/Release、签名、AltStore/SideStore/自签说明。

## 4. 验收标准（整体）

### 4.1 功能

- [ ] 内置五平台搜索各能返回一页结果。
- [ ] 导入洛雪音源后能播放搜索结果。
- [ ] 同步洛雪歌单双向一致。
- [ ] 后台/锁屏/耳机控制正常。
- [ ] 冷启动不崩；音源加载失败可降级为“同步库播放器”。
- [ ] 断网/弱网有明确错误与重试。

### 4.2 兼容性

- [ ] 至少 3 个真实洛雪音源脚本通过。
- [ ] 桌面版 v2.4+ 服务端模式通过。
- [ ] 独立 `lx-music-sync-server` v2.1.2 通过。
- [ ] 中文/英文歌名、emoji、特殊符号同步不丢。
- [ ] `defaultList`/`loveList`/用户歌单/空列表/重复歌曲边界通过。

### 4.3 性能

- 音源首次加载 < 1.5 秒（iPhone 12 级别，JSC + 官方 preload）。
- 搜索首屏 < 2 秒（受平台接口影响）。
- 1,000 首列表滚动 60fps。
- 同步 10,000 首不 OOM，消息 gzip 正常。

## 5. 测试矩阵

| 类别 | 用例 |
| --- | --- |
| 同步鉴权 | 正确码、错误码、旧 key、服务端版本过低/过高、IP 被限 |
| 同步列表 | 空/空、空/非空、非空/空、非空/非空（6 种模式） |
| 增量动作 | 12 种 action 各一条，含重复添加/删除不存在歌曲 |
| 编码 | 中文、日文、emoji、引号、反斜杠、`</script>`、超长歌名 |
| 大列表 | 1k/5k/10k 首；gzip 收发；断点重连 |
| 音源 | 无 `inited`、抛异常、返回空 URL、返回 http、返回 2048+ URL、超时 |
| 音源 | 缺失 `inited`、语法错误、某个平台报错、断网 |
| 播放器 | 来电中断、拔耳机、蓝牙切换、后台 30 分钟、URL 过期 |
| 安装 | 新装/覆盖安装/升级迁移/删除重装 |

## 6. 构建与侧载

1. Mac 安装 Xcode 16+、XcodeGen。
2. `xcodegen generate`。
3. 打开 `LxPlayer.xcodeproj`，设置 Team/Bundle ID。
4. 真机运行；确认 `UIBackgroundModes`、本地网络权限。
5. Release Archive → 导出 `.ipa`。
6. 侧载：
   - AltStore/SideStore（免费 Apple ID，7 天签名）或
   - 个人开发者证书（1 年签名）。
   - 不依赖 TestFlight。
7. 音源通过“文件”App 导入，不打包进 IPA。

## 7. 需要你确认的事项

1. App 名称、Bundle ID、最低 iOS 版本。
2. 是否接受“搜索内置、播放需导入音源”的产品逻辑。
3. 是否需要在 M3 就做本地代理（影响需要 Referer 的音源）。
4. 是否需要同步「不喜欢」规则，还是第一版只同步歌单。
5. 是否要支持 iPad / CarPlay（CarPlay 需要 entitlement，个人侧载基本不可行）。

## 8. 下一步

如果你确认以上范围，我下一步会：

1. 生成 XcodeGen 工程骨架和 SwiftUI 导航。
2. 先落 `TrackMapper` + `Gzip` + `Message2Call` 三个可单测的核心模块。
3. 再做 `LXSourceRuntime` 最小闭环（加载官方 preload → `musicUrl`）。
4. 最后接同步 UI 和真机联调。
