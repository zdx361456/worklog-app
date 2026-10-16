/// Wave A（下钻闭环）批末**口径单测**（纯 Dart，无需 Flutter / 无需设备）。
///
/// 运行（**与 `tool/verify_db.dart` 同一套办法，两者缺一不可**）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// set WORKLOG_USE_SYSTEM_SQLITE=1
/// "D:\workspace\software\installed\tools\FlyEnv-Data\app\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev tool\verify_waveA.dart
/// ```
/// 退出码：`0` = 全通过；`1` = 有失败断言。
///
/// **为什么必须 `--disable-dart-dev` + `WORKLOG_USE_SYSTEM_SQLITE=1`**：见 `tool/verify_db.dart` 头部
/// 的实证说明（`sqlite3` 包的 native-assets 构建钩子在本机 Dart VM 会 `CreateFile failed 231`）。
///
/// **本脚本要证明什么**（全部是"可被文件证伪"的断言，不是"看起来对"）：
///  1. **三条恒等式**（AC-33 / AC-P01-13 / AC-P06-08）：聚合 = 明细求和，逐分相等；
///  2. **P-DEBT「欠款合计」口径**（AC-PDBT-05 / 设计 `09 §7.3`）：
///     `Σ(remaining>0) − Σ|remaining<0| == aggregate(null).remaining`，**且 `debtTotal ≠ remaining`**；
///  3. **草稿不计入应收**（AC-32 / 设计 `§C.1.4` 陷阱 1）：
///     数据层（`includeDraft:false` 条数/求和）+ **接口层**（`RecordsFilter.receivableDrill.includeDraft == false`）；
///  4. **软删不计入**（口径 `02` 第 18 行）；
///  5. **`RecordsFilter` 值语义**（`review-core` M-1 回归）：
///     `copyWith()` 后字段相同即 `==`/`hashCode` 相等——这是 `RecordListView.didUpdateWidget`
///     不误触发查库的**唯一前提**；缺 `==` 会退化成引用比较；
///  6. **边界形态**（AC-P01-01 / AC-PDBT-10）：停用公司、已归档公司**仍计入**（「有账必列」）；
///     **只有草稿的公司不出现**在 `aggregateByCompany()`；**全多收**时 `debtTotal == 0` 而恒等式仍成立；
///  7. **逐公司一致**（AC-P01-11 / AC-P07-11）：`aggregate(cid)` 与 `aggregateByCompany()` 同一行三字段相等。
///  8. **UI 接线静态断言（§10，堵审计 F1~F3 逃逸）**：§1~§9 只证「数据层/接口常数」正确，
///     **不证页面接线**（审计 `03-verify_waveA 与 waveA2.md` §4.1 系统性结论）。§10 因此**读
///     `lib/ui/**` 真实源码、剥注释后**对**页面调用点实参**做精确锚定：P-DEBT 页面口径公式（F1a/F1b）、
///     三处 `listCompanies` 双 `true`（F3a/F3b/F3c）、下钻 `RecordsFilter` 实参（F2a/F2b）、
///     点卡片→P07 等 U-4 接线。手法与 `tool/verify_waveD2.dart` 静态层一致（剥注释 + 切方法体 + 精确计数）。
///
/// **测试数据（整数「分」，刻意让四种形态同时出现）**：
/// ```
/// 公司 A 启用     : 应收 100000+50000 = 150000，已收 40000          → 剩余  +110000（最大欠款）
/// 公司 B 停用     : 应收         30000，已收 50000                  → 剩余   -20000（多收）
/// 公司 C 已归档   : 应收         20000，已收 20000                  → 剩余        0（已结清，两视图都不显示）
/// 公司 D 只有草稿 : 草稿         77777（不计入应收）                 → 不出现于 aggregateByCompany
/// 全局            : 应收 200000，已收 110000，剩余 90000
/// 恒等式          : debtTotal 110000 − overpaidAbs 20000 = 90000 ✅
/// ```
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/db/database.dart';
import '../lib/models/company.dart';
import '../lib/models/ledger.dart';
import '../lib/models/payment_record.dart';
import '../lib/models/types.dart';
import '../lib/models/work_record.dart';
import '../lib/ui/records_filter.dart';

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

var _pass = 0;
var _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('  ✓ $name');
  } else {
    _fail++;
    print('  ✗ $name${detail == null ? '' : '  ($detail)'}');
  }
}

// ── 静态源码工具（§10 用：读真实 lib/ui 源码 → 剥注释 → 精确锚定/计数）──────────
// 手法照抄本项目唯一 0 假覆盖脚本 `tool/verify_waveD2.dart:98-227`：
//   `_stripComments`（整行 + 行尾注释都剥）、`_blockAfter`（切方法/构造块）、`_count`（精确计数）。
final RegExp _commentRe = RegExp(r'(^|\s)//.*$', multiLine: true);

String _stripComments(String src) => src.replaceAll(_commentRe, '');

String _read(String relPath) {
  final f = File(relPath);
  return f.existsSync() ? f.readAsStringSync() : '';
}

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

// ── 固定数据（合法 UUID 形状）───────────────────────────────────────────────
const _ledgerId = 'a0000000-0000-4000-8000-000000000001';
const _cidA = 'a0000000-0000-4000-8000-00000000000a'; // 启用
const _cidB = 'a0000000-0000-4000-8000-00000000000b'; // 停用
const _cidC = 'a0000000-0000-4000-8000-00000000000c'; // 已归档
const _cidD = 'a0000000-0000-4000-8000-00000000000d'; // 只有草稿

final _t0 = DateTime(2026, 10, 1, 9, 0);
final _t1 = DateTime(2026, 10, 2, 9, 0);

Ledger _ledger() => Ledger(id: _ledgerId, name: '账本', createdAt: _t0);

Company _company(String id, String name, {bool enabled = true, DateTime? deletedAt}) =>
    Company(
      id: id,
      ledgerId: _ledgerId,
      name: name,
      color: 0xE53935,
      enabled: enabled,
      createdAt: _t0,
      updatedAt: _t0,
      deletedAt: deletedAt,
    );

WorkRecord _work(
  String id,
  String companyId,
  int amount, {
  RecordStatus status = RecordStatus.confirmed,
  DateTime? deletedAt,
}) =>
    WorkRecord(
      id: id,
      workDate: _t0,
      companyId: companyId,
      methodSnapshot: PricingMethod.hourly,
      qtySnapshot: 4,
      rateSnapshot: amount,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
      amountSnapshot: amount,
      amountSource: AmountSource.auto,
      status: status,
      createdAt: _t0,
      updatedAt: _t0,
      deletedAt: deletedAt,
    );

PaymentRecord _pay(String id, String companyId, int amount) => PaymentRecord(
      id: id,
      paymentDate: _t1,
      companyId: companyId,
      amount: amount,
      method: PaymentMethod.wechat,
      createdAt: _t1,
      updatedAt: _t1,
    );

int _sumWork(List<WorkRecord> xs) =>
    xs.fold<int>(0, (s, w) => s + w.amountSnapshot);
int _sumPay(List<PaymentRecord> xs) => xs.fold<int>(0, (s, p) => s + p.amount);

Future<void> main() async {
  _maybePreloadSystemSqlite();
  sqfliteFfiInit();
  final db = AppDatabase.instance
    ..configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  await db.open();

  // ═══════════════════════════════════════════════════════════════
  print('== 0. 播种（4 公司 × 4 形态；4 条有效工作 + 2 条草稿；3 笔收款）==');
  // ═══════════════════════════════════════════════════════════════
  await db.upsertLedger(_ledger());
  await db.upsertCompany(_company(_cidA, '甲建筑'));
  await db.upsertCompany(_company(_cidB, '乙劳务', enabled: false));
  await db.upsertCompany(_company(_cidC, '丙装修', deletedAt: _t1));
  await db.upsertCompany(_company(_cidD, '丁工程'));

  await db.upsertWorkRecord(_work('w0000001-0000-4000-8000-000000000001', _cidA, 100000));
  await db.upsertWorkRecord(_work('w0000001-0000-4000-8000-000000000002', _cidA, 50000));
  await db.upsertWorkRecord(_work('w0000001-0000-4000-8000-000000000003', _cidB, 30000));
  await db.upsertWorkRecord(_work('w0000001-0000-4000-8000-000000000004', _cidC, 20000));
  // 草稿 1：挂在有账的公司上，用来证明"不计入应收"
  await db.upsertWorkRecord(_work('w0000001-0000-4000-8000-000000000005', _cidA, 999999,
      status: RecordStatus.draft));
  // 草稿 2：**全公司只有草稿**，用来证明它不出现在 aggregateByCompany
  await db.upsertWorkRecord(_work('w0000001-0000-4000-8000-000000000006', _cidD, 77777,
      status: RecordStatus.draft));

  await db.upsertPaymentRecord(_pay('p0000001-0000-4000-8000-000000000001', _cidA, 40000));
  await db.upsertPaymentRecord(_pay('p0000001-0000-4000-8000-000000000002', _cidB, 50000));
  await db.upsertPaymentRecord(_pay('p0000001-0000-4000-8000-000000000003', _cidC, 20000));
  print('  · 播种完成');

  final aggAll = await db.aggregate(null);
  final byCompany = await db.aggregateByCompany();

  // ═══════════════════════════════════════════════════════════════
  print('== 1. 三条恒等式（AC-33 / AC-P01-13 / AC-P06-08）==');
  // ═══════════════════════════════════════════════════════════════
  {
    final worksEffective = await db.listWorkRecords(includeDraft: false);
    final pays = await db.listPaymentRecords();

    check(
      '① 应收恒等式：aggregate(null).receivable == Σ 有效工作 amount_snapshot',
      aggAll.receivable == _sumWork(worksEffective),
      'aggregate=${aggAll.receivable} / Σ明细=${_sumWork(worksEffective)}',
    );
    check(
      '② 已收恒等式：aggregate(null).received == Σ 收款 amount',
      aggAll.received == _sumPay(pays),
      'aggregate=${aggAll.received} / Σ明细=${_sumPay(pays)}',
    );
    check(
      '③ 分账恒等式：aggregate(null).remaining == Σ aggregateByCompany().remaining',
      aggAll.remaining == byCompany.fold<int>(0, (s, a) => s + a.remaining),
      'aggregate=${aggAll.remaining} / Σ公司=${byCompany.fold<int>(0, (s, a) => s + a.remaining)}',
    );
    check(
      '④ 唯一口径：remaining == receivable − received（全局）',
      aggAll.remaining == aggAll.receivable - aggAll.received,
      '${aggAll.remaining} vs ${aggAll.receivable - aggAll.received}',
    );
    check('⑤ 基线数值符合预期（200000 / 110000 / 90000）',
        aggAll.receivable == 200000 && aggAll.received == 110000 && aggAll.remaining == 90000,
        '实际 ${aggAll.receivable} / ${aggAll.received} / ${aggAll.remaining}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 2. P-DEBT「欠款合计」口径（AC-PDBT-05 / 09 §7.3）==');
  // ═══════════════════════════════════════════════════════════════
  {
    final debtRows = byCompany.where((a) => a.remaining > 0).toList();
    final overpaid = byCompany.where((a) => a.remaining < 0).toList();
    final debtTotal = debtRows.fold<int>(0, (s, a) => s + a.remaining);
    final overpaidAbs = overpaid.fold<int>(0, (s, a) => s + (-a.remaining));

    check('① debtTotal == Σ(remaining>0) == 110000', debtTotal == 110000, '实际 $debtTotal');
    check('② overpaidAbs == Σ|remaining<0| == 20000', overpaidAbs == 20000, '实际 $overpaidAbs');
    check(
      '③ ★恒等式：debtTotal − overpaidAbs == aggregate(null).remaining',
      debtTotal - overpaidAbs == aggAll.remaining,
      '$debtTotal − $overpaidAbs = ${debtTotal - overpaidAbs} vs ${aggAll.remaining}',
    );
    check('④ ★口径禁令：debtTotal != aggregate(null).remaining（不得混为一谈）',
        debtTotal != aggAll.remaining, 'both=$debtTotal');
    check(
      '⑤ remaining==0 的公司（已结清）不出现在任一视图',
      byCompany.any((a) => a.remaining == 0) &&
          !debtRows.any((a) => a.remaining == 0) &&
          !overpaid.any((a) => a.remaining == 0),
      '存在 remaining==0 分组=${byCompany.any((a) => a.remaining == 0)}',
    );
    check('⑥ 欠款行数 == 1（仅公司 A）', debtRows.length == 1, '实际 ${debtRows.length}');
    check('⑦ 多收行数 == 1（仅公司 B）', overpaid.length == 1, '实际 ${overpaid.length}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 3. 草稿不计入应收（AC-32 / 陷阱 1）——数据层 + 接口层 ==');
  // ═══════════════════════════════════════════════════════════════
  {
    final withDraft = await db.listWorkRecords(); // 默认 includeDraft: true
    final withoutDraft = await db.listWorkRecords(includeDraft: false);

    check('① 默认含草稿：6 条', withDraft.length == 6, '实际 ${withDraft.length}');
    check('② includeDraft:false：4 条', withoutDraft.length == 4, '实际 ${withoutDraft.length}');
    check('③ 关闭后不含任何 draft', withoutDraft.every((w) => w.status != RecordStatus.draft));
    check('④ 草稿金额 999999 未进入应收',
        _sumWork(withoutDraft) == 200000 && aggAll.receivable == 200000,
        'Σ=${_sumWork(withoutDraft)}');
    check('⑤ 只有草稿的公司 D 不出现于 aggregateByCompany()',
        !byCompany.any((a) => a.companyId == _cidD),
        '出现=${byCompany.any((a) => a.companyId == _cidD)}');

    // ★ 接口级防线：下钻若忘了关草稿，列表会与顶部合计对不上
    check('⑥ ★RecordsFilter.receivableDrill.includeDraft == false（陷阱 1 的接口级防线）',
        RecordsFilter.receivableDrill.includeDraft == false);
    check('⑦ RecordsFilter.all.includeDraft == true（台账语义，草稿显 —）',
        RecordsFilter.all.includeDraft == true);
    check('⑧ receivableDrill 仅 work / receivedDrill 仅 payment',
        RecordsFilter.receivableDrill.scope == RecordsScope.workOnly &&
            RecordsFilter.receivedDrill.scope == RecordsScope.paymentOnly);
    check('⑨ 下钻不带公司过滤（全局口径）',
        RecordsFilter.receivableDrill.companyId == null &&
            RecordsFilter.receivedDrill.companyId == null);
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 4. 软删不计入（口径 02:18）==');
  // ═══════════════════════════════════════════════════════════════
  {
    await db.softDeleteWorkRecord('w0000001-0000-4000-8000-000000000002', _t1);
    final a1 = await db.aggregate(null);
    check('① 软删 50000 工作记录 → 应收 150000',
        a1.receivable == 150000 && a1.remaining == 40000, '实际 ${a1.receivable}/${a1.remaining}');

    await db.softDeletePaymentRecord('p0000001-0000-4000-8000-000000000001', _t1);
    final a2 = await db.aggregate(null);
    check('② 软删 40000 收款 → 已收 70000', a2.received == 70000, '实际 ${a2.received}');

    // 复原（upsert 重写整行 → deleted_at 置回 null）
    await db.upsertWorkRecord(_work('w0000001-0000-4000-8000-000000000002', _cidA, 50000));
    await db.upsertPaymentRecord(_pay('p0000001-0000-4000-8000-000000000001', _cidA, 40000));
    final a3 = await db.aggregate(null);
    check('③ 复原后回到基线（200000 / 110000 / 90000）',
        a3.receivable == 200000 && a3.received == 110000 && a3.remaining == 90000,
        '实际 ${a3.receivable}/${a3.received}/${a3.remaining}');
    final w = await db.listWorkRecords(includeDraft: false);
    check('④ 复原后有效工作记录 4 条', w.length == 4, '实际 ${w.length}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 5. RecordsFilter 值语义（review-core M-1 回归）==');
  // ═══════════════════════════════════════════════════════════════
  {
    const a = RecordsFilter.all;
    final b = RecordsFilter.all.copyWith();

    check('① copyWith() 无参 → == 成立（★didUpdateWidget 不误触发查库的前提）', a == b);
    check('② hashCode 一致', a.hashCode == b.hashCode);
    check('③ companyWork(cid) 值相等（两次构造 ==）',
        RecordsFilter.companyWork(_cidA) == RecordsFilter.companyWork(_cidA));
    check('④ companyWork(cid) hashCode 一致',
        RecordsFilter.companyWork(_cidA).hashCode ==
            RecordsFilter.companyWork(_cidA).hashCode);
    check('⑤ all != receivableDrill', a != RecordsFilter.receivableDrill);
    check('⑥ all != receivedDrill', a != RecordsFilter.receivedDrill);
    check('⑦ includeDraft 差异能区分（receivableDrill != copyWith(includeDraft:true)）',
        RecordsFilter.receivableDrill !=
            RecordsFilter.receivableDrill.copyWith(includeDraft: true));
    check('⑧ companyId 差异能区分',
        RecordsFilter.companyWork(_cidA) != RecordsFilter.companyWork(_cidB));
    check('⑨ clearCompanyId 生效',
        RecordsFilter.companyWork(_cidA).copyWith(clearCompanyId: true).companyId == null);
    check('⑩ hasCompany / hasDateRange',
        RecordsFilter.companyWork(_cidA).hasCompany &&
            !RecordsFilter.all.hasCompany &&
            RecordsFilter.day(_t0).hasDateRange);
    check('⑪ day(d)：仅工作 + 含草稿 + 起止同一天',
        RecordsFilter.day(_t0).scope == RecordsScope.workOnly &&
            RecordsFilter.day(_t0).includeDraft == true &&
            RecordsFilter.day(_t0).startDate == _t0 &&
            RecordsFilter.day(_t0).endDate == _t0);
    check('⑫ day(d) 与 day(d2) 不等',
        RecordsFilter.day(_t0) != RecordsFilter.day(_t1));
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 6. 边界形态（AC-P01-01「有账必列」/ AC-PDBT-10）==');
  // ═══════════════════════════════════════════════════════════════
  {
    check('① 停用公司 B 仍出现在 aggregateByCompany（有账必列）',
        byCompany.any((a) => a.companyId == _cidB));
    check('② 已归档公司 C 仍出现在 aggregateByCompany（有账必列）',
        byCompany.any((a) => a.companyId == _cidC));

    final allCompanies = await db.listCompanies(includeDisabled: true, includeDeleted: true);
    final bareCompanies = await db.listCompanies();
    check('③ 双 true → 4 家（含停用 + 归档）', allCompanies.length == 4,
        '实际 ${allCompanies.length}');
    check('④ ★裸调 listCompanies() → 仅 2 家（启用且未删）——证明"必须双 true"',
        bareCompanies.length == 2, '实际 ${bareCompanies.length}');
    check('⑤ 裸调会漏掉停用公司 B（AC-P01-07 / AC-PDBT-03 / AC-P06-03 的缺陷根源）',
        !bareCompanies.any((c) => c.id == _cidB));
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 7. 「全多收」边界：debtTotal == 0 而恒等式仍成立 ==');
  // ═══════════════════════════════════════════════════════════════
  {
    // 给 A 追加一笔 240000 收款 → A: 150000 − 280000 = −130000（多收）
    await db.upsertPaymentRecord(_pay('p0000001-0000-4000-8000-00000000000f', _cidA, 240000));
    final g = await db.aggregate(null);
    final bs = await db.aggregateByCompany();
    final debtTotal = bs.where((a) => a.remaining > 0).fold<int>(0, (s, a) => s + a.remaining);
    final overpaidAbs =
        bs.where((a) => a.remaining < 0).fold<int>(0, (s, a) => s + (-a.remaining));

    check('① debtTotal == 0（无人欠我钱 → 空态分支）', debtTotal == 0, '实际 $debtTotal');
    check('② overpaidAbs == 130000 + 20000 = 150000', overpaidAbs == 150000, '实际 $overpaidAbs');
    check('③ 恒等式仍成立：0 − 150000 == aggregate(null).remaining',
        debtTotal - overpaidAbs == g.remaining,
        '${debtTotal - overpaidAbs} vs ${g.remaining}');
    check('④ Σ aggregateByCompany().remaining == 全局 remaining',
        bs.fold<int>(0, (s, a) => s + a.remaining) == g.remaining);

    // 复原
    await db.softDeletePaymentRecord('p0000001-0000-4000-8000-00000000000f', _t1);
    final back = await db.aggregate(null);
    check('⑤ 复原后回基线 90000', back.remaining == 90000, '实际 ${back.remaining}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 8. 逐公司一致（AC-P01-11 / AC-P06-08 / AC-P07-11）==');
  // ═══════════════════════════════════════════════════════════════
  {
    for (final cid in [_cidA, _cidB, _cidC]) {
      final one = await db.aggregate(cid);
      final row = byCompany.firstWhere((a) => a.companyId == cid);
      check(
        'aggregate($cid) == aggregateByCompany 同行（三字段）',
        one.receivable == row.receivable &&
            one.received == row.received &&
            one.remaining == row.remaining,
        '${one.receivable}/${one.received}/${one.remaining} vs '
        '${row.receivable}/${row.received}/${row.remaining}',
      );
    }
    // 全为 0 的公司（无任何记录）→ 取值为 0，不得判为不存在
    final empty = await db.aggregate('a0000000-0000-4000-8000-00000000ffff');
    check('未出现的公司 → 全 0（不抛错）',
        empty.receivable == 0 && empty.received == 0 && empty.remaining == 0);
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 9. 金额整数纪律（设计 §2 定点小数）==');
  // ═══════════════════════════════════════════════════════════════
  {
    final g = await db.aggregate(null);
    check('① aggregate 三字段均为 int（非 double）',
        g.receivable is int && g.received is int && g.remaining is int);
    check('② remaining == receivable − received（逐分，无浮点误差）',
        g.remaining == g.receivable - g.received);
    final ws = await db.listWorkRecords(includeDraft: false);
    check('③ 明细金额均为 int', ws.every((w) => w.amountSnapshot is int));
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 10. UI 接线静态断言（读真实 lib/ui 源码 · 剥注释 · 精确锚定；堵审计 F1~F3 逃逸）==');
  // ═══════════════════════════════════════════════════════════════
  // 依据：`docs/08-验证脚本断言强度审计/03-verify_waveA 与 waveA2.md` §3.2/§4.1。
  //   审计判定 §2「P-DEBT 欠款合计口径」等**只在测试里现算**，不验证页面接线；
  //   本段补「读真实页面源码、剥注释、切方法体、对实参精确锚定」的静态断言。
  //   目标逃逸点：F1a/F1b（P-DEBT 页面口径）、F2a/F2b（下钻 filter 实参）、
  //   F3a/F3b/F3c（P01/P-DEBT/P06 裸调 listCompanies）。
  {
    final ovw = _stripComments(_read('lib/ui/overview_page.dart'));
    final debtSrc = _stripComments(_read('lib/ui/debt_list_page.dart'));
    final cdp = _stripComments(_read('lib/ui/company_detail_page.dart'));
    final compSrc = _stripComments(_read('lib/ui/company_page.dart'));
    const doubleTrue =
        'listCompanies(includeDisabled: true, includeDeleted: true)';

    // ── F1a/F1b：P-DEBT 页面「欠款合计」口径（切片 _load 方法体）────────────
    final debtLoad = _blockAfter(debtSrc, 'Future<void> _load()');
    check(
      '⑩① P-DEBT 行集仅取 remaining > 0（切片 _load 内 `if (a.remaining > 0)` 恰 1、无 `!= 0`）[堵 F1a]',
      _count(debtLoad, 'if (a.remaining > 0)') == 1 &&
          _count(debtLoad, 'if (a.remaining != 0)') == 0,
      'if(>0)=${_count(debtLoad, 'if (a.remaining > 0)')} '
          'if(!=0)=${_count(debtLoad, 'if (a.remaining != 0)')}',
    );
    check(
      '⑩② P-DEBT 欠款合计公式 == `s + r.agg.remaining`（切片 _load 内恰 1，非取反）[堵 F1b]',
      _count(debtLoad, 's + r.agg.remaining') == 1 &&
          _count(debtLoad, 's + (-r.agg.remaining)') == 1,
      'debt=${_count(debtLoad, 's + r.agg.remaining')}(期望1) '
          'overpaid=${_count(debtLoad, 's + (-r.agg.remaining)')}(期望1)',
    );
    check(
      '⑩③ P-DEBT 页面显式标注口径（`欠款合计` 文案 + `欠款合计 ≠ 看板「剩余工资」`）[AC-PDBT-05]',
      debtSrc.contains('欠款合计') &&
          debtSrc.contains('欠款合计 ≠ 看板「剩余工资」'),
      '含欠款合计=${debtSrc.contains('欠款合计')} '
          '含口径标注=${debtSrc.contains('欠款合计 ≠ 看板「剩余工资」')}',
    );

    // ── F2a/F2b：下钻 filter 实参（切片各方法体）──────────────────────────
    final recvBody = _blockAfter(ovw, 'Future<void> _openReceivableDrill()');
    check(
      '⑩④ P01 应收下钻实参 == RecordsFilter.receivableDrill（切片内，无 .all）[堵 F2a]',
      _count(recvBody, 'filter: RecordsFilter.receivableDrill') == 1 &&
          !recvBody.contains('RecordsFilter.all'),
      '命中=${_count(recvBody, 'filter: RecordsFilter.receivableDrill')} '
          '含.all=${recvBody.contains('RecordsFilter.all')}',
    );
    final rcvdBody = _blockAfter(ovw, 'Future<void> _openReceivedDrill()');
    check(
      '⑩⑤ P01 已收下钻实参 == RecordsFilter.receivedDrill（切片内）[AC-P01-05]',
      _count(rcvdBody, 'filter: RecordsFilter.receivedDrill') == 1 &&
          !rcvdBody.contains('RecordsFilter.receivableDrill'),
      '命中=${_count(rcvdBody, 'filter: RecordsFilter.receivedDrill')}',
    );
    final workListBody = _blockAfter(cdp, 'Widget _buildWorkList()');
    check(
      '⑩⑥ P07 工作 tab 实参 == RecordsFilter.companyWork(widget.companyId)（切片内）[堵 F2b]',
      _count(workListBody, 'filter: RecordsFilter.companyWork(widget.companyId)') ==
              1 &&
          !workListBody.contains('RecordsFilter.receivableDrill'),
      '命中=${_count(workListBody, 'filter: RecordsFilter.companyWork(widget.companyId)')} '
          '含receivableDrill=${workListBody.contains('RecordsFilter.receivableDrill')}',
    );
    final payListBody = _blockAfter(cdp, 'Widget _buildPaymentList()');
    check(
      '⑩⑦ P07 收款 tab 实参 == RecordsFilter.companyPayment(widget.companyId)（切片内）[AC-P07-11]',
      _count(payListBody, 'filter: RecordsFilter.companyPayment(widget.companyId)') == 1,
      '命中=${_count(payListBody, 'filter: RecordsFilter.companyPayment(widget.companyId)')}',
    );

    // ── F3a/F3b/F3c：三页公司元数据禁裸调（精确计数，剥离注释）─────────────
    check(
      '⑩⑧ P01 公司元数据双 true 恰 1、裸调 listCompanies() 恰 0 [堵 F3a / AC-P01-07]',
      _count(ovw, doubleTrue) == 1 && _count(ovw, 'listCompanies()') == 0,
      '双true=${_count(ovw, doubleTrue)} 裸调=${_count(ovw, 'listCompanies()')}',
    );
    check(
      '⑩⑨ P-DEBT 公司元数据双 true 恰 1、裸调 listCompanies() 恰 0 [堵 F3b / AC-PDBT-03]',
      _count(debtSrc, doubleTrue) == 1 && _count(debtSrc, 'listCompanies()') == 0,
      '双true=${_count(debtSrc, doubleTrue)} 裸调=${_count(debtSrc, 'listCompanies()')}',
    );
    check(
      '⑩⑩ P06 公司元数据双 true 恰 1、裸调 listCompanies() 恰 0 [堵 F3c / AC-P06-03]',
      _count(compSrc, doubleTrue) == 1 && _count(compSrc, 'listCompanies()') == 0,
      '双true=${_count(compSrc, doubleTrue)} 裸调=${_count(compSrc, 'listCompanies()')}',
    );

    // ── U-4 下钻接线（点卡片 → P07 / 剩余工资 → P-DEBT / 按钮接线）──────────
    final openCompBody = _blockAfter(ovw, 'Future<void> _openCompanyDetail(Company c)');
    check(
      '⑩⑪ P01 点公司卡片 → CompanyDetailPage(companyId: c.id)（切片内）[AC-P01-06]',
      _count(openCompBody, 'CompanyDetailPage(companyId: c.id)') == 1 &&
          !openCompBody.contains('CompanyDebtListPage()'),
      '命中=${_count(openCompBody, 'CompanyDetailPage(companyId: c.id)')}',
    );
    final openDebtBody = _blockAfter(ovw, 'Future<void> _openDebtList()');
    check(
      '⑩⑫ P01 剩余工资 → const CompanyDebtListPage()（切片内）[AC-P01-03]',
      _count(openDebtBody, 'const CompanyDebtListPage()') == 1,
      '命中=${_count(openDebtBody, 'const CompanyDebtListPage()')}',
    );
    check(
      '⑩⑬ P01 下钻按钮接线：onReceivableTap/_openReceivableDrill、onReceivedTap/_openReceivedDrill 各恰 1 [AC-P01-04/05]',
      _count(ovw, 'onReceivableTap: _openReceivableDrill') == 1 &&
          _count(ovw, 'onReceivedTap: _openReceivedDrill') == 1,
      '应收=${_count(ovw, 'onReceivableTap: _openReceivableDrill')} '
          '已收=${_count(ovw, 'onReceivedTap: _openReceivedDrill')}',
    );
    check(
      '⑩⑭ P01 公司卡片区接线：onCompanyTap/_openCompanyDetail、onAllCompaniesTap/_openAllCompanies 各恰 1 [AC-P01-06/08]',
      _count(ovw, 'onCompanyTap: _openCompanyDetail') == 1 &&
          _count(ovw, 'onAllCompaniesTap: _openAllCompanies') == 1,
      '卡片=${_count(ovw, 'onCompanyTap: _openCompanyDetail')} '
          '全部公司=${_count(ovw, 'onAllCompaniesTap: _openAllCompanies')}',
    );
    check(
      '⑩⑮ AC-P01-07 空态判据用含停用/归档全集（`_companies.isEmpty` 恰 1）',
      _count(ovw, '_companies.isEmpty') == 1,
      '命中=${_count(ovw, '_companies.isEmpty')}',
    );
  }

  print('');
  print('──────────────────────────────────────────────');
  print('结果：$_pass 通过 / $_fail 失败');
  print('──────────────────────────────────────────────');
  exit(_fail > 0 ? 1 : 0);
}
