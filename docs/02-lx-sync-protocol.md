# 02 · 洛雪数据同步协议（v4）

> 依据：`lyswhut/lx-music-mobile` v1.9.2 的 `src/plugins/sync/**`、`lyswhut/lx-music-sync-server` v2.1.2 的 `src/server/**`。  
> 本文是第三方客户端的实现说明，不是洛雪官方规范。协议可能随版本变化，接入时以实际服务端版本为准。

## 1. 范围与版本

- 同步内容：**我的列表**（默认列表、收藏、用户歌单）和 **不喜欢规则**。
- 不同步：设置、播放历史、下载、歌词缓存、音源脚本。
- 至少需要：桌面版 v2.4.0 / 移动版 v1.1.0 / 独立同步服务 v2.0.0。
- 当前握手版本：`Hello~::^-^::~v4~`。
- 传输：HTTP（鉴权）+ WebSocket（同步消息）。
- 消息体：**明文 JSON**；仅鉴权阶段使用 AES/RSA。公网必须套 TLS。

## 2. 连接总览

```text
Client                                      Server
  │  GET /hello                              │
  │ ───────────────────────────────────────> │
  │  Hello~::^-^::~v4~                       │
  │ <─────────────────────────────────────── │
  │  GET /id                                 │
  │ ───────────────────────────────────────> │
  │  OjppZDo6<serverId>                      │
  │ <─────────────────────────────────────── │
  │  POST /ah  (header m, optional i)        │
  │ ───────────────────────────────────────> │
  │  base64(RSA-OAEP(KeyInfo)) 或 AES(hello) │
  │ <─────────────────────────────────────── │
  │  WSS /socket?i=<clientId>&t=<token>      │
  │ ───────────────────────────────────────> │
  │  getEnabledFeatures(...)                 │
  │ <─────────────────────────────────────── │
  │  ... list_sync_* / dislike_sync_* ...    │
  │ <──────────────────────────────────────> │
  │  finished()                              │
  │ <─────────────────────────────────────── │
```

## 3. HTTP 鉴权

### 3.1 `GET /hello`

- 成功响应体必须精确等于：

```text
Hello~::^-^::~v4~
```

- 若响应以 `Hello~::^-^::` 开头但版本号不同：
  - 服务端版本更高 → 提示升级客户端；
  - 服务端版本更低 → 提示升级服务端。
- 这是连通性检查，不携带凭据。

### 3.2 `GET /id`

- 成功响应：

```text
OjppZDo6<serverId>
```

`OjppZDo6` 是固定的 base64 前缀（解码为 `::id::`）。只取前缀后的部分作为 `serverId`，用于区分不同的同步服务。

### 3.3 `POST /ah`

#### 首次用连接码认证

输入：用户在洛雪桌面版「设置 → 数据同步」看到的连接码（独立服务则是配置中的用户密码）。

1. 计算：

```text
authKey = Base64Decode( ASCII( MD5_hex(authCode)[0..<16] ) )
```

注意：是取 MD5 十六进制字符串的**前 16 个 ASCII 字符**，再 Base64 编码，再解码成 16 字节 AES key。

2. 生成 RSA 2048 密钥对，公钥导出为 **SPKI DER**，Base64 后去掉 PEM 头尾和换行。

3. 构造明文：

```text
lx-music auth::
<publicKeyBase64>
<deviceName>
lx_music_mobile
```

4. 用 `AES-128-ECB/PKCS7` 加密，Base64 编码，放在请求头 `m`：

```http
POST /ah
m: <base64 ciphertext>
```

5. 成功响应是 Base64 编码的 `RSA-OAEP(SHA-1)` 密文。用刚才的私钥解密，得到 JSON：

```json
{
  "clientId": "S7zrbd+J4t63hhv9C9CajA==",
  "key": "random-16-byte-key-base64",
  "serverName": "My Sync Server"
}
```

6. 保存 `clientId/key`（建议 Keychain），以后不再需要连接码。

#### 已保存 key 的再次认证

```http
POST /ah
i: <clientId>
m: <AES-128-ECB/PKCS7("lx-music auth::" + deviceName, keyInfo.key)>
```

成功响应为 Base64 密文；用 `keyInfo.key` 做 AES-128-ECB/PKCS7 解密，结果必须等于：

```text
Hello~::^-^::~v4~
```

#### 关键细节

| 项 | 值 |
| --- | --- |
| AES | AES-128-ECB，PKCS#7 填充（PKCS#5 在 16 字节块下等价） |
| RSA | 2048-bit，公钥 SPKI，OAEP + SHA-1 + MGF1-SHA1 |
| MD5 | UTF-8 输入，输出小写十六进制 |
| Base64 | 标准字母表，无换行 |
| `deviceName` | 任意稳定字符串，如 `iPhone15,2`；会显示在桌面端设备列表 |
| `isMobile` | 由服务端根据 `lx_music_mobile` 标记为 true；影响服务端发送文本 `ping` |

服务端按 IP 限制失败次数（超过约 10 次返回 `Blocked IP` / 403）。不要在 UI 里自动重试错误连接码。

## 4. WebSocket 连接

```text
ws(s)://<hostPath>/socket?i=<urlencoded clientId>&t=<urlencoded token>
```

- `hostPath` 可以是域名 + 路径，例如 `example.com/lxsync`；客户端只去掉末尾 `/`，保留路径。
- `http` → `ws`，`https` → `wss`。
- `token = AES-128-ECB/PKCS7("lx-music connect", keyInfo.key)`，Base64 后 URL 编码。
- `clientId` 也必须 URL 编码。
- 服务端会校验 query 中的 `t`；失败关闭 4100。
- 同一 `clientId` 重复连接时，服务端会关闭旧连接。
- 服务端同一时间只允许一个同步流程；第二个客户端会等待。

### 心跳

- 服务端会向 `isMobile=true` 的客户端发送文本消息 `ping`。
- 客户端收到 `ping` 后重置 31 秒看门狗；不需要回复。
- 超过约 31 秒没有收到任何消息，客户端主动关闭并重连。
- 重连退避建议：2s、3.5s、5s……上限 30s；不要无限快速重试。

### 关闭码

| code | 含义 | 处理 |
| --- | --- | --- |
| 1000 | 正常关闭 | 不重连 |
| 4100 | 鉴权/同步失败 | 不自动重连，提示错误 |
| 其他 | 网络/服务端异常 | 退避重连 |

## 5. 消息封装

### 5.1 压缩

服务端发送的字符串：

- 若以 `cg_` 开头：取 `cg_` 后面的 Base64，**gunzip** 后得到 JSON。
- 否则：直接是 JSON。

客户端发送：

- JSON 字符串长度超过 1024（服务端以 JS 字符串长度判断）时，建议：
  ```text
  "cg_" + Base64(GZIP(JSON_UTF8))
  ```
- 不超过 1024 时直接发 JSON。
- 服务端两种都能接收；压缩是兼容大列表的关键，不是可选项。

> 这不是加密。`cg_` 只是 gzip 压缩，抓包可直接解出歌单内容。

### 5.2 message2call 信封

实现来自 `message2call@0.1.3`。每条消息是一个 JSON 对象：

请求：

```json
{
  "name": "getEnabledFeatures__7429195265405945",
  "path": ["getEnabledFeatures"],
  "data": ["server", {"list": 1, "dislike": 1}]
}
```

成功响应：

```json
{
  "name": "getEnabledFeatures__7429195265405945",
  "error": null,
  "data": {"list": {"skipSnapshot": false}, "dislike": {"skipSnapshot": false}}
}
```

失败响应：

```json
{
  "name": "getEnabledFeatures__7429195265405945",
  "error": "error message"
}
```

规则：

- `name` 是「方法路径用点连接 + `__` + 随机串」；响应必须原样带回。
- `path` 是方法路径数组；当前只用到一级方法。
- `data` 是参数数组；无参数时是 `[]`。
- 请求方等待响应，默认超时 120 秒。
- `list` 和 `dislike` 各自有一个串行队列；同一模块的调用不要并发处理，避免列表状态交错。
- 收到不认识的方法时返回 `error`，不要静默丢弃。

## 6. 同步流程

### 6.1 服务端驱动

WebSocket 建立后，服务端调用客户端的 `getEnabledFeatures`：

```json
{
  "path": ["getEnabledFeatures"],
  "data": ["server", {"list": 1, "dislike": 1}]
}
```

客户端返回自己支持的模块：

```json
{
  "list": {"skipSnapshot": false},
  "dislike": {"skipSnapshot": false}
}
```

如果不想同步「不喜欢」，返回 `"dislike": false` 或省略该字段。服务端会跳过该模块。

### 6.2 列表模块

服务端可能按以下顺序调用客户端：

| 方法 | 参数 | 客户端行为 |
| --- | --- | --- |
| `list_sync_get_md5` | 无 | 返回当前 `ListData` 的 MD5 十六进制 |
| `list_sync_get_sync_mode` | 无 | 弹出同步方式选择，返回模式字符串 |
| `list_sync_get_list_data` | 无 | 返回完整 `ListData` |
| `list_sync_set_list_data` | `[ListData]` | 用服务端数据覆盖本地 |
| `list_sync_finished` | 无 | 标记 list 模块就绪，开始接收增量动作 |
| `onListSyncAction` | `[ActionList]` | 应用其他设备的增量变更 |

服务端根据两侧数据是否为空决定路径：

- 本地空、远端空：只做 `get_list_data` + `finished`。
- 本地空、远端非空：`set_list_data` + `finished`。
- 本地非空、远端空：`get_list_data`，服务端保存后 `finished`。
- 两侧都非空：先 `get_sync_mode`，再 `get_list_data`，执行合并/覆盖，然后 `set_list_data` 或让服务端保存，最后 `finished`。

### 6.3 首次同步的同步方式

`list_sync_get_sync_mode` 必须由用户选择，不能静默随便返回。客户端视角的模式：

| 模式 | 含义 |
| --- | --- |
| `merge_local_remote` | 以本机为源，合并到远端；保留双方歌曲 |
| `merge_remote_local` | 以远端为源，合并到本机；保留双方歌曲 |
| `overwrite_local_remote` | 用本机覆盖远端（远端独有的用户列表仍可能保留） |
| `overwrite_remote_local` | 用远端覆盖本机（本机独有的用户列表仍可能保留） |
| `overwrite_local_remote_full` | 本机完整覆盖远端，删除远端独有列表 |
| `overwrite_remote_local_full` | 远端完整覆盖本机，删除本机独有列表 |
| `cancel` | 取消本次同步 |

服务端内部会做一次方向翻转（`TRANS_MODE`），这是官方客户端的行为；客户端按上表返回即可。

推荐 UI：首次同步两侧都非空时，默认高亮 **`merge_remote_local`**（保留双方、以远端为基准），但必须让用户确认。合并去重按 `MusicInfo.id`；用户列表按 `id` 对齐，`locationUpdateTime` 大者决定列表顺序。

### 6.4 快照与 MD5

服务端为每个设备保存 `snapshotKey`。`skipSnapshot=false` 时：

1. 服务端取该设备上次同步的快照。
2. 调用客户端的 `list_sync_get_md5`。
3. 如果客户端 MD5 == 服务端当前快照 key，认为已是最新，直接返回。
4. 否则做三方合并（设备快照、本地、远端），避免把另一台设备刚删的歌又合并回来。

**MD5 计算：**

```text
MD5( JSON.stringify(listData) )
```

`JSON.stringify` 的细节很重要：

- 无空格。
- 字段顺序按对象插入顺序；`ListData` 固定为 `defaultList`、`loveList`、`userList`。
- 用户列表对象顺序：`id`、`name`、`source`、`sourceListId`、`locationUpdateTime`、`list`。
- `MusicInfo` 顺序：`id`、`name`、`singer`、`source`、`interval`、`meta`；`meta` 内部按洛雪生成顺序。
- `undefined` 字段会被省略；`null` 会保留。Swift 不能用普通 `Codable` 把 `undefined` 变成 `null`。
- 不要转义 `/`；Unicode 直接输出 UTF-8，不做 `\uXXXX`（控制字符除外）。

**工程建议：**

- 数据库保存原始 JSON 字符串（`lx_json`），不要每次从 Swift 结构体重建。
- 新增/修改歌曲时，用与洛雪一致的顺序构造 JSON。
- 如果 MD5 暂时对不上，不会丢数据；服务端会走快照合并，但可能重复提示冲突或产生额外合并。先把功能跑通，再做字节级对齐。

## 7. `ListData` 结构

```json
{
  "defaultList": [
    {
      "id": "tx_0039MnYb0qxYhV",
      "name": "晴天",
      "singer": "周杰伦",
      "source": "tx",
      "interval": "04:29",
      "meta": {
        "songId": "0039MnYb0qxYhV",
        "albumName": "叶惠美",
        "picUrl": "https://...",
        "qualitys": [{"type": "320k", "size": "10.29 MB"}],
        "_qualitys": {"320k": {"size": "10.29 MB"}},
        "albumId": "000MkMni19ClKG",
        "strMediaMid": "003Qui1q2u1Zho",
        "albumMid": "000MkMni19ClKG",
        "id": 97773
      }
    }
  ],
  "loveList": [],
  "userList": [
    {
      "id": "user1",
      "name": "测试歌单",
      "source": null,
      "sourceListId": null,
      "locationUpdateTime": null,
      "list": []
    }
  ]
}
```

- `defaultList` 对应「试听列表」。
- `loveList` 对应「我的收藏」。
- `userList` 是用户创建/收藏的在线歌单；`list` 内是 `MusicInfo`。
- `tempList`（临时列表）**不参与同步**。
- `source` / `sourceListId` / `locationUpdateTime` 可能缺失或为 `null`；必须原样保留。
- `id` 是同步去重键；不要用标题+歌手代替。

## 8. 增量动作 `ActionList`

服务端向其他设备广播本地变更时，会调用 `onListSyncAction`。客户端也必须能把本地变更通过 `onListSyncAction` 发给服务端。

| `action` | `data` 形状 | 本地处理 |
| --- | --- | --- |
| `list_data_overwrite` | `ListData` | 全量替换，事务提交 |
| `list_create` | `{position, listInfos:[UserListInfo]}` | 在 position 插入用户列表 |
| `list_remove` | `[listId]` | 删除用户列表及其歌曲 |
| `list_update` | `[UserListInfo]` | 更新名称/来源/位置时间 |
| `list_update_position` | `{position, ids:[listId]}` | 重排用户列表，更新 `locationUpdateTime` |
| `list_music_add` | `{id, musicInfos:[MusicInfo], addMusicLocationType}` | 去重后插入列表顶部/底部 |
| `list_music_move` | `{fromId, toId, musicInfos, addMusicLocationType}` | 从源列表移除并加到目标 |
| `list_music_remove` | `{listId, ids:[MusicInfo.id]}` | 从列表移除 |
| `list_music_update` | `[{id:listId, musicInfo: Partial<MusicInfo>}]` | 更新歌曲元数据 |
| `list_music_update_position` | `{listId, position, ids:[MusicInfo.id]}` | 重排歌曲 |
| `list_music_overwrite` | `{listId, musicInfos}` | 全量替换某列表歌曲 |
| `list_music_clear` | `[listId]` | 清空列表歌曲 |

处理原则：

- 每个动作在一个数据库事务中完成。
- `addMusicLocationType` 默认 `bottom`；服务端配置可能为 `top`，以动作字段为准。
- 歌曲去重按 `MusicInfo.id`，不是标题。
- `list_music_update` 的 `musicInfo` 可能是部分字段；只覆盖出现的字段。
- 处理成功后返回 `null`；失败返回 `error`，服务端会关闭连接，需要重连后重新同步。

## 9. 不喜欢同步（可选）

方法与列表对称：

```text
dislike_sync_get_md5
dislike_sync_get_sync_mode
dislike_sync_get_list_data
dislike_sync_set_list_data
dislike_sync_finished
onDislikeSyncAction
```

- `DislikeRules` 是一个字符串（不是数组）。
- MD5 计算为 `MD5(rules.trim())`。
- 动作：
  - `dislike_data_overwrite`：字符串全量替换。
  - `dislike_music_add`：`[{name, singer}]` 数组。
  - `dislike_music_clear`：清空。
- 第一版可以返回 `"dislike": false` 跳过；不要假装支持但返回空数据，否则会覆盖桌面端规则。

## 10. 错误、重连与边界

- RPC 超时：120 秒；超时后关闭连接并重连。
- 鉴权失败：不要自动重试连接码；让用户改。
- 同步中断：重新连接后从服务端重新走流程；不要假设上次完成。
- 服务端 `finished` 之前不要标记“已同步”。
- 大列表：10,000 首歌曲可能达到数 MB；必须支持 gzip，建议实测 10k 首。
- 时钟：`locationUpdateTime` 使用毫秒时间戳；以客户端 `Date.now()` 为准。设备时间严重不准会影响列表排序，但不会丢歌。
- 明文消息：不要在公网直接使用 `ws://`/`http://`；用 Nginx/Caddy 反代到 `wss://`/`https://`。

## 11. Swift 实现要点

### 11.1 加密

```swift
// 伪代码
let authKey = Data(base64Encoded: String(md5Hex(authCode).prefix(16)))!
let cipher = AES128ECB_PKCS7(key: authKey)
let m = cipher.encrypt(Data(authMessage.utf8)).base64EncodedString()
```

- AES 用 CommonCrypto 的 `CCCrypt`，选项 `kCCOptionECBMode | kCCOptionPKCS7Padding`。
- RSA 用 Security.framework：
  - 生成：`SecKeyCreateRandomKey`，2048-bit，`kSecAttrKeyTypeRSA`。
  - 公钥导出：`SecKeyCopyExternalRepresentation` 得到 PKCS#1，需要手工包一层 SPKI DER 再 Base64。
  - 解密：`SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, ciphertext)`。
- `CryptoKit.Insecure.MD5` 可用于 MD5。

### 11.2 gzip

- 服务端的 `cg_` 是 **gzip**（RFC 1952），不是 zlib 或 raw deflate。
- iOS 可用 `zlib` C API（`deflateInit2` 使用 `MAX_WBITS + 16`）或 `Compression` 框架加 gzip 头尾封装。
- 解码时先 Base64，再 gunzip，再 UTF-8 JSON。

### 11.3 WebSocket

- `URLSessionWebSocketTask` 负责建连和收发。
- 自己维护 `receive` 循环；不要只调用一次 `receive`。
- 服务器文本 `ping` 只重置看门狗，不要当 JSON 解析。
- 关闭时取消 receive 循环，避免 retain cycle。

### 11.4 message2call

建议实现一个 `Message2Call` actor：

```swift
actor Message2Call {
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    func request(path: [String], args: [Any]) async throws -> Any
    func handle(_ message: Message) async
}
```

- 收到 `path` 非空：调用本地 handler，发响应。
- 收到 `name` 非空、`path` 为空：完成 pending continuation。
- 用 `CheckedContinuation` 或 `AsyncStream`；不要阻塞主线程。
- 每个模块一个串行队列（actor 的方法本身可重入，需要显式串行化）。

### 11.5 JSON 保序

Swift 的 `JSONEncoder`/`JSONSerialization` 不保证字典键顺序。建议：

- 用 `OrderedJSON` 结构体/手写 writer 生成同步 JSON；或
- 保存服务端下发的原始 JSON 文本，仅在本地变更时重建受影响的对象；或
- 第一版接受 MD5 不一致，依赖服务端快照合并（不丢数据，但可能有额外冲突）。

## 12. 实测记录

已在本地运行官方 `lx-music-sync-server` 2.1.2：

1. `GET /hello` 返回 `Hello~::^-^::~v4~`。
2. `GET /id` 返回 `OjppZDo6...`。
3. 首次连接码认证返回 200，RSA-OAEP 解密得到 `clientId/key/serverName`。
4. WebSocket 连接成功，服务端调用 `getEnabledFeatures`。
5. 空库同步：`list_sync_get_list_data` → `list_sync_finished` → `dislike_sync_*` → `finished`。
6. 通过 `onListSyncAction(list_data_overwrite)` 写入一首歌和一个用户歌单后，新客户端收到 `list_sync_set_list_data`；消息因超过 1024 字符被包成 `cg_...`，**必须 gunzip** 才能解析。
7. 未做 gzip 解码时，客户端会静默卡住直到 120 秒超时——这是最容易踩的坑之一。

> 以上是 Node 参考客户端实测；iOS 端仍需在真机上复测 RSA SPKI、CommonCrypto 和 gzip。

## 13. 安全说明

- 同步消息是明文；同一局域网内可被嗅探。
- 连接码只在首次认证时使用；之后用 `clientId/key`。
- `key` 是 16 字节随机数的 Base64，不是用户密码；仍应存 Keychain。
- 公网部署：Nginx/Caddy 终止 TLS，转发 HTTP/WS 到同步服务；不要直接把 23332 暴露到公网。
- 参考官方文档的警告：同步功能是实验性的，建议先在测试账号/测试歌单上验证。
