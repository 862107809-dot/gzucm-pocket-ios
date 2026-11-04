# 广中医口袋 · iOS

基于 [Hello-Minecraft/gzucm-pocket](https://github.com/Hello-Minecraft/gzucm-pocket) 的原生 SwiftUI 移植首版。最低部署版本 **iOS 18.0**，iOS 26 使用系统 Liquid Glass，自适应窄屏、宽屏与 iPhone Duo 内外屏空间变化。

**交付状态：原生源码工程已上传至私有仓库，并已在 GitHub Mac 上通过 Xcode 编译与模拟器测试。** 最终代码已在 iOS 18.6 / iPhone 16e、iOS 26.2 / iPhone 17 Pro Max、iOS 27.1 / iPhone Duo 三组模拟器通过编译及四页、五种场景的界面测试。实际结果见 [验证记录](VERIFICATION.md) 和 [Actions 运行](https://github.com/862107809-dot/gzucm-pocket-ios/actions/runs/41775415155)。学校账号联调、实体设备和签名分发仍待完成；此目录不含可直接安装的签名 IPA。

## 已实现

| 模块 | 行为 |
| --- | --- |
| 今日 | 当日课程、后续课程、本周节次与宿舍电量入口 |
| 本科课表 | 学校校历、按周课程、真实日期、上课内容、教师、地点、学期总表回退 |
| 研究生 | 独立网页登录、学期选择、按周网格解析、连续节次合并、成绩适配器 |
| 课表界面 | 日视图、可横向滚动的周网格、重叠课程分列、周次选择、课程详情、照片背景 |
| 成绩 | 课程/等级/体测/考试、课程搜索、学期筛选、参考绩点与学分 |
| 宿舍电费 | 可见的学校网页、房间绑定、余额与逐月分页明细读取、趋势图、近 7 天估算 |
| 系统适配 | 深浅色、大字体回退日视图、VoiceOver 标签、减少透明度、iOS 26 玻璃控件 |
| 本地功能 | 离线缓存、默认启动页、用户主动开启的上课提醒与低电量提醒、退出清理 |
| 演示 | 明确标识的虚构示例；不持久化，不参与课程/电量通知 |

原项目参照提交：`b36a8a7846a2d685d8d37a473032c360d35210ed`。保留 MIT © 2026 朱致辉，见 [LICENSE](LICENSE) 和应用内第三方声明资源。iOS 工程使用相同 MIT 许可。

## 在 Mac 上运行

1. 解压整个目录，使用 **Xcode 26 或更新版本**打开 `GZUCMPocket.xcodeproj`。若要使用 iPhone Duo 模拟器/真机，使用支持该设备的 **Xcode 27.1 或更新版本**。
2. 选择 `GZUCMPocket` Scheme 与 iPhone 模拟器，点击运行。工程只依赖仓库内 `Packages/PocketCore`，不需要 CocoaPods、第三方 SDK 或 XcodeGen。
3. 首屏点「先看看演示」即可查看虚构样例。连接真实数据时，在「设置与账户」选本科/研究生，再点「登录教务」，在学校网页完成认证与验证码。
4. 电费页点「连接一卡通」，在可见网页中完成认证/房间绑定。成功分页后会显示同步状态；只有完整明细才参与低电量提醒。
5. 真机运行时，在 target 的 **Signing & Capabilities** 中选择自己的 Team，并把 `com.example.gzucm.pocket` 改为自己唯一的 Bundle Identifier。签名和分发操作在 Mac 上完成；仓库没有签名密钥、证书或账户信息。

初次学校登录可受校园网、VPN、学校单点登录策略影响。请将显示结果与学校网页核对。不要把学校密码、Cookie 或真实响应提交到 Git。

## 验证

Mac 上一次执行：

```sh
bash tools/verify-mac.sh
```

该脚本检查工程资源，运行 `PocketCore` XCTest、网页桥接与 Python 工具测试，再在指定模拟器执行四页原生 UI 测试并保留截图。开发主机为 Windows，Apple 原生步骤已交由 GitHub Mac 实际执行，结果记录在 [VERIFICATION.md](VERIFICATION.md)。GitHub Actions 配置位于 `.github/workflows/ios.yml`，提供 iOS18、iOS26 与 Duo 三条任务。选型、工具链清单和结果阅读方式见 [GitHub Mac 验证说明](docs/MAC_VERIFICATION.md)。

独立检查命令：

```sh
python3 tools/verify_project.py
node --test App/Web/Tests/EcardBridge.test.cjs
swift test --package-path Packages/PocketCore
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
xcodebuild -project GZUCMPocket.xcodeproj -scheme GZUCMPocket \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

工程已包含生成结果。增加/删除 App Swift 源文件后，可运行 `python3 tools/generate_project.py` 更新 Xcode 文件列表。生成脚本只需 Python 标准库；重绘图标的可选 `tools/make_icon.py` 需要 Pillow。

## 课表字号预览

普通启动跟随系统字号。验证产物中 `schedule_...png` 为普通字号课表，`schedule-large-text_...png` 是专门启用 `.accessibility3` 的辅助大字测试；请用前者查看默认布局。两种场景已分别通过 Duo 模拟器验证。

## 适配和已知边界

- iOS 26 新符号均位于可用性分支中，iOS 18 采用系统材质。系统导航采用原生 `TabView` / `NavigationStack` / `NavigationSplitView`。[Apple Liquid Glass 文档](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- 720pt 是本地窗口布局断点，不是设备尺寸常量。展开/收起切换时，账户、当前功能、周次、日期和成绩筛选保存在根状态。较小内容区显示日课表，周网格可横向滚动。此版本未引用 iOS 27.1 的特殊保留区域 API；半折姿态、折痕与摄像头避让仍需实际测试。[Apple iPhone Duo 适配视频](https://developer.apple.com/videos/play/tech-talks/111461/)
- 研究生接口沿用上游的 20 周窗口假设，通过带日期的课程推断校历；无带日期课程时会明确报错。研究生成绩字段映射未经真实账号验证，不显示研究生汇总绩点。
- 部分同步失败时显示提示；同学期有缓存则保留失败模块。课表按完整缓存整体保留，避免把新旧课程混合成重复安排。首次读取遇到部分周次失败，仍会明确提示数据不完整。
- 电费使用网页自己的参数与认证会话，不猜测签名。页面变动可能导致读取失败，此时保留缓存并提示。余额为「元」时不按电量估算天数；缺失或失败的余额不会作为零余额保存。
- 自动教务同步只发生在 App 前台，最短间隔 4 小时。电费需打开可见网页读取；没有关闭 App 后持续抓取的后台服务。课程通知在同步后安排未来 7 天内最多 50 条，须主动授权。
- 学校账号端到端、iOS 18/26 实机、Duo 外屏/内屏/半折和最大辅助字体检查均待执行，详见 [适配验收清单](docs/ADAPTATION.md)。

## 隐私设计

密码仅在学校网页输入，应用不读取登录表单。教务客户端使用临时会话 Cookie 容器；学校网页会话由 WebKit 管理。只缓存显示所需的课表、成绩与电费字段，缓存启用系统文件保护并排除备份。退出登录清理这些缓存、课表背景、WebKit 数据、原生会话及本应用通知。

所有学校业务请求使用 HTTPS，未开放全局不安全网络访问。脚本消息只接受一卡通 HTTPS 主框架，限制响应来源并避免持久化 Token。无广告、埋点或第三方运行时 SDK。隐私清单位于 `App/Resources/PrivacyInfo.xcprivacy`，使用应用自身偏好的 UserDefaults 原因声明；提交商店前仍需按实际分发行为核对隐私表单。

本项目非学校官方应用，与广州中医药大学无隶属关系。使用学校系统时应遵守其规则，避免高频请求。

## 目录

```text
App/                      SwiftUI 页面、根状态、通知与 WebKit
App/Resources/            电费桥接、图标、隐私声明与版权声明
Packages/PocketCore/      Foundation 模型、教务接口、解析器、XCTest 与脱敏样例
GZUCMPocket.xcodeproj/    可直接打开的 Xcode 工程与共享 Scheme
tools/                    工程生成、资源检查与 Mac 验证脚本
docs/                     系统/设备适配说明与验收清单
Tests/                    原生 App UI smoke tests，使用虚构演示数据
VERIFICATION.md           实际检查结果与未执行项目
```
