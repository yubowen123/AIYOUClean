# 构建与开发

macOS 13+，系统 Swift 工具链（Package.swift 声明 Swift tools 5.9），系统 AppKit / SwiftUI / SQLite。可选 ClamAV 不参与普通文件整理。

```bash
xcode-select --install
bash scripts/build.sh
swift run --jobs 4 CleanRoomChecks
```

`xcode-select --install` 仅在缺少工具链时执行。`build.sh` 生成 `dist/AIYOUClean-0.6.2.app` 和 `dist/aiyouclean-cli-0.6.2`，并做本地 ad-hoc 签名，不执行检测或安装。

## 只读 CLI

```bash
./dist/aiyouclean-cli-0.6.2 scan duplicates --full --root /absolute/folder --output /absolute/new-report.json
./dist/aiyouclean-cli-0.6.2 scan spaceLens --full --root /absolute/folder --output /absolute/new-space.json
```

默认持续扫描。`--max-results` 只调整最多 200 项的预览，JSON 导出完整结果。显式 `--max-files` / `--max-seconds` 切入有界诊断；`--full` 恢复完整模式，参数按从左到右处理。CLI 退出码：0 已完成；1 导出/IO错误；2 参数或隐藏功能；3 报告不完整。没有删除命令。

报告可能包含完整路径；不要把真实报告提交到仓库。

## 原生回归

先完成 release 构建，再运行：

```bash
python3 scripts/result-retention-check.py --binary-dir .build/arm64-apple-macosx/release --output-dir analysis/retention-local
python3 scripts/task-lifecycle-check.py --binary-dir .build/arm64-apple-macosx/release --output analysis/task-lifecycle-local
python3 scripts/layout-check.py analysis/layout-local.json --binary-dir .build/arm64-apple-macosx/release
```

脚本基于生成夹具和当前产品代码编译测试宿主，使用 release Core 对象；不控制用户应用。脚本中对私有可见性、输入/只读遥测和未测页面的变换需结合清单理解，不能把布局测试当完整用户验收。截图脚本见 [截图说明](screenshots.md)。

`analysis/` 是本地忽略目录，不随仓库发布。脚本会将其用作可复现结果输出；这不表示远端包含历史个人分析资料。较旧的 scale/layout 专用脚本可能依赖历史源码锚点，应使用以上当前入口。

## 发布

当前 Release 使用已经验证的 v0.6.2 / build 10 arm64 应用。使用 `scripts/package-release.sh` 生成压缩包和 SHA-256 清单；具体参数见脚本帮助。发布前核对功能策略、截图版本、许可证、文件清单和源码提交，不能将真实扫描库或商业软件分析材料打包。
