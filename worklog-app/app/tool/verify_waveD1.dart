/// Wave D1（录入与规则 · 核心链路闭合）自验证脚本 —— **静态断言层 + DB 行为层**。
///
/// **证据层级三分（DECISIONS D-8）—— 先读本段，不要误读下面的输出**：
///
/// 【实测级 / 强证据】§B（行为层，`B1~B7`）：
///   全部走**真实 `AppDatabase`（内存库）** + **真实 `AmountEngine`（`const AmountEngine()`）**
///   + **真实 `resolveDayContext`（`lib/services/day_context.dart`，非复刻）**：
///   · B1 规则写 30 读 30（写/读列闭环，证 `database.dart` 无断点）；
///   · B2 `updatePricingRule` 改基础单价 → **历史工作记录金额快照不变**（AC-P09-07 评审红线）；
///   · B3 同一规则 `isHoliday:true` → `appliedRate==30`、`isHoliday:false` → `10`（**反证：两值不同 ⇒ 非恒真**）；
///   · B4 `resolveDayContext` 周六/周日 → `isWeekend==true`，周一 → `false`；
///   · B5 `holiday_mark` 增/删 → `isHoliday` 真值随之翻转（**反证：可被变更证伪**）；
///   · B6 端到端：`resolveDayContext` 结果喂 `AmountInput`（仿 `work_form_page` 新路径）→ 真实引擎
///        → 标记节假日日 `96000`（3.0×）；未标记日 `32000`（1.0×）（**对照证明非恒真**）；
///   · B7 `listPricingRules` 默认不含停用/归档；`includeDisabled:true` 含停用、不含归档。
///   · B8/B9 **草稿/非草稿落库行为（⚠️ 脚本内自构造 `WorkRecord`）**：数量 0 → 落库
///     `status==draft` 且 `amountSnapshot==0`；数量 >0 → `status==confirmed`（**反证：两分支状态不同**）。
///     ⚠️ **`B8/B9` 不读弹层源码**，故**不构成对弹层 `status` 分支的证据**；弹层真实 `status`
///     三元式由 **`D1B-4b` 据源码精确断言**（review-d1b MAJ-2）。
///   · B10 **端到端（弹层同款输入：hourly `manualHours` + 真实 `resolveDayContext`）**：
///     标记节假日日 `96000`（3.0×）；未标记日 `32000`（1.0×）（**反证：两次必不同**）。
///
/// 【实测级 / 强证据】§A（静态层，`A1~A12` + 下批 `D1B-1~8`）：`File.readAsStringSync` 读 **真实源码**
///   （非复刻、非转述），剥离注释后正则断言（剥离：`(^|\s)//.*$`，multiLine；**整行 + 行尾都剥**）。
///   `D1B-*` 覆盖：弹层形态（`showModalBottomSheet`）/ ★ `resolveDayContext` + `isWeekend:`/`isHoliday:`
///   取值 / 默认值取自 `listWorkRecords()` 首条 / 草稿分支文案 / P08 名称内联红字+置灰 / `contact`
///   不被 `showEnabled` 门控 / `ledgerId` 无 `?? ''` / 12 色调色板 + 已用色轮转。
///
/// 【同构复刻 / 弱证据】B6 的「仿 `work_form_page._buildInput` 构造 `AmountInput`」：
///   `_buildInput` 是 `lib/ui/*` 的**私有**成员，脚本**拿不到**。此处**逐字段复刻**其 daily 分支的
///   `AmountInput(fullDay:, isOvertime:, isWeekend: _dayCtx.isWeekend, isHoliday: _dayCtx.isHoliday)`
///   构造形态（字段名与来源逐一对齐）。⚠️ 该「构造」是复刻；但**输入端的 `resolveDayContext`
///   与消费端的 `AmountEngine` 均为真实实体**，故断言对象（D → 引擎 → 金额）为真链。
///
/// 【本批范围声明 / 直读不要误判】本批 = **核心链路闭合**（D1-a / D1-b / D1-c / D1-d）
///   **∪ 下批补交付**（`16 §2.3` 的 **P02 秒级快记弹层 `quick_add_sheet.dart`** +
///   `16 §2.4` 的 **P08 收口 `company_page.dart`**）。
///   **A9 原文订正（review-d1b MIN-2）**：设计 `16 §3.6`（`16:562`）的 A9 原文 = 「新增两文件
///   （`rule_edit_page.dart` / **`quick_add_sheet.dart`**）剥注释后禁用模式零命中」——**本就把
///   `quick_add_sheet.dart` 列入**，并未写"留待下批/下批补跑"。本期因该文件**新交付**，故并入
///   A9a 的禁浮点全量扫描（见 A9a `newBatch`）。A9b 曾以"「下批须补跑 A9 全量」"为由改判为
///   "存在性断言"——该**理由失实**（`16` 全文「补跑」0 命中，A9 原文无此意），且 A9b 实为
///   「文件存在性」**恒真**、**不构成产品行为证据** ⇒ 本轮**从产品断言中剔除**（改为不计入
///   通过数的范围声明）。
///
/// 【不覆盖】页内交互 / 下拉切维 / 共存提示弹窗 / 归档二次确认渲染 / 三态视觉 —— 属 **[真机]** 档。
///
/// 运行（**必须两项齐全**）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// set WORKLOG_USE_SYSTEM_SQLITE=1
/// "...\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev --packages=.dart_tool/package_config.json tool\verify_waveD1.dart
/// ```
library;

import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/app/app_state.dart';
import '../lib/db/database.dart';
import '../lib/models/company.dart';
import '../lib/models/holiday_mark.dart';
import '../lib/models/ledger.dart';
import '../lib/models/pricing_rule.dart';
import '../lib/models/types.dart';
import '../lib/models/work_record.dart';
import '../lib/services/amount_engine.dart';
import '../lib/services/day_context.dart';

int _pass = 0;
int _fail = 0;

void _ok(String label) {
  _pass++;
  print('  [PASS] $label');
}

void _bad(String label, String detail) {
  _fail++;
  print('  [FAIL] $label');
  print('         -> $detail');
}

void _check(bool cond, String label, String detail) {
  if (cond) {
    _ok(label);
  } else {
    _bad(label, detail);
  }
}

// ── Windows 兜底：预加载系统 SQLite（与 tool/verify_db.dart 同源）───────────
void _maybePreloadSystemSqlite() {
  if (!Platform.isWindows) return;
  if (Platform.environment['WORKLOG_USE_SYSTEM_SQLITE'] != '1') return;
  for (final name in ['sqlite3.dll', 'winsqlite3.dll']) {
    try {
      DynamicLibrary.open(name);
      print('  · 已预加载系统 SQLite 动态库：$name');
      return;
    } catch (_) {
      // 继续尝试下一个
    }
  }
  print('  ! 未能预加载任何系统 SQLite 动态库');
}

// ── 静态断言层工具（读真实源码）────────────────────────────────────────────
String _read(String relPath) {
  final f = File(relPath);
  if (!f.existsSync()) return '';
  return f.readAsStringSync();
}

final RegExp _commentRe = RegExp(r'(^|\s)//.*$', multiLine: true);

String _stripComments(String src) => src.replaceAll(_commentRe, '');

/// 逐处提取 `<key>\s*:\s*([^,\n]+)` 的**实际取值**（已去首尾空白）。
/// 用于「单点逃逸」防线：`contains` 只看"存在 ≥1 处正确"，`count` 只看键出现次数，
/// 二者都无法抓住「某一个分支取值写反」。本函数把**每一处**取值列出来，逐一比对。
List<String> _extractValues(String code, String key) {
  final re = RegExp('$key\\s*:\\s*([^,\\n]+)');
  return [for (final m in re.allMatches(code)) m.group(1)!.trim()];
}

/// 浮点禁令：返回命中的模式名清单（已剥离注释）。
/// 与 `verify_waveC1.dart` 同款；`/ 10` 排除整数除法 `~/ 10`。
List<String> _floatViolations(String code) {
  final out = <String>[];
  final banned = <String, RegExp>{
    'fen/100': RegExp(r'fen\s*/\s*100'),
    'double.parse': RegExp(r'double\.parse'),
    '.round(': RegExp(r'\.round\s*\('),
    '.toDouble(': RegExp(r'\.toDouble\s*\('),
    '/100.0': RegExp(r'/\s*100\.0'),
  };
  banned.forEach((name, re) {
    if (re.hasMatch(code)) out.add(name);
  });
  final re10 = RegExp(r'/\s*10\b');
  for (final m in re10.allMatches(code)) {
    final before = m.start > 0 ? code[m.start - 1] : '';
    if (before != '~') {
      out.add('/10(float)');
      break;
    }
  }
  return out;
}

// ── 播种标识 ─────────────────────────────────────────────────────────────
const _ledgerId = 'd1000000-0000-4000-8000-000000000001';
const _cid = 'd1000000-0000-4000-8000-00000000000a';
final _t0 = DateTime(2026, 10, 1, 9, 0);

/// `pricing_bootstrap.dart` 设计冻结基线（sha256，2026-10-08 09:20 冻结前实测）。
const _pricingBootstrapSha =
    '62dfa1fe73423dae08a0060e8fa68fdbf992dcbde50e2e8f297b41d52d088cce';

/// 设计冻结时刻（`16 §0` 落盘 2026-10-08 09:14:16；派发冻结声明 09:20）。
final _freeze = DateTime(2026, 10, 8, 9, 20);

PricingRule _rule({
  required String id,
  required PricingMethod method,
  required int baseRate,
  String? unit,
  int halfDayRatio = 5,
  int overtimeRate = 15,
  int weekendRate = 10,
  int holidayRate = 10,
  bool enabled = true,
}) =>
    PricingRule(
      id: id,
      companyId: _cid,
      name: id,
      method: method,
      baseRate: baseRate,
      unit: unit,
      halfDayRatio: halfDayRatio,
      overtimeRate: overtimeRate,
      weekendRate: weekendRate,
      holidayRate: holidayRate,
      enabled: enabled,
      createdAt: _t0,
      updatedAt: _t0,
    );

Future<void> main() async {
  print('══════════════════════════════════════════════');
  print('Wave D1 · 录入与规则（核心链路闭合 ∪ 下批补交付） · 自验证');
  print('  静态层 A1~A12 + D1B-1~8（读真实源码） + 行为层 B1~B10（真实引擎/真实 DB）');
  print('══════════════════════════════════════════════');
  _maybePreloadSystemSqlite();
  sqfliteFfiInit();
  final db = AppDatabase.instance
    ..configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  await db.open();
  AppState.ledgerId = _ledgerId;

  await db.upsertLedger(Ledger(id: _ledgerId, name: '我的账本', createdAt: _t0));
  await db.upsertCompany(Company(
    id: _cid,
    ledgerId: _ledgerId,
    name: '甲建筑',
    color: 0xE53935,
    createdAt: _t0,
    updatedAt: _t0,
  ));

  await _behaviorLayer(db);

  await db.close();

  _staticLayer();

  print('\n──────────────────────────────────────────────');
  print('结果：$_pass 通过 / $_fail 失败');
  print('──────────────────────────────────────────────');
  print('【不覆盖】页内交互/下拉切维/共存弹窗/归档确认渲染/三态 → [真机] 档，本脚本不替代。');
  if (_fail > 0) exit(1);
}

// ══════════════════════════════════════════════════════════════════════════
// B. 行为层（真实引擎 + 真实 DB）—— 【实测级】
// ══════════════════════════════════════════════════════════════════════════

Future<void> _behaviorLayer(AppDatabase db) async {
  print('\n[B] 行为层（真实 AppDatabase 内存库 + 真实 AmountEngine + 真实 resolveDayContext）');

  // ── B1：规则写 30 读 30（写/读列闭环）───────────────────────────────────
  print('\n[B1] 规则倍率写/读闭环（证 pricing_rule 写读无断点）');
  await db.upsertPricingRule(
      _rule(id: 'ruleA', method: PricingMethod.hourly, baseRate: 4000, unit: '小时', holidayRate: 30, weekendRate: 20));
  final readA = await db.getPricingRule('ruleA');
  _check(readA != null, 'B1a 新建规则后 getPricingRule 命中', '结果 $readA');
  _check(readA!.holidayRate == 30,
      'B1b holidayRate 写 30 → 读 30（若 DB 丢字段会读到默认 10）', '实际 ${readA.holidayRate}');
  _check(readA.weekendRate == 20,
      'B1c weekendRate 写 20 → 读 20', '实际 ${readA.weekendRate}');
  _check(readA.baseRate == 4000, 'B1d baseRate 写 4000 → 读 4000（分，整数）', '实际 ${readA.baseRate}');

  // ── B2：改基础单价 ≠ 回改历史（AC-P09-07 评审红线）──────────────────────
  print('\n[B2] updatePricingRule 改价 → 历史快照不变（评审红线）');
  const hours8 = AmountInput(manualHours: 8, overnight: false, isOvertime: false);
  final resP1 = const AmountEngine().compute(rule: readA, input: hours8);
  _check(resP1.amount == 32000, 'B2a 基线：4000分/时 × 8h = 32000 分', '实际 ${resP1.amount}');
  await db.upsertWorkRecord(WorkRecord(
    id: 'wX',
    workDate: DateTime(2026, 10, 5),
    companyId: _cid,
    pricingRuleId: 'ruleA',
    methodSnapshot: readA.method,
    qtySnapshot: resP1.qty,
    qtyUnitSnapshot: readA.unit,
    rateSnapshot: resP1.actualRate,
    rateDetailSnapshot: resP1.rateDetail,
    amountSnapshot: resP1.amount,
    amountSource: resP1.source,
    status: RecordStatus.confirmed,
    createdAt: _t0,
    updatedAt: _t0,
  ));
  // 改基础单价 4000 → 5000（PricingRule 无 copyWith → 逐字段整对象）
  await db.updatePricingRule(_rule(
      id: 'ruleA', method: PricingMethod.hourly, baseRate: 5000, unit: '小时', holidayRate: 30, weekendRate: 20));
  final after = await db.getWorkRecord('wX');
  _check(after != null && after.amountSnapshot == 32000,
      'B2b 改价后历史 wX.amountSnapshot 仍为 32000（**不回改历史**）', '实际 ${after?.amountSnapshot}');
  final readA2 = (await db.getPricingRule('ruleA'))!;
  final resP2 = const AmountEngine().compute(rule: readA2, input: hours8);
  _check(resP2.amount == 40000,
      'B2c **反证**：改价后新建 → 5000分/时 × 8h = 40000 ≠ 历史 32000（非恒真）', '实际 ${resP2.amount}');

  // ── B3：isHoliday 分支（D1-c 闭环，含反证）──────────────────────────────
  print('\n[B3] 引擎 isHoliday 分支（同一规则，两个输入值必得两个不同倍率）');
  await db.upsertPricingRule(
      _rule(id: 'ruleB', method: PricingMethod.daily, baseRate: 32000, unit: '天', holidayRate: 30));
  final rB = (await db.getPricingRule('ruleB'))!;
  final onHoliday = const AmountEngine()
      .compute(rule: rB, input: const AmountInput(fullDay: true, isHoliday: true));
  final offHoliday = const AmountEngine()
      .compute(rule: rB, input: const AmountInput(fullDay: true, isHoliday: false));
  _check(onHoliday.rateDetail.appliedRate == 30,
      'B3a isHoliday:true → appliedRate == 30（取规则 holidayRate）', '实际 ${onHoliday.rateDetail.appliedRate}');
  _check(onHoliday.amount == 96000, 'B3b isHoliday:true → amount == 32000 × 3.0 = 96000', '实际 ${onHoliday.amount}');
  _check(offHoliday.rateDetail.appliedRate == 10,
      'B3c isHoliday:false → appliedRate == 10', '实际 ${offHoliday.rateDetail.appliedRate}');
  _check(onHoliday.rateDetail.appliedRate != offHoliday.rateDetail.appliedRate,
      'B3d **反证**：两输入的 appliedRate 不同 ⇒ 断言非恒真', '两者皆为 ${onHoliday.rateDetail.appliedRate}');

  // ── B4：周末口径（resolveDayContext，真实 DB 驱动）──────────────────────
  print('\n[B4] 周末口径（resolveDayContext：周六/周日 true，周一 false）');
  _check(DateTime(2026, 10, 3).weekday == DateTime.saturday,
      'B4 自检：2026-10-03 确为周六（日历前提）', 'weekday=${DateTime(2026, 10, 3).weekday}');
  final sat = await resolveDayContext(ledgerId: _ledgerId, workDate: DateTime(2026, 10, 3));
  final sun = await resolveDayContext(ledgerId: _ledgerId, workDate: DateTime(2026, 10, 4));
  final mon = await resolveDayContext(ledgerId: _ledgerId, workDate: DateTime(2026, 10, 5));
  _check(sat.isWeekend == true, 'B4a 周六 → isWeekend == true', '实际 ${sat.isWeekend}');
  _check(sun.isWeekend == true, 'B4b 周日 → isWeekend == true', '实际 ${sun.isWeekend}');
  _check(mon.isWeekend == false,
      'B4c **反证**：周一 → isWeekend == false（非恒真）', '实际 ${mon.isWeekend}');

  // ── B5：节假日口径（存在性，可被增/删证伪）──────────────────────────────
  print('\n[B5] 节假日口径（resolveDayContext.isHoliday 随 holiday_mark 增/删翻转）');
  final d = DateTime(2026, 10, 7); // 周三，避开周末以隔离 isHoliday
  var ctx0 = await resolveDayContext(ledgerId: _ledgerId, workDate: d);
  _check(ctx0.isHoliday == false, 'B5a 未标记日 → isHoliday == false（前置）', '实际 ${ctx0.isHoliday}');
  await db.upsertHolidayMark(HolidayMark(
      id: 'hmD1', ledgerId: _ledgerId, date: d, type: HolidayType.statutory, rate: 30, createdAt: _t0));
  final ctx1 = await resolveDayContext(ledgerId: _ledgerId, workDate: d);
  _check(ctx1.isHoliday == true,
      'B5b **反证**：标记后 → isHoliday == true（存在性判定，不看 rate）', '实际 ${ctx1.isHoliday}');
  await db.deleteHolidayMark('hmD1');
  final ctx2 = await resolveDayContext(ledgerId: _ledgerId, workDate: d);
  _check(ctx2.isHoliday == false, 'B5c **反证**：删除标记后 → isHoliday == false（可被变更证伪）', '实际 ${ctx2.isHoliday}');

  // ── B6：端到端（D → AmountInput → 引擎 → 金额）─────────────────────────
  print('\n[B6] 端到端：resolveDayContext 结果喂 AmountInput → 真实引擎（仿 work_form_page 新路径）');
  final holidayDate = DateTime(2026, 10, 8); // 周四，标记为节假日
  await db.upsertHolidayMark(HolidayMark(
      id: 'hmD2', ledgerId: _ledgerId, date: holidayDate, type: HolidayType.statutory, rate: 30, createdAt: _t0));
  final ctxH = await resolveDayContext(ledgerId: _ledgerId, workDate: holidayDate);
  _check(ctxH.isHoliday == true && ctxH.isWeekend == false,
      'B6 前置：2026-10-08 命中节假日且非周末', 'ctx=$ctxH');
  // 仿 work_form_page._buildInput 的 daily 分支（逐字段复刻；见头注【同构复刻】）。
  final inputH = AmountInput(
      fullDay: true, isOvertime: false, isWeekend: ctxH.isWeekend, isHoliday: ctxH.isHoliday);
  final resH = const AmountEngine().compute(rule: rB, input: inputH);
  _check(resH.amount == 96000 && resH.rateDetail.appliedRate == 30,
      'B6a 标记节假日日：32000 × 3.0 = 96000（D1-c 目标达成）',
      'amount=${resH.amount} appliedRate=${resH.rateDetail.appliedRate}');

  final plainDate = DateTime(2026, 10, 9); // 周五，未标记
  final ctxP = await resolveDayContext(ledgerId: _ledgerId, workDate: plainDate);
  final inputP = AmountInput(
      fullDay: true, isOvertime: false, isWeekend: ctxP.isWeekend, isHoliday: ctxP.isHoliday);
  final resP = const AmountEngine().compute(rule: rB, input: inputP);
  _check(resP.rateDetail.appliedRate == 10 && resP.amount == 32000,
      'B6b **对照（现状口径）**：未标记日 → 1.0× / 32000（96000 ≠ 32000 ⇒ 非恒真）',
      'amount=${resP.amount} appliedRate=${resP.rateDetail.appliedRate}');

  // ── B7：listPricingRules 过滤口径（AC-P09-04 / 02 §D.8:633）────────────
  print('\n[B7] listPricingRules 过滤：默认不含停用/归档；includeDisabled 含停用不含归档');
  await db.upsertPricingRule(_rule(id: 'ruleOn', method: PricingMethod.hourly, baseRate: 1000, unit: '小时'));
  await db.upsertPricingRule(
      _rule(id: 'ruleOff', method: PricingMethod.hourly, baseRate: 2000, unit: '小时', enabled: false));
  await db.upsertPricingRule(_rule(id: 'ruleArc', method: PricingMethod.hourly, baseRate: 3000, unit: '小时'));
  await db.softDeletePricingRule('ruleArc', DateTime(2026, 10, 9));

  Set<String> idsOf(List<PricingRule> l) => l.map((r) => r.id).toSet();
  final def = idsOf(await db.listPricingRules(companyId: _cid));
  final withDisabled = idsOf(await db.listPricingRules(companyId: _cid, includeDisabled: true));
  final withDeleted =
      idsOf(await db.listPricingRules(companyId: _cid, includeDisabled: true, includeDeleted: true));
  _check(def.contains('ruleOn') && !def.contains('ruleOff') && !def.contains('ruleArc'),
      'B7a 默认参数：含启用、**不含**停用与归档', '实际 $def');
  _check(withDisabled.contains('ruleOff') && !withDisabled.contains('ruleArc'),
      'B7b includeDisabled:true：含停用、**不含**归档（includeDeleted 默认 false）', '实际 $withDisabled');
  _check(withDeleted.contains('ruleArc'),
      'B7c includeDisabled+includeDeleted：含归档（对照组，证明 B7b 的"不含"非因数据缺失）',
      '实际 $withDeleted');

  // ── B8：弹层草稿分支落库（Q-2=A / AC-P02-04）────────────────────────────
  print('\n[B8] 弹层草稿分支（数量 0 → status=draft、amountSnapshot=0，真实 DB）');
  await db.upsertPricingRule(
      _rule(id: 'ruleDraft', method: PricingMethod.hourly, baseRate: 4000, unit: '小时'));
  final rDraft = (await db.getPricingRule('ruleDraft'))!;
  final draftRes =
      const AmountEngine().compute(rule: rDraft, input: const AmountInput(manualHours: 0));
  _check(draftRes.isDraft && draftRes.amount == 0,
      'B8a 数量 0 → 引擎 isDraft==true 且 amount==0',
      'isDraft=${draftRes.isDraft} amount=${draftRes.amount}');
  // 弹层保存路径：status = isDraft ? draft : confirmed（同 quick_add_sheet 落库构造）。
  final draftRec = WorkRecord(
    id: 'wDraft',
    workDate: DateTime(2026, 10, 6),
    companyId: _cid,
    pricingRuleId: rDraft.id,
    methodSnapshot: rDraft.method,
    qtySnapshot: draftRes.qty,
    qtyUnitSnapshot: draftRes.qtyUnit,
    rateSnapshot: draftRes.actualRate,
    rateDetailSnapshot: draftRes.rateDetail,
    amountSnapshot: draftRes.amount,
    amountSource: draftRes.source,
    status: draftRes.isDraft ? RecordStatus.draft : RecordStatus.confirmed,
    createdAt: _t0,
    updatedAt: _t0,
  );
  await db.upsertWorkRecord(draftRec);
  final readDraft = await db.getWorkRecord('wDraft');
  _check(readDraft != null &&
          readDraft.status == RecordStatus.draft &&
          readDraft.amountSnapshot == 0,
      'B8b 草稿分支落库后 status==draft **且** amountSnapshot==0（真实 DB 读回）',
      'status=${readDraft?.status} amount=${readDraft?.amountSnapshot}');

  // ── B9：弹层非草稿分支 → confirmed（反证：与 B8 状态不同）────────────────
  print('\n[B9] 弹层非草稿分支（数量 >0 → status=confirmed，真实 DB）');
  final okRes =
      const AmountEngine().compute(rule: rDraft, input: const AmountInput(manualHours: 8));
  final okRec = WorkRecord(
    id: 'wOk',
    workDate: DateTime(2026, 10, 6),
    companyId: _cid,
    pricingRuleId: rDraft.id,
    methodSnapshot: rDraft.method,
    qtySnapshot: okRes.qty,
    qtyUnitSnapshot: okRes.qtyUnit,
    rateSnapshot: okRes.actualRate,
    rateDetailSnapshot: okRes.rateDetail,
    amountSnapshot: okRes.amount,
    amountSource: okRes.source,
    status: okRes.isDraft ? RecordStatus.draft : RecordStatus.confirmed,
    createdAt: _t0,
    updatedAt: _t0,
  );
  await db.upsertWorkRecord(okRec);
  final readOk = await db.getWorkRecord('wOk');
  _check(
      readOk != null &&
          readOk.status == RecordStatus.confirmed &&
          readOk.amountSnapshot > 0,
      'B9 **反证**：非草稿分支 status==confirmed 且 amount>0（与 B8 状态/金额均不同）',
      'status=${readOk?.status} amount=${readOk?.amountSnapshot}');

  // ── B10：端到端（弹层同款输入：hourly manualHours + 真实 resolveDayContext）──
  print('\n[B10] 端到端：holiday_mark + holidayRate=30 → resolveDayContext 驱动的弹层同款输入 → 引擎');
  await db.upsertPricingRule(_rule(
      id: 'ruleQ', method: PricingMethod.hourly, baseRate: 4000, unit: '小时', holidayRate: 30));
  final rQ = (await db.getPricingRule('ruleQ'))!;
  final qHolDate = DateTime(2026, 10, 8); // 周四，标记为节假日
  await db.upsertHolidayMark(HolidayMark(
      id: 'hmQ', ledgerId: _ledgerId, date: qHolDate, type: HolidayType.statutory, rate: 30, createdAt: _t0));
  final ctxQ = await resolveDayContext(ledgerId: _ledgerId, workDate: qHolDate);
  // 弹层 hourly 分支同款构造（manualHours + isWeekend/isHoliday 取自 resolveDayContext）。
  final qResH = const AmountEngine().compute(
      rule: rQ,
      input: AmountInput(
          manualHours: 8, isWeekend: ctxQ.isWeekend, isHoliday: ctxQ.isHoliday));
  _check(qResH.amount == 96000,
      'B10a ★ 标记节假日日：4000分/时 × 8h × 3.0 = 96000（弹层路径 D1-c 目标达成）',
      'amount=${qResH.amount} appliedRate=${qResH.rateDetail.appliedRate}');
  final qPlainDate = DateTime(2026, 10, 9); // 周五，未标记
  final ctxQp = await resolveDayContext(ledgerId: _ledgerId, workDate: qPlainDate);
  final qResP = const AmountEngine().compute(
      rule: rQ,
      input: AmountInput(
          manualHours: 8, isWeekend: ctxQp.isWeekend, isHoliday: ctxQp.isHoliday));
  _check(qResP.amount == 32000,
      'B10b ★ 对照·未标记日：1.0× = 32000（96000 ≠ 32000 ⇒ 非恒真）',
      'amount=${qResP.amount} appliedRate=${qResP.rateDetail.appliedRate}');
  _check(qResH.amount != qResP.amount,
      'B10c **反证**：同一规则、两日金额必须不同（链路真接通，非恒真）',
      '两者皆为 ${qResH.amount}');
}

// ══════════════════════════════════════════════════════════════════════════
// A. 静态层（读真实源码）—— 【实测级】
// ══════════════════════════════════════════════════════════════════════════

void _staticLayer() {
  print('\n[A] 静态断言层 A1~A12（File.readAsStringSync 读真实源码 + 剥离注释后正则）');

  final ruleEditRaw = _read('lib/ui/rule_edit_page.dart');
  final ruleEdit = _stripComments(ruleEditRaw);
  final companyDetail = _stripComments(_read('lib/ui/company_detail_page.dart'));
  final workFormRaw = _read('lib/ui/work_form_page.dart');
  final workForm = _stripComments(workFormRaw);
  final recordDetail = _stripComments(_read('lib/ui/record_detail_page.dart'));
  final dayContextRaw = _read('lib/services/day_context.dart');
  final dayContext = _stripComments(dayContextRaw);
  final bootstrapRaw = _read('lib/services/pricing_bootstrap.dart');
  // ── 下批补交付：P02 秒级快记弹层（新建）+ P08 收口（改 company_page.dart）──
  final quickAddRaw = _read('lib/ui/quick_add_sheet.dart');
  final quickAdd = _stripComments(quickAddRaw);
  final companyPage = _stripComments(_read('lib/ui/company_page.dart'));

  // A1：rule_edit_page.dart 存在 + 三个方法名齐备
  _check(ruleEditRaw.isNotEmpty, 'A1a lib/ui/rule_edit_page.dart 存在且可读', '文件缺失/空');
  _check(ruleEdit.contains('upsertPricingRule(') &&
          ruleEdit.contains('updatePricingRule(') &&
          ruleEdit.contains('softDeletePricingRule('),
      'A1b 含 upsertPricingRule( / updatePricingRule( / softDeletePricingRule(（双分支写库 + 归档）',
      '缺：${[
        if (!ruleEdit.contains('upsertPricingRule(')) 'upsertPricingRule(',
        if (!ruleEdit.contains('updatePricingRule(')) 'updatePricingRule(',
        if (!ruleEdit.contains('softDeletePricingRule(')) 'softDeletePricingRule(',
      ].join(",")}');

  // A2：三档倍率**赋值**（构造器命名参数，带冒号 → 写而非读）
  _check(ruleEdit.contains('holidayRate:') &&
          ruleEdit.contains('weekendRate:') &&
          ruleEdit.contains('overtimeRate:'),
      'A2 含 holidayRate: / weekendRate: / overtimeRate: 赋值（D1-a 写路径 / AC-P09-02）',
      '缺：${[
        if (!ruleEdit.contains('holidayRate:')) 'holidayRate:',
        if (!ruleEdit.contains('weekendRate:')) 'weekendRate:',
        if (!ruleEdit.contains('overtimeRate:')) 'overtimeRate:',
      ].join(",")}');

  // A3：倍率口径说明固定文案
  _check(ruleEdit.contains('取最高档，不叠加'),
      'A3 含倍率口径固定文案「取最高档，不叠加」（AC-P09-05）', '未找到该文案');

  // A4：不触碰历史（评审红线）
  _check(!ruleEdit.contains('updateWorkRecord') &&
          !ruleEdit.contains('replaceWorkRecordSnapshot'),
      'A4 **不含** updateWorkRecord / replaceWorkRecordSnapshot（AC-P09-13 红线）',
      '命中：${ruleEdit.contains('updateWorkRecord')} / ${ruleEdit.contains('replaceWorkRecordSnapshot')}');

  // A5：P07 入口闭合（占位文案消失 + 指向真页）
  _check(!companyDetail.contains('计价规则编辑将在下个版本上线'),
      'A5a company_detail_page 剥注释后**不含**占位文案「计价规则编辑将在下个版本上线」',
      '仍命中占位文案');
  _check(companyDetail.contains('RuleEditPage('),
      'A5b company_detail_page 剥注释后含 RuleEditPage(（入口指向真页）', '未找到 RuleEditPage(');

  // A6：work_form_page 的 D 接线 + 预览倍率（D1-b / D1-c）
  //   ★ 逐处精确断言（取代旧「计数 ≥4」）：单点写反（`isHoliday: _dayCtx.isWeekend`）
  //     或"少写一处"都必须被抓住 —— 计数/contains 型断言对二者均逃逸（review-d1b MAJ-2）。
  //   ⚠️ 本文件（`verify_waveD1.dart`）在白名单内 ⇒ 追加对 `work_form_page.dart` 取值的
  //     精确断言**不需要改 `work_form_page.dart`**（白名单限制的是"被改的文件"，不是"读取范围"）。
  //     本条同时闭合 review-d1 的 D1-MIN-1（`work_form_page` 侧精确取值）。
  final wWk = _extractValues(workForm, 'isWeekend');
  final wHd = _extractValues(workForm, 'isHoliday');
  final wWkBad = wWk.where((v) => v != '_dayCtx.isWeekend').toList();
  final wHdBad = wHd.where((v) => v != '_dayCtx.isHoliday').toList();
  _check(wWk.length == 4 && wWkBad.isEmpty,
      'A6d ★ work_form_page isWeekend: **逐处** == _dayCtx.isWeekend（恰 4 处，4 个 AmountInput 各一）',
      '处数=${wWk.length}（期望 4）越界取值=$wWkBad 全量=$wWk');
  _check(wHd.length == 4 && wHdBad.isEmpty,
      'A6e ★ work_form_page isHoliday: **逐处** == _dayCtx.isHoliday（恰 4 处）',
      '处数=${wHd.length}（期望 4）越界取值=$wHdBad 全量=$wHd');
  _check(workForm.contains('holidayRate:'),
      'A6c work_form_page 含 holidayRate:（预览规则 D1-b，闭合 B2）', '未找到 holidayRate:');

  // A7：P05 C-01 护栏（防 D 被退化重算清零；Wave B 产物，D1 只断言不改）
  _check(recordDetail.contains(
          '(r.isDraft || r.isInvalidInput || r.needsOvernightConfirm) ? rd : r.rateDetail'),
      'A7 record_detail_page 含 C-01 护栏三元式（冻结的 D 不被退化重算清零）',
      '未找到该护栏三元式');

  // A8：day_context 唯一构造点
  _check(dayContextRaw.isNotEmpty, 'A8a lib/services/day_context.dart 存在且可读', '文件缺失/空');
  _check(dayContext.contains('weekday == DateTime.saturday') &&
          dayContext.contains('getHolidayMarkByDate('),
      'A8b 含 weekday == DateTime.saturday 与 getHolidayMarkByDate(（口径唯一构造点）',
      '缺：${[
        if (!dayContext.contains('weekday == DateTime.saturday')) 'weekday==saturday',
        if (!dayContext.contains('getHolidayMarkByDate(')) 'getHolidayMarkByDate(',
      ].join(",")}');

  // A9：新增文件禁浮点（0 命中）——下批已交付 quick_add_sheet.dart，故禁浮点批**扩容**。
  final newBatch = <String, String>{
    'lib/ui/rule_edit_page.dart': ruleEdit,
    'lib/services/day_context.dart': dayContext,
    'lib/ui/quick_add_sheet.dart': quickAdd,
  };
  final a9hits = <String>[];
  newBatch.forEach((name, code) {
    final v = _floatViolations(code);
    if (v.isNotEmpty) a9hits.add('$name: ${v.join(",")}');
  });
  _check(a9hits.isEmpty,
      'A9a 新增文件（rule_edit / day_context / quick_add_sheet）剥注释后**零**禁浮点命中'
      '（fen/100、double.parse、.round、.toDouble、浮点/10、/100.0）',
      '命中：$a9hits');
  // A9b：**范围声明（非产品断言，不计入通过数）**。
  //   原 A9b = `File('lib/ui/quick_add_sheet.dart').existsSync()`：文件一旦交付**必过** ⇒
  //   **恒真**，无法被任何产品代码改动证伪 ⇒ 不构成产品行为证据（review-d1b MIN-2 点名）。
  //   保留为"范围声明"仅用于说明 A9a 的扫描范围已含该文件；A9a 才是产品断言。
  final inA9aScope = newBatch.containsKey('lib/ui/quick_add_sheet.dart');
  assert(inA9aScope, 'quick_add_sheet.dart 未纳入 A9a 扫描范围');
  print('  · A9b [范围声明·不计入通过数] quick_add_sheet.dart 已交付（存在性**恒真**，'
      '不构成产品行为证据）；其禁浮点由 A9a 实覆盖（inA9aScope=$inA9aScope）');

  // A10：pricing_bootstrap.dart 与本设计基线逐字节相同（未改）
  _check(bootstrapRaw.isNotEmpty, 'A10 前置：pricing_bootstrap.dart 可读', '文件缺失/空');
  final sha = sha256.convert(File('lib/services/pricing_bootstrap.dart').readAsBytesSync()).toString();
  _check(sha == _pricingBootstrapSha,
      'A10a pricing_bootstrap.dart sha256 == 冻结基线（**逐字节相同**，D1-d 定案 A）',
      '实际 $sha\n           期望 $_pricingBootstrapSha');
  // A10b：**环境项（不计入产品断言）**。原 A10b 断言 mtime 早于冻结时刻 ⇒ 任何复制/检出/
  //   打补丁（未 `cp -p`）都会重置 mtime 而**误红**，测的不是代码不变量（review-d1b MIN-1）。
  //   其"文件未被改"的意图**已由 A10a 的 sha256 逐字节比对完全覆盖** ⇒ 降级为环境项提示。
  final mt = File('lib/services/pricing_bootstrap.dart').lastModifiedSync();
  print('  · A10b [环境项·不计入通过数] pricing_bootstrap mtime=$mt'
      '（早于冻结 $_freeze = ${mt.isBefore(_freeze)}）；「未改」证据以 A10a sha256 为准');

  // A11：不复活死路由
  _check(!_fileTreeContains('lib', 'pushNamed(Routes.records)') &&
          !_fileTreeContains('lib', 'pushNamed(Routes.overview)'),
      'A11 lib/ 内 pushNamed(Routes.records) / pushNamed(Routes.overview) **0 命中**',
      '命中死路由');

  // A12：陈旧注释订正（R61）
  _check(!workForm.contains('基础版没有「规则管理」页'),
      'A12 work_form_page 剥注释后**不含**「基础版没有「规则管理」页」（R61 订正）',
      '仍命中陈旧口径');

  // ══════════════════════════════════════════════════════════════════════
  // D1B. 下批补交付静态断言（P02 弹层 §2.3 + P08 收口 §2.4）
  // ══════════════════════════════════════════════════════════════════════
  print('\n[D1B] 下批补交付静态断言（quick_add_sheet.dart + company_page.dart，读真实源码）');

  // ── P02 秒级快记弹层（§2.3）───────────────────────────────────────────
  // D1B-1：弹层形态
  _check(quickAddRaw.isNotEmpty,
      'D1B-1a lib/ui/quick_add_sheet.dart 存在且可读', '文件缺失/空');
  _check(quickAdd.contains('showModalBottomSheet'),
      'D1B-1b 含 showModalBottomSheet（底部弹层形态，AC-P02-01）', '未找到 showModalBottomSheet');

  // D1B-2：★ D 接线（弹层必须调 resolveDayContext 并传 isWeekend/isHoliday）
  _check(quickAdd.contains('resolveDayContext('),
      'D1B-2a ★ 含 resolveDayContext(（复用 day_context 唯一构造点）', '未找到 resolveDayContext(');
  //   ★ 逐处精确断言（取代旧 D1B-2b「计数 ≥3」+ D1B-2c「contains」）：
  //     旧式断言对「某一个 method 分支取值写反」**逃逸**（review-d1b MAJ-2 实测：仅 piece
  //     分支写 `isHoliday: ctx.isWeekend` ⇒ 旧断言 66/0 全绿）。现把**每一处**取值列出逐一比对，
  //     且要求**恰 3 处**（防"少写一处"逃逸）。
  final qWk = _extractValues(quickAdd, 'isWeekend');
  final qHd = _extractValues(quickAdd, 'isHoliday');
  final qWkBad = qWk.where((v) => v != 'ctx.isWeekend').toList();
  final qHdBad = qHd.where((v) => v != 'ctx.isHoliday').toList();
  _check(qWk.length == 3 && qWkBad.isEmpty,
      'D1B-2b ★ 弹层 isWeekend: **逐处** == ctx.isWeekend（恰 3 处，3 个 method 分支各一）',
      '处数=${qWk.length}（期望 3）越界取值=$qWkBad 全量=$qWk');
  _check(qHd.length == 3 && qHdBad.isEmpty,
      'D1B-2c ★ 弹层 isHoliday: **逐处** == ctx.isHoliday（恰 3 处，3 个 method 分支各一）',
      '处数=${qHd.length}（期望 3）越界取值=$qHdBad 全量=$qHd');

  // D1B-3：默认值派生自 listWorkRecords() 首条（companyId/pricingRuleId/qtySnapshot）
  _check(quickAdd.contains('listWorkRecords()'),
      'D1B-3a 含 listWorkRecords()（「上次记录」读，AC-P02-02）', '未找到 listWorkRecords()');
  _check(quickAdd.contains('recent.first'),
      'D1B-3b 取 `recent.first`（首条 = ORDER BY attribution_date DESC, created_at DESC 最近一条）',
      '未找到 recent.first');
  _check(quickAdd.contains('last?.companyId') &&
          quickAdd.contains('last?.pricingRuleId') &&
          quickAdd.contains('last?.qtySnapshot'),
      'D1B-3c 默认值取自首条的 companyId / pricingRuleId / qtySnapshot',
      '缺：${[
        if (!quickAdd.contains('last?.companyId')) 'companyId',
        if (!quickAdd.contains('last?.pricingRuleId')) 'pricingRuleId',
        if (!quickAdd.contains('last?.qtySnapshot')) 'qtySnapshot',
      ].join(",")}');

  // D1B-4：草稿分支（Q-2=A / AC-P02-04）
  _check(quickAdd.contains('RecordStatus.draft') &&
          quickAdd.contains('已存为草稿，补上时长再算金额'),
      'D1B-4 含 RecordStatus.draft + 文案「已存为草稿，补上时长再算金额」（AC-P02-04）',
      '缺：${[
        if (!quickAdd.contains('RecordStatus.draft')) 'RecordStatus.draft',
        if (!quickAdd.contains('已存为草稿，补上时长再算金额')) '草稿文案',
      ].join(",")}');

  // D1B-4b：★ 弹层 `status` 三元式**精确且顺序正确**（防两分支对调）——
  //   原 `B8b/B9` 是**脚本内自构造** `WorkRecord` 去调 DB，**不读弹层代码** ⇒ 无任何断言
  //   读取弹层真实 `status` 逻辑；把 `:331` 的两分支对调仍 **66/0 全绿**（review-d1b MAJ-2）。
  //   本条为**据弹层源码精确断言**：恰好 `isDraft ? RecordStatus.draft : RecordStatus.confirmed`，
  //   顺序不得反。**原 B8/B9 为脚本自构造、不构成对弹层 status 分支的证据。**
  final statusRe = RegExp(
      r'status\s*:\s*isDraft\s*\?\s*RecordStatus\.draft\s*:\s*RecordStatus\.confirmed');
  final statusRevRe = RegExp(
      r'status\s*:\s*isDraft\s*\?\s*RecordStatus\.confirmed\s*:\s*RecordStatus\.draft');
  _check(statusRe.hasMatch(quickAdd) && !statusRevRe.hasMatch(quickAdd),
      'D1B-4b ★ 弹层 status == `isDraft ? RecordStatus.draft : RecordStatus.confirmed`'
      '（**顺序精确**，防两分支对调）｜注：原 B8/B9 为脚本自构造、不构成对弹层 status 分支的证据',
      '正序命中=${statusRe.hasMatch(quickAdd)} 反序命中=${statusRevRe.hasMatch(quickAdd)}');

  // ── P08 收口（§2.4）──────────────────────────────────────────────────
  // D1B-5：名称内联红字 + 保存置灰（**无** SnackBar）
  _check(!companyPage.contains("SnackBar(content: Text('请填写公司名'))"),
      'D1B-5a company_page 剥注释后**不含**名称校验 SnackBar（AC-P08-01：改内联）',
      '仍命中 SnackBar 名称校验');
  _check(companyPage.contains('请填写公司名') &&
          companyPage.contains('errorText: _nameError'),
      'D1B-5b 含字段内联红字 errorText: _nameError + 文案「请填写公司名」',
      '缺：${[
        if (!companyPage.contains('请填写公司名')) '文案',
        if (!companyPage.contains('errorText: _nameError')) 'errorText: _nameError',
      ].join(",")}');
  _check(companyPage.contains('canSave ? _submit : null'),
      'D1B-5c 保存按钮空名时置灰（onPressed: canSave ? _submit : null）', '未找到置灰守卫');

  // D1B-6：contact 字段不被 showEnabled 门控（结构断言：先于 if(widget.showEnabled) 出现）
  final iContact = companyPage.indexOf('联系方式（可选）');
  final iShowEnabled = companyPage.indexOf('widget.showEnabled');
  _check(iContact >= 0 && iShowEnabled >= 0 && iContact < iShowEnabled,
      'D1B-6 联系方式字段在 build 中**先于** if(widget.showEnabled)（新建态可渲染，AC-P08-05）',
      'iContact=$iContact iShowEnabled=$iShowEnabled（须 0<=iContact<iShowEnabled）');

  // D1B-7：ledgerId 的 ?? '' 兜底消失
  _check(!companyPage.contains("AppState.ledgerId ?? ''"),
      'D1B-7 ledgerId 的 ?? \'\' 兜底已消失（AC-P08-09：改显式失败）',
      '仍命中 AppState.ledgerId ?? \'\'');

  // D1B-8：12 色调色板 + 已用色轮转
  final palMatch =
      RegExp(r'_kPalette\s*=\s*<int>\[(.*?)\];', dotAll: true).firstMatch(companyPage);
  final palCount = palMatch == null
      ? -1
      : RegExp(r'0x[0-9A-Fa-f]{6}').allMatches(palMatch.group(1)!).length;
  _check(palCount == 12, 'D1B-8a 调色板为 12 色（07 §1.4 / AC-P08-03）', '实际 $palCount 色');
  _check(companyPage.contains('!used.contains(') &&
          !companyPage.contains('_companies.length %'),
      'D1B-8b 新建取色为「已用色轮转」（含 !used.contains，且**不含** _companies.length %）',
      'used轮转=${companyPage.contains('!used.contains(')} / length%=${companyPage.contains('_companies.length %')}');
}

/// 在 `dir` 下递归查 `needle`（读真实源码，用于 A11 全 lib 扫描）。
bool _fileTreeContains(String dir, String needle) {
  final d = Directory(dir);
  if (!d.existsSync()) return false;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    if (!e.path.endsWith('.dart')) continue;
    try {
      if (e.readAsStringSync().contains(needle)) {
        print('    · A11 命中：${e.path}');
        return true;
      }
    } catch (_) {
      // 跳过不可读文件
    }
  }
  return false;
}
