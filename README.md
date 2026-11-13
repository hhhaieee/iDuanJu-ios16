# i短剧 (iDuanJu)

> **本项目完全免费、开源，禁止任何形式的付费分发 / 售卖。**
> 本项目以 **GPL-3.0** 协议发布：任何使用、修改、衍生本项目代码的作品，都必须同样以 GPL-3.0 开源并公开完整源代码。
> 如果你是花钱买到本 App 或本代码的，你被骗了，请举报卖家。

i短剧 是一个原生 SwiftUI 编写的 iOS 多源短剧 / 视频 / 漫画 / Telegram 频道聚合播放器，另有原生 Kotlin 编写的
[Android 版](#android-版)。App 本身**不托管任何内容**，所有数据都由你的设备直接向各个公开站点请求。

**下载**：到 [Releases](https://github.com/my-name-is-alan/iDuanJu/releases) 获取 iOS 未签名 IPA 和 Android APK
（[Android 1.5.2](https://github.com/my-name-is-alan/iDuanJu/releases/tag/v1.5.2-android)）。

## 功能

- **内置源**：红果短剧（本地签名、匿名设备）、黄果（AI 短剧 / 视频）、Telegram 频道（网页预览 + 可选 TDLib 登录）
- **长视频站点**（18+，默认关闭）：MissAV、Jable、SupJav、Hanime1、Pornhub、XVideos、Eporner 等
- **漫画**：MangaDex、包子漫画，以及 JS 插件（manga18fx / komikindo / 18comic，18+，默认关闭）
- **JS 插件系统**：基于 QuickJS 的沙箱，每个插件独立运行、只能访问自己声明且你同意过的域名，cookie / 存储互相隔离，
  不能 `eval`、访问不到本机和内网。支持从网址 / 文件 / 粘贴添加，以及订阅列表。规范见 [`docs/plugins/SPEC_ZH.md`](docs/plugins/SPEC_ZH.md)
- **苹果 CMS v10 采集站**通用适配（m3u8 / mp4 直链）
- **播放内核**：默认 [AetherEngine](https://github.com/superuser404notfound/AetherEngine)（FFmpeg 解封装 + 系统硬解，支持 MKV/FLV/AVI、真实音轨 / 字幕列表、HDR / 杜比视界），
  遇到 CENC / FairPlay 或加载失败时自动回退系统 AVPlayer；可在设置里手动切换
- **去广告**：自动剔除 HLS 片源中插播的广告片段（adjump、异域名短片段、AES 片源里的明文短片段等），默认开启，可在设置里关闭
- **播放器**：自绘控制层、竖屏默认 / 旋转或手动横屏、亮度音量手势、倍速、画质 / 线路切换、选集、弹幕、跳过片头、
  预缓冲、本地 HLS 代理、CENC 解密、Telegram 视频边下边播（TDLib Range 流式）
- **Cloudflare 验证**：隐藏 WebView 自动过验证（每个插件独立）

## 截图

> 模拟器截图，内容均为红果公开短剧及演示插件。

| 首页 | 频道切换 | 搜索 | 详情 |
|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/01-home.jpg" width="200"> | <img src="docs/screenshots/02-channels.jpg" width="200"> | <img src="docs/screenshots/03-search.jpg" width="200"> | <img src="docs/screenshots/04-detail.jpg" width="200"> |
| **竖屏播放** | **选集** | **弹幕** | **插件管理** |
| <img src="docs/screenshots/05-player.jpg" width="200"> | <img src="docs/screenshots/06-episodes.jpg" width="200"> | <img src="docs/screenshots/07-danmaku.jpg" width="200"> | <img src="docs/screenshots/08-plugins.jpg" width="200"> |
| **插件详情与权限** | | | |
| <img src="docs/screenshots/09-plugin-detail.jpg" width="200"> | | | |

**横屏播放**

<img src="docs/screenshots/10-landscape.jpg" width="820">

**AetherEngine 播放内核（1.5 build 2）**

| 音轨 | 画质 / 播放源 | 倍速（最高 2×） | 去广告 / 播放内核设置 | 开源许可 |
|:---:|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/11-audio-tracks.jpg" width="160"> | <img src="docs/screenshots/12-quality-source.jpg" width="160"> | <img src="docs/screenshots/13-speed.jpg" width="160"> | <img src="docs/screenshots/14-settings-adstrip-engine.jpg" width="160"> | <img src="docs/screenshots/15-licenses.jpg" width="160"> |

## 编译

要求：macOS + Xcode 16 或更新、[XcodeGen](https://github.com/yonaskolb/XcodeGen)，最低支持 **iOS 18.0**（AetherEngine 的要求）。

```bash
brew install xcodegen
git clone https://github.com/my-name-is-alan/iDuanJu.git && cd iDuanJu
xcodegen generate          # 生成 STV.xcodeproj（工程文件不入库）
open STV.xcodeproj         # 或命令行：
xcodebuild -project STV.xcodeproj -scheme STV -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

依赖会由 Swift Package Manager 自动拉取：TDLibKit（含预编译 TDLib，首次拉取较大）、AetherEngine 7.62.0（含预编译 FFmpeg 等框架）；
QuickJS-ng 已 vendored 在 `Packages/QuickJS`。

## 播放内核（AetherEngine）

- 默认使用 **AetherEngine 7.62.0**（LGPL-3.0，附 App Store / DRM 例外条款），以 SwiftPM 静态链接、未修改。
- 它带的 **FFmpeg（LGPL-2.1，未启用 GPL / version3 组件）** 及 libzvbi、dav1d、zimg 以**动态框架**形式放在
  `STV.app/Frameworks/AetherLib*.framework`，没有并入主程序，可以替换 / 重新链接。各组件许可全文见
  `STV/Resources/Licenses/` 和 App 内「开源许可」，详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
- AetherEngine 目前**最高只支持 2× 倍速**，倍速列表和长按加速都封顶 2×。
- CENC 加密片源、FairPlay 或 AetherEngine 加载失败时会**自动回退系统播放器（AVPlayer）**；
  也可以在「我的 → 片源管理 → 播放设置 → 播放内核」手动选择「AetherEngine / 系统播放器」。
- **去广告**：同一页的「去广告」开关（默认开启）会在本地 HLS 代理里剔除插播广告片段；不会整段丢弃正片的分段标记。
  如遇个别片源误删或卡顿，可以关掉试试。

### 打包未签名 IPA（侧载）

```bash
scripts/package.sh            # 输出到 ./dist/STV-<版本>-unsigned.ipa
```

未签名 IPA 用 AltStore / Sideloadly / TrollStore 等工具用你自己的 Apple ID 重签后安装。

## Android 版

位于 [`android/`](android/)：原生 **Kotlin + Jetpack Compose + Media3（ExoPlayer）**，插件运行时为 QuickJS，
目标与 iOS 功能对齐。**minSdk 26（Android 8.0）/ targetSdk 35**。当前版本 **1.5.2**（预发布）。

```bash
# 要求 JDK 21 + Android SDK（platform 35）
cd android
./gradlew assembleRelease   # 输出 app/build/outputs/apk/release/app-release.apk
./gradlew :core:test        # 离线单元测试
```

Releases 里的 APK 用 Android 调试证书签名（未上架任何商店），首次安装需允许「安装未知来源应用」；
以后换成正式签名的版本需要先卸载再装。

已对齐 iOS：

- 红果：榜单 / 详情（题材、演员、关联季）/ 取流 / CENC 解密 / 播放；弹幕；选集面板（季、区间、更新至）
- 播放器：手势、倍速、画质、技术标签、季标、按设备解码能力选流；HLS 去广告（默认开启，可关）
- 苹果 CMS v10 采集站；idj1 JS 插件（视频 + 漫画、`idjimg://` 图片、域名白名单、订阅列表、内置推荐插件）
- Telegram 公开频道（t.me 网页预览）+ 屏蔽规则（关键词 / 正则 / 域名、广告识别、隐藏或折叠）
- 黄果、漫画（MangaDex、包子、插件）；首页频道栏与「频道」面板、多源搜索、继续观看 / 收藏 / 历史
- 「我的」：成人片源开关（18+ 确认，默认关闭）、去广告、重置设备 / 会话、清缓存

尚未移植：TDLib 登录与下载管理、漫画离线下载、插件执行超时中断与签名校验、长视频预缓冲设置、Face ID 片源锁。

**红果取流**：上游会软拒绝从未注册过的本地设备（HTTP 200 空包）。Android 默认每次取流现注册一台一次性匿名设备，
只用一次，仓库内不附带、不写死任何设备 ID；也可以在「我的」里填入你自己的设备覆盖。

## Telegram（TDLib）登录

公开频道走 t.me 网页预览，不需要登录。私有 / 受限频道、频道内搜索需要 TDLib 登录：

1. 到 <https://my.telegram.org> → API development tools 申请你自己的 `api_id` / `api_hash`
2. App 内「我的 → 片源管理 → Telegram 登录」填入，再用手机号 + 验证码登录

本仓库**不内置任何 api_id / api_hash**，凭据只保存在你设备的钥匙串里。

## 红果设备

红果使用每台设备本地生成的匿名设备，仓库内不附带任何设备 ID。如果上游拒绝新生成的设备，可以在
UserDefaults 键 `stv.hg.purePlayerDevice` 写入你自己的 `"<device_id>,<iid>"`。

## 成人内容

成人站点 / 频道 / 漫画插件**默认全部关闭**，需要在「我的 → 片源管理」中手动开启（可选开启 Face ID 锁，冷启动后重新隐藏）。仅限已满 18 周岁且所在地法律允许的用户使用。

## 免责声明

- 本项目仅供个人学习、研究 iOS / Swift / 网络协议使用，**不提供、不存储、不分发**任何视频、图片或漫画内容。
- 所有内容版权归原站点和权利人所有。使用时请遵守各站点的服务条款及你所在地的法律法规，由此产生的一切后果由使用者自行承担。
- 项目中对第三方接口的适配仅用于互通性研究，与相关平台无任何关联。如有权利人认为侵权，请提 issue 联系处理。

## 许可证

[GPL-3.0](LICENSE)。第三方组件及其许可见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

**禁止付费分发**：本项目是免费软件，作者不授权任何人以收费方式出售、分发本 App 或其代码。任何衍生作品都必须以 GPL-3.0 公开源代码。

---

## English

**iDuanJu** is a native SwiftUI iOS aggregator/player for short dramas, videos, manga and Telegram channels, with a
sandboxed QuickJS plugin system (per-plugin domain allow-list, isolated cookies/storage, no `eval`). It hosts no content.

- Build: `xcodegen generate`, then build the `STV` scheme in Xcode (iOS 18.0+).
- Player core: AetherEngine 7.62.0 (LGPL-3.0 with App Store exception, unmodified) with FFmpeg (LGPL-2.1) shipped as replaceable
  dynamic frameworks; automatic AVPlayer fallback; speed capped at 2× by the engine; optional HLS ad-strip (on by default). Sideload the unsigned IPA from `scripts/package.sh`.
- **Android** (`android/`): native Kotlin + Jetpack Compose + Media3, minSdk 26 / targetSdk 35. Build with JDK 21:
  `cd android && ./gradlew assembleRelease`. Prebuilt (debug-cert signed) APK on the
  [Releases](https://github.com/my-name-is-alan/iDuanJu/releases) page. Not yet ported: TDLib login/downloads, manga offline
  download, plugin timeout/signature checks, long-video precache, Face ID lock.
- Telegram login uses **your own** `api_id` / `api_hash` from my.telegram.org; none are bundled.
- Adult (18+) sources are off by default and require explicit unlock.
- For personal study only; respect each site's Terms of Service and your local laws.
- **License: GPL-3.0.** This project is free. **Selling or paid distribution is prohibited**; any derivative work must stay open source under GPL-3.0.
