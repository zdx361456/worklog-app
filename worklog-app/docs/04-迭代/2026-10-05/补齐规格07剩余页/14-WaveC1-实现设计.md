---
title: Wave C1（统计与设置）实现设计
date: 2026-10-05
role: 实现设计
阶段: 阶段②
status: 草稿（Wave C1 · 待独立审查）
需求依据: 02-需求与验收.md（status: 已冻结）§D.0 / §D.9 / §D.10；07-UI实现规格.md §1 / §2 / §3.11 / §3.12 / §6
纪律: docs/00-项目总览/DECISIONS.md D-8（不采信口头汇报 / 报告可被文件证伪 / 未签发裁定不得落地 / 先读后改 / 证据层级三分）
---

# 14 · Wave C1（统计与设置）实现设计

> **本文性质**：阶段② **实现设计**（可施工级）。**唯一需求依据** = 同目录 `02-需求与验收.md`（`status: 已冻结`）+ `docs/07-UI实现规格.md`。本文**不改任何代码**；实现属阶段③。
> **金额/倍率口径（继承冻结件，全文不松动）**：整数「分」；倍率整数「×10」；**禁浮点**；显示一律 `fenToYuan`（`app/lib/ui/widgets/money.dart:9`）；解析一律 `yuanToFen`（`:30`）。
> **剩余工资唯一口径**：只取 `aggregate()` / `aggregateByCompany()` 的 `.remaining`；UI **不得**手写 `应收 − 已收`（DECISIONS D-4 / `07 §1.8` 规则 2）。

---

## §0 范围映射（Wave C1 三项 → 落点文件）

| # | 需求项（`02 §A.3` Wave C1 行 `:102`） | 需求节 | 动作 | 落点文件 |
|---|--------------------------------------|-------|------|---------|
| ① | **P11 统计页**（原位填充 A2 占位） | §D.9（AC-P11-01~08） | **原位改** | `app/lib/ui/stats_page.dart` |
| ② | **P12 设置页**（原位填充 A2 占位） | §D.10（AC-P12-01~05） | **原位改** | `app/lib/ui/settings_page.dart` |
| ③ | **P12a 节假日标记子页** | §D.10（AC-P12-06~10） | **新建** | `app/lib/ui/holiday_mark_page.dart` |
| ④ | **P12b 关于页** | §D.10（AC-P12-04） | **新建** | `app/lib/ui/about_page.dart` |
| — | Wave C1 自验证脚本 | `02 §A.4` / D-9 缓解措施① | **新建** | `app/tool/verify_waveC1.dart` |

**Wave C1 明确不动**（文件白名单，越界即打回）：`app/lib/main.dart`（含 `MainShell` / `onGenerateRoute`，Wave A2 已定稿）、`app/lib/app/routes.dart`、`app/lib/db/database.dart`、`app/lib/db/database_schema.dart`、`app/lib/ui/calendar_page.dart` / `day_detail_page.dart` / `record_detail_page.dart`（Wave B）、`app/lib/ui/export_backup_page.dart`（Wave C2 原位填充）、`app/lib/ui/company_page.dart`、`pubspec.yaml`。

**P12a / P12b 形态裁定（本文论证，属 §E-8「形态归 Dev」授权范围）**：采**独立整页**（非弹层）。
- 依据 1：`07:907` 明确 P12a/P12b 是「子页」，**不计入 13 页**；`02 §E-8`（`:894`）「可用弹层或子页，具体形态归 Dev」。
- 依据 2：`07 §1.7`（`:143`）「**弹层**用于高频轻量录入；**整页**用于结构化录入」——P12a 含「列表（按月，可编辑/删除）+ 日期 + 类型单选 + 倍率」多字段结构，属结构化录入 → 整页；P12b 为长文案滚动页 → 整页。
- 后果：P12 出口用 `Navigator.push(MaterialPageRoute(...))`（命令式），**不新增命名路由**（`routes.dart` 冻结，`07:4`「Wave 2 不得增删」）。

---

## §1 现状核对（**已开文件逐行核对**）

### 1.1 两个占位骨架（原位填充基线）

| 文件 | 行数 | 关键行 | 核对结论 |
|------|------|--------|---------|
| `app/lib/ui/stats_page.dart` | 75 | 构造 `const StatsPage({super.key})` `:19-20`；`_load()` 空实现 `:38-40`；`_buildPlaceholder()` `:53-74`；`Scaffold`+`AppBar('统计')` 外壳 `:44-47` | 与原任务书所述一致（75 行） |
| `app/lib/ui/settings_page.dart` | 78 | 构造 `const SettingsPage({super.key})` `:22-23`；`_load()` 空实现 `:41-43`；`_buildPlaceholder()` `:56-77`；`Scaffold`+`AppBar('设置')` 外壳 `:47-50` | 与原任务书所述一致（78 行） |

**原位填充约束**：保留 `StatefulWidget` + `State` + 构造签名（`MainShell._pages` 以 `const StatsPage()` / `const SettingsPage()` 依赖，`main.dart:206-211`）+ `Scaffold`/`AppBar` 外壳；只替换 `_load()` 实现与 `_buildPlaceholder()` 及其下游 → 按 §D.10 需改名为 `_buildBody()`（**内部私有方法改名不破坏任何契约**，仅改本文件）。

### 1.2 数据接线（**真实方法名 + 行号，已开 `database.dart` 核对**）

| 接线编号（`07 §2`） | 方法 | 用途 | 关键默认值（必须显式处理） |
|---|---|---|---|
| **A1** | `aggregate(String? companyId)` `database.dart:273-274`（实现 `:297-326`） | 全局/单公司剩余（权威） | `companyId == null` → 全局；返回 `ReceivableAggregate(receivable, received, remaining)`（`:71-90`） |
| **A2** | `aggregateByCompany()` `:333-334`（实现 `:337-...`） | 各公司应收/已收**一次查完** | **仅返回有数据的公司**（`:329-332`）；未出现公司须按全 0 补齐 |
| **A3** | `listCompanies({ledgerId, includeDeleted=false, includeDisabled=false})` `:451-461` | 公司元数据 | **必须显式双 `true`**（D-5 / `07 §4.1` 约束 1） |
| **A5** | `listWorkRecords({companyId, startDate, endDate, includeDeleted=false, includeDraft=true})` `:619-633`（实现 `:636-653`；行构造 `_workRecordRows` `:1250-1274`） | 统计取数 | 日期过滤按 **归属日 `attribution_date` 闭区间**（`:1258`）；`includeDraft:false` ≡ `status IN ('confirmed','settled')`（`:1263`，与聚合 `:304` **逐字相同**） |
| **A7** | `listHolidayMarks({ledgerId, startDate, endDate})` `:1066-1076` | P12a 标记列表 | 按月取用；按 `date ASC` 排序（`:1097`） |
| **A8** | `getLedger(id)` `:394` / `upsertLedger(x)` `:387` / `listLedgers()` `:404` | 账本（名/币种） | 基础版恒 1 账本 |
| **A13** | `getHolidayMarkByDate(ledgerId, date)` `:1046-1047` / `upsertHolidayMark(x)` `:1018` / `updateHolidayMark(x)` `:1103-1104` / `deleteHolidayMark(id)` `:1114-1115` | P12a 增/改/删 | ⚠️ **G-13**：`upsertHolidayMark` = `INSERT OR REPLACE`（`:1005-1016` 已实测证伪「会抛异常」的旧注释）→ 同 `(ledger_id,date)` **换 id**，**编辑禁用 upsert**；⚠️ **硬删**（`:1110-1112`）须二次确认 |
| — | `AppState.ledgerId` `app_state.dart:11` | 当前账本 id | 首启由 `main.dart` bootstrap 赋值 |
| — | `dataBus` `app/data_bus.dart:15` / `dataChanged()` `:11` | 刷新总线 | 统计页监听；P12a 写后广播 |
| — | `EnumCodec.pricingMethod` `enum_codec.dart:14-18` / `.holidayType` `:84-88` | 枚举文案 | **禁页面硬编码中文**（`07 §1.5`） |
| — | `Validators.validRate` `validators.dart:32` / `Validators.holidayMark` `:86-90` | 倍率校验 | `rate ≥ 10`（×10） |

**接线禁令核对（`02 §D.0.2`）**：① UI 不写 SQL；② 派生不落库；③ 口径唯一（走 A1/A2）；④ 软删默认过滤；⑤ 公司列表入口用 `Routes.companies`（活路由，D-5 / M-2）；⑥ 禁浮点；⑦ 枚举走 `EnumCodec`；⑧ 写后 `dataBus.dataChanged()`；⑨ 破坏性操作二次确认。**本设计逐条满足**。

---

## §2 P11 · 统计页（`stats_page.dart` 原位填充）

### 2.1 目标与结构

`Scaffold(appBar: AppBar('统计'))` + `body`：
```
[降级黄条（仅脏数据时）]
[维度分段控件 SegmentedButton（4 项固定）]
[时间段选择行（仅"按时间段"维度可见）]
[汇总列表 ListView.builder（每行：维度值 + 金额 + 占比条；按公司行可点）]
[合计行（固定底部）]
```
`_load()` 从空实现改为并发读三路（§2.3）。

### 2.2 四维度定义（**本文唯一权威定义**，逐条锚定 AC）

> 数据来源统一：`records = listWorkRecords(includeDraft: false)`（**全时段、全部公司、非草稿、非软删**）。该集合的 `Σ amountSnapshot` **逐条等价** `aggregate(null).receivable`（`02 §C.1.4:210` 已裁定的等价关系）。

| 维度 | 分组键 | 金额 | 行点击 | 锚定 AC |
|------|--------|------|--------|---------|
| **按公司** | `companyId` | **权威取 A2**：`aggregateByCompany().receivable`（各公司应收） | → **P07** 公司详情 | AC-P11-01/03/06 |
| **按月** | `workDate` 的 `yyyy-MM`（全时段） | `Σ records.amountSnapshot` | （可选，本期不实现展开） | AC-P11-01/03 |
| **按时间段** | 选定 `[startDate, endDate]` 内按 **`yyyy-MM-dd` 日**分组 | `Σ 该日 records.amountSnapshot` | （可选，本期不实现） | AC-P11-01/02/08 |
| **按计价方式** | `methodSnapshot`（时价/日价/计件） | `Σ records.amountSnapshot` | — | AC-P11-01/04 |

- **「按公司」为何取 A2 而非 records 分组**：AC-P11-03 明文「'按公司'维度各公司金额 **== `aggregateByCompany()` 的应收**」→ 以 A2 为权威源，天然满足等式；同时保留「records 分组结果 == A2」的开发期 `assert`（AC-37 自检，`:123` 规则 3 同款手法）。
- **「按时间段」粒度 = 日**：依据 ① `02 §D.0.3` MIN-6（`:340`）把 **P11 列入「≥200 行」列表页必测** → 行数可长 → 日粒度吻合；②「按月」已覆盖月粒度，日粒度提供独立价值；③ 跨年（AC-P11-08）在纯 `DateTime(y,m,d)` 比较下天然成立。**该粒度定义为本文裁定，属 §9 缺口登记 G-C1-A**。
- **合计行**恒 = `Σ 当前维度各行金额`；并满足 `Σ 明细 == aggregate(null).receivable`（全时段维度）。「按时间段」合计 = 区间内 `Σ`。

### 2.3 数据读取与降级（D-6 / `02 §D.0.3:341`）

```
_load():
  res = await Future.wait([
    _guard(_db.listCompanies(includeDisabled:true, includeDeleted:true)), // q1 元数据
    _guard(_db.listWorkRecords(includeDraft:false)),                       // q2 统计源
    _guard(_db.aggregateByCompany()),                                      // q3 按公司权威
  ]);
  // _guard<T>: on FormatException → null（单查询隔离降级）
```
- 任一查询遇 `FormatException`（聚合坏值 / 脏行）→ `_degraded = true` → **顶部黄条**（逐字「账目数字可能不完整，请勿据此对账」+「导出备份」引导 +「重试」）+ **正常内容照常渲染**，金额不可得的维度行金额位显示 `—`。**不白屏**。
- 非 `FormatException` 异常 → 整页 `_ErrorView`（文案「数据加载失败」+「重试」），与 `overview_page.dart:792-822` 同款。
- 「导出备份」引导：**本期直接 `Navigator.push(ExportBackupPage())`**（P13 骨架已落盘，见 §5）。

### 2.4 空态 / 异常态（`02 §D.0.3` / `07 §3.11:588`）

| 场景 | 呈现 |
|------|------|
| 无数据（该维度无行） | 居中图标 + **「这段时间还没记工」**（**禁用**「暂无数据」，AC-P11-07）+ 主按钮「记一笔工作」→ `Routes.workForm` |
| 加载中 | 居中 `CircularProgressIndicator`（`07 §1.6`） |
| 加载失败 | `_ErrorView` + 重试（不白屏，E-17） |
| 脏数据/聚合坏值 | 降级黄条 + 内容照常（E-11 / D-6） |
| **结束 < 开始** | 时间段字段**红字**「结束日期不能早于开始日期」+ **不查询**（保留上次结果或空态），AC-P11-02 |
| 时间段跨年 | 正常（AC-P11-08） |
| 列表 ≥200 行 | `ListView.builder` 惰性构建（MIN-6） |

### 2.5 入口 / 出口

- **入口**：底部 4 Tab 第 3 项（`main.dart:209` `_pages[2]`）。
- **出口**：按公司行 → `Navigator.push(MaterialPageRoute(builder: (_) => CompanyDetailPage(companyId: ...)))`（`company_detail_page.dart:44-45` 构造 `{required String companyId}`）；空态主按钮 → `Navigator.pushNamed(Routes.workForm)`。

---

## §3 P12 · 设置页（`settings_page.dart` 原位填充）

### 3.1 控件清单（映射 `07 §3.12:598-607`）

| # | 控件 | 类型 | 接线 / 出口 |
|---|------|------|------------|
| 1 | 节假日标记 | `ListTile` | → **P12a** `HolidayMarkPage`（push） |
| 2 | 公司列表 | `ListTile` | → **P06** `Navigator.pushNamed(context, Routes.companies)`（**M-2：不得改命令式 push**） |
| 3 | 导出备份（**带角标**） | `ListTile` + trailing | → **P13** `Navigator.push(MaterialPageRoute(builder: (_) => const ExportBackupPage()))`；trailing 文案见 §3.3 |
| 4 | 关于 / 数据说明 | `ListTile` | → **P12b** `AboutPage`（push） |
| 5 | 账本名称 | 可编辑文本（弹窗 `TextField` + 保存） | `upsertLedger`（A8，`:387`） |
| 6 | 币种（只读） | 文本 | `Ledger.currency` = `CNY`（Q7 预留，基础版不可改） |

### 3.2 数据读取

`_load()`：`getLedger(AppState.ledgerId)`（`:394`）→ 账本名/币种；`ledgerId == null` 时兜底 `AppState.defaultLedgerName` / `'CNY'`。监听 `dataBus` 以在写后刷新。

### 3.3 导出入口角标（AC-P12-03 / E-18）

- `07 §3.12:604`：右侧显示「上次备份：X 天前」；**无记录 → 「从未备份」红色**。
- **G-07（上次备份时间本地偏好存储）未落地**，且 **U-1 未批准 `shared_preferences`**（`DECISIONS D-7`）→ 本轮**无持久化"上次备份时间"的存储介质**。
- **处置（AC-P12-03 的"无记录"分支）**：角标恒显示 **红色「从未备份」**（诚实呈现：本版本尚未落地备份时间记录，等同"无记录"）。**不伪造**「X 天前」。**该处置登记为缺口 G-C1-B（§9）**，与 `02 §D.10:713` 「本轮若未落地，则该行降级显示"从未备份"」**逐字一致**。

### 3.4 导航出口汇总

`→ P06`（`Routes.companies`）、`→ P13`（`ExportBackupPage`）、`→ P12a`、`→ P12b`。**入口**：底部 4 Tab 第 4 项（`main.dart:210` `_pages[3]`）。

---

## §4 P12a · 节假日标记页（`holiday_mark_page.dart` 新建）

### 4.1 结构

`Scaffold(appBar: AppBar('节假日标记'))`：
```
[效果说明条（只读，常显）"标记只影响以后新建的记录；已记的历史金额不变"  ← AC-P12-09 逐字]
[按月标记列表 ListView.builder（每行：日期 / 类型 / 倍率 3.0 形式 + 删除按钮）]
[FAB 或底部按钮「标记节假日」→ 打开编辑弹层]
[空态：图标 + "标了节假日，当天记工自动按节假日倍率算"（E-05 逐字）]
```
编辑采用 **`showModalBottomSheet` 轻量弹层**（`07 §1.7`：高频轻量录入用弹层）——注：§1.7 说弹层用于「高频轻量录入」，P12a 的**单个标记编辑**是轻量录入 → 弹层；而 P12a **页本身**是结构化承载（列表+说明）保留整页。两处不矛盾。

### 4.2 数据接线（A7 + A13）

- 列表：`listHolidayMarks(ledgerId: AppState.ledgerId)`（`:1066-1076`）。
- 新建：
  1. **先判重** `getHolidayMarkByDate(ledgerId, date)`（`:1046-1047`）；
  2. **命中** → 转为编辑（复用旧 `id`，走 `updateHolidayMark`）——满足 AC-P12-06「新建走 upsert 且先判重」+ G-13「id 不漂移」；
  3. **未命中** → `id = newId('hm')` → `upsertHolidayMark(x)`（`:1018`）。
- 编辑：**必须** `updateHolidayMark(x)`（`:1103-1104`，按 id 原地 UPDATE，**禁 upsert**，G-13）。
- 删除：`deleteHolidayMark(id)`（`:1114-1115`，**硬删**）→ **二次确认**弹窗，确认按钮文案逐字 **「删除后该日新建记录将不再套用节假日倍率」**（AC-P12-07）。
- 每次写后 `dataBus.dataChanged()`。

### 4.3 倍率（AC-P12-08）

- 默认值：`listPricingRules(includeDisabled: false)`（`:536-546`）取**首个启用规则的 `holidayRate`**；无启用规则则兜底 `10`（= 1.0，`Validators.minRate`，`:20`）。**该"默认来源规则"的选取口径登记为缺口 G-C1-C（§9）**（标记为账本级、规则为公司级，无天然唯一映射）。
- 显示：`${rate ~/ 10}.${rate % 10}`（`07 §1.2:93`，**禁** `rate / 10`）。
- 输入：接受「元」式 1 位小数（如 `3.0`），**整数 ×10 解析**（`split('.')` 补位，**禁** `double.parse`）；校验 `Validators.validRate`（≥1.0）；非法 → 字段红字阻止保存。
- 类型：`SegmentedButton`/`Radio` 三项，文案走 `EnumCodec.holidayType`（`enum_codec.dart:84-88`）。

### 4.4 空态 / 异常态

| 场景 | 呈现 |
|------|------|
| 无标记 | 图标 + **「标了节假日，当天记工自动按节假日倍率算」**（E-05，AC-P12-10） |
| 加载中 / 失败 | 进度圈 / `_ErrorView` + 重试 |
| 保存失败 | SnackBar 可读原因 + **保留输入**（不清空表单，`02 §D.0.3:338`） |
| 删除（破坏性） | 二次确认 + 后果文案（§4.2） |

### 4.5 入口 / 出口

**入口**：P12 第 1 项。**出口**：← P12（系统返回）。

---

## §5 P12b · 关于页（`about_page.dart` 新建）

静态滚动页。**三条文案缺一不可**（AC-P12-04，`07:609-613`，**逐字**）：

1. **数据只存本机**：「账目只保存在这台手机上，不上传、不需要登录」（AC-44）。
2. **必须自己备份**：「手机丢失/换机/误删后无法找回，请定期到「导出备份」导出文件」（A8 前提、PRD §1.4-3）。
3. **基础版不含借支**：「基础版剩余 = 应收 − 已收，不包含借支；如公司有预支，请临时记为一笔收款并在备注写"借支"，二期会正式支持」（`03 §5.2` 对策 1）。

**入口**：P12 第 4 项。**出口**：← P12。

---

## §6 AC 逐条映射表（AC 编号 → 落点 → 可验证方式）

### §6.1 P11（`02 §D.9:691-698`）

| AC | 场景 | 落点（文件:符号） | 可验证方式 |
|----|------|------------------|-----------|
| AC-P11-01 | 四维度切换 | `stats_page.dart` 维度 `SegmentedButton`；`_Dimension` 枚举 4 值 | `[真机]` |
| AC-P11-02 | 时间段默认本月 + 结束<开始红字不查询 | `_TimeRangeBar`；`_rangeInvalid` 分支 | `[真机]` + `[静态]` |
| AC-P11-03 | 合计 == 明细之和；按公司 == `aggregateByCompany().receivable` | `_totalsMatch` 断言 + 按公司行取 A2 | **`[单测]`**（`tool/verify_waveC1.dart`）+ `[真机]` |
| AC-P11-04 | 按计价方式以 `methodSnapshot` 分组 | `_groupByMethod()` + `EnumCodec.pricingMethod` | `[单测]` + `[真机]` |
| AC-P11-05 | 排除草稿与软删；与 `aggregate` 可交叉验证 | `listWorkRecords(includeDraft:false)`（`:1263`） | `[静态]` |
| AC-P11-06 | 按公司行点击 → P07 | `_openCompanyDetail()` | `[真机]` |
| AC-P11-07 | 空态「这段时间还没记工」 | `_EmptyView` | `[真机]` |
| AC-P11-08 | 时间段跨年 | 纯 `DateTime(y,m,d)` 比较 | `[真机]` |

### §6.2 P12 / P12a / P12b（`02 §D.10:719-728`）

| AC | 场景 | 落点 | 可验证方式 |
|----|------|------|-----------|
| AC-P12-01 | 入口项齐全（6 项） | `settings_page.dart` 6 个 `ListTile` | `[真机]` |
| AC-P12-02 | 公司列表 → P06（含停用/归档） | `_openCompanies()` → `pushNamed(Routes.companies)` | `[真机]` |
| AC-P12-03 | 导出角标「从未备份」红 | `_exportSubtitle` | `[真机]`（G-C1-B） |
| AC-P12-04 | 关于页三条文案 | `about_page.dart` 三段文本 | `[静态]` + `[真机]` |
| AC-P12-05 | 账本名可改；币种 CNY 只读 | `_editLedgerName()` → `upsertLedger` | `[真机]` |
| AC-P12-06 | P12a 增/改/删；新建先判重、编辑走 update（id 不漂移） | `holiday_mark_page.dart` §4.2 三分支 | `[静态]` + `[真机]` |
| AC-P12-07 | 硬删二次确认（逐字后果） | `_confirmDelete()` | `[真机]` |
| AC-P12-08 | 倍率默认取规则；显示 3.0 | `_defaultRate()` / `_rateText` | `[真机]` |
| AC-P12-09 | 效果说明（逐字） | 常显说明条 | `[真机]` + `[静态]` |
| AC-P12-10 | 空态（E-05 逐字） | `_EmptyView` | `[真机]` |

**AC 映射（`07 §8`）**：P11 → `AC-37`、`AC-38`；P12 → `AC-44`、`AC-51`。

---

## §7 风险清单

| # | 风险 | 影响 | 缓解 |
|---|------|------|------|
| R1 | **G-13 节假日 id 漂移** | 编辑误用 upsert → id 换、引用断 | 编辑**只走 `updateHolidayMark`**；新建先 `getHolidayMarkByDate` 判重转编辑（§4.2）；审查项 AC-P12-06 |
| R2 | **浮点误用**（倍率/金额） | 违反 D-1 | 倍率显示 `rate ~/ 10 . rate % 10`；解析走整数 `split('.')`；金额显示 `fenToYuan`；**静态断言层 S1**（`tool/verify_waveC1.dart` §6，读真实源码 + 正则，剥离注释后零命中；豁免 stats_page 布局比例行 = R47） |
| R3 | **`aggregateByCompany()` 返回集不含 0 值公司** | 按公司维度漏行 | 行集合以 A2 为准（A2 已只含有数据公司）；未出现公司不显示（其应收=0）；`assert` 校验 |
| R4 | **脏数据致整页白屏** | 违 D-6 | `_guard` 单查询隔离 + 降级黄条 + `_ErrorView` |
| R5 | **`includeDraft` 未显式关** | 草稿计入 → 违 AC-32 | 显式 `includeDraft:false`（`:1263`） |
| R6 | **G-07 备份时间无存储** | AC-P12-03 只能走"无记录"分支 | 恒显红「从未备份」（§3.3），登记 G-C1-B |
| R7 | **P12a 倍率默认来源无唯一映射** | 与"取规则倍率"措辞有偏差 | 取首个启用规则 `holidayRate`，无则 10；登记 G-C1-C |
| R8 | **~200+ 行列表 OOM** | 违 MIN-6 | 全部列表用 `ListView.builder` |
| R9 | **`Routes.companies` 被改命令式** | 违 M-2 | 公司列表入口**固定 `pushNamed`**（`07:603` 明确） |

---

## §8 施工顺序

1. `stats_page.dart` 原位填充（P11）→ 全量类型编译。
2. `about_page.dart` 新建（P12b，无依赖，先落）。
3. `holiday_mark_page.dart` 新建（P12a）。
4. `settings_page.dart` 原位填充（P12，依赖 ExportBackupPage 骨架 / P12a / P12b 已存在）。
5. `tool/verify_waveC1.dart` 新建 + 跑通。
6. 全量类型编译 + `verify_db` / `verify_waveA` / `verify_waveA2` 回归。

---

## §9 需求缺口 / 设计外偏差（**报主理人裁定，不自行扩大改动范围**）

| 编号 | 类型 | 说明 | 本文临时处置 | 建议归属 |
|------|------|------|------------|---------|
| **G-C1-A** | 需求缺口 | `02 §D.9` / `07 §3.11` 未定义「按时间段」维度的**行粒度**（单合计？按日？按月？）。AC-P11-02/08 仅约束日期选择与跨年 | 定为**按日分组**（依据 MIN-6「≥200 行」+ 与「按月」区分，§2.2） | 主理人裁定 |
| **G-C1-B** | 设计外偏差 | 「上次备份时间」本地偏好存储（`07 §7 G-07`）未落地，U-1 未批 `shared_preferences` → 无法持久化 | 恒显红「从未备份」（与 `02 §D.10:713` 逐字一致） | 主理人确认 |
| **G-C1-C** | 需求缺口 | AC-P12-08「默认取规则的节假日倍率」未指明**哪条规则**（标记为账本级、规则为公司级） | 取首个启用规则 `holidayRate`，无则 `10` | 主理人裁定 |
| **G-C1-D** | 设计外偏差（**已由主理人裁定，登记为回流项**） | `02 §D.10` AC-P12-03 原写「导出入口先占位」；主理人已裁定 P12 导出入口**直接接线 `ExportBackupPage`**（P13 骨架已落盘，签名 `const ExportBackupPage({super.key})` 不变） | 直接接线（§3.1 #3） | **已裁定**；回流项 **R40**（见 §10，编号经主理人核准） |

---

## §10 回流项（Wave C1 段位 **R40~R49**，经主理人核准；R-33/R-34/R-35 全部作废）

> 编号订正说明：原拟 R-33 与 `18-主理人裁定（WaveA2 收口）.md` §7 已用编号冲突；主理人将 Wave C1 回流段位重划为 **R40~R49**。下表 R40~R44 为原 5 条回流按序重编号，R45~R47 为收口轮新增。

| 编号 | 回流目标 | 内容 |
|------|---------|------|
| **R40** | `02-需求与验收.md §D.10` / `docs/07-UI实现规格.md §3.12` | 记录主理人裁定：P12「导出备份」入口**直接接线 `ExportBackupPage`**（非占位）；依据 = P13 骨架已落盘、签名冻结，直接接线更完整且满足 AC-P12-03 意图（对应 G-C1-D） |
| **R41** | `00-开放问题.md` | 登记 **G-C1-A** 需求缺口的主理人裁定结论：「按时间段」维度的**行粒度 = 按日** |
| **R42** | `00-开放问题.md` | 登记 **G-C1-C** 需求缺口的主理人裁定结论：AC-P12-08 默认倍率 = **全账本首个启用规则的 `holidayRate`，无则 `1.0`（×10 = 10）** |
| **R43** | `07 §7` / `00-开放问题.md` | 登记 **G-C1-B / G-07**：上次备份时间存储（`shared_preferences`，U-1 未批）在 C1 未落地 → AC-P12-03 走「无记录」分支，与 `02 §D.10:713` 一致 |
| **R44** | `02 §D.10:713` / `07:604` | 合规回填对照：「从未备份」文案须置于 `trailing`（角标）位（右侧），文案逐字一致 |
| **R45** | `07 §3.11` | 补规格缺口：「按时间段」维度的**行粒度 = 按日**（原 §3.11 未定义） |
| **R46** | `07:621` | 补规格缺口：AC-P12-08 未指定默认取**哪条**规则 → 补「全账本首个启用规则，无则 `1.0`」 |
| **R47** | `DECISIONS.md` D-1 / `02` 禁浮点条款 | 补条款例外声明：「禁浮点」须**显式声明呈现层比例豁免**（`stats_page.dart` 布局比例行，无量纲比值，不参与金额/倍率运算） |


---

## 变更记录

| 日期 | 版本 | 说明 |
|------|------|------|
| 2026-10-05 | v1 | 首次落盘：P11 四维定义 + P12/P12a/P12b 落点与接线、AC 逐条映射、风险清单、施工顺序、4 项缺口登记（G-C1-A~D）、回流项。**状态：草稿，待独立审查** |
| 2026-10-05 | v1.1 | 按主理人裁定回改：回流项编号 **R-33 → R36**（原编号与 `18-主理人裁定（WaveA2 收口）.md` §7 已用编号冲突）；G-C1-A（按日粒度）/ G-C1-C（默认倍率取首个启用规则 `holidayRate`）/ G-C1-B（走「从未备份」降级分支）**三条裁定结论已核准，设计不变** |
| 2026-10-05 | v1.2 | 收口轮（审查 review-c1 FAIL 后）回改：① 回流段位订正 **R36 → R40~R49**（R-33/R-34/R-35 全部作废）；§10 原 5 条回流按序重编号为 **R40~R44**，新增 **R45**（`07 §3.11` 按时间段行粒度补「按日」）/ **R46**（`07:621` 补默认取「全账本首个启用规则，无则 `1.0`」）/ **R47**（「禁浮点」须显式声明呈现层比例豁免）；② §7 R2 措辞修正：将原写作事实的「grep 断言」改为「**静态断言层 S1**（读真实源码 + 正则，剥离注释后零命中）」；③ §9 G-C1-D 引注 R36 → **R40** |
