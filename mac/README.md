# Quick Check for macOS

支持 macOS 15 及更新版本。macOS 26 使用原生 Liquid Glass，macOS 15 使用 AppKit 的半透明材质。开启系统「降低透明度」时使用实色背景。构建需要提供 macOS 26 SDK 的 Xcode 或 Command Line Tools。

```bash
./mac/build.sh
open "mac/dist/Quick Check.app"
python3 mac/Tests/run.py
```

构建脚本生成当前 Mac 架构的应用，默认使用本地临时签名。可用环境变量 `QUICK_CHECK_SIGN_IDENTITY` 指定本机的签名身份。

- **查词**：点菜单栏里的文字放大镜图标，输入词或短语。也可直接打开 Quick Check.app，在屏幕上方呼出同一个搜索框。左侧可在英语与日语之间切换。母语默认中文，停用日语查询 5 分钟后，下一次打开或查询恢复英语。结果区的方向按钮可反转当前查询。离线词库支持中英、中日双向精确查询，反查来自词典释义索引。
- **翻译**：从齿轮进入「翻译设置」，填写兼容 Chat Completions 的接口和模型。接口可填服务商基础地址（含服务商要求的版本路径，例如 `https://example.org/v1`）或完整的 `/chat/completions` 地址。API Key 保存在系统钥匙串。使用无密钥的本机 Ollama 时，地址可填 `http://127.0.0.1:11434/v1`，模型填已安装的名称。
- **操作**：按回车翻译，Shift + Enter 输入换行。译文可复制，也可选「更随和」或「更正式」，按原文重新生成。Esc 或点回其他应用收起。使用在线服务时，显式提交翻译或换语气会把当前原文发给所配置的服务。
- **词库**：构建会把仓库内的压缩 SQLite 词库展开到应用包。词库出处、许可与转换说明记录在 [DICTIONARY_LICENSE.md](Resources/DICTIONARY_LICENSE.md)。本地查询最多展示五条候选。

回归检查覆盖离线词库、语种判断、日语闲置重置、接口请求参数、语气重生成及服务错误。译文质量随模型而异，请用实际使用的中英及中日语料评估。
