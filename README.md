# Learningpak-mac-ci

iPad 学习 App 的源码镜像，用来试验把最低系统版本降到 iOS 18 后能否编译，以便在 macOS 15 的 Apple 芯片 Mac 上以「为 iPad 设计」方式运行（只用点击、拖动和键盘，不用手写）。

- 只包含源码（`Learning/`）、工程文件、`Info.plist` 和测试（`Tests/`），不含教辅内容。
- 最低版本在 `xcodebuild` 命令行用 `IPHONEOS_DEPLOYMENT_TARGET=18.0` 覆盖。
- `SOURCE_REV` 是对应的私有仓库提交号。
