# EVIDENCE-coldstart.md · t.up-fix r13

简报 (a)–(e) 要求 `.app` 冷启动后第一次粘图。席位纪律一点五 + 简报第 4 轮：

> `.app` 上同样不许合成输入事件；只能靠真实设备才验得了的那部分 ⇒ 不可判。

本回合 **未** open/kill 用户 AgentMirror，**未** 对测试包发 CGEvent / keystroke。

| # | 要求 | r13 |
|---|---|---|
| a | 冷启动时刻；清空 upload.log | **不可判(2)**：要起 `.app` 再往里粘，禁止合成输入 |
| b | 第一条日志 n=1 ok=true | 不可判 |
| c | daemon uploads 出现文件 | 不可判（无粘贴驱动） |
| d | 隔离 tmux pane 出现 attachment 路径 | 不可判 |
| e | n≥3 次 (b)(c)(d) | 不可判 |

**替代读数（Chrome，后台合成 ClipboardEvent，不抢输入设备）**

`chrome-paste.dom.html`：`PASTE_HARNESS_PASS`。

- 图片 `handleClipboardData` → `sendImage`（kind=image, 70 bytes PNG）
- 焦点列 window 监听命中 paste（window=1）
- 非焦点 pane 监听吃不到 window paste（根因对照）

上一轮 r10 HID 三次冷启动 `upload.log` 条数为 0，**不能**当作本轮好态。

原生 HTTP（不经粘贴 HID）：`DeviceManager.uploadImage` + `postUpload` 单测；Rust `post_upload_is_post_not_options`。
