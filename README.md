# LxPlayer（暂名）— iOS 洛雪兼容音乐播放器

> 状态：**M1/M2 工程骨架已生成**（核心链路待真机编译/联调）  
> 目标平台：iOS 16+，SwiftUI，个人侧载（自签）  
> 文档版本：v0.2（2026-11-08）

## 这个项目要解决什么

做一个 iOS 原生音乐播放器，兼容两类洛雪生态能力：

1. **洛雪自定义音源**：从文件或 http(s) 直链导入 `.js` 音源脚本，用脚本解析歌曲播放地址。
2. **洛雪数据同步**：与洛雪桌面版（v2.4+，服务端模式）或独立版 `lx-music-sync-server` 同步歌单；「不喜欢」规则暂未实现，不会覆盖远端数据。
3. **网易云账号**：扫码或手机号登录，把账号下的歌单同步到本机音乐库。

搜索、歌单、排行榜不再依赖用户导入的 Ceru 插件，而是直接参考安卓端 `src/utils/musicSdk` 用 Swift 重写；平台接口的签名、参数和字段映射见 `docs/03-plugin-and-source-runtime.md`。

## 先说结论

- **可行**，但应定位为个人侧载（自签）工具，不建议按 App Store 上架目标设计。
- 洛雪官方目前没有 iOS 计划；本方案是第三方兼容实现。
- **完全不用 JavaScript 做不到**：洛雪音源本身就是 JS，安卓端也是用 QuickJS 执行（`android/.../userApi/QuickJS.java` + `user-api-preload.js`）。iOS 端用系统 JavaScriptCore 执行同一份官方 preload，只保留这一处 JS 运行时。
- 搜索/歌单/排行榜是原生 Swift，不再有 400KB 的 Ceru 宿主或 `落雪兼容环境.js` 依赖。
- 洛雪同步协议可以原生实现。已用官方 `lx-music-sync-server` 2.1.2 做过握手、空库同步、非空库下发和 gzip 消息的实测。

## 构建

见 [BUILD.md](BUILD.md)。当前为个人自签安装，不使用 TestFlight。

## 文档目录

| 文档 | 内容 |
| --- | --- |
| [01-architecture.md](docs/01-architecture.md) | 产品范围、总体架构、数据模型、iOS 平台设计、风险 |
| [02-lx-sync-protocol.md](docs/02-lx-sync-protocol.md) | 洛雪同步 v4 协议：鉴权、WebSocket、message2call、全量/增量同步 |
| [03-plugin-and-source-runtime.md](docs/03-plugin-and-source-runtime.md) | 原生平台客户端、LX 音源运行时与格式转换 |
| [04-implementation-plan.md](docs/04-implementation-plan.md) | 工程结构、里程碑、验收标准、测试矩阵 |

## 重要限制

- 本文档只覆盖**技术可行性**，不构成版权、平台条款或分发合规意见。
- 第三方音源、平台搜索接口和下载功能可能涉及音乐服务条款与版权风险；请只在个人、合法范围内使用。
- `user-api-preload.js` 来自 lx-music-mobile，Apache-2.0；分发时保留 `THIRD_PARTY_NOTICES.md`。
- 洛雪同步消息本身是明文 JSON（仅鉴权用了 AES/RSA）；公网使用必须套 HTTPS/WSS 反向代理或 VPN。

## 参考实现（已对照）

洛雪安卓端仓库：<https://github.com/lyswhut/lx-music-mobile>（本文档对照 v1.9.2）

| 用途 | 源码位置 |
| --- | --- |
| 同步协议/鉴权/重连 | `src/plugins/sync/**` |
| 音源 JS 宿主 API | `android/app/src/main/assets/script/user-api-preload.js` |
| 音源管理/请求桥 | `src/core/init/userApi/**` |
| 内置平台搜索/歌单/排行榜 | `src/utils/musicSdk/**` |
| `MusicInfo` 转换 | `src/utils/index.ts` 的 `toNewMusicInfo` |
| 在线播放/歌词/封面流程 | `src/core/music/online.ts`、`src/core/music/utils.ts` |
| 同步服务端实现 | <https://github.com/lyswhut/lx-music-sync-server>（v2.1.2） |

> 注意：洛雪移动版的 `ios/` 目录只是 React Native 模板壳；QuickJS 音源宿主、播放器、文件系统、导航等原生模块都在 Android 侧。不能直接 `pod install` 得到一个可用的 iOS 版；本项目复用它的 **协议、数据模型和平台接口语义**，界面与原生能力用 SwiftUI/AVPlayer 重写。

## 当前代码状态（M1/M2）

已落地的文件：

- `project.yml`：XcodeGen 工程定义（iOS 16+）。
- `App/`：SwiftUI 入口、AppModel、音频会话。
- `Features/`：搜索、发现（歌单/排行榜）、音乐库、播放器、迷你播放器、歌词页、添加到歌单、设置。
- `Core/Music/`：五平台搜索、歌单、排行榜的 Swift 原生客户端；网易云逐字歌词（yrc）解析。
- `Core/Storage/`：JSON 文件库、音源脚本管理、Keychain。
- `Core/Services/NetEaseAccount.swift`：网易云扫码/手机号登录、账号歌单同步。
- `Core/Player/`：AVPlayer、后台音频、锁屏控制、播放模式、音量。
- `Features/PlayerView.swift`：全屏 Apple Music 风格播放页、专辑封面/专辑名、音质选择、音量、播放模式、收藏、添加到歌单。
- `Features/LyricsView.swift`：Apple Music 风格歌词页（横屏左侧封面/控制、竖屏顶栏+底栏）、逐字高亮、全屏沉浸模式与退出按钮。
- `Features/MiniPlayerView.swift`：液态玻璃迷你播放器，显示专辑封面、歌名/歌手、实时歌词和播放进度。
- `Core/JS/`：`LXSourceRuntime`（JavaScriptCore + 官方 preload）、播放解析。
- `Core/Sync/`：RSA/AES/MD5、gzip、message2call、同步客户端。
- `Resources/user-api-preload.js`：洛雪官方音源预加载脚本。

尚未完成：

- `dislike` 规则同步。
- 部分平台接口：酷狗歌单、QQ 排行榜详情。
- SQLite/GRDB 迁移（当前 JSON 文件足够跑通个人库）。
- 真机编译与端到端联调（本机没有 Xcode）。

构建步骤见 [BUILD.md](BUILD.md)。
