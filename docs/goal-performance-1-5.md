# Goal: QuietGlass 性能优化（第 1–5 项）：预热解耦与稳态去重

状态：进行中
适用范围：`Sources/QuietGlass`、`Sources/ShieldCore` 的既有行为，不改变产品语义。
交付物：代码、针对性测试、`~/Downloads/QuietGlass.app`。

## 背景

一次只读 CPU/GPU 复查发现：QuietGlass 为了保证“从触发到遮蔽”的延迟，把一部分
实时性成本常驻化了。常驻成本主要集中在五条路径：

1. 附近人脸规则一旦启用，屏幕采集会预热；预热同时开启了全屏模糊渲染。
2. 全屏模糊以 30 fps 渲染，且每帧把结果合成到上一帧上再回读。
3. 摄像头空闲时仍以 10 fps 检测，且每一帧都跑完整人脸流程。
4. 窗口/几何上下文以 10 Hz 轮询，并对所有窗口标题做 SHA-256。
5. OCR 在全分辨率帧上执行，指纹对每个像素行做哈希。

目标是在不牺牲触发延迟和正确性的前提下，把这五条路径的稳态开销降下来。

## 不变量（Invariants）

- **触发延迟不退化**：附近人脸规则从“人脸出现”到“模糊可见”的路径仍保持采集预热；
  预热只允许去掉无意义的渲染，不允许延迟采集流的建立。
- **保护正确性不退化**：任何 `hasProtection == true` 的显示仍必须持续渲染；
  任何 `fullScreenCoverage > 0` 或动画覆盖度 > 0 的显示仍必须持续渲染。
- **权限与就绪语义不退化**：采集流成功出帧后仍必须触发一次 `onReady`；
  采集失败仍必须走 `onFailure`，不得因降频/跳过渲染而吞掉。
- **OCR 灵敏度不退化**：文本规则仍必须能发现敏感文本；缓存失效必须与 OCR 实际
  看到的图像一致。
- **窗口规则匹配不退化**：窗口标题匹配、关闭窗口清理、活动窗口/桌面切换仍必须正确。
- **现有测试保持通过**：`./scripts/test.sh` 全绿；桌面集成测试按仓库脚本单独执行。

## 第 1 项：预热只做采集，不做渲染

现状：
- `ScreenBlurExecutor.renderPlan` 的 `fullScreen` 在 `captureDisplayIDs` 命中时为 true。
- `setRenderingEnabled` 与 `ScreenCaptureRequest.renderingEnabled` 同样把
  `captureDisplayIDs` 当作渲染开关。
- 结果是：没有人脸、覆盖度为 0 时，仍在 30 fps 做全屏高斯模糊并回读 CGImage。

改动：
- `renderPlan.fullScreen` 只由 `fullScreenCoverage > 0` 或动画覆盖度 > 0 决定。
- 渲染开关只由 `hasProtection`、`fullScreenCoverage > 0` 或动画覆盖度 > 0 决定。
- 采集流仍由 `captureDisplayIDs` 维持（预热保留）。
- 渲染关闭时，用原始采样帧上报一次 `onReady`，保证权限/就绪状态不被预热路径卡住。

验收：
- 仅有 `captureDisplayIDs`、无覆盖度时：采集流存在，`renderingEnabled == false`，
  `renderPlan.fullScreen == false`，且 `onReady` 至少触发一次。
- 覆盖度变为 > 0 时：无需重建采集流即可开始渲染，且使用最近一帧。

## 第 2 项：降低全屏模糊渲染成本

现状：
- 覆盖度 > 0 时按 30 fps 渲染。
- `DisplayBlurRenderer.render` 每帧构造背景并执行 `composited(over:)`，然后
  `createCGImage` 回读；`previous` 仅用于透明帧兜底。
- `CIContext` 使用 `cacheIntermediates: false`。

改动：
- 活跃全屏模糊帧率从 30 降到 20；仅预热采集使用 15；区域规则保持 12；空闲 3。
- 屏幕采集帧是 BGRA 不透明帧，渲染器增加显式 `opaque` 快速路径，跳过
  `composited(over: previous)` 与背景构造；透明输入仍保留原有兜底。
- 保持 `cacheIntermediates: false`：每帧输入都是新帧，缓存中间结果只会增长内存，
  不产生跨帧复用；在代码注释中记录该结论。

验收：
- 透明输入、空输入、分辨率变化的行为与现有 `DisplayBlurRendererTests` 一致。
- 生产路径（`DisplayCapture`）走 `opaque: true`，不再构造 `previous` 背景。

## 第 3 项：摄像头空闲降频与按需识别

现状：
- `FaceCamera.limitFrameRate` 固定 10 fps，`captureOutput` 固定 0.09 s 扫描。
- 无人脸时仍持续跑人脸检测；owner 特征只在检测到人脸后提取。

改动：
- 无人脸时把采集帧率降到 5 fps；检测到人脸立即升到 10 fps。
- 降频带滞后：连续若干空帧后才降，避免人脸抖动导致频繁重配。
- owner 识别保持“仅对已检测到的人脸提取特征”，无人脸时不加载/不执行特征推理。
- `NearbyCameraSession` 增加带默认实现的空闲配置入口，测试替身无需改动。

验收：
- 空样本后设备帧率下降；出现人脸后恢复。
- 现有 `NearbyPeopleTests` 的检测、警告、暂停、恢复语义不变。

## 第 4 项：几何轮询事件驱动化与标题按需哈希

现状：
- `RuleEventSources` 以 0.1 s 定时器轮询；`refresh()` 每次枚举窗口并对每个窗口标题
  做 SHA-256。
- 只有需要几何的规则才应轮询，但窗口标题哈希对所有窗口无条件执行。

改动：
- 保留事件驱动刷新（应用激活、空间切换、手动操作），把轮询间隔从 0.1 s 放宽到
  0.25 s；仅在 `needsGeometryPolling` 为真时刷新。
- 只为“确实需要标题摘要”的窗口计算 `titleDigest`：先收集当前规则需要的摘要集合，
  命中集合的标题才哈希；其余窗口传 `nil`。
- 不改变 `ProtectedWindowRef.matches` 的匹配语义。

验收：
- 窗口规则、区域规则、`rememberWindowTitle` 的匹配测试保持通过。
- 没有标题规则的场景下不再计算任何标题哈希。

## 第 5 项：OCR 降采样与指纹成本下降

现状：
- `LocalTextAnalyzer` 直接对原始 `CVPixelBuffer` 跑 `.accurate` OCR。
- `FrameFingerprint.digest` 对每一行、每个像素做 SHA-256。

改动：
- 在分析队列上先把帧降采样到适合文本识别的尺寸（长边上限 2048 px，保持宽高比；
  小图不放大），再对降采样后的缓冲区计算指纹并执行 OCR。
- 指纹仍覆盖它实际输入的全部像素，保证“OCR 看不到的变化不触发重扫、OCR 能看到
  的变化必定触发重扫”。
- `FrameFingerprint.digest` 的既有逐像素语义保持不变（现有单像素测试继续通过）。

验收：
- `LocalTextAnalyzerTests` 的 Vision 检测与区域换算保持通过。
- `FrameFingerprintTests` 的单像素敏感性保持通过。
- 大分辨率帧的指纹与 OCR 输入像素数显著下降。

## 非目标

- 不做第 6 项 `@Published` 写入去重/状态栏重建优化。
- 不改变任何用户可见的规则语义、警告延迟、模糊半径或快捷键行为。
- 不引入新的第三方依赖。
- 不为了性能降低保护覆盖范围或放宽权限检查。

## 验证与证据

```sh
./scripts/test.sh
QUIETGLASS_DESKTOP_TESTS=1 QUIETGLASS_TEST_DESKTOP=interactive \
  swift test --build-system native --scratch-path .build/desktop-tests/swiftpm \
  --filter RuleApplicationIntegrationTests
bash build.sh "$HOME/Downloads/QuietGlass.app"
```

交付：最新应用包固定放在 `~/Downloads/QuietGlass.app`，覆盖旧包。
