# Quick Check for macOS

支持 macOS 15 及更新版本。macOS 26 使用原生 Liquid Glass，macOS 15 使用 AppKit 的半透明材质。开启系统「降低透明度」时使用实色背景。构建需要提供 macOS 26 SDK 的 Xcode 或 Command Line Tools。

```bash
./mac/build.sh
open "mac/dist/Quick Check.app"
python3 mac/Tests/run.py
```

构建脚本生成当前 Mac 架构的应用，默认使用本地临时签名。可用环境变量 `QUICK_CHECK_SIGN_IDENTITY` 指定本机的签名身份。

- **查词**：点菜单栏里的文字放大镜图标，或直接打开 Quick Check.app。离线词库支持中英和中日双向查询，常用短语也会优先查词典。每个译词一行，词性在同一行标注。英文过去式、过去分词和短被动结构可以回查原形，常见的规则化误拼会在结果顶部显示正确形式。
- **词库与显示**：从齿轮菜单打开「词库与显示」，可分别启停 CC-CEDICT（中英）、Tomoshi（中日）和 Open English WordNet（英语）。详细释义和例句可分别开关。WordNet 在常用英文词条下提供英文释义与英文原句，具体例句取决于源词条。
- **语言**：左侧默认是「自动」。识别到外语时译成主语言，识别到主语言时译成默认第二语言。可在「语言设置」修改出厂的简体中文与英语组合。手动指定目标后，所有原文都译成该语言，闲置 5 分钟后恢复自动。
- **翻译接口**：从齿轮进入「翻译接口」，填写兼容 Chat Completions 的接口和模型。Base URL 可填服务商基础地址（含版本路径，例如 `https://example.org/v1`）或完整的 `/chat/completions` 地址。点「获取模型」查询对应的 `/models`，也可以直接填写模型 ID。本机 Ollama 可用 `http://127.0.0.1:11434/v1`。
- **LocalAiMux**：在 LocalAiMux 的「API」页选定模型，切到「JSON」并点击「复制完整配置」。在 Quick Check 的「翻译接口」选择「导入 LocalAiMux JSON」，确认 Base URL、模型 ID 和 API Key 后保存。也可手填默认 Base URL `http://127.0.0.1:8317/v1` 和 `lmx_` 网关 Key，点击「获取模型」，再从「模型 ID」下拉选择。列表查询需要 `models:read` 权限，翻译会使用保存的模型 ID。
- **Key 保存方式**：「保存到钥匙串」下留空会保留已保存的 Key，同一个接口可继续使用。「仅本次运行使用」将新输入的 Key 暂存在内存，退出后失效。首次点击「AI 翻译」或「获取模型」时，macOS 可能要求授权读取已保存的 Key。
- **本地翻译和 AI 翻译**：粘贴后先查本地词典，未命中时尝试系统翻译。手动输入按回车翻译，Shift + Enter 输入换行。若提示缺少语包，按回车向 macOS 请求下载。「AI 翻译」会把当前原文提交给配置的接口，成功后的译文可以调节语气。右下角显示不含空白的原文和译文字符数。
- **词库**：构建会把仓库内的压缩 SQLite 词库展开到应用包。词库出处、许可与转换说明记录在 [DICTIONARY_LICENSE.md](Resources/DICTIONARY_LICENSE.md)。

回归检查覆盖离线词库、语言配置与闲置重置、同文字体系的语种判断、多语言接口参数、语气重生成及服务错误。
运行 `python3 mac/Tests/run.py --offline` 可只检查本地词库、语言设置和 LocalAiMux 接口配置与模型目录格式。
