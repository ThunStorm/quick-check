# TODO · 截图翻译

## 可行性与首个交付

在 macOS 上可行。首个交付建议从现有齿轮菜单加入「识别剪贴板中的截图」。用户用系统截图功能把所选区域复制到剪贴板，再主动触发 Quick Check 读取。就地识别后把可编辑的文字填入现有搜索框，短词沿用本地词典，其他文本按回车提交。这个入口可先验证 OCR 和翻译体验，保留菜单栏弹窗原有的紧凑布局。

第二步加入「框选截图」。用户点按后收起面板，拖动选区，截取一帧，识别完成后回到同一面板。需单独验证屏幕录制权限、遮罩排除和坐标映射，加入时机由第一步的使用反馈决定。

## macOS 实施

1. **剪贴板入口**。按需读取 `NSPasteboard` 的图片，解码后限制像素和内存占用，过大图片按比例缩小。无图、无文字和识别失败分别给可恢复提示。原图仅用于本次识别。
2. **OCR**。在后台用 Vision 的 `VNRecognizeTextRequest` 准确模式执行，按运行时支持的语言配置中文及当前第二语言，并保留行位置和置信度。中日混排的适配需用样机对照单次识别与按语种分开识别，尤其测试只有汉字的日文、竖排和多栏，首个交付以横排单栏为准。按阅读顺序拼接并保留段落，结果可编辑后再翻译。参考 [Vision 文字识别](https://developer.apple.com/documentation/vision/recognizing-text-in-images)。
3. **框选入口**。仅在用户启动框选时处理系统授权和一次性截屏。macOS 15.2 及以上可试用 `SCScreenshotManager.captureImage(in:)`。macOS 15.0–15.1 可验证通过 `SCContentFilter` 和 `SCStreamConfiguration.sourceRect` 捕获当前显示器局部，亦可先保留剪贴板入口。框选原型先约束在单块显示器，随后验证跨屏坐标、Retina 像素密度、负坐标和应用自身遮罩的排除。参考 [ScreenCaptureKit](https://developer.apple.com/documentation/ScreenCaptureKit) 和 [区域截图](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(in:completionhandler:))。
4. **复用翻译流程**。OCR 输出进入现有文本框，复用语言方向、原文、语气、结果和复制。保留手动反转方向。只有用户提交翻译时，所配置的服务才收到编辑后的文字。取消、识别失败、切换输入或关闭时释放图像，并丢弃过期任务的回调。

## 验收与 Windows 衔接

- [ ] 用中、英、日横排样图验证编辑前后的识别结果，核对句读、金额、时间和数字。测试一张混排图和低清图，记录 OCR 局限。
- [ ] 在断网环境验证从截图到可编辑文本，确认 OCR 阶段零网络请求，显式翻译一次只提交文本。测试大图、空剪贴板和用户取消。
- [ ] 框选原型验证授权拒绝后仍能用剪贴板入口，测试外接屏、不同缩放、选区在屏幕边缘、全屏应用和连续选取时结果是否串位。
- [ ] 记录目标机 OCR 延迟、峰值内存，以及面板收起后内存是否回落，依据样图试测结果确定体积和延时预算。
- [ ] Windows 端沿用「图片 → 可编辑原文 → 翻译结果」流程，单独评估截图和 OCR。候选是 `Windows.Graphics.Capture` 与 `Windows.Media.Ocr`，需验证目标 Windows 版本、打包方式、已安装 OCR 语言及对托盘应用的兼容性。参考 [Windows 截图](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture) 和 [Windows OCR](https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrengine)。
