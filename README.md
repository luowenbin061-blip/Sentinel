# Sentinel · 屏幕哨兵 v2.0（iOS 注入插件）

圈一块屏幕区域 → OCR 认出关键字 → 横幅 + 震动报警。
配合 TrollFools 注入到任意 App 使用（未签名裸 dylib）。

## UI 形态

仿老贝贝的「设置弹窗」结构（同一套界面语言）：
**模糊遮罩 → 面板卡片 → 标题栏(标题+渐变高光+关闭按钮) → 内容滚动区(分区：字段标题+控件行+分割线) → 底部按钮栏**

分区：状态 / 监视区域 / 关键词 / 同义词 / 节奏 / 报警方式 / 共存
输入用面板内的**输入卡片**，全程**不使用 UIAlertController**（它和原生 Alert 都不会抢焦点）。

## 它做什么

1. 悬浮球（默认在屏幕**左侧**，可拖动）→ 点开面板
2. 「圈定监视区域」→ 拖出要盯住的矩形（拖动/四角微调/一键全屏）
3. 定时截屏 **只截这一块** → Vision OCR **只跑这一块**
4. 关键字命中（归一化 + 容错 + 同义词 + 置信度阈值）→ 非阻塞横幅 + 震动
5. 同一关键字冷却期内不重复报警

## 设计取舍（为什么这么做）

| 决定 | 原因 |
|---|---|
| OCR 只跑框选区域 | 省一个数量级 CPU；无关文字不进结果，误命中大降 |
| 四级匹配：归一化 / 滑窗容错(编辑距离≤1) / 同义词组 / 置信度阈值 | 游戏字体 OCR 常错字，纯精确匹配召回太低 |
| 连中 2 轮才报警 + 冷却 | 单帧误报最常见的来源 |
| 报警用非阻塞横幅，不用 UIAlertController | Alert 会抢焦点，影响正在操作的 App |
| 声音只用 system sound，不建 AVAudioSession | 同进程里别的插件可能正在用音频会话（例如音量键监听） |
| 悬浮球在左侧、窗口不设 rootViewController、不 makeKeyAndVisible | 与同进程其他插件共存，避免抢 keyWindow / 吞触摸 |
| 监听 `com.changqing.fullTaskExecution` 通知后降频 | 别的插件在点击时，截屏可能干扰它的时序 |
| 配置一律 `sentinel_` 前缀 | 不和别人的 NSUserDefaults 键打架 |

## 配置项（NSUserDefaults，全在 App 沙盒里）

| 键 | 默认 | 说明 |
|---|---|---|
| `sentinel_region` | 无 | `x,y,w,h`（归一化 0~1），由框选界面写入 |
| `sentinel_keywords` | `体力不足,无法操作` | 逗号分隔 |
| `sentinel_synonyms` | `体力不足=体力不够;金币不足=金币不够` | `=` 连同义词，`;` 分组 |
| `sentinel_interval` | 2.0 | 空闲扫描间隔（秒） |
| `sentinel_cooldown` | 10.0 | 同一关键字报警冷却（秒） |
| `sentinel_vibrate` | YES | 震动报警开关 |
| `sentinel_sound` | NO | 声音报警开关（system sound 1007） |
| `sentinel_ball_pos` | 左侧 | 悬浮球位置 `x,y` |
| `sentinel_selftest` | NO | 自测模式（CI 用；不截屏，用现场渲染的假 HUD 图跑完整识别链） |

## 排错

- `idevicesyslog | grep Sentinel` → 实时日志
- 沙盒 `Documents/Sentinel.log` → 滚动日志（菜单里「📋 复制日志」可一键复制）
- 沙盒 `Documents/Sentinel_selftest.txt` → 自测报告
- 菜单里「🔍 试测一次」→ 立刻扫一轮，弹窗告诉你**它到底识别到了什么**（调关键词最快的手段）

## 构建

推 `main` 即触发 GitHub Actions（`macos-14` 云编译，无需 Mac）：

- `build.yml` → 产出 `Sentinel-dylib`（iphoneos / arm64）+ ldid 伪签名
- `simtest.yml` → 模拟器 e2e：编译 simulator 版 → 装 TestHost → `dlopen` 加载 → 跑内置自测 → 断言

模拟器里 arm64 的 `DYLD_INSERT_LIBRARIES` 不生效，所以 TestHost 在 `main.swift` 顶层用 `dlopen` 加载 dylib（等效 TrollFools 的注入时序）。
`-sentinel_selftest 1` 经 `NSArgumentDomain` 传进插件，触发自测。

## 安装（真机）

1. 下载 `Sentinel-dylib` artifact 解压得 `Sentinel.dylib`
2. 传到 iPhone，用 **TrollFools** 注入到目标 App
3. 冷启动 App → 左侧出现「哨」悬浮球 → 点它 → 圈定区域

> 需要 iOS 15+ 且设备已装 TrollStore / TrollFools。
> 插件不发任何网络请求，OCR 全部本地（Apple Vision）。
