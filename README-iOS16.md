# iDuanJu（i短剧）iOS 16 降级改造包

本目录是 **iDuanJu v1.5b7 (cef6342)** 经过降级改造后的源码，目标是把最低系统版本从
**iOS 18.0 降到 iOS 16.0**。

> ⚠️ 重要提示：本次改造是在 Linux 环境下完成的，**没有经过 Xcode 编译验证**（编译 iOS
> 必须用 macOS + Xcode）。代码已尽量按 Swift 规则改全，但第一版编译时**可能仍有个别报错需要
> 根据编译信息微调**。请知悉后再继续。

---

## 一、改了什么

| # | 改动 | 规模 |
|---|---|---|
| 1 | `@Observable` / `import Observation` → `ObservableObject` + `@Published`（Combine） | 20 个类、148 个属性 |
| 2 | View 层单例持有 → `@ObservedObject` / `@StateObject` | 约 30 处 |
| 3 | iOS 17/18 SwiftUI API 加 `#available` 兜底（ContentUnavailableView、scrollPosition、onScrollGeometryChange、symbolEffect 等） | 约 20 处 |
| 4 | `onChange` 双参数闭包 → 单参数（iOS 16 兼容签名） | 23 处 |
| 5 | 竖屏短剧 feed 分页滚动：iOS 17 保留原生实现，iOS 16 用 ScrollView + 滚动吸附降级 | 1 处 |
| 6 | `deploymentTarget` 18.0 → 16.0；AetherEngine 依赖改为本地 `path:`（由构建脚本打补丁） | 2 处 |
| 7 | 新增兼容层 `STV/Views/Compat.swift` 与云编译 workflow `.github/workflows/build-ios16.yml` | 2 个文件 |

---

## 二、方式 A：GitHub Actions 云编译（不需要你自己的 Mac）

1. 在 GitHub 上 **Fork** 仓库 `my-name-is-alan/iDuanJu`。
2. 把本目录的内容**覆盖到你的 fork**（删掉 fork 里原有的 `STV/`、`project.yml`、`scripts/`，
   再把本目录里的这些文件传上去；或直接把本目录初始化成一个新仓库 push）。
3. 进入 fork 的 **Actions** 页 → 选择 **Build iOS 16 IPA** → **Run workflow**。
4. 等待编译完成（首次需拉取 TDLib、FFmpeg 预编译框架，约 10–30 分钟）。
5. 从该次运行的 **Artifacts** 下载 `STV-ios16-unsigned`，里面是未签名 IPA。

> workflow 会自动 `git clone` AetherEngine 7.62.0 并把它的 `Package.swift` 里
> `.iOS(.v18)` 改成 `.iOS(.v16)`，无需你手动处理。

## 三、方式 B：本地 Mac 编译

```bash
brew install xcodegen
# 1) 把本目录放到某处，进入后：
git clone --depth 1 --branch 7.62.0 https://github.com/superuser404notfound/AetherEngine.git ../AetherEngine
sed -i '' -e 's/\.iOS(\.v18)/.iOS(.v16)/' -e 's/\.tvOS(\.v18)/.tvOS(.v16)/' ../AetherEngine/Package.swift
# 2) 编译并打包未签名 IPA（同时产出模拟器包）
bash scripts/package.sh dist
# 3) 产物在 dist/STV-1.5-unsigned.ipa
```

---

## 四、重签并安装（AltStore / Sideloadly / TrollStore）

编译产物是**未签名 IPA**，需要用你自己的 Apple ID 重签后安装：

- **AltStore / Sideloadly**：导入 IPA → 填 Apple ID → 签名安装（免费账号 7 天有效期，需续签）。
- **TrollStore**（若设备支持）：可直接安装未签名 IPA，无需续签。

签名前请确认你的 iPhone 12（iOS 16.2）与安装工具兼容。

---

## 五、风险与可能需要微调的地方

1. **未编译验证**：如编译报错，请优先看报错文件与行号，多半是以下两类：
   - `@Published` 加到了计算属性上（应去掉该 `@Published`）；
   - `@MainActor` 与 `ObservableObject` 的隔离冲突（可按报错加 `@MainActor` 或去掉属性级隔离）。
2. **AetherEngine 的 Swift 层是否用到 iOS 17+ API 尚未验证**。若编译时 AetherEngine 内部报
   "requires iOS 17/18"，则需进一步 fork AetherEngine 处理（工作量会再增加）。
3. **iOS 16 竖屏 feed**：分页吸附为降级实现（滚动停止后 0.2s 吸附到最近集），体验略简于原生
   `scrollTargetBehavior(.paging)`，但功能可用。
4. **TDLibKit / FFmpegBuild 预编译框架**：它们的二进制最低版本分别是 iOS 12 和 iOS 16，无需处理。

---

## 六、与原作者仓库的关系

- 本项目以 **GPL-3.0** 发布，任何衍生作品必须同样开源。你的 fork 应保持公开并保留许可声明。
- 本改造仅用于个人学习与兼容性研究，禁止付费分发。
