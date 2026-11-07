# FinderX

macOS Finder 右键增强。软件把常见操作生成可编辑脚本，再将脚本绑定到右键菜单；用户自定义操作也使用同一条执行链路。

已支持：

- 在终端中打开目录。
- 复制所选文件、文件夹的路径。
- 将文件夹固定到 Dock。
- 移动到配置的目标目录。
- 拷贝到任意目标目录，支持多选文件和文件夹，重名自动编号。
- 发送到 LocalSend。
- 在桌面创建符号链接快捷方式。
- 选择应用生成“打开方式”脚本。
- 编写自定义 zsh 脚本并加入菜单。

## 构建和安装

需要 macOS 13+、Xcode Command Line Tools（swiftc、codesign）。

```bash
scripts/test.sh
scripts/build.sh
scripts/install.sh
```

安装至 `~/Applications/FinderX.app`。首次使用在系统设置的扩展管理中启用 **FinderX Finder**；也可从应用菜单栏选择“启用 Finder 扩展…”。具体设置位置随系统版本变化。

## 使用

在 Finder 中右键文件、文件夹或目录空白处，打开 **FinderX**。终端和 Dock 动作仅匹配目录；其他默认文件动作支持文件和目录，空白处作用于当前目录。

菜单栏“设置…”提供打开方式、移动到、拷贝到、发送到、自定义脚本和高级配置。移动目标与固定拷贝目标可单独启用或停用；“发送到”支持添加已有动作或移除引用。软件生成的脚本可以继续修改，后续安装保留已有脚本。

默认右键菜单包含“打开方式”分组；未添加应用时显示占位项，添加的应用会追加到同一分组。

选择“拷贝到…”后，在系统目录选择框中选择目标文件夹；取消不执行拷贝。源文件保留，同名项追加 ` 2`、` 3` 等编号，目录不会合并或覆盖。操作使用 `Scripts/copy-to.zsh`，可修改脚本或把动作的第一个参数 `--choose` 改为固定目标目录。选择目录与拷贝共用 600 秒超时。

升级时自动补入“拷贝到…”动作，原配置保存在 `config.before-copy-to.json`，以 `config.copy-to-migrated` 记录已处理；之后手工隐藏或删除该动作不会被自动恢复。

无需交互的右键动作在后台执行，不自动弹设置或抢焦点。失败时菜单栏图标提示，可主动打开“最近执行结果”查看原因。

脚本通过 `"$@"` 接收选择项。修改 JSON 后约 3 秒自动加载，重新打开右键菜单生效。菜单栏提供重新加载、最近执行结果和取消动作。

配置与脚本位于：

```text
~/Library/Containers/com.finderx.app.finder/Data/Library/Application Support/FinderX/
```

FinderX 原名 SuperRight。首次启动会复制旧版配置与用户脚本到新目录，并备份原配置；已有 FinderX 配置不会被覆盖。旧脚本的 `SUPERRIGHT_EXECUTABLE` 环境变量仍兼容，新脚本使用 `FINDERX_EXECUTABLE`。

2026-11-06 改名验证：20 项测试通过，应用构建与签名通过；已安装的 FinderX 扩展通过真实右键“复制路径”冒烟检查，旧版 9 个动作和 7 份脚本迁移成功。此前六类功能的详细验收见历史验证记录。

旧版目标目录会先备份，再迁移为动作配置。无效配置保留上次有效版本，并报告具体字段错误。

## 文档

- [脚本动作框架](docs/action-framework.md)：模块、执行流程、传输与迁移。
- [配置契约 v1](docs/configuration.md)：菜单、条件、参数、变量和运行限制。
- [自定义与边界清单](docs/customization-checklist.md)：可定制能力、不适用配置和验收记录。
- [完整配置示例](docs/examples/framework-v1.json)：基于用户脚本模板的动作绑定示例。
- [0.2.1 真实验证记录](docs/verification-2026-11-06.md)：菜单回调故障修复、实际功能效果和未覆盖范围。

## 当前边界

- Dock 脚本沿用修改系统偏好并重启 Dock 的实现，系统版本变化可能影响行为。
- 桌面快捷方式是符号链接，源对象移动后可能失效。
- LocalSend 的文件夹处理由该应用决定；缺少应用时菜单禁用。
- 菜单覆盖受 Finder Sync 限制，iCloud Drive 和部分 File Provider 位置需要实际验证。
- 默认单次脚本超时 30 秒，可配置为 1–600 秒；当前没有交互式终端和后台服务管理。
- 当前为本地 ad-hoc 签名版本，使用扩展容器里的私有请求文件交接。正式分发的 App Group、签名 IPC 与公证尚未接入。

## 代码结构

```text
Sources/Core/               数据、配置、匹配、菜单和计划
Sources/Runtime/            调度与进程执行
Sources/Platform/macOS/     脚本生成、应用查找与底层 CLI
Sources/FinderExtension/   Finder 上下文和菜单渲染
Sources/Shared/            存储路径、请求和依赖状态
Sources/App/               菜单栏、设置与结果反馈
Resources/Scripts/          初始脚本模板
Tests/                     框架与脚本测试
scripts/                   构建、测试、安装和卸载
```
