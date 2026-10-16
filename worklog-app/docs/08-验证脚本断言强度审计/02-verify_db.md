# 独立审计报告 · `app/tool/verify_db.dart` 断言强度（变异测试）

- 审计官：`audit-db`（未参与该脚本编写，独立证伪）
- 审计对象：`worklog-app/app/tool/verify_db.dart`（1037 行，93 条 `check()` 断言）
- 被验实现：`worklog-app/app/lib/db/database.dart`（1791 行）+ `lib/services/receivable_service.dart`
- 日期：2026-10-16
- 证据分级：**【实测】**= 真跑脚本 + 注入 + 观察输出；**【读码】**= 仅静态阅读推断；**【类型】**= 结构归类

---

## 0. 结论摘要（先给结论）

**可信度评级：B+（结构上是本项目已审计的 verify 脚本里最强的一个，但存在 7 处实测逃逸缺口）**

一句话总结：**该脚本 93 条断言全部是「真跑 DB 取返回值再比较」的运行时断言（无一条属于 verify_waveC1 那种整文件 `contains`／计数／存在性假断言），"剩余工资"最关键口径链路（应收/已收过滤、SUM 守卫、软删排除、剩余派生）已被实测证明可置红；但 `aggregateByCompany` 的 `remaining` 字段、`listWorkRecords`／`listPaymentRecords`／`listCompanies`／`listPricingRules` 的默认软删过滤、以及 `_recordStatus` 的不安全兜底方向共 7 处实现可被改坏而脚本仍报 93/0 全绿。**

- 实测注入样本数：**28 次**（M1~M33，其中 M3 首次因 SQL 语法破坏作废、已重做）
- 实测变红（真断言）：**21 次注入**触发了置红
- 实测全绿（逃逸 / 缺口）：**7 次注入**改坏后仍 93/0
- 结构性缺陷：**1 项**（`_parseLenient` 改坏 → 脚本崩溃而非置红，且**掩盖其后 36 条断言**）

---

## 1. 基线

副本目录（主理人指定方案，**原项目全程只读**）：

```bash
DART="D:/workspace/software/installed/tools/FlyEnv-Data/app/flutter/3.47.4/bin/cache/dart-sdk/bin/dart.exe"
APP="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/worklog-app/app"
WORK="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/_scratch/audit-db"
mkdir -p "$WORK/appcopy/tool"
cp -r "$APP/lib" "$WORK/appcopy/lib"
cp -r "$APP/.dart_tool" "$WORK/appcopy/.dart_tool"
cp "$APP/pubspec.yaml" "$APP/pubspec.lock" "$WORK/appcopy/"
cp "$APP/tool/verify_db.dart" "$WORK/appcopy/tool/"
cd "$WORK/appcopy" && export WORKLOG_USE_SYSTEM_SQLITE=1 && "$DART" --disable-dart-dev tool/verify_db.dart
```

基线输出：**【实测】`结果：93 通过 / 0 失败`，exit=0**（与主理人报告一致）。

> 计数说明：控制台 "✓" 行共 99 条，其中 6 条是缩进的 `print('    ✓ 消息：...')` 诊断行，**真实断言 = 93 条**。

原项目只读核验：**【实测】** `git status --short -- worklog-app` 输出为空；`lib/db/database.dart` mtime 仍为 `Oct 2 08:01`、`tool/verify_db.dart` 仍为 `Oct 2 08:00`。审计全程仅 Edit 副本 `$WORK/appcopy/lib/**`，每轮用 `cp` 从 `$WORK/pristine/lib` 复位。

辅助脚本：
- `$WORK/run.sh` — 跑副本、输出 `exit=`、`结果：N 通过 / M 失败`、以及全部 `✗` 行到 `$WORK/last.txt`
- `$WORK/restore.sh` — 用 `cp -r pristine/lib/. appcopy/lib/` 复位（**未使用任何删除命令**）
- `$WORK/baseline.txt` — 基线完整输出

---

## 2. 断言清单化 + 分类（Step 2）

### 2.1 分类结果：**全部 93 条 = A 类（真运行时断言）**

脚本没有 `File(...)` / `readAsString` / 源码 grep —— 唯一 import 是 `dart:async`、`dart:ffi`、`dart:io`（`dart:io` 只用于 `Platform` 与 `exit`）。所有断言形如 `check('名称', <对 db 返回值的比较>, [detail])`，末尾统计 `_pass/_fail`。

| 类 | 定义 | 本脚本条数 |
|---|---|---|
| A 类·真运行时断言 | 真跑代码、比较返回值 / DB 状态 | **93** |
| B 类·静态文本断言 | 读源码 + `contains` / 正则 | 0 |
| C 类·计数断言 | 数字符串出现次数 | 0 |
| D 类·存在性断言 | 只查文件 / 符号存在 | 0 |

> 与 `verify_waveC1.dart` 的重大结构差异：**该脚本没有"整文件 contains"式的单点逃逸面**。它的风险不在「假断言」，而在 **A 类断言的覆盖密度**（哪些实现点根本没被任何断言触及）——见 §4。
>
> 唯一 2 条「消息内容」断言（第 66、74 行附近，`'$txtErr'.contains('payment_record.amount')`）仍属 A 类：比较的是**运行时抛出的异常消息**，不是源码文本；且它是**在上一条"必须抛 FormatException"断言之外的下标级加固**，非替代。

### 2.2 章节 ↔ 断言分布（【实测】来自 baseline.txt）

| 节 | 覆盖声明 | 断言数 |
|---|---|---|
| §1 | 六表 CRUD 往返 | 14 |
| §2 | 事务正常提交 | 1 |
| §3 | 事务中途抛错 → 回滚（C-01 关键证据） | 4 |
| §4 | 事务内 `...On` 读未提交数据（C-01 正向） | 2 |
| §5 | 软删后不计入聚合 | 3 |
| §6 | `aggregate` 与 `ReceivableService` 口径一致（d-02） | 16 |
| §7 | 语义钉死：R2-01 + R2-06 | 11 |
| §8 | 脏金额硬化：B3 / R2-04 / G-03 / G-02 | 11 |
| §8b | M-01 聚合类型前置守卫 | 9 |
| §8c | Minor-1 work 侧门禁 + Minor-4 int64 守卫 | 11 |
| §9 | 快照护栏 I-8 / G-11 | 15 |
| §10 | 【反证】事务内调用公开方法会超时 | 2 |
| **合计** | | **93** |

---

## 3. 变异测试（Step 3 · 核心）

注入全部为**语义等价于"实现坏了"的最小破坏**（改常量 / 反转条件 / 换被调函数 / 删分支），**未删改任何断言本身**。每轮注入点均定位到**原项目**行号。

### 3.1 注入台账（M1~M33）

| # | 注入点（原项目行号） | 注入内容（before → after） | 结果 | 判定 |
|---|---|---|---|---|
| M1 | `database.dart:304` | `WHERE deleted_at IS NULL AND status IN ('confirmed','settled')` → `WHERE deleted_at IS NULL` | **5 红** | 真 ✓ |
| M2 | `database.dart:304` | 同上 → `WHERE status IN ('confirmed','settled')` | **6 红** | 真 ✓ |
| M3 | `database.dart:313` | `... payment_record WHERE deleted_at IS NULL` → `WHERE 1=1` | **5 红** | 真 ✓ |
| M4 | `database.dart:313` | 追加 `AND pay_date < '2026-09-30'`（**少算已收 → 剩余虚增**） | **12 红** | 真 ✓ |
| M5 | `database.dart:354` | `WHERE deleted_at IS NULL AND status IN (...)` → 去 status | **1 红** | 真 ✓（单点） |
| M6 | `database.dart:361` | `WHERE deleted_at IS NULL` → `WHERE 1=1` | **1 红** | 真 ✓（单点） |
| M7 | `database.dart:1208` | `_assertAggregateColumnTypes` 开头插 `return;`（守卫停用） | **7 红** | 真 ✓ |
| M8 | `database.dart:1694` | `_asAggregateInt`「REAL 非整」throw → 空块 | **2 红** | 真 ✓ |
| M9 | `database.dart:1701` | `_asAggregateInt` int64 范围 throw → 空块 | **2 红** | 真 ✓ |
| M10 | `database.dart:1732` | `_asAmountColumn`「REAL 非整」throw → 空块 | **6 红** | 真 ✓ |
| M11 | `database.dart:1739` | `_asAmountColumn` int64 范围 throw → 空块 | **1 红** | 真 ✓ |
| **M12** | `database.dart:1312` | `_parseLenient` 的 `catch` 体 → `rethrow;` | **0 红 / 脚本崩溃** | ✗ **结构性缺陷（见 §3.3）** |
| M12b | `database.dart:1312` | `catch` 体 → 空块（坏行静默跳过、不上报） | **3 红** | 真 ✓ |
| **M13** | `database.dart:1262` | `_workRecordRows`：`if (!includeDeleted) 'deleted_at IS NULL',` → `if (false) ...` | **0 红（93/0 全绿）** | ✗ **缺口** |
| **M14** | `database.dart:1288` | `_paymentRecordRows`：同上 | **0 红（93/0 全绿）** | ✗ **缺口** |
| M15 | `database.dart:1150` | `_softDelete`：`{'deleted_at': stamp, 'updated_at': stamp}` → `{'updated_at': stamp}` | **2 红** | 真 ✓ |
| M16 | `database.dart:473` | `listCompaniesOn`：`if (!includeDisabled) 'enabled = 1',` → `if (false) ...` | **3 红** | 真 ✓ |
| M17 | `database.dart:1135` | `_write`：`ConflictAlgorithm.replace` → `ConflictAlgorithm.ignore` | **3 红** | 真 ✓ |
| M18b | `database.dart:867` | `replaceWorkRecordSnapshotOn`：`'amount_snapshot': amountSnapshot,` → `: current.amountSnapshot,` | **2 红** | 真 ✓ |
| M20 | `database.dart:324` | `aggregateOn`：`remaining: receivable - received` → `received - receivable` | **4 红** | 真 ✓ |
| **M21** | `database.dart:1640` | `_recordStatus`：兜底 `RecordStatus.draft` → `RecordStatus.confirmed` | **0 红（93/0 全绿）** | ✗ **缺口** |
| M22 | `database.dart:305,314` | `aggregateOn`：`companyId == null ? null : 'company_id = ?'` → `null`（两家都改） | **14 红** | 真 ✓ |
| M24 | `database.dart:1241` | `_sumInt`：删 `await _assertAggregateColumnTypes(executor, table, column);` | **5 红** | 真 ✓ |
| **M26** | `database.dart:377` | `aggregateByCompanyOn`：`remaining: receivable - received` → `received - receivable` | **0 红（93/0 全绿）** | ✗ **缺口** |
| **M27** | `database.dart:472` | `listCompaniesOn`：`if (!includeDeleted) 'deleted_at IS NULL',` → `if (false) ...` | **0 红（93/0 全绿）** | ✗ **缺口** |
| **M28** | `database.dart:557` | `listPricingRulesOn`：`if (!includeDeleted) 'deleted_at IS NULL',` → `if (false) ...` | **0 红（93/0 全绿）** | ✗ **缺口** |
| **M29** | `database.dart:1263` | `_workRecordRows`：`if (!includeDraft) "status IN ('confirmed','settled')",` → `if (false) ...` | **0 红（93/0 全绿）** | ✗ **缺口** |
| M31 | `database.dart:1579` | `_workRecordFromRow`：`deletedAt: _parseDate(r['deleted_at'])` → `deletedAt: null` | **2 红** | 真 ✓ |
| M32 | `database.dart:558` | `listPricingRulesOn`：`if (!includeDisabled) 'enabled = 1',` → `if (false) ...` | **1 红** | 真 ✓ |
| M33 | `database.dart:1119` | `deleteHolidayMarkOn`：`await executor.delete(...)` → 空操作 | **2 红** | 真 ✓ |

### 3.2 关键实测输出（选取核心 3 条）

**M4 —— 「少算已收 → 剩余虚增」唯一不可容忍方向，实测被捕获（12 红）**

复现命令：
```bash
# 在副本 lib/db/database.dart:313 把
#   'SELECT COALESCE(SUM(amount), 0) AS total FROM payment_record WHERE deleted_at IS NULL',
# 改为
#   "SELECT COALESCE(SUM(amount), 0) AS total FROM payment_record WHERE deleted_at IS NULL AND pay_date < '2026-09-30'",
bash "$WORK/restore.sh"   # 先复位，再手工注入该行，然后：
bash "$WORK/run.sh"
```
```
结果：81 通过 / 12 失败
  ✗ [55555555-...] 已收 db==service  (db=0 svc=12000)
  ✗ [55555555-...] 剩余 db==service  (db=30000 svc=18000)
  ✗ [66666666-...] 已收 db==service  (db=0 svc=1000)
  ✗ [66666666-...] 剩余 db==service  (db=7000 svc=6000)
  ✗ 公司C 已收 = 12000（软删收款排除）  (实际 0)
  ✗ 公司C 剩余 = 18000  (实际 30000)
  ✗ 全局已收 db==service（全量回读，含软删）  (db=0 svc=18000)
  ✗ G-03 aggregate 对 REAL 非整金额抛 FormatException（不再静默截断）  (（未抛错 → 聚合被静默截断！）)
  ✗ M-01 对照组：int + 无损 REAL(24000.0) 不触发守卫（不误伤，received=48000）  (err=null received=0)
  ✗ Minor-4① 聚合路径 `1e20` → aggregate 抛 FormatException（不静默钳位）  (实际 null)
  ✗ Minor-4① 消息区分「超 int64 范围」（非「非整/非法」）  (实际 null)
  ✗ Minor-4 反向对照：int64 内 `48000.0` → 放行（不误伤，received=48000）  (err=null received=0)
```
→ **核心风险方向有真断言兜底**，且是**多重冗余**（4 条独立断言同时置红）。这是本脚本最有价值的部分。

**M13 —— `listWorkRecords` 默认软删过滤：改坏后 93/0 全绿**

```bash
# 副本 lib/db/database.dart:1262
#   before:  if (!includeDeleted) 'deleted_at IS NULL',
#   after :  if (false) 'deleted_at IS NULL',
bash "$WORK/run.sh"
```
```
exit=0
结果：93 通过 / 0 失败
--- 变红断言 ---
(无变红)
```
→ **实测逃逸确认**。

**M12 —— `_parseLenient` 改坏：不是置红，而是崩溃 + 掩盖后半脚本**

```bash
# 副本 lib/db/database.dart:1312  catch 体整体替换为 `rethrow;`
bash "$WORK/run.sh"
```
```
exit=255
崩溃前通过条数: 57
Unhandled exception:
#0  AppDatabase._asAmountColumn (appcopy/lib/db/database.dart:1727:9)
#4  main (appcopy/tool/verify_db.dart:548:21)   ← final lenient = await db.listPaymentRecordsLenient();
--- 变红断言 ---
(无变红)
```
→ 根因：`verify_db.dart:548` 的 `db.listPaymentRecordsLenient()` **未包在 `try` 中**；异常直接冒泡终止进程 → **第 58~93 条断言从未执行**（36 条被掩盖）。

### 3.3 归因（层级分离 A≠B）

- M24（只删 `_sumInt` 的守卫调用）→ 5 红，而 **`M-01③`「同 TEXT 脏值 → aggregateByCompany 抛」保持绿**。因为 `aggregateByCompanyOn`（`database.dart:342-343`）**自带**两次守卫调用。→ **两条守卫调用点各自被独立断言覆盖，归因清晰，无交叉污染**。
- M8（只删 `_asAggregateInt` 的 REAL 非整分支）→ 只红 `G-03` 两条；`B3`（行映射路径）保持绿 —— 证明 `_asAggregateInt` 与 `_asAmountColumn` **两条路径被分别断言**，未互相冒充。
- M5 / M6（`aggregateByCompanyOn` 的 work / payment 过滤）→ 各只红 1 条，且**只红 `[公司C]` 不红 `[公司D]`**（D 无草稿/软删数据）→ 归因精确到单点。

---

## 4. 假覆盖清单（Step 3 产出核心）

> 说明：本脚本无「假断言」（B/C/D 类），下列 7 条严格说是**实现可被改坏而脚本仍全绿**——即**断言未覆盖的 AC 面**。按本项目「置红律」，一律记为**逃逸**。

| # | 断言名 / 声称语义 | 注入点 | before → after | 重跑输出 | 严重度 |
|---|---|---|---|---|---|
| **G1** | §6 声称覆盖"软删后不计入"（聚合口径）——但**行读路径的软删过滤无断言** | `database.dart:1262`（`_workRecordRows`） | `if (!includeDeleted) 'deleted_at IS NULL',` → `if (false) 'deleted_at IS NULL',` | `结果：93 通过 / 0 失败`（exit=0） | **高**：`listWorkRecords()` 默认会把已软删记录返回给明细页/统计页 |
| **G2** | 同上（收款侧） | `database.dart:1288`（`_paymentRecordRows`） | 同上 | `结果：93 通过 / 0 失败`（exit=0） | **高**：已删收款会进明细与派生统计 |
| **G3** | §6 分组聚合一致性断言（#37~#40）**只比 `receivable` / `received`，从不比 `remaining`** | `database.dart:377`（`aggregateByCompanyOn`） | `remaining: receivable - received,` → `remaining: received - receivable,` | `结果：93 通过 / 0 失败`（exit=0） | **高**：**就在"剩余"方向上**；公司列表页（P06）每行剩余会全变负号而无人察觉 |
| **G4** | 头部 M-03 声称"`_recordStatus` 兜底方向必须安全"（已从 confirmed 纠正为 draft）——**无任何脏状态用例** | `database.dart:1640` | `RecordStatus.draft;` → `RecordStatus.confirmed;` | `结果：93 通过 / 0 失败`（exit=0） | **中高**：脏状态行会被计入应收 → 剩余虚增（正是 M-03 当初要防的方向） |
| **G5** | §7 只断言 `listCompanies` 的 **`enabled`** 过滤，未断言其**软删**过滤 | `database.dart:472` | `if (!includeDeleted) 'deleted_at IS NULL',` → `if (false) ...` | `结果：93 通过 / 0 失败`（exit=0） | **中** |
| **G6** | §7 只断言 `listPricingRules` 的 **`enabled`** 过滤（M32 真红），未断言其**软删**过滤 | `database.dart:557` | 同 G5 | `结果：93 通过 / 0 失败`（exit=0） | **中** |
| **G7** | §7 声称"草稿不计入应收（AC-32）"——但只验了聚合 SQL；`listWorkRecords(includeDraft: false)` 这条口径**从未被调用** | `database.dart:1263` | `if (!includeDraft) "status IN ('confirmed','settled')",` → `if (false) ...` | `结果：93 通过 / 0 失败`（exit=0） | **中高**：`lib/ui/calendar_page.dart:93` 正是用 `includeDraft: false`（AC-P03-04 日历色点/日小计）；该口径失效脚本完全看不见 |

### 4.1 结构性缺陷（非"假覆盖"，但违反「单点归因」纪律）

| # | 现象 | 证据 | 影响 |
|---|---|---|---|
| **S1** | `verify_db.dart:548` 的 `db.listPaymentRecordsLenient()` **未包 `try`** | M12 实测：`rethrow` 注入 → `exit=255`，`崩溃前通过条数: 57`，`(无变红)` | ① 强依赖 **exit code** 才能发现（若下游只看"通过/失败"计数会误判）；② **后 36 条断言（§8b 尾部 + §8c + §9 + §10）全部被掩盖**，无法单点归因 |
| **S2** | §9/§10 大量 `await db.xxx(...)` 不在 `try` 中（如 `verify_db.dart:856`、`905`、`938`、`980`） | 【读码】：若 `updateWorkRecordMeta` 越界写入触发内部 `_assertSnapshotUnchanged` 的 `StateError`，脚本将崩溃而非置红 | 同 S1 ② |

> 建议（非本次交付范围）：把 §8 之后的每个 `await` 段落包 `try/catch`，或在 `main()` 外层统一捕获并保证打印 `结果：N 通过 / M 失败` 后再 `exit`。

---

## 5. 逐条断言判定表（Step 2 + Step 3 合并）

> 判定口径：
> - **真【实测】** = 至少 1 次注入使该断言变红（附注入编号）
> - **真【读码】** = 断言结构上直接比较运行时返回值/异常类型，指向明确；**本次未对其单独注入**（原因见 §6 自我限定）
> - **弱** = 断言存在但在本数据集下**不可否证**（构造上重言）

### §1 六表 CRUD 往返（14 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| ledger 往返：name/currency/mode | A | 真【读码】 | 直读 `getLedger` 三字段比较 |
| ledger list = 1 | A | 真【读码】 | 直读 `listLedgers().length` |
| company 往返：name/color/enabled/ledgerId | A | 真【读码】 | 直读 `getCompany` 四字段 |
| company 按账本过滤 = 1 | A | 真【读码】 | `listCompanies(ledgerId:)` 计数 |
| pricing_rule 往返：method/baseRate/倍率 | A | 真【读码】 | 直读 `getPricingRule` |
| work_record 往返：amountSnapshot/mode/appliedRate | A | 真【读码】 | 走 `_asAmountColumn` 行映射 |
| work_record 可空字段保留 null | A | 真【读码】 | 比较 `note`/`deletedAt` |
| payment_record 往返：amount/method | A | 真【读码】 | 直读 `getPaymentRecord` |
| holiday_mark 按 id 往返 | A | 真【读码】 | `getHolidayMark().type` |
| holiday_mark 按 (ledger,date) 反查命中 | A | 真【读码】 | `getHolidayMarkByDate().rate` |
| holiday_mark 未标记日返回 null | A | 真【读码】 | 比较 null |
| holiday_mark list = 1 | A | 真【读码】 | 计数 |
| **holiday_mark 物理删除生效** | A | **真【实测】** | **M33** 使 `deleteHolidayMarkOn` 空操作 → 红 |
| **company update 生效** | A | **真【实测】** | **M17** 使 `_write` 改 `ignore` → 红 |

### §2 事务正常提交（1 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| 事务提交：3 条全部落库 | A | 真【读码】 | `before/after` 计数差 == 3；依赖 sqflite 事务语义 |

### §3 事务回滚（C-01 关键证据）（4 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| 异常已向上抛出 | A | 真【读码】 | `catch` 置 `threw`；框架行为 |
| 回滚：工作记录数量不变（无部分写入） | A | 真【读码】 | 计数比较 |
| 回滚：被写入的收款记录不存在 | A | 真【读码】 | `getPaymentRecord == null` |
| 回滚：被写入的工作记录不存在 | A | 真【读码】 | `getWorkRecord == null` |

> 说明：这 4 条验的是 **sqflite 事务语义**，非本项目业务代码；**未做注入**（破坏 `transaction` 封装无法在不引入死锁/编译错误的前提下做到"语义等价的最小破坏"）。

### §4 事务内 `...On` 读未提交（2 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| 事务内 aggregateOn 读到未提交写入 | A | 真【读码】 | `inside == outsideBefore + 999`，是**差值式**断言（非恒真） |
| 提交后事务外 aggregate 同步可见 | A | 真【读码】 | `outsideAfter == outsideBefore + 999` |

### §5 软删后不计入聚合（3 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| 新增 confirmed 记录后应收 +7777 | A | 真【读码】 | 差值式 |
| **软删后应收回落（不计入）** | A | **真【实测】** | **M2 / M15** 均使此条红 |
| **软删记录仍可按 id 读出（带 deleted_at）** | A | **真【实测】** | **M15 / M31** 均使此条红 |

### §6 `aggregate` 与 `ReceivableService` 口径一致（16 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| [C] 应收 db==service | A | **真【实测】** | M1 / M2 / M22 |
| [C] 已收 db==service | A | **真【实测】** | M3 / M4 / M22 |
| [C] 剩余 db==service | A | **真【实测】** | M4 / M20 / M22 |
| [D] 应收 db==service | A | **真【实测】** | M22 |
| [D] 已收 db==service | A | **真【实测】** | M4 / M22 |
| [D] 剩余 db==service | A | **真【实测】** | M20 / M22 |
| 公司C 应收 = 30000（草稿与软删均排除） | A | **真【实测】** | M1 / M2 / M22 |
| 公司C 已收 = 12000（软删收款排除） | A | **真【实测】** | M3 / M4 / M22 |
| 公司C 剩余 = 18000 | A | **真【实测】** | M4 / M20 / M22 |
| 全局应收 db==service（全量回读…） | A | **真【实测】** | M2 / M4 / M22 / M31 |
| 全局已收 db==service（全量回读，含软删） | A | **真【实测】** | M3 / M4 / M22 |
| 全局剩余 = 全局应收 − 全局已收 | A | **真【实测】** | M20 |
| [C] aggregateByCompany 应收一致 | A | **真【实测】** | M5（单点归因） |
| [C] aggregateByCompany 已收一致 | A | **真【实测】** | M6（单点归因） |
| [D] aggregateByCompany 应收一致 | A | **弱** | 公司 D 无草稿/软删 → 与本数据集下"去 status 过滤"不可区分（M5 未使其红） |
| [D] aggregateByCompany 已收一致 | A | **弱** | 同上（M6 未使其红）；且两条**均不比 `remaining`** |

> ⚠️ **本组最重要的缺口（G3）**：`aggregateByCompany` 的 `remaining` 字段（公司列表页每行剩余的唯一来源）**无任何断言**——M26 实测全绿。

### §7 语义钉死 R2-01 / R2-06（11 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| R2-01 插入后 (ledger,date) 命中旧 id | A | 真【读码】 | 比较 `.id == oldId` |
| R2-01 同 (ledger,date) 换 id upsert **不抛异常** | A | 真【读码】 | `!threw`（若 `_write` 改成 IGNORE 也不抛 → 本条不敏感；靠后两条抓） |
| **R2-01 换 id 后该 (ledger,date) 行数仍为 1** | A | **真【实测】** | M17 / M33 均红 |
| **R2-01 换 id 后 (ledger,date) 指向新 id** | A | **真【实测】** | M17 红 |
| **R2-01 旧 id 行已被物理删除（悬空）** | A | **真【实测】** | M17 红 |
| **R2-06 listCompanies 默认排除停用公司** | A | **真【实测】** | M16 红 |
| **R2-06 listCompanies 默认不含停用公司** | A | **真【实测】** | M16 红 |
| R2-06 listCompanies(includeDisabled:true) 含停用公司 | A | 真【读码】 | `all.any(...)` |
| **R2-06 includeDisabled 前后差值 = 1** | A | **真【实测】** | M16 红 |
| **R2-06 listPricingRules 默认排除停用规则（对称）** | A | **真【实测】** | M32 红 |
| R2-06 listPricingRules(includeDisabled:true) 含停用规则 | A | 真【读码】 | `.length == 1` |

### §8 脏金额硬化 B3 / R2-04 / G-03 / G-02（11 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| **B3 getPaymentRecord 对 REAL 非整金额抛 FormatException** | A | **真【实测】** | M10 红 |
| **B3 listPaymentRecords 对同脏值抛 FormatException（I-9 交互面）** | A | **真【实测】** | M10 红 |
| **G-03 aggregate 对 REAL 非整金额抛 FormatException** | A | **真【实测】** | M4 / M8 红 |
| **G-03 aggregateByCompany 对同脏值同样抛 FormatException** | A | **真【实测】** | M8 红 |
| **G-02 listPaymentRecordsLenient 不抛错（坏行隔离）** | A | **真【实测】** | M10 / M12b 红（**M12 → 崩溃，见 S1**） |
| **G-02 坏行清单含脏值 id 且可定位** | A | **真【实测】** | M10 / M12b 红（同上 S1） |
| **G-02 坏行 error 为 FormatException** | A | **真【实测】** | M10 / M12b 红（同上 S1） |
| **G-02 严格读法默认行为不变（listPaymentRecords 仍抛错）** | A | **真【实测】** | M10 红 |
| G-02 无坏行时容错读与严格读行数一致且 skipped=0 | A | **弱** | 左右值同源于 `_workRecordRows`，过滤改动会同向变化 → M13 实测证明抓不住 |

### §8b M-01 聚合类型前置守卫（9 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| **M-01 清掉 REAL 脏行后 aggregate 恢复（received=0）** | A | **真【实测】** | M22 顺带红（绝对值锚点） |
| **M-01 对照组：int + 无损 REAL(24000.0) 不误伤（received=48000）** | A | **真【实测】** | M4 / M22 红 |
| **M-01① TEXT 脏值 → aggregate 抛 FormatException** | A | **真【实测】** | M7 / M24 红 |
| **M-01① 抛错消息含列名 `payment_record.amount` 与具体 typeof** | A | **真【实测】** | M7 / M24 红 |
| **M-01③ 同 TEXT 脏值 → aggregateByCompany 抛** | A | **真【实测】** | M7 红（M24 未红 → 归因 `aggregateByCompanyOn:342-343` 自带守卫） |
| **M-01② BLOB(X'00') 脏值 → aggregate 抛** | A | **真【实测】** | M7 / M24 红 |
| **M-01 收尾：清理脏行后 aggregate 恢复（received=0）** | A | **真【实测】** | M22 顺带红 |

### §8c Minor-1 门禁 + Minor-4 int64（11 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| Minor-1 对照组：干净 work 数据不触发 work 侧守卫 | A | 真【读码】 | `okWorkErr == null`（防误伤） |
| **Minor-1① work_record.amount_snapshot=TEXT → aggregate 抛** | A | **真【实测】** | M7 / M24 红 |
| **Minor-1① 抛错消息含列名 `work_record.amount_snapshot`** | A | **真【实测】** | M7 / M24 红 |
| **Minor-1③ 同脏值 → aggregateByCompany 抛** | A | **真【实测】** | M7 红（M24 未红，归因同上） |
| **Minor-4① 聚合路径 `1e20` → aggregate 抛（不静默钳位）** | A | **真【实测】** | M9 红 |
| **Minor-4① 消息区分「超 int64 范围」** | A | **真【实测】** | M9 红 |
| **Minor-4② 行映射路径 `1e20` → getPaymentRecord 抛** | A | **真【实测】** | M11 红 |
| Minor-4 反向对照：int64 内 `48000.0` → 放行（received=48000） | A | 真【读码】 | 防误伤；M4/M22 红证明其对绝对值敏感 |
| **Minor-1/4 收尾：清理后 aggregate 恢复（received=0）** | A | **真【实测】** | M22 顺带红 |

### §9 快照护栏 I-8 / G-11（15 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| G-11 meta：note 已更新 | A | 真【读码】 | 直读回写值 |
| G-11 meta：status 已更新 | A | 真【读码】 | 直读回写值 |
| G-11 meta：快照四件套不变 | A | 真【读码】 | 行为断言（比较更新前后快照）——注意其**不是**对 `_assertSnapshotUnchanged` 护栏本身的断言 |
| G-11 meta：未传的 workDate 保留原值 | A | 真【读码】 | 直读 |
| G-11 meta：未传的 quantity/公司 等非 Meta 列不受影响 | A | 真【读码】 | 直读 |
| G-11 meta：workDate 可单独更新 | A | 真【读码】 | 直读 |
| G-11 meta：更新 workDate 时 note 仍保留 | A | 真【读码】 | 直读 |
| G-11 meta：不存在的 id 抛 StateError | A | 真【读码】 | 异常类型比较 |
| **G-11 snapshot：amount/rate/amountSource/autoRef 已覆盖** | A | **真【实测】** | M18b 红 |
| G-11 snapshot：倍率明细已覆盖（overtime true→false, applied 15→10） | A | 真【读码】 | 逐字段比较 |
| G-11 snapshot：Meta 列不受影响 | A | 真【读码】 | 直读 |
| G-11 snapshot：可空列传 null → 清空 | A | 真【读码】 | 比较 4 个 null |
| G-11 snapshot：非空列传 null → 保留现值 | A | 真【读码】 | 比较 quantity==8 |
| G-11 snapshot：不存在的 id 抛 StateError | A | 真【读码】 | 异常类型比较 |
| **G-11 事务内 On 变体生效（note + amount 同事务写入）** | A | **真【实测】** | M18b 红 |

### §10 【反证】事务内调用公开方法会超时（2 条）

| 断言名 | 类 | 判定 | 依据 |
|---|---|---|---|
| 事务内调用公开方法 → 超时未完成（TimeoutException） | A | 真【读码】 | 严格要求 `is TimeoutException`；验的是 **sqflite 重入缺陷存在**，无法注入（见 §6） |
| 未出现预期外异常类型（非超时 / 非重入锁定错误） | A | **弱** | 判据 `isTimeout \|\| isLockError \|\| caught == null` —— 若将来该死锁行为被"修好"（不抛异常），`caught == null` 会让**本条保持绿**；真正兜底的是上一条 |

---

## 6. 覆盖缺口清单（Step 4）

### 6.1 头部/章节"自述覆盖"逐条核对

| 自述 | 是否真有断言 | 核实结论 |
|---|---|---|
| 1. 六表基本 CRUD 往返 | ✅ | §1 共 14 条，实测 M17/M33 可置红 |
| 2. 事务正常提交（bulk + 数量） | ✅ | §2 1 条（计数式） |
| 3. 事务中途抛错 → 整体回滚（C-01 关键证据） | ✅ | §3 共 4 条（验 sqflite 语义） |
| 4. `aggregate` 应收/已收/剩余 与 Service 口径一致（d-02） | ✅ | §6 共 16 条，实测可置红；**但 `aggregateByCompany.remaining` 无断言（G3）** |
| 5. 软删后不计入聚合 | ⚠️ **部分** | **聚合路径**有断言（M2 实测）；**行读路径（`listWorkRecords` / `listPaymentRecords`）默认软删过滤无断言（G1/G2 实测全绿）** |
| 6. 事务内 `...On` 能读到未提交数据 | ✅ | §4 2 条（差值式） |
| 7. 语义钉死：R2-01 / R2-06 | ✅ | §7 共 11 条，实测 M16/M17/M32 可置红 |
| 8. 脏金额硬化 B3 / R2-04 / G-03 / **M-01** | ✅ | §8 + §8b，实测 M7/M8/M10/M11/M24 可置红 |
| 8b. 0-A.1：Minor-1 work 侧门禁 / Minor-4 int64 守卫 | ✅ | §8c，实测 M9/M11/M24 可置红 |
| 9. 快照护栏 I-8 / G-11 | ✅ | §9 共 15 条，实测 M18b 可置红 |
| 10. 【反证】事务内调用公开方法会超时 | ✅（弱） | §10 2 条；第 99 条判据过宽（见上表"弱"） |

### 6.2 未覆盖但属本项目口径/AC 的实现点（【实测】证实可改坏而全绿）

| 缺口 | 关联 AC / 纪律 | 风险方向 |
|---|---|---|
| **`aggregateByCompany.remaining`（database.dart:377）** | 剩余工资四方一致（AC-33）；公司列表页 P06 每行剩余 | **剩余**（唯一不可容忍方向） |
| **`listWorkRecords` 默认软删过滤（:1262）** | 软删约束 §8#3 | 明细/统计显示已删记录 |
| **`listPaymentRecords` 默认软删过滤（:1288）** | 同上 | 已删收款计入派生 |
| **`listWorkRecords(includeDraft:false)`（:1263）** | AC-32 / AC-P03-04（`calendar_page.dart:93` 在用） | 日历色点/日小计把草稿计入 |
| **`listCompanies` 默认软删过滤（:472）** | 公司软删 | 停用/已删公司串入列表 |
| **`listPricingRules` 默认软删过滤（:557）** | 规则软删 | 已删规则串入选择器 |
| **`_recordStatus` 兜底方向（:1638-1640）** | **M-03 修复本身** | **虚增**（脏状态兜底 confirmed → 计入应收） |
| `_assertSnapshotUnchanged` 护栏自身（:1332-1351） | G-11 运行期兜底 | 护栏失效不会被发现（§9 只验行为、不验护栏） |

> **覆盖率粗估**：本次对 `database.dart` 的**口径相关实现点**共做 28 次有效注入，**7 次逃逸（25%）**。若只统计"剩余工资口径"（应收/已收/剩余过滤与派生）相关注入 M1~M6、M20、M22、M26 共 9 次，逃逸 1 次（M26 `aggregateByCompany.remaining`），**口径主线覆盖率 8/9 ≈ 89%**。

---

## 7. 结论

- **可信度评级：B+**
  - 加分：93 条**全为 A 类运行时断言**，无 `verify_waveC1.dart` 那种"整文件 contains"假断言；"剩余工资"主线（应收/已收/软删/守卫/剩余派生）**多重冗余可置红**（M4 一次注入触发 12 条红）；守卫的**双调用点归因清晰**（M24 精确区分 `_sumInt` 与 `aggregateByCompanyOn`）。
  - 扣分：**7 处实现可改坏而仍报 93/0 全绿**（§4），其中 **G3（`aggregateByCompany.remaining`）与 G4（`_recordStatus` 兜底）直接落在"剩余"方向**；**G7（`includeDraft:false`）落在已被 P03 使用的 AC-32 口径上**。
  - 另有 **S1 结构性缺陷**：`verify_db.dart:548` 起多处 `await` 未包 `try`，实现改坏时**崩溃而非置红**，且掩盖后 36 条断言。

- **一句话总结**：`verify_db.dart` 的"全绿"**不能**作为"DB 层实现正确"的充分凭据——它证明的是**聚合主口径（`aggregate`）与三类脏值守卫**；它对**行读路径的软删/草稿过滤、`aggregateByCompany` 的剩余派生、状态兜底方向**这三类实现点是**盲的**，改坏后仍报 93/0。

---

## 8. 自我限定（哪些断言/场景我没能注入，为什么）

**A. 【读码】级判定、未做注入的断言**（共 32 条，见 §5 标"真【读码】"者）：
原因：这些断言所指向的实现点集中在**已注入点的同一函数内**（如 §1 CRUD 全部走 `_write`/`_fromRow`，已由 M17/M31/M10/M11 覆盖同一代码路径），或**注入会同时破坏编译/结构**而无"语义等价的最小破坏"。**我不把这些升级为【实测】。**

**B. 无法注入的行为**：
1. §3 事务回滚 4 条、§4 2 条——验的是 **sqflite** 事务/隔离语义，非本项目代码；破坏 `AppDatabase.transaction`（`database.dart:263-266`，仅一行委托）必然引入死锁或编译错误，无法构造"语义等价的最小破坏"。
2. §10 `TimeoutException` 反证 2 条——验的是"**sqflite 同连接重入会死锁**"这一**上游缺陷的存在性**（C-01 的根因证据）。要使其置红需"修复 sqflite 重入"，超出本审计范围与能力。

**C. 我做过但因注入破坏 SQL 拼接而作废、已重做的样本**：M3 首次注入（直接删 `WHERE deleted_at IS NULL`）导致 `_sumInt` 拼接出 `... FROM payment_record AND company_id = ?` → SQL 语法错误 → 脚本在 `verify_db.dart:318` 崩溃。**已改用 `WHERE 1=1` 重做**（结果 5 红，计入台账）。作废样本**不计入**统计。

**D. 未穷尽之处**：本次注入 28 次，覆盖 `lib/db/database.dart` 中与**金额口径**及**已验证 AC** 相关的实现点；**未**系统覆盖的还有：导出/导入服务、UI 层、`_asId`/`_asDouble` 等非口径解析器、`open/close/configureForTest` 生命周期。这些**不在** `verify_db.dart` 的自述覆盖声明内，故不计入缺口表，但也意味着本报告**不能**外推为"DB 层全体实现已验证"。

**E. 证据纪律**：本报告所有"✗ 缺口""真【实测】"标注**均有一轮真实注入 + 真实重跑输出支撑**（明细见 §3.1 与 `$WORK/last.txt`）。凡未注入者一律标【读码】，**未把【读码级】判断说成【实测级】**。

---

## 9. 归档要求（产物清单）

| 文件 | 内容 |
|---|---|
| `$WORK/审计报告.md` | 本报告 |
| `$WORK/baseline.txt` | 基线完整输出（93/0） |
| `$WORK/last.txt` | **最后一次**注入重跑输出（M33 后已复位；供格式参考） |
| `$WORK/run.sh` | 跑副本 + 打印 `exit`/结果/全部 `✗` 行 |
| `$WORK/restore.sh` | 从 `pristine/lib` 复位副本（无删除命令） |
| `$WORK/pristine/lib` | 副本的原始快照（用于复位） |
| `$WORK/appcopy/**` | 副本（当前已复位到 pristine） |

复现任一注入：`bash $WORK/restore.sh` → 按 §3.1 对应行的 before→after 用 Edit 改 `$WORK/appcopy/lib/db/database.dart` → `bash $WORK/run.sh`。

**硬约束遵守声明**：全程未修改、未新建、未删除 `worklog-app/**` 下任何文件（`git status --short -- worklog-app` 为空，mtime 未变）；产物全部位于 `$WORK/` 下；**未执行任何 `rm` / `rm -rf` / `del` / 送回收站**（复位一律用 `cp`）。
