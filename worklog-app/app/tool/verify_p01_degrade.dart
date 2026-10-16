/// P01 降级证据脚本（v2，已如实标注证据层级）。
///
/// **本脚本能证明什么、不能证明什么——先读这段，不要误读下面的输出。**
///
/// 【实测级 / 强证据】第 0~2 节：
///   往 `work_record.amount_snapshot` 直写一条 **TEXT 脏金额**后，
///   `AppDatabase.aggregate(null)` / `aggregateByCompany()` 抛出的**确实是 `FormatException`**
///   （异常类型与原文均打印），而 `listCompanies(双 true)` / `listPaymentRecords()` 不受影响。
///   → 这证明了「降级的前提条件成立」：脏金额会以 `FormatException` 的形式出现在这两个查询上。
///
/// 【实测级 / 强证据】第 4 节（加固新增，2026-10-17）：
///   第 0~2 节只脏写 `work_record.amount_snapshot`，**收款侧** `payment_record.amount` 的
///   聚合守卫从未被观测（把守卫改成跳过 `payment_record` 仍 exit 0）。第 4 节把 work_record
///   复位、改脏 payment_record.amount，断言 aggregate/aggregateByCompany **仍然**抛
///   `FormatException`，把这条缺口补成「能置红」的真断言（q5/q6，纳入 ok 门控）。
///
/// 【同构模拟 / 弱证据】第 3 节：
///   页内 `_guard<T>` 是 `_OverviewPageState` 的**私有实例方法**，脚本里**拿不到、无法调用**。
///   第 3 节用下面 `guard<T>()` —— 一份**逐字复刻** `overview_page.dart:87-93` 的同构副本 ——
///   在 `Future.wait` 里跑一遍，证明「若按同构写法包裹，四个查询的隔离结果长这样」。
///   ⚠️ 这是**同构推理**，**不等于**页内 `_guard` 本身的实测。
///   页内 `_guard` 真的生效（且**只**吞 `FormatException`），属**读码级**证据，
///   请由读码核对 `overview_page.dart:87-93` 得出，**不要**引用本脚本的第 3 节当作实测。
///
/// 运行（与 `tool/verify_db.dart` 同一套办法；两者缺一不可）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// set WORKLOG_USE_SYSTEM_SQLITE=1
/// "D:\workspace\software\installed\tools\FlyEnv-Data\app\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev tool\verify_p01_degrade.dart
/// ```
///
/// 版本关系：本文件 supersede 早期的 `_scratch/verify_p01_degrade.dart`
/// （那份第 3 节标题写作「`_guard` 同构验证」，把同构模拟写得像实测，已按主理人裁定更正；
///   原文件按「能保留就别删」纪律留档不动）。
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

/// ⚠️ **同构副本，非页内真身。**
///
/// 逐字复刻 `lib/ui/overview_page.dart:87-93` 的 `_guard<T>`，仅用于第 3 节的同构模拟。
/// 页内真身是 `_OverviewPageState` 的私有实例方法，脚本无法调用 → 本函数**取代不了**对它的实测。
Future<T?> guard<T>(Future<T> future) async {
  try {
    return await future;
  } on FormatException {
    return null;
  }
}

const _ledgerId = 'b0000000-0000-4000-8000-000000000001';
const _cidA = 'b0000000-0000-4000-8000-00000000000a';
const _wid1 = 'b0000001-0000-4000-8000-000000000001';
const _pid1 = 'b0000001-0000-4000-8000-000000000002';

final _t0 = DateTime(2026, 10, 1, 9, 0);

Future<void> main() async {
  _maybePreloadSystemSqlite();
  sqfliteFfiInit();
  final db = AppDatabase.instance
    ..configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  await db.open();

  // ── 播种：1 账本 + 1 公司 + 1 条有效工作（应收 100000）+ 1 笔收款（50000）──
  await db.upsertLedger(Ledger(id: _ledgerId, name: '账本', createdAt: _t0));
  await db.upsertCompany(Company(
    id: _cidA,
    ledgerId: _ledgerId,
    name: '甲建筑',
    color: 0xE53935,
    createdAt: _t0,
    updatedAt: _t0,
  ));
  await db.upsertWorkRecord(WorkRecord(
    id: _wid1,
    workDate: _t0,
    companyId: _cidA,
    methodSnapshot: PricingMethod.hourly,
    qtySnapshot: 4,
    rateSnapshot: 25000,
    rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
    amountSnapshot: 100000,
    amountSource: AmountSource.auto,
    status: RecordStatus.confirmed,
    createdAt: _t0,
    updatedAt: _t0,
  ));
  await db.upsertPaymentRecord(PaymentRecord(
    id: _pid1,
    paymentDate: _t0,
    companyId: _cidA,
    amount: 50000,
    method: PaymentMethod.wechat,
    createdAt: _t0,
    updatedAt: _t0,
  ));

  final before = await db.aggregate(null);
  print('== 0. 基线（脏写之前）==');
  print('  aggregate(null) = 应收 ${before.receivable} / 已收 ${before.received} / 剩余 ${before.remaining}');

  // ── 直写 TEXT 脏金额（绕过一切类型守卫，模拟"被外部工具改过数据库"）──
  final raw = db.db!;
  final n = await raw.rawUpdate(
    'UPDATE work_record SET amount_snapshot = ? WHERE id = ?',
    ['不是数字', _wid1],
  );
  print('== 1. 直写脏值 ==');
  print('  rawUpdate 影响行数 = $n');
  final verify = await raw.rawQuery(
      'SELECT typeof(amount_snapshot) AS t, amount_snapshot AS v FROM work_record WHERE id = ?',
      [_wid1]);
  print('  库内实况 = ${verify.first}');

  // ── 2. 四个查询各自的真实行为（【实测级】）──
  print('== 2. 四查询独立行为【实测级】（脏值在 work_record，未脏 payment_record）==');

  print('-- 2.1 aggregate(null) --');
  try {
    final r = await db.aggregate(null);
    print('  ✗ 未抛异常（与预期不符）：$r');
  } catch (e) {
    print('  抛出类型 = ${e.runtimeType}');
    print('  异常原文 = $e');
    print(e is FormatException ? '  ✓ 确认为 FormatException' : '  ✗ 非 FormatException');
  }

  print('-- 2.2 aggregateByCompany() --');
  try {
    final r = await db.aggregateByCompany();
    print('  ✗ 未抛异常（与预期不符）：$r');
  } catch (e) {
    print('  抛出类型 = ${e.runtimeType}');
    print('  FormatException? ${e is FormatException}');
  }

  print('-- 2.3 listCompanies(includeDisabled: true, includeDeleted: true) --');
  try {
    final r = await db.listCompanies(includeDisabled: true, includeDeleted: true);
    print('  ✓ 成功，公司数 = ${r.length} → 证明卡片可照常渲染');
  } catch (e) {
    print('  ✗ 意外抛出：${e.runtimeType} $e');
  }

  print('-- 2.4 listPaymentRecords() --');
  try {
    final r = await db.listPaymentRecords();
    print('  ✓ 成功，收款数 = ${r.length} → 最近收款日期仍可得');
  } catch (e) {
    print('  ✗ 意外抛出：${e.runtimeType} $e');
  }

  // ── 3.【同构模拟 / 弱证据】──
  print('');
  print('== 3. 同构模拟（复刻 _guard 的 try/on FormatException，**非**调用页内 _guard）==');
  print('   注：页内 _guard 是 _OverviewPageState 私有实例方法，本脚本无法调用；');
  print('       本节用的是本文件内的同构副本 guard<T>()，结论**不等于**页内 _guard 的实测。');
  final res = await Future.wait<Object?>([
    guard(db.aggregate(null)),
    guard(db.aggregateByCompany()),
    guard(db.listCompanies(includeDisabled: true, includeDeleted: true)),
    guard(db.listPaymentRecords()),
  ]);
  print('  q1  aggregate(null)        == null ? ${res[0] == null}  → 降级（剩余/应收/已收 显 —）');
  print('  q2  aggregateByCompany()   == null ? ${res[1] == null}  → 降级（卡片金额位 显 —）');
  print('  q3  listCompanies(双 true) == null ? ${res[2] == null}  → 未降级（卡片照常渲染）');
  print('  q4  listPaymentRecords()   == null ? ${res[3] == null}  → 未降级（最近收款日期可用）');

  // ── 4.【实测级·对称观测】把脏值改到 payment_record，验证「收款侧守卫」同样生效 ──
  //
  // 为什么要有这一节：第 0~2 节只脏写了 `work_record.amount_snapshot`。
  // 若把 `_assertAggregateColumnTypes` 改成 `if (rows.isEmpty || table == 'payment_record') return;`
  // （即**只**跳过收款表守卫），第 0~3 节的结论**一字不变**——脚本仍然 exit 0。
  // 这是覆盖面缺口：收款侧 `payment_record.amount` 的聚合守卫从未被观测。
  // 本节把 work_record 复位为整数、改脏 payment_record.amount，再断言
  // aggregate/aggregateByCompany **仍然**抛 FormatException，把缺口补上。
  print('');
  print('== 4. 对称观测：脏值改到 payment_record【实测级】（补收款侧守卫覆盖）==');
  await raw.rawUpdate(
    'UPDATE work_record SET amount_snapshot = ? WHERE id = ?',
    [100000, _wid1],
  );
  await raw.rawUpdate(
    'UPDATE payment_record SET amount = ? WHERE id = ?',
    ['不是数字', _pid1],
  );
  final wVerify = await raw.rawQuery(
      'SELECT typeof(amount_snapshot) AS t FROM work_record WHERE id = ?', [_wid1]);
  final pVerify = await raw.rawQuery(
      'SELECT typeof(amount) AS t, amount AS v FROM payment_record WHERE id = ?', [_pid1]);
  print('  work_record.amount_snapshot typeof = ${wVerify.first['t']}（应为 integer，已复位）');
  print('  payment_record.amount  库内实况 = ${pVerify.first}');

  Future<bool> throwsFormat(Future<Object?> f) async {
    try {
      await f;
      return false;
    } catch (e) {
      return e is FormatException;
    }
  }

  final q5 = await throwsFormat(db.aggregate(null));
  final q6 = await throwsFormat(db.aggregateByCompany());
  print('  q5  aggregate(null)                    抛 FormatException ? $q5'
      '  → 收款侧守卫生效（否则脏收款被静默按 0 计入）');
  print('  q6  aggregateByCompany()               抛 FormatException ? $q6');
  final okPayment = q5 && q6;

  final ok = res[0] == null &&
      res[1] == null &&
      res[2] != null &&
      res[3] != null &&
      okPayment;
  print('');
  print('──────────────────────────────────────────────');
  print(ok
      ? '结论【实测级】：脏金额 → aggregate/aggregateByCompany 抛 FormatException；'
          'listCompanies/listPaymentRecords 不受影响。降级前提成立。\n'
          '结论【实测级·对称】：脏 work_record 与脏 payment_record 各自都能触发守卫 → '
          '两表守卫均被测（q1/q2 覆盖 work_record，q5/q6 覆盖 payment_record）。\n'
          '结论【同构推理】：按 _guard 的同构写法包裹后，正是这四元组被逐一隔离。\n'
          '待读码核（读码级）：页内 _guard 只吞 FormatException（overview_page.dart:87-93）。'
      : '结论：与预期不符（见上）。');
  print('──────────────────────────────────────────────');
  exit(ok ? 0 : 1);
}
