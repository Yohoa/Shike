# Maccy 2.7.1 本地内存审查

日期：2026-10-21。来源：官方 tag 2.7.1 源码压缩包，非完整 Git checkout。
未修改源码、未替换应用、未读取剪贴板历史内容。

## 1. 高置信：Observation 回调强引用形成保留环

Maccy/Observables/HistoryItemDecorator.swift:190–211
Decorator 强持有 HistoryItem；其 Observation 监听回调又强捕获 Decorator（self）。
当 pin/title 不变化时，监听保持注册，没有外部引用的 Decorator 也可能继续存活。
构造时注册两个监听；普通删除的 cleanupImages 只清图像，没有断开这些监听。
load() 重建 Decorator 也没有显式拆除旧监听。

同机最小实验使用 @Observable 模型与 withObservationTracking，去除所有外部强引用后：
strong capture: object released = false
weak capture: object released = true

这证明该引用机制可泄漏；未对完整运行中的 Maccy 做堆对象归因，因此无法确认其贡献的 MB 数。
建议两个 onChange 都使用 [weak self]，内部主队列闭包也弱捕获，再更新属性与重新注册。

## 2. 明确保留风险：重复项替换遗漏 sessionLog 清理

Maccy/Observables/History.swift:60, 144–177, 284
每次 add 都向 sessionLog[changeCount] 强持有新 HistoryItem。
重复项分支删除旧模型、从 all 移除，但没有像普通 delete 那样从 sessionLog 移除旧值。
因此重复复制同一项时，旧键与旧模型的保留没有相同的清理路径；历史条数上限不直接限制这些键。
需要结合 SwiftData 删除后的对象状态，进一步验证保留的数据规模。
建议替换时清掉指向旧对象的索引，或设计有界会话索引并保留 modified 语义。

## 3. 明确图片保留策略：原图、缩略图和预览长期缓存

Maccy/Models/HistoryItem.swift:77,167–176 缓存 NSImage。
Maccy/Observables/HistoryItemDecorator.swift:45–50,121–145 保存缩略图与预览。
Maccy/Extensions/NSImage+Resized.swift:28 延迟绘制回调捕获原图 self。
因此 resized 不是立刻生成独立小位图，而是返回仍引用原图的绘制对象。
关闭弹窗或行消失时没有图像清理路径；cleanupImages 主要在删除、清空与尺寸设置改变时执行。
这可导致看过的图片持续保留，是高内存原因，单独并不证明泄漏。
建议生成独立缩略位图、用有成本上限且可驱逐的缓存，按可见性/内存压力释放预览。

## 附带功能问题

cleanupImages 取消 task 但不把两个 task 属性设为 nil。
ensureThumbnailImage/ensurePreviewImage 用 task != nil 阻止再次创建任务。
因此已执行过任务后清理图像，可能无法再次通过 ensure 路径生成图像。

## 验证范围

已完成：官方 2.7.1 静态审查、同机 Observation 强/弱引用最小对照实验。
未完成：完整应用构建、自动化复制复现、堆快照/泄漏归因、修复回归。
原应用 footprint 曾为 673 MB，重启后 168 MB；这些读数不能独立证明每个问题的贡献。
