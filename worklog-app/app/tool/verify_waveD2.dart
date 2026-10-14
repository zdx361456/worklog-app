/// Wave D2（导航收尾 · P02 入口闭合 + 死路由复核 + AC-P03-06 收口 + P01 FAB）自验证脚本
/// —— **静态断言层（A 组）+ DB/引擎行为层（B 组）**。
///
/// **证据层级三分（`DECISIONS.md` D-8）—— 先读本段，不要误读下面的输出**：
///
/// 【实测级 / 强证据】§A（静态层，`A1~A27`）：`File.readAsStringSync` 读 **真实源码**
///   （非复刻、非转述），剥离注释后正则/计数断言（剥离：`(^|\s)//.*$`，multiLine；整行 + 行尾都剥）。
///   覆盖：E1~E4 入口闭合（含 **实参级** `A19`/`A20`/`A21`/`A24`）、`WorkFormPage(` 收口（`A6`）、
///   `initialDate` 参导入/P（`A7`/`A8`/`A17`）、死路由判据（`A9`/`A10`）、禁浮点（`A11`）、
///   无新增依赖（`A12`）、`AC-P03-06` 角标独立入口（`A13`/`A14`/`A18`/`A22`）、
///   P10 收款分支保护（`A23`）、P01 FAB 形态（`A15`/`A16`）、
///   **角标图标/命中区（`A25`）、FAB 接线 + 刷新（`A26`）、两处触发按钮未断线（`A27`）**
///   ——`A25`~`A27` = `review-d2` 第三轮 5 条逃逸面（E-1~E-5）的补强（设计 §9.7 / §5.1）。
///
/// 【实测级 / 强证据】§B（行为层，`B1~B5`）：全部走**真实 `AppDatabase`（内存库）**
///   + **真实 `AmountEngine`（`const AmountEngine()`）** + **真实 `resolveDayContext`**
///   （`lib/services/day_context.dart`，非复刻）：`B1` 日期→引擎分流（节假日 3.0× / 平 1.0×，含对照）；
///   `B2` preset 归属日落库 → 闭区间命中（含异日对照）；`B3` companyId→启用规则非空（含停用对照）；
///   `B4` 弹层默认值派生链 + 草稿/非草稿落库（复跑 D1 B8/B9 口径）；`B5` 周末口径（复跑 D1 B4）。
///
/// 【本波范围声明 / 直读不要误判】本波 = `02 §A.3:105` Wave D2 行（P02 入口闭合 + 死路由复核）
///   ∪ **主理人 §9.1-Q3 裁定并波**（P01 FAB 形态，`19 R8` / `09 §6.6 O-3`）
///   ∪ **`AC-P03-06` 收口**（`02:453`；双处指派：`13 §3 缺口 5` + `19 §4 在途小项 3`）。
///   **`W7`（`holiday_mark_page.dart`）不上** —— Q5 = α，`HolidayMarkPage` 签名不改。
///
/// 【不覆盖 · `[真机]` 档】弹层**实际弹出** / `setState` 时序 / `DropdownButtonFormField.initialValue`
///   同步 / `:478-479` 归属日**显示文本** / P12a 入口**实际可达** / FAB 与底部 4 Tab 不叠压 /
///   窄屏大字号 7 列不溢出 —— **本脚本不能替代**，须末次统一出包人工验收（`DECISIONS.md` D-9 第 3 条）。
///
/// 运行（**必须两项齐全**）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// export WORKLOG_USE_SYSTEM_SQLITE=1
/// "...\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev \
///   --packages=.dart_tool/package_config.json tool/verify_waveD2.dart
/// ```
/// **严禁 `dart run`**（触发 native-assets build hook，被本机 `Process.start` 缺陷拦截）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

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

// ── Windows 兜底：预加载系统 SQLite（与 tool/verify_waveD1.dart 同源）───────────
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

// ══════════════════════════════════════════════════════════════════════════
// 静态工具（读真实源码）
// ══════════════════════════════════════════════════════════════════════════

String _read(String relPath) {
  final f = File(relPath);
  if (!f.existsSync()) return '';
  return f.readAsStringSync();
}

final RegExp _commentRe = RegExp(r'(^|\s)//.*$', multiLine: true);

String _stripComments(String src) => src.replaceAll(_commentRe, '');

/// YAML 注释剥离（`#` 起至行尾）。用于 `pubspec.yaml`（其注释中含 `shared_preferences`
/// 字样，若不剥会**假阳性**）。
String _stripYamlComments(String src) => src
    .split('\n')
    .map((l) {
      final i = l.indexOf('#');
      return i >= 0 ? l.substring(0, i) : l;
    })
    .join('\n');

/// 取 `pubspec.yaml` 的 `dependencies:` 段（到 `dev_dependencies:` 止）的**顶层键集**。
Set<String> _pubspecDependencyKeys(String yaml) {
  final code = _stripYamlComments(yaml);
  final out = <String>{};
  var inDeps = false;
  for (final l in code.split('\n')) {
    if (RegExp(r'^dependencies:\s*$').hasMatch(l)) {
      inDeps = true;
      continue;
    }
    if (RegExp(r'^[A-Za-z_]').hasMatch(l)) {
      if (inDeps) break; // 到达下一个顶层键（dev_dependencies/…）
      continue;
    }
    if (!inDeps) continue;
    final m = RegExp(r'^  ([A-Za-z_][A-Za-z0-9_]*):').firstMatch(l);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

String _norm(String p) => p.replaceAll(r'\', '/');

/// `needle` 在 `code` 中的**总出现次数**（不重叠）。
int _count(String code, String needle) {
  if (needle.isEmpty) return 0;
  var c = 0;
  var i = code.indexOf(needle);
  while (i >= 0) {
    c++;
    i = code.indexOf(needle, i + needle.length);
  }
  return c;
}

/// 正则命中处数。
int _reCount(String code, RegExp re) => re.allMatches(code).length;

/// 在 `lib/ui/**` 下统计 `needle`（已剥注释）出现总次数 + 命中文件集（可排除文件）。
({int total, Set<String> files}) _uiCount(String needle,
    {Set<String> exclude = const {}}) {
  var total = 0;
  final files = <String>{};
  final d = Directory('lib/ui');
  if (!d.existsSync()) return (total: 0, files: files);
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final p = _norm(e.path);
    if (exclude.contains(p)) continue;
    final n = _count(_stripComments(e.readAsStringSync()), needle);
    if (n > 0) {
      total += n;
      files.add(p);
    }
  }
  return (total: total, files: files);
}

/// 在全目录树（`.dart`）统计 `needle`（已剥注释）出现总次数（可排除文件）。
int _treeCount(String dir, String needle, {Set<String> exclude = const {}}) {
  var total = 0;
  final d = Directory(dir);
  if (!d.existsSync()) return 0;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    if (exclude.contains(_norm(e.path))) continue;
    total += _count(_stripComments(e.readAsStringSync()), needle);
  }
  return total;
}

/// 取 `marker` 所在方法/函数体的完整块（花括号配对）。
String _blockAfter(String code, String marker) {
  final i = code.indexOf(marker);
  if (i < 0) return '';
  final open = code.indexOf('{', i);
  if (open < 0) return '';
  var depth = 0;
  for (var j = open; j < code.length; j++) {
    final c = code[j];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return code.substring(i, j + 1);
    }
  }
  return code.substring(i);
}

/// 取 `marker` 之后**第一个** `(` 到配对 `)` 的完整表达式（含 `marker`）。
/// 用于无花括号体的块提取（如 `floatingActionButton: FloatingActionButton.extended( … )`）：
/// `_blockAfter` 找的是 `{`，对这类表达式会**越过到后续方法体**，故另设本函数。
String _parenAfter(String code, String marker) {
  final i = code.indexOf(marker);
  if (i < 0) return '';
  final open = code.indexOf('(', i);
  if (open < 0) return '';
  var depth = 0;
  for (var j = open; j < code.length; j++) {
    final c = code[j];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return code.substring(i, j + 1);
    }
  }
  return code.substring(i);
}

/// 浮点禁令：返回命中的模式名清单（已剥离注释）。复用 `verify_waveD1.dart:132-153`。
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
const _ledgerId = 'd2000000-0000-4000-8000-000000000001';
const _cid = 'd2000000-0000-4000-8000-00000000000a';
final _t0 = DateTime(2026, 10, 1, 9, 0);
final _freeze = DateTime(2026, 10, 10, 10, 1); // §0 设计冻结时刻

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
  print('Wave D2 · 导航收尾（P02 入口闭合 ∪ 死路由复核 ∪ AC-P03-06 ∪ P01 FAB） · 自验证');
  print('  静态层 A1~A27（读真实源码） + 行为层 B1~B5（真实引擎/真实 DB/真实 resolveDayContext）');
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
  print('【不覆盖·[真机]】弹层实际弹出/归属日显示文本/P12a 可达/FAB 不叠压/窄屏不溢出 → 末次出包人工验收。');
  if (_fail > 0) exit(1);
}

// ══════════════════════════════════════════════════════════════════════════
// B. 行为层（真实引擎 + 真实 DB + 真实 resolveDayContext）—— 【实测级】
// ══════════════════════════════════════════════════════════════════════════

Future<void> _behaviorLayer(AppDatabase db) async {
  print('\n[B] 行为层（真实 AppDatabase 内存库 + 真实 AmountEngine + 真实 resolveDayContext）');

  // ── B1：日期 → 引擎分流链（不含 E3 入口接线；入口实参由 A19 覆盖）─────────
  print('\n[B1] 日期 → 引擎分流链（同一弹层输入，节假日日 vs 未标记日）');
  await db.upsertPricingRule(_rule(
      id: 'ruleB1', method: PricingMethod.daily, baseRate: 32000, unit: '天', holidayRate: 30));
  final rB1 = (await db.getPricingRule('ruleB1'))!;
  final holidayDate = DateTime(2026, 10, 8); // 周四，命中节假日且非周末
  final plainDate = DateTime(2026, 10, 9); // 周五，未标记
  await db.upsertHolidayMark(HolidayMark(
      id: 'hmB1', ledgerId: _ledgerId, date: holidayDate, type: HolidayType.statutory, rate: 30, createdAt: _t0));

  final ctxH = await resolveDayContext(ledgerId: _ledgerId, workDate: holidayDate);
  _check(ctxH.isHoliday == true && ctxH.isWeekend == false,
      'B1a 前置：2026-10-08 命中节假日且非周末', 'ctx=$ctxH');
  // 弹层 daily 分支同款构造（fullDay + isWeekend/isHoliday 取自 resolveDayContext）。
  final resH = const AmountEngine().compute(
      rule: rB1,
      input: AmountInput(fullDay: true, isWeekend: ctxH.isWeekend, isHoliday: ctxH.isHoliday));
  _check(resH.rateDetail.appliedRate == 30 && resH.amount == 96000,
      'B1b ★ 命中节假日日：32000 × 3.0 = 96000（appliedRate 30）',
      'amount=${resH.amount} appliedRate=${resH.rateDetail.appliedRate}');

  final ctxP = await resolveDayContext(ledgerId: _ledgerId, workDate: plainDate);
  final resP = const AmountEngine().compute(
      rule: rB1,
      input: AmountInput(fullDay: true, isWeekend: ctxP.isWeekend, isHoliday: ctxP.isHoliday));
  _check(ctxP.isHoliday == false && resP.rateDetail.appliedRate == 10 && resP.amount == 32000,
      'B1c **对照**：未标记日 → 1.0× / 32000',
      'isHoliday=${ctxP.isHoliday} amount=${resP.amount} appliedRate=${resP.rateDetail.appliedRate}');
  _check(resH.amount != resP.amount,
      'B1d **反证**：同一规则、两日金额必须不同（链路真按日期分流，非恒真）',
      '两者皆为 ${resH.amount}');

  // ── B2：preset 归属日落库 → 闭区间命中（含异日对照）────────────────────
  print('\n[B2] preset 归属日落库口径（workDate = presetDate → 闭区间查询命中）');
  final presetDate = DateTime(2026, 10, 5);
  final otherDate = DateTime(2026, 10, 6);
  final presetRes =
      const AmountEngine().compute(rule: rB1, input: const AmountInput(fullDay: true));
  await db.upsertWorkRecord(WorkRecord(
    id: 'wrB2',
    workDate: presetDate,
    companyId: _cid,
    pricingRuleId: rB1.id,
    methodSnapshot: rB1.method,
    qtySnapshot: presetRes.qty,
    qtyUnitSnapshot: rB1.unit,
    rateSnapshot: presetRes.actualRate,
    rateDetailSnapshot: presetRes.rateDetail,
    amountSnapshot: presetRes.amount,
    amountSource: presetRes.source,
    status: RecordStatus.confirmed,
    createdAt: _t0,
    updatedAt: _t0,
  ));
  final hitPreset =
      await db.listWorkRecords(startDate: presetDate, endDate: presetDate);
  final hitOther = await db.listWorkRecords(startDate: otherDate, endDate: otherDate);
  _check(hitPreset.any((w) => w.id == 'wrB2'),
      'B2a preset 日闭区间查询命中该条（落库写 preset 而非 today）',
      '命中数=${hitPreset.length}');
  _check(!hitOther.any((w) => w.id == 'wrB2'),
      'B2b **对照**：异日区间查询**不命中**（区间真按日期过滤，非恒真）',
      '异日命中数=${hitOther.length}');

  // ── B3：E4 的 companyId preset 可查到启用规则（含停用对照）──────────────
  print('\n[B3] companyId → 启用规则（listPricingRules 默认参数 = 仅启用）');
  await db.upsertPricingRule(
      _rule(id: 'ruleB3on', method: PricingMethod.hourly, baseRate: 4000, unit: '小时'));
  await db.upsertPricingRule(_rule(
      id: 'ruleB3off', method: PricingMethod.hourly, baseRate: 5000, unit: '小时', enabled: false));
  final enabledRules = await db.listPricingRules(companyId: _cid);
  final withDisabledB3 = await db.listPricingRules(companyId: _cid, includeDisabled: true);
  _check(enabledRules.isNotEmpty && enabledRules.any((r) => r.id == 'ruleB3on'),
      'B3a f.companyId 默认查询非空且含启用规则（E4 预置公司可查规则）',
      '启用规则数=${enabledRules.length} ids=${enabledRules.map((r) => r.id).toList()}');
  _check(!enabledRules.any((r) => r.id == 'ruleB3off') &&
          withDisabledB3.any((r) => r.id == 'ruleB3off'),
      'B3b **对照**：停用规则默认不返回、includeDisabled 才返回（过滤真生效，非恒真）',
      '默认含停用=${enabledRules.any((r) => r.id == 'ruleB3off')} includeDisabled含=${withDisabledB3.any((r) => r.id == 'ruleB3off')}');

  // ── B4：弹层默认值派生链 + 草稿/非草稿落库（复跑 D1 B8/B9 口径）──────────
  print('\n[B4] 弹层默认值派生链 + 草稿/非草稿落库（复跑 verify_waveD1 B8/B9 口径）');
  await db.upsertPricingRule(
      _rule(id: 'ruleB4', method: PricingMethod.hourly, baseRate: 4000, unit: '小时'));
  final rB4 = (await db.getPricingRule('ruleB4'))!;
  // 默认值派生链：listWorkRecords() 首条（ORDER BY attribution_date DESC, created_at DESC）可提供默认。
  final recentFirst = await db.listWorkRecords();
  _check(recentFirst.isNotEmpty &&
          recentFirst.first.companyId == _cid &&
          recentFirst.first.pricingRuleId != null,
      'B4a 默认值派生链：最近一条含 companyId + pricingRuleId（弹层「上次」可派生）',
      '首条=${recentFirst.isEmpty ? "空" : "${recentFirst.first.companyId}/${recentFirst.first.pricingRuleId}"}');
  // 草稿分支（数量 0 → draft/0）
  final draftRes =
      const AmountEngine().compute(rule: rB4, input: const AmountInput(manualHours: 0));
  await db.upsertWorkRecord(WorkRecord(
    id: 'wrB4draft',
    workDate: presetDate,
    companyId: _cid,
    pricingRuleId: rB4.id,
    methodSnapshot: rB4.method,
    qtySnapshot: draftRes.qty,
    qtyUnitSnapshot: rB4.unit,
    rateSnapshot: draftRes.actualRate,
    rateDetailSnapshot: draftRes.rateDetail,
    amountSnapshot: draftRes.amount,
    amountSource: draftRes.source,
    status: draftRes.isDraft ? RecordStatus.draft : RecordStatus.confirmed,
    createdAt: _t0,
    updatedAt: _t0,
  ));
  final readDraft = await db.getWorkRecord('wrB4draft');
  _check(readDraft != null &&
          readDraft.status == RecordStatus.draft &&
          readDraft.amountSnapshot == 0,
      'B4b 草稿分支：数量 0 → status==draft 且 amountSnapshot==0（真实 DB 读回）',
      'status=${readDraft?.status} amount=${readDraft?.amountSnapshot}');
  // 非草稿分支（数量 >0 → confirmed/>0）
  final okRes =
      const AmountEngine().compute(rule: rB4, input: const AmountInput(manualHours: 8));
  await db.upsertWorkRecord(WorkRecord(
    id: 'wrB4ok',
    workDate: presetDate,
    companyId: _cid,
    pricingRuleId: rB4.id,
    methodSnapshot: rB4.method,
    qtySnapshot: okRes.qty,
    qtyUnitSnapshot: rB4.unit,
    rateSnapshot: okRes.actualRate,
    rateDetailSnapshot: okRes.rateDetail,
    amountSnapshot: okRes.amount,
    amountSource: okRes.source,
    status: okRes.isDraft ? RecordStatus.draft : RecordStatus.confirmed,
    createdAt: _t0,
    updatedAt: _t0,
  ));
  final readOk = await db.getWorkRecord('wrB4ok');
  _check(readOk != null &&
          readOk.status == RecordStatus.confirmed &&
          readOk.amountSnapshot > 0,
      'B4c **反证**：非草稿分支 status==confirmed 且 amount>0（与 B4b 状态/金额均不同）',
      'status=${readOk?.status} amount=${readOk?.amountSnapshot}');

  // ── B5：周末口径（复跑 verify_waveD1 B4）────────────────────────────────
  print('\n[B5] 周末口径（resolveDayContext：周六/周日 true，周一 false）');
  _check(DateTime(2026, 10, 3).weekday == DateTime.saturday,
      'B5 自检：2026-10-03 确为周六（日历前提）', 'weekday=${DateTime(2026, 10, 3).weekday}');
  final sat = await resolveDayContext(ledgerId: _ledgerId, workDate: DateTime(2026, 10, 3));
  final sun = await resolveDayContext(ledgerId: _ledgerId, workDate: DateTime(2026, 10, 4));
  final mon = await resolveDayContext(ledgerId: _ledgerId, workDate: DateTime(2026, 10, 5));
  _check(sat.isWeekend == true && sun.isWeekend == true,
      'B5a 周六 / 周日 → isWeekend == true', 'sat=${sat.isWeekend} sun=${sun.isWeekend}');
  _check(mon.isWeekend == false,
      'B5b **反证**：周一 → isWeekend == false（非恒真）', 'mon=${mon.isWeekend}');
}

// ══════════════════════════════════════════════════════════════════════════
// A. 静态层（读真实源码）—— 【实测级】
// ══════════════════════════════════════════════════════════════════════════

void _staticLayer() {
  print('\n[A] 静态断言层 A1~A27（File.readAsStringSync 读真实源码 + 剥离注释后正则/计数）');

  final overviewRaw = _read('lib/ui/overview_page.dart');
  final overview = _stripComments(overviewRaw);
  final companyDetail = _stripComments(_read('lib/ui/company_detail_page.dart'));
  final dayDetail = _stripComments(_read('lib/ui/day_detail_page.dart'));
  final records = _stripComments(_read('lib/ui/records_page.dart'));
  final quickAddRaw = _read('lib/ui/quick_add_sheet.dart');
  final quickAdd = _stripComments(quickAddRaw);
  final calendar = _stripComments(_read('lib/ui/calendar_page.dart'));
  final routesSrc = _read('lib/app/routes.dart');
  final mainSrc = _read('lib/main.dart');
  final pubspecSrc = _read('pubspec.yaml');

  // ── A1：QuickAddSheet.show( 在 lib/ui（排除自身）恰 4 处 = E1~E4 ──────────
  final a1 = _uiCount('QuickAddSheet.show(',
      exclude: {'lib/ui/quick_add_sheet.dart'});
  _check(a1.total == 4 && a1.files.length == 4,
      'A1 `QuickAddSheet.show(` 在 lib/ui（排除自身）恰 4 处（E1~E4）',
      'total=${a1.total}（期望 4）files=${a1.files.toList()..sort()}');

  // ── A2：overview 剥注释后不含 pushNamed(Routes.workForm) ─────────────────
  _check(!overview.contains('pushNamed(Routes.workForm)'),
      'A2 overview_page 剥注释后**不含** pushNamed(Routes.workForm)（E1 已换弹层）',
      '仍命中 pushNamed(Routes.workForm)');

  // ── A3/A4/A5：三入口已换弹层，旧 WorkFormPage 命令式消失 ─────────────────
  _check(!companyDetail.contains('WorkFormPage(companyId:') &&
          companyDetail.contains('QuickAddSheet.show('),
      'A3 company_detail_page 剥注释后不含 WorkFormPage(companyId: 且含 QuickAddSheet.show(',
      'WorkFormPage(companyId:=${companyDetail.contains('WorkFormPage(companyId:')} show=${companyDetail.contains('QuickAddSheet.show(')}');
  _check(!dayDetail.contains('WorkFormPage(initialDate:') &&
          dayDetail.contains('QuickAddSheet.show('),
      'A4 day_detail_page 剥注释后不含 WorkFormPage(initialDate: 且含 QuickAddSheet.show(',
      'WorkFormPage(initialDate:=${dayDetail.contains('WorkFormPage(initialDate:')} show=${dayDetail.contains('QuickAddSheet.show(')}');
  _check(!records.contains('WorkFormPage(companyId:') &&
          records.contains('QuickAddSheet.show('),
      'A5 records_page 工作分支不含 WorkFormPage(companyId: 且含 QuickAddSheet.show(',
      'WorkFormPage(companyId:=${records.contains('WorkFormPage(companyId:')} show=${records.contains('QuickAddSheet.show(')}');

  // ── A6：WorkFormPage( 收口（剔类定义行后恰 1 处，位于 quick_add_sheet 展开出口）─
  final a6 = _uiCount('WorkFormPage(',
      exclude: {'lib/ui/work_form_page.dart'});
  _check(a6.total == 1 && a6.files.length == 1 && a6.files.first == 'lib/ui/quick_add_sheet.dart',
      'A6 lib/ui 剔 work_form_page.dart 类定义行后 WorkFormPage( 恰 1 处，且位于 quick_add_sheet.dart（展开出口）',
      'total=${a6.total}（期望 1）files=${a6.files.toList()}');

  // ── A7：W5 initialDate 参导入 / P（四处调用点 + getter）──────────────────
  final a7a = _count(quickAdd, 'this.initialDate');
  final a7b = _count(quickAdd, 'initialDate:');
  final a7c = _count(quickAdd, 'workDate: _workDate');
  final a7d = _count(quickAdd, 'DateTime get _workDate');
  _check(a7a == 1 && a7b == 2 && a7c == 2 && a7d == 1,
      'A7 quick_add_sheet: this.initialDate==1, initialDate:==2, workDate: _workDate==2, DateTime get _workDate==1',
      'this.initialDate=$a7a(期望1) initialDate:=$a7b(期望2) workDate:_workDate=$a7c(期望2) get=$a7d(期望1)');

  // ── A8：quick_add_sheet 剥注释后不含 _today() 直传（两式均 0 命中）────────
  final a8a = _count(quickAdd, 'workDate: _today()');
  final a8b = _count(quickAdd, 'initialDate: _today()');
  _check(a8a == 0 && a8b == 0,
      'A8 quick_add_sheet 剥注释后不含 workDate: _today() / initialDate: _today()',
      'workDate:_today()=$a8a initialDate:_today()=$a8b（均期望 0）');

  // ── A9：死路由判据（routes.dart / main.dart）────────────────────────────
  _check(!routesSrc.contains('static const String records') &&
          !routesSrc.contains('static const String overview') &&
          routesSrc.contains('static const String companies') &&
          !mainSrc.contains('case Routes.records:') &&
          !mainSrc.contains('case Routes.overview:') &&
          mainSrc.contains('case Routes.companies:'),
      'A9 死路由判据：routes 无 records/overview 常量、保留 companies；main 无对应 case、保留 case Routes.companies:',
      'routes.records=${routesSrc.contains('static const String records')} routes.overview=${routesSrc.contains('static const String overview')} routes.companies=${routesSrc.contains('static const String companies')} main.caseRecords=${mainSrc.contains('case Routes.records:')} main.caseOverview=${mainSrc.contains('case Routes.overview:')} main.caseCompanies=${mainSrc.contains('case Routes.companies:')}');

  // ── A10：Routes.workForm 仍 ≥1 活调用；paymentForm 仍 =1（B1 保留）───────
  final wfCount = _treeCount('lib', 'pushNamed(Routes.workForm)');
  final pfCount = _treeCount('lib', 'pushNamed(Routes.paymentForm)');
  _check(wfCount >= 1 && pfCount == 1,
      'A10 pushNamed(Routes.workForm) 仍 >=1（stats_page:267 保留活路由）；pushNamed(Routes.paymentForm) 仍 ==1（overview_page）',
      'workForm=$wfCount（期望>=1） paymentForm=$pfCount（期望==1）');

  // ── A11：全部改动文件剥注释后禁浮点零命中（含检测器正例自检）────────────
  final changed = <String, String>{
    'overview_page.dart': overview,
    'company_detail_page.dart': companyDetail,
    'day_detail_page.dart': dayDetail,
    'records_page.dart': records,
    'quick_add_sheet.dart': quickAdd,
    'calendar_page.dart': calendar,
    'holiday_mark_page.dart':
        _stripComments(_read('lib/ui/holiday_mark_page.dart')),
  };
  final a11hits = <String>[];
  changed.forEach((name, code) {
    final v = _floatViolations(code);
    if (v.isNotEmpty) a11hits.add('$name: ${v.join(",")}');
  });
  // 检测器正例自检（负例经 7 文件零命中验证）。
  final detectorOk = _floatViolations('final x = fen / 100;').isNotEmpty &&
      _floatViolations('final y = a / 10;').isNotEmpty &&
      _floatViolations('final z = a ~/ 10;').isEmpty;
  _check(a11hits.isEmpty && detectorOk,
      'A11 全部改动文件剥注释后零禁浮点命中（fen/100、double.parse、.round、.toDouble、浮点/10、/100.0）+ 检测器正负例自检',
      '命中=$a11hits detectorOk=$detectorOk');

  // ── A12：pubspec.yaml dependencies 未新增（尤其无 shared_preferences）────
  //   ★ YAML 注释剥离后判定：pubspec 注释里含 `shared_preferences` 字样，若读原始文本会假阳性。
  final depKeys = _pubspecDependencyKeys(pubspecSrc);
  const allowed = {
    'flutter',
    'cupertino_icons',
    'sqflite',
    'sqflite_common',
    'path_provider',
    'share_plus',
    'file_picker',
  };
  final extra = depKeys.difference(allowed);
  _check(pubspecSrc.isNotEmpty &&
          !_stripYamlComments(pubspecSrc).contains('shared_preferences') &&
          extra.isEmpty,
      'A12 pubspec.yaml dependencies 未新增（键集 ⊆ 已知 7 项，且剥 YAML 注释后无 shared_preferences）',
      '可读=${pubspecSrc.isNotEmpty} 新增键=$extra 含shared_preferences(剥注释后)=${_stripYamlComments(pubspecSrc).contains('shared_preferences')} keys=$depKeys');

  // ── A13：calendar 含 HolidayMarkPage( 命令式 push + 原 cell 点击路径仍在 ──
  _check(calendar.contains('HolidayMarkPage(') &&
          calendar.contains('onTap: () => _openDay(date)'),
      'A13 calendar 含 HolidayMarkPage( 命令式 push 且原 onTap: () => _openDay(date) 仍在（保 AC-P03-08）',
      'HolidayMarkPage(=${calendar.contains('HolidayMarkPage(')} openDay=${calendar.contains('onTap: () => _openDay(date)')}');

  // ── A14（辅助项）：onHolidayTap 不在 onTap: () => _openDay(date) 同一行 ──
  final a14lines = calendar.split('\n').where((l) => l.contains('onTap: () => _openDay(date)'));
  final a14sameLine = a14lines.any((l) => l.contains('onHolidayTap'));
  _check(!a14sameLine && a14lines.isNotEmpty,
      'A14（辅助）onHolidayTap 与 onTap: () => _openDay(date) 不在同一行（独立入口）｜主证据见 A22',
      'openDay 行数=${a14lines.length} 同行含 onHolidayTap=$a14sameLine');

  // ── A15：P01 FAB 形态（floatingActionButton: 恰 1 处 + FloatingActionButton ≥1）─
  final a15a = _count(overview, 'floatingActionButton:');
  final a15b = _count(overview, 'FloatingActionButton');
  _check(a15a == 1 && a15b >= 1,
      'A15 overview 剥注释后 floatingActionButton: 恰 1 处 且 FloatingActionButton >=1 处（P01 FAB）',
      'floatingActionButton:=$a15a(期望1) FloatingActionButton=$a15b(期望>=1)');

  // ── A16：两条用户可见文案各恰 1 处（收款按钮未删）────────────────────────
  final a16a = _count(overview, '记一笔工作');
  final a16b = _count(overview, '记一笔收款');
  _check(a16a == 1 && a16b == 1,
      'A16 overview 剥注释后「记一笔工作」恰 1 处、「记一笔收款」恰 1 处（防误删收款按钮）',
      '记一笔工作=$a16a（期望1） 记一笔收款=$a16b（期望1）');

  // ── A17：_workDate getter 存在且体内取 initialDate ?? _today() ──────────
  final a17a = _count(quickAdd, 'DateTime get _workDate');
  final a17b = _count(quickAdd, 'widget.initialDate ?? _today()');
  _check(a17a == 1 && a17b == 1,
      'A17 quick_add_sheet 含 DateTime get _workDate 恰 1 处，且体内含 widget.initialDate ?? _today() 恰 1 处',
      'get=$a17a(期望1) body=$a17b(期望1)');

  // ── A18：calendar const HolidayMarkPage() 恰 1 处 且总命中恰 1（证 α 非 β）─
  final a18a = _count(calendar, 'const HolidayMarkPage()');
  final a18b = _count(calendar, 'HolidayMarkPage(');
  _check(a18a == 1 && a18b == 1,
      'A18 calendar 剥注释后 const HolidayMarkPage() 恰 1 处，且 HolidayMarkPage( 总命中恰 1 处（无 initialDate: 传参 = 证 α）',
      'const=$a18a(期望1) total=$a18b(期望1)');

  // ── A19：E3 预置归属日**实参**（防「静默记到今天」）───────────────────────
  final a19 = _reCount(dayDetail,
      RegExp(r'QuickAddSheet\.show\(\s*context\s*,\s*date\s*:\s*widget\.date\s*,?\s*\)'));
  _check(a19 == 1,
      'A19 ★ day_detail_page 正则 QuickAddSheet.show(context, date: widget.date) 恰 1 处（E3 预置实参）',
      '命中=$a19（期望1）');

  // ── A20：E2 预置公司实参 ────────────────────────────────────────────────
  final a20 = _reCount(companyDetail,
      RegExp(r'QuickAddSheet\.show\(\s*context\s*,\s*companyId\s*:\s*widget\.companyId\s*,?\s*\)'));
  _check(a20 == 1,
      'A20 ★ company_detail_page 正则 QuickAddSheet.show(context, companyId: widget.companyId) 恰 1 处（E2 预置实参）',
      '命中=$a20（期望1）');

  // ── A21：E4 预置公司实参（工作分支）─────────────────────────────────────
  final a21whole = _reCount(records,
      RegExp(r'QuickAddSheet\.show\(\s*context\s*,\s*companyId\s*:\s*f\.companyId\s*,?\s*\)'));
  final a21branch = _reCount(
      _blockAfter(records, 'Future<void> _handleEmptyAction('),
      RegExp(r'QuickAddSheet\.show\(\s*context\s*,\s*companyId\s*:\s*f\.companyId\s*,?\s*\)'));
  _check(a21whole == 1 && a21branch == 1,
      'A21 ★ records_page 工作分支内正则 QuickAddSheet.show(context, companyId: f.companyId) 恰 1 处（E4 预置实参）',
      'whole=$a21whole branch=$a21branch（均期望1）');

  // ── A22：角标真的接线（三条件缺一即红）──────────────────────────────────
  final a22re = _reCount(calendar,
      RegExp(r'onHolidayTap:\s*_holidayByDate\[key\]\s*==\s*null\s*\?\s*null\s*:\s*\(\)\s*=>\s*_openHolidayMark\(\),?'));
  final a22cnt = _count(calendar, 'onHolidayTap');
  final a22m = _count(calendar, '_openHolidayMark(');
  _check(a22re == 1 && a22cnt >= 4 && a22m >= 2,
      'A22 ★ calendar：① 调用处传参正则恰 1 处 ② onHolidayTap>=4 ③ _openHolidayMark(>=2（三条件缺一即红）',
      '①=$a22re(期望1) ②=$a22cnt(期望>=4) ③=$a22m(期望>=2)');

  // ── A23：records else 分支（P10 收款）保护 ──────────────────────────────
  final a23 = _count(records, 'PaymentFormPage(companyId: f.companyId)');
  _check(a23 == 1,
      'A23 records_page 剥注释后 PaymentFormPage(companyId: f.companyId) 恰 1 处（保护 P10 收款 else 分支）',
      '命中=$a23（期望1）');

  // ── A24：E1 无预置（_openWorkForm 方法体内 show 实参仅 context）──────────
  final ownBody = _blockAfter(overview, 'Future<void> _openWorkForm()');
  final ownArgs = RegExp(r'QuickAddSheet\.show\(([^)]*)\)')
      .allMatches(ownBody)
      .map((m) => m.group(1)!.trim())
      .toList();
  _check(ownArgs.length == 1 &&
          ownArgs.first == 'context' &&
          !ownArgs.first.contains('companyId:') &&
          !ownArgs.first.contains('date:'),
      'A24 overview _openWorkForm 方法体内 QuickAddSheet.show 实参不含 companyId:/date:（E1 = 新建态无预置）',
      '实参=$ownArgs');

  // ── A25：`_DayCell` 角标图标 + 命中区仍在（堵 E-1 / E-2）─────────────────
  //   ★ E-1 根因 = 主理人 v4 修 R-01 把 A22 收紧为三条件时**丢掉了 v3 曾有的
  //     `Icon(Icons.local_offer` 检查** ⇒ 删角标仍 38/0（AC-P03-06 唯一可视入口消失）。本条补回。
  //   ★ 空白容错（lead 配对审查加固 2026-10-13）：`dart format` 会把
  //     `child: Icon(Icons.local_offer, size: 10, color: Colors.red.shade300),`
  //     （22 空格缩进 = 84 列 > 80）折成 tall style ⇒ 裸子串会假红。故改 `\s*` 容错。
  //     计数强度不变（①仍恰 1、②仍 >=1、③仍恰 1），仅消除「语义等价重排」的假红。
  final a25a = _reCount(calendar, RegExp(r'Icon\(\s*Icons\.local_offer'));
  final a25b = _reCount(calendar, RegExp(r'GestureDetector\s*\('));
  final a25c = _reCount(calendar, RegExp(r'behavior:\s*HitTestBehavior\.opaque'));
  _check(a25a == 1 && a25b >= 1 && a25c == 1,
      'A25 ★ calendar：① Icon(Icons.local_offer 恰 1 处 ② GestureDetector( >=1 处 ③ behavior: HitTestBehavior.opaque 恰 1 处（缺一即红；堵 E-1/E-2）',
      '①=$a25a(期望1) ②=$a25b(期望>=1) ③=$a25c(期望1)');

  // ── A26：P01 FAB 真的接上方法 + 方法体保留刷新（堵 E-3；与 E-5 同源）──────
  //   ★ 定位到 `floatingActionButton:` 表达式**块内**（用 `_parenAfter`，非整文件计数），
  //     防「FAB 的 onPressed 改动后，文件别处另有同名 onPressed 造成假绿/假红」。
  final fabBlock = _parenAfter(overview, 'floatingActionButton:');
  final a26a = _count(fabBlock, 'onPressed: _openWorkForm');
  final workFormBody = _blockAfter(overview, 'Future<void> _openWorkForm()');
  final a26b = _count(workFormBody, 'await _load()');
  _check(a26a == 1 && a26b >= 1,
      'A26 ★ overview：① FAB 块内 onPressed: _openWorkForm 恰 1 处 ② _openWorkForm 方法体内 await _load() >=1 处（堵 E-3/E-5 同源）',
      '①=$a26a(期望1) ②=$a26b(期望>=1) fabBlock内onPressed总数=${_count(fabBlock, "onPressed:")} fabBlock空=${fabBlock.isEmpty}');

  // ── A27：两处触发按钮未断线（堵 E-4 / E-5）──────────────────────────────
  //   ① P04「+ 记一笔」触发按钮（E-4）；② P01「记一笔收款」按钮（E-5；A16 只数字案）。
  final a27a = _count(dayDetail, 'onPressed: _openWorkNew');
  final actionButtonsBody =
      _blockAfter(overview, 'class _ActionButtons extends StatelessWidget');
  final a27b = _count(actionButtonsBody, 'onPressed: onPaymentTap');
  _check(a27a >= 1 && a27b == 1,
      'A27 ★ ① day_detail_page 含 onPressed: _openWorkNew >=1 处（堵 E-4）② overview _ActionButtons 类体内 onPressed: onPaymentTap 恰 1 处（堵 E-5）',
      '①=$a27a(期望>=1) ②=$a27b(期望1)');

  print('  · 设计冻结时刻参考 _freeze=$_freeze（本项不作断言，仅留痕）');
}

/// 供 S8 置红实验复用：返回指定文件的剥注释源码（便于人工比对）。
// ignore: unused_element
String debugStripped(String relPath) => _stripComments(_read(relPath));
