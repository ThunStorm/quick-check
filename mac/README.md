# Quick Check for macOS

支持 macOS 15 及更新版本。构建需要带有 macOS 26.4 或更新 SDK 的 Xcode 或 Command Line Tools。macOS 26 上使用原生 Liquid Glass。较早版本使用 AppKit 半透明材质，开启系统「降低透明度」时使用实色背景。

## 安装和更新

在仓库根目录执行：

```bash
./mac/build.sh --install
```

应用从「应用程序」中的 Quick Check 打开。再次运行同一命令会替换 `/Applications/Quick Check.app` 并启动新版，沿用现有设置。

## 仅构建

在仓库根目录执行：

```bash
./mac/build.sh
```

脚本在 `mac/dist` 生成适配当前 Mac 架构的应用，默认使用临时签名。可通过环境变量 `QUICK_CHECK_SIGN_IDENTITY` 指定本机的签名身份。

发布用的通用构建可运行 `./mac/build.sh --universal`，产物同时包含 Apple 芯片（arm64）和 Intel（x86_64）架构。`bash mac/package.sh` 会进一步生成、验证 DMG 和 SHA‑256 校验文件。推送与应用版本一致的 `vX.Y.Z` 标签会触发 GitHub Release。

## 查词和本地翻译

1. 点菜单栏的文字放大镜，或直接打开 Quick Check.app。输入或粘贴文字，离线词库命中时立即显示结果。常见英文过去式、过去分词和短被动结构可回查原形。
2. 输入较长文字后按回车使用 macOS 本地翻译。粘贴时，本地词典未命中的内容也会尝试系统翻译。Shift + Enter 可换行，输入法组词时先确认候选字。
3. 首次使用某个语言对时，按回车打开系统下载界面。点所需语言旁的 **Download**，等语包就绪后返回并重试。系统会按所选语言对判断支持和安装状态。也可在 macOS「系统设置 → 通用 → 语言与地区 → 翻译语言」管理语包。
4. 可复制查询结果。右下角分两行显示原文和当前译文的字符数，空白不计入。按 Esc 或点回其他应用可收起浮窗。

在齿轮 →「语言设置」可修改主语言和默认第二语言。出厂组合为简体中文和英语。「自」模式将外语译成主语言，将主语言译成默认第二语言。也可以从左侧下拉指定目标语言，闲置 5 分钟后恢复自动模式。

同一界面的「输入时实时翻译」默认关闭。开启后，词库未命中的文字会在停止输入片刻后自动使用 macOS 本地翻译。首次下载语包仍需按回车。

简繁字形转换在本机完成。简繁共用字按已指定的中文目标或语言设置判断。

在齿轮 →「词库与显示」可分别启停 CC-CEDICT（中英）、Tomoshi（中日）和 Open English WordNet（英语），也可以单独开关详细释义和例句。WordNet 显示英文释义和原句，例句覆盖取决于词条。 [词库来源与许可](Resources/DICTIONARY_LICENSE.md)

中英词库也收录了常见软件界面术语，如 `console panel`（控制台面板）、`menu bar`（菜单栏）。`console`、`port` 等多义词同时保留常见技术义和一般词义。查词时，同组译义用顿号并排显示，同一词性下的不同义项用分号隔开。

## AI 翻译和模型列表

点击结果区下方的「AI 翻译」会把当前原文交给配置的服务。AI 译文可从语气菜单选「更随和」或「更正式」重新生成。

在齿轮 →「翻译接口」配置兼容 Chat Completions 的服务：

| 字段 | 填写方法 |
| --- | --- |
| Base URL | 填服务商提供的基础地址和版本路径，例如 `https://example.org/v1`。也可填完整的 `/chat/completions` 地址。 |
| 模型 ID | 输入服务商提供的模型 ID，或点「获取模型」查询该地址对应的 `/models`，再从下拉框选择。 |
| API Key | 按服务商要求填写。保存到钥匙串时，留空可继续使用与该接口关联的 Key。「仅本次运行使用」会把新填的 Key 暂存在内存，退出后失效。 |

本机服务可使用回环 HTTP 地址，例如 Ollama 的 `http://127.0.0.1:11434/v1`。远程地址使用 HTTPS。首次获取模型或请求 AI 翻译时，macOS 可能要求授权读取已保存的 Key。

使用 LocalAiMux 时，可在其「API」页选定模型并复制完整 JSON，再点 Quick Check「导入 LocalAiMux JSON」并保存。手填时，默认 Base URL 为 `http://127.0.0.1:8317/v1`，Key 使用 `lmx_` 开头的网关 Key。获取列表需要该 Key 具备 `models:read` 权限。

## 开发检查

```bash
python3 mac/Tests/run.py --offline
python3 mac/Tests/run.py
```

离线模式检查词库、词形变化、语言方向和接口配置。默认模式增加本机回环的模拟接口检查。系统翻译需另行在安装语包后验证，具体步骤见[实施与验收计划](../IMPLEMENTATION_PLAN.md)。
