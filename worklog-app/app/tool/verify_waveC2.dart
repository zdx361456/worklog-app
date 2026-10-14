// Wave C2 专项验证脚本（纯 Dart，内存库；不触 Flutter / 不触设备）。
//
// 证据层级标注（本项目纪律，`docs/00-项目总览/DECISIONS.md` D-8）：
//   【实测级】 本脚本 **直接 import 真源码**（`lib/services/export_service.dart`、
//             `lib/services/import_service.dart`、`lib/db/database.dart`、`lib/services/id_gen.dart`），
//             用 `sqflite_common_ffi` **内存库**真跑：序列化 / 反序列化 / 事务落库 / 谓词 /
//             六表往返 — 结论可直接采信（服务层 + DB 层）。
//   【读码级】 ① UI 私有方法 `_buildBackupData`（`lib/ui/export_backup_page.dart`）不可从外部调用 →
//             本脚本以**逐字相同的六个公开 DB 调用**复刻组装（见 `buildBackup`，行号对照见下）；
//             ② `lib/ui/export_backup_page.dart` 的点击/文件读写/分享（path_provider/share_plus/
//             file_picker）**不覆盖** → 属 `[真机]`/【仅类型编译】。
//   【静态级】 §7 读 `lib/ui/export_backup_page.dart` / `lib/services/import_service.dart`
//             **源码文本**做落点断言（可被文件证伪；覆盖 UI 私有分支 MAJ-2/MAJ-3/MIN-3 落点）。
//   【实测级·新增】 §6 直接调 `ImportService.verifyImportInvariants`（**公共函数**，UI 事务内同款），
//             真跑 merge 场景 + (A)/(B)/(C) 反证 —— 对 MAJ-1 修复有**真实证伪力**（非复刻）。
//   【不覆盖】 平台库落盘/分享、对话框交互、Tab 导航 — 须末次出包真机验收。
//
// 跑法（本机可复现，`--disable-dart-dev` + `WORKLOG_USE_SYSTEM_SQLITE=1` 缺一报 CreateFile failed 231）：
//   cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
//   set WORKLOG_USE_SYSTEM_SQLITE=1
//   "<FR>\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev tool\verify_waveC2.dart
//
// 契约来源：
//   · `docs/04-迭代/2026-10-05/补齐规格07剩余页/02-需求与验收.md` §D.11（`AC-P13-01/03/07/09/11`）
//     + §C.3.1（`AC-Q23-01~04`，U-2 谓词）
//   · `docs/07-UI实现规格.md` §4.3（I-4 全量读）:`803-843`
//
// 设计对照：`docs/04-迭代/2026-10-05/补齐规格07剩余页/15-WaveC2-实现设计.md`

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/db/database.dart';
import '../lib/models/company.dart';
import '../lib/models/holiday_mark.dart';
import '../lib/models/ledger.dart';
import '../lib/models/payment_record.dart';
import '../lib/models/pricing_rule.dart';
import '../lib/models/types.dart';
import '../lib/models/work_record.dart';
import '../lib/services/export_service.dart';
import '../lib/services/id_gen.dart';
import '../lib/services/import_service.dart';
import '../lib/services/receivable_service.dart';

/// 见 `tool/verify_db.dart` 同名函数（Windows 无 native-assets 时预载系统 SQLite）。
void _maybePreloadSystemSqlite() {
  if (!Platform.isWindows) return;
  if (Platform.environment['WORKLOG_USE_SYSTEM_SQLITE'] != '1') return;
  for (final name in ['sqlite3.dll', 'winsqlite3.dll']) {
    try {
      DynamicLibrary.open(name);
      stdout.writeln('  · 已预加载系统 SQLite 动态库：$name');
      return;
    } catch (_) {}
  }
  stdout.writeln('  ! 未能预加载任何系统 SQLite 动态库');
}

var _pass = 0;
var _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

// ── 样本（**全部本地格式 id**，验证 U-2 放宽后的端到端往返）──
final _ledgerId = newId('led');
final _coA = newId('co'); // 启用、有账
final _coB = newId('co'); // **停用**（enabled=false）、有账
final _coC = newId('co'); // **软删**（deleted_at != null）、有账
final _ruleA = newId('rule');
final _wrA = newId('wr'); // 已确认
final _wrDraft = newId('wr'); // **草稿**
final _wrDeleted = newId('wr'); // **软删**
final _pmA = newId('pm');
final _pmDeleted = newId('pm'); // **软删**
final _hmA = newId('hm');

final _base = DateTime(2026, 9, 30, 9, 0);
DateTime _t(int i) => _base.add(Duration(minutes: i));

/// `export_backup_page.dart` `_buildBackupData()` 的**逐字复刻**（六个公开 DB 调用完全一致）。
/// 【读码级】UI 私有方法不可外部调用；本函数仅作搬运，序列化/反序列化/落库均为真源码（【实测级】）。
Future<BackupData> buildBackup(AppDatabase db, String ledgerId) async => BackupData(
      ledger: (await db.getLedger(ledgerId))!,
      companies: await db.listCompanies(
        ledgerId: ledgerId,
        includeDeleted: true,
        includeDisabled: true,
      ),
      pricingRules: await db.listPricingRules(
        includeDeleted: true,
        includeDisabled: true,
      ),
      workRecords: await db.listWorkRecords(
        includeDeleted: true,
        includeDraft: true,
      ),
      paymentRecords: await db.listPaymentRecords(includeDeleted: true),
      holidayMarks: await db.listHolidayMarks(ledgerId: ledgerId),
    );

Future<void> _clearAll(AppDatabase db) async {
  final d = db.db!;
  for (final t in const [
    'work_record',
    'payment_record',
    'pricing_rule',
    'company',
    'holiday_mark',
    'ledger',
  ]) {
    await d.delete(t);
  }
}

Ledger _ledger() => Ledger(id: _ledgerId, name: '我的账本', createdAt: _t(0));

RateSnapshot _rate({bool weekend = false, int weekendRate = 10, int applied = 10}) =>
    RateSnapshot(
      weekend: weekend,
      weekendRate: weekendRate,
      appliedRate: applied,
    );

WorkRecord _work(
  String id, {
  required String companyId,
  required String workDate,
  required int amount,
  RecordStatus status = RecordStatus.confirmed,
  DateTime? deletedAt,
  int tIndex = 5,
}) =>
    WorkRecord(
      id: id,
      workDate: DateTime.parse(workDate),
      companyId: companyId,
      pricingRuleId: _ruleA,
      methodSnapshot: PricingMethod.hourly,
      qtySnapshot: 4.5,
      qtyUnitSnapshot: '小时',
      startTime: DateTime(1970, 1, 1, 8, 0),
      endTime: DateTime(1970, 1, 1, 12, 30),
      overnight: false,
      rateSnapshot: 4000,
      rateDetailSnapshot: _rate(weekend: true, weekendRate: 15, applied: 15),
      amountSnapshot: amount,
      amountSource: AmountSource.auto,
      currencySnapshot: 'CNY',
      note: '样本 $id',
      status: status,
      createdAt: _t(tIndex),
      updatedAt: _t(tIndex),
      deletedAt: deletedAt,
    );

Future<void> _seed(AppDatabase db) async {
  await db.upsertLedger(_ledger());
  await db.upsertCompany(Company(
    id: _coA,
    ledgerId: _ledgerId,
    name: '甲公司',
    color: 0xE53935,
    contact: '张三',
    createdAt: _t(1),
    updatedAt: _t(1),
  ));
  await db.upsertCompany(Company(
    id: _coB,
    ledgerId: _ledgerId,
    name: '乙公司',
    color: 0x43A047,
    enabled: false, // 停用
    createdAt: _t(2),
    updatedAt: _t(2),
  ));
  await db.upsertCompany(Company(
    id: _coC,
    ledgerId: _ledgerId,
    name: '丙公司',
    color: 0x1E88E5,
    createdAt: _t(3),
    updatedAt: _t(3),
    deletedAt: _t(3), // 软删（归档）
  ));
  await db.upsertPricingRule(PricingRule(
    id: _ruleA,
    companyId: _coA,
    name: '砌墙',
    method: PricingMethod.hourly,
    baseRate: 4000,
    unit: '小时',
    standardHours: 8.0,
    overtimeRate: 15,
    weekendRate: 15,
    holidayRate: 30,
    effectiveDate: DateTime(2026, 1, 1),
    createdAt: _t(4),
    updatedAt: _t(4),
  ));
  await db.upsertWorkRecord(_work(_wrA,
      companyId: _coA, workDate: '2026-09-28', amount: 12000, tIndex: 5));
  await db.upsertWorkRecord(_work(_wrDraft,
      companyId: _coB,
      workDate: '2026-09-29',
      amount: 0,
      status: RecordStatus.draft,
      tIndex: 6));
  await db.upsertWorkRecord(_work(_wrDeleted,
      companyId: _coC,
      workDate: '2026-09-30',
      amount: 8888,
      deletedAt: _t(7),
      tIndex: 7));
  await db.upsertPaymentRecord(PaymentRecord(
    id: _pmA,
    paymentDate: DateTime(2026, 9, 25),
    companyId: _coA,
    amount: 5000,
    method: PaymentMethod.wechat,
    note: '微信收款',
    createdAt: _t(8),
    updatedAt: _t(8),
  ));
  await db.upsertPaymentRecord(PaymentRecord(
    id: _pmDeleted,
    paymentDate: DateTime(2026, 9, 26),
    companyId: _coB,
    amount: 3000,
    method: PaymentMethod.cash,
    createdAt: _t(9),
    updatedAt: _t(9),
    deletedAt: _t(9),
  ));
  await db.upsertHolidayMark(HolidayMark(
    id: _hmA,
    ledgerId: _ledgerId,
    date: DateTime(2026, 10, 1),
    type: HolidayType.statutory,
    rate: 30,
    manual: true,
    createdAt: _t(10),
  ));
}

Future<void> main() async {
  stdout.writeln('══════════════════════════════════════════════');
  stdout.writeln('Wave C2 · P13 导出备份 + U-2 放宽导入校验 · 专项验证');
  stdout.writeln('证据层级：服务层/DB 层=【实测级】；UI 私有方法/平台库=【读码级】/【不覆盖】');
  stdout.writeln('══════════════════════════════════════════════');

  _maybePreloadSystemSqlite();
  sqfliteFfiInit();
  AppDatabase.instance
      .configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  final db = AppDatabase.instance;
  await db.open();

  await _seed(db);

  // ═══════════════════ §1 U-2 谓词（AC-Q23-01 / 03）═══════════════════
  stdout.writeln('\n[1] U-2 谓词：本地格式 + UUID 均接受，非法 id 拒绝（AC-Q23-01/03）');
  const imp = ImportService();
  final localData = await buildBackup(db, _ledgerId);
  final localMap = jsonDecode(const ExportService().toJson(localData)) as Map<String, dynamic>;
  check('本地格式 id（5 类实体：led/co/rule/wr/pm）整体 validate 通过（AC-Q23-01）',
      imp.validate(localMap).isEmpty,
      '${imp.validate(localMap)}');

  // UUID 样本（AC-Q23-03：既有基线格式仍须通过 → 命中分支②）
  final uuidMap = jsonDecode(jsonEncode(localMap)) as Map<String, dynamic>;
  const uuidSamples = [
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222',
    '33333333-3333-4333-8333-333333333333',
    '44444444-4444-4444-8444-444444444444',
    '55555555-5555-4555-8555-555555555555',
    '66666666-6666-4666-8666-666666666666',
  ];
  (uuidMap['ledger'] as Map)['id'] = uuidSamples[0];
  ((uuidMap['companies'] as List)[0] as Map)['id'] = uuidSamples[1];
  ((uuidMap['pricing_rules'] as List)[0] as Map)['id'] = uuidSamples[2];
  ((uuidMap['work_records'] as List)[0] as Map)['id'] = uuidSamples[3];
  ((uuidMap['payment_records'] as List)[0] as Map)['id'] = uuidSamples[4];
  ((uuidMap['holiday_marks'] as List)[0] as Map)['id'] = uuidSamples[5];
  check('UUID 样本仍通过（AC-Q23-03，命中分支②）', imp.validate(uuidMap).isEmpty,
      '${imp.validate(uuidMap)}');

  final badMap = jsonDecode(jsonEncode(localMap)) as Map<String, dynamic>;
  ((badMap['companies'] as List)[0] as Map)['id'] = 'bad id!';
  final badErrs = imp.validate(badMap);
  check('非法 id 被拒绝（分支①/② 均不命中）',
      badErrs.any((e) => e.contains('非法 id')), '$badErrs');

  // 1000 个同批本地 id 无重复（AC-Q23-04）
  final ids = {for (var i = 0; i < 1000; i++) newId('wr')};
  check('连续生成 1000 个本地 id 无重复（AC-Q23-04）', ids.length == 1000,
      '实际 ${ids.length}');

  // ═══════════════════ §2 导出全量断言（AC-P13-01）═══════════════════
  stdout.writeln('\n[2] 导出全量：软删/停用/草稿均不被漏（AC-P13-01）');
  final data0 = await buildBackup(db, _ledgerId);
  check('companies 含 3 家（含停用 + 软删）', data0.companies.length == 3,
      '${data0.companies.length}');
  check('停用公司（乙）在备份内', data0.companies.any((c) => c.id == _coB && !c.enabled));
  check('软删公司（丙）在备份内', data0.companies.any((c) => c.id == _coC && c.deletedAt != null));
  check('workRecords 含 3 条（含草稿 + 软删）', data0.workRecords.length == 3,
      '${data0.workRecords.length}');
  check('草稿记录在备份内', data0.workRecords.any((w) => w.id == _wrDraft && w.status == RecordStatus.draft));
  check('软删工作记录在备份内', data0.workRecords.any((w) => w.id == _wrDeleted && w.deletedAt != null));
  check('软删收款在备份内', data0.paymentRecords.any((p) => p.deletedAt != null));
  check('节假日标记在备份内', data0.holidayMarks.length == 1);
  // 全量断言 A1~A4（与 export_backup_page._assertFullExportCounts 同式）
  final reCompanies = await db.listCompanies(ledgerId: _ledgerId, includeDeleted: true, includeDisabled: true);
  final reRules = await db.listPricingRules(includeDeleted: true, includeDisabled: true);
  final reWorks = await db.listWorkRecords(includeDeleted: true, includeDraft: true);
  final rePays = await db.listPaymentRecords(includeDeleted: true);
  check('A1 companies 条数一致', data0.companies.length == reCompanies.length);
  check('A2 pricingRules 条数一致', data0.pricingRules.length == reRules.length);
  check('A3 workRecords 条数一致（含草稿）', data0.workRecords.length == reWorks.length);
  check('A4 paymentRecords 条数一致', data0.paymentRecords.length == rePays.length);

  // A5 一致性断言（AC-61）
  final export = const ExportService();
  final fixedAt = DateTime(2026, 9, 30, 12, 0);
  final json1 = export.toJson(data0, exportedAt: fixedAt, appVersion: '1.0.0');
  final consistent = export.assertExportConsistency(
    workRecords: data0.workRecords,
    paymentRecords: data0.paymentRecords,
    exportedJson: export.toMap(data0, exportedAt: fixedAt, appVersion: '1.0.0'),
  );
  check('A5 assertExportConsistency 通过（AC-61）', consistent);

  // ═══════════════════ §3 AC-62 往返：导出→清空→导入→再导出，逐字节等价 ═══════════════════
  stdout.writeln('\n[3] AC-62 往返无损：导出 → 清空 → 导入 → 再导出（六表逐字节等价）');
  final map1 = jsonDecode(json1) as Map<String, dynamic>;

  // 清空六表（模拟"恢复"场景：本机清空后导入）
  await _clearAll(db);
  final cCnt = await db.listCompanies(ledgerId: _ledgerId, includeDeleted: true, includeDisabled: true);
  final rCnt = await db.listPricingRules(includeDeleted: true, includeDisabled: true);
  final wCnt = await db.listWorkRecords(includeDeleted: true, includeDraft: true);
  final pCnt = await db.listPaymentRecords(includeDeleted: true);
  final hCnt = await db.listHolidayMarks(ledgerId: _ledgerId);
  final lCnt = await db.listLedgers();
  check('清空后六表为空（含账本）',
      cCnt.isEmpty && rCnt.isEmpty && wCnt.isEmpty && pCnt.isEmpty && hCnt.isEmpty && lCnt.isEmpty,
      'c=${cCnt.length} r=${rCnt.length} w=${wCnt.length} p=${pCnt.length} h=${hCnt.length} l=${lCnt.length}');

  // 导入：真 ImportService.validate + parse（AC-Q23-02：validate 返回空错误清单）
  final impErrs = imp.validate(map1);
  check('导入 validate 返回空错误清单（AC-Q23-02）', impErrs.isEmpty, '$impErrs');
  final parsed = imp.parse(map1);

  // 事务内批量 upsert（与 export_backup_page._doImportTransaction 同款 `...On(txn,…)`）
  await db.transaction((txn) async {
    await db.upsertLedgerOn(txn, parsed.ledger);
    for (final c in parsed.companies) {
      await db.upsertCompanyOn(txn, c);
    }
    for (final r in parsed.pricingRules) {
      await db.upsertPricingRuleOn(txn, r);
    }
    for (final w in parsed.workRecords) {
      await db.upsertWorkRecordOn(txn, w);
    }
    for (final p in parsed.paymentRecords) {
      await db.upsertPaymentRecordOn(txn, p);
    }
    for (final h in parsed.holidayMarks) {
      await db.upsertHolidayMarkOn(txn, h);
    }
  });

  // 再导出（**同一 exportedAt** → 目标是整体逐字节等价，比"时间戳除外"更强）
  final data2 = await buildBackup(db, _ledgerId);
  final json2 = export.toJson(data2, exportedAt: fixedAt, appVersion: '1.0.0');
  final m2 = jsonDecode(json2) as Map<String, dynamic>;

  check('两份 JSON **逐字节等价**（AC-62 核心 / 03 §6.5 断言 3）',
      json1 == json2,
      json1 == json2 ? null : '差异见下方逐表 id');
  if (json1 != json2) {
    for (final t in const ['companies', 'pricing_rules', 'work_records', 'payment_records', 'holiday_marks']) {
      final a = (map1[t] as List).map((e) => (e as Map)['id']).toList();
      final b = (m2[t] as List).map((e) => (e as Map)['id']).toList();
      stdout.writeln('      $t: $a vs $b');
    }
  }

  // 六表 id 集合逐条一致（AC-Q23-02）
  for (final t in const ['companies', 'pricing_rules', 'work_records', 'payment_records', 'holiday_marks']) {
    final a = (map1[t] as List).map((e) => (e as Map)['id']).toSet();
    final b = (m2[t] as List).map((e) => (e as Map)['id']).toSet();
    check('$t id 集合一致', a.length == b.length && a.containsAll(b), '$a vs $b');
  }
  check('ledger id 一致', (map1['ledger'] as Map)['id'] == (m2['ledger'] as Map)['id']);

  // 软删行/草稿在再导出后仍保留（全量原则不因往返打折）
  check('往返后软删工作记录仍在', (m2['work_records'] as List)
      .any((e) => (e as Map)['id'] == _wrDeleted && e['deleted_at'] != null));
  check('往返后草稿仍在', (m2['work_records'] as List)
      .any((e) => (e as Map)['id'] == _wrDraft && e['status'] == '草稿'));

  // ═══════════════════ §4 DB 坏行：strict 抛 / lenient 跳过（AC-P13-11 检测路径）═══════════════════
  stdout.writeln('\n[4] DB 坏行行为：strict 读抛 / 容错读跳过计数（AC-P13-11 检测路径）');
  await db.db!.rawUpdate(
      "UPDATE work_record SET amount_snapshot = 'abc' WHERE id = ?", [_wrA]);
  var strictThrew = false;
  try {
    await db.listWorkRecords(includeDeleted: true, includeDraft: true);
  } catch (_) {
    strictThrew = true;
  }
  check('含坏行时严格读 listWorkRecords 抛错（导出 Fail-loud 依据）', strictThrew);
  final lenient = await db.listWorkRecordsLenient(includeDeleted: true, includeDraft: true);
  check('容错读 listWorkRecordsLenient 跳过坏行并计数（页面坏行告警来源）',
      lenient.skippedCount >= 1, 'skipped=${lenient.skippedCount}');

  // ═══════════════════ §5 CSV 导出格式（AC-P13-04，纯 Dart 层）═══════════════════
  stdout.writeln('\n[5] CSV 导出格式（AC-P13-04，ExportService 既有实现）');
  // 用 §2 的干净快照 data0（§4 已把 wrA 写坏，避免污染）
  final companyNames = {for (final c in data0.companies) c.id: c.name};
  final ruleNames = {for (final r in data0.pricingRules) r.id: r.name};
  final csvW = export.workRecordsCsv(data0.workRecords, companyNames, ruleNames);
  final csvP = export.paymentRecordsCsv(data0.paymentRecords, companyNames);
  check('CSV 带 UTF-8 BOM（Excel 不乱码）',
      csvW.startsWith('\uFEFF') && csvP.startsWith('\uFEFF'));
  check('CSV 金额两位小数（12000 分 → 120.00）', csvW.contains('120.00'));
  check('CSV 无 ¥ 符号', !csvW.contains('¥') && !csvP.contains('¥'));

  // ═══════════ §6 导入后不变量校验（R55/R57）：真实驱动 verifyImportInvariants ═══════════
  //  真实驱动：直接调 `ImportService.verifyImportInvariants`（**公共函数**，非复刻）
  //  —— 该函数即 UI `_doImportTransaction` 事务内所调，故对 UI 路径有**真实证伪力**。
  stdout.writeln('\n[6] 导入后不变量校验（R55 merge (A)(B)(C) / R57 五表）——真调 verifyImportInvariants');

  // 重置内存库（§4 已把 _wrA 写坏）；close 后 in-memory 库销毁，重开 = 干净空库。
  await db.close();
  await db.open();
  await _seed(db);

  ImportSnapshot mkSnap({
    required List<Company> companies,
    required List<PricingRule> rules,
    required List<WorkRecord> works,
    required List<PaymentRecord> pays,
    required List<HolidayMark> hols,
  }) =>
      ImportSnapshot(
        companies: companies,
        pricingRules: rules,
        workRecords: works,
        paymentRecords: pays,
        holidayMarks: hols,
        ids: {
          _ledgerId,
          ...companies.map((e) => e.id),
          ...rules.map((e) => e.id),
          ...works.map((e) => e.id),
          ...pays.map((e) => e.id),
          ...hols.map((e) => e.id),
        },
      );

  Future<ImportSnapshot> readSnap() async => mkSnap(
        companies: await db.listCompanies(
            ledgerId: _ledgerId, includeDeleted: true, includeDisabled: true),
        rules: await db.listPricingRules(
            includeDeleted: true, includeDisabled: true),
        works: (await db.listWorkRecordsLenient(
                includeDeleted: true, includeDraft: true))
            .rows,
        pays: (await db.listPaymentRecordsLenient(includeDeleted: true)).rows,
        hols: await db.listHolidayMarks(),
      );

  final pre = await readSnap();

  // 来件：同 id 分歧（_wrA 金额 12000→20000）+ 新公司 + 新工作记录 + 同 (账本,日期) 换 id 的节假日。
  final newCo = newId('co');
  final newWr = newId('wr');
  final swappedHm = newId('hm');
  final incomingData = BackupData(
    ledger: _ledger(),
    companies: [
      ...pre.companies,
      Company(
          id: newCo,
          ledgerId: _ledgerId,
          name: '新公司',
          color: 0x8E24AA,
          createdAt: _t(50),
          updatedAt: _t(50)),
    ],
    pricingRules: pre.pricingRules,
    workRecords: [
      _work(_wrA,
          companyId: _coA, workDate: '2026-09-28', amount: 20000, tIndex: 5),
      _work(newWr,
          companyId: _coA, workDate: '2026-09-27', amount: 7000, tIndex: 51),
    ],
    paymentRecords: pre.paymentRecords,
    holidayMarks: [
      HolidayMark(
          id: swappedHm,
          ledgerId: _ledgerId,
          date: DateTime(2026, 10, 1),
          type: HolidayType.statutory,
          rate: 30,
          manual: true,
          createdAt: _t(52)),
    ],
  );

  final incIdSet = {
    incomingData.ledger.id,
    ...incomingData.companies.map((e) => e.id),
    ...incomingData.pricingRules.map((e) => e.id),
    ...incomingData.workRecords.map((e) => e.id),
    ...incomingData.paymentRecords.map((e) => e.id),
    ...incomingData.holidayMarks.map((e) => e.id),
  };
  final localIds = pre.ids;
  final newIds = incIdSet.difference(localIds)..remove(incomingData.ledger.id);

  // merge 效果（**逐字复刻 `_doImportTransaction` 的 merge 跳过分支**；写为真 DB 操作）
  await db.transaction((txn) async {
    await db.upsertLedgerOn(txn, incomingData.ledger);
    for (final c in incomingData.companies) {
      if (localIds.contains(c.id)) continue;
      await db.upsertCompanyOn(txn, c);
    }
    for (final r in incomingData.pricingRules) {
      if (localIds.contains(r.id)) continue;
      await db.upsertPricingRuleOn(txn, r);
    }
    for (final w in incomingData.workRecords) {
      if (localIds.contains(w.id)) continue;
      await db.upsertWorkRecordOn(txn, w);
    }
    for (final p in incomingData.paymentRecords) {
      if (localIds.contains(p.id)) continue;
      await db.upsertPaymentRecordOn(txn, p);
    }
    for (final h in incomingData.holidayMarks) {
      if (localIds.contains(h.id)) continue;
      await db.upsertHolidayMarkOn(txn, h);
    }
  });
  final post = await readSnap();

  final v = imp.verifyImportInvariants(
    strategy: ImportStrategy.merge,
    pre: pre,
    post: post,
    data: incomingData,
    newIds: newIds,
  );
  // 断言 1：merge 正常场景 → (A)(B)(C) 全过（同 id 分歧**不再**误判为失败）
  check('merge 正常：verifyImportInvariants ok（(A)(B)(C) 全过）', v.ok, '${v.all}');
  check('merge 下同 id 分歧记录**保留本机值**（_wrA 仍 12000，未被来件 20000 覆盖）',
      (await db.getWorkRecord(_wrA))!.amountSnapshot == 12000,
      '实际 ${(await db.getWorkRecord(_wrA))!.amountSnapshot}');

  // 反证条：旧断言口径（来件 id 集合 × 本机行 比金额）在 merge 分歧下**必然不等** → 佐证 MAJ-1 已修
  final postById = {for (final w in post.workRecords) w.id: w};
  const rsvc = ReceivableService();
  final oldBackupRecv = rsvc.receivable(incomingData.workRecords);
  final oldLocalRecv =
      rsvc.receivable(incomingData.workRecords.map((w) => postById[w.id]!));
  check('反证（旧口径）：merge 分歧下「来件应收 ≠ 本机应收」（新断言已不再据此回滚）',
      oldBackupRecv != oldLocalRecv,
      '旧式 backup=$oldBackupRecv local=$oldLocalRecv');

  // 断言 2/3/4：分别篡改 post 制造 (A)/(B)/(C) 违反 → 新校验**必须**报出（证其非空转）
  final vA = imp.verifyImportInvariants(
    strategy: ImportStrategy.merge,
    pre: pre,
    post: mkSnap(
      companies: post.companies,
      rules: post.pricingRules,
      works: [
        for (final w in post.workRecords)
          w.id == _wrDraft
              ? _work(_wrDraft,
                  companyId: _coB,
                  workDate: '2026-09-29',
                  amount: 9000,
                  status: RecordStatus.draft,
                  tIndex: 6)
              : w,
      ],
      pays: post.paymentRecords,
      hols: post.holidayMarks,
    ),
    data: incomingData,
    newIds: newIds,
  );
  check('反证 (A)：本机原有记录被改写 → 报 (A)',
      vA.mergeFailures.any((e) => e.startsWith('(A)')), '${vA.mergeFailures}');

  final vB = imp.verifyImportInvariants(
    strategy: ImportStrategy.merge,
    pre: pre,
    post: mkSnap(
      companies: post.companies,
      rules: post.pricingRules,
      works: [
        for (final w in post.workRecords)
          w.id == newWr
              ? _work(newWr,
                  companyId: _coA,
                  workDate: '2026-09-27',
                  amount: 1,
                  tIndex: 51)
              : w,
      ],
      pays: post.paymentRecords,
      hols: post.holidayMarks,
    ),
    data: incomingData,
    newIds: newIds,
  );
  check('反证 (B)：新插入 id 内容≠来件 → 报 (B)',
      vB.mergeFailures.any((e) => e.startsWith('(B)')), '${vB.mergeFailures}');

  final vC = imp.verifyImportInvariants(
    strategy: ImportStrategy.merge,
    pre: pre,
    post: mkSnap(
      companies: post.companies,
      rules: post.pricingRules,
      works: [
        ...post.workRecords,
        _work(newId('wr'),
            companyId: _coA, workDate: '2026-09-26', amount: 500, tIndex: 60),
      ],
      pays: post.paymentRecords,
      hols: post.holidayMarks,
    ),
    data: incomingData,
    newIds: newIds,
  );
  check('反证 (C)：id 集合 ≠ 前∪来件 → 报 (C)',
      vC.mergeFailures.any((e) => e.startsWith('(C)')), '${vC.mergeFailures}');

  // R57：节假日同 (账本,日期) 换 id（G-13 静默漂移）→ 键集合仍一致、不误报；id 已漂移
  check('R57：merge 后节假日 (账本@日期) 键集合与「前∪来件」一致（G-13 宽容 id 漂移）',
      !v.failures.any((e) => e.contains('节假日')) &&
          !v.mergeFailures.any((e) => e.contains('节假日')),
      '${v.all}');
  check('R57 佐证：节假日 id 已由 _hmA 漂移为来件 id（G-13 INSERT OR REPLACE 实况）',
      (await db.listHolidayMarks()).any((h) => h.id == swappedHm) &&
          !(await db.listHolidayMarks()).any((h) => h.id == _hmA));

  // ═══════════ §7 静态核对（文件级可证伪；覆盖 UI 私有分支，标注【静态/读码】）═══════════
  stdout.writeln('\n[7] 静态核对（读源码文本，可被文件证伪）—— MAJ-2/MAJ-3/MIN-3/R55 落点');
  final page = File('lib/ui/export_backup_page.dart').readAsStringSync();
  final svcSrc = File('lib/services/import_service.dart').readAsStringSync();
  check('MAJ-3：坏行文案已改「导出将被中止」，且**不再**含伪文案「仍会原样导出」',
      page.contains('导出将被中止') && !page.contains('仍会原样导出'));
  check('MAJ-2：`_autoBackupBeforeOverwrite` 返回 bool（不再吞失败）',
      RegExp(r'Future<bool>\s+_autoBackupBeforeOverwrite').hasMatch(page));
  check('MAJ-2：自动备份失败分支存在（`if (!backedUp)` 中止导入）',
      page.contains('if (!backedUp)'));
  check('MAJ-1：事务内调用 `verifyImportInvariants`（断言口径真实接线）',
      page.contains('verifyImportInvariants'));
  check('MIN-3：`_startImport` 入口即置 `_busy`',
      RegExp(r'_startImport\(\) async \{[\s\S]*?setState\(\(\) => _busy = true\)',
              dotAll: true)
          .hasMatch(page));
  check('R55：merge (A)(B)(C) 三条检查均落地 import_service',
      svcSrc.contains("'(A) ") &&
          svcSrc.contains("'(B) ") &&
          svcSrc.contains("'(C) "));
  check('R57：节假日以 (ledger_id,date) 为键断言（id 漂移宽容）',
      svcSrc.contains('_holidayByKey') && svcSrc.contains('ledger_id,date'));

  stdout.writeln('\n══════════════════════════════════════════════');
  stdout.writeln('结果：$_pass 通过 / $_fail 失败');
  stdout.writeln('══════════════════════════════════════════════');
  stdout.writeln('【不覆盖·须真机】平台库落盘/分享/选文件、对话框交互、Tab 导航 → 末次出包验收');
  await db.close();
  exit(_fail == 0 ? 0 : 1);
}
