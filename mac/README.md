# Quick Check for macOS

支持 macOS 15 及更新版本。macOS 26 使用原生 Liquid Glass，macOS 15 使用 AppKit 的半透明材质。开启系统「降低透明度」时使用实色背景。构建需要提供 macOS 26 SDK 的 Xcode 或 Command Line Tools。

```bash
./mac/build.sh
open "mac/dist/Quick Check.app"
python3 mac/Tests/run.py
```

构建脚本生成当前 Mac 架构的应用，默认使用本地临时签名。可用环境变量 `QUICK_CHECK_SIGN_IDENTITY` 指定本机的签名身份。

- **查词**：点菜单栏里的文字放大镜图标，或直接打开 Quick Check.app。离线词库支持中英和中日双向精确查询，反查来自词典释义索引。结果区的方向按钮可反转本次查询。
- **语言**：从齿轮进入「语言设置」，选择主语言和默认第二语言。出厂组合是简体中文与英语。左侧下拉可临时切换第二语言，闲置 5 分钟后下次打开或查询会恢复为设定的默认值。自动识别方向时会参考当前两种语言，简短或混合语种的文字可手动反转。
- **翻译接口**：从齿轮进入「翻译接口」，填写兼容 Chat Completions 的接口和模型。翻译菜单提供 26 个语言选项，包括简体和繁体中文、英语、日语、韩语、法语、德语、西班牙语、葡萄牙语、俄语、阿拉伯语等，实际翻译取决于模型的语言能力。接口可填服务商基础地址（含所需的版本路径，例如 `https://example.org/v1`）或完整的 `/chat/completions` 地址。API Key 保存在系统钥匙串。本机 Ollama 可用 `http://127.0.0.1:11434/v1` 和已安装的模型。
- **LocalAiMux**：在 LocalAiMux 的「API」页选定模型，切到「JSON」并点击「复制完整配置」。在 Quick Check 的「翻译接口」选择「导入 LocalAiMux JSON」，确认 Base URL、模型 ID 和 API Key 后保存。也可手填默认 Base URL `http://127.0.0.1:8317/v1` 和 `lmx_` 网关 Key，点击「获取模型」，再从「模型 ID」下拉选择。列表查询需要 `models:read` 权限，翻译会使用保存的模型 ID。
- **操作**：按回车翻译，Shift + Enter 输入换行。译文可复制，也可选「更随和」或「更正式」，按原文重新生成。Esc 或点回其他应用收起。使用在线服务时，显式提交翻译或换语气会把当前原文发给所配置的服务。
- **词库**：构建会把仓库内的压缩 SQLite 词库展开到应用包。词库出处、许可与转换说明记录在 [DICTIONARY_LICENSE.md](Resources/DICTIONARY_LICENSE.md)。本地查询最多展示五条候选。

回归检查覆盖离线词库、语言配置与闲置重置、同文字体系的语种判断、多语言接口参数、语气重生成及服务错误。
运行 `python3 mac/Tests/run.py --offline` 可只检查本地词库、语言设置和 LocalAiMux 接口配置与模型目录格式。
