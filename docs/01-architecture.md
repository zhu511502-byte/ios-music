# 01 · 技术方案与总体架构

> 目标：在 iOS 上做一个原生音乐播放器，兼容洛雪自定义音源和洛雪数据同步；搜索/歌单/排行榜由 Swift 原生客户端提供，自定义音源由系统 JavaScriptCore 执行官方 preload。

## 1. 目标与非目标

### 1.1 目标（MVP）

- 从文件或 http(s) 直链导入并管理洛雪 `.js` 自定义音源脚本。
- 搜索歌曲、浏览歌单/排行榜（内置五平台接口）。
- 用选中的洛雪音源解析播放地址并播放；播放器提供专辑封面、歌词、音量、播放模式和添加到歌单。
- 与洛雪桌面版/独立同步服务双向同步歌单；「不喜欢」规则待补。
- 后台播放、锁屏/控制中心、耳机线控、播放中断恢复。
- 本地音乐库、播放队列、最近播放、收藏。
- 个人侧载（自签）安装。

### 1.2 非目标（第一版不做）

- App Store 上架。
- 歌曲下载、批量导出、云盘。
- 洛雪桌面版的全部设置同步（同步协议只覆盖歌单和不喜欢规则）。
- 评论、MV、听歌识曲、社交、桌面歌词。
- 多用户账号体系。
- 版权内容的分发或绕过付费墙。

## 2. 兼容性矩阵

| 能力 | 兼容级别 | 说明 |
| --- | --- | --- |
| 洛雪移动版自定义音源 | ✅ 目标支持 | 用官方移动版 `lx` API 语义运行；只支持 `musicUrl`（local 源可扩展 lyric/pic） |
| 洛雪桌面版自定义音源 | ⚠️ 部分支持 | 纯 `lx` API 的脚本可运行；依赖 Node/Electron/DOM 的脚本不支持 |
| 洛雪数据同步 v2.4+ | ✅ 目标支持 | 协议握手 v4；歌单 + 不喜欢规则；可对接桌面服务端模式和独立同步服务 |
| 内置平台搜索/歌单/排行榜 | ✅ | Swift 移植 `lx-music-mobile/src/utils/musicSdk` |
| Ceru 插件 | ❌ 已移除 | 不再加载 `落雪兼容环境.js` 或 `ceru-host.js` |
| App Store 上架 | ❌ 不建议 | 第三方音源/平台抓取/版权风险高，审核大概率不通过 |
| iOS 后台播放 | ✅ | `AVAudioSession` + `UIBackgroundModes=audio` |
| 任意 HTTP 音源 | ⚠️ 需 ATS 例外 | 个人构建可 `NSAllowsArbitraryLoads`，上架不可行 |
| 需要 Referer/UA 的音频 URL | ⚠️ 有条件 | 优先直连；不行时用本地代理注入请求头 |

## 3. 总体架构

```text
┌──────────────────────────── iOS App ────────────────────────────┐
│                                                                  │
│  SwiftUI Presentation                                            │
│  ├─ Search / Discover / Library / Player                         │
│  └─ Settings (source, sync, quality)                             │
│                              │                                   │
│  Application / Domain                                            │
│  ├─ LibraryStore (playlists, tracks, sync state)                 │
│  ├─ PlaybackCoordinator (queue, resolve, history)                │
│  └─ SyncClient (profiles, conflict UI)                           │
│                              │                                   │
│  Infrastructure                                                  │
│  ├─ NativeMusicAPI (Swift)                                       │
│  │  ├─ NativeSearchClients: QQ/网易/酷狗/酷我/咪咕搜索           │
│  │  └─ NativeDiscoveryClients: 歌单、排行榜                      │
│  ├─ LXSourceRuntime (JavaScriptCore)                             │
│  │  └─ 官方 user-api-preload.js + 用户音源脚本                   │
│  ├─ SyncClient: HTTP auth + URLSessionWebSocketTask              │
│  ├─ Player: AVPlayer + AVAudioSession + Now Playing              │
│  └─ Storage: JSON（后续 GRDB）                                   │
│                              │                                   │
└──────────────────────────────┼───────────────────────────────────┘
                               │
              HTTPS / WSS (LAN 或公网反向代理)
                               │
          ┌────────────────────┴────────────────────┐
          │ 洛雪桌面版「服务端模式」                  │
          │ 或 lx-music-sync-server                 │
          └─────────────────────────────────────────┘
```

### 3.1 三层兼容边界

1. **原生平台接口层**：Swift 直接请求 QQ/网易/酷狗/酷我/咪咕，输出洛雪 `MusicInfo`。不需要任何插件。
2. **洛雪音源层**：只负责把已知歌曲解析为播放 URL。输入是洛雪 `MusicInfo`，输出是 HTTP(S) URL；由 JavaScriptCore 执行官方 preload + 用户脚本。
3. **洛雪同步层**：只处理歌单和不喜欢规则；通过 WebSocket 的 message2call 协议工作。

三层之间用内部领域模型解耦，不要让 UI 直接依赖任何一层的私有 JSON。

## 4. 数据模型

核心模型在 `Core/Models/MusicModels.swift`：

```swift
struct MusicInfo {
    var id: String
    var name: String
    var singer: String
    var source: String
    var interval: String?
    var meta: JSONValue
}
```

`meta` 是动态 JSON，保留：

- `songId/albumName/picUrl/qualitys/_qualitys`
- 平台字段：`hash`（酷狗）、`strMediaMid/albumMid`（QQ）、`copyrightId`（咪咕）等
- 本地文件：`filePath/ext`

这样既满足洛雪同步的 `MusicInfo` 结构，也能把同一对象交给音源脚本解析。

歌单同步模型：

```swift
struct ListData { defaultList; loveList; userList }
struct UserListInfo { id; name; source; sourceListId; locationUpdateTime; list }
```

## 5. iOS 平台设计

### 5.1 播放

- `AVPlayer` + `AVAudioSession(.playback)`。
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`。
- 后台音频需要在 target 的 `UIBackgroundModes` 中包含 `audio`。
- 播放 URL 由 `PlaybackResolver` 解析：本地文件直读；在线歌曲交给 `LXSourceRuntime`。

### 5.2 搜索与发现

- `NativeMusicAPI` 直接请求平台接口。
- 平台签名：
  - QQ：`zzcSign`（SHA1 + 固定索引 + XOR + Base64）。
  - 网易：eapi（AES-128-ECB/PKCS7 + MD5 校验串）。
  - 咪咕：MD5 签名 + 设备头。
- 平台接口可能因改版/地区/风控失效，UI 必须显示具体错误。

### 5.3 音源运行时

- `LXSourceRuntime` 每个音源脚本一个 `JSContext`。
- 初始化：加载 `user-api-preload.js` → `lx_setup(...)` → 执行脚本 → 等待 `inited`。
- 解析：`__lx_native__(key, "request", ...)` → 脚本 `lx.on('request')` → 原生 `response`。
- 网络：`URLSession`，支持 headers/body/form/timeout。
- 安全：禁用 `eval/Function`，脚本不能读文件系统，2MB 脚本上限。

### 5.4 同步

- 鉴权：`/hello` → `/id` → `/ah`。
- 加密：AES-128-ECB/PKCS7、RSA-2048 OAEP-SHA1、MD5。
- 传输：`URLSessionWebSocketTask`；大于 1024 字符的消息用 `cg_` + gzip。
- 同步内容：`defaultList/loveList/userList`；`dislike` 规则暂未启用，避免空数据覆盖远端。

## 6. 风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 平台接口改版 | 搜索/歌单失效 | 原生客户端集中在 `Core/Music`，便于逐个修 |
| 音源脚本写法差异 | 播放解析失败 | 同时传 `meta` 和顶层平台字段；错误信息具体化 |
| 版权/平台条款 | 分发风险 | 个人侧载；不内置音源；不提供下载 |
| 同步协议细节差异 | 数据不一致 | 已用官方 sync-server 实测；保留快照合并 |
| ATS/HTTP 音频 | 播放失败 | 个人构建允许任意加载；必要时本地代理 |
| 真机编译未验证 | 类型错误 | 在 Mac/Xcode 首次编译后逐项修 |

## 7. 关键决策

- **不再使用 Ceru 插件**。搜索/歌单/排行榜原生实现；自定义音源只保留官方 preload 的 JSC 运行时。
- **完全不用 JS 做不到**：洛雪音源是 JS，安卓端也用 QuickJS。iOS 用系统 JavaScriptCore，避免引入第三方 JS 引擎。
- **同步协议原生实现**，不复用安卓的 RN 代码。
- **先 JSON 存储，后迁 GRDB**；个人库规模足够。
- **个人自签**，不做 TestFlight/App Store。
