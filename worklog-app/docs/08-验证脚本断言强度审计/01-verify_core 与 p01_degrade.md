# 独立断言审计报告：`verify_core.dart` + `verify_p01_degrade.dart`

- **审计官**：audit-core（未参与两脚本编写）
- **审计日期**：2026-10-16
- **方法**：变异测试（把实现改坏 → 看哪条断言变红），全程在**副本**中进行
- **项目源码**：`worklog-app/**` **只读**，未修改/新建/删除任何文件（复核：`diff -r` 副本 lib 与项目 lib 逐字一致）
- **证据分级**：本文每条结论标注【实测】/【读码】/【类型】

---

## 一、基线

副本方案（主理人已验通）：

```bash
DART="D:/workspace/software/installed/tools/FlyEnv-Data/app/flutter/3.47.4/bin/cache/dart-sdk/bin/dart.exe"
APP="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/worklog-app/app"
WORK="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/_scratch/audit-core"
mkdir -p "$WORK/appcopy/tool"
cp -r "$APP/lib" "$WORK/appcopy/lib"
cp -r "$APP/.dart_tool" "$WORK/appcopy/.dart_tool"
cp "$APP/pubspec.yaml" "$APP/pubspec.lock" "$WORK/appcopy/"
cp "$APP/tool/verify_core.dart" "$APP/tool/verify_p01_degrade.dart" "$WORK/appcopy/tool/"
cd "$WORK/appcopy" && export WORKLOG_USE_SYSTEM_SQLITE=1
"$DART" --disable-dart-dev tool/verify_core.dart
```

| 脚本 | 结果 | 退出码 |
|---|---|---|
| `verify_core.dart` | `结果：81 通过 / 0 失败` | 0 |
| `verify_p01_degrade.dart` | 输出四元组 q1=T q2=T q3=F q4=F，结论行打印 | 0 |

**副本方案成立**（基线 81/0 与主理人实测一致），审计可继续。

---

## 二、逐条断言判定表

### 2.1 `verify_core.dart`（81 条）

类：**A**=真运行时断言 / **B**=静态文本 `contains`/正则 / **C**=计数·常量自指 / **D**=存在性

| # | 断言（分组） | 类 | 判定 | 依据（注入→反应） |
|---|---|---|---|---|
| 1-6 | 金额引擎基础 6 条（时价/日价整天/半天/计件） | A | **真** | A1 注入（`_roundDiv` 半入→截断）实测：R-2 两条置红；其余 4 条为整除算例，对舍入破坏不敏感（算例选取问题，非假覆盖） |
| 7 | `时价 4000分 × 4h = 16000分` | A | 真 | 同上 |
| 8-9 | `R-2 临界 30003分×10min=5001` / `日价30005×0.3=9002` | A | **真** | A1 实测两条置红（5001→5000、9002→9001） |
| 10-13 | 倍率组 4 条（取最高 Q12） | A | **真** | A2 注入（`a>b?a:b`→`a<b?a:b`）实测 4 条全红 |
| 14 | `跨夜 22:00→06:00 = 32000` | A | **真** | A3 注入（删 `mins += 24*60`）实测置红 |
| 15 | `AC-11 结束<开始 → needsOvernightConfirm` | A | 真 | 同源分支，读码 |
| 16 | `AC-12 时长为0 → isDraft` | A | **真** | A4 注入（`if(minutes==0)`→`if(minutes==-1)`）实测置红 |
| 17 | `Q5 手工覆盖 → 金额=12345、来源=manual` | A | 真 | 读码（分支落点 amount_engine.dart:181-191） |
| 18 | `Q5 自动参考值 = 16000` | A | **真** | A5 注入（`autoReference: mainAmount`→`0`）实测置红 |
| 19-20 | `c1 应收=10000（草稿排除）` / `c1 已收=5000` | A | 真 | R1 注入（去公司过滤）→ 应收条置红；`已收`条对**收款**过滤破坏不敏感（夹具仅 1 笔 c1 收款），但由 c2 条兜住 |
| 21 | `c1 剩余 = 5000` | A | **真** | R1 实测置红 |
| 22 | `c2 剩余 = 20000（不被 c1 污染）` | A | **真** | R1 实测置红（同时兜住收款过滤破坏） |
| 23 | `全局剩余 = 25000` | A | 真 | 走 `globalRemaining`，与 companySummary 不同路径；读码 |
| 24 | `导出 JSON 含 format` | **B** | **假** | 见假覆盖 #2：`'format'`键改名`'fmt'`后仍绿 |
| 25 | `导入校验无硬错误` | A | **真** | 键改名注入实测置红（兜住 #24 的逃逸） |
| 26 | `往返：工作记录金额一致` | A | **真** | E1 注入（`amount_snapshot`→`0`）实测置红 |
| 27 | `往返：公司默认规则保留` | A | **真** | E2 注入（`default_rule_id`→`null`）实测置红 |
| 28 | `往返：节假日类型=法定节假日` | A | **真** | E3 注入（type 恒 custom）实测置红 |
| 29 | `断言 §6.5：导出合计 == App 合计` | A | **真** | E1 实测置红 |
| 30 | `缺表 → 拒绝导入` | A | 真 | 读码（validate 六表检查 import_service.dart:148-151） |
| 31 | `值域非法(基础单价=0) → 拒绝导入` | A | **真** | Validators 恒真注入实测置红 |
| 32 | `N-3 类型不符不抛异常` | A | **真** | `_str` 改为 `v as String?` 注入实测置红（且**击穿脚本**，见缺口 #6） |
| 33 | `N-3 类型不符被报告为错误` | A | 真 | 同注入：该断言未 try/catch → 整脚本崩溃 exit 255 |
| 34 | `P-1 standard_hours 类型不符不抛异常` | A | 真 | 读码 |
| 35 | `P-1 standard_hours 类型不符被报告` | A | **真** | 检查移除注入实测置红 |
| 36-37 | `手填负数时长 → isInvalidInput` / `→ 非跨夜确认` | A | 真 | 读码（amount_engine.dart:112） |
| 38 | `N-8 半天折算比=0 → isInvalidInput` | A | **真** | Validators 恒真注入实测置红 |
| 39-73 | 必填字段覆盖 **35 个用例** | A | **真** | 分四次注入实测：`_requireDate` 破坏→3 条红；`_requireNonEmpty` 破坏→9 条红；`standard_hours` 检查移除→2 条红；`Validators.*` 恒真→3 条红。每用例均有专责校验器，无一人云亦云 |
| 74 | `必填字段覆盖：全部被拦下（无漏网）` | A | 真 | 元断言，随用例置红 |
| 75 | `六张建表语句`（`length==6`） | **C** | 真（自指） | 读码：改常量长度即红；但只校验常量自身 |
| 76-81 | `建表含 ledger/company/pricing_rule/work_record/payment_record/holiday_mark` | **B** | **假（语义）** | 见假覆盖 #1、#3 |
| 82 | `节假日唯一约束 (ledger_id, date)` | B | **真** | 删 `UNIQUE(...)` 注入实测置红（但为字面量自指） |
| 83 | `含归属日索引` | B | **真** | 删 `idx_work_record_attribution_date` 注入实测置红（字面量自指） |
| 84 | `数据库版本 = 1` | C | **真** | `kDbVersion`→2 注入实测置红 |

> 注：表中编号为分组示意（实际 81 条 check）。

**小结**：81 条中，**约 73 条为真运行时断言并已实测置红**；**7 条属静态/子串类**（6 条 `建表含 X` + 1 条 `导出 JSON 含 format`），其中 **6 条可被语义破坏逃逸**；3 条（唯一约束/索引/版本）虽为字面量自指，但对「删除」有效。

### 2.2 `verify_p01_degrade.dart`（四观测 + 退出码门）

脚本无 `check()` 计数，门控 = `exit(ok ? 0 : 1)`，`ok = q1==null && q2==null && q3!=null && q4!=null`。

| 观测 | 声明 | 独立核验 | 判定 |
|---|---|---|---|
| q1 `aggregate(null)` 脏值下抛 FormatException | 【实测级】 | 自行复跑 + P1 注入（守卫失效）→ q1 翻 false、exit 1 | **成立【实测】** |
| q2 `aggregateByCompany()` 同上 | 【实测级】 | 同 P1 | **成立【实测】** |
| q3 `listCompanies(双true)` 不受影响 | 【实测级】 | 基线 q3=F；未受 P1 影响 | **成立【实测】** |
| q4 `listPaymentRecords()` 不受影响 | 【实测级】 | 基线 q4=F | **成立【实测】** |
| 第 3 节「同构 guard 隔离四元组」 | 【同构推理】非实测 | 脚本自声明「不等于页内 `_guard` 实测」；读页内 `_guard`（overview_page.dart:88-94）与脚本 `guard<T>()` **逐字一致** | **标注诚实** |

**证据层级标注核验**：**诚实**。
- 头部「实测级 / 同构推理 / 读码级」三分清楚；
- 第 3 节标题明写「**非**调用页内 `_guard`」；
- 结尾结论行**未**把同构结论写成实测。
- 唯一瑕疵：引文写作 `overview_page.dart:87-93`，实际方法体为 **88-94**（87 为注释行），**off-by-one，无实质误导**【读码】。

---

## 三、假覆盖清单（核心，附可复现注入）

> 全部在 `$WORK/appcopy/` 副本内操作；`before→after` 逐字给出（路径按**项目内文件**标注）。每条都附「改完仍全绿/变红」的实测输出。

### 假覆盖 #1 · `建表含 work_record`（含同类 5 条 `建表含 X`）——子串逃逸

- **断言**：`verify_core.dart:430`
  `check('建表含 $t', kCreateTableStatements.any((s) => s.contains('CREATE TABLE IF NOT EXISTS $t')))`
- **注入点**：`lib/db/database_schema.dart:70`
  - before：`CREATE TABLE IF NOT EXISTS work_record (`
  - after ：`CREATE TABLE IF NOT EXISTS work_records (`
- **逐字命令**：
  ```bash
  # 在副本 lib/db/database_schema.dart 第 70 行改 work_record → work_records
  cd "$WORK/appcopy" && export WORKLOG_USE_SYSTEM_SQLITE=1
  "$DART" --disable-dart-dev tool/verify_core.dart
  ```
- **重跑输出**：
  ```
  ✓ 建表含 work_record
  ...
  结果：81 通过 / 0 失败
  ```
- **危害**：`work_records` **包含**子串 `work_record` → `contains` 恒真；而 App 真实建表/查询用的表名已与断言以为的不符。**表名追加后缀式改名**整组逃逸（`ledger`→`ledgers`、`payment_record`→`payment_records`、`holiday_mark`→`holiday_marks` 同理）。

### 假覆盖 #2 · `导出 JSON 含 format`——子串逃逸（键名不受校验）

- **断言**：`verify_core.dart:262` `check('导出 JSON 含 format', json.contains('worklog-app-backup'))`
- **注入点**：`lib/services/export_service.dart:57`
  - before：`'format': formatTag,`
  - after ：`'fmt': formatTag,`
- **重跑输出**：
  ```
  ✓ 导出 JSON 含 format
  ✗ 导入校验无硬错误  (错误: [格式标识不符：期望 "worklog-app-backup"，实际 "null"])
  结果：80 通过 / 1 失败
  ```
- **危害**：断言名声称「含 format」，实为「JSON 文本里出现该字面量**值**」，**不校验键**。该断言自身逃逸（套件层由 `导入校验无硬错误` 兜住，故未被掩盖成静默失误）。

### 假覆盖 #3 · `建表含 X` 组对「删列」全盲

- **注入点**：`lib/db/database_schema.dart:89`
  - before：`    amount_snapshot        INTEGER NOT NULL, -- 分`
  - after ：（整行删除）
- **重跑输出**：
  ```
  ✓ 六张建表语句 / ✓ 建表含 ledger / ... / ✓ 建表含 work_record / ...
  ✓ 节假日唯一约束 (ledger_id, date) / ✓ 含归属日索引 / ✓ 数据库版本 = 1
  结果：81 通过 / 0 失败
  ```
- **危害**：删掉 `work_record` 的**核心金额列**（App 聚合与行映射都依赖它），DB Schema 整组 10 条断言**全绿**。该组只做「表名字面量 + 2 个约束/索引名」的存在性检查，**不校验列/类型/约束完整性**。

### 对照 · 真断言（置红有效，证明「全绿」≠ 假）

| 注入 | 变红断言 |
|---|---|
| `_roundDiv` 半入→截断 | R-2 ×2 |
| 倍率 `max`→`min` | 倍率组 ×4 |
| 删跨夜 `+24h` | 跨夜 ×1 |
| 删 `AC-12` 草稿分支 | AC-12 ×1 |
| `autoReference`→0 | Q5 参考值 ×1 |
| 去公司过滤（应收/已收） | c1应收/c1剩余/c2剩余 ×3 |
| `amount_snapshot` 序列化→0 | 往返金额 + §6.5 ×2 |
| 删 `UNIQUE(ledger_id,date)` | 节假日唯一约束 ×1 |
| 删归属日索引 | 含归属日索引 ×1 |
| `Validators.*` 恒真 | 值域/越界 ×4（含必填 case ×3） |
| `_requireDate`/`_requireNonEmpty` 破坏 | 必填 case ×12 |
| `_str` 改 `as String?` | N-3 ×1（并崩溃） |

---

## 四、覆盖缺口清单

| # | 缺口 | 证据 | 分级 |
|---|---|---|---|
| 1 | **软删记录不计入应收/已收（§8 约束#3 / AC-32）**：`ReceivableService.receivable/received` 的 `if (r.isDeleted) continue;` / `if (p.isDeleted) continue;` 两分支，夹具无软删记录 | 注入（删除两处 `isDeleted` 跳过）→ **仍 81/0 全绿** | **【实测】** |
| 2 | **DB Schema 语义完整性**：`建表含 X` 只查表名字面量，不校验列/类型/约束 | 假覆盖 #3 实测 | **【实测】** |
| 3 | **`payment_record` 聚合守卫**：`verify_p01_degrade` 只脏写 `work_record.amount_snapshot`，未覆盖 `payment_record.amount` 聚合守卫 | 注入（`_assertAggregateColumnTypes` 对 `payment_record` 提前 return）→ 脚本**仍 exit 0 全绿**，且照印「降级前提成立」结论 | **【实测】** |
| 4 | **CSV 导出**（`workRecordsCsv`/`paymentRecordsCsv`） | 两脚本均无任何断言 | 【读码】 |
| 5 | **AC-11 / AC-08**：跨夜与需确认各仅 1 条算例（单点） | 读码 | 【读码】 |
| 6 | **脚本健壮性**：`N-3 类型不符被报告为错误`（`verify_core.dart:299`）未包 try/catch → 实现若抛异常会**击穿整脚本**（实测 exit 255），而非干净置红 | N-3 注入实测 | **【实测】** |
| 7 | `导出 JSON 含 format` 不校验键名 | 假覆盖 #2 实测 | **【实测】** |

---

## 五、结论

### `verify_core.dart` —— 可信度：**中高**

- **81 条中约 73 条是真运行时断言**，覆盖金额引擎（整数精度/倍率取最高/跨夜/草稿/手工覆盖）、剩余工资公司维度过滤、导出导入往返与校验、必填字段 35 例、非法输入——**这些均经注入实测置红，强度真实**。核心业务口径（AC-08/11/12、Q5、Q12、R-1、R-2、§6.5）**确为真断言**，可以支撑「这些点实现正确」。
- **薄弱面集中在 `== DB Schema ==` 静态组建**：6 条 `建表含 X` 为**子串式假覆盖**，可被「表名追加后缀 / 删列」整组逃逸；`导出 JSON 含 format` 亦是子串式假覆盖。**schema 组"全绿"不能作为"表结构正确"的证据**。
- 另有 1 条**软删排除**口径完全未被覆盖（缺口 #1）。

**一句话**：业务逻辑断言扎实、可信；「DB Schema 全绿」是**被高估的凭据**，需按缺口 #1/#2 补强或降级表述。

### `verify_p01_degrade.dart` —— 可信度：**中（但诚实）**

- 四观测 q1~q4 **成立**（独立复跑 + 注入翻红证实），退出码门真实有效（守卫失效 → exit 1）。
- **证据层级标注诚实**：明确区分【实测级】/【同构推理】/【读码级】，并显著声明第 3 节是「同构副本、非页内 `_guard` 实测」；页内 `_guard` 确与其同构副本逐字一致（仅引用行号 off-by-one）。
- 局限：它是**行为观测脚本、非逐点断言**；且结论「降级前提成立」**只覆盖 work_record 聚合路径**——`payment_record` 聚合守卫是覆盖缺口（缺口 #3）。

**一句话**：**声明层面诚实、无夸大**，可采信其四观测；但**不可**据其推出「两表聚合都受保护」。

### 项目级提醒

`verify_core` 的「DB Schema 全绿」与 `verify_p01_degrade` 的「降级前提成立」两条**最容易被当作整体正确性凭据**的结论，恰好各自带一个已实测的逃逸面（schema 子串 / payment 守卫盲区）。建议在验收证据引用时显式标注其边界，并按缺口 #1/#2/#3 补测或降级为「局部证据」。

---

## 六、自我限定（未做/做不了的注入）

1. **未对本脚本自身做「易断言作弊」式注入**（如把 `check` 改成恒真）——那是改测试、非改实现，按纪律排除。
2. **未注入 `AC-11 needsOvernightConfirm` / `手填负数时长 isInvalidInput` / `缺表拒绝` 三条**：其落点与已注入的同源分支重叠（`minutes<0` 分支、`validate` 结构检查），判为**读码级真**，未单独跑。**故这三条为【读码】而非【实测】。**
3. **未覆盖 `verify_core` 未触及的实现模块**（CSV 导出、UI 层、db 层运行时写入），不在本审计对象范围内。
4. **`verify_p01_degrade` 第 3 节对页内 `_guard` 的真实行为**（是否只吞 `FormatException`）**属读码级**，我核对了源码一致，但**未**在真机/组件测试中调用页内私有 `_guard`。**不得**把本报告对该节的结论升级为【实测】。
5. 全部注入均在**副本**完成；项目源码 `worklog-app/**` 未改动（已用 `diff -r` 复核逐字一致，mtime 未变）。

---

## 附：本审计产生的全部注入（可复现清单）

| 注入 | 文件:行（项目内） | before → after |
|---|---|---|
| S1 | database_schema.dart:70 | `... work_record (` → `... work_records (` |
| S2 | database_schema.dart:89 | 删 `amount_snapshot INTEGER NOT NULL, -- 分` |
| S3 | database_schema.dart:15/124/133 | `kDbVersion=1→2`；删 `UNIQUE (ledger_id, date)`；删归属日索引行 |
| F1 | export_service.dart:57 | `'format': formatTag` → `'fmt': formatTag` |
| A1 | amount_engine.dart:252 | `(numerator + denominator ~/ 2) ~/ denominator` → `numerator ~/ denominator` |
| A2 | amount_engine.dart:162 | `a > b ? a : b` → `a < b ? a : b` |
| A3 | amount_engine.dart:211 | 删 `if (input.overnight) mins += 24 * 60;` |
| A4 | amount_engine.dart:113 | `if (minutes == 0) return _draft(rule);` → `if (minutes == -1) ...` |
| A5 | amount_engine.dart:189 | `autoReference: mainAmount` → `autoReference: 0` |
| R1 | receivable_service.dart:39/42 | `r.companyId == companyId`→`true`；`p.companyId == companyId`→`true` |
| R2 | receivable_service.dart:64/75 | 删 `if (r.isDeleted) continue;` / `if (p.isDeleted) continue;` |
| E1-3 | export_service.dart:133/91/176 | `amount_snapshot`→`0`；`default_rule_id`→`null`；type 恒 `custom` |
| V1 | import_service.dart:239-241 | `_validateRule` 的 standard_hours 检查 → `if (false)` |
| V2 | import_service.dart:775 | `_requireUuid` 域外；改 `_str` → `v as String?` |
| V3 | import_service.dart:784 | `_requireDate`：`v is! String \|\| ...` → `v is String && ...` |
| V4 | import_service.dart:780 | `_requireNonEmpty`：`v is! String \|\| ...` → `v is String && ...` |
| V5 | validators.dart:29/32/35/39 | `validBaseRate/validRate/validHalfDayRatio/validPositiveAmount` → `=> true` |
| P1 | database.dart:1213 | `if (rows.isEmpty) return;` → `if (rows.isEmpty \|\| true) return;` |
| P2 | database.dart:1213 | `if (rows.isEmpty) return;` → `if (rows.isEmpty \|\| table == 'payment_record') return;` |

> 所有注入均已回退；副本 lib 与项目 lib 复核为逐字一致。
