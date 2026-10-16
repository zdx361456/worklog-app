# 断言强度独立审计报告：`verify_waveA.dart` / `verify_waveA2.dart`

- **审计官**：`audit-a`（独立，未参与两脚本编写）
- **审计方法**：变异测试（mutation testing）——把实现**故意改坏**，看断言能否置红
- **日期**：2026-10-16
- **审计对象**：
  - `worklog-app/app/tool/verify_waveA.dart`（413 行，声称 54 断言）
  - `worklog-app/app/tool/verify_waveA2.dart`（309 行，声称 35 断言）
- **只读承诺**：`worklog-app/**` 全程零修改（所有注入只在副本 `_scratch/audit-a/appcopy/**`）。
  无任何删除命令。
- **证据分级**：每条结论标注【实测】= 真跑命令得到的输出；【读码】= 读源码判断。

---

## 一、环境与基线（Step 1）

Dart：
```
DART="D:/workspace/software/installed/tools/FlyEnv-Data/app/flutter/3.47.4/bin/cache/dart-sdk/bin/dart.exe"
```

副本方案（原项目只读；`verify_waveA` 用 `../lib/...` 相对导入，`verify_waveA2` 用 `lib/...`
相对 CWD 读取，故副本内运行即读副本）：
```bash
WORK="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/_scratch/audit-a"
APP="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/worklog-app/app"
mkdir -p "$WORK/appcopy/tool"
cp -r "$APP/lib" "$WORK/appcopy/lib"
cp -r "$APP/.dart_tool" "$WORK/appcopy/.dart_tool"
cp "$APP/pubspec.yaml" "$APP/pubspec.lock" "$WORK/appcopy/"
cp "$APP/tool/verify_waveA.dart" "$APP/tool/verify_waveA2.dart" "$WORK/appcopy/tool/"
```

基线复跑命令：
```bash
cd "$WORK/appcopy"
WORKLOG_USE_SYSTEM_SQLITE=1 "$DART" --disable-dart-dev tool/verify_waveA.dart
WORKLOG_USE_SYSTEM_SQLITE=1 "$DART" --disable-dart-dev tool/verify_waveA2.dart
```

| 脚本 | 基线结果 | 是否与主理人声称一致 |
|---|---|---|
| `verify_waveA.dart` | **54 通过 / 0 失败**（exit 0） | ✅ 一致【实测】 |
| `verify_waveA2.dart` | **35 通过 / 0 失败**（exit 0） | ✅ 一致【实测】 |

> 副产物：`verify_waveA2` 复跑时输出显示 `calendar_page.dart`「已由 Wave B 原位填充」、
> `stats_page.dart`/`settings_page.dart`「已由 Wave C1 原位填充」→ 证实其**占位态分支已退役**（见 §4）。

---

## 二、逐条断言判定表（Step 2）

### 2.1 `verify_waveA.dart` —— 断言分类

**结论：54 条断言全部为 A 类（真运行时断言）**。脚本 `import '../lib/...'` 真调
`AppDatabase` / `RecordsFilter`，比较真实返回值。**无 B/C/D 类静态文本断言**。
（断言 API：`check(name, bool, [detail])`，末尾统计 `_pass/_fail`。）

| 组 | 断言（逐条） | 类 | 判定 | 依据 |
|---|---|---|---|---|
| §1 恒等式 | ①应收恒等式(agg vs Σ明细) ②已收恒等式 ③分账恒等式(agg vs Σ公司) ④remaining=receivable−received ⑤基线数值 200000/110000/90000 | A | **真** | ① ② ③ 是**两条独立代码路径互校**（SQL 聚合 vs 列表求和）；⑤ 硬编码锚点【实测：WA-2 全红】 |
| §2 P-DEBT 口径 | ①debtTotal==110000 ②overpaidAbs==20000 ③恒等式 ④debtTotal≠remaining ⑤remaining==0不出现 ⑥欠款行数1 ⑦多收行数1 | A | **真(局部)/弱** | ① ② ③ ⑥ ⑦ 为真断言，但**全部在测试内部用 `aggregateByCompany()` 现算** → 只验证 `aggregateByCompany`，**不验证 App 的 P-DEBT 页面 `_debtTotal`**；④ 是**恒真式**（此组数据下 110000≠90000 恒成立）；⑤ 后两子句为恒真。**页面口径逃逸见 §3-F1** |
| §3 草稿不计入 | ①默认6条 ②false时4条 ③无draft ④99999未进入 ⑤公司D不出现 ⑥receivableDrill.includeDraft==false ⑦all==true ⑧scope ⑨companyId==null | A | **真** | 数据层 ①–⑤ + 接口层 ⑥–⑨（运行时常量取值）【实测：WA-1 红 ⑥⑦；WA-2 红 ②③④⑤】 |
| §4 软删 | ①软删50000→应收150000 ②软删40000→已收70000 ③复原基线 ④有效4条 | A | **真** | 【实测：WA-3 红 ①②⑤…】 |
| §5 RecordsFilter 值语义 | ①copyWith()==成立 ②hashCode ③值相等 ④hashCode ⑤all≠receivableDrill ⑥all≠receivedDrill ⑦includeDraft 可区分 ⑧companyId 可区分 ⑨clearCompanyId ⑩hasCompany/hasDateRange ⑪day(d) ⑫day(d)≠day(d2) | A | **真** | `==` 弱化后 ⑦⑧⑫ 变红【实测：WA-RF1】 |
| §6 边界形态 | ①停用B出现 ②归档C出现 ③双true→4家 ④裸调→2家 ⑤裸调漏B | A | **真(数据层)/局限** | ③④⑤ 验证 `listCompanies` 默认行为【实测：WA-4 红 ④⑤】；但**未验证三个页面是否真传双 true**（F3） |
| §7 全多收 | ①debtTotal==0 ②overpaidAbs==150000 ③恒等式 ④Σ==全局 ⑤复原90000 | A | **真** | 同 §2 形态；③ 用 `g`（aggregate 现算）做交叉 |
| §8 逐公司一致 | 3× `aggregate(cid)==aggregateByCompany 同行` + 未出现公司→全0 | A | **真** | 两条独立路径互校【实测：WA-3 红其一】 |
| §9 整数纪律 | ①三字段int ②remaining逐分 ③明细int | A | **真** | 类型运行时校验 |

### 2.2 `verify_waveA2.dart` —— 断言分类

**结论：35 条断言全部为静态文本断言（B/C/D 类）**。脚本只 `import 'dart:io'`，
读源码文件做 `contains` / 正则 / 计数。**无任何运行时行为断言**。

| 组 | 断言（逐条） | 类 | 判定 |
|---|---|---|---|
| [0] | `lib/main.dart 可读` | D | 弱(存在性) |
| [1] | `_pages 可定位` | B | 真 |
| | `_pages 恰 4 项` | C | 真 |
| | `_pages 顺序 == 期望` | C | **真**【实测 A2-M1 红】 |
| | `旧 Tab 页已移出 _pages` | B | 真 |
| [2] | `BottomNavigationBarItem 恰 4 个` | C | 真 |
| | `Tab 文案 == [看板,日历,统计,设置]` | B/C | **真**【实测 A2-M2 红】 |
| | `旧 Tab 文案已不存在` | B | 真 |
| [3] | ×3 文件 `Xxx Page 为 StatefulWidget` | B | **真**【实测 A2-M14 红】 |
| | ×3 `构造签名 const Xxx({super.key})` | B | 真 |
| | ×3 `保留 Scaffold/AppBar` | B | 真 |
| | ×3 「已填充→占位断言退役」 | D | **空断言**：当前恒走 `_ok` 分支，无校验 |
| [4] | `Routes.companies 保留` (routeSrc.contains('companies')) | B | **弱**：任何含 "companies" 字样即过 |
| | `main 注册 Routes.companies → CompanyPage` | B | 真 |
| | `P01 仍有 RecordsPage 下钻入口 (count>=1)` | C | **假覆盖**（见 F4） |
| | `P01 仍有 pushNamed(Routes.companies) (count>=1)` | C | **假覆盖**（见 F5；且**注释行也计入**，见 §3 备注） |
| [5] | `P01 AppBar 标题 = 看板` (contains `Text('看板')`) | B | **假覆盖**：未锚定 AppBar，任意位置一处 `Text('看板')` 即过（见 F6） |
| | `lib/ui 下无「总览」字面量` | B | **弱**：扫描范围仅 `lib/ui`（见 F7） |
| [6] | `routes.dart 已删 Routes.records` | B | **真**【实测 A2-M4 红】 |
| | `routes.dart 已删 Routes.overview` | B | 真 |
| | `routes.dart 保留 Routes.companies` | B | 真 |
| | `main.dart 已删 case Routes.records` | B | 真 |
| | `main.dart 无 case Routes.overview` | B | 真 |
| | `main.dart 保留 case Routes.companies` | B | 真 |
| | `main.dart 无 records_page import` | B | 真 |
| | `lib/ 代码中零 Routes.records/overview 引用` | B | 真(范围较宽，含全 lib) |
| | `records_page title 必填、旧默认 '明细' 消失` | B | 真 |

---

## 三、变异测试结果（Step 3，核心）

> 所有注入均在副本 `appcopy/**` 完成，打完后从 `base/**` 还原（无删除）。
> 「置红」= 重跑出现 `✗` 且 `结果：…/ N 失败`；「仍绿」= `54 通过 / 0 失败` 或 `35 通过 / 0 失败`。

### 3.1 置红 → 真断言（证明断言有效）

| # | 注入点 | 破坏内容（before → after） | 重跑结果 | 结论 |
|---|---|---|---|---|
| WA-1 | `lib/ui/records_filter.dart:53` | `receivableDrill` 的 `includeDraft: false` → `true` | waveA **52/2** ✗⑥✗⑦ | 真 |
| WA-2 | `lib/db/database.dart:304,354` | `status IN ('confirmed','settled')` → `(… ,'draft')`（草稿计入应收） | waveA **41/13** | 真 |
| WA-3 | `lib/db/database.dart:1150` | `{'deleted_at': stamp,'updated_at': stamp}` → `{'updated_at': stamp}`（软删不置删标记） | waveA **50/4** | 真 |
| WA-4 | `lib/db/database.dart:454` | `includeDisabled = false` → `true` | waveA **52/2** ✗④✗⑤ | 真 |
| WA-RF1 | `lib/ui/records_filter.dart:107-113` | `operator==` 收敛为「仅比 `scope`」 | waveA **51/3** ✗⑦✗⑧✗⑫ | 真 |
| A2-M1 | `lib/main.dart:210-211` | `_pages` 中 `StatsPage()` 与 `SettingsPage()` 互换 | waveA2 **34/1** ✗顺序 | 真 |
| A2-M2 | `lib/main.dart:229` | Tab 文案 `'设置'` → `'我的'` | waveA2 **34/1** ✗文案 | 真 |
| A2-M4 | `lib/app/routes.dart:29` | 追加 `static const String records = '/records';` | waveA2 **34/1** ✗已删常量 | 真 |
| A2-M14 | `lib/ui/calendar_page.dart:35` | `class CalendarPage extends StatefulWidget` → `StatelessWidget` | waveA2 **34/1** ✗结构不变量 | 真 |

### 3.2 仍绿 → 假覆盖（★ 本报告价值核心）

| # | 断言声称 | 注入点 | 破坏内容（before → after） | 重跑结果 | 判定 |
|---|---|---|---|---|---|
| **F1a** | waveA §2「P-DEBT 欠款合计口径」/ 头部 AC-PDBT-05 | `lib/ui/debt_list_page.dart:141` | `if (a.remaining > 0) {` → `if (a.remaining != 0) {`（**多收公司混入欠款表**） | waveA **54/0** | **假覆盖** ✗ |
| **F1b** | 同上 | `lib/ui/debt_list_page.dart:150` | `final debtTotal = rows.fold<int>(0,(s,r)=>s + r.agg.remaining);` → `s + (-r.agg.remaining)`（**欠款合计符号反转**） | waveA **54/0** | **假覆盖** ✗ |
| **F2a** | waveA §3⑥⑧⑨「陷阱1接口防线」/ 头部 AC-P01-04 | `lib/ui/overview_page.dart:176` | 应收下钻 `filter: RecordsFilter.receivableDrill,` → `RecordsFilter.all,`（**点应收合计看到的列表含草稿+收款**） | waveA **54/0** & waveA2 **35/0** | **假覆盖** ✗ |
| **F2b** | waveA §8 头部 AC-P07-11 | `lib/ui/company_detail_page.dart:576` | `filter: RecordsFilter.companyWork(widget.companyId),` → `RecordsFilter.receivableDrill,`（**P07 工作 tab 丢公司过滤**） | waveA **54/0** & waveA2 **35/0** | **假覆盖** ✗ |
| **F3a** | waveA §6④⑤ 头部 AC-P01-07 | `lib/ui/overview_page.dart:103` | `_guard(_db.listCompanies(includeDisabled: true, includeDeleted: true)),` → `_guard(_db.listCompanies()),`（**P01 裸调 → 停用/归档公司落空态，AC-P01-07 原缺陷复现**） | waveA **54/0** & waveA2 **35/0** | **假覆盖** ✗ |
| **F3b** | 头部 AC-PDBT-03 | `lib/ui/debt_list_page.dart:118` | `_db.listCompanies(includeDisabled: true, includeDeleted: true),` → `_db.listCompanies(),` | waveA **54/0** & waveA2 **35/0** | **假覆盖** ✗ |
| **F3c** | 头部 AC-P06-03 | `lib/ui/company_page.dart:97` | 同上裸调 | waveA **54/0** & waveA2 **35/0** | **假覆盖** ✗ |
| **F4** | waveA2 [4]「P01 仍有 RecordsPage 下钻入口」 | `lib/ui/overview_page.dart:213` | `builder: (_) => CompanyDetailPage(companyId: c.id),` → `builder: (_) => const CompanyDebtListPage(),`（**点公司卡片进错页；AC-A2-04 / AC-P01-06 的 U-1 直接验收点**） | waveA2 **35/0** | **假覆盖** ✗ |
| **F5** | waveA2 [4]「P01 仍有 pushNamed(Routes.companies)」 | `lib/ui/overview_page.dart:222` | 「全部公司」改命令式 `push(MaterialPageRoute(builder: (_) => const CompanyPage()));`（**违反 M-2 / Q-D1**），另一处 `pushNamed` 作诱饵 | waveA2 **35/0** | **假覆盖** ✗ |
| **F6** | waveA2 [5]「P01 AppBar 标题 = 看板」 | `lib/ui/overview_page.dart:260` | `AppBar(title: const Text('看板'))` → `const Text('首页')`，并在文件尾追加真实代码 `const Widget _decoyKanban2 = Text('看板');` | waveA2 **35/0** | **假覆盖**（单点逃逸）✗ |
| **F7** | waveA2 [5]「lib/ui 下无「总览」字面量」 | `lib/main.dart`（尾） | 追加 `const Widget _legacyTitle = Text("总览");`（用户可见，但在 `lib/ui` 之外） | waveA2 **35/0** | **未覆盖**（扫描范围缺口）✗ |

**F6 备注**：断言写法是 `overviewSrc.contains("Text('看板')")`——**只查子串出现**，不锚定
`AppBar(title:)`。第一次尝试用双引号诱饵 `Text("看板")` 未命中（因断言只匹配单引号字面量），
换单引号后即逃逸，**证明这是"字符串出现"级断言**。

**F5 备注**：`RegExp(r'pushNamed\(Routes\.companies\)')` 统计的是**全文正则计数**，
`overview_page.dart:777` 的**注释行**也含 `pushNamed(Routes.companies)` 字样会被计入 →
即使真实接线全删，只要残留一处注释即满足 `>=1`。**计数断言 + 注释计入 = 双弱点**。

### 3.3 假覆盖的复现命令模板

```bash
WORK="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/_scratch/audit-a"
DART="D:/workspace/software/installed/tools/FlyEnv-Data/app/flutter/3.47.4/bin/cache/dart-sdk/bin/dart.exe"
# 例：F1b —— 欠款合计符号反转，waveA 仍 54/0
sed -i 's/final debtTotal = rows.fold<int>(0, (s, r) => s + r.agg.remaining);/final debtTotal = rows.fold<int>(0, (s, r) => s + (-r.agg.remaining));/' \
  "$WORK/appcopy/lib/ui/debt_list_page.dart"
cd "$WORK/appcopy" && WORKLOG_USE_SYSTEM_SQLITE=1 "$DART" --disable-dart-dev tool/verify_waveA.dart
# → 结果：54 通过 / 0 失败   （实现已坏，断言全绿）
```

---

## 四、覆盖缺口清单（Step 4）

依据：脚本头部/注释**自述**覆盖的需求编号 ↔ `02-需求与验收.md` §D.15 / §D.1 / §D.12 / §D.13
的 AC 定义（**读码级**核对）。

### 4.1 `verify_waveA` 声称的 AC 与其实际强度

| AC（脚本自述） | 02 文档定义 | 脚本实际断言的内容 | 缺口 |
|---|---|---|---|
| AC-33 / AC-P01-13 | 开发期断言 `aggregate(null).remaining == Σ aggregateByCompany` | §1③ §7④ §8 | ✅ 基本覆盖（数据层） |
| AC-32 | 草稿不计入应收 | §3（数据层+常数） | ✅ 数据层真覆盖 |
| AC-PDBT-05 | 欠款合计 == Σ 行内 remaining **且页面须显式标注口径** + 恒等式断言 | §2 仅在测试内现算恒等式 | ⚠️ **页面 `_debtTotal` 与页面标注未覆盖**（F1a/F1b） |
| AC-P01-01 | 3 家公司卡片**全部出现**、灰色角标、金额计入全局 | §6① ② 仅验 `aggregateByCompany` 含 B/C | ⚠️ UI 卡片/角标未覆盖 |
| AC-PDBT-10 | 边界：0 家 / 1 家 / 全多收 / 停用仍欠款 | §7（全多收）+§6（停用） | ⚠️ 0家/1家 未覆盖；UI 未覆盖 |
| **AC-P01-11** | **空态（无公司）主按钮文案 → P08** | §8 却断言「逐公司一致」 | ❌ **编号引用与 02 定义不符**（§8 所示语义实为 AC-33 的派生）【读码】 |
| AC-P07-11 | P01 卡片剩余 == P07 剩余 == `aggregate(cid)` | §8 仅 `aggregate(cid)==aggregateByCompany` | ⚠️ P07 UI 未覆盖（F2b） |
| AC-P01-07 | 停用公司仍显示（**缺陷修复**） | §6⑤ 仅验「裸调会漏 B」 | ⚠️ **P01 页面是否双 true 未验证**（F3a） |
| AC-PDBT-03 | **禁裸调** `listCompanies()` | §6④⑤ 仅验 DB 默认值 | ⚠️ P-DEBT 页面调用点未验证（F3b） |
| AC-P06-03 | 状态角标需 `includeDeleted:true` | §6④ 间接 | ⚠️ P06 页面调用点未验证（F3c） |
| **AC-P01-03/04/05/06/08/09/14** | 下钻闭环 UI（点金额/点卡片 → 明细） | **零断言** | ❌ **整条 U-4 用户诉求无脚本覆盖**（F2a/F2b/F4；须真机） |
| AC-PDBT-01/02/04 | P-DEBT 列表内容/排序/行点击 | **零断言** | ❌ 未覆盖（F1a） |

> **系统性结论（waveA）**：脚本**把「数据层默认行为」当成「页面接线正确」的代理证据**。
> 三处页面（P01/P-DEBT/P06）的调用点、三处下钻接线、P-DEBT 页面口径——**全在脚本视线之外**。
> 而这批 AC 的**真实实现落点全在 UI 层**。

### 4.2 `verify_waveA2` 声称的 AC 与其实际强度

| AC（脚本自述） | 02 文档定义 | 脚本实际断言 | 缺口 |
|---|---|---|---|
| AC-A2-03 | 零一次性代码：占位页 = 文件骨架，原位填充 | [3] 结构不变量（StatefulWidget + const 构造 + Scaffold/AppBar） | ✅ 部分覆盖（结构层） |
| AC-A2-05 | 启动读数：占位页 `_load()` 空实现 | [3] 条件式分支 | ❌ **已退役**：三页均已填充 → 恒走 `_ok` 空断言，**当前零校验** |
| 文案口径（总览→看板） | [5] | [5] 两条 | ⚠️ 单点逃逸（F6）+ 范围缺口（F7） |
| 死路由清理 MAJ-01 | [6] | [6] 9 条 | ✅ 较强（A2-M4 实测置红） |
| `RecordsPage.title` 必填 | [6] | [6] 1 条 | ✅ |
| **AC-A2-04** | **P01 不改结构与下钻入口，Wave A 入口保持可用** | [4] 标题自称覆盖 AC-A2-04 | ❌ **自称覆盖但实际是「计数出现」级断言**（F4/F5）；且**脚本 footer 又自称 AC-A2-04 属[真机]不覆盖** → **自相矛盾**（读码） |
| AC-A2-01/02 | 4 Tab 可点入 / 占位页非空白 | 脚本自述「不覆盖·真机」 | 诚实声明 ✅（但 [1]/[2] 的静态检查**部分**充当了 A2-01/02 的代理） |

---

## 五、结论（Step 5）

### 5.1 两个脚本的可信度评级

| 脚本 | 断言内在强度 | 有效覆盖（相对其自称的 AC） | 综合评级 |
|---|---|---|---|
| `verify_waveA.dart` | **强**（54/54 真运行时断言；5 处注入全置红） | **低**——自称覆盖 12 个 AC，其中 **≥7 个的实现落点（UI 接线/页面口径）零覆盖**；**7 处 UI 注入全绿** | **「数据层可信，交付面不可信」** |
| `verify_waveA2.dart` | **弱**（35/35 静态文本断言；4 处注入置红，**4 处注入逃逸**） | **中**——死路由/结构不变量较可靠；**可达性([4])与文案([5])为单点逃逸** | **「骨架级可信，行为级不可信」** |

### 5.2 一句话总结（每个脚本）

- **`verify_waveA.dart`**：「**把 P-DEBT 页面口径改成反向、把三处下钻接线接错、把三个页面裸调
  `listCompanies`——全绿**」→ 它验证的是**数据库和筛选常数的正确性**，而不是 **Wave A 的真正
  交付物「下钻闭环 UI」**；其"全绿"**不能**支撑 AC-P01-P01/03/04/05/06/07、AC-PDBT-02/03/05、
  AC-P06-03、AC-P07-11 的验收结论。
- **`verify_waveA2.dart`**：「**点公司卡片进错页 → 仍 35/0 全绿**」→ [4]「可达性」与 [5]「文案」
  是**字符串出现/计数**级断言，存在单点逃逸；只有 [1]/[2]/[6] 与 [3] 结构不变量真加了约束。

### 5.3 假覆盖汇总

- **假覆盖条数：11 处注入**（waveA 7 处：F1a/F1b/F2a/F2b/F3a/F3b/F3c；waveA2 4 处：F4/F5/F6/F7）。
- **覆盖缺口条数：约 14 条 AC**（waveA ≥9：AC-P01-01/03/04/05/06/07/14、AC-PDBT-01/02/03/05、
  AC-P06-03、AC-P07-11 中属 UI 的部分 + AC-P01-11 编号引用错；waveA2 2 条：AC-A2-04 自称覆盖
  实为计数断言、AC-A2-05 已退役）。**去重后逐条清单见 §4。**

### 5.4 最严重的 1~2 条（附注入点与复现命令）

**① `verify_waveA` 对 P-DEBT 页面口径零覆盖（AC-PDBT-05 名不副实）**
- 注入点：`lib/ui/debt_list_page.dart:150`
- 破坏：`s + r.agg.remaining` → `s + (-r.agg.remaining)`（**「欠款合计」符号整体反了**）
- 重跑：waveA **54 通过 / 0 失败**
- 复现：见 §3.3
- 意义：脚本 §2 自称验证「P-DEBT 欠款合计口径」，但公式在**测试里重算**了一遍，
  **页面里那份公式坏掉它看不见**。

**② 两个脚本对 Wave A 的 U-4 核心（下钻接线）零覆盖**
- 注入点：`lib/ui/overview_page.dart:176`（应收下钻 filter 改 `RecordsFilter.all`）
- 重跑：waveA **54/0**、waveA2 **35/0**（两脚本同时逃逸）
- 意义：用户原始诉求就是「点金额/点公司看不到明细」；**把明细 drilling 接成"全部记录"，
  两个脚本都判全绿**。同类还有 F2b（P07 工作 tab 丢公司过滤）、F4（点公司卡片进错页）。

---

## 六、自我限定（Step 5.6）

以下断言/AC **未能注入**，原因如实说明，**不作臆测**：

1. **凡依赖 Flutter UI 运行时（build/didUpdateWidget/Navigator/真机渲染）的行为**，本环境
   **无法真跑**（本项目 Dart VM `Process.start` 失效、无 Flutter 引擎）。
   故 §4 中一切「UI 接线/页面渲染」类结论，均为**通过"改坏源码后重跑脚本仍绿"反推的覆盖缺口**
   （证据级别：【实测】= 脚本确实全绿；对"UI 是否真坏"的判定属【读码】——注入均为语义等价于
   实现坏的最小改动，但未在真机复现用户可见效果）。
2. **AC-A2-01/02/04 的 [真机] 档**（Tab 可点入、占位页非空白、切换不崩）**本审计未验**，
   与脚本自述一致；本报告仅指出 [4] 的**静态代理**不足，**未否认**真机验收的可能性。
3. **waveA §2 的 ④（debtTotal≠remaining）** 我判定为「恒真式」，依据是【读码】此组数据
   （110000 vs 90000）——未构造使二者相等的反例去证伪该式，属**读码级**判断。
4. **AC-P01-11 编号不一致**：我按 `02-需求与验收.md:391` 的现行定义（空态主按钮文案）
   判定脚本引用有误；若项目存在**旧编号版本**，则该"缺口"可能不成立——标注为【读码·存疑】。
5. 本审计**未**检查其他 `verify_*.dart`（waveB/C1/C2/D1/D2/core/db）是否补上了这些 UI 覆盖；
   故 §5 的"零覆盖"均限定为「**这两个脚本内**零覆盖」。
6. 所有注入命令使用 `sed`/`python` 作用于**副本**；脚本内部假覆盖的**根因判定**（如 F6 单点逃逸、
   F5 注释计入计数）均为【读码】分析 + 【实测】复现，二者已分别标注。

---

## 附：本审计用到的副本目录（产物，均在 `_scratch/audit-a/`）

- `appcopy/` —— 变异测试工作副本（每轮注入后还原）
- `base/` —— 纯净基线副本（用于逐次还原单个文件）
- `审计报告.md` —— 本文件

> 原项目 `worklog-app/**` 全程 **未被修改**（仅 `Read` / `Grep`）。
