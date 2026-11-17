# 网课作业 / 刷课 托管

把网课平台上的**作业**和**刷课**交给本机自动化：AI 负责把环境拉起来、登录、导航、盯进度和验收，页面上真正做题和看视频的是 [OCS](https://docs.ocsjs.com/) 的用户脚本，答题用的本地 AI 题库是 [ZError](https://app.zerror.cc/)。

你不用记命令，只要对 Agent说一句：

> 配置我 GitHub 上的这个项目，然后帮我做学习通上那个作业

剩下 AI 会按 [`SKILL.md`](./SKILL.md) 自己走完。

---

## 它解决什么问题

现有工具（OCS 桌面版 + ZError 题库）本身很强，但**每次都要人工点一串固定操作**：开 ZError → 点启动 → 开 OCS → 点浏览器 → 等导航页 → 点平台 → 检查登录 → 找作业……

这套脚本把那串操作封装成可被 AI 调用的原子动作，并且解决了一路上所有脏问题：Electron/Tauri 的窗口识别、被遮挡时点击失效、DPI 缩放、中文标题乱码、GitHub 下载被墙、浏览器自动填充导致账号密码拼接……

## 能力

| 模块 | 做什么 |
|---|---|
| `install-deps.ps1` | 首次安装 OCS + ZError，多镜像下载（国内直连 GitHub 文件域名通常不通） |
| `chaoxing.ps1` | 环境层：自动发现路径与浏览器、起 ZError 服务、起 OCS、拉起浏览器、标定按钮位置 |
| `ocs-session.ps1` | 手眼层：截图 / 读标题 / 点击 / 输入 / 按键 / 地址栏导航 |
| `login.ps1` | 登录检查（三态）+ 自动填账号密码 |
| `run.ps1` | 一条命令走完「起环境 → 打开平台」 |
| `verify.ps1` | 盯进度 + 验收：定时截图、帧间像素差异、静止告警 |
| `install-skill.ps1` | 把 SKILL.md 注册成 DSH 技能，AI/IM 机器人说「做网课作业」自动路由 |

支持平台见 [`platforms.json`](./platforms.json)：超星学习通、知道智慧树、智慧职教、职教云、中国大学MOOC、雨课堂。**除学习通外均标注 `verified: false`**——入口地址未经实测，用到的平台需要现场截图校正。

## 快速开始

> ### ⚠ 先解决执行策略
>
> Windows 客户端默认 `ExecutionPolicy = Restricted`，直接 `.\xxx.ps1` 会报
> **「在此系统上禁止运行脚本」**。两条路，任选：
>
> **A. 双击 `go.cmd`**（已内置 Bypass，不改系统任何设置）
>
> **B. 命令行显式带 Bypass**：
>
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
> ```
>
> 本文档下面所有 `.\xxx.ps1` 的写法，都请理解成上面这种带 Bypass 的调用。
> `go.cmd` 还支持快捷子命令：`go.cmd probe` / `go.cmd login` / `go.cmd status` / `go.cmd verify`。

### 1. 装依赖

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-deps.ps1 check
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-deps.ps1 all
```

### 2. 手动过一遍首次向导（只做一次）

装完后第一次启动这两个软件，都需要人工点几下：

**ZError**：设置 → 模型配置 → 填 AI 平台 API Key → 回主页点「启动」，看到 `127.0.0.1:3000` 才算好。

**OCS 3.9.1**：
1. 弹窗「OCS 初始化」正在下载内置浏览器 —— **等进度条走完**
2. 弹「欢迎使用」时点「开始使用」关掉
3. 卡片式界面上点「新建浏览器」，起个名字**并记住**（要填进配置）

### 3. 配置

```powershell
Copy-Item config.example.json config.json
```

填 `accounts`（各平台账号）、`ocs.browserName`（OCS 里那个浏览器的名字）。

### 4. 跑

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\login.ps1 -Platform chaoxing
.\login.ps1 -Platform chaoxing   # 检查登录，掉线自动填表
.\verify.ps1 -Watch              # 盯进度
```

### 5. 注册成 DSH 技能（可选，给 AI / IM 机器人用）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-skill.ps1
```

装完后，任何 DSH 会话（含 QQ/微信 IM 机器人）里说「帮我做网课作业/刷课」就会自动按 SKILL.md 干活。
仓库更新后用 `.\install-skill.ps1 -Force` 把已注册技能同步到新版本。

## 前置要求

- Windows 10/11，PowerShell 5.1+
- 两个**必须你自己办**的事：
  - 给 ZError 配 AI 模型 API Key（去阿里云百炼 / 智谱 / DeepSeek 注册，自己填）
  - 提供网课平台账号密码

## 目录

```
.
├── SKILL.md               # AI 照这个干活（核心）
├── platforms.json         # 平台入口速查
├── config.example.json    # 配置模板
├── install-deps.ps1       # 装依赖
├── lib.ps1                # 共享底层：P/Invoke / UIA / 登录判定
├── chaoxing.ps1           # 环境层
├── ocs-session.ps1        # 手眼层
├── login.ps1              # 登录
├── run.ps1                # 一键起环境
├── verify.ps1             # 盯进度/验收
├── install-skill.ps1      # 注册 DSH 技能（AI/IM 机器人自动路由）
└── js/                    # 早期用的浏览器内探测脚本（备用）
```

## 设计取舍

**为什么不用 CDP，全靠截图点坐标？**

OCS 桌面版是用 Playwright 的 `launchPersistentContext` 起浏览器的，走 `--remote-debugging-pipe`，外部连不上 CDP。所以拿不到 DOM，只能靠「截图 + 视觉定位 + 坐标点击」。这也是为什么有 `verify.ps1` 用像素差异判断页面动没动。

**为什么按钮位置用固定像素而不是百分比？**

按钮固定在顶部工具栏下方，和窗口高度无关。用百分比算，窗口一高一矮就偏——这是实测踩出来的。

**为什么 ZError 用 UIA 而 OCS 用坐标？**

ZError 是 Tauri + WebView2，UIA 能读到按钮（55 个元素），可以用 `InvokePattern` 直接触发，不受遮挡影响。OCS 是 Electron，对 UIA 完全不可见（实测后代元素 0 个），只能用坐标。

## 已知限制

- 平台前端改版会让导航失效，需要现场重截图标定
- 撞到滑块验证码需要人工
- 按钮坐标只对 OCS 2.x 有意义；3.9.1 走 UIA 按名字定位，不需要标定。换到 2.x 才需要跑 `chaoxing.ps1 calibrate`
- 只做过超星学习通的端到端验证

## 接到 IM 机器人（手机派单）

完整闭环：手机收到学习通通知 → 截图发给 QQ/微信里的 DSH 机器人 → 机器人按本仓库
SKILL.md 在电脑上做完 → 验收截图发回手机。需要四个条件：

1. DSH 装好 `@xmanrui/dsh-im` 并绑定 QQ/微信渠道（设置 → IM机器人）；
2. 跑过上面第 5 步的 `install-skill.ps1` 注册技能；
3. **会话模型必须支持图像输入**——通知截图和验收图都靠读图，纯文本模型跑不了；
4. 电脑保持开机、不锁屏、不睡眠（UI 自动化在锁屏下无效）。

刷课是小时级长任务：让机器人用后台任务跑 `verify.ps1 -Watch` 并定时回传进度，
不要占着一个对话回合干等。撞到滑块/人脸识别，机器人应截图回传请你人工处理。

## 免责

仅供个人学习自动化使用。请遵守所在平台的使用条款，因使用产生的后果由使用者自负。
