/// Wave B（P03 日历 / P04 日详情 / P05 记录详情编辑）批末**可执行断言**（纯 Dart，无需 Flutter / 无需设备）。
///
/// 运行（与 `tool/verify_db.dart` / `tool/verify_waveA.dart` 同一套办法）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// set WORKLOG_USE_SYSTEM_SQLITE=1
/// "D:\workspace\software\installed\tools\FlyEnv-Data\app\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev tool\verify_waveB.dart
/// ```
/// 退出码：`0` = 全通过；`1` = 有失败断言。
/// **为何必须 `--disable-dart-dev` + `WORKLOG_USE_SYSTEM_SQLITE=1`**：见 `tool/verify_db.dart` 头部。
///
/// ═══════════════════════════════════════════════════════════════════════════
/// 证据层级标注（本项目纪律，`docs/00-项目总览/DECISIONS.md` D-8「证据三分」）
/// ═══════════════════════════════════════════════════════════════════════════
///   【实测级】§1 / §2 / §3：真实内存库（`databaseFactoryFfi` + `inMemoryDatabasePath`）
///             播种 → 调 **真实 DB 方法** → 断言返回值 / 原生列终态。结论**可直接采信**。
///   【复刻实测（部分等价）】§4：用**真实 `AmountEngine`** 复刻页面 `_target()` 取数链，
///             但**仅驱动 hourly-manual 分支**，且复刻体硬编码 `halfDayRatio: 5` /
///             `name: '（快照重建）'`（页面实际用 `_halfDayRatio(rec)` / `_ruleName ?? ''`）
///             ⇒ **整体等价性未证明**，结论**限 hourly-manual 分支**。
///   【读码级 · 源码断言】§5：读**真实源码文件**做**字符串**检查，分三档强度：
///             (a) **整行精确匹配**（强）：仅 `baseRate` 反推行、`_roundDiv` 公式行、C-01 草稿守卫行；
///             (b) **关键片段包含**（中）：如 `isOvertime: rd.overtime,`、可空字段显式传全；
///             (c) **存在性检查**（弱）：如 `contains('_db.softDeleteWorkRecord(')`。
///             **加固（2026-10-17 · 审计 04 假覆盖修复）**：§5 全部断言一律作用于
///             **剥注释后**的源码（`_stripComments`，行注释 + 块注释），并对关键项**切片到
///             调用点看实参 / 精确计数**（⑩⑭⑮⑲）。理由：`calendar_page.dart:12/78/80` 等
///             doc 注释含与代码相同的字面量，未剥注释时 `contains` 会被注释「救活」
///             （审计 F1/F2/F3/F4 实测：改坏代码仍 76/0）。
///             ⇒ **不得**据此宣称「页面与脚本逐字一致」；**P05 重算类结论一律降级为【读码级】**。
///   【不覆盖 · [真机]】UI 渲染 / 手势 / 弹窗 / 高亮 / 虚线框 / 折叠交互——
///             本脚本**不能**替代，须末次出包真机验收（见 `13-WaveB-实现设计.md` §2）。
///
/// 契约来源：`02-需求与验收.md` §D.3/§D.4/§D.5；`07-UI实现规格.md` §3.3/§3.4/§3.5/§4.2；
///           `03-数据模型与信息架构.md` §7.1；`13-WaveB-实现设计.md`。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/db/database.dart';
import '../lib/models/company.dart';
import '../lib/models/ledger.dart';
import '../lib/models/pricing_rule.dart';
import '../lib/models/types.dart';
import '../lib/models/work_record.dart';
import '../lib/services/amount_engine.dart';

/// 与 `tool/verify_db.dart` 同源的 Windows 兜底（预加载系统 SQLite）。
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

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('  ✓ $name');
  } else {
    _fail++;
    print('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

String _read(String relPath) {
  final f = File(relPath);
  return f.existsSync() ? f.readAsStringSync() : '';
}

// ── 静态断言工具（读码级）────────────────────────────────────────────────────
// 手法沿用本项目唯一「0 假覆盖」脚本 `tool/verify_waveD2.dart`：
//   ① 剥注释后再断言（否则文档注释里出现过同一字面量会救活被改坏的代码 —— 审计 F1/F2 根因）；
//   ② 切片到具体调用点看**实参**（否则「两处字面量对调 / 单点取值写反」逃逸 —— 审计 F4）；
//   ③ 计数精确到确定期望（否则「存在 ≥1 处正确」即绿 —— 审计 F3）。
final RegExp _commentRe = RegExp(r'(^|\s)//.*$', multiLine: true);
final RegExp _blockCommentRe = RegExp(r'/\*.*?\*/', dotAll: true);

/// 剥行注释 + 块注释。**所有** `contains`/正则断言必须作用于其返回值。
String _stripComments(String src) =>
    src.replaceAll(_blockCommentRe, '').replaceAll(_commentRe, '');

/// `needle` 在 `code` 中的非重叠出现次数。
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

/// 逐处提取 `<key>\s*:\s*([^,\n]+)` 的**实际取值**（去首尾空白）。
/// 用于「单点逃逸」防线：`contains` 只看「存在 ≥1 处正确」，抓不住「某一处取值写反」。
List<String> _extractValues(String code, String key) {
  final re = RegExp('$key\\s*:\\s*([^,\\n]+)');
  return [for (final m in re.allMatches(code)) m.group(1)!.trim()];
}

/// 取 `marker` 之后**第一个** `(` 到配对 `)` 的完整表达式（含 `marker`）。
/// 用于把断言锚定到某个调用点的**实参**。
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

/// 取 [from] 到 [to] 之间的源码切片（把断言锚定到单个 getter / 方法体）。
String _slice(String code, String from, String to) {
  final i = code.indexOf(from);
  if (i < 0) return '';
  final j = code.indexOf(to, i + from.length);
  return j < 0 ? code.substring(i) : code.substring(i, j);
}

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ── 固定数据 ─────────────────────────────────────────────────────────────────
const _ledgerId = 'a0000000-0000-4000-8000-0000000000b0';
const _cidA = 'a0000000-0000-4000-8000-0000000000aa';
const _cidB = 'a0000000-0000-4000-8000-0000000000bb';
const _ruleC = 'c0000000-0000-4000-8000-0000000000cc';

// 归属日：10-05 / 10-06 / 10-07
final _d05 = DateTime(2026, 10, 5);
final _d06 = DateTime(2026, 10, 6);
final _d07 = DateTime(2026, 10, 7);

int _sumAmount(List<WorkRecord> xs) =>
    xs.fold<int>(0, (s, w) => s + w.amountSnapshot);

/// 复刻 `record_detail_page.dart: _target()` 的基础单价反推 + `_roundDiv`（§4 自证逐字一致）。
int _roundDiv(int numerator, int denominator) {
  if (numerator < 0 || denominator <= 0) return 0;
  return (numerator + denominator ~/ 2) ~/ denominator;
}

Future<void> main() async {
  _maybePreloadSystemSqlite();
  sqfliteFfiInit();
  final db = AppDatabase.instance
    ..configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  await db.open();

  await db.upsertLedger(Ledger(id: _ledgerId, name: '账本', createdAt: _d05));
  await db.upsertCompany(Company(
      id: _cidA,
      ledgerId: _ledgerId,
      name: '甲建筑',
      color: 0xE53935,
      createdAt: _d05,
      updatedAt: _d05));
  await db.upsertCompany(Company(
      id: _cidB,
      ledgerId: _ledgerId,
      name: '乙劳务',
      color: 0x1E88E5,
      createdAt: _d05,
      updatedAt: _d05));
  await db.upsertPricingRule(PricingRule(
    id: _ruleC,
    companyId: _cidA,
    name: '砌墙',
    method: PricingMethod.hourly,
    baseRate: 6000, // ¥60/h
    halfDayRatio: 5,
    overtimeRate: 15,
    weekendRate: 10,
    holidayRate: 10,
    createdAt: _d05,
    updatedAt: _d05,
  ));

  // w1/w5/w2 同属 10-05（created_at 递增 → 用于验证组内升序）；w3 属公司 B；w4 属 10-06。
  WorkRecord work(String id, String cid, DateTime date, int amount,
          {RecordStatus status = RecordStatus.confirmed,
          DateTime? createdAt,
          bool overnight = false,
          DateTime? start,
          DateTime? end,
          String? qtyUnit,
          int? autoReference,
          AmountSource source = AmountSource.auto,
          double qty = 2}) =>
      WorkRecord(
        id: id,
        workDate: date,
        companyId: cid,
        pricingRuleId: _ruleC,
        methodSnapshot: PricingMethod.hourly,
        qtySnapshot: qty,
        qtyUnitSnapshot: qtyUnit,
        startTime: start,
        endTime: end,
        overnight: overnight,
        rateSnapshot: 5000,
        rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
        amountSnapshot: amount,
        amountSource: source,
        autoReferenceAmount: autoReference,
        status: status,
        createdAt: createdAt ?? date,
        updatedAt: createdAt ?? date,
      );

  await db.upsertWorkRecord(work('w0000001-0000-4000-8000-000000000001', _cidA,
      _d05, 100000,
      createdAt: DateTime(2026, 10, 5, 9)));
  await db.upsertWorkRecord(work('w0000001-0000-4000-8000-000000000002', _cidA,
      _d05, 999999,
      status: RecordStatus.draft, createdAt: DateTime(2026, 10, 5, 11)));
  await db.upsertWorkRecord(work('w0000001-0000-4000-8000-000000000003', _cidB,
      _d05, 50000,
      status: RecordStatus.settled, createdAt: DateTime(2026, 10, 5, 12)));
  await db.upsertWorkRecord(work(
      'w0000001-0000-4000-8000-000000000004', _cidA, _d06, 20000,
      createdAt: DateTime(2026, 10, 6, 9)));
  // 跨夜记录：归属日 = 开始日 10-05（AC-10 / Q6）。
  await db.upsertWorkRecord(work(
      'w0000001-0000-4000-8000-000000000005', _cidA, _d05, 30000,
      overnight: true,
      start: DateTime(2026, 10, 5, 22),
      end: DateTime(2026, 10, 5, 2),
      createdAt: DateTime(2026, 10, 5, 10)));
  // w6：快照护栏用例专用（带可空快照字段）。**置于 11 月**，避免污染 10 月日历口径用例。
  await db.upsertWorkRecord(work(
      'w0000001-0000-4000-8000-000000000006', _cidA, DateTime(2026, 11, 1), 12000,
      qtyUnit: '趟',
      start: DateTime(2026, 11, 1, 8),
      end: DateTime(2026, 11, 1, 12),
      autoReference: 123,
      createdAt: DateTime(2026, 11, 1, 9)));

  // ═══════════════════════════════════════════════════════════════════════
  print('== 1.5 整表排序口径（listWorkRecords() 归日 DESC → 「最近一条」在首）==');
  // ═══════════════════════════════════════════════════════════════════════
  {
    // 审计 F7/D1B-3b：`database.dart:1272` 的 `attribution_date DESC, created_at DESC`
    // 若被改为 ASC（「最近一条」变「最早一条」），原两脚本皆 0 红。
    // 本段用真实 DB 回读兜住该口径 —— 行为级断言，与页面/弹层无关地证明底层排序。
    final all = await db.listWorkRecords();
    check(
      '★1 整表排序：首条 = 归日最新（w6 @2026-11-01）—— 证明底层 ORDER BY 归日 DESC 生效',
      all.isNotEmpty &&
          all.first.id.endsWith('000006') &&
          _fmt(all.first.workDate) == '2026-11-01',
      '首条=${all.isEmpty ? "空" : "${all.first.id.substring(29)}@${_fmt(all.first.workDate)}"}',
    );
    check(
      '★2 **反证**：末条归日 ≠ 首条归日（集合含多日，排序确有区分力，非恒真）',
      all.length >= 2 && _fmt(all.last.workDate) != _fmt(all.first.workDate),
      '首=${all.isEmpty ? "-" : _fmt(all.first.workDate)} 末=${all.isEmpty ? "-" : _fmt(all.last.workDate)}',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  print('== 1. P03 日历日期口径（实测级：真实 DB）==');
  // ═══════════════════════════════════════════════════════════════════════
  {
    final monthStart = DateTime(2026, 10, 1);
    final monthEnd = DateTime(2026, 10, 31);
    final effective = await db.listWorkRecords(
      startDate: monthStart,
      endDate: monthEnd,
      includeDraft: false, // 日历口径（AC-P03-04 / AC-32）
    );
    check(
      '① 日历查询(includeDraft:false) = 4 条（排除草稿 w2）',
      effective.length == 4,
      '实际 ${effective.length} 条：${effective.map((w) => w.id.substring(29)).toList()}',
    );
    check(
      '② 4 条中不含 status=draft',
      effective.every((w) => w.status != RecordStatus.draft),
      '含草稿行',
    );
    check(
      '③ 含 settled（w3 应为唯一 settled）',
      effective.where((w) => w.status == RecordStatus.settled).length == 1,
      'settled 数 != 1',
    );
    check(
      '④ 月有效合计 = 100000+50000+20000+30000 = 200000 分',
      _sumAmount(effective) == 200000,
      '实际 ${_sumAmount(effective)}',
    );

    // 10-05 当日有效记录：w1(100000) + w3(50000) + w5(30000，跨夜归开始日)
    final d05 = await db.listWorkRecords(
        startDate: _d05, endDate: _d05, includeDraft: false);
    check(
      '⑤ 10-05 有效=3 条、小计 180000（草稿 w2 不计入）',
      d05.length == 3 && _sumAmount(d05) == 180000,
      '条数=${d05.length} 小计=${_sumAmount(d05)}',
    );
    check(
      '⑥ 跨夜记录 w5 归「开始日」10-05（在 10-05 结果内）',
      d05.any((w) => w.id.endsWith('000005')),
      '10-05 结果缺 w5',
    );
    final d06 = await db.listWorkRecords(
        startDate: _d06, endDate: _d06, includeDraft: false);
    check(
      '⑦ 跨夜记录 w5 不出现在 10-06（归属日 = 开始日，非结束日）',
      !d06.any((w) => w.id.endsWith('000005')) && d06.length == 1,
      '10-06 条数=${d06.length}',
    );

    // 对照组：includeDraft:true 会把草稿纳入 → 证明过滤真的生效。
    final withDraft = await db.listWorkRecords(
        startDate: monthStart, endDate: monthEnd, includeDraft: true);
    check(
      '⑧ 对照组：includeDraft:true → 5 条（w2 草稿进入），与 ① 相差恰 1',
      withDraft.length == 5 && withDraft.length - effective.length == 1,
      'withDraft=${withDraft.length} effective=${effective.length}',
    );

    // 当月色点 distinct（03 §7.1）：10-05 涉及公司 A、B 两家。
    final colors = d05.map((w) => w.companyId).toSet();
    check('⑨ 10-05 distinct 公司 = 2（A/B 各一色点）', colors.length == 2,
        '实际 ${colors.length}');
  }

  // ═══════════════════════════════════════════════════════════════════════
  print('== 2. P04 日详情分组数据前提（实测级）==');
  // ═══════════════════════════════════════════════════════════════════════
  {
    final lenient = await db.listWorkRecordsLenient(
        startDate: _d05, endDate: _d05, includeDraft: true);
    check('① 容错读无坏行（skipped == 0）', lenient.skipped.isEmpty,
        'skipped=${lenient.skippedCount}');
    check('② 10-05 台账读含草稿 = 4 条（w1/w2/w3/w5）', lenient.rows.length == 4,
        '实际 ${lenient.rows.length}');

    // 按公司分组（复刻页面 _groups 语义）。
    final map = <String, List<WorkRecord>>{};
    for (final w in lenient.rows) {
      map.putIfAbsent(w.companyId, () => <WorkRecord>[]).add(w);
    }
    check('③ 分组数 = 2（公司 A / 公司 B）', map.length == 2, '实际 ${map.length}');
    final gA = map[_cidA]!..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final gB = map[_cidB]!;
    check('④ A 组 3 条（w1/w5/w2）', gA.length == 3, '实际 ${gA.length}');
    check('⑤ A 组按 createdAt 升序（w1→w5→w2）',
        gA[0].id.endsWith('000001') &&
            gA[1].id.endsWith('000005') &&
            gA[2].id.endsWith('000002'),
        '实际顺序 ${gA.map((w) => w.id.substring(29)).toList()}');
    check('⑥ B 组 1 条', gB.length == 1, '实际 ${gB.length}');

    // 组小计（仅有效记录）。
    int eff(List<WorkRecord> xs) => xs
        .where((w) => w.status != RecordStatus.draft)
        .fold<int>(0, (s, w) => s + w.amountSnapshot);
    check('⑦ A 组小计 = 130000（草稿 999999 不计入）', eff(gA) == 130000,
        '实际 ${eff(gA)}');
    check('⑧ B 组小计 = 50000', eff(gB) == 50000, '实际 ${eff(gB)}');
    final dayTotal = eff(lenient.rows);
    check('⑨ 当日合计 == Σ 各组小计（AC-P04-02 自检）',
        dayTotal == eff(gA) + eff(gB),
        'day=${dayTotal} Σ组=${eff(gA) + eff(gB)}');
    check('⑩ 当日合计 = 180000', dayTotal == 180000, '实际 $dayTotal');
    check('⑪ 草稿条数 = 1（提示「不含 N 条草稿」）',
        lenient.rows.where((w) => w.status == RecordStatus.draft).length == 1,
        '实际草稿数 != 1');
  }

  // ═══════════════════════════════════════════════════════════════════════
  print('== 3. P05 快照护栏数据层前提（实测级）==');
  // ═══════════════════════════════════════════════════════════════════════
  {
    const w1 = 'w0000001-0000-4000-8000-000000000001';
    const w6 = 'w0000001-0000-4000-8000-000000000006';

    // 3.1 updateWorkRecordMeta 只改 Meta，快照四件套不变（AC-P05-13 / D2 断言）。
    final before = (await db.getWorkRecord(w6))!;
    await db.updateWorkRecordMeta(
      id: w6,
      workDate: DateTime(2026, 10, 9),
      note: '改备注',
      status: RecordStatus.settled,
      updatedAt: DateTime(2026, 10, 9, 12),
    );
    final afterMeta = (await db.getWorkRecord(w6))!;
    check('① 改 Meta(归属日/备注/状态)：attribution_date 已变',
        _fmt(afterMeta.workDate) == '2026-10-09',
        '实际 ${_fmt(afterMeta.workDate)}');
    check('② 改 Meta：amountSnapshot 不变', afterMeta.amountSnapshot == before.amountSnapshot,
        '${before.amountSnapshot} → ${afterMeta.amountSnapshot}');
    check('③ 改 Meta：rateSnapshot 不变', afterMeta.rateSnapshot == before.rateSnapshot,
        '${before.rateSnapshot} → ${afterMeta.rateSnapshot}');
    check('④ 改 Meta：rateDetailSnapshot.appliedRate 不变',
        afterMeta.rateDetailSnapshot.appliedRate == before.rateDetailSnapshot.appliedRate,
        '${before.rateDetailSnapshot.appliedRate} → ${afterMeta.rateDetailSnapshot.appliedRate}');
    check('⑤ 改 Meta：autoReferenceAmount 不变（123）',
        afterMeta.autoReferenceAmount == 123,
        '实际 ${afterMeta.autoReferenceAmount}');
    check('⑥ 改 Meta：status 已置 settled', afterMeta.status == RecordStatus.settled,
        '实际 ${afterMeta.status}');

    // 3.2 updateWorkRecordMeta 对不存在 id 抛错。
    var threw = false;
    try {
      await db.updateWorkRecordMeta(
          id: 'no-such-id', note: 'x', updatedAt: DateTime(2026, 10, 9));
    } catch (_) {
      threw = true;
    }
    check('⑦ updateWorkRecordMeta(不存在 id) 抛错', threw, '未抛错');

    // 3.3 replaceWorkRecordSnapshot 「传全」→ 保留传入终态；Meta 列不动。
    final t1 = DateTime(2026, 10, 7, 8);
    final t2 = DateTime(2026, 10, 7, 18);
    await db.replaceWorkRecordSnapshot(
      id: w6,
      rateSnapshot: 7000,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
      amountSnapshot: 14000,
      amountSource: AmountSource.auto,
      autoReferenceAmount: 555, // 显式
      qtySnapshot: 2,
      qtyUnitSnapshot: '趟', // 显式
      startTime: t1, // 显式
      endTime: t2, // 显式
      overnight: false,
      updatedAt: DateTime(2026, 10, 7, 20),
    );
    var raw = (await db.db!.query('work_record',
            where: 'id = ?', whereArgs: [w6], limit: 1))
        .first;
    check('⑧ 传全：unit_price_snapshot=7000', raw['unit_price_snapshot'] == 7000,
        '实际 ${raw['unit_price_snapshot']}');
    check('⑨ 传全：quantity_unit_snapshot=趟（保留）',
        raw['quantity_unit_snapshot'] == '趟', '实际 ${raw['quantity_unit_snapshot']}');
    check('⑩ 传全：start_time/end_time 保留', raw['start_time'] == '08:00' && raw['end_time'] == '18:00',
        '${raw['start_time']} / ${raw['end_time']}');
    check('⑪ 传全：auto_reference=555', raw['auto_reference'] == 555,
        '实际 ${raw['auto_reference']}');
    check('⑫ replaceWorkRecordSnapshot 不改 attribution_date（仍 2026-10-09）',
        raw['attribution_date'] == '2026-10-09', '实际 ${raw['attribution_date']}');
    check('⑬ replaceWorkRecordSnapshot 不改 note/status（Meta 列）',
        raw['note'] == '改备注' && raw['status'] == 'settled',
        'note=${raw['note']} status=${raw['status']}');

    // 3.4 「漏传」→ 可空列被**清空**（AC-P05-11 反例：证明硬契约危害真实存在）。
    await db.replaceWorkRecordSnapshot(
      id: w6,
      rateSnapshot: 7000,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
      amountSnapshot: 14000,
      amountSource: AmountSource.auto,
      // 故意漏传 autoReferenceAmount / qtyUnitSnapshot / startTime / endTime
      qtySnapshot: 2,
      overnight: false,
      updatedAt: DateTime(2026, 10, 7, 21),
    );
    raw = (await db.db!.query('work_record',
            where: 'id = ?', whereArgs: [w6], limit: 1))
        .first;
    check('⑭ 漏传：auto_reference 被清空（NULL）', raw['auto_reference'] == null,
        '实际 ${raw['auto_reference']}');
    check('⑮ 漏传：quantity_unit_snapshot 被清空（NULL）',
        raw['quantity_unit_snapshot'] == null, '实际 ${raw['quantity_unit_snapshot']}');
    check('⑯ 漏传：start_time / end_time 被清空（NULL）',
        raw['start_time'] == null && raw['end_time'] == null,
        '${raw['start_time']} / ${raw['end_time']}');
    check('⑰ 漏传：非空列 quantity 保留（2，传 null 才是保留）',
        raw['quantity'] == 2, '实际 ${raw['quantity']}');

    // 3.5 updateWorkRecordMeta 对已清空快照的记录再跑一次，仍不改金额（护栏持续有效）。
    await db.updateWorkRecordMeta(
        id: w6, note: '再改', updatedAt: DateTime(2026, 10, 7, 22));
    final after2 = (await db.getWorkRecord(w6))!;
    check('⑱ 二次改 Meta：amountSnapshot 仍 14000',
        after2.amountSnapshot == 14000, '实际 ${after2.amountSnapshot}');

    // 3.6 软删不计入占用（P04 默认过滤）：软删 w1 后 10-05 有效读减 1。
    final d05Before = await db.listWorkRecords(
        startDate: _d05, endDate: _d05, includeDraft: false);
    await db.softDeleteWorkRecord(w1, DateTime(2026, 10, 8));
    final d05After = await db.listWorkRecords(
        startDate: _d05, endDate: _d05, includeDraft: false);
    check('⑲ 软删 w1 → 10-05 有效读 3→2（默认过滤软删，AC-P04-07）',
        d05Before.length == 3 && d05After.length == 2,
        'before=${d05Before.length} after=${d05After.length}');

    // 3.7 草稿分支快照保全（**C-01 直接对应**，审查报告 §2.7 第 1 条）：
    //     以「加班命中」记录驱动引擎 draft 分支 → 证明「写回冻结 rd」（页面修复后语义）
    //     保全命中上下文；并**反证**「写回引擎占位值」会损坏（使断言可证伪）。
    final c01Rule = PricingRule(
      id: _ruleC,
      companyId: _cidA,
      name: '砌墙',
      method: PricingMethod.hourly,
      baseRate: 6000,
      halfDayRatio: 5,
      overtimeRate: 15,
      weekendRate: 10,
      holidayRate: 10,
      createdAt: _d05,
      updatedAt: _d05,
    );
    // 引擎在 qty=0 → draft 分支，返回**占位** rateDetail（appliedRate=10、命中标记全 false）。
    final draftRes = const AmountEngine().compute(
      rule: c01Rule,
      input: const AmountInput(manualHours: 0.0, isOvertime: true),
    );
    check('C-01① 引擎 draft 分支返回占位 rateDetail.appliedRate==10（危害真实存在）',
        draftRes.isDraft && draftRes.rateDetail.appliedRate == 10,
        'isDraft=${draftRes.isDraft} appliedRate=${draftRes.rateDetail.appliedRate}');
    check('C-01② 引擎占位 rateDetail 丢失加班命中（overtime=false）',
        !draftRes.rateDetail.overtime,
        'overtime=${draftRes.rateDetail.overtime}');

    const w8 = 'w0000001-0000-4000-8000-000000000008';
    const frozenRd = RateSnapshot(
      overtime: true,
      overtimeRate: 15,
      weekend: false,
      weekendRate: 10,
      holiday: false,
      holidayRate: 10,
      appliedRate: 15,
    );
    await db.upsertWorkRecord(WorkRecord(
      id: w8,
      workDate: _d06,
      companyId: _cidA,
      pricingRuleId: _ruleC,
      methodSnapshot: PricingMethod.hourly,
      qtySnapshot: 0.0,
      rateSnapshot: 9000,
      rateDetailSnapshot: frozenRd,
      amountSnapshot: 0,
      amountSource: AmountSource.auto,
      status: RecordStatus.draft,
      createdAt: _d06,
      updatedAt: _d06,
    ));
    // 修复后语义（页面 `rateDetail: (r.isDraft||r.isInvalid||r.needsOvernight) ? rd : ...`）
    // → 草稿分支写回**冻结** rd。
    await db.replaceWorkRecordSnapshot(
      id: w8,
      rateSnapshot: 9000,
      rateDetailSnapshot: frozenRd,
      amountSnapshot: 0,
      amountSource: AmountSource.auto,
      qtySnapshot: 0.0,
      overnight: false,
      updatedAt: _d06,
    );
    final kept = (await db.getWorkRecord(w8))!;
    check('C-01③ 草稿写回 rd → appliedRate 保全为 15（非占位 10）',
        kept.rateDetailSnapshot.appliedRate == 15,
        '实际 ${kept.rateDetailSnapshot.appliedRate}');
    check('C-01④ 草稿写回 rd → 加班命中上下文保全（overtime=true, rate=15）',
        kept.rateDetailSnapshot.overtime &&
            kept.rateDetailSnapshot.overtimeRate == 15,
        'overtime=${kept.rateDetailSnapshot.overtime} rate=${kept.rateDetailSnapshot.overtimeRate}');
    // 反证：若误写引擎占位值 → 冻结上下文被清零（证明修复必要 + 断言具可证伪性）。
    await db.replaceWorkRecordSnapshot(
      id: w8,
      rateSnapshot: 9000,
      rateDetailSnapshot: draftRes.rateDetail,
      amountSnapshot: 0,
      amountSource: AmountSource.auto,
      qtySnapshot: 0.0,
      overnight: false,
      updatedAt: _d06,
    );
    final corrupted = (await db.getWorkRecord(w8))!;
    check('C-01⑤ 反证：若写回引擎占位值 → appliedRate 退化 10 且 overtime=false',
        corrupted.rateDetailSnapshot.appliedRate == 10 &&
            !corrupted.rateDetailSnapshot.overtime,
        'appliedRate=${corrupted.rateDetailSnapshot.appliedRate} overtime=${corrupted.rateDetailSnapshot.overtime}');
  }

  // ═══════════════════════════════════════════════════════════════════════
  print('== 4. P05 重算「不读当前规则」+ 快照反推（复刻实测 · 限 hourly-manual）==');
  // ═══════════════════════════════════════════════════════════════════════
  {
    // 造一条新记录：qty 2 小时，rateSnapshot 6000（¥60），amount 12000。
    const w7 = 'w0000001-0000-4000-8000-000000000007';
    await db.upsertWorkRecord(WorkRecord(
      id: w7,
      workDate: _d07,
      companyId: _cidA,
      pricingRuleId: _ruleC,
      methodSnapshot: PricingMethod.hourly,
      qtySnapshot: 2,
      rateSnapshot: 6000,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
      amountSnapshot: 12000,
      amountSource: AmountSource.auto,
      status: RecordStatus.confirmed,
      createdAt: _d07,
      updatedAt: _d07,
    ));

    final rec = (await db.getWorkRecord(w7))!;
    final rd = rec.rateDetailSnapshot;
    // 复刻页面公式：baseRate = roundDiv(rateSnapshot × 10, appliedRate)
    final baseRate = rd.appliedRate > 0
        ? _roundDiv(rec.rateSnapshot * 10, rd.appliedRate)
        : 0;
    check('① 快照反推基础单价 = 6000（rateSnapshot 6000 / appliedRate 10）',
        baseRate == 6000, '实际 $baseRate');

    PricingRule ruleFromSnapshot(int base) => PricingRule(
          id: rec.pricingRuleId ?? '_snapshot',
          companyId: rec.companyId,
          name: '（快照重建）',
          method: rec.methodSnapshot,
          baseRate: base,
          unit: rec.qtyUnitSnapshot,
          halfDayRatio: 5,
          overtimeRate: rd.overtimeRate,
          weekendRate: rd.weekendRate,
          holidayRate: rd.holidayRate,
          createdAt: rec.createdAt,
          updatedAt: rec.updatedAt,
        );

    final snapRecompute = const AmountEngine().compute(
      rule: ruleFromSnapshot(baseRate),
      input: AmountInput(
        manualHours: rec.qtySnapshot,
        isOvertime: rd.overtime,
        isWeekend: rd.weekend,
        isHoliday: rd.holiday,
      ),
    );
    check('② 快照重建重算 → 金额仍 12000（与历史一致）',
        snapRecompute.amount == 12000, '实际 ${snapRecompute.amount}');
    check('③ 快照重建重算 → amountSource=auto',
        snapRecompute.source == AmountSource.auto, '实际 ${snapRecompute.source}');

    // 改「当前规则」单价（模拟 P09 改价），再从快照重算 → 不受影响。
    await db.upsertPricingRule(PricingRule(
      id: _ruleC,
      companyId: _cidA,
      name: '砌墙',
      method: PricingMethod.hourly,
      baseRate: 9900, // 现价 ¥99（改价）
      halfDayRatio: 5,
      overtimeRate: 15,
      weekendRate: 10,
      holidayRate: 10,
      createdAt: _d05,
      updatedAt: DateTime(2026, 10, 8),
    ));
    final currentRule = (await db.getPricingRule(_ruleC))!;
    check('④ 现价已改：getPricingRule(baseRate) = 9900', currentRule.baseRate == 9900,
        '实际 ${currentRule.baseRate}');

    final snapAgain = const AmountEngine().compute(
      rule: ruleFromSnapshot(baseRate),
      input: AmountInput(manualHours: rec.qtySnapshot),
    );
    check('⑤ 改价后「仍按快照」重算 → 仍 12000（快照优先，底线 2）',
        snapAgain.amount == 12000, '实际 ${snapAgain.amount}');

    final usingCurrent = const AmountEngine().compute(
      rule: currentRule,
      input: AmountInput(manualHours: rec.qtySnapshot),
    );
    check('⑥ 反证：若误读现价重算 → 得 19800（≠12000，证明两路径有别，测试有意义）',
        usingCurrent.amount == 19800 && usingCurrent.amount != snapAgain.amount,
        '现价重算=${usingCurrent.amount}');

    // 动作 B（手工覆盖）：引擎 source=manual、autoReference=自动值。
    final manual = const AmountEngine().compute(
      rule: ruleFromSnapshot(baseRate),
      input: AmountInput(manualHours: rec.qtySnapshot, manualAmount: 10000),
    );
    check('⑦ 动作 B：source=manual 且 autoReference=自动值 12000',
        manual.source == AmountSource.manual && manual.autoReference == 12000,
        'source=${manual.source} autoRef=${manual.autoReference}');
  }

  // ═══════════════════════════════════════════════════════════════════════
  print('== 5. 源码断言（读码级：字符串/整行检查，强度分档见文件头注）==');
  // ═══════════════════════════════════════════════════════════════════════
  {
    final p05 = _read('lib/ui/record_detail_page.dart');
    final p03 = _read('lib/ui/calendar_page.dart');
    final p04 = _read('lib/ui/day_detail_page.dart');

    // **剥注释版本**：本段所有静态断言一律作用于剥注释后的源码。
    // 根因（审计 F1/F2）：`calendar_page.dart:12`/`:78`/`:80` 的 doc 注释含与代码相同的
    // 字面量，`contains` 在未剥注释时被注释救活 ⇒ 改坏代码仍绿。
    final p05Code = _stripComments(p05);
    final p03Code = _stripComments(p03);
    final p04Code = _stripComments(p04);

    // P05：完整调用链（拆签名两组 + 事务变体 + 可空字段显式传全）。
    check('① record_detail_page 结构存在（含 _RecordDetailPageState，非空文件）',
        p05.contains('class _RecordDetailPageState'), '文件缺失或结构异常');
    check('② 含 Meta 写调用 updateWorkRecordMeta(',
        p05.contains('_db.updateWorkRecordMeta('), '未见 updateWorkRecordMeta 调用');
    check('③ 含 Snapshot 写调用 replaceWorkRecordSnapshot(',
        p05.contains('_db.replaceWorkRecordSnapshot('), '未见 replaceWorkRecordSnapshot 调用');
    check('④ 含事务分支 updateWorkRecordMetaOn(txn,',
        p05.contains('_db.updateWorkRecordMetaOn(txn,'), '未见事务内 Meta 变体');
    check('⑤ 含事务分支 replaceWorkRecordSnapshotOn(',
        p05.contains('_db.replaceWorkRecordSnapshotOn('), '未见事务内 Snapshot 变体');
    check('⑥ 可空字段显式传全：autoReferenceAmount/qtyUnitSnapshot/startTime/endTime',
        p05.contains('autoReferenceAmount: t.autoReference,') &&
            p05.contains('qtyUnitSnapshot: t.qtyUnit,') &&
            p05.contains('startTime: t.start,') &&
            p05.contains('endTime: t.end,'),
        '可空字段未显式传全（漏传 = 静默清空）');
    check('⑦ 含软删调用 softDeleteWorkRecord(',
        p05.contains('_db.softDeleteWorkRecord('), '未见软删调用');
    check('⑧ 基础单价反推公式逐字存在',
        p05.contains('final baseRate = appliedRate > 0 ? _roundDiv(rateFen * 10, appliedRate) : 0;'),
        '反推公式与脚本不一致');
    check('⑨ _roundDiv 实现逐字一致',
        p05.contains('return (numerator + denominator ~/ 2) ~/ denominator;'),
        '_roundDiv 与脚本默认实现不一致');
    // ⑩ **加固（审计 F4）**：旧式只查 `isOvertime: rd.overtime,` 一个字面量
    //   ⇒ 把 `record_detail_page.dart:218` 的 `isWeekend: rd.weekend,` 改成 `rd.holiday,`
    //   仍 76/0（"3 档命中只查 1 档"的单点逃逸）。现**切片到引擎调用的 `AmountInput(...)` 实参**，
    //   把三档取值**逐处**列出并逐一比对（各恰 1 处且分别 == rd.overtime / rd.weekend / rd.holiday）。
    final p05EngCall = _parenAfter(p05Code, '.compute(');
    final p05InputArgs = _parenAfter(p05EngCall, 'input: AmountInput(');
    final p05Ot = _extractValues(p05InputArgs, 'isOvertime');
    final p05Wk = _extractValues(p05InputArgs, 'isWeekend');
    final p05Hd = _extractValues(p05InputArgs, 'isHoliday');
    check('⑩ 重算调用引擎：三档命中上下文**逐处**取自冻结快照 rd'
        '（isOvertime/isWeekend/isHoliday 各恰 1 处且分别 == rd.overtime/rd.weekend/rd.holiday）',
        p05Code.contains('const AmountEngine().compute(') &&
            p05Ot.length == 1 &&
            p05Ot.single == 'rd.overtime' &&
            p05Wk.length == 1 &&
            p05Wk.single == 'rd.weekend' &&
            p05Hd.length == 1 &&
            p05Hd.single == 'rd.holiday',
        'ot=$p05Ot（期望[rd.overtime]） wk=$p05Wk（期望[rd.weekend]） hd=$p05Hd（期望[rd.holiday]）');
    // 剥离注释后再扫（整行 + 行尾注释都要剥，避免注释里的说明文字制造假阳性）。
    check('⑪ 全页无浮点金额路径（禁 fen/100、double.parse、.round()、.toDouble()）',
        !RegExp(r'fen\s*/\s*100').hasMatch(p05Code) &&
            !RegExp(r'double\.parse\(').hasMatch(p05Code) &&
            !RegExp(r'\.round\(\)').hasMatch(p05Code) &&
            !RegExp(r'\.toDouble\(\)').hasMatch(p05Code),
        '命中浮点金额路径禁令');
    // 重算禁用路径：_target() 内不得出现 listPricingRules（只看不重算）。
    final targetIdx = p05Code.indexOf('_Target _target()');
    final targetEnd = p05Code.indexOf('int _halfDayRatio(');
    final targetBody =
        (targetIdx >= 0 && targetEnd > targetIdx) ? p05Code.substring(targetIdx, targetEnd) : '';
    check('⑫ _target() 重算体不含 listPricingRules（禁读现价，AC-P05-10）',
        targetBody.isNotEmpty && !targetBody.contains('listPricingRules'),
        '重算体内出现 listPricingRules 或片段未定位');

    // P03：日历口径 + 色点补 alpha + **容错读**（一律作用于剥注释源码 p03Code）。
    check('⑬ calendar_page 用**容错读** listWorkRecordsLenient(（M-01）',
        p03Code.contains('_db.listWorkRecordsLenient('), '未见容错读（M-01 未修）');
    // ⑭ **加固（审计 F1）**：旧式 `p03.contains('includeDraft: false')` 被 `:12`/`:78` 的
    //   doc 注释救活 ⇒ 代码 `false`→`true` 仍 76/0。现**切片到 `_db.listWorkRecordsLenient(...)`
    //   实参**（剥注释后）——注释已剥，且断言只看该调用点实参，别处字面量无法救活。
    final p03LenientArgs = _parenAfter(p03Code, '_db.listWorkRecordsLenient(');
    check('⑭ calendar_page `_db.listWorkRecordsLenient(...)` 实参含 includeDraft: false'
        '（剥注释 + 切片锚定实参，防注释/他处字面量救活）',
        p03LenientArgs.contains('includeDraft: false') &&
            !p03LenientArgs.contains('includeDraft: true'),
        'lenient 实参=${p03LenientArgs.replaceAll(RegExp(r"\s+"), " ")}');
    // ⑮ **加固（审计 F2）**：同类，旧式被 `:80` 注释救活。切片到 `_db.listCompanies(...)` 实参。
    final p03CompaniesArgs = _parenAfter(p03Code, '_db.listCompanies(');
    check('⑮ calendar_page `_db.listCompanies(...)` 实参含 includeDisabled: true, includeDeleted: true'
        '（剥注释 + 切片锚定实参）',
        p03CompaniesArgs.contains('includeDisabled: true') &&
            p03CompaniesArgs.contains('includeDeleted: true') &&
            !p03CompaniesArgs.contains('includeDisabled: false') &&
            !p03CompaniesArgs.contains('includeDeleted: false'),
        'listCompanies 实参=${p03CompaniesArgs.replaceAll(RegExp(r"\s+"), " ")}');
    check('⑯ calendar_page 色点补 alpha：Color(0xFF000000 | c)（剥注释）',
        p03Code.contains('Color(0xFF000000 | c)'), '色点未补 alpha');
    check('⑰ calendar_page 含 listHolidayMarks(',
        p03Code.contains('_db.listHolidayMarks('), '未见节假日读取');

    // P04：容错读 + 草稿不计入 + 分组 + 删除。
    check('⑱ day_detail_page 含 listWorkRecordsLenient(',
        p04Code.contains('_db.listWorkRecordsLenient('), '未用容错读');
    // ⑲ **加固（审计 F3）**：旧式 `p04.contains('status != RecordStatus.draft')` 被 `:301`/`:369`
    //   的同类字面量救活 ⇒ `:128`（`_dayTotal` 过滤）改 `!=`→`==` 仍 76/0。
    //   现**切片到 `_dayTotal` getter 体**（剥注释）精确判定，别处字面量无法救活。
    final p04DayTotal = _slice(p04Code, 'int get _dayTotal', 'List<_CompanyGroup> get _groups');
    check('⑲ day_detail_page `_dayTotal` 过滤为 `!= RecordStatus.draft`'
        '（切片锚定 getter 体，剥注释；草稿不计入合计 AC-P04-02）',
        p04DayTotal.isNotEmpty &&
            _reCount(p04DayTotal, RegExp(r'status\s*!=\s*RecordStatus\.draft')) == 1 &&
            !p04DayTotal.contains('status == RecordStatus.draft'),
        '切片=${p04DayTotal.replaceAll(RegExp(r"\s+"), " ")}');
    check('⑳ day_detail_page 含 softDeleteWorkRecord(',
        p04Code.contains('_db.softDeleteWorkRecord('), '未见软删调用');
    check('㉑ day_detail_page 分组按 companyId',
        p04Code.contains('map.putIfAbsent(w.companyId,'), '未见按公司分组');
    check('㉒ day_detail_page 点记录进 RecordDetailPage(',
        p04Code.contains('RecordDetailPage(id: id)'), '未见 P05 入口');

    // ㉓ **强化（M-06 · 教训第 10 类：断言须能被回退修复置红）**：C-01 **页面级**守卫，
    // 由「整行字符串存在性」升级为**结构式断言**（仍属静态档，如实标注）。
    // 三项同时成立才绿（任一回退即红）：
    //   ① 三元式三分支 flag 全在场（r.isDraft / r.isInvalidInput / r.needsOvernightConfirm）；
    //   ② 命中（true）分支取 `rd`（保留冻结快照）、else 取 `r.rateDetail`；
    //   ③ `rateDetail:` 键在整文件**仅出现一次**（防新增绕过路径）。
    final p05n = p05Code.replaceAll(RegExp(r'\s+'), ' ');
    final nKey = 'rateDetail:'.allMatches(p05n).length;
    final nFlags =
        p05n.contains('(r.isDraft || r.isInvalidInput || r.needsOvernightConfirm)');
    final nTakesFrozen = p05n.contains('? rd : r.rateDetail');
    check('㉓ C-01 页面级守卫（结构式：三 flag 全在场 + 命中取 rd + rateDetail: 唯一）',
        nKey == 1 && nFlags && nTakesFrozen,
        'C-01 守卫缺失/被改：rateDetail: 出现 $nKey 次，flags=$nFlags，取rd=$nTakesFrozen');
    check('㉔ M-02 恢复自动计算置灰条件存在（autoReferenceAmount==null → 不可点）',
        p05.contains('_rec?.autoReferenceAmount == null'), '未见 M-02 置灰条件');
    check('㉕ MIN-04 软删记录 Meta 只读守卫存在（归属日 onTap 门控 deleted）',
        p05.contains('(_saving || deleted) ? null : _pickDate'),
        '未见软删 Meta 只读门控');
  }

  print('');
  print('──────────────────────────────────────────────');
  print('结果：$_pass 通过 / $_fail 失败');
  print('──────────────────────────────────────────────');
  if (_fail > 0) {
    print('【未覆盖 · [真机]】UI 渲染 / 手势 / 弹窗 / 高亮 / 虚线框 / 折叠 → 须末次出包人工验收。');
    exit(1);
  }
  print('覆盖 [实测级]（§1/§2/§3）+ [复刻实测·限 hourly-manual]（§4）+ [读码级·源码断言]（§5）。');
  print('【未覆盖 · [真机]】UI 渲染 / 手势 / 弹窗 / 高亮 / 虚线框 / 折叠 → 须末次出包人工验收。');
}
