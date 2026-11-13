# Codex 额度浮窗

一个独立的 macOS 应用。Codex 窗口在前台时，右下角显示 5 小时和周额度各自的剩余百分比、下次刷新时间和倒计时；只显示接口返回的订阅窗口。切换到其他应用时隐藏。浮窗不抢焦点，鼠标可穿透。

**额外额度（Credits）**是订阅额度用完后可用于符合条件功能的余额，与 5 小时额度、周额度和重置卡分开。余额为 `0` 不代表订阅额度用完；服务未返回数据时显示「未返回」，不填成 `0`。见 [OpenAI 额度说明](https://help.openai.com/en/articles/12642688-using-credits-for-flexible-usage-in-chatgpt-personal-plans)。

## 运行

需要 macOS 14+ 和已登录的 Codex 桌面版。当前版本按 `/Applications/ChatGPT.app` 定位 Codex 自带的 CLI，构建需 Apple Command Line Tools；不依赖第三方包或 CodexBar。本项目不是 OpenAI 官方插件。

```bash
git clone https://github.com/hummingg/codex-quota-overlay.git
cd codex-quota-overlay
./build.sh
open -g "build/Codex 额度浮窗.app"
```

可从活动监视器退出进程 `CodexQuotaOverlay`。不会添加开机启动项，不修改 Codex 或 CodexBar 的设置。

## 数据与权限

浮窗从 Codex 自带的 CLI 启动短时 App Server，只调用官方 `account/rateLimits/read`。按窗口时长识别 5 小时（300 分钟）和周额度（10080 分钟），不依赖主槽或副槽的顺序。仅读取数据，不发送模型请求、不购买额外额度、不兑换重置卡、不直接读取凭证或浏览器 Cookie。Codex 在前台且有可见窗口时才发起刷新，正常约 90 秒一轮；切换回来若上次数据仍新鲜，则继续使用该快照。显示的刷新时间按 Mac 时区格式化；失败不假装刷新已完成。窗口定位只读取窗口所属进程和边界，不读取标题或屏幕内容。

## 验证

```bash
./build.sh --test
"build/Codex 额度浮窗.app/Contents/MacOS/CodexQuotaOverlay" --check
```

如本机 CLT 同时存在旧版 `module.modulemap` 和新版 `bridging.modulemap`，构建脚本用本项目生成的 VFS 文件临时屏蔽重复定义，不改系统工具链。

## 许可证

[MIT](LICENSE)
