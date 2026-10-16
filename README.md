# 工时工资记账 App（worklog-app）

个人使用的**双向台账**记账 App：左边记「应收」（做了多少工时、该拿多少钱），右边记「已收」（实际收到多少），
两边一减就是**还剩多少工资没结**。

- **形态**：Android 单机应用，纯本地 SQLite 存储，**无后端、无账号、无联网**
- **技术**：Flutter + sqflite
- **状态**：基础版已完成，七波交付（A / A2 / B / C1 / C2 / D1 / D2）全部闭环

---

## 一、这是什么

日常接活儿、按工时结算的人，通常要同时回答两个问题：

1. **我干了多少活？该拿多少钱？**（应收）
2. **对方给了我多少钱？还差多少？**（已收 / 差额）

表格软件记这事有两个麻烦：改一次要重算一遍，而且「公司 A 一共差我多少」这种汇总视角很难一眼看到。

这个 App 把两本账做在同一个界面里，差额实时算好；公司维度、日维度、总维度都能下钻看明细。

---

## 二、功能一览

| 页面 | 作用 |
|---|---|
| 总览 | 应收 / 已收 / 剩余工资 三个总口径，点进去看明细 |
| 工作记录 | 按工时记应收，支持价目表自动算钱 |
| 收款记录 | 记实际到账，可指定冲抵哪一笔 |
| 公司 | 按公司分组看往来，支持公司明细页 |
| 日明细 | 某一天干了什么、收了什么 |
| 欠款清单 | 所有未结清项一览 |
| 统计 | 按时间维度的收支走势 |
| 日历 | 工作日 / 休息日标记，节假日标注 |
| 价目表 | 工时单价规则维护 |
| 导出备份 | 导出/导入数据文件，可分享到微信/邮件 |

---

## 三、快速开始（构建 APK）

### 方式一：双击一键脚本（Windows，推荐）

```
build_apk.bat
```

脚本会自动完成：`flutter pub get` → `flutter build apk --release` → 新鲜度校验 → 交付到工程内 `release/` → 同步桌面副本。

产物落在：

```
worklog-app/app/release/worklog-release-latest.apk
```

> **版本轮换规则**：`release/` 里**永远只有一份「最新」**（固定名 `worklog-release-latest.apk`）。
> 每次重新构建，旧的会被自动改名加上**被替换的时间**（`worklog-release-20261013-171000-replaced.apk`）保留下来，只增不删。

### 方式二：手动命令

```bash
cd worklog-app/app
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

### 环境要求

| 组件 | 版本 |
|---|---|
| Flutter | 3.47.4 |
| Dart SDK | ^3.13.3 |
| Java | 17 |
| Gradle | 9.3.1 |
| Android Gradle Plugin | 9.1.0 |
| Kotlin | 2.4.0 |
| Android compileSdk | 36 |

> 根目录 `android/build.gradle.kts` 里有一段 `[compileSdk-fix]` 逻辑，用反射把各子工程的 `compileSdk` 抬到 36 ——
> 因为部分 Flutter 插件仍声明 `compileSdk 34`，新版 AGP 会直接报错。这段逻辑必须在 `subprojects { evaluationDependsOn(":app") }` **之前**注册才生效。

---

## 四、仓库同步与工具脚本

仓库同时推送到两个远端，**都走 SSH 22 端口**（本机 github.com:443 被代理拦死，必须走 SSH），因此推送不需要任何令牌。

| 远端 | 地址 | 可见性 |
|---|---|---|
| `github` | `git@github.com:zdx361456/worklog-app.git` | 公开 |
| `gitee` | `git@gitee.com:clouds_and_clouds_on_the_sea/worklog-app.git` | 公开 |

日常操作**不用记 git 命令**，双击即可：

| 双击这个 | 干什么 |
|---|---|
| `sync-repos.bat` | 提交 → 推 GitHub → 推 Gitee → **校验三处 HEAD 一致** |
| `check-repos.bat` | 只读巡检双仓（不改任何东西） |

对应的脚本在 `tool/`：

| 文件 | 作用 |
|---|---|
| `tool/repos.conf` | **唯一配置点**：远端名 / owner / repo / 分支。换仓库只改这里 |
| `tool/git-sync.sh` | 提交 + 双推 + HEAD 比对。支持 `-m "说明"`、`-n`（演练）、`--push-only`、`--only github\|gitee` |
| `tool/check-repos.sh` | 只读巡检：远端配置 / HEAD 一致性 / 工作区状态 / SSH 连通性；加 `--online` 再查仓库可见性 |
| `tool/cleanup.sh` | 把实施过程中的临时产物送进**回收站**。默认 DRY-RUN，加 `--apply` 才动手 |

> **关于令牌**：脚本设计上**不需要令牌**（走 SSH）。`tool/repos.conf` 里也没有任何密钥。
> 万一将来要查私有仓库，把令牌放在仓库**之外**的 `~/.workbuddy/secrets/worklog.env`，绝不写进本仓库。

### `git-sync.sh` 的一条纪律

推送后**一定回读远端 HEAD 做比对**——因为 `git push` 退出码 0 不等于「远端真的停在这个提交」（受保护分支、pre-receive hook 都可能静默吞掉）。
任一远端对不上，脚本就以非 0 退出并标出来，不会假装成功。

### `cleanup.sh` 的三道闸门

临时产物清理天生危险，所以规则写死在脚本里：

1. **默认 DRY-RUN**。不加 `--apply` 只列清单，一个字节都不动。
2. **永不永久删除**。只走 Windows 回收站（`SHFileOperationW` + `FOF_ALLOWUNDO`），全部可还原。
3. **范围硬闸门**。任何候选只要**不在本仓库根之下**，整体拒绝执行——
   本机 `~/.workbuddy/` 下还有别的独立仓库（各有自己的 `_scratch`），按目录名模糊扫会误伤它们，所以这里是断言而不是靠约定。

---

## 五、目录结构

```
.
├── build_apk.bat                  # 一键出包（Windows）
├── sync-repos.bat                 # 一键提交并推双仓（Windows）
├── check-repos.bat                # 一键双仓巡检（Windows）
├── tool/                          # ★ 仓库运维脚本与配置
│   ├── repos.conf                 #   双远端配置（唯一配置点，无密钥）
│   ├── git-sync.sh                #   提交 + 双推 + HEAD 比对
│   ├── check-repos.sh             #   只读巡检
│   └── cleanup.sh                 #   临时产物送回收站（默认 DRY-RUN）
├── worklog-app/
│   ├── app/                       # Flutter 应用主体
│   │   ├── lib/
│   │   │   ├── app/               # 应用级状态、路由、数据总线
│   │   │   ├── db/                # SQLite 建库与 schema
│   │   │   ├── models/            # 数据模型
│   │   │   ├── services/          # 业务服务层（记账、结算、统计）
│   │   │   └── ui/                # 页面与组件（16 个 *_page.dart + 2 个通用件 + widgets/）
│   │   ├── android/               # Android 工程
│   │   ├── tool/                  # 出包链脚本（publish/stamp/check 等 .py）+ 纯 Dart 验证脚本（verify_*.dart）
│   │   └── release/               # ★ 交付目录：永远只放最新 APK
│   └── docs/                      # 需求 / 设计 / 审查 / 迭代全套文档（30 篇）
└── .gitignore
```

---

## 六、文档

需求到实现的完整链路都在 `worklog-app/docs/`：

| 文件 | 内容 |
|---|---|
| `01-需求理解与边界.md` | 需求澄清、范围边界、明确不做的事 |
| `02-PRD.md` | 产品需求文档（含验收标准） |
| `03-数据模型与信息架构.md` | 表结构、字段、页面信息架构 |
| `04-技术可行性审查.md` | 技术风险与可行性结论 |
| `05-审查报告.md` | 独立审查记录 |
| `06-技术选型对比.md` | 选型对比与理由 |
| `07-UI实现规格.md` | UI 实现规格 |
| `00-开放问题.md` | 开放问题台账 |
| `00-项目总览/DECISIONS.md` | 项目级决策记录 |
| `04-迭代/` | 迭代板块，按日期 + 任务归集 |

---

## 七、开发说明

### 依赖约束

本项目依赖**刻意保持极简**。除 `pubspec.yaml` 中已列出的库外，**不新增任何依赖**（含 `shared_preferences`）：

- `sqflite` / `sqflite_common` —— 本地数据库
- `path_provider` / `share_plus` / `file_picker` —— 仅用于导出备份页（导出 / 导入 / 分享）

### 数据层可脱离 Flutter 验证

数据访问层只依赖 `sqflite_common`（纯 Dart），不直接 `import package:sqflite`。
这样可以在纯 Dart VM 下用 `sqflite_common_ffi` 内存库跑运行时验证（见 `app/tool/verify_*.dart`），
不必启动模拟器。

---

## 八、已知事项

- **交付件入库**：仓库内含约 53 MB 的 APK。每次重新构建都会在 git 历史里新增一个同量级 blob。
  如需长期高频出包，建议后续迁移到 Releases 分发。
- **真机验收**：尚未在真机上完成验收点检，`app/tool/` 下的验证脚本覆盖数据层与业务规则，UI 层以代码审查为主。
