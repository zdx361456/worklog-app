# 独立审计报告：`verify_waveC2.dart` / `verify_waveD2.dart` 断言可证伪性

- **审计官**：audit-c2d2（独立，未参与两脚本编写）
- **审计日期**：2026-10-16
- **审计对象**：
  1. `worklog-app/app/tool/verify_waveC2.dart`（696 行）
  2. `worklog-app/app/tool/verify_waveD2.dart`（744 行）
- **方法**：副本变异测试（mutation testing）—— 只改**副本**，注入「语义等价于实现坏了」的最小破坏，重跑脚本，看断言是否置红。
- **硬约束遵守**：只读 `worklog-app/**`（未修改/新建/删除其下任何文件）；全部产物在 `_scratch/audit-c2d2/`；**未执行任何删除命令**。
- **证据分级**：【实测】= 现盘实跑；【读码】= 只读源码推断（**未实测**，不得当作实测）。

---

## 一、基线（命令 + 结果）

副本构建（照主理人方案，主理人已验通）：

```bash
DART="D:/workspace/software/installed/tools/FlyEnv-Data/app/flutter/3.47.4/bin/cache/dart-sdk/bin/dart.exe"
APP="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/worklog-app/app"
WORK="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/_scratch/audit-c2d2"
mkdir -p "$WORK/appcopy/tool"
cp -r "$APP/lib" "$WORK/appcopy/lib"
cp -r "$APP/.dart_tool" "$WORK/appcopy/.dart_tool"
cp "$APP/pubspec.yaml" "$APP/pubspec.lock" "$WORK/appcopy/"
cp "$APP/tool/verify_waveC2.dart" "$APP/tool/verify_waveD2.dart" "$WORK/appcopy/tool/"
cd "$WORK/appcopy" && export WORKLOG_USE_SYSTEM_SQLITE=1
"$DART" --disable-dart-dev tool/verify_waveC2.dart
"$DART" --disable-dart-dev tool/verify_waveD2.dart
```

| 脚本 | 主理人基线 | 审计官副本基线 | 一致？ |
|---|---|---|---|
| `verify_waveC2.dart` | 48 通过 / 0 失败 | **48 通过 / 0 失败**（rc=0） | ✅ |
| `verify_waveD2.dart` | 41 通过 / 0 失败 | **41 通过 / 0 失败**（rc=0） | ✅ |

- Dart SDK 3.13.3（stable）。`.dart_tool/` 已随副本复制（`package_config.json` 中 `worklog_app -> ../` 为相对路径，`../lib/` 自动指向副本）。
- **脚本输入路径核对**（确保读的是副本，非原项目）：
  - C2：`File('lib/ui/export_backup_page.dart')`、`File('lib/services/import_service.dart')`（相对）；其余为真 import。
  - D2：`_read('lib/ui/**.dart')`、`_read('pubspec.yaml')`（相对）；其余为真 import。
  - ⇒ 两者输入均为**相对路径**，副本隔离**成立**（已用「注入后脚本行为变化」反向实证）。

**副本还原机制**：每次注入后用 `cp -r "$WORK/lib_pristine/." "$WORK/appcopy/lib/"` 覆盖还原（`lib_pristine` = 首次复制的只读镜像）；`pubspec.yaml` 用 `cp` 自原项目还原。每次注入前均确认已还原。**审计结束时两条基线均复跑为绿**（C2 48/0、D2 41/0）【实测】。

---

## 二、逐条断言判定表

### 2.1 `verify_waveC2.dart`（48 条）

| # | 断言名（简） | 类 | 判定 | 依据 |
|---|---|---|---|---|
| 1 | 本地格式 id 整体 validate 通过（AC-Q23-01） | A 真运行时 | 真 | 真 import `ImportService.validate`；同族 3 实测红【实测】 |
| 2 | UUID 样本仍通过（AC-Q23-03） | A | 真 | 同上 |
| 3 | 非法 id 被拒绝 | A | **真** | 注入 `_requireUuid` 恒不报 → **红**【实测】 |
| 4 | 连续 1000 个本地 id 无重复（AC-Q23-04） | A | 真 | 真 import `id_gen.newId`【读码】 |
| 5 | companies 含 3 家（含停用+软删） | A（脚本复刻 `buildBackup`） | **假（对交付 UI 方法）** | 见「三·假覆盖 A」；对 DB 层为真【实测/读码】 |
| 6 | 停用公司（乙）在备份内 | A（复刻） | **假（对交付 UI 方法）** | 同上 |
| 7 | 软删公司（丙）在备份内 | A（复刻） | **假（对交付 UI 方法）** | 同上 |
| 8 | workRecords 含 3 条（含草稿+软删） | A（复刻） | **真（对 DB 层）** | 注入 DB 永久排草稿 → **红**【实测】；对 UI 装配为假 |
| 9 | 草稿记录在备份内 | A（复刻） | **真（对 DB 层）** | 同上 → **红**【实测】 |
| 10 | 软删工作记录在备份内 | A（复刻） | 真（对 DB 层） | 同类 DB 读【读码】 |
| 11 | 软删收款在备份内 | A（复刻） | 真（对 DB 层） | 同类【读码】 |
| 12 | 节假日标记在备份内 | A（复刻） | 真 | 同类【读码】 |
| 13 | A1 companies 条数一致 | A（复刻 vs 真 DB 显式读） | 真 | 双侧真 DB【读码】 |
| 14 | A2 pricingRules 条数一致 | A | 真 | 【读码】 |
| 15 | A3 workRecords 条数一致（含草稿） | A | 真 | 【读码】 |
| 16 | A4 paymentRecords 条数一致 | A | 真 | 【读码】 |
| 17 | A5 assertExportConsistency 通过（AC-61） | A（真 SDK） | **假** | 见「三·假覆盖 C」；**无负例对照** → 半 no-op 仍绿【实测】 |
| 18 | 清空后六表为空 | A | 真 | 真 DB【读码】 |
| 19 | 导入 validate 返回空（AC-Q23-02） | A | 真 | 真 import【读码】 |
| 20 | 两份 JSON 逐字节等价（AC-62） | A（复刻装配 + 真 DB/序列化） | 真（对 DB 层） | 注入 DB 排草稿 → 变体红【实测】；对 UI 装配为假 |
| 21 | companies id 集合一致 | A（复刻） | 真（对 DB 层） | 【读码】 |
| 22 | pricing_rules id 集合一致 | A（复刻） | 真（对 DB 层） | 【读码】 |
| 23 | work_records id 集合一致 | A（复刻） | 真（对 DB 层） | 【读码】 |
| 24 | payment_records id 集合一致 | A（复刻） | 真（对 DB 层） | 【读码】 |
| 25 | holiday_marks id 集合一致 | A（复刻） | 真（对 DB 层） | 【读码】 |
| 26 | ledger id 一致 | A（复刻） | 真 | 【读码】 |
| 27 | 往返后软删工作记录仍在 | A（复刻） | **真（对 DB 层）** | 注入 DB 排草稿 → **红**【实测】 |
| 28 | 往返后草稿仍在 | A（复刻） | 真（对 DB 层） | 【读码】 |
| 29 | 坏行时严格读抛错 | A（真 DB） | 真 | 真 `listWorkRecords`【读码】 |
| 30 | 容错读跳过坏行并计数（AC-P13-11） | A（真 DB） | 真 | 真 `listWorkRecordsLenient`【读码】 |
| 31 | CSV 带 UTF-8 BOM | A（真 SDK） | 真 | 真 `ExportService`【读码】 |
| 32 | CSV 金额两位小数 | A（真 SDK） | **真** | 注入 `_yuan` 0 位小数 → **红**【实测】 |
| 33 | CSV 无 ¥ 符号 | A（真 SDK） | 真 | 【读码】 |
| 34 | merge 正常：verifyImportInvariants ok | A（真 SDK 公共函数） | 真 | 真 `verifyImportInvariants`【读码】 |
| 35 | merge 下同 id 分歧保留本机值 | A（真 DB） | 真 | 【读码】 |
| 36 | 反证（旧口径）来件≠本机应收 | A | 真 | 【读码】 |
| 37 | 反证 (A)：本机原有被改写 → 报 (A) | A（真 SDK） | **真** | 注入 `_reportMergeA` (A) 失效 → **红**【实测】 |
| 38 | 反证 (B)：新插入内容≠来件 → 报 (B) | A（真 SDK） | **真** | 注入 (B) 检查失效 → **红**【实测】 |
| 39 | 反证 (C)：id 集合≠前∪来件 → 报 (C) | A（真 SDK） | **真** | 注入 (C) 检查失效 → **红**【实测】 |
| 40 | R57 节假日键集合一致 | A（真 SDK） | 真 | 【读码】 |
| 41 | R57 佐证：节假日 id 已漂移 | A（真 DB） | 真 | 【读码】 |
| 42 | MAJ-3 坏行文案「导出将被中止」 | B 静态文本 | **真** | 注入文案回退伪文案 → **红**【实测】 |
| 43 | MAJ-2 `_autoBackupBeforeOverwrite` 返回 bool | B | 真 | 改签名可置红【读码】 |
| 44 | MAJ-2 `if (!backedUp)` 分支存在 | B | 真 | 删分支可置红【读码】 |
| 45 | MAJ-1 事务内调用 `verifyImportInvariants` | B | **假** | 见「三·假覆盖 D」：只 `contains` 字符串【实测】 |
| 46 | MIN-3 `_startImport` 入口置 `_busy` | B（正则） | 真 | 移位可置红【读码】 |
| 47 | R55 merge (A)(B)(C) 落 import_service | C 计数/文本 | 真（文本级） | 改名可置红；**但纯文本，不能证明 (A)(B)(C) 生效** —— 见「三·假覆盖 B 附注」 |
| 48 | R57 节假日 (ledger_id,date) 为键 | C 文本 | 真（文本级） | 同上 |

### 2.2 `verify_waveD2.dart`（41 条）

| # | 断言名（简） | 类 | 判定 | 依据 |
|---|---|---|---|---|
| 1 | B1a 前置：10-08 命中节假日且非周末 | A 真运行时 | 真 | 真 `resolveDayContext`【读码】 |
| 2 | B1b 节假日 ×3.0 = 96000 | A | **真** | 注入引擎 `hits.add(10)` → **红**【实测】 |
| 3 | B1c 对照：未标记日 1.0× | A | 真 | 【读码】 |
| 4 | B1d 反证：两日金额必不同 | A | **真** | 同上注入 → **红**【实测】 |
| 5 | B2a preset 日闭区间命中 | A（真 DB） | 真 | 【读码】 |
| 6 | B2b 对照：异日不命中 | A | 真 | 【读码】 |
| 7 | B3a 启用规则非空 | A | 真 | 【读码】 |
| 8 | B3b 对照：停用默认不返回 | A | 真 | 【读码】 |
| 9 | B4a 默认值派生链 | A | 真 | 【读码】 |
| 10 | B4b 草稿分支（0→draft/0） | A | 真 | 【读码】 |
| 11 | B4c 反证：非草稿 confirmed/>0 | A | 真 | 【读码】 |
| 12 | B5 自检：10-03 是周六 | A | 真 | 【读码】 |
| 13 | B5a 周六/周日 isWeekend=true | A | **真** | 注入 `isWeekendDate` 去周日 → **红**【实测】 |
| 14 | B5b 反证：周一 isWeekend=false | A | 真 | 【读码】 |
| 15 | A1 `QuickAddSheet.show(` 恰 4 处（E1~E4） | C 计数 | **真** | 4 处单点注入各 → **红**【实测】 |
| 16 | A2 overview 不含 pushNamed(Routes.workForm) | B | **真** | E1 注入 → **红**【实测】 |
| 17 | A3 company_detail 不含 WorkFormPage(companyId: | B | **真** | E2 注入 → **红**【实测】 |
| 18 | A4 day_detail 不含 WorkFormPage(initialDate: | B | **真** | E3 注入 → **红**【实测】 |
| 19 | A5 records 工作分支不含 WorkFormPage(companyId: | B | **真** | E4 注入 → **红**【实测】 |
| 20 | A6 lib/ui 内 WorkFormPage( 恰 1 处 | C 计数 | **真** | E1~E4 任一注入 → **红**【实测】 |
| 21 | A7 quick_add_sheet 四处计数 | C 计数 | 真 | 【读码】 |
| 22 | A8 不含 `_today()` 直传 | B（负） | 真 | 【读码】 |
| 23 | A9 死路由判据 | B | **真** | 复位 `Routes.records` 常量 → **红**【实测】 |
| 24 | A10 workForm ≥1 / paymentForm ==1 活路由 | C 计数 | **真** | 移除 stats_page 活路由 → **红**【实测】 |
| 25 | A11 全改动文件禁浮点 + 检测器自检 | B | 真 | 检测器正负例自检；注入浮点可置红【读码】 |
| 26 | A12 pubspec 未新增依赖 | B | **真** | 加 `shared_preferences` → **红**【实测】 |
| 27 | A13 calendar 含 HolidayMarkPage( + onTap _openDay | B | **真** | 换目标页 AboutPage → **红**【实测】 |
| 28 | A14 onHolidayTap 不在同 line | B 辅助 | 真 | 【读码】 |
| 29 | A15 FAB 形态 | C 计数 | 真 | 【读码】 |
| 30 | A16 两文案各恰 1 处 | C 计数 | **真** | 改名 → **红**【实测】 |
| 31 | A17 `_workDate` 含 `widget.initialDate ?? _today()` | B | **真** | 改 getter 忽略预置 → **红**【实测】 |
| 32 | A18 `const HolidayMarkPage()` 恰 1 | C | **真** | 换目标页 → **红**【实测】 |
| 33 | A19 E3 预置实参正则 | B（实参级） | **真** | E3 注入 → **红**【实测】 |
| 34 | A20 E2 预置实参正则 | B | **真** | E2 注入 → **红**【实测】 |
| 35 | A21 E4 预置实参正则 | B | **真** | E4 注入 → **红**【实测】 |
| 36 | A22 calendar 角标三条件 | B/C 混合 | **真** | onHolidayTap 置 null → **红**【实测】 |
| 37 | A23 records PaymentFormPage 恰 1 | C 计数 | 真 | 【读码】 |
| 38 | A24 E1 实参仅 context | B（实参级） | **真** | E1 注入 → **红**【实测】 |
| 39 | A25 角标图标/GestureDetector/命中区 | B/C 混合 | **真** | 图标改 star → **红**；删 opaque → **红**【实测×2】 |
| 40 | A26 FAB 接线 + 刷新 | B | **真** | onPressed→null → **红**；删 `await _load()` → **红**【实测×2】 |
| 41 | A27 两触发按钮未断线 | B | **真** | 两按钮各置 null → **红**【实测×2】 |

---

## 三、假覆盖清单（报告核心：可直接复现的注入命令 + 重跑输出）

> 通用复现脚手架：`bash "$WORK/run.sh" C2|D2 "标签"`（见 `_scratch/audit-c2d2/run.sh`）。
> 注入点均位于**副本** `$WORK/appcopy/lib/**`，**原项目只读未动**。

### 假覆盖 A（最严重）——「导出全量含草稿」对**交付 UI 方法**为假覆盖

**声称**：脚本头部列 `AC-P13-01`（JSON 导出全量、含草稿、条数一致否则中止）；断言 5~16、§3 的 18~28。

**根因**：`export_backup_page.dart::_buildBackupData()` 是 **UI 私有方法**，脚本无法调用，于是**在脚本内复刻**了一份逐字相同的 `buildBackup()`（`verify_waveC2.dart:94-111`）。脚本 §2/§3 全程只驱动**复刻版**，**从不触达交付实现** ⇒ 真方法被改坏，脚本仍绿（**同构复刻**脆弱性，正是 `import_service.dart:521` 明令「不许同构复刻」的同一风险类别）。

- **注入点**：`lib/ui/export_backup_page.dart:126`（`_buildBackupData` 内 `workRecords` 读参）
- **注入内容（逐字）**：
  - before：`        includeDraft: true,`（该行属 `_buildBackupData` 的 `listWorkRecords(...)` 调用）
  - after：`        includeDraft: false,`
- **命令**：`bash "$WORK/run.sh" C2 "假覆盖A"`
- **重跑输出（实测）**：
  ```
  ----- C2 [注入C2-A：真_buildBackupData的includeDraft:true→false] rc=0 -----
  (无失败断言)
  结果：48 通过 / 0 失败
  ```
- **影响**：脚本「全绿」**不能**支撑 `AC-P13-01`/`AC-P13-03` 在**交付物**上的成立 —— 这正是 Wave C1 同类逃逸（`stats_page` 的 `includeDraft`）的**未修复兄弟**。

> **附注（避免过度指控）**：脚本头部已把该复刻标注为【读码级】，属**已声明的限制**。但断言名仍直接挂 `AC-P13-01`，未加限定；且真实 DB 层部分（断言 8/9/27）**确有证伪力**（见 §四）。故本条判为「**A 层（真 DB）成立、B 层（交付 UI 装配）缺位**」的**层级混同**，而非「整条断言为空」。

### 假覆盖 B——`_doImportTransaction` 的 merge 跳过分支对交付 UI 为假覆盖

**声称**：R55 / `AC-Q23-02`（merge 时本机已有记录不动）；涉及断言 34、35、40、41、45。

**根因**：脚本 §6 用**自身内联事务复刻**了 merge 跳过分支（`verify_waveC2.dart:538-560`），不驱动 UI 的 `_doImportTransaction`。

- **注入点**：`lib/ui/export_backup_page.dart:531-536`（`_doImportTransaction` 内 workRecords 循环）
- **注入内容（逐字）**：
  - before：`          if (strategy == ImportStrategy.merge && localIds.contains(w.id)) {`
  - after：`          if (false) {`
  - （语义 = merge 时不再跳过本机已有 id ⇒ 会覆盖本机记录，即 MAJ-1 那一类回归）
- **命令**：`bash "$WORK/run.sh" C2 "假覆盖B"`
- **重跑输出（实测）**：
  ```
  ----- C2 [注入C2-D：真_doImportTransaction的merge跳过分支失效(会覆盖本机)] rc=0 -----
  (无失败断言)
  结果：48 通过 / 0 失败
  ```
- **附注**：断言 47（R55 静态 `contains("'(A) ")`）只**数字符串**，本注入下仍绿 —— 印证它对「(A)(B)(C) 是否生效」**无证伪力**（其行为证伪力由断言 37/38/39 提供，见 §四）。

### 假覆盖 C——`assertExportConsistency` 无负例对照（半 no-op 仍绿）

**声称**：`AC-P13-02` / `AC-61`（导出文件合计 == App 内合计）；断言 17。

- **注入点**：`lib/services/export_service.dart:277`（`assertExportConsistency` 结尾 return）
- **注入内容（逐字）**：
  - before：`    return modelReceivable == jsonReceivable && modelReceived == jsonReceived;`
  - after：`    return true && modelReceived == jsonReceived;`（应收比较恒真）
- **命令**：`bash "$WORK/run.sh" C2 "假覆盖C"`
- **重跑输出（实测）**：
  ```
  ----- C2 [注入C2-E：assertExportConsistency的应收比较恒真(半no-op)] rc=0 -----
  (无失败断言)
  结果：48 通过 / 0 失败
  ```
- **影响**：断言 17 **只验「正确数据下函数返回 true」**，**缺「不一致数据下应返回 false」的负例对照** ⇒ 无法区分「真校验」与「no-op」。判为**弱断言（无证伪力）**。

### 假覆盖 D——MAJ-1「真实接线」实为字符串存在性

**声称**：MAJ-1 ——「事务内调用 `verifyImportInvariants`（**断言口径真实接线**）」；断言 45。

- **注入点**：`lib/ui/export_backup_page.dart:592`（`_doImportTransaction` 内校验结果消费处）
- **注入内容（逐字）**：
  - before：`        if (!verdict.ok) {`
  - after：`        if (false && !verdict.ok) {`（校验结果被彻底忽略，导入后断言形同虚设）
- **命令**：`bash "$WORK/run.sh" C2 "假覆盖D"`
- **重跑输出（实测）**：
  ```
  ----- C2 [注入C2-G：MAJ-1校验结果被忽略(if(false&&!verdict.ok))] rc=0 -----
  (无失败断言)
  结果：48 通过 / 0 失败
  ```
- **影响**：断言 45 = `page.contains('verifyImportInvariants')`（**B 类整文件 `contains`**），只能证明「字符串在」。断言名含「**真实接线**」但**无接线语义**，属**名实不符**。

---

## 四、真断言清单（置红成功的注入，作为对照）

> 下列均为【实测】置红，证明 C2 的 DB/SDK 驱动部分与 D2 的绝大部分确有证伪力。

### 4.1 C2 实测置红

| 注入点 | 注入内容（before→after） | 变红断言 | 重跑结果 |
|---|---|---|---|
| `import_service.dart:775` `_requireUuid` | `if (v is! String \|\| !_id.hasMatch(v))` → `if (false)` | **#3 非法 id 被拒绝** | 47/1 |
| `db/database.dart:1262` `_workRecordRows` | `if (!includeDraft) "status IN (...)"` → `if (true) "status IN (...)"` | **#8 / #9 / #27 / #37** | 44/4 |
| `import_service.dart:763` `_reportMergeA` | `else if (post[e.key] != e.value)` → `else if (false)` | **#37 反证 (A)** | 47/1 |
| `import_service.dart:663` (B) | `else if (postAll[id] != incAll[id])` → `else if (false)` | **#38 反证 (B)** | 47/1 |
| `import_service.dart:680-681` (C) | `if (lost.isNotEmpty)` / `if (extra.isNotEmpty)` → `if (false)` | **#39 反证 (C)** | 47/1 |
| `export_service.dart:293` `_yuan` | `toStringAsFixed(2)` → `toStringAsFixed(0)` | **#32 CSV 两位小数** | 47/1 |
| `export_backup_page.dart:721` 坏行文案 | `导出将被中止` → `导出仍会原样导出` | **#42 MAJ-3** | 47/1 |

### 4.2 D2 实测置红（全部注入点）

| 注入点 | 注入内容（before→after） | 变红断言 | 结果 |
|---|---|---|---|
| `company_detail_page.dart:198`（E2） | `QuickAddSheet.show(context, companyId: widget.companyId)` → 裸 `WorkFormPage(companyId: widget.companyId)` | **A1/A3/A6/A20** | 37/4 |
| `day_detail_page.dart:182`（E3） | `QuickAddSheet.show(context, date: widget.date)` → 裸 `WorkFormPage(initialDate: widget.date)` | **A1/A4/A6/A19** | 37/4 |
| `overview_page.dart:235`（E1） | `QuickAddSheet.show(context)` → `pushNamed(Routes.workForm)` | **A1/A2/A24** | 38/3 |
| `records_page.dart:307`（E4） | `QuickAddSheet.show(context, companyId: f.companyId)` → 裸 `WorkFormPage(companyId: f.companyId)` | **A1/A5/A6/A21** | 37/4 |
| `calendar_page.dart:359`（E-1） | `Icons.local_offer` → `Icons.star` | **A25** | 40/1 |
| `calendar_page.dart:356`（E-2） | 删 `behavior: HitTestBehavior.opaque,` | **A25** | 40/1 |
| `calendar_page.dart:230`（E-1 入口） | `onHolidayTap: _holidayByDate[key]==null?null:()=>_openHolidayMark()` → `null` | **A22** | 40/1 |
| `overview_page.dart:270`（E-3/E-5） | FAB `onPressed: _openWorkForm` → `null` | **A26** | 40/1 |
| `overview_page.dart` `_openWorkForm`（E-3） | 删 `if (mounted) await _load();` | **A26** | 40/1 |
| `day_detail_page.dart:231`（E-4） | `onPressed: _openWorkNew` → `null` | **A27** | 40/1 |
| `overview_page.dart:747`（E-5） | `onPressed: onPaymentTap` → `null` | **A27** | 40/1 |
| `quick_add_sheet.dart:125`（W5） | `widget.initialDate ?? _today()` → `_today()` | **A17** | 40/1 |
| `stats_page.dart:267` | `pushNamed(Routes.workForm)` → `pushNamed(Routes.companies)` | **A10** | 40/1 |
| `routes.dart:36` | 复位 `static const String records = '/records';` | **A9** | 40/1 |
| `overview_page.dart:749` | `'记一笔收款'` → `'记收款'` | **A16** | 40/1 |
| `calendar_page.dart:163` | `const HolidayMarkPage()` → `const AboutPage()` | **A13/A18** | 39/2 |
| `pubspec.yaml` deps | 新增 `shared_preferences: ^2.0.0` | **A12** | 40/1 |
| `amount_engine.dart:161` | `hits.add(rule.holidayRate)` → `hits.add(10)` | **B1b/B1d** | 39/2 |
| `day_context.dart:44` | `saturday \|\| sunday` → `saturday` | **B5a** | 40/1 |

**★ 单点逃逸专项检验（任务重点）**：D2 的 4 处入口（E1~E4）**逐一单点注入**（只改一处、其余不动），**每一处均置红**（A1 由「恰 4 处」计到 3 ⇒ 计数断言本身可被单点逃逸捕获）。⇒ **D2 入口接线性断言无单点逃逸**；与 `review-d2` 已留痕的 E-1~E-5 置红结论**一致**。

---

## 五、覆盖缺口清单

### 5.1 C2（脚本头部声称覆盖 `§D.11 AC-P13-01/03/07/09/11` + `§C.3.1 AC-Q23-01~04`）

| 缺口 | 详情 | 证据 |
|---|---|---|
| **`AC-P13-07`（id 冲突三选 + `localIds` 六表全量 `includeDeleted:true`）** | 头部**声称覆盖**，但脚本**零断言**：全文无 `planImport` / `_collectLocalIds` / `conflict` / `reject` 字样【读码+实测 grep】 | `grep -n "planImport\|_collectLocalIds\|softWarnings\|AC-P13-07\|conflict\|reject" verify_waveC2.dart` → **无输出** |
| **`AC-P13-09`（导入后断言）** | 仅驱动 **merge** 路径；`overwrite` 策略的「覆盖后应收/已收合计相等」（`verifyImportInvariants` 的 F2 分支，`:582-601`）**未驱动** ⇒ 该分支无证伪力 | 【读码】 |
| **`AC-P13-03`（往返无损）** | 断言 20 有证伪力（对 DB 层），但**装配用复刻**（假覆盖 A） | 【实测】 |
| **`AC-P13-04`（CSV）** | 断言 31~33 缺「**无千分位**」一项（`02:790` 要求）；仅验 BOM / 两位小数 / 无 ¥ | 【读码】 |
| **`AC-P13-08`（覆盖前自动备份）** | 仅断言 43/44 静态文本（返回 bool + `if (!backedUp)`），**未验「失败确实中止」行为** | 【读码】 |
| **`AC-P13-05` / `AC-P13-06`** | 未在头部声称；`AC-P13-06`（`schema_version` 过高专项文案）**完全无断言** | 【读码】 |

### 5.2 D2

| 项 | 结论 |
|---|---|
| 头部声明的「不覆盖 · `[真机]` 档」（弹层实际弹出 / `setState` 时序 / `DropdownButtonFormField.initialValue` / 归属日显示文本 / P12a 实际可达 / FAB 与 4 Tab 不叠压 / 窄屏不溢出） | **声明诚实**，确无断言；属本脚本**能力边界**（纯 Dart 无 Flutter 运行时），非隐瞒 |
| `AC-P02-01`（弹层形态）/ `AC-P02-02~05/07~09`（弹层行为）/ `AC-P02-06`（保存后刷新） | 设计 §9.2 自标 `[真机]`；脚本对 `AC-P02-06` 有**静态代理**（A26②/A27/A16），行为仍待真机 |
| **未发现「声称覆盖却无断言」的缺口** | 设计 §9.2 的 AC 映射逐条与脚本断言对得上（A1~A27 / B1~B5）；静态层的局限**已显式标注** |

---

## 六、结论

### 6.1 可信度评级

| 脚本 | 评级 | 一句话总结 |
|---|---|---|
| **`verify_waveD2.dart`** | **高（A 级）** | 41 条断言中，**24 条经本审计独立注入全部置红**（含 4 处入口单点注入、E-1~E-5 全覆盖、行为层引擎/日历注入）；**未发现假覆盖**；声称与断言名相符，`[真机]` 缺口显式声明。可支撑「入口闭合 + 死路由复核 + AC-P03-06 + P01 FAB」的静态验收。 |
| **`verify_waveC2.dart`** | **中偏低（C 级，且存在 2 条高危假覆盖）** | 48 条中 **DB/SDK 驱动部分（约 30 条）确有证伪力**（8 处独立注入置红）；但**最吃重的 4 条 AC 声明存在假覆盖**：`AC-P13-01/03`（交付 UI 全量装配器 `_buildBackupData` **零覆盖**，同构复刻）、`AC-P13-02/AC-61`（`assertExportConsistency` **无负例对照**）、`MAJ-1`（**字符串存在性冒充「真实接线」**）；且 `AC-P13-07` **声称覆盖但零断言**。「48/0 全绿」**不能**支撑 `AC-P13-01/03/07/09` 的验收结论。 |

### 6.2 最严重 2 条（附注入点 + 复现命令）

1. **【C2·假覆盖 A】交付 UI 的 `_buildBackupData` 漏草稿，脚本仍 48/0 全绿**
   - 注入点：`app/lib/ui/export_backup_page.dart:126`：
     `        includeDraft: true,` → `        includeDraft: false,`
   - 复现：`bash _scratch/audit-c2d2/run.sh C2 "假覆盖A"` → `结果：48 通过 / 0 失败`
   - 危害：脚本 §2/§3 用的是**脚本内复刻**（`verify_waveC2.dart:94-111`），与 Wave C1 抓出的 `stats_page.dart` 同款逃逸；`AC-P13-01`（全量导出含草稿）在**交付物**上**无凭据**。

2. **【C2·假覆盖 D】MAJ-1「真实接线」只做字符串 `contains`，忽略校验结果仍全绿**
   - 注入点：`app/lib/ui/export_backup_page.dart:592`：
     `        if (!verdict.ok) {` → `        if (false && !verdict.ok) {`
   - 复现：`bash _scratch/audit-c2d2/run.sh C2 "假覆盖D"` → `结果：48 通过 / 0 失败`
   - 危害：断言 45 名为「断言口径**真实接线**」，实为整文件 `contains('verifyImportInvariants')`；导入后**不变量校验被整体旁路**（导入破坏性写入的保护网失效）却依然全绿 —— **名实不符 + 安全网静默失效**。

---

## 七、自我限定（哪些断言**没能**注入，及原因 —— 不许猜、不得把【读码】说成【实测】）

**所有「表 2.1/2.2 未标【实测】」的条目均为【读码级判断】**，理由如下：

1. **依赖 Flutter UI 运行时 / `BuildContext` / 平台库**：C2 的 §2/§3 装配链、§7 的 MAJ-2/MIN-3 行为面；D2 的「弹层实际弹出 / `setState` 时序 / P12a 可达 / FAB 布局」—— 需真机或 Flutter 测试宿主，纯 Dart VM 无法驱动 ⇒ **未注入**，标【读码】或直接归入脚本已声明的 `[真机]` 缺口。
2. **需真机系统文件选择器 / 分享**：C2 的 `_exportJson`/`_startImport` 的落盘、`Share.shareXFiles`、`FilePicker` —— 无法在纯 Dart VM 触发。
3. **需构造「运行时坏行 + 严格读」的特定 DB 状态**：C2 断言 29（严格读抛错）依赖把行写成非法值；本轮以**读码**判定（同族 `listWorkRecordsLenient` 的 30 条已在 §6 由 DB 注入间接体现），**未单独构造**。
4. **同一实现落点归组注入**：对「同源」的断言（如 C2 §2 的 5~12、D2 的 A7/A8/A17），按任务允许的「组内一次注入看整组反应」策略执行——**组内未逐条细分归因**的，均已标注【读码】。
5. **`A11`（禁浮点）/`A14`（辅助）/`A23`/`B2`/`B3`/`B4`**：本轮**未单独注入**（读码判定为「可置红」）；不作【实测】宣称。
6. **未做**：其余 `verify_*.dart` 的同等强度审计；对本两脚本的**性能/超时**维度审计；对 `_scratch` 下其他审查官报告的交叉比对（超出本任务范围）。

---

## 附录 A：审计产物清单（均在 `_scratch/audit-c2d2/`）

| 文件 | 说明 |
|---|---|
| `审计报告.md` | 本报告 |
| `run.sh` | 变异运行脚手架（跑脚本 + 只打印失败断言 + 结果行） |
| `baseline_C2.txt` / `baseline_D2.txt` | 基线完整输出 |
| `lib_pristine/` | lib 只读镜像（每次注入后覆盖还原用） |
| `appcopy/` | 副本工作区（`lib/` + `tool/` + `pubspec.yaml` + `.dart_tool/`） |

## 附录 B：复现全部置红/假覆盖的最小步骤

```bash
WORK="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/_scratch/audit-c2d2"
# 假覆盖 A（C2 仍 48/0）：
#   改 appcopy/lib/ui/export_backup_page.dart:126  includeDraft: true -> false
bash "$WORK/run.sh" C2 "假覆盖A"          # → 48 通过 / 0 失败

# 假覆盖 D（C2 仍 48/0）：
#   改 appcopy/lib/ui/export_backup_page.dart:592  if (!verdict.ok) -> if (false && !verdict.ok)
bash "$WORK/run.sh" C2 "假覆盖D"          # → 48 通过 / 0 失败

# D2 单点逃逸检验（应置红）：
#   改 appcopy/lib/ui/company_detail_page.dart:198  QuickAddSheet.show(...) -> 裸 WorkFormPage(...)
bash "$WORK/run.sh" D2 "E2-单点"          # → 37 通过 / 4 失败
```
