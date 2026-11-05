# 验证记录

记录日期：2026-11-04（Asia/Shanghai）；各次执行的 UTC 时间保留在产物中。开发主机为 Windows，Apple 原生构建与测试通过 GitHub 托管 Mac 实际执行。

## 本次原生验证

- 私有仓库：[862107809-dot/gzucm-pocket-ios](https://github.com/862107809-dot/gzucm-pocket-ios)。上传源码前已确认私有可见性。
- 被测代码提交：`65bcc168bea5514309113e3b8f94d3364085d5e6`。
- [GitHub Actions 运行 41775415155](https://github.com/862107809-dot/gzucm-pocket-ios/actions/runs/41775415155)。最终回归状态见下表；未用此前提交的结果替代本次结果。

| Runner / Xcode | 实际设备 / 系统 | 结果 |
| --- | --- | --- |
| macos-15 / Xcode 26.3，Simulator SDK 26.2 | iPhone 16e / iOS 18.6 | 通过 |
| macos-15 / Xcode 26.3，Simulator SDK 26.2 | iPhone 17 Pro Max / iOS 26.2 | 通过 |
| xcode-27 / Xcode 27.1，Simulator SDK 27.1 | iPhone Duo / iOS 27.1 | 通过 |

每条成功任务实际执行：工程及 plist 检查、26 项 Python 工具测试、29 项宿主 Mac 上的 PocketCore XCTest、16 项电费网页桥接测试，以及 App 编译和 5 项原生 UI 测试。各类测试独立计数，三台环境重复执行不会被当作更多独立用例。UI 测试使用虚构演示数据，不进行学校登录。

五个 UI 场景为「今日」「普通字号课表」「辅助大字体课表」「深色成绩」「深色电费」。普通字号课表另检查周次控件不超过100pt，三组实测均约50.7pt。断言检查演示提示具有可见屏幕区域、恰有一个可命中的登录按钮、主要页面标识可命中。测试在断言前保存原始截图和控件树。该覆盖验证了应用启动及指定元素；没有遍历全部交互或检查所有滚动内容。

## 证据与截图复核

每条任务的 artifact 包含 `status.json`、`selected.json`、模拟器完整清单、Xcode/SDK 版本、测试日志、原生 `.xcresult`、截图和控件树。工作流保留产物 14 天，可在上述 Actions 运行页面下载；证据到期后需重新运行。后续纯文档提交不会触发原生回归，应以此处记录的代码提交定位结果。

本次运行总体结果为 **success**，三个 job 均为 **success**。已下载三个最终原始产物，并逐一核对 GitHub 返回的 SHA-256；日志中的各类用例数与 `status.json` 均一致。实际版本、设备、完整状态和原始截图散列见 [机器可读证据摘要](docs/verification-run-41775415155.json)。

本轮保留15张首屏原图，新增的三张普通字号课表已人工复核：日期、周次与课程信息的大小和层级正常，三组周次控件高度均约50.7pt；没有出现辅助大字号截图中的整页放大。普通字号用例未传 `--large-text`，生产代码继续跟随系统字号。

此前 Duo 课表预览来自专门传入 `--large-text` 的 `.accessibility3` 测试，不能代表默认外观。本轮普通课表附件为 `schedule_...png`，大字体附件为 `schedule-large-text_...png`，两者分别保留。此次修改为补全验证和预览说明，没有缩小用户主动选择的辅助字体。

前一运行41772998925的12张首屏截图已人工检查日期、横幅和时间换行修复；本轮相关原生断言亦成功。复核范围限于截图可见区域，不代表整个图表、全部滚动内容或 Duo 所有折叠姿态都已验收。

前几轮真实执行中修复了两类构建/工具问题：模拟器 runtime 标识省略版本末位时的选择失败，以及 App Debug 同时编译 x86_64/arm64 与本地包活动架构不一致。截图复核又修复了演示横幅遮住导航标题、辅助大字体使时间数字分行的问题。另已修复海外时区下学校日期提前一天与周范围说明对比度不足的问题，电费日期分箱和刻度也统一为学校时区，新增两项跨时区测试。UI 测试改为对真实登录按钮检查可命中性，对被动提示文字检查可见区域。

## 测试覆盖与本地检查

- PocketCore：校历、周日归属、学期末边界、课表总表回退、绩点范围/缺失值、研究生连续节次、异常响应、认证过期、表单编码等。29 项 XCTest 已在远端 Mac 实际执行。
- 电费桥接：HTTPS 来源与主框架限制、真实零余额/缺失余额、非成功响应、日期校验、排序去重、先明细后余额、旧房间响应、fetch/XHR、分页、令牌不进入消息、完整月份标记、失败/截断、余额变化后重新同步。16 项测试已实际执行。
- Python：26 项严格模拟器选择测试，包括普通 iPhone 与 Duo 区分、指定系统主版本、runtime 标识与版本前缀一致性。
- Windows 检查：13 个 App Swift 与 1 个 UI 测试源文件的 target 成员关系、资源/JSON/XML/plist、66 个 PBX 对象及独立 OpenStep 解析；20 个 Swift 文件 tree-sitter 语法解析；工作流和 Bash 语法解析。语法解析不替代编译，原生编译结论来自 Mac CI。
- 原项目 MIT 许可证和第三方声明已保留。可选解析器位于本地 `.tools/python`，不进入 App 或源码包。

## 尚未验证

1. 本科、研究生、一卡通真实账号端到端联调；核对课程、成绩、余额、分页、SSO、验证码、房间绑定、会话过期及重新登录。
2. iOS 18.0 本身与实体 iPhone；已执行的旧系统 runtime 是 iOS 18.6。部署目标 18.0 不等于逐一实测所有版本。
3. 实体 Duo，以及外屏/内屏切换、书本/笔记本半折、折痕、摄像头避让、旋转、键盘和连续缩放。默认 Duo 模拟器截图不代表全部姿态。
4. 最大/最小辅助字号、VoiceOver、减少透明度/动态效果、全部页面与表单，以及真实离线/通知权限/账户切换。已测 `.accessibility3` 不等于最大字号。
5. Release 归档、真机签名安装、TestFlight 与 App Store 分发。CI 使用 Debug Simulator、`CODE_SIGNING_ALLOWED=NO`，没有签名 IPA。

上述范围以外的兼容性不由本记录保证。后续设备检查见 [ADAPTATION.md](docs/ADAPTATION.md)，Mac 环境选择与复现命令见 [MAC_VERIFICATION.md](docs/MAC_VERIFICATION.md)。

## 2026-11-05 native design update
New native Liquid Glass controls use Apple glassEffect / interactive / GlassEffectContainer / glassEffectID behind iOS26 and Mac Catalyst26 availability checks. iOS18 fallback uses system Material; reduce-transparency uses solid surfaces and reduce-motion disables magnification/spring. Native system TabView is retained. Added compact Sunday-first month grid and full selected-day course list; semester-end Sunday remains navigable. Settings and course sheets share native glass, with explicit light/dark/system preference. Mac Catalyst target and iPad CI lane added.
Local validation:18 JS bridge tests,34 Python tests,20 Swift syntax parses, independent OpenStep project structure passed. UI XCTest now includes month navigation in addition to five existing demo cases. These new native UI tests have NOT executed.
Cloud run42037531881 (simulators/Mac Catalyst) and42037531741 (device archive), source70a4286: all jobs failed before a runner was assigned, steps empty, no compiler logs and no artifacts. This is not evidence of a successful build or a diagnosed compiler failure. Connector cannot read annotation endpoints; browser navigation also timed out. No exact infrastructure/account reason has been confirmed. Windows has no Apple SDK/Xcode. Re-run after runner allocation is restored; do not present earlier screenshots or IPA as evidence for this UI revision.
Apple reference:https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
