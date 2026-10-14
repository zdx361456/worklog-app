---
title: Wave A（下钻闭环）实现设计 · 独立审查
date: 2026-10-05
role: 设计审查
结论: 有条件通过
---

# 10 · Wave A 实现设计 · 独立设计审查

> **审查对象**：同目录 `09-WaveA-实现设计.md`（`status: 草稿`）。
> **唯一需求依据**：同目录 `02-需求与验收.md`（`status: 已冻结`）。
> **审查纪律**：**逐条打开文件核验**，不采信设计自述。凡设计写「某文件:行号 是 X」者，均已打开该文件定位核对。
> **本次实际打开的文件**：`app/lib/main.dart`、`app/lib/app/routes.dart`、`app/lib/app/data_bus.dart`、`app/lib/ui/overview_page.dart`、`app/lib/ui/records_page.dart`、`app/lib/ui/company_page.dart`、`app/lib/ui/payment_form_page.dart`、`app/lib/ui/work_form_page.dart`、`app/lib/db/database.dart`（签名段/聚合段/列表段/日期段/row 段）、`app/lib/models/company.dart`、`app/lib/models/work_record.dart`、`app/lib/services/enum_codec.dart`、`app/lib/services/receivable_service.dart`、`app/lib/ui/widgets/money.dart`、`app/pubspec.yaml`；`docs/07-UI实现规格.md`（P01/P02/P04/P06/P07/P08/P09/P10 段 + §2/§4.1）、`docs/04-迭代/.../02-需求与验收.md`（§A/§B/§C/§D.0~D.15/§E）。

---

## 1. 逐项判定表（对照 team-lead 下发的 10 项必审）

| 编号 | 必审项 | 判定 | 我打开的位置（核验证据） | 说明 |
|------|--------|------|------------------------|------|
| **1** | Wave A 六项全覆盖 + `§15` AC→落点是否覆盖 `§D.1`/`§D.6`/`§D.13`/`§D.14` 每条 AC | **合格（AC 层）/ 需求文本层有遗漏** | `02` §D.1（`:365-384` 14 条）、§D.6（`:569-588` 14 条含 07a/b/c）、§D.12（`:789-802` 8 条）、§D.13（`:815-829` 10 条）、§D.14（`:845-859` 9 条）；`09` §15（`:952-1009`）逐行 | 六项齐全（§0 `:21-28`）；`§15` 对上述 5 段 **AC 无逐条遗漏**（我逐条对齐：P01 14/14、P07 14/14、P06 8/8、P-DEBT 10/10、P10 9/9）。**但需求文本层（无 AC 的文字要求）有遗漏** → 见 §2。 |
| **2** | 硬约束是否被违反（依赖 / DB 只读 / 禁浮点 / 命令式下钻 / 两条陷阱） | **大部分合格；发现 1 处新增死路由（M2）** | `pubspec.yaml:30-56`（依赖集合）；`database.dart:273/333/451/536/619/910/983/488/877/992`（签名逐条核对）；`routes.dart`、`main.dart:45-61`（路由）；`overview_page.dart:56/343/352/379`；`records_page.dart:68-70/211/239` | ①依赖：`pubspec.yaml` 仅 `flutter/cupertino_icons/sqflite/sqflite_common`(+dev)，设计未引新件 ✅。②DB 只读：设计调用的方法名/参数**全部真实存在**（详见 §3）✅。③禁浮点：全篇金额 `int`，无 `double` 参与金额 ✅。④下钻命令式：新增跳转均 `Navigator.push(MaterialPageRoute)`，`routes.dart`/`onGenerateRoute`/`_extractId` 未动 ✅。⑤陷阱1/陷阱2：**每一处**调用均落实（P01 §6.4 q3、P06 §9.1、P-DEBT §7.2 q2、RecordsPage §4.5-1、P07 §5.2 q2 全为双 true；`receivableDrill.includeDraft=false`）✅。**⑥不合格点**：设计把 P01 空态主按钮由 `pushNamed(Routes.companies)` 改为命令式 `push(const CompanyPage())`（`09` §6.7 `:571`、§8 `:647`），而 `Routes.companies` 的唯一调用点就是 `overview_page.dart:379` → 改后 `Routes.companies` 成为**新增死路由**（已注册 `main.dart:57`、零调用），与本设计 `Q-D1` 自设的「无定义了但永不调用的路由」判据冲突。**M2**。 |
| **3** | 参数化列表接口能否编译（`RecordsFilter` 必须 const 可构造） | **合格** | `main.dart:56`（`const RecordsPage()`）、`main.dart:190-194`（`static const List<Widget> _pages` 内 `RecordsPage()` 亦为 const 上下文）；`09` §4.2 `:156-206`、§4.3 `:212-224` | `main.dart:56` 确为 `const RecordsPage()`；`main.dart:192` 亦在 `const` 列表内。`RecordsFilter` 构造为 `const`、字段全 `final`、值域仅 enum/`String?`/`DateTime?`/`bool`；`static const RecordsFilter all` 为编译期常量 → 作为 `RecordsPage` 默认参数值合法。✅ 合规。 |
| **4** | 查询次数是否真的零 N+1，`Future.wait` 是否安全 | **合格（无 N+1）/ P07「全并发」表述存疑** | P01：`09` §6.4 `:539-551`；P07：§5.2 `:374-384`；P-DEBT：§7.2 `:589-595`；RecordsPage：§4.5 `:349-354` | 逐项核对用途：P01 q1 全局剩余(q1 权威) / q2 各公司金额 / q3 公司元数据 / q4 最近收款——均必要，无逐行查询 ✅；P-DEBT q1/q2/q3（q3 仅口径标注+恒等式）✅；P07 q1~q5 用途齐备、无遗漏依赖（公司名/状态/剩余/两列表/规则区块全覆盖）✅。`Future.wait` 内各查询互不依赖，并发安全 ✅。**存疑**：P07 声称「首帧 5 次全并发」，但 q4/q5 由 `TabBarView` 子页 `initState` 发起，而 `TabBarView`（`PageView` 语义）**默认只构建当前页** → q5 通常在切到「收款」tab 时才发起，并非首帧全并发。功能无碍（仍是零 N+1），但表述不准确。**m4**。 |
| **5** | P01 落点是否准确（删除符号/行号；公司卡片区是否从零新增） | **合格** | `overview_page.dart` 全量（`:38/79-103/102/126-128/131-150/138-142/144/154-167/169-203/205-230/232-254/256-276/278-307/309-333/340-356/362-388/378-382`） | 逐符号核对：`_RecentSection :278-307`✅、`_RecentRow :309-333`✅、`_RecentEntry :154-167`✅、`_buildRecent :79-103`（`take(5)` 在 `:102`）✅、`_recent :38`✅、调用点 `:144`✅、`_StatsLine :256-276`+调用 `:138-142`✅、三金额 `:169-203/:205-230/:232-254`✅。**「公司卡片区从零新增」属实**：`_load()` 仅取 `_companyCount`（`:56/:63`），`_buildBody()`（`:131-150`）无卡片 ✅。 |
| **6** | P10 算法（AC-24 严格 `>`；编辑态阈值） | **合格（阈值数学正确）/ 编辑态换公司有边界缺口** | `payment_form_page.dart:152-191/179/182-183/193-229/132-139/154-161/291-294/232-245`；`09` §11.1-11.3 `:713-838`；`07:543/546/558` | **严格 `>` 正确**（§11.3 `!(amountFen > t)`）。**编辑态 `T = remaining + old` 数学验算通过**：令 A=本次、old=原金额、R=当前 remaining（已含 old），编辑后剩余 = R + old − A → 弹窗条件 `A > R + old` ⟺ 编辑后剩余 `< 0`，与新建口径同构。**题设验算**：欠 1000、已收 400（R=600）、改 400→500：T=600+400=1000，A=500 不 >1000 → **不弹窗**（编辑后剩余 500，未超收）→ **正确**。改 1001 → T=1000、A=1001>1000 → 弹窗（编辑后 −1）→ 正确；改 1000 → 不弹（编辑后 0，符合 `==` 不弹）。✅ **缺口**：编辑态 `_lockCompany=false`（§11.1 仅新建预置才锁），若用户在编辑态**切换公司**，`_compareBase()` 的 `+ old` 会把「旧公司」的金额加到「新公司剩余」上 → 语义错位。**m6**。 |
| **7** | P07 计价规则区块是否让 Wave D1「只填充不返工」 | **基本合格（注入点够用）/ 补两处硬化** | `09` §5.6 `:431-463`；`07:457`（P07 规则入口「显示规则条数」）、`07:501-526`（P09 新建/编辑共用单条规则页）；`02` §A.3 契约（`:107`）、AC-P07-07a/b/c | 单一函数注入点 `_openRuleEditor({String? ruleId})` **足以承载 D1**：行点击与「新建」两个入口都归一到该函数；P09（`07:501` 单条规则页）自持 `A10/A4` 加载，P07 只需传 `companyId`(自持)+`ruleId`。**缺口**：① 替换体示例（`:453`）只写了 `Navigator.push`，**未含 `await` 后 `_load()`**（编辑规则返回后 P07 规则列表需刷新）；② 若 D1 需「停用/删除」后立即反映，亦依赖第①点。→ 属文档硬化，不构成返工。 |
| **8** | `§13` 十一项处置是否合理 | **见 §4（逐条）** | `09` §13 `:868-884`；`02`/`07` 对应段落 | 十一项**无一项「不合理」**；6 项「处置合理」、5 项「需主理人/评审裁定或补登记」。其中 **Q-D7 与 Q-D3 有更优解**（见 §4）。 |
| **9** | 风险与施工顺序（六线是否有写冲突） | **存疑（发现 1 处写冲突 + 1 处自相矛盾）** | `09` §14 `:888-935`；`03`（不涉）；文件归属见 `09` §0 `:30`/§3.2 `:88-96` | **M1（写冲突）**：L4 与 L6 **同时改 `payment_form_page.dart`**（L4=§3.2 第 4 行的 AC-24 收口；L6=§3.3 的 `companyId` 参数），违反本设计自订的「每个文件同一时刻只有一条线在改」（`:932-933`）。**m9**：§14.2 首行称「Step 0（串行·**唯一先决**，必须最先）」，同节末又称「L4/L6 可与 Step 0 并行」→ 自相矛盾。其余：Step0 内部依赖（S0-c 依赖 S0-a/b；S0-d 无依赖）正确；Step1 各线依赖声明正确；Step2 串行收口正确。 |
| **10** | 既有功能回归风险 | **大部分合格（有 2 处需登记）** | `overview_page.dart:102/278-333/56/126-128/362-388`；`records_page.dart:33-34/66-93`；`company_page.dart:63-80/293`；`main.dart:190-210`；`02` AC-P01-01/07/10、AC-P06-06 | ①删「最近 5 条」有 `AC-P01-09` 承接 ✅。②`records_page` 参数化默认 `filter=all`（both、`includeDraft=true`）≡ 现状两列表默认口径 ✅；公司名映射由裸调升级为双 true → 已归档/停用公司名不再落「未知公司」（改进）✅；删除 Dart 排序改依赖 DB `ORDER BY attribution_date DESC, created_at DESC`（`database.dart:1272`）/`pay_date DESC, created_at DESC`（`:1297`）✅。③P01 裸调改双 true → 已归档公司进入卡片，**符合** `AC-P01-01`（「含 1 家停用、1 家已归档」且「有账必列」）✅，空态判据改 `_companies.isEmpty`（`AC-P01-07`）✅。**需登记**：(a) 显示全部公司（含无账且停用/归档）虽合 `02 AC-P06-06`「不自作折叠」，但**偏离 `07 §4.1 D3 ④`（无账且非启用 → 不显示/折叠）**，设计未登记该 07 漂移（**m13**）；(b) P01 `_StatsLine`（`:256-276`）移除后 `MainShell` Tab2 底栏「明细」(`main.dart:207`) 与 AppBar 新默认标题「全部记录」不一致（`A2` 前，**m12**）。 |

---

## 2. AC 覆盖遗漏清单（打开 `02` 逐条比对得出）

**结论：`§15` 对具备 AC 编号的条目无遗漏**（P01 14/14、P07 14/14、P06 8/8、P-DEBT 10/10、P10 9/9）。**遗漏的是「有文字要求但未立 AC」的项**：

| # | 遗漏来源 | 原文 | 设计现状 | 级别 |
|---|---------|------|---------|------|
| **O-1** | `02 §D.1`（`:361`）/ `07:241` / `07 §4.1 D3 ③` | 「有公司但全 0（未开工）：卡片区正常显示，**每卡显示"还没记过账"**」 | `09 §6.3`（`:520-531`）卡片元素表**未含**该文案；`§15` 亦无条目；`Q-D5` 只覆盖了 `07:223-224`（「从未收款/已X天」），**未覆盖 07:241** | 中（属"要求落地缺项"；且 `07 §4.1 D3 ③` 明确该文案） |
| **O-2** | `02 §D.6`（`:565`）/ `07:466` | P07「该公司**从未有记录**（新公司）：显示 `¥0.00` + "**还没开始记账**"」 | `§15` 只写 `AC-P07-10 → §5.4 空态注入`；`§5.4`（`:416-421`）仅写"不截断"，**未明确第 3 种（页面级）空态文案落点** | 低-中 |
| **O-3** | `07:226` / `02 §A.3` 补口径1（N-4） | P01 `+ 记一笔` 为**悬浮主按钮** → P02 | 设计保留现有**两个** `FilledButton`（`overview_page.dart:335-360`）并标「临时」；未登记"07:226 FAB 形态推迟到 D2" | 低（属已知临时降级，但未登记） |

> O-1 建议**照 07 实现**（与 `Q-D5` 同批、同一次 `listPaymentRecords()`/`_aggById` 派生即可，不需额外读）；O-2 建议在 P07 页面级空态显式补文案；O-3 建议在交付说明登记。

**已核对无遗漏的（供对照）**：`02 §D.1` 的「无公司整屏空态→P08」「聚合坏值降级+告警」「出口 P02/P06/P07/P08/下钻/Tab」；`§D.6` 的「停用/已删除横幅」「三种空态（前两种）」「AC-P07-07a/b/c」；`§D.12` 的「空态 + 全部剩余 0 正常显示」；`§D.13` 全部边界；`§D.14` 的「无公司/保存失败/编辑态删除」——**均有落点**。

---

## 3. 行号 / 签名核对结果

### 3.1 设计写错或需修正的（附真实值）

| # | 设计原文 | 真实值 | 级别 |
|---|---------|--------|------|
| E-1 | `09 §6.2`（`:494`）「`_RemainingCard`… 原 **`:181-199`** 内容一字不动」 | `_RemainingCard` 的 `Padding` 起于 **`overview_page.dart:180`**（`:181` 是 `padding:` 行） | 低（off-by-one，不影响施工理解） |
| E-2 | `09 §5.6`（`:453`）D1 替换体示例仅 `Navigator.push(...)` | 需补 `await` + `if (mounted) _load();`（否则规则列表返回后不刷新） | 中（文档硬化，见 §1-7） |
| E-3 | `09 §11.3`（`:795-804`）`_compareBase()` 假定 `_existing` 必属当前 `companyId` | 编辑态 `_lockCompany=false`，允许切公司 → `+ old` 归错公司 | 中（逻辑边界） |
| E-4 | `09 §6.3`（`:524`）「公司名 + 短名 … `company.shortName ?? company.name`（`company.dart:40` `displayName`）」 | `displayName`（`company.dart:40-45`）= `shortName ?? name 前 2 字`，**≠** `shortName ?? name` | 低（引用与表达式不符；应统一用 `displayName` 以合 `07:218`） |
| E-5 | `09 §7.4`（`:627`）「多收核对」视图含 `remaining <= 0` 的行 | 提示计数 `overpaidAbs` 只统计 `remaining < 0`（§7.3 `:608`）→ 计数与列表口径不一致 | 低 |
| E-6 | `09 §9.2`（`:699`）/§5.3（`:413`）写 `updateCompany(enabled: true/false)` | `database.dart:488` 真实签名为 `updateCompany(Company x)`（整对象；`Company` **无 `copyWith`**）——此为 `07:181/488` 的简写约定，非设计独创 | 低（需施工者自行构造整对象） |

> **注（非 09 之错，但 09 依赖它）**：`02 §D.14`（`:842`）把写方法行号标为 `:913`/`:927-930`，实为 `listPaymentRecords`/`listPaymentRecordsOn` 的行；`upsertPaymentRecord` 真实在 `database.dart:890`、`updatePaymentRecord` 在 `:983`。以真实值为准。

### 3.2 已逐条核对属实的（摘要）

- **DB 签名**：`aggregate`（`database.dart:273`）、`aggregateByCompany`（`:333`）、`listCompanies({ledgerId, includeDeleted=false, includeDisabled=false})`（`:451-455`）、`getCompany`（`:436`）、`updateCompany`（`:488`）、`listPricingRules({companyId, includeDeleted=false, includeDisabled=false})`（`:536-540`）、`listWorkRecords({companyId,startDate,endDate,includeDeleted=false,includeDraft=true})`（`:619-624`）、`listPaymentRecords({companyId,startDate,endDate,includeDeleted=false})`（`:910-914`）、`getPaymentRecord`（`:898`）、`upsertPaymentRecord`（`:890`）、`updatePaymentRecord`（`:983`）、`softDeletePaymentRecord`（`:992`）、`softDeleteWorkRecord`（`:877`）、`getWorkRecord`（`:604`）——**设计调用的每个方法名与参数均真实存在** ✅（含 `listPricingRules` 确有 `includeDisabled`/`includeDeleted`；`listCompanies` 两布尔默认均 `false`；`aggregateByCompany` 确无参）。
- **排序/日期**：`_workRecordRows` orderBy `attribution_date DESC, created_at DESC`（`:1272`）✅；`_paymentRecordRows` orderBy `pay_date DESC, created_at DESC`（`:1297`）✅；`_dateRange` 在 `:1163-1179` ✅；`attribution_date`=`workDate`（`database.dart:1467` / `:1566`）✅。
- **UI 行号**：`overview_page.dart` 全部引用✅；`records_page.dart:33-34/52-64/68-70/73-76/100-163/182-184/211/239/325/405-437`✅；`company_page.dart:66/293/294/302-342/433-542/120`✅；`payment_form_page.dart:30-32/82-122/132-139/152-191/179/182-183/184-190/193-229/232-245/291-294`✅；`work_form_page.dart:44-52/120-153/122/157/402/469/475`✅；`main.dart:45-61/55-56/190-194/203-210/191`✅；`routes.dart:11/14/15`✅；`data_bus.dart:9/11/15`✅；`money.dart:9/19/30/35-40`✅；`enum_codec.dart:14/110`✅；`company.dart:40`✅。
- **07 行号**：`07:208/217/223-224/226/229/240/241/242/283/340/417-422/441/450/451-456/458-459/461/464-466/488/501/540/543/546/558/907`——全部**属实**。

---

## 4. `§13` 十一项的独立判断

> 判定口径：**处置合理**（可照施工）/ **需主理人裁定** / **处置不合理（建议改）**。

| # | 独立判断 | 理由（我打开的位置） |
|---|---------|-------------------|
| **Q-D1** 死路由顺延 | **处置合理（但须补 1 项）** | `§C.2.3`（`02:240-243`）的触发条件是「4 Tab 落地后」，而 Wave A 硬约束 5 禁止动路由 → **顺延到 A2/D2 是唯一自洽解**。`Routes.records`（`routes.dart:14`+`main.dart:55-56`）确为死路由，`Routes.overview`（`routes.dart:11`）确未注册（`main.dart` 用 `home:` 承接）——设计陈述属实。**但遗漏 `Routes.companies`**：设计自身把 `overview_page.dart:379`（其唯一调用点）改为命令式后，`Routes.companies` 也变死路由 → 须并入同批清理，或（更优）保留该按钮的 `pushNamed(Routes.companies)`。见 M2。 |
| **Q-D2** `RecordsPage` const 兼容 | **处置合理（且为硬要求）** | `main.dart:56` 与 `main.dart:192`（`const _pages`）两处均为 const 上下文；设计 §4.3 的「全可选 + `const` 默认」满足之（`RecordsFilter.all` 为 `static const`）。已实际核对可编译。 |
| **Q-D3** P07/P01 的 P08 出口临时 push `CompanyPage()` | **处置合理但属"临时降级"，需主理人确认** | `07:456`「编辑公司→P08」、`02 §C.2.1`（`:226`）确将 P07 列为 P08 入口；P08 真页在 D1 → Wave A 无落点。与 T-1「临时降级 + 标注」模式一致（`02 §A.3` 补口径1）。**建议补**：临时跳转优先用 `pushNamed(Routes.companies)`（等价且不制造新死路由，见 M2）。 |
| **Q-D4** 规则区块查询参数与 `AC-P07-07a` 字面 | **处置合理（推荐设计原方案），需评审确认** | `AC-P07-07a`（`02:579`）/`§D.6`（`02:558`）字面用 `includeDisabled:true`（`includeDeleted` 默认 false）；设计改用 `includeDeleted:true` 一次查全 + Dart 侧滤 `!isDeleted` 作展示列表——**两者可见集等价**（`:557` `deleted_at IS NULL` 条件），且额外服务 `ruleNameById` 溯源（`§E-11` 允许悬空）。**建议**：采设计原方案（省 1 读），在验收证据中写明「Dart 侧滤 `!isDeleted` ≡ `includeDeleted:false`」。 |
| **Q-D5** `07:223-224` 无 AC | **处置合理** | `07:223-224` 确在控件清单内；`02 §D.1` AC-P01-01~14 确无对应条目 → 「照 07 实现 + 登记验收缺口」是正确处置。**注意**：同源但**被遗漏**的 `07:241`（"还没记过账"）应一并登记/实现，见 O-1。 |
| **Q-D6** `07:242` 草稿提示「不做」 | **处置合理，但"不做"须正式登记** | 核实：DB 层无「按公司聚合草稿」的方法（`database.dart` 无此签名），`§E-6`（`02:892`）禁止新增 DB 方法 → 只能全表 `listWorkRecords(includeDraft:true)` 后 UI 计数，**"非廉价"属实**。因 `02 §D.1`（`:362`）确有该空态文字要求，**"不做"应登记（`00-开放问题` 或 `02 §E`，由 PM 定）**，不能只写在 09 里。 |
| **Q-D7** P01 既有 `_StatsLine` | **建议移除（合理），但需主理人拍板** | 已核：`07` P01 控件清单（`:214-229`）**确实没有** `_StatsLine` 对应控件；`_StatsLine`（`overview_page.dart:256-276`）显示「共 N 家公司 · N 条工作记录 · N 笔收款」，其 `_workCount` 依赖裸调 `listWorkRecords()`（`overview_page.dart:57`）。`02 §D.1` AC 亦无此条 → **「07 无此控件」成立，**移除合理且省 1 次全表读。**备选**：若要保留，可只用新版已具备的数据（公司数 + q4 收款数）拼接、去掉 work count，避免额外全表读。**建议：同意移除，但在交付说明登记"移除既有行为"。** |
| **Q-D8** AC-24 编辑态阈值 | **处置合理（数学正确）** | 见 §1-6 验算：`T=remaining+old` 使弹窗条件 ⟺ 编辑后剩余 `<0`，与新建同构、与 `AC-P10-01`「严格 `>`/`==` 不弹」相容。**唯一缺口**：编辑态切公司时 `+old` 语义错位（m6）——建议：编辑态若 `companyId` 变更，`old` 按 0 处理。 |
| **Q-D9** 移除「仅计应收」chip | **处置合理，需评审确认口径** | `02 §C.1.3`（`:195`）明确「chips … 可删」；初始态 `includeDraft:false` 满足 `AC-P01-04`；移除后草稿行显 `—`（`07:340`）且不计入求和 → 顶部合计仍 `aggregate(null).receivable`（`AC-P01-04`）。**建议**：验收证据标注「默认态不含草稿；chip 可删系 `02 §C.1.3` 授权」。 |
| **Q-D10** 「多收核对」实现方式 | **处置合理** | `02 §C.1.3`（`:178`）只说"点开**同一列表的「多收」筛选视图**"，未定"同页/新页" → 同页 toggle 满足。**注意** `remaining<=0` 行集与提示计数口径不一致（E-5）。 |
| **Q-D11** P01 卡片区从零新增 | **处置合理（事实澄清）** | 已核实 `overview_page.dart` 现无公司卡片（`:131-150` 无卡片节点）→ 必须新建 `_CompanyCardSection`，不得按"改造既有卡片"理解。✔ |

---

## 5. 结论

**结论：有条件通过（Conditional Pass）。**

设计整体达到**可施工级**：六项落点齐全、`§15` AC 追溯表对本波全部 AC 无遗漏、全部被引行号/方法签名经开文件核对基本属实、硬约束（不新增依赖 / DB 只读 / 禁浮点 / 命令式下钻 / 两条陷阱）在**代码层**均未被违反。主要问题集中在**工程组织与需求文本覆盖**，非设计方向错误。

### 最小必改项（不改则不应开工）

1. **M1（施工顺序写冲突）**：`§14.2` 的 L4 与 L6 同改 `payment_form_page.dart`，违反自身「每文件单线」约束。→ 将 L4、L6 合并为同一条线（或明确先后串行），并修正「Step 0 为唯一先决」与「L4/L6 可与 Step 0 并行」的自相矛盾（m9）。
2. **M2（新增死路由）**：P01 空态主按钮由 `pushNamed(Routes.companies)` 改命令式（`09 §6.7/:571`、§8/:647）会**杀死 `Routes.companies` 的唯一调用点**，新增死路由。→ **保留 `pushNamed(Routes.companies)`**（等价于 `push(const CompanyPage())`，且 T-1 无理由改它）；同时把 `Routes.companies` 补进 `Q-D1` 的死路由清单（与 `Routes.records`/`Routes.overview` 同批处置）。
3. **M3（需求文本覆盖缺项）**：`07:241`/`02 §D.1`（`:361`）「每卡显示"还没记过账"」未落实、未登记。→ 照 07 实现（可复用现有派生数据，无需额外读），或正式登记为覆盖缺口。

### 建议随同修复（非阻塞，但建议一并处理）

4. **m4**：修正 P07「首帧 5 次全并发」表述（`TabBarView` 懒构建，q5 多在切 tab 时发起）。
5. **m5**：`AC-P10-08` 字面要求 `updatePaymentRecord`，设计沿用 `upsertPaymentRecord`——两者均 `_write` 全行 replace（`database.dart:1130-1136`/`:987`/`:894`），**功能等价**；建议在验收证据登记等价性，或按字面改用 `updatePaymentRecord`。
6. **m6**：编辑态切公司时 `_compareBase` 的 `+old` 语义修正（`companyId` 变更 → `old=0`）。
7. **E-2**：`_openRuleEditor` 的 D1 替换体补 `await` + `_load()`。
8. **O-2**：P07 页面级空态「该公司从未有记录 → 还没开始记账」补落点。
9. **m13**：登记「P01/P06 显示全部公司（含无账且停用/归档）」与 `07 §4.1 D3 ④` 的漂移（依 `02 AC-P06-06`「不自作折叠」为准）。
10. **E-4/E-5/E-1/E-6/m12/O-3**：小项订正（`displayName` 用法、多收视图行集口径、`:181` off-by-one、`updateCompany` 简写、Tab2 标题不一致、`+记一笔` FAB 形态登记）。

### 需主理人/评审裁定的 5 项

`Q-D1`（死路由顺延范围 + `Routes.companies`）、`Q-D3`（P08 出口临时跳转）、`Q-D4`（规则查询参数二选一）、`Q-D7`（`_StatsLine` 去留）、`Q-D6`（`07:242` 不做的登记位置）。

---

## 附：本次审查未修改任何文件

本文为本次审查**唯一新增产物**；`09-WaveA-实现设计.md`、`02-需求与验收.md`、`07-UI实现规格.md` 及 `app/lib/**` 均**未作任何改动**。
