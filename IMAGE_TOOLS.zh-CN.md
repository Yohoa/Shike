# 截图与图片工具（Local Fix 7）

状态：2026-10-26 已构建并安装到 `/Applications/Maccy Fixed.app`。112 项单元测试通过；真实桌面截图及界面操作仍待权限与人工验收。

## 开关与入口

设置 → 图片工具 → 启用截图与图片工具（默认关闭）。启用后，历史列表下方出现“截图”和“图片工具”。图片右键菜单也提供操作；多选图片时按选中顺序处理。快捷键在这个设置页自行指定，默认不占用系统快捷键。

关闭模块会取消待完成的操作、注销模块快捷键并关闭其窗口。没有后台截屏、索引、网络调用或独立常驻进程。已有 Maccy 的图片文字索引行为保持原样。

## 功能

- 区域截图：在任意显示器拖出区域，Esc 取消；Retina 按显示器比例输出。截图加入历史并打开标注窗口。
- 窗口截图：选择可见窗口进行捕获。
- 截图并识别文字：选择区域后运行本地 Apple Vision OCR；结果加入历史并复制，可在结果窗口核对编辑。
- 识别文字：对历史图片运行准确模式 OCR，支持中英文和语言自动检测。
- 识别二维码：显示并复制二维码内容，不自动打开链接。
- 标注：画笔、箭头、矩形、椭圆、高亮、文字、步骤编号、黑色遮盖、裁剪，支持颜色/线宽和撤销。
- 图片处理：旋转 90°、水平翻转、灰度、调整尺寸（可保持宽高比）。
- 贴到屏幕：可拖动、缩放的置顶窗口，支持透明度调整；关闭释放图片。
- 拼接：水平/垂直两种布局，多选按顺序排列；只选一张时通过文件窗口选其他图片。
- 前后对比 GIF：恰好两张图片，两帧循环切换，各停留 0.8 秒；不同尺寸保持宽高比居中，输出原始 GIF 数据并打开另存窗口。
- 复制图片：生成 PNG，复制并新增历史；原始历史不变。另存为输出 PNG，GIF 使用 GIF 格式。

## 限制与权限

- 截图使用 ScreenCaptureKit，仅在用户发起截图时请求系统“屏幕与系统音频录制”授权；系统许可由用户确认。
- 2026-10-26 用户明确同意将沙盒 `files.user-selected` 权限由只读改为读写，仅用于打开/保存窗口选择的文件。沙盒仍保留。
- 本地临时签名会随重建变化；系统若拒绝旧权限，需要在系统设置删除旧条目并重新添加本版本。自动粘贴权限与截屏权限是两项不同权限。
- 为限制内存，编辑图像最长边最多 4096 像素、贴图最多 2048；拼接输入总计与输出各最多 3200 万像素、单边上限 16384。超限显示错误，不强行分配。
- 同时最多 6 个工具窗口；变换撤销保留最多 3 张压缩快照，并限制快照总大小。裁剪/变换会烘焙已有标注。
- 不是 FlowShelf 全套 Screenshot Studio 的复刻；未加入其放大镜、标尺、渐变背景等本次未指定的扩展工具。

## 代码与验证

独立模块在 `Maccy/ImageTools/`：

- `ImageToolsModule.swift`：生命周期、开关、快捷键、菜单、结果/贴图窗口、拼接与导出。
- `WorkbenchCapture.swift`：ScreenCaptureKit 区域/窗口捕获，多屏覆盖选择器。
- `AnnotationEditor.swift`：标注/图片编辑与撤销。
- `ImageWorkbench.swift`：有界解码、像素处理、GIF、Vision OCR 和 QR。

原生拖动视图补上图片上下文菜单，Footer 补上模块工具栏，Settings 新增独立页。文案覆盖英文、简体中文、繁体中文。

参照 FlowShelf 的公开功能说明独立实现，未复制其受限源码或资源：<https://github.com/mahinkadery/FlowShelf>。

测试：`build/image-tools-tests.log`（112 通过）；发布构建：`build/image-tools-release.log`（成功）。新增 9 项测试覆盖像素顺序、GIF 帧/时间/历史兼容、损坏图片/超大输出、遮盖/裁剪/撤销、真实二维码、实际绘制文字 OCR、变换/编码、编辑模型释放。

旧应用备份：`/private/tmp/Maccy-Fixed-before-image-tools-20261026.app`（临时目录，可能被系统清理）。源码改动前备份：`build/before-image-tools-source/`。


## Local Fix 8 更新（2026-10-26）

图片工具启用后单击改为选中（不会复制后立即关闭）；悬停不会改变主动选择。Enter 粘贴，⌘/Shift 多选。已在实际界面确认图片选中后菜单可用、标注编辑器正常打开。新增历史的标题生成已修复。刘海模块说明见 `NOTCH.zh-CN.md`。

## OCR / 二维码结果方式（2026-10-26）
- 设置 → 图片工具 → “OCR 与二维码结果”：**复制到剪贴板**（默认）或 **复制并在窗口中显示**。保存在 `UserDefaults` 的 `localOCRShowWindow`，默认关闭。
- 两种方式都会把文字复制到剪贴板，并记入 Maccy 历史。默认方式不弹窗，只在当前屏幕顶部显示约 1.6 s 的玻璃 HUD：“✓ 已复制文字（N 个字符）”。HUD 不接收点击、不抢焦点。
- 英、简、繁三语已加。测试 123 项通过（`build/ocr-tests.log`）。实机截图 OCR 尚待用户确认。

## OCR 后闪退（2026-10-27）
- 崩溃报告 `~/Library/Logs/DiagnosticReports/Maccy-2026-10-27-010043.ips` 和 `-010338.ips`：AppKit 显示周期限制。窗口的 Update Constraints 次数超限后抛异常、终止程序。调用栈为 `NSHostingView.windowDidLayout → updateAnimatedWindowSize → setFrame → invalidateSafeAreaInsets → setNeedsUpdateConstraints`。
- Fable 子代理分析：窗口无 `.titled`，所以是主弹窗 FloatingPanel、ToastHUD 或 NotchPanel 之一；最可能是主弹窗 FloatingPanel。OCR 结果写入历史、`busy` 指示消失的同一轮里，仍在淡出（当天新增）的弹窗在 SwiftUI 动画中改变尺寸，SwiftUI 的窗口尺寸桥循环写回 frame。`sizingOptions` 不影响这条路径。两次单元测试复现均未成功，**根因未证实**。
- 修复：① `FloatingPanel.close()` 在图片工具 `busy` 时不淡出，直接关闭；② `AppDelegate` 注册 `NSWindowAssertWhenDisplayCycleLimitReached = false`，再遇到同类循环时只记录日志、不再终止程序；③ ToastHUD 改为固定尺寸（无害）；④ 新增回归测试 `PopupFadeOCRTests`、`ToastHUDTests`。125 项测试通过（`build/ocrcrash-tests.log`）。
- 备选的结构性修复（未做）：把 FloatingPanel 的 NSHostingView 放进一个容器 NSView 再作为 contentView，彻底退出 SwiftUI 的动画窗口尺寸路径。改动会影响主弹窗布局，需实机验证后再做。

## 区域截图与系统截图对齐（2026-10-27）
- 问题：原流程先激活 Maccy、弹出可成为 key 的遮罩窗口，再截图；其他应用打开的下拉菜单因此被关掉，截不到。
- 现在：先用 ScreenCaptureKit 把所有显示器各截一张完整图（排除 Maccy 自己的窗口），在这张定格图上框选，再按像素裁剪。遮罩改为不激活应用的 `.nonactivatingPanel`，去掉 `NSApp.activate`；区域模式不再等待 200 ms。窗口截图模式不变。
- 内存：每块屏一张全分辨率定格图，框选结束即释放。测试见 `build/freeze-tests.log`；实机菜单截图待用户确认。
