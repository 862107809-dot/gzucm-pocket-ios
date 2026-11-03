# GitHub 上的 Mac 环境与本工程验证

核对日期：2026-11-03。开源项目的功能描述与本工程的实际测试结果分别记录；没有拿到 Actions 结果前不能声称原生编译通过。

## 查找到的项目

| 方案 | 项目与适用性 |
| --- | --- |
| macOS 虚拟机 | [sickcodes/Docker-OSX](https://github.com/sickcodes/Docker-OSX) 使用 QEMU/KVM；README 要求 x86_64、硬件虚拟化，并提供 Windows 11 + WSL2/嵌套虚拟化路径。需要安装完整 macOS/Xcode，不能从能启动系统推断 SwiftUI 渲染或 Duo 兼容。 |
| QEMU/KVM 脚本 | [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) 提供 Linux 上 macOS 虚拟机的启动和安装脚本，需要主机虚拟化能力及相应系统镜像。 |
| macOS 兼容层 | [darlinghq/darling](https://github.com/darlinghq/darling) 在 Linux 实现 Darwin/macOS 兼容层，项目说明 Xcode 本身尚不能运行，不作为本 App 的 Apple SDK 验证环境。 |
| 已安装 Xcode 的云端 Mac | [actions/runner-images](https://github.com/actions/runner-images) 提供 GitHub Actions 虚拟机镜像的开源配置与软件清单，可直接运行 Xcode、XCTest 和 Simulator。本工程采用此方案。 |
| 已安装 Xcode 版本选择 | [maxim-lobanov/setup-xcode](https://github.com/maxim-lobanov/setup-xcode) 在 Actions 中选择预装的 Xcode，不自行模拟 macOS、不自动安装缺失版本。 |

Apple 的 [Xcode 27 说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)要求 Apple silicon Mac，相关主机系统要求见 [Xcode system requirements](https://developer.apple.com/xcode/system-requirements)。因此上述 x86 虚拟机不是 Duo/Xcode 27.1 的受支持验证路线。这里的选择依据是验证本 App 所需的工具链，而不是虚拟机能否显示 macOS 桌面。

## 已接入的三条 Actions 任务

| 任务 | Runner | Xcode | 必须实际存在的模拟器 |
| --- | --- | --- | --- |
| 旧系统回退 | `macos-15` | `26.3` | iOS **18** 普通 iPhone |
| Liquid Glass 系统 | `macos-26` | `26.6` | iOS **26** 普通 iPhone |
| Duo 布局 | `xcode-27` | `27.1` | iOS **27** 的 **iPhone Duo** |

配置位于 `.github/workflows/ios.yml`，上传至仓库后 push / pull_request 自动运行，也支持 Actions 页手动运行。

上述版本来自核对时的 GitHub 官方 [macos-15 软件清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)、[macos-26 软件清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)和 [xcode-27 软件清单](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)。GitHub 的 [2026-10-15 公告](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/)说明 Xcode 27 runner 已正式可用。镜像会更新，实际运行仍逐次采集工具链和模拟器清单；缺失指定系统或设备会明确失败，不能换成另一台设备后当作同一覆盖范围。

GitHub 托管运行器是云端 Mac 虚拟机，Windows 上无需安装虚拟 macOS。私有仓库的运行时间会使用账号的 Actions 配额；配额和计费取决于实际账号，见 [GitHub runner 说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。本工程没有购买服务或修改付费设置。

## 每条任务实际执行什么

1. 记录所选 Xcode、Simulator SDK 与完整 `simctl` JSON 清单。
2. 验证工程、资源、Info/Privacy plist、Scheme 与 UI 测试 target 引用。
3. 执行 Python 模拟器选择器测试、27 项 PocketCore XCTest，以及 16 项实际电费脚本测试。
4. 从实际清单中选出同一主版本和设备种类的模拟器，启动并等待启动完成。
5. 通过 `xcodebuild test` 编译 App 与 UI 测试 runner。四页分别用虚构演示数据启动，验证横幅与主要页面元素出现；其中包含深色模式与辅助大字体场景。测试不读取学校账户、不自动登录学校系统。
6. 保留编译日志、`.xcresult` 和截图附件。失败也上传已生成的证据；`status.json` 区分未开始、未运行、失败与通过。

实际入口：

```sh
bash tools/verify-mac.sh --os-major 18 --device-kind iphone
bash tools/verify-mac.sh --os-major 26 --device-kind iphone
bash tools/verify-mac.sh --os-major 27 --device-kind duo
```

脚本不修改全局 `xcode-select`，只使用已选工具链。不会安装操作系统、擦除模拟器、下载 Apple SDK 或替换缺失的覆盖目标。仅在自己启动了原先关闭的模拟器时，于退出时关闭它。

## 如何判断结果

在仓库的 **Actions → iOS simulator verification** 打开一次运行，检查三个任务的状态与日志。下载各任务的 `verification-ios...` artifact，其中包含：

- `status.json`：退出状态、运行阶段及每项检查结果。
- `inventory.json`、`selected.json`：实际系统与设备证据。
- `xcode-version.log`、`sdk-version.log`：实际工具链。
- `native-ui-tests.log` 与 `native-ui-tests-*.xcresult`：编译、断言与原生测试结果。
- `attachments-*`：测试截图；若导出失败，截图仍可在原始 `.xcresult` 中查看。

截图需要人工复核。页面成功启动不能证明 Liquid Glass 的每个视觉细节、大字体所有内容无截断，或 Duo 半折、折痕与摄像头的每一种姿态都适配。学校认证、真实课程、电量、通知权限和安装签名仍须后续验收。详见 [ADAPTATION.md](ADAPTATION.md)。
