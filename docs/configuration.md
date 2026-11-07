# 脚本动作配置契约 v1

状态：已实现。配置只负责把菜单与脚本连接起来；操作逻辑可以完全由用户脚本实现。配套说明见 [框架](action-framework.md) 与 [自定义清单](customization-checklist.md)。

## 1. 最小配置

```json
{
  "schemaVersion": 1,
  "actions": [
    {
      "id": "custom.reveal",
      "title": "在 Finder 中显示",
      "when": {
        "surfaces": ["items", "container", "sidebar"],
        "kinds": ["file", "directory"]
      },
      "execution": {
        "type": "command",
        "executable": "/bin/zsh",
        "arguments": ["{home}/.config/finderx/reveal.zsh", "{paths}"],
        "requirements": { "paths": ["{home}/.config/finderx/reveal.zsh"] }
      }
    }
  ],
  "menu": [
    {
      "type": "action",
      "id": "menu.reveal",
      "actionID": "custom.reveal"
    }
  ]
}
```

对应的 `reveal.zsh` 由用户创建，或通过设置里的自定义脚本入口生成：

```sh
#!/bin/zsh
set -euo pipefail
for selected_path in "$@"; do
  /usr/bin/open -R "$selected_path"
done
```

完整样例见 [framework-v1.json](examples/framework-v1.json)。该样例使用首次启动安装的模板；先启动应用，再按需要合并配置，避免覆盖个人动作。

## 2. 根对象和动作

根对象只包含 `schemaVersion/actions/menu`。版本固定 1；动作 ID 全局唯一，菜单节点 ID 在整棵菜单树中唯一；两者各自独立。

| 动作字段 | 含义 |
| --- | --- |
| `id` | 必填，稳定非空字符串，最长 128 字符 |
| `title` | 必填，默认菜单名称 |
| `icon` | 可选，系统符号名，不可用时无图标 |
| `enabled` | 默认 true，关闭后不显示且不能调度执行 |
| `when` | 必填，适用入口和目标条件 |
| `batch` | all 或 each，默认 all |
| `onError` | stop 或 continue，默认 stop；continue 仅用于 each |
| `execution` | 必填，命令或界面管理操作 |

`when` 的字段：

| 字段 | 含义 |
| --- | --- |
| `surfaces` | 非空数组，items/container/sidebar |
| `kinds` | 非空数组，file/directory/unknown；每个目标都必须在允许集合中 |
| `minCount` | 默认 1，必须 ≥ 1 |
| `maxCount` | 可选，必须 ≥ minCount |
| `extensions` | 可选非空数组，不带点、忽略大小写；仅用于 kinds=[file] |

条件字段之间为 AND，数组内为 OR。不执行动态条件脚本。元数据未知的目标可参与菜单匹配，但执行前仍要求路径可访问且存在。

限制：配置文件最多 2 MiB，动作最多 256 个，菜单节点最多 512 个，菜单深度最多 4，单次有效目标最多 128 个。无效配置拒绝发布，保留最近有效版本并报告字段路径。

## 3. 菜单树

| 类型 | 字段 |
| --- | --- |
| group | 必填 type/id/title/children；可选 icon/showWhenEmpty |
| action | 必填 type/id/actionID；可选 title/icon，用于覆盖动作展示字段 |
| separator | 仅 type/id |

数组顺序就是显示顺序。同一动作可被不同菜单节点引用。未知引用、重复 ID、未知字段和枚举均为错误。空分组默认不显示；分组设置 `"showWhenEmpty": true` 后，即使没有可用子项也会保留并显示带禁用占位项的子菜单。

“添加打开方式”与“添加自定义脚本”会在 `menu.finderx` 中创建或复用 `menu.open-with/menu.custom` 分组。默认配置已包含 `menu.open-with`（打开方式）分组，因此它始终可见；添加的应用会追加到该分组。移动目标管理使用 `menu.move`，修改这个分组 ID 后，应自行管理移动动作或恢复该 ID。

## 4. command 执行定义

| 字段 | 含义 |
| --- | --- |
| `type` | 固定 command |
| `executable` | 必填，可执行文件绝对路径模板；脚本动作通常是 /bin/zsh |
| `arguments` | 必填，有序字符串数组，可为空 |
| `workingDirectory` | 默认 {home}，展开后必须是存在的绝对目录 |
| `environment` | 可选字符串键值覆盖，值支持单值变量 |
| `stdin` | 可选，默认立即 EOF |
| `timeoutSeconds` | 默认 30，允许 1–600 |
| `successExitCodes` | 默认 [0]，非空，值为 0–255 |
| `requirements` | 可选，应用和依赖文件 |

`requirements.applications` 接受应用名称、bundle ID 或绝对 `.app` 路径。名称查找覆盖 /Applications、~/Applications、/System/Applications 和其 Utilities 目录；非标准安装位置建议保存绝对路径。`requirements.paths` 为必须存在的绝对路径模板。

执行文件始终检查存在且可执行。依赖缺失时菜单禁用，点击后主程序仍会再次检查。

环境基础值由框架提供：固定 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`、真实用户的 HOME/USER/TMPDIR、`LANG=en_US.UTF-8` 和 `FINDERX_EXECUTABLE`，再应用用户配置覆盖。不会自动载入交互式终端启动配置；Homebrew 工具可以使用绝对路径或在脚本中显式设置 PATH。

每个任务参数最多 256 个，参数 UTF-8 数据总量最多 64 KiB，标准输入最多 1 MiB；仍受系统实际进程限制。参数超限时拒绝执行，不截断路径或自动拆批。

## 5. 变量

| 变量 | 含义 |
| --- | --- |
| {paths} | 当前任务全部目标，展开为多个独立参数；each 中只有当前目标 |
| {path} | 当前任务恰好一个目标的路径 |
| {name} | 单个目标的文件名，含扩展名 |
| {parent} | 单个目标的父目录 |
| {container} | Finder 提供的当前目录，有可能不存在该上下文 |
| {home} | 执行主程序的用户主目录 |

`{paths}` 只允许作为 arguments 数组的完整元素。`"--files={paths}"` 无效。单值变量可以嵌入字符串，例如 `"{home}/Desktop"`。

all 模式若使用 `{path}/{name}/{parent}`，必须声明 `when.maxCount=1`；否则改成 each。未知变量、未闭合花括号和单值字段使用列表变量都拒绝。

可执行文件和依赖声明只能使用 `{home}`；不能让选中文件决定解释器。工作目录、参数和环境值可以使用满足条件的单值变量。

使用 `{{` 和 `}}` 表示字面花括号，例如 `{{home}}` 不被展开。替换只有一次；文件名自身包含变量外观时不递归解释。

框架不隐式处理 `~`、`$VAR`、`$(...)` 或通配符。它们在脚本正文中可以作为正常 shell 语法使用，但不要把选择路径拼进 `zsh -c` 程序正文，应使用位置参数。

## 6. 标准输入

两个互斥形式：

```json
{ "source": "text", "value": "固定文本或{home}" }
```

```json
{ "source": "paths", "separator": "\n", "trailingSeparator": false }
```

text.value 必填且支持单值变量。paths 按目标顺序连接路径；separator 默认换行，也可为 `"\u0000"`；trailingSeparator 默认 false。输入以 UTF-8 写入，完成后关闭管道。

换行路径列表适合人工复制，但包含换行的文件名不适合机器按行解析。机器处理可使用 NUL 分隔，或直接使用最推荐的独立参数与 `"$@"`。

## 7. builtin 管理操作

只有下列界面入口需要 builtin：

```json
{
  "type": "builtin",
  "operation": "app.add-destination",
  "parameters": {}
}
```

目前允许 `app.add-destination`、`app.settings`，要求 all 和空参数。它们打开主程序表单。文件移动、符号链接和 Dock 都使用脚本，不再提供 `files.move/files.symlink/dock.pin` 原生执行类型。

## 8. 用户脚本协议

- 软件生成 zsh 文件；脚本不需要可执行位，由解释器读取。
- 目标路径作为独立参数传入，用 `"$@"` 或 `$1` 等读取。
- 成功通常退出 0；失败用非零退出码，并将原因写到 stderr。
- 框架只知道进程结果，不解析自然语言推断业务状态。
- 脚本正文允许管道、条件、循环、函数、命令组合、网络调用等用户自定义逻辑。
- 用户可调用其他已安装工具和解释器，并声明相应依赖。
- 默认超时 30 秒，上限 600 秒；输出各保存 64 KiB，超出继续排空。
- 取消和超时结束受管进程组；脚本应自行清理临时文件与处理已经产生的副作用。

手工编辑现有脚本时可先运行 `/bin/zsh -n 脚本路径` 检查语法。设置中的新增脚本入口会自动做该检查，不会在保存时试运行。
