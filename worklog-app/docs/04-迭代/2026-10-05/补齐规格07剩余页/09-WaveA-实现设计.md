---
title: Wave A（下钻闭环）实现设计
date: 2026-10-05
role: 实现设计
阶段: 阶段②
status: 已冻结（阶段② 闭环 · 2026-10-06）
审查: 10-WaveA设计审查.md（有条件通过）
裁定: 11-主理人裁定（WaveA设计）.md（M-1~M-15 已全部落实，v2）
---

# 09 · Wave A（下钻闭环）实现设计

> **本文性质**：阶段② **实现设计**（可施工级）。**唯一需求依据** = 同目录 `02-需求与验收.md`（`status: 已冻结`）。
> **本文不改任何代码**；实现属阶段③。凡与本设计冲突者，以 `02-需求与验收.md` 冻结件为准。
> **冻结说明（2026-10-06）**：v2 已通过**独立审查**（`10-WaveA设计审查.md`，有条件通过）与**主理人 15 项修订指令**（`11-主理人裁定（WaveA设计）.md`，M-1~M-15），并**由主理人独立复核 7 项自检（0/0/0/0/0/5/12 全部达标）**后冻结。**阶段③ 施工以本文 v2 为唯一设计依据**；施工中发现的**设计外偏差**须报主理人，**不得自行改设计**。
> **金额口径（继承冻结件，全文不松动）**：整数「分」；倍率整数「×10」；**禁浮点**；显示一律 `fenToYuan`（`app/lib/ui/widgets/money.dart:9`）；解析一律 `yuanToFen`（`:30`）。

---

## §0 范围映射（Wave A 六项 → 落点文件）

| # | 需求项（`02 §A.3`） | 需求节 | 动作 | 落点文件（新建/改） |
|---|--------------------|-------|------|-------------------|
| ① | **P01 改造**：公司卡片可点 + 三金额可点 + 「查看全部」/「全部公司」 + **删「最近 5 条」** | §D.1（AC-P01-01~14） | 改 | `app/lib/ui/overview_page.dart` |
| ② | **P-DEBT 公司欠款列表页**（谁还欠我钱） | §D.13（AC-PDBT-01~10）/ §C.1.2 | 新建 | `app/lib/ui/debt_list_page.dart` |
| ③ | **`records_page.dart` 参数化** + 补「全部记录」入口 | §C.2.2 / §C.1.3 / AC-P01-09 | 改 + 新建 | `app/lib/ui/records_page.dart` / `app/lib/ui/records_filter.dart` / `app/lib/ui/widgets/record_list_view.dart` |
| ④ | **P07 公司详情页**（含**计价规则列表区块**） | §D.6（AC-P07-01~12）/ §A.3 契约 | 新建 | `app/lib/ui/company_detail_page.dart` |
| ⑤ | **P10 收款登记页收口**（AC-24 超过确认 + 实时剩余提示） | §D.14（AC-P10-01~09） | 改 | `app/lib/ui/payment_form_page.dart` |
| ⑥ | **P06 公司列表页收口**（行点击 → P07；行内金额/状态角标） | §D.12（AC-P06-01~08） | 改 | `app/lib/ui/company_page.dart` |
| — | 共享件（状态角标 / 停用·归档角标） | §D.6 / §D.12 / §D.13 | 新建 | `app/lib/ui/widgets/receivable_status.dart` |
| — | **T-1 入口预置**：`WorkFormPage` / `PaymentFormPage` 各加**可选**构造参数 | §A.3 补口径 1 | 改 | `app/lib/ui/work_form_page.dart` / `app/lib/ui/payment_form_page.dart` |

**Wave A 明确不动**：`app/lib/main.dart`（含 `onGenerateRoute` / `MainShell`）、`app/lib/app/routes.dart`、`app/lib/db/database.dart`、`app/lib/db/database_schema.dart`、`app/lib/services/receivable_service.dart`、`app/lib/services/pricing_bootstrap.dart`、`app/lib/app/data_bus.dart`、`app/lib/ui/widgets/money.dart`、`pubspec.yaml`。

---

## §1 现状核对（**已开文件逐行核对**，纠正文档行号漂移）

> 本节是施工前提。`02` 引用的行号**多数成立**，但有 3 处必须纠正，否则照抄会改错地方。

| 断言（文档） | 代码事实 | 结论 |
|-------------|---------|------|
| `overview_page.dart:278-333` = `_RecentSection`（U-2 现场） | ✅ 成立：`_RecentSection` 类在 `:278-307`，`_RecentRow` 在 `:309-333`；`entries.take(5)` 在 **`:102`**（`_buildRecent` 内） | 成立 |
| `overview_page.dart:169-254` = 三金额控件 | ✅ 成立：`_RemainingCard` `:169-203`、`_ReceivableReceivedRow` `:205-230`、`_MiniStat` `:232-254` | 成立 |
| 「P01 公司卡片区」（Wave A 新增） | ⚠️ **现状根本不存在公司卡片区**；`_load()` 只取 `_companyCount`（`:56`/`:63`），`_buildBody()`（`:131-150`）无卡片。`07:208`/`07:217` 要求的卡片区**从未实现** | **需在新设计中新建该区块** |
| `company_page.dart:293` 行点击 → `_onEdit` | ✅ 成立（`:293` `onTap: () => _onEdit(c)`） | 成立 |
| `company_page.dart:66` 只传 `includeDisabled` | ✅ 成立（`:66`）；**确未传 `includeDeleted`** | 成立 |
| `payment_form_page.dart` 无 remaining/aggregate | ✅ 成立（全文件无 `aggregate`/`remaining`） | 成立 |
| `records_page.dart:33-34` 无参构造 | ✅ 成立（`:34` `const RecordsPage({super.key})`） | 成立 |
| `main.dart:55-56` 注册了 `Routes.records` → `const RecordsPage()` | ✅ 成立 | **关键约束**：`RecordsPage` 必须保持 `const` 可构造（见 §3.1） |
| `records_page.dart:68-70` 裸调三个零参方法 | ✅ 成立：`listCompanies()`（**裸调**，违 `07 §4.1` D2）、`listWorkRecords()`、`listPaymentRecords()` | 成立 |
| `work_form_page.dart:44-52` `WorkFormPage({this.id})` | ✅ 成立（`:46`）；**确无 `companyId`/`initialDate`** | 成立 |
| `payment_form_page.dart:30-32` `PaymentFormPage({this.id})` | ✅ 成立（`:30`）；**确无 `companyId`** | 成立 |

**要点**：`P01 公司卡片区` 是**从零新建**（不是"改造既有卡片"）；这决定了 §6 的落点必须新增一个 `_CompanyCardSection`，而非修改既有控件。

---

## §2 硬约束落实（逐条对照，施工时按此自检）

| # | 约束（team-lead 下发 / `02 §E-6`） | 本设计的落实方式 |
|---|-----------------------------------|-----------------|
| 1 | **不新增任何依赖** | 全程仅用 `flutter/material` + 现有 `lib/**`。**不碰 `pubspec.yaml`**。不用 `shared_preferences`（未获批准）→ 筛选状态只走**构造参数 + State 内存**（§4.3）。 |
| 2 | **数据层只读冻结** | 不新增/不改 `database.dart` 任何签名；所有查询用**既有**方法：`aggregate`（`:273`）、`aggregateByCompany`（`:333`）、`listCompanies`（`:451`）、`listWorkRecords`（`:619`）、`listPaymentRecords`（`:910`）、`listPricingRules`（`:536`）。不改 `receivable_service.dart`。 |
| 3 | **金额纪律** | 一切金额 `int`（分）；比较/相减全用 `int` 运算；显示 `fenToYuan`；输入解析 `yuanToFen`。**无任何 `double` 参与金额**。 |
| 4 | **剩余工资唯一口径** = 应收 − 已收，由 `receivable_service.dart` 给出 | UI 一律调 `AppDatabase.instance.aggregate(...)`（其 SQL 与 `receivable_service` 逐条对齐，见 `database.dart:279-296` 对照表）。UI **不自算剩余**；P-DEBT 的「欠款合计」是**独立命名口径**（§7.3），不与剩余混用。 |
| 5 | **下钻用命令式 `Navigator.push(MaterialPageRoute(...))`**，**不动 `routes.dart` / `onGenerateRoute` / `_extractId`** | 全部**新增页**跳转均为命令式 push（§8 表）。`routes.dart`、`main.dart:45-85` 一字不改。**唯一例外（M-2 裁定）**：目标为 **P06** 的跳转（P01「全部公司」入口、P01 空态主按钮、P07「编辑公司」临时出口）**一律沿用 `pushNamed(Routes.companies)`** —— `Routes.companies` 的**唯一调用点**是 `overview_page.dart:379`，若改命令式会让它变成**新增死路由**（`main.dart:57` 仍注册、零调用），故**必须保留为活路由**（详见 §13 Q-D1 / §8）。 |
| 6 | **陷阱 1**：应收下钻 → `listWorkRecords(includeDraft: false)` | `RecordsFilter.receivableDrill` 默认 `includeDraft: false`（§4.2）；`RecordListView` 透传（§4.4）。**默认态永不混入草稿**。 |
| 7 | **陷阱 2**：公司名映射 → `listCompanies(includeDisabled: true, includeDeleted: true)` | P01（§6）、P06（§9）、P-DEBT（§7）、RecordsPage（§4）**全部显式传双 true**；仅 P07 因固定单公司用同一调用。**`listCompanies()` 裸调在 Wave A 代码中归零**。 |
| 8 | **P-DEBT 欠款合计独立口径** + 恒等式断言 | §7.3 写死；单测断言 `欠款合计 − \|多收合计\| == aggregate(null).remaining`。 |
| 9 | **P07 预留计价规则区块**（Wave D1 只填充不返工） | §5.6：规则区块结构在 Wave A 一次成型（列表/行渲染/新建入口），**唯一注入点** `_openRuleEditor({String? ruleId})`，Wave A 体内是 SnackBar 占位，D1 只换函数体。 |
| 10 | **刷新策略**：页面级 `setState` + `_reload()`；跨页返回由调用方 `await push` 后**无条件 `_reload()`**；**不使用状态管理库** | §10 写死：每页 `initState` 注册 `dataBus` 监听；**每个 push 点** `await Navigator.push(...)` 之后 `if (mounted) _load();`。全程 `StatefulWidget` + `setState`，无 provider/riverpod/bloc。 |

---

## §3 文件级改动清单

### 3.1 新建文件（5 个）

| 文件 | 内容 | 谁依赖它 |
|------|------|---------|
| `app/lib/ui/records_filter.dart` | `enum RecordsScope { workOnly, paymentOnly, both }` + `class RecordsFilter`（不可变值对象，含 `copyWith` 与静态工厂） | RecordsPage / RecordListView / P07 / P04(Wave B) |
| `app/lib/ui/widgets/record_list_view.dart` | `RecordListView`（**单类型列表**，自持加载 + 空/错/加载态 + 行渲染 + 滑动删除）；行组件 `WorkRecordRow` / `PaymentRecordRow` / `RecordStatusChip`（由 `records_page.dart` 的私有件上提为公开件） | RecordsPage / P07 / P04(Wave B) |
| `app/lib/ui/widgets/receivable_status.dart` | `receivableStatusLabel(int receivable, int received)`（PRD §5.2 五态，整数严格等号）+ `ReceivableStatusChip` + `CompanyFlagChips`（停用/已归档灰角标） | P01 / P06 / P07 / P-DEBT |
| `app/lib/ui/company_detail_page.dart` | `CompanyDetailPage({required String companyId})`（**P07**） | P01 / P06 / P-DEBT / P04(Wave B) / P11(Wave C1) |
| `app/lib/ui/debt_list_page.dart` | `CompanyDebtListPage()`（**P-DEBT**，无参） | P01 |

> **`RecordsPage` 保持文件名与类名不变**（`app/lib/ui/records_page.dart`），以保证 `main.dart:55-56` 的 `const RecordsPage()` **零改动编译**（见 §1 关键约束）。
> **对齐 `§A.3` 的"P07 必须预留规则区块"**：`company_detail_page.dart` 在 Wave A 即包含规则区块的完整结构（§5.6）。

### 3.2 修改文件（5 个）

| 文件 | 改什么 | 不改什么 |
|------|-------|---------|
| `app/lib/ui/overview_page.dart` | ① 删 `_RecentSection`/`_RecentRow`/`_RecentEntry`/`_buildRecent`/`take(5)`/`_recent`；② **删 `_StatsLine` + 调用 + `_workCount` 字段与赋值**（Q-D7 定论移除）；③ 三金额加 onTap；④ **新增** `_CompanyCardSection`（公司卡片区，含「全部公司」入口）；⑤ 新增「查看全部」入口；⑥ `listCompanies()` 裸调 → `listCompanies(includeDisabled: true, includeDeleted: true)`；⑦ `_load()` 由**串行 4 读**改**并发 4 读**（N-D6）；⑧ **同步更新文件头注释与类文档**（删"统计行 / 最近 5 条"，补"公司卡片区 / 查看全部"，N-D1） | 不动 `_VersionNote`、空态/错误态骨架、`_ActionButtons`（保留两个 `FilledButton`） |
| `app/lib/ui/records_page.dart` | ① 构造签名参数化（**全部可选 + const 默认**，`title` 默认 **`'明细'`** 以与本波 `MainShell` 第 2 个 Tab 标签一致，见 m12）；② `_load()` 委托 `RecordListView`；③ 顶部合计 + 筛选 chips；④ 删除动作下放给 `RecordListView` | 不动类名 `RecordsPage`、文件路径 |
| `app/lib/ui/company_page.dart` | ① `_load()` 加 `includeDeleted: true` + `aggregateByCompany()`；② `_CompanyTile` 加金额 + 双角标；③ 行 `onTap` 由 `_onEdit` 改 **push P07**；④ 行尾加「⋯」菜单（编辑/停用/删除，保留长按） | **不动** `_CompanyEditDialog`（P08 收口属 Wave D1） |
| `app/lib/ui/payment_form_page.dart` | ① 加可选 `companyId`；② 公司预置 + 锁定；③ `aggregate(companyId)` 取剩余；④ 实时提示；⑤ `_save()` 前加 AC-24 严格 `>` 二次确认 | 不动 `upsertPaymentRecord`/`softDeletePaymentRecord` 调用与编辑态回填逻辑 |
| `app/lib/ui/work_form_page.dart` | **仅** 加两个可选构造参数 `companyId` / `initialDate`（新建态预置；编辑态忽略） | 不动 `ensureRule`（`:402`）、不动编辑态只改「备注 + 归属日」的口径 |

### 3.3 T-1 入口预置的**最小改动**（写死，避免返工）

```dart
// work_form_page.dart:44-52（改后）
class WorkFormPage extends StatefulWidget {
  const WorkFormPage({super.key, this.id, this.companyId, this.initialDate});
  final String? id;          // 编辑态 id（原字段，语义不变）
  final String? companyId;   // 新增：新建态预置公司（P07「+ 记一笔」）
  final DateTime? initialDate; // 新增：新建态预置归属日（P04「+ 记一笔」）
  ...
}
```
- **生效点**：`_load()`（`:120-153`）末尾，**仅当 `widget.id == null`** 时：`if (widget.companyId != null) _companyId = widget.companyId;`、`if (widget.initialDate != null) _workDate = DateTime(y,m,d);`。
- **编辑态忽略预置**（AC-P02-10）：`widget.id != null` 时预置代码整体跳过（由 DB 回填）。
- **预置公司已停用/已删**：~~`_load()` 后校验 `_companyId` 是否在 `_companies`（`listCompanies()` 默认只含启用）中；不在 → 回退"第一个启用公司"（`07:283`），不报错。~~
  > ### ⚠️ 勘误 E-3.3-1（主理人 · 2026-10-06 · 阶段③ 批 1 独立审查发现）
  > **上句的"回退第一个启用公司"作废。修正为：不回退 —— `_companyId = null`（保持未选）+ 首帧后一次性提示「该公司已停用或已删除，请重新选择公司」。**
  > **错在哪（两处）**：
  > ① **引错范围**：`07:283`「上次记录的公司已停用/已删 → 回退到"第一个启用公司"，不报错」位于 `07:281-285`，该整段是 **P02 秒级快记弹层**的「空态 / 异常态」（依据：`:281` 有"**弹层顶部**提示"、`:282` 有"规则下拉"、`:285` 有"**展开→完整补记表单**"）。**它不是 P10/全量表单页的要求**，本设计把它泛化到了 `PaymentFormPage` / `WorkFormPage`。
  > ② **与本波目标直接冲突**：用户是在**公司 X 的详情页**点「记一笔收款/工作」进来的（**明确意图**，非 P02 的"上次值记忆"）。静默换成公司 Y，用户不看下拉直接保存 → **钱记到错的公司上**。且原回退分支**未加锁**，风险更大。
  > ③ **已有正确依据可用**：`07:557` / `AC-P10-05` 规定「**无公司**：提示先建公司；**不允许保存**」→ "保持未选"会自然落到该既有校验上，安全。
- `PaymentFormPage` 同理加 `this.companyId`（**并同样适用勘误 E-3.3-1：不回退**）。
  - **★ 阶段⑤ 双回流 R11 合并标记**：勘误 E-3.3-1 的**修正内容已就地合并**（上引「修正为：不回退」段为**权威正文**）；原**删除线/作废块保留可溯**（依本项目「严禁删除既有内容」铁律，未删块）。`02 §F` 侧偏差登记见 `02 §F-26`。

> **向后兼容**：两处均为**具名可选参数**，`main.dart:47-54` 的 `WorkFormPage(id: ...)` / `PaymentFormPage(id: ...)` 与 `records_page` 的既有调用**零破坏**。

### 3.4 删除项的「符号名优先 + 残留自检」纪律（N-D5）

> 本迭代已多次踩"行号漂移"（`00:53`→`:61`；`07:341`→`:340`；`02-PRD.md:74`→`:459-477`）。**行号仅作锚点提示，施工与自检一律以符号名为准。**

- **`overview_page.dart` 删除后必须 `grep` 残留自检**，以下符号**全部 0 命中**：
  `_RecentSection`、`_RecentRow`、`_RecentEntry`、`_buildRecent`、`_recent`、`_StatsLine`、`_workCount`。
- 其余行号（如 `:154-167`/`:256-276`/`:278-333`）**仅供定位**；若与文件实际不符，以**符号名**为准。
- **文件头注释同步（N-D1）**：`overview_page.dart:1-4` 的 `:3` 描述为"统计行 → 最近 5 条"，改造后必然失实 → 必须同步改为描述"剩余大字 / 应收已收 / **公司卡片区** / **查看全部**"。**注释与实现不一致 = 阶段⑤ 一致性审查的必扣项**。

---

## §4 `records_page.dart` 参数化列表组件设计（③ 的核心）

### 4.1 分层（谁是什么）

```
RecordsFilter（值对象，唯一筛选真源，纯数据，无 IO）      lib/ui/records_filter.dart
        │
        ├─ RecordListView（"列表主源"：自持 _load() + 渲染 + 删除；无 Scaffold）   lib/ui/widgets/record_list_view.dart
        │        ▲                        ▲
        │        │                        └── P07 内嵌两个实例（工作 / 收款，showCompanyName=false）
        │        └── P04（Wave B）内嵌（day 过滤，groupBy 由 Wave B 追加可选参数）
        │
        └─ RecordsPage（"页面壳"：Scaffold + AppBar + 可选 TabBar + 顶部合计 + 筛选 chips；持有 _filter 实例状态）
                 ▲
                 └── P01 三处下钻 + 「查看全部」入口（命令式 push）
```

**主源/复用关系（写死）**：

| 场景 | 主源 | 复用 |
|------|------|------|
| 「全部记录」（P01「查看全部」） | `RecordsPage(filter: RecordsFilter.all, title: '全部记录')` | → 两个 `RecordListView` |
| 「应收下钻」 | `RecordsPage(filter: RecordsFilter.receivableDrill, title: '应收明细', showAggregateHeader: true)` | → 一个 `RecordListView`（workOnly） |
| 「已收下钻」 | `RecordsPage(filter: RecordsFilter.receivedDrill, title: '收款明细', showAggregateHeader: true)` | → 一个 `RecordListView`（paymentOnly） |
| P07 内的两个列表 | **P07**（自持 `aggregate`/规则/公司元数据） | 复用 `RecordListView`（`showCompanyName: false`, `showRuleName: true`）+ 行组件 + 空/错态 |
| P04 日详情（Wave B） | Wave B 页 | 复用 `RecordsPage(filter: RecordsFilter.day(d))` 或 `RecordListView`（Wave B 追加 `groupByCompany` **可选**参数，**不改 Wave A API**） |
| P-DEBT | **P-DEBT 页自身**（行实体是"公司"，不是记录） | 复用 `receivableStatusLabel` / `CompanyFlagChips`；**不复用** `RecordListView` |

> **规则**：`RecordListView` 是"列表主源"（谁显示列表谁用它）；`RecordsPage` 是"页面壳"（只在需要 AppBar/标题/合计/chips 时用）。P07 要自定义头部与 TabBar，故**直接用 `RecordListView`**，不经 `RecordsPage`（避免双层 Scaffold 与重复加载）。

### 4.2 `RecordsFilter` 接口（含默认值）

```dart
// lib/ui/records_filter.dart
enum RecordsScope { workOnly, paymentOnly, both }

/// 不可变筛选值对象（唯一筛选真源；不进全局状态，不做跨会话记忆）。
class RecordsFilter {
  const RecordsFilter({
    this.scope = RecordsScope.both,
    this.companyId,
    this.startDate,
    this.endDate,
    this.includeDraft = true,     // listWorkRecords 默认值；仅 work 相关
    this.includeDeleted = false,  // 默认排除软删（§D.0.2-4）
  });

  final RecordsScope scope;
  final String? companyId;   // null = 全部公司
  final DateTime? startDate; // 闭区间起（含），按归属日/收款日
  final DateTime? endDate;   // 闭区间止（含）
  final bool includeDraft;   // 工作记录是否含草稿
  final bool includeDeleted;

  /// 工厂（写死 5 个入口语义，避免各处手写参数漂移）
  static const RecordsFilter all =
      RecordsFilter(scope: RecordsScope.both, includeDraft: true);          // 「全部记录」
  static const RecordsFilter receivableDrill =
      RecordsFilter(scope: RecordsScope.workOnly, includeDraft: false);     // 点「应收合计」（陷阱1）
  static const RecordsFilter receivedDrill =
      RecordsFilter(scope: RecordsScope.paymentOnly);                       // 点「已收合计」
  static RecordsFilter companyWork(String cid) =>
      RecordsFilter(scope: RecordsScope.workOnly, companyId: cid);          // P07 工作 tab
  static RecordsFilter companyPayment(String cid) =>
      RecordsFilter(scope: RecordsScope.paymentOnly, companyId: cid);       // P07 收款 tab
  static RecordsFilter day(DateTime d) =>
      RecordsFilter(scope: RecordsScope.workOnly, startDate: d, endDate: d, includeDraft: true); // P04/B

  /// 用显式 clear 标志表达"清除可空字段"（避免 null 语义歧义）。
  RecordsFilter copyWith({
    RecordsScope? scope, String? companyId, DateTime? startDate, DateTime? endDate,
    bool? includeDraft, bool? includeDeleted,
    bool clearCompanyId = false, bool clearDateRange = false,
  }) => RecordsFilter(
        scope: scope ?? this.scope,
        companyId: clearCompanyId ? null : (companyId ?? this.companyId),
        startDate: clearDateRange ? null : (startDate ?? this.startDate),
        endDate: clearDateRange ? null : (endDate ?? this.endDate),
        includeDraft: includeDraft ?? this.includeDraft,
        includeDeleted: includeDeleted ?? this.includeDeleted,
      );

  bool get hasCompany => companyId != null;
  bool get hasDateRange => startDate != null || endDate != null;
}
```

> **`const` 要求（编译硬约束）**：`RecordsFilter.all` 必须是 `static const`，因为 `RecordsPage` 的默认参数值必须是 const（§4.3）。`RecordsFilter` 的构造函数必须 `const`。

### 4.3 `RecordsPage` 构造签名（**全可选 + const 默认** = 向后兼容）

```dart
// lib/ui/records_page.dart（类名/文件不变）
class RecordsPage extends StatefulWidget {
  const RecordsPage({
    super.key,
    this.filter = RecordsFilter.all,   // 默认 both + includeDraft:true ≡ 现状两列表默认口径
    this.title = '明细',                // m12：与本波 MainShell 第 2 个 Tab 标签「明细」(main.dart:207) 一致；A2 换 Tab 后该默认值随之消失
    this.showAggregateHeader = false,  // 下钻列表才为 true
  });

  final RecordsFilter filter;
  final String title;
  final bool showAggregateHeader;
  ...
}
```

**筛选状态的保存口径（对齐 `§C.1.3`）**：

```dart
class _RecordsPageState extends State<RecordsPage> {
  late RecordsFilter _filter = widget.filter;  // 参数化传入 → 实例内保留
  ...
  // 跨次进入不记忆：push 每次 new 一个 RecordsPage（命令式 push，新 Route 新 State），
  // _filter 从 widget.filter 重建 → 天然不跨次记忆（无全局单例、无本地偏好）。
}
```

- **参数化传入**：`widget.filter`。
- **实例内保留**：`_filter` 由 chips 交互 `setState(() => _filter = _filter.copyWith(...))` 修改；**同一页面实例内**保留。
- **跨次进入不记忆**：不写任何持久化（无 `shared_preferences`，`§C.1.3` 明确不引入"上次筛选"）；每次 push 都是新 State。
- **`didUpdateWidget`**：若父级在同一位置传入新 `filter`，需同步 `_filter = widget.filter` 并 `_load()`（P07 不需要；RecordsPage 作为 Tab 时不需要；为健壮性仍实现）。

**顶部合计（AC-P01-04 / AC-P01-05 / `§C.1.4` 陷阱 2）**：
- 仅 `showAggregateHeader == true` 时渲染；数值**必须**取聚合（**禁本地求和当真值**）：
  - `workOnly` → `aggregate(_filter.companyId).receivable`
  - `paymentOnly` → `aggregate(_filter.companyId).received`
  - `both` → 不显示合计（「全部记录」无对应单一合计）
- 本地求和仅作开发期 `assert`（`Σ 列表内非草稿 amountSnapshot == agg.receivable`）。

**筛选 chips（`§C.1.3` 可删除）**：
- `workOnly` 且 `includeDraft == false` → chip「仅计应收（不含草稿）」；点 × → `_filter = _filter.copyWith(includeDraft: true)`，chip 变为「含草稿（不计数）」。
  - **不移除合计、不改口径**：草稿行金额显示 `—`（`07:340`），不参与求和，故 `aggregate(null).receivable` 仍成立（见 §13 Q-D9）。
- `companyId == null` → chip「全部公司」（`workOnly`/`paymentOnly` 下为筛选身份；P01 下钻即全公司，点 × 不改变结果，仅作展示）。
- `hasDateRange` → chip「YYYY-MM-DD ~ YYYY-MM-DD」。
- chips 变更 → `setState` → `RecordListView` 走 `didUpdateWidget` → `_load()`。

### 4.4 `RecordListView` 接口（**列表主源**）

```dart
// lib/ui/widgets/record_list_view.dart
class RecordListView extends StatefulWidget {
  const RecordListView({
    super.key,
    required this.filter,                  // 必须 scope != both（单类型列表）
    this.companyNameById = const {},       // showCompanyName=true 时必传
    this.ruleNameById = const {},          // 工作记录行显示「工序」用（pricingRuleId → 规则名）
    this.showCompanyName = true,           // 全部记录/下钻=true；P07=false（公司固定）
    this.showRuleName = true,              // 工作记录是否显示工序
    this.emptyTitle = '还没有记录',
    this.emptyHint,
    this.emptyActionLabel,                 // null → 不显示主按钮
    this.onEmptyAction,                    // 空态主按钮回调（由壳层注入跳转）
    this.enableDismissDelete = true,       // P07 也需要删除（07:461）
  });
  ...
}
```

**内部 `_load()`（按 `scope` 二选一，单查询）**：

```dart
Future<void> _load() async {
  try {
    final f = widget.filter;
    final List<Object> data;
    if (f.scope == RecordsScope.workOnly) {
      data = await _db.listWorkRecords(
        companyId: f.companyId,
        startDate: f.startDate,
        endDate: f.endDate,
        includeDeleted: f.includeDeleted,
        includeDraft: f.includeDraft,   // ← 陷阱1 落点：receivableDrill = false
      );
    } else {
      data = await _db.listPaymentRecords(
        companyId: f.companyId,
        startDate: f.startDate,
        endDate: f.endDate,
        includeDeleted: f.includeDeleted,
      );
    }
    ...
  } catch (e) { /* _ErrorView + 重试（复用 records_page.dart:405-437 样式） */ }
}
```

- **排序**：DB 已 `ORDER BY attribution_date DESC, created_at DESC`（`database.dart:1272`）/ `pay_date DESC, created_at DESC`（`:1297`）→ **UI 不再重复排序**（现状 `records_page.dart:73-76` 的 Dart 排序删除，避免"双排序口径"）。
- **日期闭区间**：`_dateRange`（`database.dart:1163-1179`）用 `>=` / `<=` + `_dateOnly` → 当日过滤传 `startDate == endDate == d` 即**含当日全部**（P04 口径）。
- **行渲染**：
  - 工作行：`归属日` + `工序`（`ruleNameById[r.pricingRuleId] ?? '—'`）+ 金额 + 状态 chip；`status == draft` → 金额显 `—`、行置灰（`07:340`）。
  - 收款行：`收款日期` + 金额（`+`）+ `EnumCodec.paymentMethod(p.method)`（`records_page.dart:325`）+ 备注。
  - `showCompanyName` → 标题行显示 `companyNameById[cid] ?? '未知公司'`。
- **行点击**（由壳层/调用方注入 `onTapWork(id)` / `onTapPayment(id)`，默认实现 push 编辑页）：
  - 工作 → `WorkFormPage(id: r.id)`（**Wave B 前临时**，T-1，验收记录标"临时"）。
  - 收款 → `PaymentFormPage(id: p.id)`。
- **滑动删除**：沿用 `records_page.dart:100-163` 的"乐观移除 + 确认对话框 + 失败 `_load()` 回滚"写法（**保留既有正确性**，不重写逻辑）；成功 → `dataBus.dataChanged()`。
- **空态**：`emptyTitle`/`emptyHint`/`emptyAction*` 由壳层注入（同一组件服务不同入口，文案已由 `§C.1.3` 写死）。
- **大表**：`ListView.builder` 惰性构建（`§D.0.3`，≥200 行）。

### 4.5 `RecordsPage` 内部组装（`build` 骨架）

```dart
Scaffold(
  appBar: AppBar(
    title: Text(widget.title),
    bottom: _filter.scope == RecordsScope.both
        ? TabBar(controller: _tab, tabs: const [Tab(text: '工作'), Tab(text: '收款')])
        : (_chips.isEmpty ? null : PreferredSize(... chips 条 ...)),
  ),
  body: _loading ? progress
      : _error != null ? _ErrorView(onRetry: _load)
      : Column(children: [
          if (widget.showAggregateHeader) _AggregateHeader(agg: _headerAgg, kind: _filter.scope),
          Expanded(
            child: _filter.scope == RecordsScope.both
              ? TabBarView(controller: _tab, children: [
                  RecordListView(filter: _filter.copyWith(scope: RecordsScope.workOnly),
                                 companyNameById: _nameById, ruleNameById: _ruleNameById, ...),
                  RecordListView(filter: _filter.copyWith(scope: RecordsScope.paymentOnly),
                                 companyNameById: _nameById, ...),
                ])
              : RecordListView(filter: _filter, companyNameById: _nameById,
                               ruleNameById: _ruleNameById, ...),
          ),
        ]),
)
```

**`RecordsPage._load()`（2~3 并发查询）**：
1. `listCompanies(includeDisabled: true, includeDeleted: true)` → `_nameById`（**陷阱 2**）
2. `listPricingRules(includeDisabled: true, includeDeleted: true)` → `_ruleNameById`（**1 次全表规则查询**，供工作行显示工序；`includeDeleted: true` 是为让**已归档规则**的历史记录也能显示名字，仅用于建 Map，不用于展示）
3. 若 `showAggregateHeader` → `aggregate(_filter.companyId)`

`Future.wait` 并发；`aggregate` 抛 `FormatException` → 降级（合计显 `—` + 告警条），列表仍可渲染。

---

## §5 P07 `CompanyDetailPage` 数据装配（④ 的核心）

### 5.1 构造与骨架

```dart
// lib/ui/company_detail_page.dart
class CompanyDetailPage extends StatefulWidget {
  const CompanyDetailPage({super.key, required this.companyId});
  final String companyId;
}
```

**首屏结构**（`07:441`）：`公司名 + 剩余（大字 ≥32sp）` → `应收 / 已收 + 状态角标` → 分段切换 `工作记录 | 收款记录` → 列表 → **计价规则区块** → `+ 记一笔` / `记一笔收款` / `编辑公司`。

### 5.2 数据装配（**5 次查询，全并发，零 N+1**）

| # | 查询 | 用途 | 参数（**逐字**） |
|---|------|------|-----------------|
| q1 | `aggregate(companyId)` | 剩余大字 / 应收 / 已收 / 状态角标 | `database.dart:273` |
| q2 | `listCompanies(includeDisabled: true, includeDeleted: true)` | 公司名 + `enabled` + `deletedAt`（横幅判定） | `:451` |
| q3 | `listPricingRules(companyId: cid, includeDisabled: true, includeDeleted: true)` | ① 规则区块**展示列表**（Dart 侧滤 `deletedAt == null`）② `ruleNameById`（含**已归档**规则名，供历史工作行显示工序） | `:536` |
| q4 | （由子 `RecordListView` 发起）`listWorkRecords(companyId: cid)` | 工作 tab | `:619`（`includeDraft` 默认 `true`） |
| q5 | （由子 `RecordListView` 发起）`listPaymentRecords(companyId: cid)` | 收款 tab | `:910` |

- **并发还是串行（M-14 订正）**：**聚合类 q1~q3** 在 P07 的 `_load()` 里用 `Future.wait` **首帧并发**；**列表类 q4/q5** 由 `TabBarView` 的子页**按需发起**（`TabBarView` = `PageView` 语义，**默认只构建当前页**；切到「收款」tab 时才发起 q5）。→ 全程 **5 次** DB 读、**无逐行查询（零 N+1）**；**不宣称"首帧 5 次全并发"**。
- **为什么不用 `listCompanies` 只取一家**：可用 `getCompany(cid)`（`:437-443`，不过滤软删，1 行）替代 q2 以更省；本设计**按 `§D.6` 数据接线选 `listCompanies(...)`**，因为需要"公司元数据 + 状态"且与其它页口径一致。**若评审要求最小化读数，可换成 `getCompany(cid)`（1 行）**——不影响其它查询与结构。
- **规则区块一次查询服务两用途（Q-D4 定论）**：展示列表 = `q3.where((r) => !r.isDeleted)`（≡ `includeDeleted:false` 的可见集合）；`ruleNameById` 用全量（含已归档）以支持历史记录溯源（`§E-11` 允许弱引用悬空，此处仅用于**显示兜底**，否则历史行的工序名会空 → 真实 UX 缺陷）。
  - ⚠️ **与 `AC-P07-07a` 字面的差异（M-6，必须标注）**：AC 字面只写 `listPricingRules({companyId, includeDisabled: true})`（**未写** `includeDeleted`，其默认 `false`，已核实 `database.dart:536-540`）；本设计改用 `includeDeleted: true` **一次查全** + Dart 侧滤 `!isDeleted` 作展示集。**两者可见集等价**（`:557` 的 `deleted_at IS NULL`），差异仅在**多取到了已归档规则用于工序名兜底**。→ 已列入**回流 R4**（`02 §D.6 AC-P07-07a` 补 `includeDeleted: true` 的说明）。

### 5.3 单公司 `_load()` 伪码

```dart
Future<void> _load() async {
  try {
    final results = await Future.wait([
      _db.aggregate(widget.companyId),                                              // q1
      _db.listCompanies(includeDisabled: true, includeDeleted: true),               // q2
      _db.listPricingRules(companyId: widget.companyId,
                           includeDisabled: true, includeDeleted: true),            // q3
    ]);
    final agg = results[0] as ReceivableAggregate;
    final companies = results[1] as List<Company>;
    final rules = results[2] as List<PricingRule>;
    final company = companies.firstWhere((c) => c.id == widget.companyId,
                                         orElse: () => /* 兜底：未知公司占位 */);
    setState(() {
      _agg = agg;
      _company = company;
      _ruleNameById = {for (final r in rules) r.id: r.name};
      _visibleRules = rules.where((r) => !r.isDeleted).toList(growable: false);      // 见 §5.6
      _loading = false; _error = null;
    });
  } catch (e) { setState(() { _error = e; _loading = false; }); }
}
```
- `aggregate` 抛 `FormatException`（脏金额）→ **降级呈现**（`§D.0.3` 聚合坏值：应收可信、已收标"读取失败" + 顶部告警 + 引导导出备份），**不白屏**。
- 横幅：`company.enabled == false` → 停用横幅 + 「重新启用」（`database.dart:488`）；`company.deletedAt != null` → 已删除警示横幅（`§D.6`）。
  - ⚠️ **M-13① 施工注意**：真实签名是 **`updateCompany(Company x)`（整对象）**，`Company` **无 `copyWith`**；`07` 写的 `updateCompany(enabled: true)` 是**简写约定**。施工须**逐字段构造整对象**（保留 `id`/`ledgerId`/`name`/`shortName`/`color`/`defaultRuleId`/`contact`/`currency`/`note`/`createdAt`/`deletedAt`，仅改 `enabled` 与 `updatedAt`）——范例见 `company_page.dart:143-157`。
- 列表行点击注入：`onTapWork` → `WorkFormPage(id:)`（临时）；`onTapPayment` → `PaymentFormPage(id:)`。

### 5.4 分段切换（`07:450`）

`TabController(length: 2)`；两个 `RecordListView`：
- 工作：`RecordListView(filter: RecordsFilter.companyWork(cid), showCompanyName: false, showRuleName: true, ruleNameById: _ruleNameById, companyNameById: const {})`
- 收款：`RecordListView(filter: RecordsFilter.companyPayment(cid), showCompanyName: false, showRuleName: false)`
- **不截断**（`§C.1.1` 补充：P07 全量 + 滚动）。
- **P07 三种空态（M-11①，`07:463-466`）**：① 无工作记录 → tab 内空态 + `+ 记一笔`（`07:464`）；② 无收款记录 → tab 内空态 + `记一笔收款` + 提示「老板给钱后记一笔，剩余会自动减」（`07:465`）；③ **页面级空态**「**该公司从未有记录（新公司）**」→ 当 `agg.receivable == 0 && agg.received == 0`（且工作/收款两列表均空）时，在**头部区域**显示 `¥0.00` + 「**还没开始记账**」（`07:466`）——**零额外读**（复用 q1 的 `aggregate`）。第 ①/② 种由 `RecordListView` 的 `emptyTitle/emptyHint/emptyAction*` 注入。

### 5.5 P07 的动作按钮（`07:454-456`）

| 按钮 | Wave A 落点 | 备注 |
|------|------------|------|
| `+ 记一笔` | 命令式 `push(WorkFormPage(companyId: cid))` | **临时**（T-1） |
| `记一笔收款` | 命令式 `push(PaymentFormPage(companyId: cid))` | **不标临时**（N-5：P10 本体已在 Wave A） |
| `编辑公司` | **`Navigator.pushNamed(context, Routes.companies)`** + `// 临时(D1)`（M-2：保留活路由；P06 列表长按该行可编辑） | **临时**（P08 收口属 Wave D1；见 §13 Q-D3） |

### 5.6 ★ 计价规则列表区块（**Wave A ↔ Wave D1 接口契约**，不得返工）

**区块结构（Wave A 一次成型，AC-P07-07a）**：

```
计价规则（N 条）                     [新建规则]
──────────────────────────────────────────────
● 规则名            计价方式   基础单价      启用状态
  砌墙              日价       ¥300.00/天    停用   ›
  司机趟次          计件       ¥50.00/趟     启用   ›
──────────────────────────────────────────────
```

- 每行字段（`AC-P07-07a`）：**规则名**（`rule.name`）+ **计价方式**（`EnumCodec.pricingMethod(rule.method)`，`enum_codec.dart:14`）+ **基础单价**（`fenToYuan(rule.baseRate)` + 单位 `rule.unit`）+ **启用状态**（`EnumCodec.enabled(rule.enabled)`，`:110`）；**含停用项**（`includeDisabled: true`），**不含已归档**（Dart 侧滤 `!isDeleted`，对齐 C-4：`includeDeleted:true` 会产生"归档 + ensureRule 重建"的重复行）。
- **每行可点**：`onTap: () => _openRuleEditor(ruleId: rule.id)`。
- **「新建规则」入口**：`onTap: () => _openRuleEditor()`。

**唯一注入点（D1 只换函数体、不动结构）**：

```dart
/// Wave A：P09 未交付 → 占位提示（不白跳、不返工）。
/// Wave D1：只把本函数体替换为下面这段（M-11②：必须 await 后 _load()，否则
///          从规则编辑页返回时 P07 的规则列表不刷新）：
///   Future<void> _openRuleEditor({String? ruleId}) async {
///     await Navigator.of(context).push(MaterialPageRoute<void>(
///       builder: (_) => RuleEditPage(companyId: widget.companyId, ruleId: ruleId),
///     ));
///     if (!mounted) return;
///     await _load();                 // 规则列表 / ruleNameById 同步刷新
///   }
/// 页面结构、行组件、字段绑定、入口位置【一字不改】。
void _openRuleEditor({String? ruleId}) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('计价规则编辑将在下个版本上线')),
  );
}
```

- **Wave A 验收范围**：仅 **列表渲染正确**（`AC-P07-07a` 后半 + `07c`）；「行点击 → P09」「新建 → P09」的**行为验收归 Wave D1**（`AC-P07-07b` / `07a` 前半）。
- **Wave D1 的填充面**：仅替换 `_openRuleEditor` 函数体 + 引入 `RuleEditPage`。**P07 的 `_visibleRules`/`_ruleNameById`/区块布局/行渲染全部复用，零返工**（满足 `§A.3` 契约与 `AC-P07-07c`）。

---

## §6 P01 `overview_page.dart` 改造落点（① 的核心）

### 6.1 删除项（AC-P01-10）

| 删除对象 | 当前位置 | 依据 |
|---------|---------|------|
| `class _RecentSection` | `overview_page.dart:278-307` | AC-P01-10 |
| `class _RecentRow` | `:309-333` | AC-P01-10 |
| `class _RecentEntry` | `:154-167` | 仅服务于"最近 5 条" |
| `_buildRecent(...)` 方法 | `:79-103`（含 `take(5)` `:102`） | AC-P01-10（U-2 现场） |
| `_recent` 字段 | `:38` | 同上 |
| `_buildBody()` 内的 `_RecentSection(entries: _recent)` | `:144` | 同上 |
| **`class _StatsLine` + 其调用 + `_workCount`** | `:256-276` / `:138-142` / 字段 `:36` / 赋值 `:64` | **见 §13 Q-D7（定论移除）**：`07` P01 控件清单无此控件；`_workCount` **唯一**服务于它 → 移除不破坏既有功能，并省一次全表 `listWorkRecords()` |

> `take(5)`（`:102`）随 `_buildRecent` 整体删除；**不需要迁移**——"看最近记录"由「查看全部」承接（`AC-P01-09`：双 tab、全量不截断、`includeDraft: true`）。
>
> **删除项自检（N-D5）**：以下符号删除后 **`grep` 全部 0 命中**：`_RecentSection`/`_RecentRow`/`_RecentEntry`/`_buildRecent`/`_recent`/`_StatsLine`/`_workCount`。**行号仅作锚点，以符号名为准**。
> **文件头注释同步（N-D1）**：`overview_page.dart:1-4`（`:3` 写"统计行 → 最近 5 条"）**必须同步更新**，见 §3.4。

### 6.2 三金额加点击（AC-P01-03/04/05）

```dart
// _RemainingCard：加 onTap
class _RemainingCard extends StatelessWidget {
  const _RemainingCard({required this.agg, required this.onTap});
  final ReceivableAggregate agg;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,                       // 让 InkWell 水波被 Card 裁剪
    child: InkWell(onTap: onTap, child: Padding(/* 原 :180-199 内容一字不动（M-13② 订正 off-by-one） */)),
  );
}

// _MiniStat：加 onTap
class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, required this.color, required this.onTap});
  ...
  Widget build(...) => InkWell(onTap: onTap, child: Column(/* 原 :240-252 内容 */));
}

// _ReceivableReceivedRow：透传两个回调
_ReceivableReceivedRow({
  required this.agg, required this.onReceivableTap, required this.onReceivedTap,
})
```

**点击 → 跳转（命令式，均 `await` 后 `_load()`）**：
- `_RemainingCard.onTap` → `CompanyDebtListPage()`
- `应收合计` → `RecordsPage(filter: RecordsFilter.receivableDrill, title: '应收明细', showAggregateHeader: true)`
- `已收合计` → `RecordsPage(filter: RecordsFilter.receivedDrill, title: '收款明细', showAggregateHeader: true)`

### 6.3 新增公司卡片区（`_CompanyCardSection`，`07:208/217-224`）

> **现状该区块不存在**（§1 已核实），本设计**从零新增**。位置：`_buildBody()` 的 `children` 中，紧接 `_ReceivableReceivedRow` 之后（`:136` 与 `:137` 之间）。

**单卡内容（`07:217-224`）**：

| 元素 | 绑定 | 规则 |
|------|------|------|
| 公司名（+ 简称） | ~~**`company.displayName`**~~ → **全名 `company.name`**；`shortName` 非空时追加「（`shortName`）」（**勘误 E-14**，见 §6.3.1） | 合 `07:218`「公司名 + 短名」；~~**M-13③：禁止「短名回落全名」的写法（`shortName ?? company`）**~~ — **该禁令已作废**（只禁止 `String? ?? Company` 这个**类型错误**写法，不禁止回落全名） |
| 标记色点 | `Color(0xFF000000 \| company.color)`（**禁** `Color(company.color)`） | `07 §1.4` |
| **剩余**（≥28sp） | `aggById[c.id]?.remaining ?? 0` | 负数前缀「多收」 |
| 小字 应收 / 已收 | `.receivable` / `.received` | `¥X · ¥Y` |
| 状态角标 | `receivableStatusLabel(receivable, received)`（`receivable_status.dart`，PRD §5.2 严格等号） | 未开工/未收/部分收款/已结清/多收·待核对 |
| **「还没记过账」**（M-10①/`07:241`） | `aggById[c.id]` 的 `receivable == 0 && received == 0` → 卡内显示「**还没记过账**」 | **零额外读**（复用 q2 派生值）；`02 §D.1:361` / `07 §4.1 D3 ③` 同文要求；登记回流（R2/R7） |
| 停用 / 已归档角标 | `company.enabled == false` / `company.deletedAt != null` | `CompanyFlagChips` |
| 最近收款时间 + 「已 X 天未收款」 | 由 q4 全量 `listPaymentRecords()` **按公司分组取首条**（**M-6：禁逐卡查询**） | 仅 `remaining > 0` 显示；无收款 → 「从未收款」；有 → 「已 X 天未收款」（`今天 − 最近收款日`，日期整数天） |
| 卡片点击 | → `CompanyDetailPage(companyId: c.id)` | AC-P01-06（**U-1 直接验收点**） |

- **顺延登记（R22）**：P01 公司卡片区（及 P04 分组列表）的 `ListView.builder` 惰性化；顺延依据 = `11 §10.4` / `§9.7`；**未排期**；**理由 = `app/**` 自 Wave D2 收口后冻结（`gen_kernel rc=0` + 10 个 `verify_*.dart` **590/0** 全绿），改动会作废该基线，而出包验收在即**。（现盘卡片区为 `ListView`，非 `.builder`；数据量个位数至几十，实测无卡顿。）

#### 6.3.1 ⚠️ 勘误 **E-14**（主理人 2026-10-06，裁定见 `11 §9.2/§9.3`）——公司名**禁用 `displayName`**

- **原设计（已作废）**：公司名主标签一律用 `company.displayName`。
- **实测反证（主理人独立核实）**：`shortName` 在本 App **无任何 UI 可设置**——新建公司写死 `shortName: null`（`company_page.dart:161`），编辑对话框仅透传（`:201`/`:372`），**全仓唯一可能赋非 null 的路径是备份导入**（`import_service.dart:307`）。而 `displayName`（`models/company.dart:40-45`）= 简称非空取之，**否则取 `name` 前 2 字**。
  ⇒ 实际渲染 = **公司名前 2 个字**；「某某建筑」与「某某劳务」显示成同一个词 → **用户分不出欠谁的钱**。
- **修正（R-14）**：**主标签用全名 `company.name`**；`shortName` 非空时追加「（简称）」：
  ```dart
  final label = (c.shortName == null || c.shortName!.isEmpty)
      ? c.name
      : '${c.name}（${c.shortName}）';
  ```
- **`displayName` 不删不改**：保留给 **Wave C 的 P03 日历窄格**使用（窄格才需要 2 字标签）；**本波只是不在主标签位使用它**。
- **同步作废**：`§16` 自检项 `grep "shortName ?? company"` → 改为 `grep "displayName"` 在 **4 个 UI 文件**（`overview_page` / `company_page` / `company_detail_page` / `debt_list_page`）**0 命中**。
- **同源勘误**：`§7.4`（P-DEBT 行）、`§9.2`（P06 tile）中的 `displayName` 一并作废，同按本节修正。

> **★ 阶段⑤ 双回流 R14 合并标记（勘误 E-14）**：本节「**修正（R-14）**：主标签用全名 `company.name`」段为**权威正文**，`§5.1` / `§6.3` / `§7.4` / `§9.2` 四处的 `displayName` 行**已就地改为全名口径**（删除线标记**保留可溯**，依本项目「严禁删除既有内容」铁律，未删块）。`02 §F` 侧偏差登记见 `02 §F-26`（3 处：E-11.3-1 / E-3.3-1 / E-14）。

**「全部公司」入口**（AC-P01-08 / `07:229`）：卡片区块**尾部**一个 `ListTile('全部公司', trailing: chevron)` → **`Navigator.pushNamed(context, Routes.companies)`（M-2：保留为活路由，不得改命令式）**。**该入口是 P06 的第一条入边**（第二条在 P12，Wave C1）。

**排序**：按 `company.createdAt ASC`（`listCompanies` 的 `orderBy`，`database.dart:481`）——与 P06 一致，避免两页顺序不同。

### 6.4 `_load()` 改造（**4 次查询，全并发**）

```dart
Future<void> _load() async {
  try {
    final res = await Future.wait([
      _db.aggregate(null),                                                          // q1 全局剩余（权威）
      _db.aggregateByCompany(),                                                     // q2 各公司金额（一次查完）
      _db.listCompanies(includeDisabled: true, includeDeleted: true),               // q3 元数据全集（陷阱2；修 AC-P01-07）
      _db.listPaymentRecords(),                                                     // q4 最近收款时间（M-6：全量+UI 分组）
    ]);
    ...
    setState(() { _agg = ...; _aggById = {for (final a in aggByCompany) a.companyId!: a};
                  _companies = ...; _latestPaymentByCompany = ...; _loading = false; });
  } catch (e) { /* 聚合坏值 → 降级；其它 → _ErrorView */ }
}
```

- **AC-P01-07 修复**：`listCompanies()`（裸调，`:56`）→ `listCompanies(includeDisabled: true, includeDeleted: true)`；空态判据由 `_companyCount == 0`（`:126-128`）改为 `_companies.isEmpty`（**含停用/归档**）→ 唯一公司被停用后**不再落进"无公司"空态**。
- **未出现的公司 = 全 0**（`database.dart:329-332` 注释）：`_aggById[c.id] ?? ReceivableAggregate(companyId: c.id, receivable: 0, received: 0, remaining: 0)`。
- **开发期断言**（AC-P01-13）：`assert(_agg!.remaining == _aggById.values.fold(0, (s, a) => s + a.remaining))`（仅 debug，`assert` 天然在 release 关闭）。
- **N-D6（如实写入交付说明）**：改造后 P01 的读数为 **4 次** = `aggregate(null)` / `aggregateByCompany()` / `listCompanies(双 true)` / `listPaymentRecords()`。**其中 `listPaymentRecords()` 是既有行为**（`overview_page.dart:58` 今日已全量读），**非本波新增**；本波的**真实性能改善**是把它与另三次由**现状的串行 4 次 `await`**（`:53-58`）改为 **`Future.wait` 并发**。

### 6.5 「查看全部」入口（AC-P01-09）

卡片区之后新增一行 `Card(child: ListTile('查看全部记录', trailing: chevron, onTap: ...))` → `RecordsPage(filter: RecordsFilter.all, title: '全部记录')`（双 tab、全量不截断、`includeDraft: true`，草稿行显 `—`）。

### 6.6 「+ 记一笔」按钮（T-1，P01 自身入口，N-4 补漏）

- 「记一笔工作」→ `await Navigator.pushNamed(context, Routes.workForm); _load();`（**保留既有命名路由**，新建态无预置）。
- 「记一笔收款」→ `await Navigator.pushNamed(context, Routes.paymentForm); _load();`
- 「记一笔工作」标**"临时"**（Wave D1 交付 P02 后由 Wave D2 统一替换为弹层）。
- 「记一笔收款」**不属"临时"**：该入口指向 **P10**（收款登记），**已列 Wave A**，**永不会被替换为弹层**。—— **R72 订正**：原句把「记一笔工作」与「记一笔收款」**一并判为"临时"**，属**双重失实**（既误把指向 P10 的收款入口当作 P02 临时入口，又声称它会被"统一替换为弹层"）。
- **O-3 登记**：`07:226` 的 P01 `+ 记一笔` 为**悬浮主按钮（FAB）**；Wave A **保留现有两个 `FilledButton`**（`overview_page.dart:335-360`）的**临时降级**，**FAB 形态推 Wave D2** → 入回流 R8。

### 6.7 空态文案收口（AC-P01-11）

`_EmptyView`（`:362-388`）：**按钮**由『去添加公司』→ **『先建一个公司』**（`07:240`，**逐字不改**）；**标题**由『先添加一家公司』→ **『还没有公司』**（**勘误 E-15 / 补丁 S2**：`07:240` **只规定按钮文案**，AC-P01-11 亦只约束「主按钮文案与出口」→ 标题不受该字面约束；若把标题也改成同句，会出现**标题与按钮两遍同一句话**）；出口**沿用 `Navigator.pushNamed(context, Routes.companies)`**（M-2：**不得改命令式**，否则 `Routes.companies` 变死路由）`// 临时(D1)`（P08 真页在 Wave D1；见 §13 Q-D3）。

---

## §7 P-DEBT `CompanyDebtListPage`（② 的核心）

### 7.1 名称与构造

```dart
// app/lib/ui/debt_list_page.dart
class CompanyDebtListPage extends StatefulWidget {
  const CompanyDebtListPage({super.key});   // 无参（入口不携带筛选）
}
```
> 最终命名/归属由阶段②确定（`§C.1.2` 授权）；本设计定名 `debt_list_page.dart` / `CompanyDebtListPage`，标题「**谁还欠我钱**」。

### 7.2 数据装配（**3 次查询，全并发**）

| # | 查询 | 用途 |
|---|------|------|
| q1 | `aggregateByCompany()`（`database.dart:333`） | 各公司应收/已收/剩余（**一次查完，零 N+1**） |
| q2 | `listCompanies(includeDisabled: true, includeDeleted: true)`（`:451`） | 公司名 + 停用/归档角标（**陷阱 2**） |
| q3 | `aggregate(null)`（`:273`） | **仅用于口径标注 + 恒等式断言/单测**（不当作「欠款合计」） |

`Future.wait` 并发。q1 抛 `FormatException` → 降级（`§7.4`）。

### 7.3 「欠款合计」口径（**写死，AC-PDBT-05 / `§C.1.2` 口径禁令**）

```dart
// 行集：仅 remaining > 0 的公司
final rows = aggByCompany
    .map((a) => _DebtRow(company: byId[a.companyId!], agg: a))
    .where((r) => r.agg.remaining > 0)
    .toList()
  ..sort((a, b) => b.agg.remaining.compareTo(a.agg.remaining));   // 倒序（AC-PDBT-02）

final debtTotal    = rows.fold<int>(0, (s, r) => s + r.agg.remaining);          // 「欠款合计」
final overpaidAbs  = aggByCompany.where((a) => a.remaining < 0)
                                 .fold<int>(0, (s, a) => s + (-a.remaining));    // 「多收合计的绝对值」

// 开发期断言 / 单测（AC-PDBT-05）：
assert(debtTotal - overpaidAbs == globalAgg.remaining,
       'P-DEBT 恒等式被破坏：欠款合计 − 多收 = 全局剩余');
```

- **禁**：把 `debtTotal` 当作 `aggregate(null).remaining`（后者是**扣除多收后的净值**）。
- **页面显式标注**（满足"须显式标注口径不同"）：顶部副标题写 "**欠款合计 ≠ 看板「剩余工资」**（看板扣除多收）"；底部一行 "看板剩余（已扣多收）：`fenToYuan(globalAgg.remaining)`"。
- **边界**：仅含**草稿**记录的公司不出现在 `aggregateByCompany()` 中（`database.dart:331-332`）→ 其 remaining 恒为 0，**不影响**恒等式（0 贡献）。

### 7.4 页面结构 / 空态 / 错误态 / 边界

| 项 | 实现（对齐 `§C.1.2` `§C.1.3`） |
|----|------|
| 首屏 | 标题「谁还欠我钱」+ 顶部「共 N 家公司 · **欠款合计 ¥X**」+ `ListView.builder`（≥100 家惰性，AC-PDBT-09） |
| 每行 | ~~`displayName`~~ → **全名 `company.name`**（`shortName` 非空追加「（简称）」；**勘误 E-14**，见 §6.3.1）+ 色点（`Color(0xFF000000 \| color)`）+ 「应收 ¥A − 已收 ¥B = 剩余 ¥C」（**整数分**，`fenToYuan`）+ `ReceivableStatusChip` + `CompanyFlagChips`（停用/已删除） |
| 行点击 | → `CompanyDetailPage(companyId)`（AC-PDBT-04） |
| 空态 | 无 `remaining > 0` 的公司 → 居中「**太好了，没有公司欠你钱**」；若存在 `remaining < 0` 的公司 → 附一行「有 N 家「多收 / 记错」，**点此核对**」→ 本地切换 `_showAll = true`，显示「多收核对」视图。**M-13④ 订正**：该视图**行集 = `remaining < 0`（与提示计数 `overpaidAbs` 同口径）**，按 `remaining` **升序**；`remaining == 0`（已结清）**两处均不显示**（`§C.1.2` 未要求其出现）——**页面实例内保留，跨次进入不记忆**（AC-PDBT-08） |
| 错误态 | q1 抛 `FormatException` → **不白屏**：黄色告警条「**账目数字可能不完整**」+「导出备份」引导 + 「重试」（AC-PDBT-07） |
| 加载态 | 居中进度圈 |
| 返回 | `AppBar` 自动返回箭头 / 系统返回 → P01；P01 在 `await push` 后 `_load()` |
| 排序 | `remaining` 倒序（AC-PDBT-02） |

- **顺延登记（R23）**：P-DEBT / P07 / P01 三页内联的「黄条 + 导出备份 + 重试」降级条应抽为共享件（`ui/widgets/degraded_banner.dart`），避免三处文案与行为漂移；顺延依据 = `11 §9.7`；**未排期**；**理由 = `app/**` 自 Wave D2 收口后冻结（`gen_kernel rc=0` + 10 个 `verify_*.dart` **590/0** 全绿），改动会作废该基线，而出包验收在即**（跨页统一设计不应由单页批内发明）。
- **顺延登记（R24）**：降级态「理想档」（`*Lenient` 行级隔离 + 「有 N 条数据异常…」告警条）三页统一；顺延依据 = `11 §9.7`；**未排期**；**理由 = `app/**` 自 Wave D2 收口后冻结（`gen_kernel rc=0` + 10 个 `verify_*.dart` **590/0** 全绿），改动会作废该基线，而出包验收在即**（本波三页统一采 `07 §4.4 D5` 退让档：不白屏 + 告警 + 导出引导 + 重试）。

---

## §8 导航接线（**全部新增 push 点**）

> **为什么不需要改 `onGenerateRoute`**：① 所有**新增页**跳转均为 **命令式 `Navigator.push(MaterialPageRoute(builder: (_) => XxxPage(...)))`**，参数是**强类型构造参数**（不走 `RouteSettings.arguments`，故不需要 `_extractId` 的 `Map`/query 解析）；② 新页面**不注册命名路由**，`routes.dart` 无需新增常量；③ `RecordsPage` 的新参数**全部可选且 `const` 默认**，故 `main.dart:55-56` 的 `const RecordsPage()` 与 `MainShell` 的 `_pages`（`main.dart:190-194`）**原样编译**。
> **M-2 例外（务必遵守）**：**目标为 P06 的跳转一律 `pushNamed(Routes.companies)`**（P01「全部公司」、P01 空态主按钮、P07「编辑公司」）。`Routes.companies` 的**唯一调用点**是 `overview_page.dart:379`；改命令式 → 它变**新增死路由**。`Routes.companies` **不列入 A2 清理**。

| 起点控件（文件:行） | 目标页 | 跳转方式 | 传参 | 返回后 |
|---------------------|--------|---------|------|--------|
| P01 `_RemainingCard`（`overview_page.dart:169-203`） | `CompanyDebtListPage()` | 命令式 push | 无 | P01 `_load()` |
| P01 `应收合计`（`_MiniStat`，`:232-254`） | `RecordsPage(filter: receivableDrill, title:'应收明细', showAggregateHeader:true)` | 命令式 push | `RecordsFilter` | P01 `_load()` |
| P01 `已收合计`（`_MiniStat`） | `RecordsPage(filter: receivedDrill, title:'收款明细', showAggregateHeader:true)` | 命令式 push | `RecordsFilter` | P01 `_load()` |
| P01 公司卡片（**新增** `_CompanyCardSection`） | `CompanyDetailPage(companyId: c.id)` | 命令式 push | `String companyId` | P01 `_load()` |
| P01 「全部公司」（**新增** 卡片区尾入口） | P06 | **`pushNamed(Routes.companies)`**（M-2） | 无 | P01 `_load()` |
| P01 「查看全部记录」（**新增**） | `RecordsPage(filter: all, title:'全部记录')` | 命令式 push | `RecordsFilter` | P01 `_load()` |
| P01 空态主按钮（`:378-382`） | P06（**临时(D1)**：P08 真页在 D1） | **`pushNamed(Routes.companies)`**（M-2，**保留既有调用点**） | 无 | P01 `_load()` |
| P01 「记一笔工作」（`:340-347`） | `pushNamed(Routes.workForm)`（**保留既有**，临时） | 命名路由 | 无 | P01 `_load()` |
| P01 「记一笔收款」（`:349-356`） | `pushNamed(Routes.paymentForm)`（保留既有） | 命名路由 | 无 | P01 `_load()` |
| P07 工作行 | `WorkFormPage(id: r.id)`（**临时** T-1） | 命令式 push | `String id` | P07 `_load()` |
| P07 收款行 | `PaymentFormPage(id: p.id)` | 命令式 push | `String id` | P07 `_load()` |
| P07 「+ 记一笔」 | `WorkFormPage(companyId: cid)`（**临时** T-1） | 命令式 push | `String companyId` | P07 `_load()` |
| P07 「记一笔收款」 | `PaymentFormPage(companyId: cid)` | 命令式 push | `String companyId` | P07 `_load()` |
| P07 「编辑公司」 | P06（**临时(D1)**：P08 真页在 D1） | **`pushNamed(Routes.companies)`**（M-2） | 无 | P07 `_load()` |
| P07 规则行 / 「新建规则」 | `_openRuleEditor(...)`（Wave A = SnackBar 占位；D1 = P09） | 注入点 | — | — |
| P07 停用横幅「重新启用」 | 就地 `updateCompany(整对象)` + `dataBus.dataChanged()` | 就地写 | — | P07 `_load()` |
| P-DEBT 行 | `CompanyDetailPage(companyId)` | 命令式 push | `String companyId` | P-DEBT `_load()` |
| P-DEBT 「点此核对」 | 就地切换 `_showAll`（无跳转） | 就地 | — | — |
| P06 行点击（`company_page.dart:293`） | `CompanyDetailPage(companyId: c.id)` | 命令式 push | `String companyId` | P06 `_load()` |
| RecordsPage 工作行 | `WorkFormPage(id: r.id)`（临时） | 命令式 push | `String id` | RecordsPage `_load()` |
| RecordsPage 收款行 | `PaymentFormPage(id: p.id)` | 命令式 push | `String id` | RecordsPage `_load()` |
| RecordsPage 空态「记一笔工作」 | `WorkFormPage(companyId: filter.companyId)`（临时；无公司则 `WorkFormPage()`） | 命令式 push | — | RecordsPage `_load()` |
| RecordsPage 空态「记一笔收款」 | `PaymentFormPage(companyId: filter.companyId)` | 命令式 push | — | RecordsPage `_load()` |

**统一写法（每个 push 点）**：
```dart
await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TargetPage(...)));
if (!mounted) return;
await _load();            // §0.2-7：无条件重载
```

---

## §9 P06 `company_page.dart` 收口（⑥）

### 9.1 `_load()` 改造

```dart
final results = await Future.wait([
  _db.listCompanies(includeDisabled: true, includeDeleted: true),  // 加 includeDeleted（AC-P06-03；现 :66 只有 includeDisabled）
  _db.aggregateByCompany(),                                        // 加：行内金额（AC-P06-02，一次查完）
]);
_aggById = {for (final a in agg) a.companyId!: a};
```
- 未出现的公司 → 全 0 补齐（`database.dart:331-332`），**不得**判为不存在。
- 空态判据 `_companies.isEmpty`（含停用/归档）。
- **★ 阶段⑤ 双回流 R20 登记（已知限制）**：滑动删除后该行以「已删除」角标**重新出现**（`_load()` 双 `true` 把已归档公司查回）→ **瞬时抖动**；属 `AC-P06-03`「有账必列 / 归档仍显示」的**必然结果**，**非缺陷、本波不改**。

### 9.2 `_CompanyTile` 改造（`company_page.dart:302-342`）

| 变更 | 内容 |
|------|------|
| title 行 | ~~`displayName`~~ → **全名 `company.name`**（`shortName` 非空追加「（简称）」；**勘误 E-14**，见 §6.3.1）+ `ReceivableStatusChip`（PRD §5.2） |
| subtitle 行 | 「剩余 ¥Z · 应收 ¥A / 已收 ¥B」（`fenToYuan`，整数分） |
| trailing | `CompanyFlagChips`（停用/已删除灰角标）+ 「⋯」`IconButton`（弹出菜单：编辑/停用/删除） |
| `onTap`（`:293`） | **改**：`() => _openDetail(c)`（→ `CompanyDetailPage(companyId: c.id)`） |
| `onLongPress`（`:294`） | 保留（编辑/删除菜单，`_onLongPress` `:199-225` 不动） |

- **AC-P06-04**：编辑/停用/删除入口 = 行尾「⋯」菜单 + 长按（两处都保留；编辑仍走既有 `_onEdit` → `_CompanyEditDialog`，P08 收口属 Wave D1）。
  - **★ 阶段⑤ 双回流 R21 补登**：P06 删除实为**三个入口** —— 行尾「⋯」菜单 + 长按 + **滑动删除 `Dismissible`**（`company_page.dart`）；本节与 `11 §9.6` 原仅列**两个**，**第三入口（滑动删除）补登于此**；`02 §D.12` AC-P06-04 同步补登。
- **「停用/启用」菜单项**：`_onLongPress`（`:199-225`）现只有「编辑/删除」；AC-P06-04 要求「编辑/停用/删除」→ **Wave A 在「⋯」菜单中补一项「停用/启用」**（二次确认文案「历史账目不受影响，只是不再出现在快记里」，`07:488`）。这是 P06 内的小补，**不动** `_CompanyEditDialog`。
  - ⚠️ **M-13① 施工注意**：写方法真实签名为 **`updateCompany(Company x)`（整对象，`database.dart:488`）**，`Company` **无 `copyWith`**；`07` 的 `updateCompany(enabled:false)` 是**简写**。施工须**逐字段构造整对象**（范例 `company_page.dart:143-157`），仅改 `enabled` 与 `updatedAt`。
  - **★ 阶段⑤ 双回流 R19 登记**：**已归档（`deletedAt != null`）公司的「停用/启用」菜单项不适用** —— `listCompanies()` 同时滤停用与软删，改 `enabled` 不产生任何可见变化；**本版不提供取消归档**（`app/lib` 内 `restore` / `undelete` 命中 0），归档后**唯一恢复路径 = 导入备份**。**`P-DEBT`（R19）**：后续可隐藏该项（**本版不改**，理由 = `app/**` 已冻结 + `AC-P06-04` 要求「编辑 / 停用·启用 / 删除」三入口）。

---

## §10 刷新策略（写死，落实约束 10）

1. **每页**（RecordsPage / RecordListView / CompanyDetailPage / CompanyDebtListPage / OverviewPage / CompanyPage / PaymentFormPage）：`initState` → `dataBus.addListener(_load); _load();`；`dispose` → `dataBus.removeListener(_load);`（**必须成对**，现有范例 `records_page.dart:52-64`）。
2. **每次 `await Navigator.push(...)` 之后**，调用方**无条件** `if (mounted) await _load();`（`§0.2-7`）。**不依赖返回值**。
3. **每次写库成功后**：`dataBus.dataChanged()`（`data_bus.dart:11`）。写库成功 —— `upsertWorkRecord` / `upsertPaymentRecord` / `softDeleteWorkRecord` / `softDeletePaymentRecord` / `updateCompany`（重新启用/停用）。
4. **不使用任何状态管理库**；不用 `FutureBuilder` 驱动列表（避免重复触发）；一律 `StatefulWidget` + `setState` + 页面级 `_load()`。
5. **派生值不缓存为真相**：页面每次 `_load()` 重新聚合（`§D.0.2-2`）。

---

## §11 P10 `payment_form_page.dart` 收口算法（⑤ 的核心）

### 11.1 新增状态与加载

```dart
class PaymentFormPage extends StatefulWidget {
  const PaymentFormPage({super.key, this.id, this.companyId});   // companyId 新增（T-1）
  final String? id;
  final String? companyId;
}
```
State 新增：
```dart
bool _lockCompany = false;      // 从 P07 进入：公司预置且锁定（07:540）
int? _remainingFen;             // aggregate(cid).remaining；null = 尚未取到/取失败
int? _receivableFen;            // aggregate(cid).receivable（判定"应收为0"文案）
bool _remainingDegraded = false;// aggregate 抛 FormatException
```

`_load()` 末尾（`payment_form_page.dart:82-122` 内）：
```dart
if (!_isEditing && widget.companyId != null) {
  _companyId = widget.companyId;   // 预置
  _lockCompany = true;             // 锁定（07:540）
}
... // setState 后
await _refreshRemaining();         // 公司确定后立即取剩余
```

```dart
Future<void> _refreshRemaining() async {
  final cid = _companyId;
  if (cid == null) { setState(() { _remainingFen = null; _receivableFen = null; _remainingDegraded = false; }); return; }
  try {
    final agg = await _db.aggregate(cid);          // 唯一来源（§D.14）
    if (!mounted) return;
    setState(() { _remainingFen = agg.remaining; _receivableFen = agg.receivable; _remainingDegraded = false; });
  } catch (e) {
    if (!mounted) return;
    // FormatException（脏金额）：不静默；标记降级，跳过 AC-24 比较（无法核对），但仍允许保存（有告警）
    setState(() { _remainingFen = null; _receivableFen = null; _remainingDegraded = true; });
  }
}
```
**触发点**：`CompanyPicker.onChanged`（`:291-294`）→ `setState(_companyId = id); _refreshRemaining();`；`_onCompanyCreated`（`:232-245`）→ 新公司剩余 0，`_refreshRemaining()`。

> ⚠️ **M-12/M-4 前提（已核实）**：**编辑态公司下拉并未禁用** —— `payment_form_page.dart:105` 把 `_companyId = existing.companyId` 后，`CompanyPicker`（`:286-295`）**无 `enabled:false`/锁定**，故**编辑态确实可切换公司**；`_lockCompany = true` 只在**新建态从 P07 预置**时置位（`07:540` 的"预置且锁定"仅指该入口）。
> 由此：`_remainingFen` **始终是"当前选中公司"的 `aggregate().remaining`**（公司一变就 `_refreshRemaining()` 重取）——这正是 §11.3 `_compareBase()` 必须按**当前公司**取值的原因。

### 11.2 实时剩余提示（AC-P10-02，**整数分**）

```dart
String? _remainingHint() {
  if (_companyId == null) return null;
  if (_remainingDegraded) return '账目数字可能不完整，暂时无法核对剩余';
  final x = _remainingFen;
  if (x == null) return null;
  final a = yuanToFen(_amountCtrl.text);
  if (a == null || a <= 0) {
    // 仅未输入金额时：显示当前欠款
    if (x > 0) return '该公司现在还欠 ${fenToYuan(x)}';
    if (x == 0) return '该公司目前不欠钱（剩余 ${fenToYuan(0)}）';
    return '该公司已多收 ${fenToYuan(-x)}，请核对是否记错';
  }
  final y = x - a;                      // 整数分
  if (y > 0)  return '记完这笔后将剩 ${fenToYuan(y)}';
  if (y == 0) return '记完这笔后将结清（剩余 ${fenToYuan(0)}）';
  return '记完这笔后将多收 ${fenToYuan(-y)}';   // Y 为负 → 显示绝对值 + "将多收"
}
```
| 情形 | 文案 |
|------|------|
| `X > 0`（未输入金额） | 「该公司现在还欠 ¥X」 |
| `X == 0` | 「该公司目前不欠钱（剩余 ¥0.00）」 |
| `X < 0` | 「该公司已多收 ¥\|X\|，请核对是否记错」 |
| `Y = X − A > 0` | 「记完这笔后将剩 ¥Y」 |
| `Y == 0` | 「记完这笔后将结清（剩余 ¥0.00）」 |
| `Y < 0` | 「记完这笔后将多收 ¥\|Y\|」 |

> 金额恒为 `int`；`fenToYuan` 已处理负号，此处对 `-x`/`-y` 取正后再交给 `fenToYuan` 以配合"多收"措辞。

### 11.3 ★ AC-24 超过剩余二次确认（**阈值严格 `>`**）

**判定基准 T（M-12 定论 · 含"编辑态改公司"分支）**：

> **规则（写死）**：`_remainingFen` 恒为**当前选中公司**的 `aggregate().remaining`（公司一变即 `_refreshRemaining()` 重取，见 §11.1）。
> - **新建** → `T = _remainingFen`；
> - **编辑 · `companyId` 未变** → `T = _remainingFen + 原金额`（`_remainingFen` 已含本条原金额，须先剔除本条自身再比较，否则"持平编辑"误判）；
> - **编辑 · `companyId` 变更** → `old = 0`，`T = _remainingFen`（即 `aggregate(目标公司).remaining`，**不得**把原公司金额累加进来）。

```dart
int? _compareBase() {
  final x = _remainingFen;                       // 恒为"当前选中公司"的 remaining（公司变更后已重取）
  if (x == null) return null;
  if (!_isEditing) return x;                     // 新建
  final sameCompany = _existing!.companyId == _companyId;   // 编辑态：是否仍指向原公司
  final old = sameCompany ? _existing!.amount : 0;          // 改了公司 → old = 0
  return x + old;
}
```

**编辑态改公司时的额外提示（N-D3）**：当 `_isEditing && _existing!.companyId != _companyId` 时，除对**目标公司**重取 `aggregate(目标公司)`（已由 `_refreshRemaining()` 完成）外，**额外 1 次** `aggregate(原公司)` 仅用于**一次性提示**（**不阻断保存**）。成本 = 公司变更时 +1 次读（**非 N+1**，仅变更时触发一次）。

> ### ⚠️ 勘误 E-11.3-1（主理人 · 2026-10-06 · 阶段③ 批 1 独立审查发现）
> **本节下方原示例代码有口径错误，已作废并按下文修正**（同批已开勘误，见 `11-主理人裁定（WaveA设计）.md §8`）。
> **错在哪**：原代码读**移动前**的 `aggregate(原公司).remaining`（**该值已含本条金额**），却拿它当"移出后"的结论。
> **自证伪（自造数字）**：原公司 `remaining = −100`、本条 `400` → 移出后原公司 = `−100 + 400 = +300`（**根本不欠多收**），原代码却会提示"变成多收"（**假告警**）；`remaining = −500`、本条 `400` → 移出后实为 `−100`，原代码却显示 `−500`（**数字错**）。
> **正确口径**：收款减少 → 其余额**增大** → **移出后原公司剩余 = `agg.remaining + 原金额`**。**须以该值判负与显示。**

**修正后（以此为准）**：
```dart
/// 公司变更时调用（仅编辑态、仅当真的换了公司）。
/// 注意：用的是**移出后**的推算值 —— aggregate(原公司).remaining 已含本条金额，
/// 把本条移走会让原公司"已收"减少、剩余**增大**，故须 + 原金额。（勘误 E-11.3-1）
Future<void> _hintMovedOutOfOriginal(String originalCompanyId) async {
  try {
    final agg = await _db.aggregate(originalCompanyId);
    if (!mounted) return;
    final afterMove = agg.remaining + (_existing?.amount ?? 0);  // 移出后原公司的剩余
    if (afterMove < 0) {                                        // 真的变成多收才提示
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('该笔收款改到别的公司后，原公司将变成多收 ${fenToYuan(afterMove)}，请注意核对'),
      ));
    }
  } catch (_) { /* 脏值：忽略提示，不影响保存 */ }
}
```
> 保留"**只在真的产生多收时提示**"这个条件 —— 否则每次改公司都弹，太吵。

> **★ 阶段⑤ 双回流 R11 合并标记（勘误 E-11.3-1）**：上引「**修正后（以此为准）**」段为**权威正文**，勘误内容已就地合并；其下「~~原示例（已作废，勿照抄）~~」代码块**保留可溯**（依本项目「严禁删除既有内容」铁律，未删块）。`02 §F` 侧偏差登记见 `02 §F-26`。

**~~原示例（已作废，勿照抄）~~**：
```dart
Future<void> _hintMovedOutOfOriginal(String originalCompanyId) async {
  try {
    final agg = await _db.aggregate(originalCompanyId);
    if (!mounted) return;
    if (agg.remaining < 0) {                       // ❌ 错：这是移动前的值，且已含本条
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('该笔收款改到别的公司后，原公司$(fenToYuan(agg.remaining)) 变成多收，请注意核对'),
      ));
    }
  } catch (_) { /* 脏值：忽略提示，不影响保存 */ }
}
```

**触发（在 `_save()` 校验通过后、写库前）**：
```dart
Future<bool> _confirmIfOverpay(int amountFen) async {
  final t = _compareBase();
  if (t == null) return true;                 // 剩余不可用（降级）→ 不阻断（已有告警）
  if (!(amountFen > t)) return true;          // 阈值 =【严格大于】；== 不弹（AC-P10-01）
  final noWork = (_receivableFen ?? 0) == 0;  // 07:558 先收钱后干活
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('确认收款金额？'),
      content: Text(noWork
          ? '该公司还没有工作记录，确认是真收到钱？'
          : '这次收的钱比公司欠的还多，确认吗？（可能"多给"或"记错"）'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('再核对一下')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('确认，就收这么多')),
      ],
    ),
  );
  return ok == true;
}
```
`_save()`（`:152-191`）插入点：`if (!companyOk || !amountOk) return;` 之后、`setState(() => _saving = true);` 之前：
```dart
if (!await _confirmIfOverpay(amountFen!)) return;   // 取消 → 保留用户输入，不写库
```
- **`==` 不弹**（AC-P10-01 写死）；**`>` 才弹**。
- `X == 0` 且 `A > 0` → 必然 `A > 0 == T` → 触发，且文案走"还没有工作记录"分支（AC-P10-04）。
- `X < 0`（多收公司）→ `A > T` 恒真（`A>0>T`）→ 必触发（正确：已多收再收更可疑）。
- 确认后：**新建分支**照常 `upsertPaymentRecord`（`database.dart:890`）；**编辑分支改用 `updatePaymentRecord`（`database.dart:983`）**（**M-13⑤：按 `AC-P10-08` 字面**；已核实二者均为 `_write` **全行 replace**，功能等价）。两分支均**保留原 `createdAt`**、仅推进 `updatedAt`（现有逻辑不动）。
- **保存成功**：`dataBus.dataChanged()` + `Navigator.pop()`（`:182-183` 不动）→ 上级页 `await push` 后 `_load()`。

### 11.4 P10 其余收口点（保持既有正确性）

- 金额 `≤ 0`/空 → 内联红字 + 禁存（`_validateAmount` `:132-139`）——现有已满足（AC-P10-03）。
- 不接受负号：`yuanToFen` 会解析负号（`money.dart:35-40`）→ 在本页 `_validateAmount` 已 `fen <= 0` 拦截；保持。
- 无公司 → `_companyError` 拦截（`:154-161`，AC-P10-05）。
- 保存失败 → SnackBar + 保留输入（`:184-190`，AC-P10-07）。
- **M-13⑤ 写方法分流**：编辑分支 `updatePaymentRecord`（`:983`），新建分支 `upsertPaymentRecord`（`:890`）——**按 `AC-P10-08` 字面**。⚠️ **回流 R10**：`02 §D.14:842` 把写方法行号错标为 `:913`/`:927-930`（实为 `listPaymentRecords`/`listPaymentRecordsOn` 的行）→ **生产以真实值 `:890` / `:983` 为准**，错标入阶段⑤ 回流。

---

## §12 共享件：`receivable_status.dart`

```dart
// lib/ui/widgets/receivable_status.dart
/// PRD §5.2（整数严格等号）
String receivableStatusLabel(int receivable, int received) {
  if (receivable == 0 && received == 0) return '未开工';
  if (receivable > 0 && received == 0) return '未收';
  if (received > 0 && received < receivable) return '部分收款';
  if (received == receivable) return '已结清';       // 严格等号
  return '多收·待核对';                              // received > receivable
}
```
- `ReceivableStatusChip`：Chip 样式（颜色按 label 分档）。
- `CompanyFlagChips(company)`：`enabled == false` → 灰「已停用」；`deletedAt != null` → 灰「已删除」。
- **单测**：5 态边界（`0/0`、`>0/0`、`0<recv<recv`、`recv==recv`、`recv>recv`）纯 Dart 可跑。

---

## §13 设计中发现的需求问题（**如实上报，不自行绕过**）

> 下列各项为**读代码 + 交叉核对冻结件**时发现的冲突/缺口。
> **★ 全部已由主理人裁定（见同目录 `11-主理人裁定（WaveA设计）.md`）**；本表已按裁定**回填为定论**，`11` 号文 §1/§2 为最终依据。**表内一律为定论、无未决措辞**。
> **阶段⑤ 双回流登记清单（R1~R10）见 `11` 号文 §4**，本设计**不改** `00/01/02/03~08`。

| # | 问题 | 冲突双方 | 本设计的处置（**已定论**） | 裁定状态 |
|---|------|---------|---------------------------|---------|
| **Q-D1** | **死路由处置与"不动路由"冲突** | `§C.2.3` 要求 `Routes.records`（`routes.dart:14` + `main.dart:55-57`）在 4 Tab 后必须被删除或重定义；`§A.3` 补口径 1 + 硬约束 5 又**禁止 Wave A 动 `routes.dart`/`onGenerateRoute`** | ✅ **采纳"顺延"**。Wave A **不动**路由；`Routes.records` + `main.dart` 的 case + `Routes.overview`（理论上**从未注册**，`'/'` 由 `home:` 承接）**一律顺延 Wave A2 清理**（`Routes.records` 与 `Routes.overview` 写入 A2 交付清单；**A2 未清理前不得宣告"路由已收口"**）。**v2 追加（M-2）**：**`Routes.companies` 保留为"活路由"，A2/D2 均不得删** —— 凡目标为 P06 的跳转**一律 `pushNamed(Routes.companies)`**（P01「全部公司」、P01 空态主按钮、P07「编辑公司」），**不得改命令式**（其唯一调用点 `overview_page.dart:379`，改则新增死路由）。**A2 清理清单 = `Routes.records` + `Routes.overview`（仅此二项）** | **已裁定（见 `11` 号文）** |
| **Q-D2** | `RecordsPage` 的 `const` 兼容 | `main.dart:56` 构造 `const RecordsPage()`，且 Wave A 不得改 `onGenerateRoute` | 参数化**全部可选 + `const` 默认**（§4.3）。**若不遵守，`main.dart` 将编译失败**（R-1） | **已裁定（见 `11` 号文）** · 施工硬要求 |
| **Q-D3** | **P07/P01 的 P08 出口在 Wave A 无落地页** | `07:456`/`07:228` 要求 `编辑公司` / 空态「先建公司」→ **P08**；但 P08 收口属 **Wave D1**（`§A.3`），Wave A 无真实 P08 页（现存仅是 `company_page.dart` 内嵌对话框） | ✅ **采纳"临时降级"**：Wave A 目标为 **P06**、且**统一用 `Navigator.pushNamed(context, Routes.companies)`（M-2）**，并加**可 grep 的注释标记 `// 临时(D1)`**；Wave D1 交付 P08 后替换为真实跳转（替换登记 = 回流 R6；阶段⑤ 一致性审查核对是否已全部替换） | **已裁定（见 `11` 号文）** |
| **Q-D4** | 规则区块的**查询参数**与 `AC-P07-07a` 字面 | `AC-P07-07a` 字面写 `listPricingRules({companyId, includeDisabled: true})`（**未写** `includeDeleted`，其默认 `false`）；若 `includeDeleted:false`，历史工作记录引用的**已归档规则**名会显示不出（真实 UX 缺陷） | ✅ **采纳"一次查全"**：`listPricingRules(companyId: cid, includeDisabled: true, **includeDeleted: true**)`，Dart 侧滤 `!isDeleted` 作展示集（**可见集 ≡ `includeDeleted:false`**），全量集另作 `ruleNameById` 溯源兜底。**与 AC 字面的差异已在 §5.6 显式标注**（省 1 读 + 溯源必需），入**回流 R4** | **已裁定（见 `11` 号文）** |
| **Q-D5** | **07 要求但 `§D.1` 未立 AC** 的 P01 卡片小字 | `07:223-224` 要求每卡显示「最近收款时间 / 已 X 天未收款 / 从未收款」；`§D.1` 的 AC-P01-01~14 **无对应条目** | ✅ **照 `07` 实现**（一次全量 `listPaymentRecords()` + UI 分组，**禁逐卡查询**）；**同源被遗漏的 `07:241`「还没记过账」一并实现**（§6.3，零额外读）。登记为"有文字要求、无 AC"的覆盖缺口 → **回流 R2/R7**（补 `AC-P01-15` 或等价）；**AC 补登前验收走"人工核 + §15 落点追溯"**，不得因无 AC 略过 | **已裁定（见 `11` 号文）** |
| **Q-D6** | `07:242`「有 N 条草稿未完成」的实现成本 | `07:242` 要求有草稿的卡片显示该小字；数据层**无**按公司聚合草稿的方法，且 `§E-6` **禁止新增 DB 方法** | ✅ **Wave A 不做该小字**。**成本基线（M-1/M-15，必须标明）**：以**今日**为基线（`overview_page.dart:57` 现状**已全量读含草稿**的 `listWorkRecords()`）→ 边际成本 **+0**；以**本设计的 4 读方案**为基线 → 边际成本 **+1 全表读**。**未来补做的两条路径都不廉价**：**全表读**（`listWorkRecords(includeDraft:true)` + UI 计数）**或 N+1**（逐公司 `listWorkRecords({companyId, ...})`，该参数确支持按公司过滤，`database.dart:619-633`）。不做理由：① `§D.1` 无 AC；② 触发条件罕见；③ 完整实现含"小字可点 → P07 草稿筛选"的**跨页契约变更**，与 U-4「每波一个包」冲突。**卡片其余元素照 07 实现**；登记 → **回流 E-12（R1）** | **已裁定（见 `11` 号文）** |
| **Q-D7** | P01 既有 `_StatsLine` 的处理 | `_StatsLine`（`overview_page.dart:256-276`）**不在 07 P01 控件清单**内；其 `_workCount`（`:36`/`:64`）**唯一**服务于它，且依赖一次全表 `listWorkRecords()` | ✅ **定论移除**：删 `class _StatsLine`（`:256-276`）+ 调用（`:138-142`）+ 字段 `_workCount`（`:36`）+ 赋值（`:64`）。`07` 全文无此控件、`_workCount` 无第二消费者 → **不破坏任何既有功能**，且省一次全表读。**交付说明登记"移除既有行为"** | **已裁定（见 `11` 号文）** |
| **Q-D8** | **AC-24 在编辑态的阈值口径未定义** | `AC-P10-01` 只说"输入金额 > 该公司当前剩余"；但编辑态 `aggregate(cid).remaining` **已把本条原金额计入已收**，直接比较会对"持平编辑"误判 | ✅ **采纳补定义 + 补一条边界**：新建 `T = remaining`；编辑且 `companyId` **未变** → `T = remaining + 原金额`（化简后弹窗条件 ⟺ 编辑后剩余 `<0`，与新建同构）；编辑且 `companyId` **变更** → `old = 0`，**必须对目标公司重新 `aggregate(目标公司)`**（不得复用旧公司 `remaining`），`T = remaining(目标公司)`；并对**原公司**做"移出后是否变多收"的一次性提示（§11.3，非 N+1）。入**回流 R3** | **已裁定（见 `11` 号文）** |
| **Q-D9** | 移除「仅计应收」chip 后与 `AC-P01-04`「不含草稿」的关系 | `§C.1.3`（`02:195`）允许「仅计应收」chip 可删除（→含草稿）；`AC-P01-04` 要求应收下钻**不含草稿** | ✅ **采纳设计处置**：**初始态** `includeDraft:false`（满足 AC-P01-04）；用户主动移除 chip 后 `includeDraft:true`，草稿行以 `—` 显示（`07:340`）且**不参与求和**，顶部合计仍取 `aggregate(null).receivable`（**口径不变**）；chip 文案改「含草稿（不计数）」，样式与同页其它 chip 统一。**★ 必须写明的验收边界（否则阶段④ 会误判不通过）**：`AC-P01-04` 的「顶部合计 == Σ列表」断言**仅在初始态（chip 未移除）成立**；移除 chip 后列表含草稿行、该断言**不再适用** | **已裁定（见 `11` 号文）** |
| **Q-D10** | P-DEBT「多收核对」视图的实现方式 | `§C.1.3` 说"点开**同一列表的「多收」筛选视图**"，未定义是同一页切换还是新页 | ✅ 用**同页本地 toggle**（`_showAll`），**页内保留、跨次不记忆**（满足 AC-PDBT-08）；**禁**落全局状态。行集 = `remaining < 0`（见 §7.4，M-13④） | **已裁定（见 `11` 号文）** |
| **Q-D11** | P01 卡片区为**从零新增** | `02` 措辞多处假设"公司卡片"已存在（如 `§D.1` 复核结论"缺公司卡片列表"实为**完全没有**） | 设计按"从零新建 `_CompanyCardSection`"处理（§6.3）；**施工时不得按"改造既有卡片"理解** | **已裁定（见 `11` 号文）** · 事实澄清 |

### 13.1 主理人独立核实新增项（N-D1~N-D7）落点

| # | 新增项 | 本设计的落点 |
|---|-------|-------------|
| **N-D1** | `overview_page.dart:1-4` 文件头注释失实 | 已写入施工清单：§3.2（overview 行 ⑧）+ §3.4 + §6.1（"文件头注释同步"） |
| **N-D2** | Q-D6 成本表述未标基线 | 已在 Q-D6 行补 "+0 vs 今日 / +1 vs 本设计 4 读方案" |
| **N-D3** | 编辑态改公司时 `T` 须按目标公司重算 | 已在 §11.3 写死三支分支 + 原公司一次性提示 |
| **N-D4** | `§14.1 R-4` 误把既有行为当成新增风险 | 已订正（见 §14.1 R-4） |
| **N-D5** | 删除清单用行号定位易漂移 | 已加 §3.4「符号名优先 + `grep` 残留自检」 |
| **N-D6** | P01 查询数 4 + 串行改并发 | 已写入 §6.4 尾条 + §15 覆盖说明 |
| **N-D7** | `Routes.records` 顺延后 `/records` 命名路由仍可打开无过滤记录页 | 可接受（无入口指向它）；**A2 清理时必须一并处理**（常量 + `main.dart` case 同批，不得只删其一）——见 Q-D1 与回流 R5 |

### 13.2 阶段⑤ 双回流 · 顺延登记 / 无须落笔 / 已知限制（R8 / R25 / R26 / R27 / R28 / R31 / R44 / R63）

> 本节为 `19-回流总台账` 阶段⑤ 双回流项在 `09` 侧的**统一登记位**。`app/**` 自 Wave D2 收口后**已冻结**，本波**只改文档、不改码**（逐条理由见下）；顺延项统一标「**未排期**」。
>
> **★ 补登记说明（`2026-10-13` · 阶段⑤ 收官批，主理人裁定；**同批复核后订正一次**）**：**R8** 与 **R44** 原未列入本节（均属「零改动闭合」类）。**二者缺口性质不同，不可并称**：
>
> - **R44** —— 裁定单 §2.1 的**落点列明列 `09`/`19`**，但 §3 三组任务清单**均未派发** ⇒ 本节补登记，**闭合分派缺口**（R44 定性 = 「**已具备**」，**非** `09` 侧应新增代码改动）。
> - **R8** —— 裁定单 §2.1 的**落点列为「—」**，且**明写「不另开登记行」**；其「无须落笔 + 依据」此前**只在 `19 §1` 本行备注留痕** ⇒ 本节补一行，**补齐统一登记位**。**口径澄清（消除表面矛盾）**：§2.1 的「**不另开登记行**」= **不在 `02 §E` 另开回流登记行**（R8 的上游登记已由 `R32 扩写` 承担）；与本处 **`09 §13.2` 统一登记位留痕**属**不同层级**，二者**不矛盾**（后置 §5.2 的 E2 裁定已授权本行）。
>
> ~~裁定单 §2.1 曾把二者落点列为 `09`，但 §3 三组任务清单均未派发~~ **（原文（已过时，保留可溯）：上句对 `R8` 失实 —— §2.1 的 R8 落点为「—」、非 `09`；`2026-10-13` 复核官 `phase5-efix` 报出 F1 后订正。）**

- **无须落笔（R8）**：`02 §E` 侧**不新增登记行** —— P01 `+ 记一笔` 的 **FAB 形态**（`07:226`）已由 **Wave D2 交付**；其上游登记已由 **R32 扩写**（`02 §A.3` Wave D2 行）承担。依据 = 裁定单 §2.1 R8（原备注：并入 R1；源自 `11 §5.2 O-3`）。本波**零改动**。
- **顺延登记（R25）**：`overview_page.dart` 的 `catch` 分支未重置 `_degraded`（状态卫生）；顺延依据 = `11 §10.4`；**未排期**；**理由 = `app/**` 自 Wave D2 收口后冻结（`gen_kernel rc=0` + 10 个 `verify_*.dart` **590/0** 全绿），改动会作废该基线，而出包验收在即**（`_buildBody` 中 `_error` 优先于 `_degraded` ⇒ 无可达缺陷）。
- **无须落笔（R26）**：`company_page.dart` 注释「或计数为 0」—— 代码**已自然满足**（注释已含「① 计数抛异常；② 计数成功但工作与收款都为 0」两种退回情形），本波**零改动**。
- **无须落笔（R27）**：`company_detail_page.dart` 注释「仅 `_onExportGuide` 文案三页一致」—— 所述为**事实描述**（注释已逐字写明「文案与 P-DEBT `_onExportGuide` 逐字一致，保持三页一致」），**非缺陷**，本波**零改动**。
- **顺延登记（R28）**：`company_detail_page.dart` 顶层非滚动 `Column`（含告警条 +60px）的溢出防护；顺延依据 = `11 §10.4` / `§9.7`；**未排期**；**理由 = `app/**` 自 Wave D2 收口后冻结（`gen_kernel rc=0` + 10 个 `verify_*.dart` **590/0** 全绿），改动会作废该基线，而出包验收在即**（`Column→ListView` 会改 P07 结构，与 `AC-P07-07c`「不得返工 P07 结构」冲突）。
- **顺延登记（R31）+ `P-DEBT`**：代码注释口径统一（旧称「总览 / 明细」→「看板 / 日历 / 统计 / 设置」，**仅注释、零行为**）；顺延依据 = `18 §5 MIN-03`；**未排期**；**理由 = `app/**` 自 Wave D2 收口后冻结（`gen_kernel rc=0` + 10 个 `verify_*.dart` **590/0** 全绿），改动会作废该基线，而出包验收在即**。**`P-DEBT`**：后续可**一次性统一**（仅注释，零用户可见价值）。
- **已具备（R44，代码侧）**：`app/tool/verify_waveC1.dart` **已有独立静态断言层 `S1~S12`**（报告原文 = `review-c1 §5 R41` + `§7.3 S1~S10`；收口轮 `14 v1.2` 起具备）⇒ 本项以「**代码已具备**」闭合，**不另改脚本**。**`app/**` 不改**（理由同下：`app/**` 冻结，改动会作废 `gen_kernel rc=0` + 10 个 `verify_*.dart` **590/0** 基线）。依据 = 裁定单 §2.1 R44。
- **本版不改（R63）**：P12a 倍率控件只读化（R63）为**可选优化、本版不改**；`HolidayMark.rate` 已由 **R48** 明确**不参与金额计算、仅预填展示**（`03 §2.6` / `§4.6`），故上述张力**已由文档消除**。

---

## §14 风险与施工顺序

### 14.1 风险清单

| # | 风险 | 影响面 | 缓解 / 自检 |
|---|------|-------|-------------|
| **R-1** | **`RecordsPage` 构造签名变更 → `main.dart:56` 编译失败** | 全 App 起不来（最高危） | 参数**全可选 + `const` 默认**（Q-D2）；施工后先跑 `gen_kernel` 类型编译通道（`§D.0.1`）再谈其它 |
| **R-2** | 删 `_RecentSection`（U-2 现场）后**用户暂时看不到"最近记录"** | P01 UX | 「查看全部」承接（`AC-P01-09` 即为此）；验收须真机确认「查看全部 → 全量不截断」 |
| **R-3** | P06 行点击语义改变（编辑对话框 → P07），**编辑入口变隐蔽**（只剩长按/⋯菜单） | P06 UX | 行尾加**可见的「⋯」菜单**（含编辑/停用/删除），降低可发现性损失；验收真机确认三入口均可达 |
| **R-4** | `listPaymentRecords()` 全量读（`overview_page.dart:58`） | 大表（≥200 行）启动读 | **N-D4 订正：这是既有行为（`overview_page.dart:58` 今日已全量读），非本波新增**；本波仅将其与另三读由**串行改并发**（N-D6）。量级 `§D.0.3` 可接受；`ListView.builder`；如实测卡顿，登记为"可丢弃可重建缓存"（`§C.1.1` 补充允许缓存，但**不得改分页语义**） |
| **R-5** | 状态角标判定与 PRD §5.2 不一致 | 多页一致性（AC-33） | 唯一实现 `receivableStatusLabel`（`receivable_status.dart`）+ 纯 Dart 单测 5 态边界 |
| **R-6** | `includeDeleted: true` 让已归档公司出现在 P01/P06/P-DEBT | 空态判据与列表长度 | 空态判据改 `_companies.isEmpty`；"有账必列"（AC-19/AC-20）正是要求如此；与 `07 §4.1 D3 ④` 的偏差**以 `02 AC-P06-06`「不自作折叠」为准**并登记（m13 → 回流 R9） |
| **R-7** | `_compareBase()` 口径（Q-D8，已定论） | P10 误判风险 | 已隔离为 `_compareBase()` 单函数，含**编辑态改公司**分支（§11.3，M-12）；改口径只动一处 |
| **R-8** | P07 内嵌 `RecordListView` 与 P07 自身 `_load()` 双通道刷新（dataBus + 显式） | 短暂重复加载 | 二者幂等（只读）；`_load()` 内 `if (!mounted) return;` 防悬挂；不做"防抖"以免引入状态管理 |
| **R-9** | 规则区块的 `ruleNameById` 使用 `includeDeleted: true`（Q-D4，已定论） | 与 AC-P07-07a 字面 | 展示列表已滤 `!isDeleted`（**可见集等价**）；差异已在 §5.6 标注并入回流 R4 |
| **R-10** | `// 临时(D1)` 标记位（P01 空态按钮、P07 编辑公司）未按期替换 | Wave D1 遗漏回收 | 标记**必须可 grep**（`grep -n "临时(D1)"`）；阶段⑤ 一致性审查核对 Wave D1 是否已全部替换（回流 R6） |
| **R-11** | P01 删除后**文件头注释未同步**（N-D1） | 阶段⑤ 一致性审查必扣项 | §3.4 + §6.1 已列为施工清单必做项；自检 `grep` 文件头"最近 5 条/统计行"应为 0 |

### 14.2 施工顺序（哪些可并行、哪些有先后依赖）

```
Step 0（先决·共享件与接口）── 目标为"把三处下钻/列表/角标的共同依赖先定接口"
  S0-a  records_filter.dart（RecordsFilter）
  S0-b  receivable_status.dart（状态角标/标志角标 + 单测）
  S0-c  record_list_view.dart（RecordListView + 行组件；依赖 S0-a/S0-b）
  S0-d  company_detail_page.dart 的【骨架】（类 + 构造 + 空 _openRuleEditor）
        ↑ 仅先落"类名与构造"，让 P01/P06/P-DEBT 能引用，避免循环等待
  ── 关口：gen_kernel 类型编译通过（S0 全绿再分流）

Step 1（可并行，5 条线）── 各自独立、互不写同一文件
  线 L1  overview_page.dart（依赖 S0-a/b/c/d）
  线 L2  company_detail_page.dart 全量（依赖 S0-a/b/c；S0-d 已占位；**还依赖 L4′**）
  线 L3  debt_list_page.dart（依赖 S0-b/d）
  线 L4′ payment_form_page.dart + work_form_page.dart（**P10 收口 + T-1 参数一次改完**，
        同一线内串行；不引用任何新件 → **可与 Step 0 并行**；但须**早于 L2**，
        因 P07 调用 `PaymentFormPage(companyId:)` 与 `WorkFormPage(companyId:)`）
  线 L5  company_page.dart（依赖 S0-b/d）

Step 2（串行·收口）—— 依赖 Step 1 全部完成
  S2-a  overview_page 的三处下钻 + 两个入口接线（需 S1 目标页类已存在）
  S2-b  company_page 行点击改 push P07
  S2-c  P07 的 `+ 记一笔`/`记一笔收款`/`编辑公司` 接线
  S2-d  P-DEBT 行点击接 push P07（若 S0-d 骨架已足够可提前到 S1）

Step 3（验证）—— 见 §14.3
```

**并行边界（写死，防冲突）**：
- **每个文件同一时刻只有一条线在改**（`overview_page.dart` 只属 L1；`company_page.dart` 只属 L5；**`payment_form_page.dart` / `work_form_page.dart` 归并入 L4′**——原 L4 与 L6 同改 `payment_form_page.dart` 的写冲突已消除，M-9）。
- **Step 0 是"先定接口"的先决，但不是全流程唯一先决**：`RecordsFilter`/`ReceivableStatusChip`/`RecordListView` 是三处下钻与 P06/P07/P-DEBT 的共同依赖，先定接口可避免"各写一版、事后统一"的返工。
- **`L4′` 与 Step 0 可并行**（不引用任何新件）；**但 `L4′` 须早于 L2 完成**（P07 调用 `PaymentFormPage(companyId:)` / `WorkFormPage(companyId:)`）。建议 `L4′` 与 Step 0 同批启动。

### 14.3 验证关口（每步/收尾）

| 关口 | 手段 | 对应 AC |
|------|------|--------|
| 类型编译 | `gen_kernel` 通道（`§D.0.1`，`check_flutter.sh` 不存在，`§E-7`） | 全 Wave A（R-1 必过） |
| 纯 Dart 单测（`set WORKLOG_USE_SYSTEM_SQLITE=1` + `dart.exe --disable-dart-dev tool\verify_db.dart` 风格） | ① 状态角标 5 态；② `aggregate(null).remaining == Σ aggregateByCompany().remaining`；③ `Σ listWorkRecords(includeDraft:false).amountSnapshot == aggregate(null).receivable`；④ `Σ listPaymentRecords().amount == aggregate(null).received`；⑤ **P-DEBT 恒等式** `欠款合计 − \|多收合计\| == aggregate(null).remaining`；⑥ P01 `剩余 == Σ 卡片剩余` | AC-P01-13 / AC-PDBT-05 / `§C.1.4` 等价关系 |
| 静态走查 | 逐条核对 §15 的 AC → 落点 | `§D.0.2` 九条禁令（UI 无 SQL / 无浮点 / 裸调 `listCompanies()` 归零 / 枚举走 `EnumCodec` / 写入后广播） |
| **真机验收（U-4 闸门，不可省）** | 出包后人工：**点公司卡片看明细、点三个金额看对应列表、公司列表与明细不再截断 5 条** | AC-P01-03/04/05/06/14、AC-P06-01/02/03、AC-P07-01~07a/c、AC-PDBT-01~06、AC-P10-01/02、AC-P01-10 |

---

## §15 验收条目 → 施工落点（可追溯表）

> 供 Reviewer 逐条核（`§D.0` 要求每条 AC 有 `[静态]`/`[单测]`/`[真机]` 证据）。

| AC | 一句话 | 落点（文件:构造/方法） |
|----|--------|----------------------|
| AC-P01-01 | 三家公司卡片全出现（含停用/归档）+ 灰角标 | `overview_page.dart` → `_CompanyCardSection` + `CompanyFlagChips` |
| AC-P01-02 | 全局剩余 == `aggregate(null).remaining`；负值前缀「多收」 | `overview_page.dart:169-203`（保留）+ §6.2 |
| AC-P01-03 | 点剩余 → P-DEBT（`remaining>0` 倒序） | `_RemainingCard.onTap` → `CompanyDebtListPage` |
| AC-P01-04 | 点应收 → 工作列表（**不含草稿**）合计 == `aggregate(null).receivable` | `RecordsFilter.receivableDrill` + `RecordsPage(showAggregateHeader:true)` |
| AC-P01-05 | 点已收 → 收款列表 合计 == `aggregate(null).received` | `RecordsFilter.receivedDrill` + 同上 |
| AC-P01-06 | 点公司卡片 → P07 | `_CompanyCardSection` 卡片 onTap |
| AC-P01-07 | 唯一公司停用后不落"无公司"空态 | `listCompanies(includeDisabled:true, includeDeleted:true)` + `_companies.isEmpty` 判据 |
| AC-P01-08 | 「全部公司」→ P06 | `_CompanyCardSection` 尾入口 |
| AC-P01-09 | 「查看全部」→ 参数化列表（双 tab 全量不截断） | `RecordsPage(filter: RecordsFilter.all)` |
| AC-P01-10 | 「最近 5 条」已移除 | 删 `overview_page.dart:154-167/278-333`/`_buildRecent`/`take(5)` |
| AC-P01-11 | 空态文案 == `07:240` + → P08 | `_EmptyView` 文案改『先建一个公司』；出口**沿用 `pushNamed(Routes.companies)`** + `// 临时(D1)`（Q-D3 / M-2） |
| AC-P01-12 | 子页返回 P01 无条件 `_reload()` | §10.2 |
| AC-P01-13 | 开发期断言 剩余 == Σ 卡片剩余 | §6.4 assert（`[单测]`） |
| AC-P01-14 | 真机可感知项 | §14.3 真机闸门 |
| AC-PDBT-01 | 仅 `remaining>0`；行内「应收−已收=剩余」 | `debt_list_page.dart` 行组件 |
| AC-PDBT-02 | `remaining` 倒序 | §7.3 `sort` |
| AC-PDBT-03 | 公司名映射必须双 true；禁裸调 | §7.2 q2 |
| AC-PDBT-04 | 行点击 → P07 | §8 表 |
| AC-PDBT-05 | 欠款合计 = Σ 列表内 remaining + 恒等式断言 | §7.3 |
| AC-PDBT-06 | 空态「太好了，没有公司欠你钱」+ 多收提示行 | §7.4 |
| AC-PDBT-07 | 聚合坏值降级不白屏 | §7.4 错误态 |
| AC-PDBT-08 | 返回 P01 + P01 `_reload()` + 筛选不记忆 | §10 + `_showAll` 实例态 |
| AC-PDBT-09 | ≥100 惰性构建 | `ListView.builder` |
| AC-PDBT-10 | 0/1/全多收/停用仍欠款 边界 | §7.3/§7.4 |
| AC-P07-01 | 剩余大字 == `aggregate(cid).remaining`；负 → 「多收·待核对」 | `company_detail_page.dart` 头部（S0-d/L2） |
| AC-P07-02 | 应收/已收 == 聚合；与 P01 一致 | 同上（同 `aggregate`） |
| AC-P07-03 | 两 tab 全量不截断 | §5.4 |
| AC-P07-04 | 工作行点击 → P05（**临时** `WorkFormPage(id:)`） | §5.3 注入 `onTapWork` |
| AC-P07-05 | 收款行点击 → P10 编辑态 | `PaymentFormPage(id:)` |
| AC-P07-06 | 「记一笔收款」→ P10（预置公司，**不标临时**） | `PaymentFormPage(companyId:)` |
| AC-P07-07a | **规则列表**（名/方式/单价/启用，含停用） | §5.6（Wave A 只读渲染） |
| AC-P07-07b | 「新建规则」→ P09（Wave D1 验收） | `_openRuleEditor()` 注入点 |
| AC-P07-07c | Wave A 只读 + 跳转；**D1 不返工结构** | §5.6 唯一注入点 |
| AC-P07-08 | 停用横幅 + 重新启用 | §5.3（`updateCompany(整对象)` + `// 临时(D1)` 标记不涉；M-13① 逐字段构造） |
| AC-P07-09 | 已归档横幅 + 账目仍计入剩余 | §5.3（`deletedAt != null`） |
| AC-P07-10 | 三种空态（`07:464-466`） | §5.4 空态注入 |
| AC-P07-11 | P01 卡片剩余 == P07 剩余 == 聚合 | §6.4 + §5.3（同 `aggregate`） |
| AC-P07-12 | 「+ 记一笔」→ 预置公司（**临时** T-1） | `WorkFormPage(companyId:)` |
| AC-P10-01 | AC-24 严格 `>` 二次确认（`==` 不弹） | §11.3 |
| AC-P10-02 | 实时剩余提示（X / Y 全情形文案） | §11.2 |
| AC-P10-03 | 金额 ≤0/空 → 内联红字 + 禁存 | `_validateAmount`（既有，保持） |
| AC-P10-04 | 应收为 0 收款 → 走 AC-24 + 专用文案 | §11.3 `noWork` 分支 |
| AC-P10-05 | 无公司 → 阻止保存 | `_companyError`（既有） |
| AC-P10-06 | 保存成功 → 返回 + 上级 `_reload()` + 广播 | `payment_form_page.dart:182-183`（既有）+ §10 |
| AC-P10-07 | 保存失败 → SnackBar + 保留输入 | `:184-190`（既有） |
| AC-P10-08 | 编辑态删除 + **`updatePaymentRecord`**（编辑分支按字面） | `:193-229`（删除既有）/ **`:983` `updatePaymentRecord`**（M-13⑤）；新建分支仍 `:890` `upsertPaymentRecord` |
| AC-P10-09 | 收款列表 ≥200 惰性 | `RecordListView` |
| AC-P06-01 | 行点击 → P07（改） | `company_page.dart:293` → `_openDetail(c)` |
| AC-P06-02 | 行内金额（`aggregateByCompany()`，未出现按全 0） | §9.1/§9.2 |
| AC-P06-03 | 状态角标（启用/停用/已删除） | §9.2 `CompanyFlagChips`（需 `includeDeleted:true`） |
| AC-P06-04 | 编辑/停用/删除（行内菜单或长按） | §9.2「⋯」菜单 + 既有 `_onLongPress` |
| AC-P06-05 | 「新建公司」→ P08 | 既有 FAB → 对话框（P08 真页在 D1） |
| AC-P06-06 | 空态 + 全部剩余 0 正常显示 | `_companies.isEmpty` + 不折叠 |
| AC-P06-07 | P01「全部公司」入边（Wave A 范围） | §6.3 尾入口 |
| AC-P06-08 | 与 P01 卡片数字一致（同 `aggregateByCompany()`） | §6.4 / §9.1 |

### 15.1 有文字要求、但 `§D.1`/`§D.6` 无 AC 的条目（**不得因无 AC 略过**）

| 来源 | 要求原文 | 本设计落点 | 回流 |
|------|---------|-----------|------|
| `07:241` / `02 §D.1:361` / `07 §4.1 D3 ③` | 有公司但全 0 → **每卡显示「还没记过账」** | §6.3 卡片元素表（`receivable==0 && received==0`，**零额外读**） | **R2 / R7** |
| `07:223-224` | 每卡「最近收款时间 / 已 X 天未收款 / 从未收款」 | §6.3（q4 全量 + UI 分组） | **R2**（补 `AC-P01-15`） |
| `07:466` / `02 §D.6:565` | P07 第 3 种空态「还没开始记账」 | §5.4（`AC-P07-10` 已覆盖，此处补充落点） | R2 同批 |
| `07:242` | 有草稿的卡片「有 N 条草稿未完成」 | **Wave A 不做**（Q-D6 定论） | **R1（E-12）** |
| `07:226` | P01 `+ 记一笔` 为 **FAB** | Wave A 保留两个 `FilledButton`（临时），FAB 推 Wave D2 | **R8** |

### 15.2 N-D6 性能改善（如实写入交付说明）

P01 由**现状的串行 4 次 `await`**（`overview_page.dart:53-58`）改为 **`Future.wait` 并发 4 次**；其中 `listPaymentRecords()` 是**既有行为**（`overview_page.dart:58` 今日已全量读），**非本波新增**（N-D4）。

---

## §16 交付自检（施工者对照）

- [ ] `pubspec.yaml` **零改动**；`database.dart` / `database_schema.dart` / `receivable_service.dart` / `routes.dart` / `main.dart` **零改动**。
- [ ] `RecordsPage` 仍可 `const RecordsPage()` 构造（`main.dart:56` 编译通过）。
- [ ] **`Routes.companies` 仍是"活路由"**：全工程仍有调用点（`grep -n "Routes.companies"` 命中 `main.dart`（注册）+ 至少一处 `pushNamed`）；**Wave A 后不得为零调用**（M-2）。
- [ ] **历史展示页**全工程 **无 `listCompanies()` 裸调**（`grep "listCompanies()"` 在 P01/P06/P07/P-DEBT/RecordsPage 归零）；`work_form_page.dart:122/157`、`payment_form_page.dart:84` 的裸调属**新建选择器**场景（"仅启用公司"是**正确**语义），**保留不动**。
- [ ] 金额路径**无 `double`**（`grep` 无 `fen / 100`、`double.parse(...) * 100`）。
- [ ] 枚举文案全走 `EnumCodec.*`（无硬编码中文枚举）。
- [ ] 每次写库后 `dataBus.dataChanged()`；每个 push 点 `await` 后 `_load()`。
- [ ] P-DEBT 恒等式断言存在且单测通过。
- [ ] P07 规则区块结构完整，`_openRuleEditor` 是**唯一** D1 注入点，其 D1 替换体含 `await ... ; if (mounted) _load();`（M-11②）。
- [ ] **`overview_page.dart` 删除项残留自检（N-D5）**：`grep` 以下符号 **0 命中**：`_RecentSection`/`_RecentRow`/`_RecentEntry`/`_buildRecent`/`_recent`/`_StatsLine`/`_workCount`。
- [ ] **文件头注释已同步（N-D1 / R-11）**：`overview_page.dart` 头部**不再**含"统计行 / 最近 5 条"（`grep` 0 命中），改为描述「公司卡片区 / 查看全部」。
- [ ] ~~**`// 临时(D1)` 标记可 grep**（`grep -n "临时(D1)"` ≥1），且仅出现在 P01 空态按钮 / P07「编辑公司」两处。~~ **（原文已过时，保留可溯）** —— **★ 阶段⑤ 双回流 R13① 订正**：该标记**已在 Wave D2 全部清除**，**计数口径终值 = `grep -rn '临时(D1)' app/lib` 命中 = 0**（依据主理人裁定单 §1-F8 实跑；`09 §6.6`/`§6.7` 同口径）。
- [ ] **★ 阶段⑤ 双回流 R13③ / R6（替换登记）**：三处 `// 临时(D1)` 注释的**替换登记**已由 `20-WaveD2-实现设计.md §9.1-Q4(A)/Q6(A)` **授权并落地**（即 **R6** 的落点）。
- [ ] **P01 卡片元素齐全（M-10①）**：`grep -n "还没记过账"` ≥1（`07:241`）。
- [ ] **公司名统一（M-13③）**：~~`grep -n "shortName ?? company"` **0 命中**~~ **（该自检项已作废，旧字面保留可溯；作废理由见 §6.3.1）** —— **★ 阶段⑤ 双回流 R13② 订正**：改 `grep -n "displayName"` 在 **4 个 UI 文件**（`overview_page` / `company_page` / `company_detail_page` / `debt_list_page`）**命中 0**。
- [ ] `§13` 全部 11 项 + N-D1~N-D7 的处理**与 `11` 号文一致**；交付说明**引用 `11` 号文**（不再向评审提问）。
- [x] **Wave A2 清理登记（★ 阶段⑤ 双回流 R5）**：`Routes.records` / `Routes.overview` 常量与 `main.dart` 对应 `case` **已由 Wave A2 实际删除**（依据 `18 §6.2`）；本项**只补文书登记**（代码已删，勿再去找）。

---

## 附：本文引用核对说明

- 被引代码：`main.dart`（全量）、`routes.dart`、`data_bus.dart`、`receivable_service.dart`、`overview_page.dart`（全量）、`records_page.dart`（全量）、`company_page.dart`（全量）、`payment_form_page.dart`（全量）、`work_form_page.dart`（`:1-175`、`:390-420`）、`widgets/money.dart`、`models/*.dart`、`services/enum_codec.dart`、`db/database.dart`（聚合/列表/日期/规则段）、`db/database_schema.dart`（索引）——均**打开定位到被引行号**。
- 冻结件：`02-需求与验收.md`（`§A.3`/`§B Q21/Q22`/`§C.1`/`§C.2`/`§D.0`/`§D.1`/`§D.6`/`§D.12`/`§D.13`/`§D.14`/`§D.15`/`§E-6`）、`07-UI实现规格.md`（P01/P02/P06/P07/P09 段）、`02-PRD.md`（§5.2）、`03-技术可行性意见.md`（§3/§5 M-6）。
- 裁定件：`11-主理人裁定（WaveA设计）.md`（M-1~M-15 / N-D1~N-D7 / R1~R10）——本次修订**逐条落实**（见下变更记录）。
- **未修改任何代码文件、未修改 `00`/`01`/`02`/`03`~`08`/`10`/`11`**；本文件为唯一被改产物。

---

## 变更记录

| 日期 | 版本 | 说明 |
|------|------|------|
| 2026-10-05 | v1（草稿） | 首版：Wave A 六项实现设计（§0~§16），含 §13 十一项需求问题上报。 |
| 2026-10-06 | **v2（按 `11` 号文修订）** | 依 `11-主理人裁定（WaveA设计）.md` 的 **M-1~M-15 + N-D1~N-D7** 逐条回填：<br>· **M-1/M-15（Q-D6）**：补成本基线（+0 vs 今日 `overview_page.dart:57` 已全量读含草稿／+1 全表读 vs 本设计 4 读方案），改述为"**全表读 或 N+1**"（`listWorkRecords({companyId})` 支持按公司过滤），结论仍为**不做 + 回流 E-12**。<br>· **M-2/N-D4（R-4）**：`listPaymentRecords()` 订正为"**既有行为（`:58`），非本波新增**；本波仅改并发"。<br>· **M-2/M-10（路由/`07:241`）**：**凡目标为 P06 的跳转全部改回 `pushNamed(Routes.companies)`**（取消全部命令式 `CompanyPage` push）；`Routes.companies` **保留为活路由**、不列入 A2 清理（清理清单仅 `Routes.records` + `Routes.overview`）；卡片元素表补「**还没记过账**」（`07:241`，零额外读，回流 R2/R7）。<br>· **M-3/N-D1（Q-D7）**：`_StatsLine` **定论移除**（含 `_workCount`），并写入施工清单：同步更新 `overview_page.dart` 文件头注释。<br>· **M-4/M-12/N-D3（Q-D8）**：`_compareBase()` 补"**编辑态改公司**"分支（`old=0` + 对目标公司重取 `aggregate` + 原公司一次性提示）。<br>· **M-5（Q-D9）**：补验收边界——`AC-P01-04` 断言**仅初始态成立**。<br>· **M-6（Q-D4）**：标注与 `AC-P07-07a` 字面的差异及理由（回流 R4）。<br>· **M-7**：§13 表格"需谁裁定"→「**已裁定（见 `11` 号文）**」，删除全部未决措辞。<br>· **M-8**：逐处回填定论，保证内部一致。<br>· **M-9（§14.2）**：合并 `L4+L6 → L4′`（`payment_form_page.dart` + `work_form_page.dart` 一次改完），删除"Step 0 为唯一先决"的绝对表述。<br>· **M-11**：`§5.4` 补 P07 第 3 种页面级空态「还没开始记账」（`07:466`）；`_openRuleEditor` 的 D1 替换体补 `await ...; if (mounted) _load();`。<br>· **M-13（批量订正）**：`updateCompany(整对象·无 copyWith)` 注明；`:181-199`→`:180-199`；公司名统一 `company.displayName`；多收视图行集统一 `remaining < 0`；P10 编辑分支改 `updatePaymentRecord`（`:983`）；`RecordsPage` 默认标题回填 `'明细'`（与 Tab2 一致）。<br>· **M-14**：P07 查询数表述改为"q1~q3 首帧并发；q4/q5 由 `TabBarView` 子页按需发起"（保留"零 N+1"）。<br>· **N-D5/N-D6/N-D7**：删除项改"符号名优先 + `grep` 残留自检"；P01 4 读 + 串行改并发如实写入；`Routes.records` 清理须常量与 `main.dart` case 同批。<br>· 新增 **§13.1**（N 项落点）、**§15.1**（有文字要求无 AC 的条目）、**§15.2**（性能改善）；§16 自检扩充。 |
| 2026-10-13 | **v3（阶段⑤ 双回流 · C 组）** | 按主理人裁定单（`_scratch/phase5-exec/主理人裁定-档2档3.md §2 / §3 C 组`）逐条回填 `09` 侧：**R5**（§16 补 Wave A2 清理登记行：`Routes.records` / `Routes.overview` 常量与 `main.dart` case 已实际删除，依据 `18 §6.2`）；**R13 + R6**（§16 两处就地订正：`临时(D1)` 计数口径改「`grep -rn '临时(D1)' app/lib` 命中 = 0」；自检项 `grep "shortName ?? company"` 作废、改 `grep "displayName"` 四 UI 文件 0 命中；并补「三处注释替换登记已由 `20 §9.1-Q4(A)/Q6(A)` 授权并落地」）；**R19**（§9.2 登记已归档公司「停用/启用」菜单项不适用 + 本版不提供取消归档 + `P-DEBT`）；**R20**（§9.1 登记已知限制：滑动删除后角标重现→瞬时抖动，`AC-P06-03` 必然结果、非缺陷）；**R22**（§6.3 顺延登记：P01 卡片区 `ListView.builder` 惰性化）；**R23 / R24**（§7.4 顺延登记：三页降级条抽共享件 / 降级态「理想档」三页统一）；**R25 / R28**（新增 §13.2 顺延登记：`_degraded` 状态卫生 / 非滚动 `Column` 溢出防护）；**R26 / R27**（§13.2 无须落笔 + 理由）；**R31**（§13.2 顺延登记 + `P-DEBT`：注释旧称口径）；**R63**（§13.2 可选优化、本版不改、张力已由文档消除）。**只增不删**：订正处旧字面一律以「原文（已过时，保留可溯）」保留。未改 `app/**`、未改其它 `docs/**`。 |