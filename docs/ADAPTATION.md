# iOS 与 iPhone Duo 适配说明

核对日期：2026-11-03。本文区分代码设计与设备验证，不能替代 Xcode 构建记录或真机测试报告。

## 支持范围

| 环境 | 设计行为 | 验证要求 |
| --- | --- | --- |
| iOS 18–25 | SwiftUI 原生导航、系统材质回退、窄屏布局 | Mac 上构建并运行 iOS 18 模拟器/设备 |
| iOS 26 及以上 | 系统导航栏和标签栏采用新版外观；自定义关键操作使用可用性保护的 Liquid Glass | 用 Xcode 26 或更高版本编译，运行 iOS 26 |
| iPhone Duo 外屏 | 按可用宽度提供单栏操作 | 外屏竖屏与横屏验证 |
| iPhone Duo 内屏 | 宽布局显示侧栏和内容；适应连续尺寸变化 | 使用支持该设备的 Xcode 27.1 或更新工具，验证展开、半折与多任务 |

最低部署目标为 iOS 18.0。Xcode 26+ 是基础工程的构建要求；设备模拟器与设备支持包可能要求更新的 Xcode。Windows 没有 Apple iOS SDK，交付时不能宣称已通过 Xcode 或 Duo 真机验证。

## Liquid Glass

优先使用 `TabView`、`NavigationStack`、`NavigationSplitView`、系统工具栏与表单。使用新 SDK 编译后，这些系统控件会在新版系统中获得相应外观。避免为系统导航栏强制覆盖不透明背景；课表、成绩和正文采用便于阅读的内容表面。玻璃用于操作与导航层，避免给所有内容卡片叠加效果。[Apple：Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

自定义操作表面的分支写法：

```swift
@ViewBuilder
func operationSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if #available(iOS 26.0, *) {
        content()
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    } else {
        content()
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
```

`glassEffect(_:in:)` 从 iOS 26.0 可用；默认玻璃为 `.regular`。需要触摸响应的自定义操作可使用 `.regular.interactive()`。同一组多个自定义玻璃控件可使用 `GlassEffectContainer`。这些符号必须由支持相应 SDK 的 Xcode 编译；运行时的 `#available` 不会让旧 SDK 认识新符号。[Apple：glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))、[Apple：Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

系统效果会响应减少透明度、减少动态效果等设置。自定义表面仍需检查这些设置下的文字对比度；必要时用不透明系统背景代替材质。可选的 `.tabBarMinimizeBehavior(.onScrollDown)` 同样需要 iOS 26 可用性判断。[Apple：tabBarMinimizeBehavior](https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:))

## iPhone Duo 布局策略

采用本地 `GeometryReader` 的可用宽度与 size class 决定布局；`720pt` 是本工程的界面断点，并非某个机型的固定尺寸。窄窗口使用标签页与单栏导航，宽窗口使用 `NavigationSplitView` 展示功能侧栏及内容。无需判断设备名称、屏幕分辨率或手机/平板 idiom。不要使用 `UIScreen.main.bounds` 决定界面，也不要把横竖屏方向当成内容宽度。Apple 将 Duo 外屏视为紧凑水平空间，内屏提供常规空间，标准导航容器能够随开合调整。[Apple：Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)

账号、缓存、学期、周次和功能选择应由根级应用状态持有，不能只保存在被宽度分支替换的子视图中。这样切换显示区域后仍能恢复正在查看的内容。前景操作遵守安全区域；只有装饰背景可以延伸到屏幕边缘。动态字体较大时，优先允许换行和纵向排列，而不是压小字体或挤占按钮点击区域。[Apple：Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)

本工程基础代码不引用 iOS 27.1 的 `ReservedRegion` 或 `ArrangementView`，以保留 Xcode 26 SDK 构建能力。标准导航容器能处理其所在区域的系统保留空间，但自定义课表、滚动行和网格在半折状态可能仍需额外调整。因此此版本属于自适应布局实现，不能等同于已经验证全部折叠姿态。后续若实测内容跨越折痕，应在升级 SDK 后评估保留区域处理；不要硬编码铰链位置。[Apple：ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion)、[Apple：ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview)

## 必须在 Mac/设备执行的验收

- [ ] Xcode 26+ 构建 iOS 18 与 iOS 26 配置，确认 iOS 18 不执行新增玻璃 API。
- [ ] 窄屏、横屏、宽屏与窗口连续缩放；重点检查 719/720/721pt 附近。
- [ ] Duo 外屏与内屏之间反复切换，确认登录状态、周次、学期、当前功能及已加载数据保留。
- [ ] Duo 完全展开、书本半折、笔记本半折和系统多任务；检查课表文字、成绩行、浮动操作与安全区域，确认折痕和摄像头不遮挡主要内容。
- [ ] 侧栏折叠/展开、返回、弹窗和键盘出现时，不丢失选择且可以完成操作。
- [ ] 最小与最大辅助功能字体、粗体、增加对比度、减少透明度、减少动态效果、浅色/深色模式。
- [ ] VoiceOver 可读出图标按钮、课名、时间、成绩和错误状态；操作具有至少 44pt 的易点击区域。
- [ ] 后台返回、会话过期、离线缓存及重新登录不造成重复网络请求或旧数据归属混淆。

只有执行并记录这些步骤后，才能对具体系统和具体设备给出“已验证兼容”的结论。
