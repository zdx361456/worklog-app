/// d-02 · 口径对照测试：锁定「db 层 SQL 聚合」与「service 层纯函数」的等价性（Q1 等价关系）。
///
/// 运行：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// flutter test test\receivable_parity_test.dart
/// ```
///
/// ⚠️ **验证状态（如实标注，2026-09-30）**：**本文件未经编译验证**。
/// 原因：产出该文件的机器上，Dart VM 存在机器级进程创建缺陷（`CreateFile failed 231 /
/// ProcessException`），`dart analyze` 与 `flutter test` 均无法运行；且本文件依赖
/// `package:flutter_test`（需 Flutter patched SDK 平台），离线类型检查工具链亦不可用。
/// 现有证据**仅**为 `dart format` 解析检查通过（语法层面）。
/// **请在本机执行 `flutter test test\receivable_parity_test.dart` 确认后再据此文件下断言。**
/// 其断言语义与**已验证**的 `tool/verify_db.dart` §6（实跑 16 项全绿）等价——
/// 如需立即取得运行证据，可先跑 `tool/verify_db.dart`。
///
/// **为什么必须有这个测试**：剩余工资唯一口径（§5.1「剩余 = 应收 − 已收」）在项目里
/// 落在两处独立实现上 —— `db/database.dart` 的 SQL 聚合（`aggregate` / `aggregateByCompany`）
/// 与 `services/receivable_service.dart` 的 Dart 纯函数。二者必须逐条件等价，
/// 任何一处漂移都会让「首页看板 / 公司详情 / 统计 / 日历下钻 / 导出文件」五处显示对不上
/// （AC-33）。本测试用**同一组数据**同时喂两条路径，逐字段断言相等，
/// 并把口径关键点（草稿不计入 / 软删不计入 / 公司维度过滤）固化为可执行断言。
///
/// 覆盖类型：
/// - 正常：四态混合（draft / confirmed / settled / 软删）
/// - 边界：空库全 0；多收（剩余为负）；多公司互不污染
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:worklog_app/db/database.dart';
import 'package:worklog_app/models/payment_record.dart';
import 'package:worklog_app/models/types.dart';
import 'package:worklog_app/models/work_record.dart';
import 'package:worklog_app/services/receivable_service.dart';

// ── 测试数据构造 ──

final _now = DateTime(2026, 9, 30, 9, 0);

const _c1 = '22222222-2222-4222-8222-222222222222';
const _c2 = '33333333-3333-4333-8333-333333333333';

WorkRecord _work(
  String id,
  String companyId,
  int amount, {
  RecordStatus status = RecordStatus.confirmed,
  DateTime? deletedAt,
}) =>
    WorkRecord(
      id: id,
      workDate: _now,
      companyId: companyId,
      methodSnapshot: PricingMethod.hourly,
      qtySnapshot: 4,
      rateSnapshot: amount,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
      amountSnapshot: amount,
      amountSource: AmountSource.auto,
      status: status,
      createdAt: _now,
      updatedAt: _now,
      deletedAt: deletedAt,
    );

PaymentRecord _pay(
  String id,
  String companyId,
  int amount, {
  DateTime? deletedAt,
}) =>
    PaymentRecord(
      id: id,
      paymentDate: _now,
      companyId: companyId,
      amount: amount,
      createdAt: _now,
      updatedAt: _now,
      deletedAt: deletedAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.instance;
    db.configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    await db.open();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  group('口径对照：四态混合（正常）', () {
    final records = <WorkRecord>[
      _work('70000001-1111-4111-8111-111111111111', _c1, 10000,
          status: RecordStatus.confirmed),
      _work('70000002-1111-4111-8111-111111111111', _c1, 20000,
          status: RecordStatus.settled),
      _work('70000003-1111-4111-8111-111111111111', _c1, 9999,
          status: RecordStatus.draft), // 草稿：不计入应收（AC-32）
      _work('70000004-1111-4111-8111-111111111111', _c1, 5000,
          status: RecordStatus.confirmed, deletedAt: _now), // 软删：不计入
      _work('70000005-1111-4111-8111-111111111111', _c2, 7000,
          status: RecordStatus.confirmed),
    ];
    final payments = <PaymentRecord>[
      _pay('80000001-1111-4111-8111-111111111111', _c1, 12000),
      _pay('80000002-1111-4111-8111-111111111111', _c1, 3000,
          deletedAt: _now), // 软删：不计入
      _pay('80000003-1111-4111-8111-111111111111', _c2, 1000),
    ];

    setUp(() async {
      for (final r in records) {
        await db.upsertWorkRecord(r);
      }
      for (final p in payments) {
        await db.upsertPaymentRecord(p);
      }
    });

    test('db.aggregate 应收/已收/剩余 与 service 逐字段相等（公司 C1）', () async {
      const svc = ReceivableService();
      final agg = await db.aggregate(_c1);
      final s = svc.companySummary(
          companyId: _c1, records: records, payments: payments);

      expect(agg.receivable, s.receivable);
      expect(agg.received, s.received);
      expect(agg.remaining, s.remaining);

      // 绝对数值锚点：防止"两条路径同错"
      expect(agg.receivable, 30000, reason: 'confirmed 10000 + settled 20000；草稿与软删排除');
      expect(agg.received, 12000, reason: '软删收款 3000 排除');
      expect(agg.remaining, 18000);
    });

    test('db.aggregate 与 service 相等（公司 C2，互不污染）', () async {
      const svc = ReceivableService();
      final agg = await db.aggregate(_c2);
      final s = svc.companySummary(
          companyId: _c2, records: records, payments: payments);
      expect(agg.receivable, s.receivable);
      expect(agg.received, s.received);
      expect(agg.remaining, s.remaining);
      expect(agg.remaining, 6000, reason: '7000 − 1000');
    });

    test('全局口径（companyId=null）与 service 全量集合相等', () async {
      const svc = ReceivableService();
      final aggAll = await db.aggregate(null);
      // 从库里全量回读（含草稿与软删），与 service 纯函数比对，避免"漏喂数据"
      final allRecords = await db.listWorkRecords(includeDeleted: true);
      final allPayments = await db.listPaymentRecords(includeDeleted: true);
      expect(aggAll.receivable, svc.receivable(allRecords));
      expect(aggAll.received, svc.received(allPayments));
      expect(aggAll.remaining, aggAll.receivable - aggAll.received);
    });

    test('aggregateByCompany 与逐公司 service 结果相等', () async {
      const svc = ReceivableService();
      final byCompany = await db.aggregateByCompany();
      for (final cid in [_c1, _c2]) {
        final rows = byCompany.where((e) => e.companyId == cid).toList();
        expect(rows, hasLength(1), reason: '公司 $cid 应有且仅有一行');
        final s = svc.companySummary(
            companyId: cid, records: records, payments: payments);
        expect(rows.first.receivable, s.receivable);
        expect(rows.first.received, s.received);
        expect(rows.first.remaining, s.remaining);
      }
    });
  });

  group('口径对照：边界', () {
    test('空库 → 应收/已收/剩余 全 0，且与 service 空集合一致', () async {
      const svc = ReceivableService();
      final agg = await db.aggregate(_c1);
      expect(agg.receivable, 0);
      expect(agg.received, 0);
      expect(agg.remaining, 0);
      expect(agg.receivable, svc.receivable(<WorkRecord>[]));
      expect(agg.received, svc.received(<PaymentRecord>[]));
      // 无数据的公司不应出现在分组结果里
      expect(await db.aggregateByCompany(), isEmpty);
    });

    test('多收（已收 > 应收）→ 剩余为负，两条路径一致', () async {
      const svc = ReceivableService();
      final records = [
        _work('90000001-1111-4111-8111-111111111111', _c1, 5000),
      ];
      final payments = [
        _pay('90000002-1111-4111-8111-111111111111', _c1, 8000),
      ];
      await db.upsertWorkRecord(records.first);
      await db.upsertPaymentRecord(payments.first);

      final agg = await db.aggregate(_c1);
      final s = svc.companySummary(
          companyId: _c1, records: records, payments: payments);
      expect(agg.remaining, -3000);
      expect(agg.remaining, s.remaining);
      expect(agg.remaining, agg.receivable - agg.received);
    });

    test('全部记录为草稿 → 应收 0（草稿不计入，AC-32）', () async {
      const svc = ReceivableService();
      final records = [
        _work('91000001-1111-4111-8111-111111111111', _c1, 12345,
            status: RecordStatus.draft),
      ];
      await db.upsertWorkRecord(records.first);

      final agg = await db.aggregate(_c1);
      expect(agg.receivable, 0);
      expect(agg.receivable, svc.receivable(records));
    });
  });

  group('口径对照：事务内读（aggregateOn）', () {
    test('事务内未提交的写入对 aggregateOn 可见，且与 service 一致', () async {
      const svc = ReceivableService();
      final rec = _work('92000001-1111-4111-8111-111111111111', _c1, 1234);

      await db.transaction((txn) async {
        await db.upsertWorkRecordOn(txn, rec);
        final inside = await db.aggregateOn(txn, _c1);
        expect(inside.receivable, 1234);
        expect(inside.receivable, svc.receivable([rec]));
      });

      final after = await db.aggregate(_c1);
      expect(after.receivable, 1234);
    });
  });
}
