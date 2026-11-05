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

## 一卡通「登录一次，前台自动查询」— 2026-11-05

**适用范围：原生 iOS App；不等同于 Safari 网页自动登录。**

- 首次在「电费 → 连接一卡通」打开的学校官方 HTTPS 网页完成登录、房间绑定并成功读取一次余额。学校密码、验证码、扫码与多因素验证仅在官方可见页面进行；App 不代输或保存这些凭据。
- 使用同一个 App 专属的 `WKWebsiteDataStore.default()` 保存校方登录 Cookie，后续打开 App 时会尽量复用该会话。在 App **前台**且已成功连接过一卡通时，余额超过 4 小时会尝试通过学校 HTTPS 页面自动读取；可以在电费页主动点「自动刷新」。用户可在「设置 → 一卡通自动同步」关闭。
- 桥接脚本只在 `https://ecard.gzucm.edu.cn/user/powerfee/` 顶层页面运行；采用校方页面自身已绑定的房间与 Token，通过同源只读接口查询。Native 端只保存余额、单位、宿舍标签、有效每日用量、更新时间与最近 90 天的每日余额记录，不保存密码、Cookie、Token 或身份证号到电量记录中。余额记录不用于反推日耗，避免充值造成误判。
- 若校方跳转到独立登录认证页面或登录失效，停止自动查询，并在电费模块提示用户**重新登录**；自动读取不会绕过学校验证码、扫码或双重认证。
- iOS 可能暂停页面/后台任务，因此**无法承诺 App 退出或锁屏时每 4 小时执行**；必须启动或恢复前台才有机会查询。校方是否允许 WebKit 会话长期复用、会话失效时间以及真实宿舍接口行为都需要使用个人授权账号真机核验。
- 当前`gzucm-pocket-web`公开 Safari/PWA 网站与此 iOS 原生版本相互独立。**网页版自己不能通过跨域方式读取学校的 HttpOnly Cookie，尚未建立学校批准的服务器端一卡通认证回调。** 如只使用网页，不能保证自动获取余额；请勿向公开站点粘贴校园 Cookie。

### 推送电量到 Safari 网页（双端配对）

已有一次性配对和只读结果推送通道：

1. 原生 App「电费 → 一卡通」在校方网页完成首次登录和房间绑定，并确认成功读取余额。
2. 用 Safari 打开**你实际部署的广中医口袋 Web 站点**，前往电费页，点击「生成设备配对码」。
3. App「设置与账户 → 网站配对与电量同步」填写该网页的完整 HTTPS 域名和 12 位配对码，点击「连接网页版电量记录」。
4. App 将服务器发放的**只读电量推送凭据**和对应的 HTTPS 站点绑定后存入 iOS Keychain（不存于普通 UserDefaults）；后续本机读取电量时，向被用户批准的网页推送余额、房间标签、每日用电量和数据时间。网页不接收校方密码、Cookie 或 SSO Token。
5. App 前台自动检查原有学校登录（最短 4 小时一次），无法通过学校校验时要求在**可见学校网页**重新认证。网站显示最近的推送记录及预计可用天数，并保存本地历史快照。

注意：配对码有效期 5 分钟；Web 端当前使用临时内存保存配对，Render 休眠、重启或约 30 天到期都可能导致失效，需要重新配对。**不能保证 iOS 锁屏或关闭 App 后依然自动查询**，也不能替代学校认可的独立网页版 SSO 授权。账号登录必须始终发生在真实学校域名。

### App Store 交互细节（2026-11-05）

- iPhone 底部保留**系统 SwiftUI TabView**，由支持的 iOS 版本直接呈现 Apple 原生标签栏和 Liquid Glass，避免私自重写系统标签栏导致可访问性、视图大小、键盘或滚动行为退化。
- 页面内按钮增加弹簧按压样式，针对**整个按钮标签及背景表面**缩放，而不是仅放大文字；切换原生 Tab 时使用系统选择触觉反馈。用户设置了「减少动态效果」时，关闭按压缩放。
- 课表周次到达第一周／最后一周后，继续触碰左右箭头会出现最多 7pt 的阻尼位移和对应方向短暂柔光，再弹回原位，不再仅是无响应的灰色按钮。屏幕阅读器会说明已到边界。

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
- 自动教务同步只发生在 App 前台，最短间隔 4 小时。电费首次需打开可见网页进行认证，成功授权后前台可复用 WebKit 会话按需检查；没有关闭 App 后持续抓取的后台服务。课程通知在同步后安排未来 7 天内最多 50 条，须主动授权。
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


## 原生界面：网站设计适配

iOS / iPadOS 26 以上的自定义选项使用 Apple `glassEffect`、`GlassEffectContainer` 和 `glassEffectID`。系统 TabView、菜单和导航保留原生行为；iOS18–25 使用 Apple Material 毛玻璃。开启减少透明度时改为实底，减少动态效果时停止放大和弹性动画。正文卡片使用较轻的 Material 保持阅读对比。

课表增加日 / 周 / 月切换和可拖动玻璃选择器。周与月从星期日开始显示，内部官方教学周仍按原数据计算；月历以课程点和 +N 保持紧凑，点击后显示当天全部课程。设置与课程详情使用同一玻璃弹窗，页顶标题居中。

保留当前版本的学校登录、课程/等级/体测/考试、Cookie 连接的一卡通与自动刷新功能。Mac 使用 Mac Catalyst 目标，iPad / 宽窗口使用侧栏，窄窗口使用原生底部导航。GitHub Mac 验证包含 iOS18、iOS26、iPad、Duo 及 Mac Catalyst 编译；实际状态以该次工作流结果为准。


## 教务登录、消息与电费

本科登录提供原生微信二维码和学校官方账号密码页面两种方式。二维码使用学校 qrcode/qrcodeStatus 接口，只有完成跳转并确认受保护教务接口后才交给 App；扫码结果写回本设备 WebKit 会话，密码由学校网页处理，App不读取或保存。二维码五分钟过期，切换方式或关闭窗口会取消，后台期间暂停轮询。研究生仍使用官方密码页面。

消息页在 App 内打开已登录的学校官方页面，只从学校实际提供的菜单定位消息入口。原项目没有可核实的消息JSON协议，因此不显示虚构的列表、未读数量或“暂无消息”。

电费的“立即读取电量”通过已授权的一卡通页面直接读取，不依赖自动刷新开关。教务二维码不等于一卡通授权；学校要求重新认证或宿舍绑定时，仍在官方页面操作。旧读数保留并标记时间，缺失数据不补零。
