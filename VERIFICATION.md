# 验证记录

日期：2026-11-03（Asia/Shanghai）。环境：Windows，无 Swift 编译器、Xcode、Apple SDK、iPhone 模拟器和学校登录账号。

## 实际执行

| 检查 | 结果 |
| --- | --- |
| Xcode 工程、源文件清单与资源引用 | 通过：13 个 App Swift 文件，PocketCore 本地包，4 个资源条目 |
| PBX 对象引用与独立 OpenStep 解析 | 后续已加入 UI test target；最新结果见文末记录 |
| Info/Privacy plist、Assets/Fixture JSON、Scheme/Workspace XML | 通过 |
| Swift 文件的 tree-sitter 语法树 | 通过：无 ERROR 或 missing 节点。后续新增 UI tests 的结果见文末；此检查不解析 Apple API 类型，不等同于 Swift 编译 |
| 实际交付的 EcardBridge.js | Node 内置测试运行器，16/16 通过 |
| 许可证 | 原项目 MIT 原文保留在 LICENSE 与 App/Resources/ThirdPartyNotices.txt |
| 数据/会话/提醒静态复核 | 修复演示通知、退出后的异步通知提交、旧请求重写 Cookie、部分课表混合重复、金额余额估算天数等问题 |

电费脚本测试包含：受限来源/主框架、真实零余额、缺失余额、非成功响应、dateTime、排序去重与日期校验、先明细后余额、旧房间响应、fetch 与 XHR、分页请求、令牌不进入消息、全部月份完成标记、合法空明细、失败/截断未完成、余额变化后的重新同步。

tree-sitter、Swift grammar 与 OpenStep 解析器安装在本地可选 `.tools/python`，不属于 App 运行时，也不进入源码交付压缩包。Mac 上使用 Xcode/Swift 原生检查。

## 已提供但未执行

- PocketCore 的 27 个 XCTest 方法和 3 个脱敏/合成 JSON 样例，覆盖校历、周日归属、学期末周日、课表总表回退、绩点范围/缺失值、研究生连续节次、响应异常、认证过期、表单编码等。
- `tools/verify-mac.sh`：资源检查、`swift test`、网页脚本测试、iOS Simulator 编译。
- `.github/workflows/ios.yml`：Mac CI 配置。本次没有推送仓库、触发 CI 或取得远端构建结果。

## 仍需完成的验收

1. Xcode 26+ 原生编译与类型检查，执行 XCTest。
2. iOS 18 与 iOS 26 模拟器/真机运行，核实旧系统材质回退与新系统 Liquid Glass。
3. 学校本科、研究生和一卡通真实账号联调；核对课程/分数/电量、SSO、验证码、绑定房间及过期重新登录。
4. 用支持 Duo 的 Xcode 27.1+ 检查外屏/内屏/半折/旋转/键盘/安全区域及界面状态保留。
5. 大字体、VoiceOver、减少透明度、深浅色、离线、通知授权拒绝、退出与切换账户。
6. 选择开发 Team 和唯一 Bundle Identifier，真机签名安装；如需分发，再完成相应签名与商店要求。

交付为实现首版源码，不能据本记录声称 App 已通过 Apple 编译、可直接安装、完成学校生产联调或已经验证 Duo 全姿态兼容。完整设备验收表见 docs/ADAPTATION.md。

## 后续：GitHub Mac 验证准备

- 新增 `GZUCMPocketUITests` target、四项演示 UI smoke tests 与自动截图，调试启动参数不进入 Release 功能。
- 更新工程检查：13 个 App Swift 源文件、1 个 UI 测试源文件、66 个 PBX 对象，独立 OpenStep 解析通过；20 个 Swift 文件语法解析通过。
- 新增模拟器选择工具：24 项 Python 测试已在 Windows 执行通过，严格选择指定 iOS 主版本和设备类型。
- 工作流 YAML 已通过解析和矩阵/权限/产物规则检查；Shell 完整语法树无错误，5 段嵌入 Python 通过语法检查。未在 Windows 执行 Bash 或 Apple 原生工具。
- Actions 现配置三个明确环境：`macos-15/Xcode26.3/iOS18`、`macos-26/Xcode26.6/iOS26`、`xcode-27/Xcode27.1/iPhone Duo`。镜像列出设备不等同于本账号实际运行通过。
- 当前尚未取得远端构建结果。需在仓库确认私有可见性并上传工作流后触发，不提前填写原生成功结论。
