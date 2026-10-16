# 独立审计报告 · `verify_waveB.dart` / `verify_waveD1.dart` 断言强度（变异测试）

- 审计官：`audit-bd1`（独立，未参与两脚本编写）
- 任务性质：**证伪** —— 证明脚本「全绿」是否等于「实现正确」
- 审计日期：2026-10-16
- 审计对象：
  - `worklog-app/app/tool/verify_waveB.dart`（734 行，76 条断言）
  - `worklog-app/app/tool/verify_waveD1.dart`（734 行，65 条断言）
- 硬约束遵守：**未修改 / 新建 / 删除 `worklog-app/**` 下任何文件**；未使用任何删除命令；全部注入均在副本 `_scratch/audit-bd1/appcopy/**` 内完成，注入后逐次 `cp` 原文件还原。

---

## 0. 结论摘要（先读这一段）

| 脚本 | 基线 | 假覆盖（改坏仍绿）实测条数 | 覆盖缺口 | 可信度评级 |
|---|---|---|---|---|
| `verify_waveB.dart` | 76 通过 / 0 失败 | **4 条**（⑩ / ⑭ / ⑮ / ⑲） | 6 项 | **中**（行为层 §1–§3 强；静态层 §5 有明确单点逃逸） |
| `verify_waveD1.dart` | 65 通过 / 0 失败 | **5 条**（A1b / A2 / D1B-2b·2c 补集 / D1B-3b / D1B-7） | 7 项 | **中偏低**（行为层 B1–B10 强；静态层 A1~A12 / D1B-* 与「页面真实逻辑」之间存在系统性缺口） |

**一句话总结**：两脚本的**行为层（真跑 DB + 真实体）是真断言，可置红**；但两脚本的**静态层（读源码 + `contains`）在「页面真实业务分支」上大面积失效** —— 只要某字面量在**文件里任意位置**（含 doc 注释）出现过 ≥1 次，对应断言就永久为绿。`verify_waveD1` 经 `impl-d1c` 加固的 `D1B-2b/2c`、`D1B-4b` **确实能抓住"某分支取值写反"（实测置红）**，但**抓不住"取值来源算错"（工作日期传错）与"分支路由写反"（新建/编辑走错、排序口径反转）**。

**最关键的两条**（详见 §3）：
- `verify_waveD1` 里 **P09 规则编辑页「写库双分支」路由 + 三档倍率字段映射，全程零有效断言**：把 `updatePricingRule` 与 `upsertPricingRule` 对调、把 `weekendRate` 改读「节假日」输入框，脚本仍 **65/0 全绿**。
- `verify_waveB` 里 **`calendar_page.dart:93` 的 `includeDraft: false` 是"注释救活"的**：把代码改成 `true`，脚本仍 **76/0 全绿**（因为 `calendar_page.dart:12` 与 `:78` 的 doc 注释里就写着 `includeDraft: false`）。

---

## 1. 基线与方法

### 1.1 环境（照抄主理人，不另下 SDK）

```bash
DART="D:/workspace/software/installed/tools/FlyEnv-Data/app/flutter/3.47.4/bin/cache/dart-sdk/bin/dart.exe"
APP="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/worklog-app/app"
WORK="C:/Users/ZDX/WorkBuddy/2026-09-30-11-23-00/_scratch/audit-bd1"
```

### 1.2 副本方案（实测可行，`worklog-app/**` 只读）

```bash
mkdir -p "$WORK/appcopy/tool"
cp -r "$APP/lib" "$WORK/appcopy/lib"
cp -r "$APP/.dart_tool" "$WORK/appcopy/.dart_tool"
cp "$APP/pubspec.yaml" "$APP/pubspec.lock" "$WORK/appcopy/"
cp "$APP/tool/verify_waveB.dart" "$APP/tool/verify_waveD1.dart" "$WORK/appcopy/tool/"
cd "$WORK/appcopy" && export WORKLOG_USE_SYSTEM_SQLITE=1 && "$DART" --disable-dart-dev tool/verify_waveB.dart
```

- 两脚本所有输入路径均为**相对路径**（`lib/...`），故副本内 `../lib/` 自动指向副本；`package_config.json` 的 `worklog_app -> ../` 与第三方包 rootUri（pub cache 绝对路径）不受影响 —— **实测确认**。
- **A10a 的 sha256 断言在副本内初始为绿**（`lib/` 原样复制 ⇒ 字节一致）⇒ 副本方案不构成对 sha256 断言的干扰。**该项"副本局限"排除。**

### 1.3 基线（实测）

| 脚本 | 命令 | 结果 |
|---|---|---|
| `verify_waveB.dart` | `"$DART" --disable-dart-dev tool/verify_waveB.dart` | **76 通过 / 0 失败**（与派单基线一致） |
| `verify_waveD1.dart` | `"$DART" --disable-dart-dev tool/verify_waveD1.dart` | **65 通过 / 0 失败**（与派单基线一致） |

> 基线一致 ⇒ 副本 == 原项目行为，后续注入结论可直接外推到原项目。

### 1.4 断言 API（读码 + 实测确认）

| 脚本 | 断言函数 | 计数 | 末尾统计 |
|---|---|---|---|
| `verify_waveB.dart:65` | `check(name, bool, [detail])` | `_pass` / `_fail` | `结果：$_pass 通过 / $_fail 失败`；`_fail>0 → exit(1)` |
| `verify_waveD1.dart:87` | `_check(bool, label, detail)`（`_ok`/`_bad` 计数） | `_pass` / `_fail` | 同上 |

判据（本项目「第 10 类教训」）：
- **置红律**：把实现改坏 ⇒ 断言必须变红。仍绿 = 假覆盖。
- **单点归因**：注入点须收敛到「某文件某行」。
- **层级分离 A≠B**：本报告凡标【实测】者，均为「改副本 → 重跑 → 观察红/绿」；【读码】者仅为源码阅读推断，二者不混用。
- **归档要求**：注入 before/after 逐字 + 复现命令均在 §3 给出。

---

## 2. 逐条断言判定表

分类口径：
- **A 类·真运行时断言**：真跑代码、比较返回值 / DB 终态 → 天然强。
- **B 类·静态文本断言**：读源码 + `contains` / 正则 → **高风险**（整文件匹配 ⇒ 单点逃逸）。
- **C 类·计数断言**：数某模式出现次数 → 高风险。
- **D 类·存在性断言**：只查文件 / 符号存在 → 弱。
- **E 类·哈希断言**：sha256 → 能置红，但**置红原因未必是"行为错了"**（单列，见 §4）。

判定列：**【实测】真** = 注入破坏后实测变红；**【实测】假** = 注入破坏后实测仍绿；**【读码】** = 未注入，仅据源码结构推断（**不得当作实测**）。

### 2.1 `verify_waveB.dart`（76 条）

#### §1 P03 日历日期口径（9 条，实测级行为层）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| §1① 日历查询(includeDraft:false)=4 条 | A | 【实测】真 | 注入 `database.dart:1263` `if (!includeDraft)`→`if (includeDraft)` ⇒ ✗① |
| §1② 4 条中不含 draft | A | 【实测】真 | 同上 ⇒ ✗② |
| §1③ 含 settled（唯一 1 条） | A | 【读码】真 | 同族查询，未单独注入（③ 依赖 status 列读取） |
| §1④ 月有效合计=200000 | A | 【实测】真 | 同 ① 注入 ⇒ ✗④（实际 1199999） |
| §1⑤ 10-05 有效=3 条、小计 180000 | A | 【实测】真 | 同 ① 注入 ⇒ ✗⑤ |
| §1⑥ 跨夜 w5 归「开始日」10-05 | A | 【读码】**弱** | 见 §5 缺口 G-5：断言只查"种子 workDate=10-05 的行落在 10-05"，**未验证任何归属日推导**（seed 硬编码） |
| §1⑦ w5 不出现在 10-06 | A | 【读码】**弱** | 同 ⑥（同族） |
| §1⑧ 对照组 includeDraft:true → 5 条 | A | 【实测】真 | 同 ① 注入 ⇒ ✗⑧ |
| §1⑨ 10-05 distinct 公司=2 | A | 【读码】真 | 依赖查询结果集，与 ① 同源 |

#### §2 P04 日详情分组数据前提（11 条，实测级行为层）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| §2① 容错读无坏行 | A | 【读码】真 | 依赖 `listWorkRecordsLenient` |
| §2② 10-05 含草稿=4 条 | A | 【实测】真 | 同 §1 注入 ⇒ ✗② |
| §2③ 分组数=2 | A | 【读码】真 | 复刻分组，与查询结果同源 |
| §2④ A 组 3 条 | A | 【实测】真 | 同 §1 注入 ⇒ ✗④ |
| §2⑤ A 组按 createdAt 升序 | A | 【读码】真 | 断言体自带 sort，属"复刻体自证"（非页面） |
| §2⑥ B 组 1 条 | A | 【读码】真 | 同族 |
| §2⑦ A 组小计=130000 | A | 【读码】真 | 同族 |
| §2⑧ B 组小计=50000 | A | 【读码】真 | 同族 |
| §2⑨ 当日合计==Σ各组小计 | A | 【读码】**自反式弱断言** | 两边都由复刻体算出，恒等；不构成对页面 `_dayTotal` 的证据 |
| §2⑩ 当日合计=180000 | A | 【读码】真 | 同族 |
| §2⑪ 草稿条数=1 | A | 【读码】真 | 同族 |

#### §3 P05 快照护栏数据层前提（24 条，实测级行为层）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| §3① 改 Meta：attribution_date 已变 | A | 【读码】真 | DB 回读 |
| §3② 改 Meta：amountSnapshot 不变 | A | 【读码】真 | DB 回读（有 DB 内置 `_assertSnapshotUnchanged` 护栏，见 §5 缺口 G-6） |
| §3③ 改 Meta：rateSnapshot 不变 | A | 【读码】真 | 同上 |
| §3④ 改 Meta：appliedRate 不变 | A | 【读码】真 | 同上 |
| §3⑤ 改 Meta：autoReferenceAmount 不变 | A | 【读码】真 | 同上 |
| §3⑥ 改 Meta：status 已置 settled | A | 【读码】真 | 同上 |
| §3⑦ 不存在 id 抛错 | A | 【读码】真 | try/catch 观察 |
| §3⑧ 传全：unit_price_snapshot=7000 | A | 【读码】真 | 原生列回读 |
| §3⑨ 传全：quantity_unit_snapshot=趟 | A | 【读码】真 | 同上 |
| §3⑩ 传全：start/end 保留 | A | 【读码】真 | 同上 |
| §3⑪ 传全：auto_reference=555 | A | 【读码】真 | 同上 |
| §3⑫ 不改 attribution_date | A | 【读码】真 | 同上 |
| §3⑬ 不改 note/status | A | 【读码】真 | 同上 |
| §3⑭ 漏传：auto_reference 清空 | A | 【读码】真 | 同族，与 ⑮ 同机制 |
| §3⑮ 漏传：quantity_unit_snapshot 清空 | A | 【实测】真 | 注入 `database.dart:855` `qtyUnitSnapshot`→`qtyUnitSnapshot ?? current.qtyUnitSnapshot` ⇒ **✗⑮**（实际 `趟`） |
| §3⑯ 漏传：start/end 清空 | A | 【读码】真 | 同族 |
| §3⑰ 漏传：非空列 quantity 保留 | A | 【读码】真 | 同族 |
| §3⑱ 二次改 Meta：amountSnapshot 仍 14000 | A | 【读码】真 | DB 回读 |
| §3⑲ 软删 w1 → 有效读 3→2 | A | 【读码】真 | 计数对比 |
| C-01① draft 分支占位 appliedRate==10 | A | 【读码】真 | 真实 `AmountEngine` 返回值 |
| C-01② 占位 rateDetail 丢加班命中 | A | 【读码】真 | 同上 |
| C-01③ 草稿写回 rd → appliedRate 保全 15 | A | 【读码】真 | DB 回读 |
| C-01④ 草稿写回 rd → 加班上下文保全 | A | 【读码】真 | 同上 |
| C-01⑤ 反证：写回占位值 → 退化 | A | 【读码】**自反式** | 由脚本自己选值驱动，恒成立；**不读页面代码**（review-b 已认此点） |

#### §4 P05 重算「不读当前规则」+ 快照反推（7 条，复刻实测·限 hourly-manual）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| §4① 快照反推基础单价=6000 | A（复刻） | 【读码】真 | 复刻 `_roundDiv`；**未驱动页面** |
| §4② 快照重建重算 → 12000 | A（复刻） | 【读码】真 | 复刻体 |
| §4③ 快照重建重算 → source=auto | A（复刻） | 【读码】真 | 复刻体 |
| §4④ 现价已改：baseRate=9900 | A | 【读码】真 | DB 回读 |
| §4⑤ 改价后仍按快照重算 → 12000 | A（复刻） | 【读码】真 | 复刻体 |
| §4⑥ 反证：误读现价 → 19800 | A（复刻） | 【读码】**自反式** | 由复刻体自己构造，证明"两路径有别"，非页面证据 |
| §4⑦ 动作 B：source=manual 且 autoRef=12000 | A（复刻） | 【读码】真 | 复刻体 |

> §4 全部为**复刻实测**（脚本头注自认：`halfDayRatio: 5` / `name: '（快照重建）'` 硬编码，页面实际用 `_halfDayRatio(rec)` / `_ruleName ?? ''`）⇒ **不得**据此宣称页面重算正确。

#### §5 源码断言（25 条，读码级）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| §5① 结构存在 `_RecordDetailPageState` | D | 【读码】弱真 | 存在性；改名即红 |
| §5② 含 `_db.updateWorkRecordMeta(` | B/D | 【读码】弱真 | 存在性 |
| §5③ 含 `_db.replaceWorkRecordSnapshot(` | B/D | 【读码】弱真 | 存在性 |
| §5④ 含 `_db.updateWorkRecordMetaOn(txn,` | B/D | 【读码】弱真 | 存在性（**不验证保存流真走事务**） |
| §5⑤ 含 `_db.replaceWorkRecordSnapshotOn(` | B/D | 【读码】弱真 | 存在性 |
| §5⑥ 可空字段显式传全（4 个字面量） | B | 【读码】中 | 4 个精确字面量，交换源即红；但**不验证调用点是否真在保存流** |
| §5⑦ 含 `_db.softDeleteWorkRecord(` | D | 【读码】弱真 | 存在性 |
| §5⑧ 反推公式整行逐字 | B | 【读码】真 | 整行精确 |
| §5⑨ `_roundDiv` 实现逐字 | B | 【读码】真 | 整行精确 |
| §5⑩ 引擎重算 + `isOvertime: rd.overtime,` | B | **【实测】假** | 注入 `record_detail_page.dart:218` `isWeekend: rd.weekend,`→`isWeekend: rd.holiday,` ⇒ **仍 76/0**（只查 isOvertime） |
| §5⑪ 无浮点金额路径 | C | 【读码】中 | 正则黑名单，剥注释后扫描 |
| §5⑫ `_target()` 不含 `listPricingRules` | B | 【读码】中 | 局部切片 + 缺席判定；切片定位失败亦会红 |
| §5⑬ 用容错读 `_db.listWorkRecordsLenient(` | B | 【实测】真 | 注入 `calendar_page.dart:90` →`_db.listWorkRecords(` ⇒ **✗⑬**（注释里的 `listWorkRecordsLenient` 无 `_db.` 前缀，未救活） |
| §5⑭ 传 `includeDraft: false` | B | **【实测】假** | 注入 `calendar_page.dart:93` `false`→`true` ⇒ **仍 76/0**（`:12`/`:78` doc 注释含同一字面量救活；§5 **未剥注释**） |
| §5⑮ 传 `includeDisabled: true, includeDeleted: true` | B | **【实测】假** | 注入 `calendar_page.dart:95` 双 `true`→双 `false` ⇒ **仍 76/0**（`:80` 注释含同一字面量救活） |
| §5⑯ 色点补 alpha `Color(0xFF000000 | c)` | B | 【实测】真 | 注入 `calendar_page.dart:416` →`Color(c)` ⇒ **✗⑯** |
| §5⑰ 含 `_db.listHolidayMarks(` | D | 【读码】弱真 | 存在性 |
| §5⑱ 含 `_db.listWorkRecordsLenient(`（P04） | D | 【读码】弱真 | 存在性（**不验证页面真用它读**） |
| §5⑲ `status != RecordStatus.draft` | B | **【实测】假** | 注入 `day_detail_page.dart:128`（`_dayTotal` 过滤）`!=`→`==` ⇒ **仍 76/0**（`:301`/`:369` 同字面量救活） |
| §5⑳ 含 `_db.softDeleteWorkRecord(` | D | 【读码】弱真 | 存在性 |
| §5㉑ 分组按 `map.putIfAbsent(w.companyId,` | B/D | 【读码】弱真 | 存在性 |
| §5㉒ 含 `RecordDetailPage(id: id)` | D | 【读码】弱真 | 存在性 |
| §5㉓ C-01 页面级守卫（结构式：flags + `? rd :` + `rateDetail:` 唯一） | B+C | 【实测】真 | 注入 `record_detail_page.dart:233` 删 `|| r.needsOvernightConfirm` ⇒ **✗㉓**（且 waveD1 ✗A7） |
| §5㉔ `_rec?.autoReferenceAmount == null` | B/D | 【读码】弱真 | 存在性 |
| §5㉕ `(_saving || deleted) ? null : _pickDate` | B/D | 【读码】弱真 | 存在性 |

**§5 汇总**：实测 **3 真**（⑬/⑯/㉓）、**4 假**（⑩/⑭/⑮/⑲）、其余 18 条为存在性 / 整行精确 / 自反式，未逐条注入。

---

### 2.2 `verify_waveD1.dart`（65 条）

#### B 行为层（30 条，实测级）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| B1a 新建后 getPricingRule 命中 | A | 【读码】真 | DB 回读 |
| B1b holidayRate 写 30 读 30 | A | 【读码】真 | DB 回读 |
| B1c weekendRate 写 20 读 20 | A | 【读码】真 | DB 回读 |
| B1d baseRate 写 4000 读 4000 | A | 【读码】真 | DB 回读 |
| B2a 4000×8=32000 | A | 【读码】真 | 真实引擎 |
| B2b 改价后历史 wX.amountSnapshot 仍 32000 | A | 【读码】真 | DB 回读（红线确实被覆盖 ✓） |
| B2c 反证：改价后新建=40000≠32000 | A | 【读码】真 | 真实引擎 |
| B3a isHoliday:true → appliedRate==30 | A | **【实测】真** | 注入 `amount_engine.dart:160-161` 周末/节假日倍率互换 ⇒ **✗B3a** |
| B3b isHoliday:true → 96000 | A | **【实测】真** | 同上 ⇒ ✗B3b |
| B3c isHoliday:false → 10 | A | 【读码】真 | 同族 |
| B3d 反证：两值不同 | A | **【实测】真** | 同上 ⇒ ✗B3d |
| B4 自检 2026-10-03 为周六 | A | 【读码】真 | 日历常量自检 |
| B4a 周六 → isWeekend==true | A | **【实测】真** | 注入 `day_context.dart:44` `\|\|`→`&&` ⇒ **✗B4a** |
| B4b 周日 → isWeekend==true | A | **【实测】真** | 同上 ⇒ ✗B4b |
| B4c 周一 → isWeekend==false | A | 【读码】真 | 同上组 |
| B5a 未标记日 → isHoliday==false | A | **【实测】真** | 注入 `day_context.dart:58` `mark != null`→`mark == null` ⇒ **✗B5a** |
| B5b 标记后 → isHoliday==true | A | **【实测】真** | 同上 ⇒ ✗B5b |
| B5c 删标记后 → isHoliday==false | A | **【实测】真** | 同上 ⇒ ✗B5c |
| B6 前置：10-08 命中节假日且非周末 | A | **【实测】真** | 同上 ⇒ ✗B6 |
| B6a 标记节假日日 → 96000 | A | **【实测】真** | 同上 ⇒ ✗B6a；引擎互换注入亦 ⇒ ✗B6a |
| B6b 对照：未标记日 → 32000 | A | **【实测】真** | 同上 ⇒ ✗B6b |
| B7a 默认不含停用/归档 | A | 【读码】真 | DB 过滤口径 |
| B7b includeDisabled 含停用不含归档 | A | 【读码】真 | 同族 |
| B7c includeDeleted 含归档 | A | 【读码】真 | 同族（对照组） |
| B8a 数量 0 → isDraft 且 amount==0 | A | 【读码】真 | 真实引擎 |
| B8b 草稿落库 status==draft 且 amount==0 | A | 【读码】**自构造** | 脚本**自建** `WorkRecord` 调 DB，**不读弹层**（脚本头注自认；review-d1b MAJ-2 已点名） |
| B9 非草稿分支 status==confirmed | A | 【读码】**自构造** | 同上 |
| B10a 标记节假日日 → 96000 | A | **【实测】真** | `day_context` 注入 + 引擎互换注入均 ⇒ ✗B10a |
| B10b 对照·未标记日 → 32000 | A | **【实测】真** | `day_context` 注入 ⇒ ✗B10b |
| B10c 反证：两日金额不同 | A | **【实测】真** | 引擎互换注入 ⇒ ✗B10c |

#### A 静态层（18 条）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| A1a `rule_edit_page.dart` 存在可读 | D | 【读码】恒真 | 文件交付后必过 |
| A1b 含 3 个方法名（upsert/update/softDelete） | B | **【实测】假** | 注入 `rule_edit_page.dart:221-224` 交换 `updatePricingRule`/`upsertPricingRule`（编辑↔新建走反）⇒ **仍 65/0** |
| A2 含 `holidayRate:`/`weekendRate:`/`overtimeRate:` 赋值 | B | **【实测】假** | 注入 `rule_edit_page.dart:349` `_parseRateX10(_wkCtrl.text)`→`_hdCtrl.text`（周末倍率读节假日输入框）⇒ **仍 65/0** |
| A3 含固定文案「取最高档，不叠加」 | B | 【实测】真 | 注入 `rule_edit_page.dart:545` 文案改字 ⇒ **✗A3** |
| A4 不含 `updateWorkRecord`/`replaceWorkRecordSnapshot` | B | 【读码】窄 | 只禁两个方法名；`upsertWorkRecord`/`replaceWorkRecordSnapshotOn`/`updateWorkRecordMeta` 均不在禁令内（见 §5 缺口 G-8） |
| A5a 不含占位文案 | B | 【读码】真 | 缺席判定 |
| A5b 含 `RuleEditPage(` | B/D | 【读码】弱真 | 存在性 |
| A6d `isWeekend:` 逐处 `== _dayCtx.isWeekend`（恰 4 处） | C | 【读码】中强 | 逐处取值 + 计数双约束（impl 加固）；**不验证传给 `resolveDayContext` 的日期**（见 §5 缺口 G-3） |
| A6e `isHoliday:` 逐处 `== _dayCtx.isHoliday`（恰 4 处） | C | 【读码】中强 | 同上 |
| A6c 含 `holidayRate:`（work_form_page） | B/D | 【读码】弱真 | 存在性 |
| A7 含 C-01 护栏三元式 | B | 【实测】真 | 注入 `record_detail_page.dart:233` 删 flag ⇒ **✗A7** |
| A8a `day_context.dart` 存在可读 | D | 【读码】恒真 | — |
| A8b 含 `weekday == DateTime.saturday` 与 `getHolidayMarkByDate(` | B | 【读码】中 | 两个字面量；`&&`/`\|\|` 反转不在其内（**但被 B4 行为层抓住**，见 §3 D1-C） |
| A9a 新增文件剥注释后零禁浮点命中 | C | 【读码】中 | 正则黑名单 + 剥注释 |
| A10 前置 bootstrap 可读 | D | 【读码】恒真 | — |
| **A10a** bootstrap sha256 == 冻结基线 | **E** | **【实测】真（性质特殊）** | 见 §4 专章 |
| A11 lib/ 内死路由 0 命中 | C | **【实测】真（过敏感）** | 注入 `about_page.dart` **仅追加一句注释** `// ... pushNamed(Routes.records)` ⇒ **✗A11**（`_fileTreeContains` **不剥注释**，见 §4） |
| A12 work_form_page 不含陈旧口径 | B | 【读码】真 | 缺席判定 |

#### D1B 下批补交付静态层（17 条）

| 断言 | 类 | 判定 | 依据 |
|---|---|---|---|
| D1B-1a `quick_add_sheet.dart` 存在可读 | D | 【读码】恒真 | — |
| D1B-1b 含 `showModalBottomSheet` | B/D | 【读码】弱真 | 存在性 |
| D1B-2a ★ 含 `resolveDayContext(` | B/D | 【读码】弱真 | 存在性 |
| D1B-2b ★ `isWeekend:` 逐处 `== ctx.isWeekend`（恰 3 处） | C | 【读码】中强 | impl-d1c 加固；**"取值来源算错"仍逃逸**（§3 实测 D1-quickadd） |
| D1B-2c ★ `isHoliday:` 逐处 `== ctx.isHoliday`（恰 3 处） | C | **【实测】真** | 注入 `quick_add_sheet.dart:254` `ctx.isHoliday`→`ctx.isWeekend` ⇒ **✗D1B-2c** |
| D1B-3a 含 `listWorkRecords()` | B/D | 【读码】弱真 | 存在性 |
| D1B-3b 取 `recent.first` | B | **【实测】假** | 注入 `database.dart:1272` ORDER BY `DESC`→`ASC`（"最近一条"变"最早一条"）⇒ **仍 65/0**（两脚本皆 0 红）；断言只查字面量存在 |
| D1B-3c 默认值取 `last?.companyId`/`pricingRuleId`/`qtySnapshot` | B | 【读码】弱 | 存在性（3 个字面量） |
| D1B-4 含 `RecordStatus.draft` + 草稿文案 | B | 【读码】弱真 | 存在性 |
| D1B-4b ★ status 三元式**顺序精确** | B+C | 【实测】真 | 注入 `quick_add_sheet.dart:343` 两分支对调 ⇒ **✗D1B-4b** |
| D1B-5a 不含名称校验 SnackBar | B | 【读码】中 | 精确字面量缺席 |
| D1B-5b 含 `errorText: _nameError` + 文案 | B | 【读码】中 | 两字面量（唯一出现，无注释干扰） |
| D1B-5c `canSave ? _submit : null` 置灰 | B | 【读码】中 | 精确字面量（唯一出现） |
| D1B-6 联系方式**先于** `widget.showEnabled` | B+C | **【实测】真** | 把真实控件移入 `if (widget.showEnabled)` 门控 ⇒ **✗D1B-6**（`_stripComments` 有效 ⇒ 注释无法救活） |
| D1B-7 不含 `AppState.ledgerId ?? ''` | B | **【实测】假** | 注入 `company_page.dart:174` `AppState.ledgerId`→`AppState.ledgerId ?? ""`（**双引号变体**）⇒ **仍 65/0**，且 `if (ledgerId == null)` 沦为死代码 ⇒ 空账本 id 被写入 |
| D1B-8a 调色板 12 色 | C | 【读码】中 | 正则计数（`0xRRGGBB` 计数；**注释内十六进制可干扰**见 §5 缺口 G-7） |
| D1B-8b 已用色轮转（含 `!used.contains(` 且不含 `_companies.length %`） | B+C | 【读码】中 | 双条件 |

---

## 3. 假覆盖清单（核心 · 每条可复现）

> 复现通用前置：按 §1.2 建副本 `$WORK/appcopy`；下述注入后 `cd "$WORK/appcopy" && export WORKLOG_USE_SYSTEM_SQLITE=1 && "$DART" --disable-dart-dev tool/<脚本>`。
> 所有注入**只改副本**，跑完即 `cp` 原文件还原。

### 假覆盖 F1 — `verify_waveB` §5⑭：`calendar_page.dart` 日历口径（代码改坏，注释救活）★最严重

- 落点：`lib/ui/calendar_page.dart:93`
- before：`          includeDraft: false, // 草稿不计入（AC-32 / AC-P03-04）`
- after ：`          includeDraft: true, // 草稿不计入（AC-32 / AC-P03-04）`
- 语义：日历把草稿计入色点/当日小计 ⇒ 违反 AC-32 / AC-P03-04。
- 重跑：`结果：76 通过 / 0 失败`
- 根因：`verify_waveB.dart:683` `p03.contains('includeDraft: false')`，而 **`calendar_page.dart:12` 与 `:78` 的 doc 注释里同样含 `includeDraft: false`** ⇒ 断言被注释救活。§5 对 `p03`/`p04` **未剥注释**（仅 `p05Code` 剥）。

### 假覆盖 F2 — `verify_waveB` §5⑮：公司元数据双 true（同类，注释救活）

- 落点：`lib/ui/calendar_page.dart:95`
- before：`        _db.listCompanies(includeDisabled: true, includeDeleted: true),`
- after ：`        _db.listCompanies(includeDisabled: false, includeDeleted: false),`
- 语义：停用 / 已归档公司在日历色点与名称上"消失" ⇒ 历史记录显示错误公司名。
- 重跑：`结果：76 通过 / 0 失败`
- 根因：`:80` 注释含同一字面量 ⇒ 救活。

### 假覆盖 F3 — `verify_waveB` §5⑲：`day_detail_page` 草稿过滤（他处字面量救活）

- 落点：`lib/ui/day_detail_page.dart:128`（`_dayTotal` 的过滤条件）
- before：`      .where((w) => w.status != RecordStatus.draft)`
- after ：`      .where((w) => w.status == RecordStatus.draft)`
- 语义：日详情「当日合计」变成只累加草稿 ⇒ 与页面显示的明细完全对不上。
- 重跑：`结果：76 通过 / 0 失败`
- 根因：`:301`、`:369` 仍含 `status != RecordStatus.draft` ⇒ `contains` 命中。

### 假覆盖 F4 — `verify_waveB` §5⑩：P05 重算 D 接线单点逃逸

- 落点：`lib/ui/record_detail_page.dart:218`
- before：`        isWeekend: rd.weekend,`
- after ：`        isWeekend: rd.holiday,`
- 语义：P05 重算时用"节假日命中"当"周末命中"喂引擎 ⇒ 重算金额错。
- 重跑：`结果：76 通过 / 0 失败`
- 根因：⑩ 只断言 `contains('isOvertime: rd.overtime,')`，**不查 `isWeekend:`/`isHoliday:` 取值**；§4 用**复刻体**，不驱动页面。

### 假覆盖 F5 — `verify_waveD1` A1b：P09 写库双分支路由对调

- 落点：`lib/ui/rule_edit_page.dart:221-225`
- before：
  ```dart
  if (_isEdit) {
    await _db.updatePricingRule(rule); // 编辑：复用原 id
  } else {
    await _db.upsertPricingRule(rule); // 新建：newId('rule')
  }
  ```
- after ：
  ```dart
  if (_isEdit) {
    await _db.upsertPricingRule(rule);
  } else {
    await _db.updatePricingRule(rule);
  }
  ```
- 语义：编辑走插入（丢 `createdAt` 原 id 语义）、新建走"按 id 更新"（对不存在 id 抛错 → 新建永远失败）。
- 重跑：`结果：65 通过 / 0 失败`
- 根因：A1b 只断言**三个方法名各出现 ≥1 次**，**不验证分支路由**。全脚本无任何断言读取 `rule_edit_page` 的 `_isEdit` 分支。

### 假覆盖 F6 — `verify_waveD1` A2：P09 三档倍率**字段映射**串线

- 落点：`lib/ui/rule_edit_page.dart:349`
- before：`      weekendRate: _parseRateX10(_wkCtrl.text) ?? 10,`
- after ：`      weekendRate: _parseRateX10(_hdCtrl.text) ?? 10,`
- 语义：周末倍率被"节假日倍率"输入框的值覆盖写入 ⇒ 用户设的周末倍率静默丢失/错存。
- 重跑：`结果：65 通过 / 0 失败`
- 根因：A2 只断言字段名 `holidayRate:`/`weekendRate:`/`overtimeRate:` 出现，**不验证每个字段读到哪个控制器**。

### 假覆盖 F7 — `verify_waveD1` D1B-3b：`listWorkRecords` 排序口径反转

- 落点：`lib/db/database.dart:1272`
- before：`      orderBy: 'attribution_date DESC, created_at DESC',`
- after ：`      orderBy: 'attribution_date ASC, created_at ASC',`
- 语义：`listWorkRecords()` 首条由"最近一条"变"最早一条" ⇒ 快记弹层「上次记录」默认值取到最旧的记录（AC-P02-02 失效）。
- 重跑：`verify_waveD1 → 65/0`；`verify_waveB → 76/0`（两脚本皆 0 红）
- 根因：D1B-3b 只断言源码含 `recent.first` 字面量，不验证底层排序；两脚本行为层均无 work_record 排序断言。

### 假覆盖 F8 — `verify_waveD1` D1B-2b/2c 补集：`resolveDayContext` 日期传错

- 落点：`lib/ui/quick_add_sheet.dart:172`
- before：`          ctx = await resolveDayContext(ledgerId: ledgerId, workDate: _workDate);`
- after ：`          ctx = await resolveDayContext(ledgerId: ledgerId, workDate: DateTime.now());`
- 语义：弹层的周末/节假日上下文按"今天"而非"本条记录日期"判定 ⇒ 周末/节假日倍率整体错档。
- 重跑：`结果：65 通过 / 0 失败`
- 根因：D1B-2b/2c 只校验**取值表达式** `ctx.isWeekend`/`ctx.isHoliday`（加固后确实能抓"某分支写反"），**不校验 ctx 由哪个日期算出**；B 行为层直接调 `resolveDayContext`，不驱动弹层。`work_form_page`（A6d/A6e）同构存在同一缺口。

### 假覆盖 F9 — `verify_waveD1` D1B-7：`ledgerId` 兜底「引号变体」逃逸

- 落点：`lib/ui/company_page.dart:174`
- before：`    final ledgerId = AppState.ledgerId;`
- after ：`    final ledgerId = AppState.ledgerId ?? "";`
- 语义：账本未初始化时把**空串**当 ledgerId 写入新建公司（正是 AC-P08-09 要禁的行为），且紧随的 `if (ledgerId == null)` 沦为死代码（永假），"显式失败"分支失效。
- 重跑：`结果：65 通过 / 0 失败`
- 根因：D1B-7 = `!companyPage.contains("AppState.ledgerId ?? ''")`，**单引号字面量**匹配；双引号变体 `?? ""` 逃逸。

**假覆盖合计：9 条**（waveB 4 条：F1~F4；waveD1 5 条：F5~F9）。

---

## 4. E 类（哈希）与「过敏感」断言专项评估

派单要求：对 sha256 类断言**单独评估**，说明「它们能置红，但置红的原因未必是实现坏了」。实测结论如下。

### 4.1 A10a（`verify_waveD1.dart:587`）

```
sha256(lib/services/pricing_bootstrap.dart) == 62dfa1fe...88cce
```

**两个对照注入（同一断言、同一红）：**

| 注入 | 性质 | 结果 |
|---|---|---|
| `pricing_bootstrap.dart:30` `&& r.unit == unit` → `&& true`（**真实语义 bug**：复用规则时忽略单位） | 行为破坏 | **✗A10a**（64/1） |
| `pricing_bootstrap.dart` 末尾**仅追加一行注释**（无任何行为影响） | 语义无害 | **✗A10a**（64/1），输出**逐字相同** |

**判定**：
- A10a 验证的是「**文件字节未变**」，**不是「行为正确」**。它**无法区分**"实现被改坏"与"实现被改好/仅加注释/仅格式化"—— 三者产生**完全相同的红**。
- 因此 A10a 作为**验收凭据**时，其"全绿"只能说明"该文件未被触碰"，**不能**说明"该文件行为正确"。`pricing_bootstrap.dart` 的**行为正确性在本脚本内零覆盖**（全脚本无任何断言调用 `ensureRule`）。
- 另：冻结哈希本身是一项**设计意图**（`16 §D1-d 定案 A`：本批不许改 bootstrap）。作为**变更看门狗**是合理的；作为**质量证据**是不可用的。
- **附带风险**：任何**正当**的后续改动（修 bug、加注释、换行符）都会误报红 ⇒ 属"过敏感 + 无法归因"。

### 4.2 A11（`verify_waveD1.dart:598`，`_fileTreeContains`）

- 注入：仅在 `lib/ui/about_page.dart` 末尾**追加一句注释** `// ... pushNamed(Routes.records)` ⇒ **✗A11**（64/1）。
- 判定：`_fileTreeContains` 读**原始字节**（`:725` `e.readAsStringSync().contains(needle)`），**不剥注释、不解析 AST**。
  - **过敏感**：注释/文档里出现该字串即误红（本项实测）。
  - **同时**：真实死路由若被格式化（`pushNamed( Routes.records )`）或用变量中转，则**逃逸**。
- 与 A10a 同属"能置红，但置红原因 ≠ 行为错"的一类。**单列，不与其他断言混算。**

### 4.3 C 类"计数/存在性"余留风险（读码级，未注入）

- `D1B-8a`：`RegExp(r'_kPalette\s*=\s*<int>\[(.*?)\];', dotAll: true)` 非贪婪截到第一个 `];`，再数 `0x[0-9A-Fa-f]{6}`。若在调色板块内**加入含十六进制色值的注释**即可虚增计数（或删真色 + 加注释色值以维持 12）。**【读码】未实测**。
- `A9a` / `§5⑪` 浮点黑名单：正则黑名单天然可绕过（如 `(x) ~/ 10` 之外的等价写法、`0.5 * 2 * x`、`num.parse`）。**【读码】未实测**，不作为"假覆盖"计数，仅登记风险。

---

## 5. 覆盖缺口清单（声称覆盖但实际无有效断言）

| # | 缺口 | 声称位置 | 实测证据 | 级别 |
|---|---|---|---|---|
| G-1 | **P09 写库双分支路由**（新建 vs 编辑走哪个 API） | `verify_waveD1` 头注「D1-a」、A1b | F5：对调后 65/0 | 【实测】 |
| G-2 | **P09 三档倍率字段↔输入框映射** | `verify_waveD1` A2（AC-P09-02） | F6：串线后 65/0 | 【实测】 |
| G-3 | **日历 / 弹层 / 完整表单传入 `resolveDayContext` 的日期** | `verify_waveB` §5⑩⑭、`verify_waveD1` A6d/A6e/D1B-2b/2c | F8：传 `DateTime.now()` 后 65/0 | 【实测】 |
| G-4 | **`listWorkRecords()` 排序口径（决定"最近一条"）** | `verify_waveD1` D1B-3b | F7：DESC→ASC 后两脚本 0 红 | 【实测】 |
| G-5 | **AC-10 跨夜「归属日 = 开始日」的推导** | `verify_waveB` §1⑥⑦ | 断言只观察 seed 里**已硬编码** `workDate=10-05` 的行落在 10-05 —— 属**同义反复**；真正的推导在 `work_form_page`，两脚本均未驱动 | 【读码】 |
| G-6 | **`updateWorkRecordMeta` 快照护栏被移除** | `verify_waveB` §3②~⑤ | DB 内部 `database.dart:784 _assertSnapshotUnchanged` 会先抛错终止；**无法**在不改 `database.dart` 的前提下验证"§3② 自身"的置红能力（本轮未做双点注入，避免越界归因） | 【读码】 |
| G-7 | **调色板 12 色的"真实色数"** | `verify_waveD1` D1B-8a | 计数基于正则文本，注释可干扰（§4.3） | 【读码】 |
| G-8 | **P09「不触碰历史」红线（AC-P09-13）的完整面** | `verify_waveD1` A4 | A4 只禁 `updateWorkRecord` / `replaceWorkRecordSnapshot` 两个字符串；`upsertWorkRecord` / `replaceWorkRecordSnapshotOn` / `updateWorkRecordMeta` **不在禁令内** —— 用它们改写历史不会被 A4 抓到 | 【读码】 |
| G-9 | **`pricing_bootstrap.dart` 行为正确性** | `verify_waveD1` A10a | 全脚本无一处调用 `ensureRule`；仅哈希看门狗（§4.1） | 【实测】 |
| G-10 | **P05 页面真实保存流是否走事务分支** | `verify_waveB` §5④⑤ | 仅断言方法名字符串存在；不验证保存代码路径 | 【读码】 |
| G-11 | **P05 复刻体的等价性** | `verify_waveB` §4 | 脚本头注已自认硬编码 `halfDayRatio: 5` / `name:` ⇒ 页面 `_halfDayRatio(rec)` / `_ruleName` 分支未被驱动 | 【读码】 |

（G-1~G-4、G-9 有实测证据；G-5~G-8、G-10、G-11 为读码级判断，**不作为已证事实**。）

---

## 6. 结论与可信度评级

### 6.1 `verify_waveB.dart` —— 可信度 **中**

- **可信的部分（真断言，实测可置红）**：§1 / §2 / §3 行为层（7 条实测变红：① ② ④ ⑤ ⑧ / §2② ④ / §3⑮），§5 的 ⑬ ⑯ ㉓。
- **不可信的部分**：§5 静态层 —— ⑭ ⑮ 因 **doc 注释含同一字面量**而永久为绿（§5 **不剥注释**）；⑲ 因文件他处同字面量而永久为绿；⑩ 因只查 3 个字段中的 1 个而存在单点逃逸。
- **一句话**：**它的通过数里，行为层可信、静态层有 4 处已知假覆盖；"全绿"不能推出"P03/P04/P05 页面口径正确"。**

### 6.2 `verify_waveD1.dart` —— 可信度 **中偏低**

- **可信的部分（真断言，实测可置红）**：B 行为层（day_context / amount_engine / DB 过滤 共 13 条实测变红）、A3 / A7 / A11、`D1B-2c` / `D1B-4b` / `D1B-6`。
  - 特别确认：**`impl-d1c` 的加固是有效的** —— `D1B-2b/2c` 与 `D1B-4b` 实测能抓住"某一个 method 分支取值写反"与"status 两分支对调"（这正是 review-d1b MAJ-2 的两个"改坏仍全绿"场景，**已真实闭合**）。
- **不可信的部分（实测仍绿 5 处）**：A1b（写库分支路由）、A2（倍率字段映射）、D1B-3b（排序口径）、D1B-2b/2c 的"日期来源"面、D1B-7（引号变体）。
- **结构与行为的断层**：D1B-* / A1~A12 覆盖的 `rule_edit_page.dart` / `quick_add_sheet.dart` / `company_page.dart` **在 B 行为层中完全不被驱动**（B 层只驱动 `AppDatabase` + `AmountEngine` + `resolveDayContext`）⇒ **这几个页面的静态断言是它们的全部覆盖**，而静态断言只查字面量 ⇒ 页面真实分支逻辑处于"**形式上有断言、实质无覆盖**"状态。
- **一句话**：**"行为层真、静态层虚"**；经加固后能抓"取值写反"，但抓不住"路由写反 / 映射串线 / 日期来源错 / 排序口径反转 / 引号变体"。

### 6.3 对"全绿支撑验收"的直接回答

> **两脚本"全绿" ≠ "实现正确"。**
> - `verify_waveB`：**4 条已知假覆盖**（F1~F4）；
> - `verify_waveD1`：**5 条已知假覆盖**（F5~F9）；
> - 另有 **1 条 E 类哈希断言（A10a）**与 **1 条过敏感缺席断言（A11）** 能在"实现未坏"时也置红 ⇒ 其红/绿**均不能**作为行为证据；
> - **共 9 条假覆盖 + 9 项覆盖缺口**已被本审计以可复现注入坐实或读码登记。

---

## 7. 自我限定（哪些没做 / 不许猜）

**【实测】范围**：本报告凡标【实测】的判定，均按「副本内注入 → 重跑 → 观察红/绿」取得，注入点与 before/after 已逐字记录，命令可直接复现。

**【读码】范围（未注入，**不得当作实测**）**：
- `verify_waveB` §3 的 ①~⑭、⑯~⑲、C-01 五条：依赖同一 `database.dart` 机制，本轮仅注入 ⑮（`quantity_unit_snapshot` 漏传）与 includeDraft 反转作为该组的代表；其余据源码推断为真。
- `verify_waveB` §1③、§2①③⑤⑥⑦⑧⑨⑩⑪：未逐条注入。
- `verify_waveD1` B1 / B2 / B7 / B8 / B9：属 DB 读回类，未逐条注入（B8/B9 据脚本头注与源码确认为**自构造体**，已如实标注）。
- `verify_waveD1` A4 / A5 / A6c / A9a / A12 / D1B-1 / D1B-3a / 3c / 4 / 5a / 5b / 5c / 8a / 8b：仅读码，未注入。
- §4.3 的 C 类余留风险（D1B-8a 注释干扰、浮点黑名单绕过）：**仅读码登记，未实测**。

**未做的事（说明原因）**：
1. **未做"双点注入"**（如"移除 DB 内部 `_assertSnapshotUnchanged` 护栏 + 让 `updateWorkRecordMeta` 写金额"）来验证 §3② 自身置红律 —— 因为那会让"红"无法**单点归因**到脚本断言；如实降级为缺口 G-6。
2. **未注入 `work_form_page.dart` 的 `workDate` 传参错误**（与 F8 同构）—— 已用弹层同构点实测，避免重复同类证据；如需要可另跑。
3. **未修改 / 未新增 / 未删除 `worklog-app/**` 任何文件**；未使用任何删除命令；副本注入后均已 `cp` 原文件还原（副本当前即 §1.2 的干净拷贝）。

**证据分级纪律**：本报告中凡写「真 / 假」且标【实测】者，均有重跑输出为凭；凡标【读码】者，均为源码结构推断，**明确不构成实测**。—— 不把【读码级】判断说成【实测级】。

---

## 附：本轮注入全表（before → after → 结果）

| # | 文件:行 | before → after | 脚本 | 结果 |
|---|---|---|---|---|
| D1-A | `rule_edit_page.dart:349` | `_wkCtrl.text` → `_hdCtrl.text` | waveD1 | 65/0 **假** |
| D1-B | `rule_edit_page.dart:221-224` | update↔upsert 对调 | waveD1 | 65/0 **假** |
| D1-C | `day_context.dart:44` | `\|\|` → `&&` | waveD1 | 63/2 真（B4a/B4b） |
| D1-D | `day_context.dart:58` | `mark != null` → `mark == null` | waveD1 | 57/8 真 |
| D1-E | `quick_add_sheet.dart:254` | `ctx.isHoliday` → `ctx.isWeekend` | waveD1 | 64/1 真（D1B-2c） |
| D1-F | `quick_add_sheet.dart:343` | status 三元式对调 | waveD1 | 64/1 真（D1B-4b） |
| D1-G | `amount_engine.dart:160-161` | 周末/节假日倍率互换 | waveD1 / waveB | 59/6 真 / 76/0 |
| D1-H1 | `pricing_bootstrap.dart:30` | `&& r.unit == unit` → `&& true` | waveD1 | 64/1 真（A10a，E 类） |
| D1-H2 | `pricing_bootstrap.dart` 尾 | 追加注释 | waveD1 | 64/1 **同一条红**（E 类） |
| D1-quickadd | `quick_add_sheet.dart:172` | `workDate: _workDate` → `DateTime.now()` | waveD1 | 65/0 **假** |
| D1B-7 | `company_page.dart:174` | `AppState.ledgerId` → `?? ""` | waveD1 | 65/0 **假** |
| A3 | `rule_edit_page.dart:545` | 文案改字 | waveD1 | 64/1 真（A3） |
| A11 | `about_page.dart` 尾 | 追加含死路由字串的**注释** | waveD1 | 64/1 真（A11，过敏感） |
| D1B-6 | `company_page.dart:800-803/812` | 联系方式控件移入 `showEnabled` 门控 | waveD1 | 64/1 真（D1B-6） |
| B-A | `calendar_page.dart:93` | `includeDraft: false` → `true` | waveB | 76/0 **假** |
| B-B | `day_detail_page.dart:128` | `!=` → `==` | waveB | 76/0 **假** |
| B-C | `calendar_page.dart:416` | `Color(0xFF000000 \| c)` → `Color(c)` | waveB | 75/1 真（⑯） |
| B-D | `record_detail_page.dart:233` | 删 `\|\| r.needsOvernightConfirm` | waveB / waveD1 | 75/1 真 / 64/1 真（A7） |
| B-E | `calendar_page.dart:90` | `listWorkRecordsLenient(` → `listWorkRecords(` | waveB | 75/1 真（⑬） |
| B-⑩ | `record_detail_page.dart:218` | `rd.weekend` → `rd.holiday` | waveB | 76/0 **假** |
| B-⑮ | `calendar_page.dart:95` | 双 `true` → 双 `false` | waveB | 76/0 **假** |
| B-F | `database.dart:1263` | `if (!includeDraft)` → `if (includeDraft)` | waveB | 7 红 真 |
| B-§3⑮ | `database.dart:855` | `qtyUnitSnapshot` → `?? current.qtyUnitSnapshot` | waveB | 75/1 真（⑮） |
| B-orderBy | `database.dart:1272` | `DESC` → `ASC` | waveB / waveD1 | 76/0 · 65/0 **假** |

---

*报告结束 · audit-bd1 · 2026-10-16*
