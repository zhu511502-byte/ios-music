# 03 · 原生平台接口与洛雪音源运行时

> 本文说明为什么不能“完全不用 JS”、原生搜索/歌单/排行榜如何移植，以及洛雪自定义音源脚本在 iOS 上如何执行。

## 1. 硬约束：洛雪音源本身就是 JavaScript

洛雪自定义音源不是二进制插件，而是一段 `.js` 脚本。安卓端的执行链是：

```
UserApiModule.loadScript()
  → JavaScriptThread
  → QuickJS.create()
  → 执行 assets/script/user-api-preload.js
  → lx_setup(key, id, name, description, version, author, homepage, rawScript)
  → 执行用户脚本
  → 脚本调用 lx.send(EVENT_NAMES.inited, { sources })
```

所以“完全不用 JS 引擎”无法实现。能去掉的是**第三方 Ceru 插件和 400KB 的 `ceru-host.js`**，不能去掉执行洛雪音源所必需的 JS 引擎。

iOS 端对应实现：

| 安卓 | iOS |
| --- | --- |
| QuickJS（JNI） | JavaScriptCore（系统框架） |
| `user-api-preload.js` | 同一份 `Resources/user-api-preload.js` |
| `__lx_native_call__*` JNI 回调 | `LXSourceRuntime` 里的 Objective-C block |
| `UserApiModule` 请求桥 | `URLSession` |
| `AES.java` / `RSA.java` | CommonCrypto / Security |

## 2. 原生平台接口（不再需要 Ceru 插件）

`Core/Music` 直接参考 `lx-music-mobile/src/utils/musicSdk`：

| 平台 | 搜索 | 歌单 | 排行榜 |
| --- | --- | --- | --- |
| QQ `tx` | ✅ | ✅ 列表/详情 | ⏳ 详情接口迁移中 |
| 网易 `wy` | ✅ | ✅ 列表/详情 | ✅（复用歌单详情） |
| 酷狗 `kg` | ✅ | ⏳ | ✅ |
| 酷我 `kw` | ✅ | ✅ 列表/详情 | ✅ |
| 咪咕 `mg` | ✅ | ✅ 列表/详情 | ✅ |

关键实现点：

- QQ 搜索使用 `zzcSign`：SHA1 → 固定索引取字符 → XOR 混淆 → Base64 → `zzc...`。
- 网易使用 eapi：`nobody{path}use{body}md5forencrypt` → AES-128-ECB/PKCS7 → 大写 hex `params`。
- 咪咕使用 `sign = md5(query + 固定盐 + deviceId + timestamp)`，并带 `uiVersion/deviceId/timestamp/sign/channel` 头。
- 酷我搜索用 `search.kuwo.cn/r.s`，酷狗搜索用 `songsearch.kugou.com/song_search_v2`。
- 所有平台最终都转换成洛雪 `MusicInfo`：`id/name/singer/source/interval/meta`，`meta` 里保留 `songId/albumName/picUrl/qualitys/_qualitys` 及平台字段（`hash`、`strMediaMid`、`copyrightId` 等）。

平台接口可能因改版、地区或风控失效；这是这类客户端的固有限制。

## 3. `LXSourceRuntime`

文件：`Core/JS/LXSourceRuntime.swift`。

### 3.1 初始化

```swift
let runtime = try await LXSourceRuntime.start(profile: profile, script: script)
let capabilities = runtime.supportedCapabilities
```

内部步骤：

1. 创建 `JSContext`。
2. 注入 `__lx_native_call__`、`__lx_native_call__utils_str2b64`、`b642buf`、`str2md5`、`aes_encrypt`、`rsa_encrypt`、`set_timeout`。
3. 执行 `user-api-preload.js`。
4. 调用 `lx_setup(key, id, name, description, version, author, homepage, rawScript)`。
5. 执行用户脚本。
6. 等待脚本 `lx.send(lx.EVENT_NAMES.inited, { sources })`，解析出平台能力。

### 3.2 播放解析

`PlaybackResolver` 调用：

```swift
runtime.musicURL(for: musicInfo, quality: .k320)
```

`LXSourceRuntime` 通过 `__lx_native__(key, "request", payload)` 触发脚本的 `request` 事件；脚本返回 URL 后，preload 会回调原生 `response`，Swift 用 `CheckedContinuation` 把结果交回播放器。

传给脚本的 `musicInfo` 同时保留两种形状：

- `musicInfo.meta.songmid` / `meta.songId`
- 顶层 `musicInfo.songmid` / `musicInfo.hash` / `musicInfo.copyrightId`

这样能兼容新旧音源脚本。

### 3.3 网络与超时

- 脚本的 `lx.request` 由 `URLSession` 执行，支持 `headers/body/form/timeout`。
- 单次 HTTP 默认 13 秒，播放解析整体 25 秒，脚本初始化 15 秒。
- 响应 body 优先按 JSON 解析，失败则按 UTF-8 文本返回；`binary: true` 返回字节数组。

### 3.4 安全边界

- 不提供 `eval` / `Function` 动态执行（preload 已禁用）。
- 脚本只能通过 `lx.request` 访问网络，不能直接读文件系统。
- 脚本大小限制 2MB；HTTP 响应限制 10MB。
- 不加载 Ceru 的 UI surface，也不执行任何插件 UI 代码。

## 4. 音源脚本格式

最小示例：

```js
/*!
 * @name 示例音源
 * @description 仅用于测试
 * @version 1.0.0
 * @author you
 */
const { EVENT_NAMES, request, on, send } = globalThis.lx

on(EVENT_NAMES.request, ({ action, source, info }) => {
  if (action !== 'musicUrl') return Promise.reject(new Error('unsupported'))
  return Promise.resolve('https://example.com/song.mp3')
})

send(EVENT_NAMES.inited, {
  status: true,
  sources: {
    tx: { name: 'QQ', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] }
  }
})
```

## 5. 许可证

- `lx-music-mobile` 为 Apache-2.0；`Resources/user-api-preload.js` 取自该仓库，分发时保留 `THIRD_PARTY_NOTICES.md`。
- 支持文件导入和 http(s) 直链在线导入；用户导入的音源脚本由用户自行确认许可与合法性，本项目不内置任何音源。
- 本文档不构成版权、平台条款或分发合规意见。
