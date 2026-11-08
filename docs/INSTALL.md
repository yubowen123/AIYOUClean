# 安装 AIYOUClean

当前提供 **0.6.2 / build 10，Apple Silicon（arm64），macOS 13+**。构建目标与实测平台不同：当前只在开发者本机 Apple Silicon/macOS 26.6.2 验证，未完成 Intel 或多个 macOS 版本回归。

## 下载后打开

1. 到 [GitHub Releases](https://github.com/yubowen123/AIYOUClean/releases/latest) 下载 `AIYOUClean-0.6.2-macOS-arm64.zip` 和 `SHA256SUMS`。
2. 如需校验，将两者放进同一目录，在该目录执行 `shasum -a 256 -c SHA256SUMS`。
3. 解压，将 `AIYOUClean.app` 拖进 `~/Applications` 或“应用程序”。升级前先让已有检测结束，退出旧应用。
4. 在 Finder 中打开应用。安装本身不会开始检测或删除文件。

## 终端便捷安装

安装脚本会获取 GitHub 最新正式版、检查下载文件的 SHA-256、ZIP 结构、bundle 标识、版本、arm64 架构及本地签名，然后安装到 `~/Applications/AIYOUClean.app`。可以先查看脚本再执行：

```sh
curl -fL https://raw.githubusercontent.com/yubowen123/AIYOUClean/main/scripts/install.sh -o /tmp/aiyouclean-install.sh
bash /tmp/aiyouclean-install.sh
```

也可以使用已下载的发布文件，或指定一个已经存在、当前账号可写的安装目录：

```sh
bash scripts/install.sh --local-zip /absolute/AIYOUClean-0.6.2-macOS-arm64.zip --checksums /absolute/SHA256SUMS
bash scripts/install.sh --destination /absolute/existing-directory
```

脚本不调用 `sudo`，不主动打开应用，不授予文件访问权限，不移除 quarantine，不修改 Gatekeeper/TCC/SIP。检测到目标安装路径中的 AIYOUClean 正在运行时会退出，留给用户结束任务并自行退出后重试。覆盖失败会尝试恢复此前的应用；备份无法恢复时会明确打印其保留位置。

## 首次打开与文件权限

当前发布包采用 **本地 ad-hoc 签名，尚未 Apple 公证**。签名检查只确认 bundle 内容自洽，不代表 Apple 已验证开发者身份。SHA-256 是下载完整性校验，也不替代可信发布来源。

若 macOS 拦截打开，先确认来自本仓库，再按“系统设置 → 隐私与安全性 → 仍要打开”完成系统确认；不要运行来源不明的“关闭安全检查”命令。参见 [Apple：安全地打开 Mac 上的 App](https://support.apple.com/zh-cn/102445)。

需要检查受保护目录时，在“系统设置 → 隐私与安全性 → 完整磁盘访问”手动添加正在使用的 AIYOUClean，再按系统要求重新打开并重扫。应用里的权限引导可定位当前版本路径。并非所有访问拒绝都来自完整磁盘访问权限；系统保护、ACL、不可读文件仍可能无法读取。参见 [Apple：控制 Mac 上 App 对文件的访问权限](https://support.apple.com/en-ng/guide/mac-help/mchld5a35146/27/mac/27)。

## 从源码构建

需要 macOS、Swift 5.9+ 和 Xcode Command Line Tools：

```sh
git clone https://github.com/yubowen123/AIYOUClean.git
cd AIYOUClean
bash scripts/build.sh
swift run --jobs 4 CleanRoomChecks
```

应用输出到 `dist/AIYOUClean-0.6.2.app`；CLI 为 `dist/aiyouclean-cli-0.6.2`。`build.sh` 根据构建机器架构生成二进制，本仓库当前发布包和安装脚本只支持 arm64。

## 打包与发布维护

已有已签名 app 时：

```sh
bash scripts/package-release.sh --app /absolute/AIYOUClean-0.6.2.app --output /absolute/new-release-directory
```

输出版本化 arm64 ZIP 和 `SHA256SUMS`，ZIP 内 app 使用稳定名称 `AIYOUClean.app`。脚本不改原 app、不安装、不上传；拒绝覆盖已存在的同名发布文件。发布时将两份文件一起上传到对应 `v0.6.2` Release。源码以仓库 tag 为准。

GitHub Actions 的 `macOS checks` 会在 macOS 14 runner 上运行 Core 行为检查、构建 app/CLI，并检查安装/打包脚本语法。CI 的真实结果以对应 workflow run 为准，配置存在不代表执行已经成功。

## 本次脚本验证

[隔离验证回执](install-checks.json)：11 个场景通过，包括实际已签名 bundle 打包、生成目录中的安装/替换、错误校验值、越界 ZIP、ZIP 符号链接、目标符号链接、非本应用目标、目标文件占用及重复打包拒绝。临时目录已删除，原发布 app 的可执行文件哈希未变化。未运行真实用户目录安装；联网下载须在 Release 实际发布后另行验证。
