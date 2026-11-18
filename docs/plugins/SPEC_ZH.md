# i短剧 插件规范 idj1（给写源的人看）

> 版本：idj1 草案 · 2026-11-10（UTC+8）。App 还没有实现，这份是要冻结的格式。
> 字段的完整类型标注见同目录 `idj-plugin.d.ts`，可运行的示例见 `manga18fx/`，检查和测试工具见 `harness/idj.mjs`。

## 1. 一个插件长什么样

```
manga18fx/
├── manifest.json   必须：身份、类型、权限、更新地址
├── main.js         必须：入口脚本（manifest.entry）
└── icon.png        可选
```

插件只有一个脚本文件（不支持 import，包括相对路径 import）。分发时打成 `.idjplugin`：一个 JSON 文件 `{"manifest": {...}, "files": {"main.js": "..."}}`（不是 zip，`files` 里只能有入口脚本）。也可以直接给 `manifest.json` 的网址，App 按 `entry` 把同目录的脚本一起下回来。

## 2. manifest.json 逐项说明

| 字段 | 必填 | 说明 |
|---|---|---|
| `schema` | ✓ | 固定 `1` |
| `id` | ✓ | 反向域名，全局唯一，如 `com.yourname.manga18fx`。装好后不能改，改了算另一个插件 |
| `name` / `version` | ✓ | 显示名；版本号 `x.y.z`，升级必须变大 |
| `author` | ✓ | `{ "name": "...", "contact": "..." }` |
| `type` | ✓ | `video` 长视频 · `shortdrama` 短剧（竖屏、多集） · `comic` 漫画 · `live` 直播 |
| `adult` | ✓ | 必须显式写 `true/false`。`true` 的插件只在「片源管理」打开成人内容并通过 Face ID 后才出现 |
| `minAppVersion` | ✓ | 低于这个版本的 App 拒绝安装 |
| `entry` | ✓ | 入口脚本文件名 |
| `permissions.http` | ✓ | 脚本能请求的域名。只能写 `a.com` 或 `*.a.com`；不能写 `*`、IP、端口 |
| `permissions.media` | | 播放器/图片加载器能去的域名（CDN 常和网页不同）。不写 = 同 `http` |
| `permissions.cloudflare` | | `true` = 允许 App 在后台浏览器里替它过 CF 验证（只对 `http` 里的域名） |
| `permissions.storage` | | `true` = 可用 `host.storage`（每插件 1MB，互相看不到） |
| `permissions.login` | | `true` = 可以请用户在 App 的独立浏览器里登录这个站（cookie 只进本插件） |
| `capabilities` | ✓ | 实现了哪些函数。video/shortdrama 至少 `detail`+`play`；comic 至少 `detail`+`pages` |
| `settings` | | 让用户填的配置项，如镜像地址、API key：`[{ "key": "mirror", "name": "镜像", "type": "text\|select\|secret", "default": "..." }]`。`secret` 类型脚本只拿到句柄，见安全说明 |
| `update.url` | | 新版 manifest 的地址。必须是 https |
| `integrity` | ✓(打包时) | 每个文件的 `sha256-…`，由 `idj pack` 填写；`signature` 可选（作者 Ed25519 签名） |

**权限越少越好。** 安装时用户会看到完整列表；升级时如果权限变多（多了域名、开了 CF/登录），App 会单独弹窗让用户再确认一次，不同意就停在旧版。

## 3. 要写哪些函数

`export default { ... }`，每个函数收**一个参数对象**，返回**普通对象**（可以 `async`）。

| 函数 | 参数 | 返回 | 何时调用 |
|---|---|---|---|
| `init` | `{}` | 无 | 每次加载插件 |
| `home` | `{}` | `{ categories, items? }` | 打开插件首页 |
| `category` | `{ id, page, filters }` | `{ items, page, hasMore }` | 分类翻页，`page` 从 1 开始 |
| `search` | `{ keyword, page }` | `{ items, page, hasMore }` | 全局搜索会并发调用所有开着的插件 |
| `detail` | `{ id }` | 视频：`{ title, cover, desc, lines:[{name, episodes:[{id,name}]}] }`；漫画：`{ title, cover, desc, chapters:[{id,name}] }` | 进详情页 |
| `play` | `{ line, episodeId }` | `{ streams:[{ url, format, headers, proxy? }], subtitles?, danmaku?, skip? }` | 点播放；`expiresAt` 到期前会再调 |
| `pages` | `{ chapterId }` | `{ images:[{ url, transform? }], headers? }` | 漫画进章节 |
| `danmaku` | `{ episodeKey, from, to }` | `{ items:[{ time, text, color?, mode? }] }` | 可选，按时间段分批拉 |

规则：
- **id 都是你自己定的字符串**，App 原样存、原样传回。不要把 cookie、token 塞进 id（会被存进观看历史）。
- 所有地址必须是 `http(s)` 绝对地址，相对地址自己补全。
- 列表里 `title` 和 `id` 不能空；没有封面就不写，别写占位图。
- 漫画 `chapters`、视频 `episodes` 一律**旧→新**。
- 出错用 `throw host.error('E_PARSE', '人能看懂的原因')`，不要吞掉错误返回空列表（空列表 App 会当成「真的没有」）。

## 4. 播放怎么描述（插件不碰播放器）

插件只告诉 App **去哪取、带什么请求头、要不要本地代理做什么处理**。播放、倍速、画质切换、预缓冲、弹幕渲染、字幕渲染、横竖屏，全在 App 里，插件不能也不需要控制。

```js
return {
  streams: [{
    name: '1080P', url: 'https://cdn.example.com/x/index.m3u8', format: 'hls',
    headers: { Referer: 'https://example.com/' },
    proxy: { stripFakeHeader: 'auto' }          // TS 段前有假 PNG 头时
  }],
  subtitles: [{ url: 'https://example.com/a.vtt', lang: 'zh', format: 'vtt' }],
  skip: { introEnd: 90 }
};
```

`proxy` 能声明的处理（都由 App 原生代码执行，插件不在播放热路径里跑代码）：`stripFakeHeader`（去假头）、`hlsKey`（覆盖 AES-128 key）、`segmentDecrypt`（分段解密）、`drm: {type:'cenc-ctr', key}`（CENC MP4 解密）、`rewriteHosts`（段地址换 CDN）。

图片同理：`transform: {type:'stripes', segments: 10}` 让 App 原生把打乱的横条拼回去（18comic 这类）；`{type:'aes', ...}` 解密加密图片（黄果封面这类）。

## 5. 宿主能力 host.*

| 能力 | 说明 |
|---|---|
| `host.http.request(o)` | 唯一的联网方式。只能访问 `permissions.http` 里的域名（跳转后的落点也查），禁止本机/内网地址。自动带本插件自己的 cookie。`cloudflare:'auto'` 时遇到 CF 会由 App 在本插件专用的后台浏览器里过验证再重试 |
| `host.html.parse(text)` | 原生 HTML 解析，`select(css)` / `selectFirst(css)` / `text()` / `attr()` / `html()`。比在 JS 里用正则快得多 |
| `host.crypto.*` | md5 / sha1 / sha256 / hmac / aes(cbc/ecb/ctr/gcm) / rsa 公钥加密与验签 / 随机数 |
| `host.codec.*` | base64、hex、gunzip、`unpackPacker`（解 `eval(function(p,a,c,k,e,d)…)`，纯字符串替换，不执行） |
| `host.m3u8.parse` | 解析 master/media playlist，地址自动补全 |
| `host.storage` | 本插件私有 KV（需 `permissions.storage`） |
| `host.settings` | 用户在插件设置里填的值 |
| `host.log` | 写入本插件日志（「片源管理 → 插件 → 日志」可看） |
| `host.error(code, msg)` | 构造标准错误 |

**没有的东西**：`eval` / `new Function` / 动态 `import()`、`fetch` / `XMLHttpRequest` / `WebSocket`、`document` / `window`、文件系统、剪贴板、通知、打开网页、Telegram/红果/其他插件的任何数据。

## 6. 错误码

| 码 | 含义 | App 怎么处理 |
|---|---|---|
| `E_NETWORK` / `E_TIMEOUT` | 网络不通 / 超时 | 提示重试，可自动换镜像（如果插件设置里有） |
| `E_HTTP` | 非 2xx | 显示状态码 |
| `E_CF_REQUIRED` | 后台过不了 CF | 弹出「去验证」 |
| `E_LOGIN_REQUIRED` | 需要登录 | 有 `login` 权限时弹出登录页 |
| `E_PARSE` | 页面结构变了 | 提示「源可能失效，去更新」 |
| `E_NOT_FOUND` / `E_GEO` / `E_RATE_LIMIT` | 不存在 / 地区限制 / 被限流 | 原样提示 |
| `E_UNSUPPORTED` | 这个操作本插件不支持 | 隐藏入口 |
| `E_PERMISSION` | 访问了未声明的域名 | 宿主抛出，记日志 |
| `E_INTERNAL` | 其他 | 显示消息 |

## 7. 只支持 idj1 格式

App 只接受本规范（idj1）的插件，不提供 FongMi / 影视TV（CatVod）兼容模式；manifest 里出现 `compat` 且不是 `idj1` 会被拒绝安装。老脚本需要按本规范改写（函数名和返回结构见上文）。苹果 CMS 采集站（`/api.php/provide/vod/`）不需要脚本：App 内置通用适配器，在「我的 → 插件 → 采集站」里填接口地址，或写进订阅列表的 `cms` 数组。

订阅列表格式：`{"name": "...", "plugins": [{"id","name","manifest","type","adult","version","description"}], "cms": [{"name","api","adult"}]}`，`manifest` 可以是相对订阅地址的路径。

## 8. 写完怎么自测

```
cd harness && npm i && node idj.mjs validate ../你的插件
node idj.mjs test ../你的插件 搜索词
```

`validate` 查 manifest 格式、禁用写法（eval / fetch / require / window…）、脚本里写死但没声明的域名。`test` 在和 App 同样的限制下（无 eval、域名白名单、禁内网）实际跑 home → category → search → detail → pages/play，并校验返回结构，最后自检越权访问会被拦。App 里也会有同样的「插件调试」页。
