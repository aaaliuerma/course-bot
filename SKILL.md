---
name: ocs-course-bot
description: 用 OCS Desktop + ZError 题库托管网课作业与刷课。当用户要求"帮我做网课作业/刷课"、发来学习通等平台的作业通知截图、或要求在 Windows 上配置这套自动化时使用。
---

# 网课作业 / 刷课 托管

用 **OCS Desktop**（浏览器多开 + 用户脚本宿主）和 **ZError**（本地 AI 题库服务）搭一套网课自动化。分工是：**你负责把环境拉起来、登录、导航、监督、验收；OCS 的用户脚本负责在页面里真正刷课和答题。**

> **先找到项目目录**：本文所有命令都在 course-bot 仓库目录里执行。
> 用户给过本地路径就用它；否则在工作区找 `course-bot` 目录；再没有就问用户，
> 或先克隆：`git clone https://github.com/aaaliuerma/course-bot.git`。
> 会话模型**必须支持图像输入**——本技能的核心循环是读截图，纯文本模型跑不了。

---

## 〇、第一件事：绕过执行策略

Windows 客户端默认 `ExecutionPolicy = Restricted`，**任何 `.ps1` 直接调用都会失败**：

```
无法加载文件 xxx.ps1，因为在此系统上禁止运行脚本。
FullyQualifiedErrorId : UnauthorizedAccess
```

**所有脚本都必须这样调**（进程级 Bypass，不改系统设置）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\chaoxing.ps1 discover
```

或者让用户双击仓库里的 **`go.cmd`**（已内置 Bypass，还支持 `go.cmd probe|check|login|status|start|verify|setup|skill` 子命令）。

> 本文档后面出现 `.\xxx.ps1` 的地方，一律按上面这种带 Bypass 的形式理解。**这是 100% 会撞上的第一道墙，先过它。**

## 一、动手前先确认三件事

1. **Windows + PowerShell 5.1 以上**（`$PSVersionTable.PSVersion`）。
2. **用户要自己去办的两件事**（你代办不了）：
   - 给 ZError 配 AI 模型 API Key —— 需要用户去阿里云百炼 / 智谱 / DeepSeek 注册拿 Key
   - 网课平台的账号密码 —— 需要用户自己提供
3. **问清楚这次要做什么**：做作业 / 刷课 / 两者。以及**哪个平台、哪门课**。

---

## 二、首次安装

```powershell
cd <项目目录>
.\install-deps.ps1 check      # 看装没装、将装什么版本、上游最新是什么
.\install-deps.ps1 all        # 装 OCS Desktop + ZError
```

**装的是锁定版本**：OCS `3.9.1` / ZError `2.2.5`。

为什么锁版本而不是永远跟最新：3.9.1 的 Electron 开始暴露无障碍树，脚本能用 UIA 按名字精确定位按钮，不再依赖像素坐标。再往后的大版本万一又改了无障碍结构，锁定的这个仍然可用。

想换版本：`.\install-deps.ps1 ocs -Version ocs=<版本号>`，换完跑一次 `up-a` 验证。2.x 还要重新标定（见第五节），3.x 不用。

安装器会：按锁定版本查 GitHub release → 多镜像下载（国内直连 GitHub 文件域名通常不通，会自动切 ghproxy）→ NSIS `/S` 静默安装 → 读注册表复核。

装完必须让用户手动做（**只有第一次**，之后不用再碰）：

**1. ZError**
打开 → 设置 → 模型配置 → 填 AI 平台 API Key → 回主页点右上角「启动」，直到页面上显示 `127.0.0.1:3000`（红点变绿）。

**2. OCS 3.9.1 有初始化向导，三件事一个都不能跳**

| 步骤 | 界面上看到什么 | 要做什么 |
|---|---|---|
| ① 初始化 | 弹窗「OCS 初始化」，文字「正在下载内置浏览器（国内镜像源，第 N 个下载源）… 42%」 | **等进度条走完**。几十秒到几分钟，取决于网速。中途关掉会前功尽弃 |
| ② 欢迎页 | 弹窗「欢迎使用 OCS 桌面软件」，一个蓝色「开始使用」按钮 | 点掉它。不点的话它一直盖在卡片上，脚本点不到底下的按钮 |
| ③ 建浏览器 | 卡片式网格布局，右上角有「新建浏览器」 | 新建一个，**随便起名但一定要记住**，这个名字要填进 `config.json` 的 `ocs.browserName` |

> 3.9.1 是卡片网格布局（2.x 是列表行），每个卡片右上角一个「启动」按钮。脚本靠 UIA 读卡片上的名字文本来定位对应按钮，所以**名字必须和配置里写的一致**。

卡在哪一步的话看第六节的坑位表。

> 如果静默安装失败（退出码非 0、注册表没记录），多半是安全软件拦截。让用户手动双击安装包，不要反复重试。

---

## 三、配置

复制 `config.example.json` 为 `config.json`，填这几项：

| 字段 | 类型 | 说明 | 谁在读 |
|---|---|---|---|
| `ocs.browserName` | string | **第二步在 OCS 里建的那个浏览器名字，必须一字不差** | `chaoxing.ps1` 的 UIA 定位 |
| `accounts.<平台id>.user` | string | 该平台账号 | `login.ps1` |
| `accounts.<平台id>.pass` | string | 该平台密码 | `login.ps1` |
| `calibration.ocsBrowserRun` | `{right, top}` | 像素，距窗口右边缘/顶部。**3.x 走 UIA 不读这里**，只给 2.x 兜底 | `chaoxing.ps1` |
| `calibration.zErrorStartBtn` | `{right, top}` | 同上，ZError 的坐标兜底 | `chaoxing.ps1` |
| `loginLayout.<平台id>` | `{account, password, submit}` | **登录页三个控件的位置**。`config.example.json` 里是**空的**，首次登录会停下要你标定（`exit 2`），标完填进来就能全自动 | `login.ps1` |
| `behavior.windowWaitSeconds` | int | 等窗口出现的上限秒数，机器慢就调大 | `chaoxing.ps1` |

> **只有 `accounts` 是真源。** 不要往 `config.json` 里写 `chaoxing.user` 那种旧格式——脚本不读，改了也静默无效。

`config.json` 含凭据，**必须在 `.gitignore` 里**（仓库已配好）。

---

## 四、每次运行的标准流程

### 阶段 ① 启动编排（你来干）

```powershell
.\chaoxing.ps1 discover     # 确认自动发现到的路径/浏览器都对
.\chaoxing.ps1 start        # 起 ZError → 起 OCS → 起浏览器 → 题库自检
```

**成功标志**（三条都要满足）：

1. ZError 的 `/query` 返回 `code=1`
2. 浏览器进程挂在目标 profile 上
3. 窗口标题含 `导航页`（3.9.1 是「OCS - 快捷导航页」，2.x 是「OCS - 导航页」）

也可以用 `.\run.ps1` 一条命令做完上面这些（它内部就是 `discover` + `start` + 导航 + 截图）。

### 阶段 ①.5 登录检查（每次都要过）

**首跑几乎一定落在登录页**——新 profile 没有 cookie。别手点，用脚本：

```powershell
.\login.ps1 -Platform chaoxing              # 三态判断：已登录放行 / 掉登录自动填表 / 判不了给你截图
.\login.ps1 -Platform chaoxing -CheckOnly   # 只看不登（不导航，只读当前页）
.\login.ps1 -Platform chaoxing -Force       # 强制重登
```

判据：标题出现 `个人空间` / `我的课程` / 学校名 = 已登录；出现 `用户登录` = 没登录。

`-CheckOnly` 的退出码可以直接用来分支：`0`=已登录 / `1`=未登录 / `3`=判不了（看图）。它**不会导航**，只读当前窗口的标题，所以不会把你正在看的页面踢走。

**首跑会多走一步**：新 profile 还没 cookie，加上 `url` 有时静默失败，第一次跑很可能判成 `unknown`。脚本已经会自动再走一遍填表流程，不用你手动加 `-Force`。

**如果它停在「需要标定登录页」**（`exit 2`）：说明 `config.json` 里没有 `loginLayout.<平台id>`。照它输出的四个点（agreement/account/password/submit）量好填进去，之后这个平台就全自动了。`config.example.json` 里这一项是空的，**这是唯一需要亲手标一次的东西**。

`-Platform` 的取值见 `platforms.json`。除 chaoxing 外其他平台入口未实测，落到登录页后按阶段②的截图流程现场校正。

### 阶段 ② 导航到目标页（你来干）

用 `ocs-session.ps1` 这份手眼层：

```powershell
.\ocs-session.ps1 title                 # 读窗口标题，粗判在哪一页
.\ocs-session.ps1 shot before           # 截图到 shots\before.png，然后你读图
.\ocs-session.ps1 clickpx 140 640       # 点窗口内某个像素位置
.\ocs-session.ps1 click 0.5 0.3         # 或者按相对比例点
.\ocs-session.ps1 url "https://..."     # 地址栏直达
.\ocs-session.ps1 type "文字"            # 粘贴式输入（支持中文）
.\ocs-session.ps1 key ctrl+l            # 组合键
```

**核心工作方式**：`shot` → 你读图看懂页面 → 算出该点哪 → `clickpx` → 再 `shot` 确认。平台的入口地址查 `platforms.json`。

### 阶段 ③ 交接给 OCS（你确认后撒手）

判据：页面**左上角**出现 **OCS 悬浮球**。出现了就说明 `ocs.user.js` 已注入，剩下交给它。

**别认错**（实测踩过这个坑）：

| 版本 | 悬浮球长什么样 |
|---|---|
| OCS 3.x | **白色圆角矩形**底 + 里面一个黑色圆形图标（像个小人/旋涡） |
| OCS 2.x | **黑色圆形**底 + 白色「OCS」字样 |

平台自己的 logo 也在左上角附近（比如学习通有个圆形头像），两者容易混。**认错的后果是误判「脚本没注入」然后白折腾一轮**。

### 阶段 ④ 监督与验收

A 道拿不到 DOM，所以验收靠**截图 + 像素差异 + 目视判断**三件套：

```powershell
.\verify.ps1 -Shot                    # 拍一张当证据
.\verify.ps1 -Watch -Interval 60      # 每 60 秒一张，最多 30 张，自己算帧间差异
.\verify.ps1 -Diff a.png,b.png        # 单独比较两张图
.\verify.ps1 -Report                  # 汇总最近一次监控
```

`-Watch` 会自己判断三件事：

| 现象 | 判据 | 含义 |
|---|---|---|
| 在推进 | 帧间差异 ≥ 0.3% | 页面在动，正常 |
| 卡住了 | 连续 3 次差异 < 0.3% | 提前退出并提示你读图 |
| 完成 | 需你自己看最后一张图 | 找「已完成 / 已提交 / 得分」 |

**验收要看的重点**：

- **作业**：页面顶部有没有得分、「已提交」字样；右侧答题卡是否全部变绿/打勾
- **刷课**：视频进度条是否到底、任务点是否打勾、OCS 面板的「已完成 x/y」是否 x=y
- **异常**：验证码弹窗、掉登录（标题变「用户登录」）、报错红字

**只在发现异常时才动手点** —— OCS 在跑脚本时你插手会打断它。

### 阶段 ⑤ 汇报

告诉用户：做了什么、结果如何、证据在哪张截图。别只说「已完成」。
在 IM 会话（QQ/微信机器人）里，用宿主的 IM 文件回传能力把验收截图发回用户手机，附一句结论。

---

## 五、界面坐标标定

OCS / ZError 升级后按钮位置会变，`calibrate` 用来重新量：

```powershell
.\chaoxing.ps1 calibrate     # 截 OCS 窗口到 calibration\ocs-window.png 并打印尺寸
```

`up-a` 三次点击都没命中时会**自动调用 calibrate**，把窗口图和尺寸打给你。

**但先别急着量坐标**——按这个顺序排查：

| 先看什么 | 怎么查 | 处理 |
|---|---|---|
| ① `ocs.browserName` 对不对 | `discover` 输出里的浏览器名字 | **3.x 配置加密，名字会显示成 `(第 N 个浏览器)`**，此时必须对照 OCS 界面里卡片的真名手填，且要一字不差 |
| ② 是不是被「欢迎使用」弹窗挡住了 | `shot` 看 OCS 窗口 | 点掉「开始使用」 |
| ③ OCS 里到底有没有浏览器 | `discover` | 没有就先在 OCS 里新建一个 |
| ④ 上面都对，才轮到坐标漂了 | 走 `calibrate` | 2.x 才需要；3.9.1 走 UIA，基本用不上 |

**最常见的是 ①**，不是坐标问题。名字错了的表现是：UIA 找不到卡片 → 静默退回像素点击 → 三次点空 → 报「需要重新标定」。

然后你读这张图，量出目标按钮中心的像素坐标 `(px, py)`，换算成**距窗口右边缘 / 距顶部**的像素写进 `config.json`：

```json
"calibration": {
  "ocsBrowserRun":  { "right": 77,  "top": 272 },
  "zErrorStartBtn": { "right": 126, "top": 104 }
}
```

`right = 窗口宽度 - px`，`top = py`。**单位是像素，不是比例**——按钮固定在工具栏下方，和窗口高度无关，用比例算窗口一高一矮就偏。

（旧的 `{"x":…,"y":…}` 比例写法脚本仍然兼容，但 `right`/`top` 优先。）

**换浏览器内核也支持**：OCS 可以在设置里把浏览器内核从自带的 Chromium 换成系统 Edge。脚本认 `chrome.exe` / `msedge.exe` / `chromium.exe` 三种进程名，并按 `userDataDirs` 路径过滤，换内核不用改配置。

**ZError 的版本差异不影响自动化**：GitHub 只发布到 2.2.5，官网可能更新（比如 2.2.8）。2.2.x 系列全是功能修复（选项匹配、弹窗 bug、端口占用），主界面没重构过。脚本找 ZError 按钮时用**包含匹配**（`启动`/`开始`/`运行`/`Start` 都认）；OCS 浏览器的「启动」按钮是**精确等于**（靠卡片名字文本定位，所以要一字不差）。

**OCS 3.x 起不需要标定了**：3.9.1 的 Electron 开始暴露无障碍树（实测 81 个元素），`up-a` 会按浏览器名字定位对应的「启动」按钮，直接用 UIA 的 InvokePattern 触发，不受窗口尺寸、位置、DPI 影响。

只有 **OCS 2.x** 才需要标定——那些版本 UIA 后代元素是 0 个，只能靠像素坐标。脚本会自动判断：UIA 能用就走 UIA，用不了才退回坐标，两条路都失败才提示你手动标定。

（ZError 一直是 Tauri + WebView2，UIA 可读，从来不用标定。）

---

## 六、已知坑（按踩坑频率排）

| 现象 | 原因 | 解法 |
|---|---|---|
| OCS 进程秒退、退出码 0、无日志 | 用 `Start-Process` 直连启动 | 必须 `& explorer.exe $exe`（等效双击） |
| 点击没反应 | 目标窗口被别的程序整屏压住，`SetForegroundWindow` 抢不过前台 | 点击前 `SetWindowPos(HWND_TOPMOST)`，点完取消 |
| 找不到窗口 / 找到 18×18 幽灵窗 | `EnumWindows` 读到的是辅助窗 | chrome/OCS 用 `Get-Process.MainWindowHandle`；Tauri 应用用「可见最大窗」 |
| 窗口 rect 是 `-32000` | 最小化状态读的 rect | 先 `ShowWindow(RESTORE)`，睡 600ms，再 `GetWindowRect` |
| 坐标全偏 1.25 倍 | 进程不是 DPI-aware | 脚本开头 `SetProcessDPIAware()` |
| 下载 106MB 卡死 | GitHub 文件域名被墙 | 走 `ghproxy.net` 镜像，安装器已内置多源 |
| `.ps1` 中文乱码、报「缺少 )」 | 存成了 UTF-8 无 BOM，PowerShell 5.1 按 GBK 读 | 必须存 **UTF-8 with BOM** |

---

## 七、边界

- ZError 的 API Key、平台账号密码，**只能用户自己办**
- 撞到滑块验证码，停手截图发给用户，不要瞎试
- 平台前端改版会让导航失效 —— 重新 `shot` 看页面，别硬套旧坐标
- 别把 `config.json`、`shots\` 里的截图提交到 git（截图里有用户的课程、姓名、学号）
