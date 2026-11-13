# Third-party notices (i短剧 / STV multi-source)

## UAV-Downloader — Apache License 2.0
Copyright © ALOS (https://github.com/Alos21750/UAV-Downloader), commit de92300 (latest as of 2026-11-10).
MissAV / Jable / SupJav / Hanime1 / Huangguo-AI parsing logic was ported to Swift (regex instead of BeautifulSoup)
and modified for this app. Full license text: `STV/Resources/Licenses/` (shown in 我的 → 片源管理 → 开源许可).

## yt-dlp — The Unlicense (public domain)
https://github.com/yt-dlp/yt-dlp — page structures / endpoints for Eporner (xhr hash), XVideos / XNXX (html5player),
Pornhub (mediaDefinitions) were cross-checked against its extractors. The Swift code is an independent implementation.

## Interface references without code reuse
- Huangguo AI site (huangguoai.com and mirrors): the 2026-11-09 `POST /api/videos/<id>/episodes/<ep>/playback`
  flow was derived by reading the site's own public front-end scripts (services/playback.js); no third-party code copied.
- Hanime1 compact-grid markup change (`search-videos hover-lighter`) was observed on the live site.

## TDLibKit (MIT) / TDLibFramework / TDLib (Boost Software License 1.0)
- https://github.com/Swiftgram/TDLibKit 1.5.2-tdlib-1.8.69-6126ecae (SPM dependency, MIT)
- https://github.com/tdlib/td 1.8.69 (BSL-1.0), prebuilt by https://github.com/Swiftgram/TDLibFramework
- Used only with the user's own api_id / api_hash entered in the app; none are bundled.

## Telegram web preview / MangaDex / 包子漫画
- t.me/s public channel preview: own HTML parser (interface reference only, no third-party code).
- MangaDex public API (api.mangadex.org), used per its API docs; only safe/suggestive content ratings are requested.
- 包子漫画 mobile pages: own HTML parser (interface reference only).

## QuickJS-ng — MIT
- https://github.com/quickjs-ng/quickjs v0.10.1 (commit 3c9afc9), vendored unmodified in `Packages/QuickJS/Sources/CQuickJS`
  (quickjs.c, libregexp.c, libunicode.c, cutils.c, xsum.c and headers). Full text: `Packages/QuickJS/LICENSE-quickjs-ng.txt`,
  also bundled as `STV/Resources/Licenses/quickjs-ng-LICENSE.txt` and shown in 开源许可.
- `idj_sandbox.c/.h` (eval-less sandbox wrapper, interrupt deadline, host bridge) is this app's own code.

## JMComic-Crawler-Python — MIT (algorithm reference only)
- https://github.com/hect0x7/JMComic-Crawler-Python — the public 18comic image segment algorithm
  (`JmImageTool.get_num` / `decode_and_save`) was re-implemented in Swift (`ImageStripes`) and in the bundled
  18comic plugin's JS. No code copied.

## Bundled plugin site references
- manga18fx / komikindo / 18comic plugins (`STV/Resources/Plugins/*.idjplugin`) parse the sites' public HTML with the
  host CSS selector API; independent implementations.
- 苹果 CMS v10 采集接口 (`?ac=list|detail`) adapter: independent implementation of the public API format.

## AetherEngine — LGPL-3.0 with App Store / DRM Exception (player core, 1.5 build 2+)
- https://github.com/superuser404notfound/AetherEngine — **tag 7.62.0** (commit a1d2cab8281cbf06f5f459b05dad4653ad12559f),
  SwiftPM product `AetherEngine`, statically linked, **unmodified**. Copyright (C) 2026 Vincent Herbst.
- Distributed under the license's App Store / DRM exception (end-user re-linking of the app binary is waived by that
  exception); the corresponding source is the 7.62.0 tag above. Full text: `STV/Resources/Licenses/AetherEngine-LICENSE.txt`
  (bundled, shown in 开源许可).
- Only the `AetherEngine` product is linked; SMBClient appears in Package.resolved but is not linked (no symbols).

## FFmpeg (via FFmpegBuild 3.14.0) — LGPL-2.1-or-later, dynamically linked
- https://github.com/superuser404notfound/FFmpegBuild — tag 3.14.0 (commit 2ff2238f6b65d7686e71c8aa9e45fa4e26f33e1d);
  build script, configure flags and local FFmpeg / libzvbi patches are in that tag's `build.sh` and `patches/`.
- FFmpeg built without `--enable-gpl` / `--enable-version3`. Shipped as dynamic frameworks in `STV.app/Frameworks/`
  (`AetherLibavcodec`, `AetherLibavformat`, `AetherLibavutil`, `AetherLibswresample`, `AetherLibswscale`, `AetherLibavfilter`),
  never merged into the app binary, so they can be replaced/relinked.
- libzvbi (`AetherLibzvbi`): LGPL-2.0-or-later conveyed under LGPL-2.1, `ure.c` MIT; GPL-2 files removed by build.sh.
- Texts: `STV/Resources/Licenses/FFmpeg-LGPL-2.1.txt`, `libzvbi-ure-MIT.txt`.

## dav1d — BSD-2-Clause (`AetherLibdav1d`), zimg — WTFPL (`AetherLibzimg`)
- Unmodified upstream sources built by FFmpegBuild 3.14.0. Texts: `dav1d-BSD-2-Clause.txt`, `zimg-WTFPL.txt`.

## libdovi (dovi_tool `dolby_vision` crate, via LibDovi 2.2.0) — MIT
- https://github.com/quietvoid/dovi_tool — Copyright (c) quietvoid and contributors (MIT OR Apache-2.0, used under MIT).
- Packaged by https://github.com/superuser404notfound/LibDovi tag 2.2.0 (static). Text: `LibDovi-LICENSE.txt`.

## Reverse-engineered protocol data (Hongguo / 红果)
- `STV/Providers/Hongguo/*` and `STV/Resources/medusa_tables.bin` implement the Hongguo app's request signing
  (X-Gorgon / X-Argus / X-Medusa) and device registration from interoperability analysis. Apart from the playback
  signer noted below, no third-party source code is included. No device identifiers, accounts or keys are bundled:
  every install registers / mints its own anonymous device.

## Hongguo playback authentication — GPL-3.0-only
The Argus 551 framing and Ladon implementation in `HGPlayerSign.swift` (`playbackHeaders`) is adapted to Swift from
`zfdang/hongguo-open-player`, commit 3f687c5, `src/server/native/argus.js` (SPDX: GPL-3.0-only),
which credits fqapp / N3urda/hongguoTV. The test vectors in `STVTests/PrefetchTests.swift` match that JS signer.
Source reference: https://github.com/zfdang/hongguo-open-player/commit/3f687c5

## License compatibility
All components above (Apache-2.0, MIT, BSD-2-Clause, WTFPL, BSL-1.0, Unlicense, LGPL-2.1/LGPL-3.0 with exception, GPL-3.0-only) are
compatible with distributing the whole work under GPL-3.0. This project itself is licensed under **GPL-3.0** (see `LICENSE`).
