# 截图来源与复现

这些图片展示 **AIYOUClean 0.6.2 当前原生 SwiftUI 内容区**，使用生成的演示数据。每张图顶部额外加了文档标签“演示数据”。没有把 AI 生成图、设计稿或用户真实扫描结果当作产品截图。

| 图片 | 展示内容 |
| --- | --- |
| [smart-processable.png](images/screenshots/smart-processable.png) | 智能检查的可处理候选、所选大小与固定清理栏 |
| [smart-readonly.png](images/screenshots/smart-readonly.png) | 系统和应用数据的只读发现，不提供清理选择 |
| [smart-issues.png](images/screenshots/smart-issues.png) | 访问受限、云占位、符号链接与忽略规则的分别展示 |
| [duplicates.png](images/screenshots/duplicates.png) | 重复文件按内容校验、分组与逐项选择 |

截图中的路径统一使用 `/Users/demo` 等示例路径，容量和数量均为演示值。它们说明界面与流程，不代表在这台 Mac 上扫描得到的结果、空间节省承诺或性能基准。

## 复现

在 macOS 上，先完成 release 构建，然后运行：

```sh
bash scripts/build.sh
python3 scripts/docs-screenshots.py
```

脚本读取当前 `Sources/CleanRoomMac`，在临时目录编译副本，调用 AppKit 的 `NSHostingView` 渲染 `SmartCareView` 和 `ScanView`。生产界面的布局和结果分页读取保留；只在临时副本开放状态访问、使用可构造的演示报告类型、注入数据，并禁用扫描、清理与文件夹对话框。其他未展示页面仅为编译依赖提供空视图。

文档图仅截取内容区，不包含原生侧栏和工具栏；这是为了避开离屏 AppKit 原生侧栏绘制空白的已知限制。图片最顶端的版本/演示标签属于文档包装，不属于应用窗口。

数据写入脚本自有的临时 SQLite 结果库，截图后删除；普通结果使用不超过一页的演示报告。系统快照使用固定演示值，历史记录指向脚本自己的临时目录。脚本不读取用户真实扫描库、不打开或控制旧应用、不扫描用户文件、不执行清理、不请求或更改系统权限。

实际渲染回执、生产源码 SHA-256 和 OCR 页脚检查见 [render-receipt.json](images/screenshots/render-receipt.json) 与 [screenshots-check.json](images/screenshots/screenshots-check.json)。源码变化后应重新生成图片。
