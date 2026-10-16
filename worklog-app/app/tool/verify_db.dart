/// 数据访问层运行时验证脚本（纯 Dart，无需 Flutter / 无需设备）。
///
/// 运行（前提：`pub get` 已执行，见 pubspec.yaml）。**本机可复现的命令**（已实跑 93/0）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// set WORKLOG_USE_SYSTEM_SQLITE=1
/// "D:\workspace\software\installed\tools\FlyEnv-Data\app\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev tool\verify_db.dart
/// ```
/// **为何不用 `dart run`**（实证，2026-09-30）：`sqflite_common_ffi` → `sqlite3` 包带
/// native-assets 构建钩子；`dart run` 会先联网/编译该钩子（`cmd /c ... dart compile kernel
/// ...\sqlite3-3.6.0\hook\build.dart`），而本机 Dart VM 存在进程创建缺陷
/// （`CreateFile failed 231 / ProcessException`，`process_win.cc:744`），钩子必然失败。
/// `--disable-dart-dev`（直接用 VM 跑脚本、不经 dartdev）会**跳过该钩子**；
/// 此时用 [_maybePreloadSystemSqlite] 预加载系统 SQLite（Windows 10+ 自带
/// `winsqlite3.dll`）满足 `sqlite3` 的 `@Native` 符号解析，全程离线可跑。
/// 即：`set WORKLOG_USE_SYSTEM_SQLITE=1` 与 `--disable-dart-dev` **两者缺一不可**。
///
/// 为什么本脚本能跑而 verify_core.dart 不覆盖本层：
///   `lib/db/database.dart` 已改为只依赖 `package:sqflite_common`（纯 Dart）。
///   若它 import `package:sqflite`，则会经 `package:flutter/foundation.dart` 传递依赖
///   `dart:ui`，纯 Dart VM 直接报 `Dart library 'dart:ui' is not available on this platform`，
///   本脚本将无法运行（这是 V-3 要求「纯 Dart 可验证」的硬前提）。
///
/// 覆盖（对应 V-3 五项 + C-01 反证 + R2 语义钉死）：
///  1. 六表基本 CRUD 往返
///  2. 事务正常提交（bulk 写入 + 数量断言）
///  3. 事务中途抛错 → 整体回滚（**C-01 关键证据**）
///  4. `aggregate` 应收/已收/剩余 与 `ReceivableService` 口径逐项一致（d-02 脚本版）
///  5. 软删后不计入聚合
///  6. 事务内用 `...On(txn, ...)` 能读到未提交数据（C-01 正向证据）
///  7. 语义钉死（把「注释」变成「可执行断言」，防再次漂移）：
///     - holiday_mark 的 `INSERT OR REPLACE` 真行为（**R2-01**：换 id 同 (ledger,date) 静默替换、
///       不抛异常、行数不变、id 变为新值、旧行被删）；
///     - `listCompanies` 停用过滤与 `listPricingRules` 对称（**R2-06**）。
///  8. 脏金额硬化（B3 / R2-04 / **G-03** / **M-01**）：直写 REAL 非整值 → **行映射 / 整表读抛 `FormatException`**
///     （不再静默截断）；**G-03 硬化后聚合路径（`aggregate` / `aggregateByCompany`）同样抛错**
///     （原「聚合不抛错」的 B2 断言已**反转**）；**G-02** 容错读入口（`*Lenient`）跳过坏行并收集；
///     **M-01**（§8b）聚合**类型前置守卫**：TEXT / BLOB 被 `SUM()` 洗成 `0.0`，由 SQL 侧 `typeof`
///     守卫拦下（含 int + 无损 REAL 的**防误伤**对照）。
///  8b. **0-A.1 补丁轮**（§8c）：
///     - **Minor-1**：`work_record.amount_snapshot` 守卫**门禁**——`amount_snapshot='abc'` →
///       `aggregate` / `aggregateByCompany` 均抛（此前只有 payment 侧有脏行用例，work 侧虽被调用但从未被触发）；
///     - **Minor-4**：`int64` 范围守卫——整值 double `1e20` 经 `_asAggregateInt` / `_asAmountColumn`
///       均抛（拒绝 `toInt()` 静默钳位到 `9223372036854775807`），`48000.0` 反向对照放行。
///  9. 快照护栏（I-8 / **G-11**）：`updateWorkRecordMeta` 只改 Meta 且快照四件套不变、不存在 id 抛错；
///     `replaceWorkRecordSnapshot` 仅覆盖快照块、可空列传 null → 清空、非空列传 null → 保留。
/// 10. 【反证】事务内调用**公开**方法会超时（**只认 `TimeoutException` 或 sqflite 重入/锁定错误**，
///     其它异常单独报、不计入死锁），证明 C-01 原缺陷真实存在。
/// 11. **断言加固轮**（2026-10-16，消除独立变异测试审计实测的 G1~G7 逃逸 + S1 结构缺陷）：
///     - **G3**（最严重）：`aggregateByCompany.remaining` 此前**从不比对**——把 `:377` 的
///       `receivable - received` 反成 `received - receivable` 仍全绿，而 P06 公司列表页每行剩余
///       正是取此字段。→ 补「派生一致 + 与 service 逐字段一致 + 绝对值锚点（公司C 18000 / 公司D 6000）」；
///     - **G1/G2**：`listWorkRecords` / `listPaymentRecords` 的**默认软删过滤**（`:1262` / `:1288`）
///       此前从未被调用（§5/§6 只验聚合 SQL）→ 补夹具断言（条数 + 差值 + every(!isDeleted)）；
///     - **G7**：`listWorkRecords(includeDraft:false)`（`:1263`，即 `calendar_page.dart:93` 在用、
///       AC-P03-04 日历色点口径）此前从未被调用 → 补「排除草稿 + 条数 + 前后差值」；
///     - **G5/G6**：`listCompanies`（`:472`）/ `listPricingRules`（`:557`）的**软删过滤**此前无断言
///       （§7 只验了 `enabled` 过滤）→ 补软删前后断言；
///     - **G4**：`_recordStatus` 脏状态兜底方向（`database.dart:1638-1640`，M-03 修复本身）
///       此前**零用例** → 新增 §8d：绕过模型直改 `status` 列为未知值，三条断言覆盖
///       ①行映射兜底 `draft`、②**行读派生**（`ReceivableService` 按解析枚举累加——
///       这是兜底方向反转时「剩余虚增」的真实风险路径）、③SQL 聚合力保「原始字符串过滤」事实；
///     - **S1**：`main()` 外层加**全局异常兜底**——实现侧抛未捕获异常时必定打印
///       `结果：N 通过 / M 失败` 并 exit=1（旧行为是 exit=255，且其后 36 条断言被静默掩盖）。
///
/// 注记（与 `test/receivable_parity_test.dart` 的关系）：本脚本打印的 **§6「aggregate 与
/// ReceivableService 口径一致（d-02）」** 与 `test/receivable_parity_test.dart` **语义等价**——
/// 同一组数据同时喂「db 层 SQL 聚合」与「service 层纯函数」，逐字段断言相等。二者是同一口径的
/// **两套载体**：本脚本 **纯 Dart 可跑**（本机实跑 93/0）；`receivable_parity_test.dart` 依赖
/// `flutter_test`（需 Flutter patched SDK / engine），**本机不可编译运行**（见该文件头部标注）。
/// 因此「口径等价」的**运行证据以本脚本为准**；测试文件待 Flutter 环境就绪后补跑，**二者非覆盖不同**。
library;

import 'dart:async';
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
import '../lib/services/receivable_service.dart';

/// Windows 下「无 native-assets」时的兜底：预加载系统 SQLite 动态库，
/// 让 `sqlite3` 包的 `@Native` 符号解析走到「process 查找」回退路径时能命中。
///
/// 仅在显式设置 `WORKLOG_USE_SYSTEM_SQLITE=1` 时启用——正常路径（`dart run`
/// 已构建 native assets）无需且不应预加载，以免与包内原生库重复加载。
void _maybePreloadSystemSqlite() {
  if (!Platform.isWindows) return;
  if (Platform.environment['WORKLOG_USE_SYSTEM_SQLITE'] != '1') return;
  for (final name in ['sqlite3.dll', 'winsqlite3.dll']) {
    try {
      DynamicLibrary.open(name);
      print('  · 已预加载系统 SQLite 动态库：$name（WORKLOG_USE_SYSTEM_SQLITE=1）');
      return;
    } catch (_) {
      // 继续尝试下一个
    }
  }
  print('  ! 未能预加载任何系统 SQLite 动态库，后续可能因缺少原生库而失败');
}

// ── 极简断言器（与 tool/verify_core.dart 同风格，无第三方测试框架依赖）──

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

// ── 固定测试数据（全部使用合法 UUID 形状，与设计 §3.2 一致）──

const _ledgerId = '11111111-1111-4111-8111-111111111111';
const _companyA = '22222222-2222-4222-8222-222222222222';
const _companyB = '33333333-3333-4333-8333-333333333333';
const _ruleA = '44444444-4444-4444-8444-444444444444';

// 第 6 节口径对照专用公司：刻意与前面各节隔离，避免历史写入污染数值断言
const _companyC = '55555555-5555-4555-8555-555555555555';
const _companyD = '66666666-6666-4666-8666-666666666666';

// §8（REAL 非整脏值）与 §8b（M-01 前置清理）共用的脏行 id（块内局部常量无法跨节引用，故提升）
const _dirtyPayId = 'd0111111-1111-4111-8111-111111111111';

final _now = DateTime(2026, 9, 30, 9, 0);

Ledger _ledger() => Ledger(id: _ledgerId, name: '我的账本', createdAt: _now);

Company _company(String id, String name, {bool enabled = true}) => Company(
      id: id,
      ledgerId: _ledgerId,
      name: name,
      color: 0xE53935,
      enabled: enabled,
      createdAt: _now,
      updatedAt: _now,
    );

PricingRule _rule(String id,
        {String companyId = _companyA, bool enabled = true, String name = '木工'}) =>
    PricingRule(
      id: id,
      companyId: companyId,
      name: name,
      method: PricingMethod.hourly,
      baseRate: 4000,
      unit: '小时',
      enabled: enabled,
      createdAt: _now,
      updatedAt: _now,
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
      method: PaymentMethod.wechat,
      createdAt: _now,
      updatedAt: _now,
      deletedAt: deletedAt,
    );

HolidayMark _holiday(String id, DateTime date) => HolidayMark(
      id: id,
      ledgerId: _ledgerId,
      date: date,
      type: HolidayType.statutory,
      rate: 30,
      createdAt: _now,
    );

Future<void> main() async {
  // ── S1 加固（2026-10-16）：脚本级异常兜底 ──
  // 加固前：实现侧一旦抛未捕获异常（实测 `_parseLenient` 的 catch 体改成 `rethrow`），
  // 脚本直接崩溃 exit=255，**不打印 `结果：N 通过 / M 失败`**，且其后 36 条断言
  // （§8b 尾部 + §8c + §9 + §10）**全部被掩盖**，违反「单点归因」纪律（无法判断是
  // 哪条断言红了、也看不出还有多少断言没跑）。
  // 加固后：任何未捕获异常都计入失败数、打印结果行、exit=1 —— 「崩溃」与「置红」在
  // 退出码与结果行上均可区分且必定可见，断言不再被静默掩盖。
  try {
    await _run();
  } catch (e, st) {
    _fail++;
    print('  ✗ 【脚本级异常】实现抛出未捕获异常，脚本提前终止（断言未跑完）：');
    print('    ${e.runtimeType}: $e');
    print('    ${st.toString().split('\n').take(3).join('\n    ')}');
    print('\n结果：$_pass 通过 / $_fail 失败  （⚠️ 未跑完全部断言，异常见上）');
    exit(1);
  }
}

Future<void> _run() async {
  _maybePreloadSystemSqlite();
  // sqflite 在纯 Dart 下必须用 ffi 工厂 + 内存库（不落盘）
  sqfliteFfiInit();
  final db = AppDatabase.instance
    ..configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  await db.open();

  // ═══════════════════════════════════════════════════════════════
  print('== 1. 六表 CRUD 往返 ==');
  // ═══════════════════════════════════════════════════════════════
  {
    await db.upsertLedger(_ledger());
    final l = await db.getLedger(_ledgerId);
    check('ledger 往返：name/currency/mode',
        l?.name == '我的账本' && l?.currency == 'CNY' && l?.mode == LedgerMode.local,
        '实际 ${l?.name}/${l?.currency}/${l?.mode}');
    check('ledger list = 1', (await db.listLedgers()).length == 1);

    await db.upsertCompany(_company(_companyA, '装修队'));
    final c = await db.getCompany(_companyA);
    check('company 往返：name/color/enabled/ledgerId',
        c?.name == '装修队' && c?.color == 0xE53935 && c?.enabled == true && c?.ledgerId == _ledgerId,
        '实际 ${c?.name}/${c?.color}/${c?.enabled}');
    check('company 按账本过滤 = 1',
        (await db.listCompanies(ledgerId: _ledgerId)).length == 1);

    await db.upsertPricingRule(_rule(_ruleA));
    final r = await db.getPricingRule(_ruleA);
    check('pricing_rule 往返：method/baseRate/倍率',
        r?.method == PricingMethod.hourly && r?.baseRate == 4000 && r?.overtimeRate == 15,
        '实际 ${r?.method}/${r?.baseRate}/${r?.overtimeRate}');

    await db.upsertWorkRecord(_work('aaaaaaa1-1111-4111-8111-111111111111', _companyA, 16000));
    final w = await db.getWorkRecord('aaaaaaa1-1111-4111-8111-111111111111');
    check('work_record 往返：amountSnapshot/mode/appliedRate',
        w?.amountSnapshot == 16000 &&
            w?.methodSnapshot == PricingMethod.hourly &&
            w?.rateDetailSnapshot.appliedRate == 10,
        '实际 ${w?.amountSnapshot}');
    check('work_record 可空字段保留 null', w?.note == null && w?.deletedAt == null);

    await db.upsertPaymentRecord(_pay('bbbbbbb1-1111-4111-8111-111111111111', _companyA, 5000));
    final p = await db.getPaymentRecord('bbbbbbb1-1111-4111-8111-111111111111');
    check('payment_record 往返：amount/method',
        p?.amount == 5000 && p?.method == PaymentMethod.wechat,
        '实际 ${p?.amount}/${p?.method}');

    final hDate = DateTime(2026, 10, 1);
    await db.upsertHolidayMark(_holiday('ccccccc1-1111-4111-8111-111111111111', hDate));
    check('holiday_mark 按 id 往返',
        (await db.getHolidayMark('ccccccc1-1111-4111-8111-111111111111'))?.type ==
            HolidayType.statutory);
    check('holiday_mark 按 (ledger,date) 反查命中',
        (await db.getHolidayMarkByDate(_ledgerId, hDate))?.rate == 30);
    check('holiday_mark 未标记日返回 null',
        (await db.getHolidayMarkByDate(_ledgerId, DateTime(2026, 10, 2))) == null);
    check('holiday_mark list = 1',
        (await db.listHolidayMarks(ledgerId: _ledgerId)).length == 1);
    await db.deleteHolidayMark('ccccccc1-1111-4111-8111-111111111111');
    check('holiday_mark 物理删除生效',
        (await db.listHolidayMarks(ledgerId: _ledgerId)).isEmpty);

    // 更新路径
    await db.updateCompany(_company(_companyA, '装修队（改名）'));
    check('company update 生效',
        (await db.getCompany(_companyA))?.name == '装修队（改名）');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 2. 事务正常提交（bulk + 数量断言）==');
  // ═══════════════════════════════════════════════════════════════
  {
    final before = (await db.listWorkRecords(companyId: _companyB)).length;
    await db.transaction((txn) async {
      for (var i = 0; i < 3; i++) {
        await db.upsertWorkRecordOn(
          txn,
          _work('ddddddd$i-1111-4111-8111-111111111111', _companyB, 1000 * (i + 1)),
        );
      }
    });
    final after = (await db.listWorkRecords(companyId: _companyB)).length;
    check('事务提交：3 条全部落库', after == before + 3, 'before=$before after=$after');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 3. 事务中途抛错 → 整体回滚（C-01 关键证据）==');
  // ═══════════════════════════════════════════════════════════════
  {
    final before = (await db.listWorkRecords(companyId: _companyB)).length;
    var threw = false;
    try {
      await db.transaction((txn) async {
        await db.upsertWorkRecordOn(
          txn, _work('eeeeeee1-1111-4111-8111-111111111111', _companyB, 11111));
        await db.upsertPaymentRecordOn(
          txn, _pay('eeeeeee2-1111-4111-8111-111111111111', _companyB, 22222));
        throw StateError('模拟导入中途失败');
      });
    } catch (_) {
      threw = true;
    }
    final after = (await db.listWorkRecords(companyId: _companyB)).length;
    check('异常已向上抛出', threw);
    check('回滚：工作记录数量不变（无部分写入）', after == before, 'before=$before after=$after');
    check('回滚：被写入的收款记录不存在',
        (await db.getPaymentRecord('eeeeeee2-1111-4111-8111-111111111111')) == null);
    check('回滚：被写入的工作记录不存在',
        (await db.getWorkRecord('eeeeeee1-1111-4111-8111-111111111111')) == null);
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 4. 事务内用 On 版本可读到未提交数据（C-01 正向证据）==');
  // ═══════════════════════════════════════════════════════════════
  {
    int? insideView;
    int? outsideViewBefore;
    outsideViewBefore = (await db.aggregate(_companyB)).receivable;
    await db.transaction((txn) async {
      await db.upsertWorkRecordOn(
        txn, _work('ffffff01-1111-4111-8111-111111111111', _companyB, 999));
      insideView = (await db.aggregateOn(txn, _companyB)).receivable;
    });
    final outsideViewAfter = (await db.aggregate(_companyB)).receivable;
    check('事务内 aggregateOn 读到未提交写入',
        insideView == outsideViewBefore + 999,
        'inside=$insideView before=$outsideViewBefore');
    check('提交后事务外 aggregate 同步可见',
        outsideViewAfter == outsideViewBefore + 999,
        'after=$outsideViewAfter');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 5. 软删后不计入聚合 ==');
  // ═══════════════════════════════════════════════════════════════
  {
    final r0 = (await db.aggregate(_companyA)).receivable;
    // 造一条 confirmed 记录再软删，应收应回到 r0
    await db.upsertWorkRecord(
        _work('99999901-1111-4111-8111-111111111111', _companyA, 7777));
    final r1 = (await db.aggregate(_companyA)).receivable;
    check('新增 confirmed 记录后应收 +7777', r1 == r0 + 7777, 'r0=$r0 r1=$r1');
    await db.softDeleteWorkRecord('99999901-1111-4111-8111-111111111111', _now);
    final r2 = (await db.aggregate(_companyA)).receivable;
    check('软删后应收回落（不计入）', r2 == r0, 'r0=$r0 r2=$r2');
    check('软删记录仍可按 id 读出（带 deleted_at）',
        (await db.getWorkRecord('99999901-1111-4111-8111-111111111111'))?.isDeleted == true);
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 6. aggregate 与 ReceivableService 口径一致（d-02）==');
  // ═══════════════════════════════════════════════════════════════
  {
    const svc = ReceivableService();

    // 构造覆盖四种状态的集合：draft / confirmed / settled / 软删
    final records = <WorkRecord>[
      _work('70000001-1111-4111-8111-111111111111', _companyC, 10000,
          status: RecordStatus.confirmed),
      _work('70000002-1111-4111-8111-111111111111', _companyC, 20000,
          status: RecordStatus.settled),
      _work('70000003-1111-4111-8111-111111111111', _companyC, 9999,
          status: RecordStatus.draft), // 草稿：不计入应收（AC-32）
      _work('70000004-1111-4111-8111-111111111111', _companyC, 5000,
          status: RecordStatus.confirmed, deletedAt: _now), // 软删：不计入
      _work('70000005-1111-4111-8111-111111111111', _companyD, 7000,
          status: RecordStatus.confirmed),
    ];
    final payments = <PaymentRecord>[
      _pay('80000001-1111-4111-8111-111111111111', _companyC, 12000),
      _pay('80000002-1111-4111-8111-111111111111', _companyC, 3000, deletedAt: _now), // 软删
      _pay('80000003-1111-4111-8111-111111111111', _companyD, 1000),
    ];

    for (final r in records) {
      await db.upsertWorkRecord(r);
    }
    for (final p in payments) {
      await db.upsertPaymentRecord(p);
    }

    // 公司维度逐一比对
    for (final cid in [_companyC, _companyD]) {
      final agg = await db.aggregate(cid);
      final s = svc.companySummary(
          companyId: cid, records: records, payments: payments);
      check('[$cid] 应收 db==service', agg.receivable == s.receivable,
          'db=${agg.receivable} svc=${s.receivable}');
      check('[$cid] 已收 db==service', agg.received == s.received,
          'db=${agg.received} svc=${s.received}');
      check('[$cid] 剩余 db==service', agg.remaining == s.remaining,
          'db=${agg.remaining} svc=${s.remaining}');
    }

    // 数值断言（防"两边同错"）：C 应收 30000 / 已收 12000 / 剩余 18000
    final aggC = await db.aggregate(_companyC);
    check('公司C 应收 = 30000（草稿与软删均排除）', aggC.receivable == 30000,
        '实际 ${aggC.receivable}');
    check('公司C 已收 = 12000（软删收款排除）', aggC.received == 12000, '实际 ${aggC.received}');
    check('公司C 剩余 = 18000', aggC.remaining == 18000, '实际 ${aggC.remaining}');

    // 全局口径（companyId = null）：与 service 纯函数在全量回读集合上比对
    final allRecords = await db.listWorkRecords(includeDeleted: true);
    final allPayments = await db.listPaymentRecords(includeDeleted: true);
    final aggAll = await db.aggregate(null);
    check('全局应收 db==service（全量回读，含草稿/软删）',
        aggAll.receivable == svc.receivable(allRecords),
        'db=${aggAll.receivable} svc=${svc.receivable(allRecords)}');
    check('全局已收 db==service（全量回读，含软删）',
        aggAll.received == svc.received(allPayments),
        'db=${aggAll.received} svc=${svc.received(allPayments)}');
    check('全局剩余 = 全局应收 − 全局已收',
        aggAll.remaining == aggAll.receivable - aggAll.received);

    // 分组聚合一致性
    final byCompany = await db.aggregateByCompany();
    for (final cid in [_companyC, _companyD]) {
      final row = byCompany.where((e) => e.companyId == cid).toList();
      final s = svc.companySummary(
          companyId: cid, records: records, payments: payments);
      check('[$cid] aggregateByCompany 应收一致',
          row.length == 1 && row.first.receivable == s.receivable,
          'row=$row');
      check('[$cid] aggregateByCompany 已收一致',
          row.length == 1 && row.first.received == s.received, 'row=$row');
      // ── G3 加固（2026-10-16）：此前只比 receivable / received，**从不比 remaining**。
      // 实测：把 `database.dart:377` 的 `remaining: receivable - received` 反成
      // `received - receivable`（符号翻转）后，本脚本仍报 93/0 全绿。
      // 而公司列表页（P06）**每行剩余正是取此字段** → 全表剩余变负号而无人察觉。
      // 补两条：① 结构派生一致性（不信任实现自带的自洽性）；② 与 service 纯函数逐字段一致。
      check('[$cid] aggregateByCompany 剩余 == 应收 − 已收（派生一致，可捕获符号翻转）',
          row.length == 1 &&
              row.first.remaining == row.first.receivable - row.first.received,
          'row=$row');
      check('[$cid] aggregateByCompany 剩余 == service 剩余（逐字段口径一致）',
          row.length == 1 && row.first.remaining == s.remaining, 'row=$row');
    }

    // ── G3 绝对值锚点（防「两边同错」）：剩余必须是可心算的确定值 ──
    // 公司C：应收 30000（10000 confirmed + 20000 settled，草稿 9999 与软删 5000 均排除）
    //        已收 12000（软删的 3000 排除） → 剩余 18000
    // 公司D：应收 7000 / 已收 1000 → 剩余 6000
    final bcC = byCompany.where((e) => e.companyId == _companyC).toList();
    final bcD = byCompany.where((e) => e.companyId == _companyD).toList();
    check('公司C aggregateByCompany 应收 = 30000',
        bcC.length == 1 && bcC.first.receivable == 30000, 'row=$bcC');
    check('公司C aggregateByCompany 已收 = 12000',
        bcC.length == 1 && bcC.first.received == 12000, 'row=$bcC');
    check('公司C aggregateByCompany 剩余 = 18000（P06 公司列表页每行剩余来源）',
        bcC.length == 1 && bcC.first.remaining == 18000, 'row=$bcC');
    check('公司D aggregateByCompany 剩余 = 6000（7000 − 1000）',
        bcD.length == 1 && bcD.first.remaining == 6000, 'row=$bcD');

    // ── G1 / G2 / G7 加固（2026-10-16）：**行读路径**的默认过滤口径 ──
    // 此前 §6 只验了**聚合 SQL** 的过滤；`listWorkRecords` / `listPaymentRecords` 的
    // 默认软删过滤（`database.dart:1262` / `:1288`）与 `listWorkRecords(includeDraft:false)`
    // （`:1263`，即 `calendar_page.dart:93` 在用、AC-P03-04 日历色点口径）**从未被调用**。
    // 实测：三处各自改成 `if (false)` 后仍 93/0 全绿。
    // 夹具（公司C）：工作记录 4 条 = confirmed 10000 / settled 20000 / draft 9999 / 软删 5000
    //               收款记录 2 条 = 12000 / 软删 3000
    final cRowsDefault = await db.listWorkRecords(companyId: _companyC);
    check('软删排除 G1：listWorkRecords 默认不含已软删记录',
        cRowsDefault.every((r) => !r.isDeleted),
        'deletedAt 序列=${cRowsDefault.map((r) => r.deletedAt).toList()}');
    check('软删排除 G1：listWorkRecords 默认 公司C = 3 条（含草稿、排除软删）',
        cRowsDefault.length == 3, '实际 ${cRowsDefault.length}');
    final cRowsAll =
        await db.listWorkRecords(companyId: _companyC, includeDeleted: true);
    check('软删排除 G1：includeDeleted 前后差值 = 1（恰 1 条软删）',
        cRowsAll.length == cRowsDefault.length + 1,
        'default=${cRowsDefault.length} all=${cRowsAll.length}');

    final cPayDefault = await db.listPaymentRecords(companyId: _companyC);
    check('软删排除 G2：listPaymentRecords 默认不含已软删收款',
        cPayDefault.every((p) => !p.isDeleted),
        'deletedAt 序列=${cPayDefault.map((p) => p.deletedAt).toList()}');
    check('软删排除 G2：listPaymentRecords 默认 公司C = 1 条',
        cPayDefault.length == 1, '实际 ${cPayDefault.length}');
    final cPayAll =
        await db.listPaymentRecords(companyId: _companyC, includeDeleted: true);
    check('软删排除 G2：includeDeleted 前后差值 = 1（恰 1 条软删）',
        cPayAll.length == cPayDefault.length + 1,
        'default=${cPayDefault.length} all=${cPayAll.length}');

    final cNoDraft =
        await db.listWorkRecords(companyId: _companyC, includeDraft: false);
    check('AC-32 G7：listWorkRecords(includeDraft:false) 排除草稿（P03 日历色点口径）',
        cNoDraft.every((r) => r.status != RecordStatus.draft),
        '状态序列=${cNoDraft.map((r) => r.status).toList()}');
    check('AC-32 G7：includeDraft:false 公司C = 2 条（confirmed + settled）',
        cNoDraft.length == 2, '实际 ${cNoDraft.length}');
    check('AC-32 G7：includeDraft true/false 差值 = 1（草稿恰 1 条）',
        cRowsDefault.length == cNoDraft.length + 1,
        'true=${cRowsDefault.length} false=${cNoDraft.length}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 7. 语义钉死：holiday_mark OR REPLACE 行为（R2-01）+ company 停用过滤（R2-06）==');
  // ═══════════════════════════════════════════════════════════════
  {
    // ── R2-01：同一 (ledger,date) 用**不同 id** upsert → 静默替换（不抛异常）、行数不变、id 变新值 ──
    final d = DateTime(2026, 12, 25);
    const oldId = 'a0111111-1111-4111-8111-111111111111';
    const newId = 'a0222222-2222-4222-8222-222222222222';
    await db.upsertHolidayMark(_holiday(oldId, d));
    check('R2-01 插入后 (ledger,date) 命中旧 id',
        (await db.getHolidayMarkByDate(_ledgerId, d))?.id == oldId);

    var threw = false;
    try {
      await db.upsertHolidayMark(_holiday(newId, d)); // 同 (ledger,date)、不同 id
    } catch (e) {
      threw = true;
      print('    ⚠️ 换 id upsert 竟抛异常：${e.runtimeType}: $e');
    }
    final rows = await db.listHolidayMarks(ledgerId: _ledgerId);
    final hit = await db.getHolidayMarkByDate(_ledgerId, d);
    check('R2-01 同 (ledger,date) 换 id upsert **不抛异常**（静默替换）', !threw);
    check('R2-01 换 id 后该 (ledger,date) 行数仍为 1', rows.length == 1, '实际 ${rows.length}');
    check('R2-01 换 id 后 (ledger,date) 指向新 id', hit?.id == newId, '实际 ${hit?.id}');
    check('R2-01 旧 id 行已被物理删除（悬空）', (await db.getHolidayMark(oldId)) == null);
    await db.deleteHolidayMark(newId); // 清理

    // ── R2-06：listCompanies 默认排除停用公司；includeDisabled: true 时包含；与 listPricingRules 对称 ──
    const companyE = '77777777-7777-4777-8777-777777777777';
    await db.upsertCompany(_company(companyE, '已停用公司', enabled: false));
    final def = await db.listCompanies(ledgerId: _ledgerId);
    final all = await db.listCompanies(ledgerId: _ledgerId, includeDisabled: true);
    check('R2-06 listCompanies 默认排除停用公司', def.every((c) => c.enabled),
        'enabled 序列=${def.map((c) => c.enabled).toList()}');
    check('R2-06 listCompanies 默认不含停用公司',
        def.where((c) => c.id == companyE).isEmpty);
    check('R2-06 listCompanies(includeDisabled:true) 含停用公司',
        all.any((c) => c.id == companyE));
    check('R2-06 includeDisabled 前后差值 = 1（停用公司恰 1 家）',
        all.length == def.length + 1, 'default=${def.length} all=${all.length}');
    // 与 listPricingRules 对称：停用规则同被默认排除、显式包含
    const ruleF = '88888888-8888-4888-8888-888888888888';
    await db.upsertPricingRule(
        _rule(ruleF, companyId: companyE, enabled: false, name: '停用规则'));
    check('R2-06 listPricingRules 默认排除停用规则（对称）',
        (await db.listPricingRules(companyId: companyE)).isEmpty);
    check('R2-06 listPricingRules(includeDisabled:true) 含停用规则（对称）',
        (await db.listPricingRules(companyId: companyE, includeDisabled: true)).length == 1);

    // ── G6 加固（2026-10-16）：此前 §7 只验了 listPricingRules 的 **enabled** 过滤，
    // 其 **软删** 过滤（`database.dart:557` 的 `if (!includeDeleted) 'deleted_at IS NULL'`）
    // 无任何断言 —— 实测改成 `if (false)` 后仍 93/0 全绿 → 已删规则会串进新建选择器。
    await db.softDeletePricingRule(ruleF, _now);
    check('规则软删排除 G6：listPricingRules(includeDisabled:true) 不含已软删规则',
        (await db.listPricingRules(companyId: companyE, includeDisabled: true)).isEmpty);
    check('规则软删排除 G6：includeDeleted:true 时含已软删规则（差值 = 1）',
        (await db.listPricingRules(
                companyId: companyE, includeDeleted: true, includeDisabled: true))
            .length ==
            1);

    // ── G5 加固（2026-10-16）：同理，listCompanies 的**软删**过滤（`:472`）此前无断言 ──
    await db.softDeleteCompany(companyE, _now); // 清理 + 兼作 G5 夹具
    final afterSoftDel =
        await db.listCompanies(ledgerId: _ledgerId, includeDisabled: true);
    check('公司软删排除 G5：listCompanies(includeDisabled:true) 不含已软删公司',
        afterSoftDel.every((c) => c.id != companyE),
        'ids=${afterSoftDel.map((c) => c.id).toList()}');
    check('公司软删排除 G5：软删前后差值 = 1（停用公司 E 恰 1 家）',
        afterSoftDel.length == all.length - 1,
        'before=${all.length} after=${afterSoftDel.length}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 8. 脏金额硬化：REAL 非整值拒绝静默截断（B3 / R2-04 / G-03）+ 脏行隔离（G-02）==');
  // ═══════════════════════════════════════════════════════════════
  {
    // 绕过模型直写，模拟「外部改库 / 库损坏」：amount 列塞入 REAL 24000.7
    const dirtyId = _dirtyPayId;
    await db.transaction((txn) async {
      await txn.insert('payment_record', {
        'id': dirtyId,
        'company_id': _companyB,
        'pay_date': '2026-09-30',
        'amount': 24000.7, // REAL 非整值：INTEGER 亲和列无法无损转 int → 原样存 REAL
        'method': 'cash',
        'created_at': _now.toIso8601String(),
        'updated_at': _now.toIso8601String(),
      });
    });

    // 行映射路径（单条读）：应抛 FormatException，而非静默截断成 24000
    Object? singleErr;
    try {
      await db.getPaymentRecord(dirtyId);
    } catch (e) {
      singleErr = e;
    }
    check('B3 getPaymentRecord 对 REAL 非整金额抛 FormatException（不截断）',
        singleErr is FormatException,
        singleErr == null ? '（未抛错 → 被静默截断！）' : '实际 ${singleErr.runtimeType}');
    if (singleErr is FormatException) {
      print('    ✓ 抛错消息可定位列名+坏值：$singleErr');
    }

    // 整表读路径（I-9 交互面：硬化后此面略扩）：应同样抛
    Object? listErr;
    try {
      await db.listPaymentRecords();
    } catch (e) {
      listErr = e;
    }
    check('B3 listPaymentRecords 对同脏值抛 FormatException（I-9 交互面）',
        listErr is FormatException, '实际 ${listErr.runtimeType}');

    // ── G-03 硬化（2026-09-30）：聚合路径由「静默按 0 计 / 截断」改为**抛 FormatException** ──
    // （原此处断言「B2 聚合路径不抛错」——G-03 后**反转**为「必须抛错」，属行为升级非弱化。）
    Object? aggErr;
    try {
      await db.aggregate(_companyB);
    } catch (e) {
      aggErr = e;
    }
    check('G-03 aggregate 对 REAL 非整金额抛 FormatException（不再静默截断）',
        aggErr is FormatException,
        aggErr == null ? '（未抛错 → 聚合被静默截断！）' : '实际 ${aggErr.runtimeType}');
    if (aggErr is FormatException) {
      print('    ✓ 聚合抛错消息可定位列名+坏值：$aggErr');
    }

    // 分组聚合同样走 [_asAggregateInt] → 同样抛
    Object? bcErr;
    try {
      await db.aggregateByCompany();
    } catch (e) {
      bcErr = e;
    }
    check('G-03 aggregateByCompany 对同脏值同样抛 FormatException',
        bcErr is FormatException, '实际 ${bcErr.runtimeType}');

    // ── G-02 容错读（脏行隔离）：坏行跳过并收集、不上抛 ──
    final lenient = await db.listPaymentRecordsLenient();
    check('G-02 listPaymentRecordsLenient 不抛错（坏行隔离）',
        lenient.hasSkipped && lenient.skippedCount == 1,
        'rows=${lenient.rows.length} skipped=${lenient.skippedCount}');
    check('G-02 坏行清单含脏值 id 且可定位',
        lenient.skipped.isNotEmpty && lenient.skipped.first.id == dirtyId,
        'skipped=${lenient.skipped}');
    check('G-02 坏行 error 为 FormatException（带列名/坏值）',
        lenient.skipped.isNotEmpty && lenient.skipped.first.error is FormatException);
    // 严格读法**不变**：同一数据下 listPaymentRecords 仍整表抛错（默认契约未被削弱）
    Object? strictErr;
    try {
      await db.listPaymentRecords();
    } catch (e) {
      strictErr = e;
    }
    check('G-02 严格读法默认行为不变（listPaymentRecords 仍抛错）',
        strictErr is FormatException);
    // 没有坏行的表走容错读 → skipped 为空、行数与非容错读一致
    final lenientWork = await db.listWorkRecordsLenient();
    final strictWork = await db.listWorkRecords();
    check('G-02 无坏行时容错读与严格读行数一致且 skipped=0',
        !lenientWork.hasSkipped && lenientWork.rows.length == strictWork.length,
        'lenient=${lenientWork.rows.length} strict=${strictWork.length}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 8b. M-01 聚合类型前置守卫：TEXT/BLOB 被 SUM() 洗成 0.0 ==');
  // ═══════════════════════════════════════════════════════════════
  {
    // 先清掉 §8 遗留的 REAL 非整脏行——守卫是**全局**的（任一行类型坏即拒绝），
    // 不清则本节 4 条用例无法与「REAL 非整」隔离。
    await db.transaction((txn) async {
      await txn.delete('payment_record', where: 'id = ?', whereArgs: [_dirtyPayId]);
    });
    final baseline = (await db.aggregate(_companyB)).received;
    check('M-01 清掉 REAL 脏行后 aggregate 恢复（干净库不被误伤）', baseline == 0,
        '实际 received=$baseline');

    // ── 对照组（防误伤）：库内同时有 int 与 24000.0（无损 REAL）→ 守卫**不得**抛 ──
    const okIntId = 'e0e0e0e0-0000-4000-8000-00000000000c';
    const okRealId = 'e0e0e0e0-0000-4000-8000-00000000000d';
    await db.transaction((txn) async {
      await txn.insert('payment_record', {
        'id': okIntId, 'company_id': _companyB, 'pay_date': '2026-09-30',
        'amount': 24000, 'method': 'cash',
        'created_at': _now.toIso8601String(), 'updated_at': _now.toIso8601String(),
      });
      await txn.insert('payment_record', {
        'id': okRealId, 'company_id': _companyB, 'pay_date': '2026-09-30',
        'amount': 24000.0, // 无损 REAL → INTEGER 亲和列归一为 int（白名单放行）
        'method': 'cash',
        'created_at': _now.toIso8601String(), 'updated_at': _now.toIso8601String(),
      });
    });
    final realType = await db.transaction((txn) => txn.rawQuery(
        'SELECT typeof(amount) AS t FROM payment_record WHERE id = ?', [okRealId]));
    print('    · 24000.0 落库后 typeof=${realType.first['t']}（INTEGER 亲和归一，守卫白名单放行 real/int）');
    Object? okErr;
    ReceivableAggregate? okAgg;
    try {
      okAgg = await db.aggregate(_companyB);
    } catch (e) {
      okErr = e;
    }
    check('M-01 对照组：int + 无损 REAL(24000.0) 不触发守卫（不误伤，received=48000）',
        okErr == null && okAgg?.received == 48000,
        'err=${okErr?.runtimeType} received=${okAgg?.received}');

    // ── 用例①：TEXT 脏值 → aggregate 抛 FormatException（且消息含列名）──
    const txtId = 'e0e0e0e0-0000-4000-8000-00000000000e';
    await db.transaction((txn) async {
      await txn.insert('payment_record', {
        'id': txtId, 'company_id': _companyB, 'pay_date': '2026-09-30',
        'amount': 'abc', // TEXT：SQLite INTEGER 亲和无法把非数值串转数 → 原样存 TEXT
        'method': 'cash',
        'created_at': _now.toIso8601String(), 'updated_at': _now.toIso8601String(),
      });
    });
    Object? txtErr;
    try {
      await db.aggregate(_companyB);
    } catch (e) {
      txtErr = e;
    }
    check('M-01① TEXT 脏值 → aggregate 抛 FormatException（不再静默算 0）',
        txtErr is FormatException, '实际 ${txtErr?.runtimeType}');
    check('M-01① 抛错消息含列名 `payment_record.amount` 与具体 typeof',
        txtErr is FormatException && '$txtErr'.contains('payment_record.amount'),
        '实际 $txtErr');
    print('    ✓ 消息：$txtErr');

    // ── 用例③：同脏值 → aggregateByCompany（分组路径）也抛 ──
    Object? tbcErr;
    try {
      await db.aggregateByCompany();
    } catch (e) {
      tbcErr = e;
    }
    check('M-01③ 同 TEXT 脏值 → aggregateByCompany 抛 FormatException（分组路径已挂守卫）',
        tbcErr is FormatException, '实际 ${tbcErr?.runtimeType}');
    await db.transaction((txn) async {
      await txn.delete('payment_record', where: 'id = ?', whereArgs: [txtId]);
    });

    // ── 用例②：BLOB(X'00') 脏值 → aggregate 抛（用 rawInsert 传 SQL BLOB 字面量）──
    const blobId = 'e0e0e0e0-0000-4000-8000-00000000000f';
    await db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT INTO payment_record '
        '(id, company_id, pay_date, amount, method, created_at, updated_at) '
        "VALUES (?, ?, ?, x'00', 'cash', ?, ?)",
        [blobId, _companyB, '2026-09-30', _now.toIso8601String(),
            _now.toIso8601String()],
      );
    });
    Object? blobErr;
    try {
      await db.aggregate(_companyB);
    } catch (e) {
      blobErr = e;
    }
    check("M-01② BLOB(X'00') 脏值 → aggregate 抛 FormatException",
        blobErr is FormatException, '实际 ${blobErr?.runtimeType}');
    print('    ✓ 消息：$blobErr');

    // 收尾：清掉本节全部插入行 → 库恢复干净、aggregate 恢复
    await db.transaction((txn) async {
      for (final id in [blobId, okIntId, okRealId]) {
        await txn.delete('payment_record', where: 'id = ?', whereArgs: [id]);
      }
    });
    final healed = (await db.aggregate(_companyB)).received;
    check('M-01 收尾：清理脏行后 aggregate 恢复（received=0）', healed == 0,
        '实际 received=$healed');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 8c. 0-A.1：work 侧守卫门禁（Minor-1）+ int64 范围守卫（Minor-4）==');
  // ═══════════════════════════════════════════════════════════════
  {
    // ── Minor-1：`work_record.amount_snapshot` 守卫**门禁** ──
    // 此前 §8b 只有 payment 侧「脏行 → 抛」用例；work 侧守卫虽被每次 aggregate 调用，
    // 但从未有脏行触发过 → 结构上未覆盖（reviewer M4b 变异：停掉 work 侧守卫仍全绿）。
    const okWorkId = 'e0e0e0e0-0000-4000-8000-000000000020';
    const dirtyWorkId = 'e0e0e0e0-0000-4000-8000-000000000021';
    Map<String, Object?> workRow(String id, Object? amountSnapshot) => {
          'id': id,
          'company_id': _companyB,
          'attribution_date': '2026-09-30',
          'mode_snapshot': 'hourly',
          'quantity': 8.0,
          'unit_price_snapshot': 4000,
          'amount_snapshot': amountSnapshot,
          'amount_source': 'auto',
          'status': 'confirmed',
          'created_at': _now.toIso8601String(),
          'updated_at': _now.toIso8601String(),
        };

    // 对照组（防误伤）：干净 work 数据 → work 侧守卫**不**抛
    await db.transaction((txn) async {
      await txn.insert('work_record', workRow(okWorkId, 3600));
    });
    Object? okWorkErr;
    try {
      await db.aggregate(_companyB);
    } catch (e) {
      okWorkErr = e;
    }
    check('Minor-1 对照组：干净 work 数据不触发 work 侧守卫（不误伤）',
        okWorkErr == null, 'err=${okWorkErr?.runtimeType}');

    // 用例①：amount_snapshot='abc'（TEXT）→ aggregate 抛，且消息含列名
    await db.transaction((txn) async {
      await txn.insert('work_record', workRow(dirtyWorkId, 'abc'));
    });
    Object? wTxtErr;
    try {
      await db.aggregate(_companyB);
    } catch (e) {
      wTxtErr = e;
    }
    check('Minor-1① work_record.amount_snapshot=TEXT → aggregate 抛 FormatException（不再静默算 0）',
        wTxtErr is FormatException, '实际 ${wTxtErr?.runtimeType}');
    check('Minor-1① 抛错消息含列名 `work_record.amount_snapshot`',
        wTxtErr is FormatException && '$wTxtErr'.contains('work_record.amount_snapshot'),
        '实际 $wTxtErr');
    print('    ✓ 消息：$wTxtErr');

    // 用例③：同脏值 → aggregateByCompany（分组路径）也抛
    Object? wBcErr;
    try {
      await db.aggregateByCompany();
    } catch (e) {
      wBcErr = e;
    }
    check('Minor-1③ 同脏值 → aggregateByCompany 抛 FormatException（work 守卫已挂分组路径）',
        wBcErr is FormatException, '实际 ${wBcErr?.runtimeType}');

    // 收尾：清掉 work 侧两行
    await db.transaction((txn) async {
      for (final id in [okWorkId, dirtyWorkId]) {
        await txn.delete('work_record', where: 'id = ?', whereArgs: [id]);
      }
    });

    // ── Minor-4：int64 范围守卫（`toInt()` 对 ≥2^63 的整值 double 会静默钳位）──
    const bigPayId = 'e0e0e0e0-0000-4000-8000-000000000022';
    const bigOkId = 'e0e0e0e0-0000-4000-8000-000000000023';
    await db.transaction((txn) async {
      await txn.insert('payment_record', {
        'id': bigPayId, 'company_id': _companyB, 'pay_date': '2026-09-30',
        'amount': 1e20, // 整值 double，但远超 int64 → SQLite 存 REAL，toInt() 会钳位
        'method': 'cash',
        'created_at': _now.toIso8601String(), 'updated_at': _now.toIso8601String(),
      });
    });
    final bigType = await db.transaction((txn) => txn.rawQuery(
        'SELECT typeof(amount) AS t FROM payment_record WHERE id = ?', [bigPayId]));
    print('    · 1e20 落库后 typeof=${bigType.first['t']}（超 int64 → 保留 REAL）');

    // ① 聚合路径：_asAggregateInt 抛（消息区分「超 int64 范围」）
    Object? bigAggErr;
    try {
      await db.aggregate(_companyB);
    } catch (e) {
      bigAggErr = e;
    }
    check('Minor-4① 聚合路径 `1e20` → aggregate 抛 FormatException（不静默钳位）',
        bigAggErr is FormatException, '实际 ${bigAggErr?.runtimeType}');
    check('Minor-4① 消息区分「超 int64 范围」（非「非整/非法」）',
        bigAggErr is FormatException &&
            '$bigAggErr'.contains('int64') &&
            !'$bigAggErr'.contains('非整'),
        '实际 $bigAggErr');
    print('    ✓ 消息：$bigAggErr');

    // ② 行映射路径：_asAmountColumn 抛
    Object? bigRowErr;
    try {
      await db.getPaymentRecord(bigPayId);
    } catch (e) {
      bigRowErr = e;
    }
    check('Minor-4② 行映射路径 `1e20` → getPaymentRecord 抛 FormatException（不静默钳位）',
        bigRowErr is FormatException && '$bigRowErr'.contains('int64'),
        '实际 ${bigRowErr?.runtimeType} / $bigRowErr');

    // 反向对照：int64 内 `48000.0`（归一为 int）→ 放行
    await db.transaction((txn) async {
      await txn.insert('payment_record', {
        'id': bigOkId, 'company_id': _companyB, 'pay_date': '2026-09-30',
        'amount': 48000.0, 'method': 'cash',
        'created_at': _now.toIso8601String(), 'updated_at': _now.toIso8601String(),
      });
      await txn.delete('payment_record', where: 'id = ?', whereArgs: [bigPayId]); // 清掉 1e20 脏行
    });
    Object? bigOkErr;
    ReceivableAggregate? bigOkAgg;
    try {
      bigOkAgg = await db.aggregate(_companyB);
    } catch (e) {
      bigOkErr = e;
    }
    check('Minor-4 反向对照：int64 内 `48000.0` → 放行（不误伤，received=48000）',
        bigOkErr == null && bigOkAgg?.received == 48000,
        'err=${bigOkErr?.runtimeType} received=${bigOkAgg?.received}');

    // 收尾：清干净 → aggregate 恢复
    await db.transaction((txn) async {
      await txn.delete('payment_record', where: 'id = ?', whereArgs: [bigOkId]);
    });
    final healed8c = (await db.aggregate(_companyB)).received;
    check('Minor-1/4 收尾：清理后 aggregate 恢复（received=0）', healed8c == 0,
        '实际 received=$healed8c');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 8d. 脏状态兜底方向（M-03）：未知 status 必须兜底为 draft，不得虚增应收 ==');
  // ═══════════════════════════════════════════════════════════════
  {
    // G4 加固（2026-10-16）：头部 M-03 声称「`_recordStatus` 兜底方向必须安全」
    // （`database.dart:1638-1640`，已从 `confirmed` 纠正为 `draft`），但**此前没有任何
    // 脏状态用例**——实测把兜底改回 `RecordStatus.confirmed` 后仍 93/0 全绿。
    // 风险方向正是 M-03 当初要防的：脏状态行被计入应收 → **剩余工资虚增**。
    // 手法：先用模型写入一条**合法**记录（保证所有 NOT NULL 列齐全），再绕过模型把
    // `status` 列直改成模型不认识的字符串（模拟外部改库 / 版本回退 / 手工修库）。
    const dirtyStatusId = 'b0111111-1111-4111-8111-111111111111';
    const companyH = 'aaaaaaaa-9999-4999-8999-999999999999';
    await db.upsertCompany(_company(companyH, '脏状态测试公司'));
    await db.upsertWorkRecord(_work(dirtyStatusId, companyH, 50000));
    await db.transaction((txn) async {
      await txn.update('work_record', {'status': 'bogus_status_xyz'},
          where: 'id = ?', whereArgs: [dirtyStatusId]);
    });

    // ① 行映射路径（M-03 修复本体的**直接**断言）
    final dirtyRow = await db.getWorkRecord(dirtyStatusId);
    check('M-03 脏状态兜底方向：未知 status → draft（不虚增）',
        dirtyRow?.status == RecordStatus.draft, '实际 ${dirtyRow?.status}');

    // ② **风险路径**：行读后被 `ReceivableService` 按**解析后的枚举**判 status 再累加。
    // 若兜底方向变成 `confirmed`，这行会被计入应收 → **剩余工资虚增**（M-03 当初要防的方向）。
    // —— 实测：把 `:1640` 改回 `RecordStatus.confirmed` 时本条置红。
    const svc8d = ReceivableService();
    final hRows = await db.listWorkRecords(companyId: companyH);
    check('M-03 脏状态行经 ReceivableService 派生不计入应收（兜底 draft → 0）',
        svc8d.receivable(hRows) == 0 && hRows.length == 1,
        'rows=${hRows.length} svc应收=${svc8d.receivable(hRows)}');

    // ③ SQL 聚合路径：`status` 列以**原始字符串**参与 `WHERE`，脏值不在 `('confirmed','settled')`
    //    内 → 天然不计入。此处把该事实固化下来（防日后被改成「先解析再过滤」而引入虚增），
    //    并同时确认「公司H 不出现在 P06 的分组聚合里」。
    final hAgg = await db.aggregate(companyH);
    final hByCompany = await db.aggregateByCompany();
    final hRow = hByCompany.where((e) => e.companyId == companyH).toList();
    check('M-03 脏状态行不计入 SQL 聚合（原始值不在 confirmed/settled；含 P06 分组）',
        hAgg.receivable == 0 && hAgg.remaining == 0 && hRow.isEmpty,
        'agg应收=${hAgg.receivable} byCompany=$hRow');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 9. 快照护栏（I-8 / G-11）：updateWorkRecordMeta / replaceWorkRecordSnapshot ==');
  // ═══════════════════════════════════════════════════════════════
  {
    const gid = 'a0a0a0a0-0000-4000-8000-0000000000a1';
    // 用与已存在记录不同的公司，避免污染前面各节的数值断言
    const companyG = '99999999-9999-4999-8999-999999999999';
    final base = WorkRecord(
      id: gid,
      workDate: DateTime(2026, 9, 10),
      companyId: companyG,
      methodSnapshot: PricingMethod.hourly,
      qtySnapshot: 8,
      qtyUnitSnapshot: '小时',
      startTime: DateTime(2026, 1, 1, 9, 0),
      endTime: DateTime(2026, 1, 1, 17, 0),
      overnight: false,
      rateSnapshot: 4000,
      rateDetailSnapshot: const RateSnapshot(
          overtime: true, overtimeRate: 15, appliedRate: 15),
      amountSnapshot: 48000,
      amountSource: AmountSource.auto,
      note: '原始备注',
      status: RecordStatus.confirmed,
      createdAt: _now,
      updatedAt: _now,
    );
    await db.upsertWorkRecord(base);

    // ── ① updateWorkRecordMeta：只改 Meta；快照四件套**必须原样不变** ──
    await db.updateWorkRecordMeta(
      id: gid,
      note: '改后的备注',
      status: RecordStatus.settled,
      updatedAt: DateTime(2026, 9, 30, 12, 0),
    );
    final afterMeta = await db.getWorkRecord(gid);
    check('G-11 meta：note 已更新', afterMeta?.note == '改后的备注', '实际 ${afterMeta?.note}');
    check('G-11 meta：status 已更新', afterMeta?.status == RecordStatus.settled,
        '实际 ${afterMeta?.status}');
    check(
        'G-11 meta：快照四件套不变（amount/rate/rateDetail/autoRef）',
        afterMeta?.amountSnapshot == base.amountSnapshot &&
            afterMeta?.rateSnapshot == base.rateSnapshot &&
            afterMeta?.autoReferenceAmount == base.autoReferenceAmount &&
            afterMeta?.rateDetailSnapshot.appliedRate ==
                base.rateDetailSnapshot.appliedRate &&
            afterMeta?.rateDetailSnapshot.overtime ==
                base.rateDetailSnapshot.overtime,
        '实际 amount=${afterMeta?.amountSnapshot} rate=${afterMeta?.rateSnapshot}');
    check('G-11 meta：未传的 workDate 保留原值',
        afterMeta?.workDate == base.workDate, '实际 ${afterMeta?.workDate}');
    check('G-11 meta：未传的 quantity/公司 等非 Meta 列不受影响',
        afterMeta?.qtySnapshot == base.qtySnapshot &&
            afterMeta?.companyId == companyG);

    // workDate 单独更新
    final newDate = DateTime(2026, 9, 11);
    await db.updateWorkRecordMeta(
        id: gid, workDate: newDate, updatedAt: DateTime(2026, 9, 30, 13, 0));
    final afterDate = await db.getWorkRecord(gid);
    check('G-11 meta：workDate 可单独更新',
        afterDate?.workDate == newDate, '实际 ${afterDate?.workDate}');
    check('G-11 meta：更新 workDate 时 note 仍保留',
        afterDate?.note == '改后的备注', '实际 ${afterDate?.note}');

    // 不存在的 id → 抛错（存在性校验）
    Object? metaMissingErr;
    try {
      await db.updateWorkRecordMeta(
          id: 'a0a0a0a0-0000-4000-8000-0000000000ff', note: 'x',
          updatedAt: _now);
    } catch (e) {
      metaMissingErr = e;
    }
    check('G-11 meta：不存在的 id 抛 StateError（不静默成功）',
        metaMissingErr is StateError, '实际 ${metaMissingErr.runtimeType}');

    // ── ② replaceWorkRecordSnapshot：显式覆盖快照块；Meta 列**不动** ──
    await db.replaceWorkRecordSnapshot(
      id: gid,
      rateSnapshot: 5000,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10), // overtime 落到 false
      amountSnapshot: 40000,
      amountSource: AmountSource.manual,
      autoReferenceAmount: 48000, // 手工覆盖：保留自动值
      qtySnapshot: 8,
      qtyUnitSnapshot: '小时',
      startTime: DateTime(2026, 1, 1, 9, 0),
      endTime: DateTime(2026, 1, 1, 17, 0),
      overnight: false,
      updatedAt: DateTime(2026, 9, 30, 14, 0),
    );
    final afterSnap = await db.getWorkRecord(gid);
    check('G-11 snapshot：amount/rate/amountSource/autoRef 已覆盖',
        afterSnap?.amountSnapshot == 40000 &&
            afterSnap?.rateSnapshot == 5000 &&
            afterSnap?.amountSource == AmountSource.manual &&
            afterSnap?.autoReferenceAmount == 48000,
        '实际 amount=${afterSnap?.amountSnapshot} rate=${afterSnap?.rateSnapshot} '
        'src=${afterSnap?.amountSource} autoRef=${afterSnap?.autoReferenceAmount}');
    check('G-11 snapshot：倍率明细已覆盖（overtime 由 true→false, applied 15→10）',
        afterSnap?.rateDetailSnapshot.overtime == false &&
            afterSnap?.rateDetailSnapshot.appliedRate == 10,
        '实际 ${afterSnap?.rateDetailSnapshot.overtime}/${afterSnap?.rateDetailSnapshot.appliedRate}');
    check('G-11 snapshot：Meta 列不受影响（note/status/workDate 保持）',
        afterSnap?.note == '改后的备注' &&
            afterSnap?.status == RecordStatus.settled &&
            afterSnap?.workDate == newDate,
        'note=${afterSnap?.note} status=${afterSnap?.status} date=${afterSnap?.workDate}');

    // 可空列传 null → 清空（start/end/autoRef/qtyUnit）；非空列传 null → 保留现值
    await db.replaceWorkRecordSnapshot(
      id: gid,
      rateSnapshot: 6000,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
      amountSnapshot: 48000,
      amountSource: AmountSource.auto,
      autoReferenceAmount: null, // 清空 auto_reference
      qtySnapshot: null, // 非空列 → 保留现值 8
      qtyUnitSnapshot: null, // 可空列 → 清空
      startTime: null, // 可空列 → 清空
      endTime: null, // 可空列 → 清空
      overnight: null, // 非空列 → 保留现值 false
      updatedAt: DateTime(2026, 9, 30, 15, 0),
    );
    final afterClear = await db.getWorkRecord(gid);
    check('G-11 snapshot：可空列传 null → 清空（start/end/qtyUnit/autoRef）',
        afterClear?.startTime == null &&
            afterClear?.endTime == null &&
            afterClear?.qtyUnitSnapshot == null &&
            afterClear?.autoReferenceAmount == null,
        'start=${afterClear?.startTime} end=${afterClear?.endTime} '
        'unit=${afterClear?.qtyUnitSnapshot} autoRef=${afterClear?.autoReferenceAmount}');
    check('G-11 snapshot：非空列传 null → 保留现值（quantity=8 未变）',
        afterClear?.qtySnapshot == 8, '实际 ${afterClear?.qtySnapshot}');

    Object? snapMissingErr;
    try {
      await db.replaceWorkRecordSnapshot(
        id: 'a0a0a0a0-ffff-4fff-8fff-ffffffffffff',
        rateSnapshot: 1,
        rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
        amountSnapshot: 1,
        amountSource: AmountSource.auto,
        updatedAt: _now,
      );
    } catch (e) {
      snapMissingErr = e;
    }
    check('G-11 snapshot：不存在的 id 抛 StateError',
        snapMissingErr is StateError, '实际 ${snapMissingErr.runtimeType}');

    // 事务内用 ...On 变体（原子：meta + snapshot 一次事务内）
    await db.transaction((txn) async {
      await db.updateWorkRecordMetaOn(txn,
          id: gid, note: '事务内改备注', updatedAt: DateTime(2026, 9, 30, 16, 0));
      await db.replaceWorkRecordSnapshotOn(txn,
          id: gid,
          rateSnapshot: 7000,
          rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
          amountSnapshot: 56000,
          amountSource: AmountSource.auto,
          updatedAt: DateTime(2026, 9, 30, 16, 0));
    });
    final afterTxn = await db.getWorkRecord(gid);
    check('G-11 事务内 On 变体生效（note + amount 同事务写入）',
        afterTxn?.note == '事务内改备注' && afterTxn?.amountSnapshot == 56000,
        'note=${afterTxn?.note} amount=${afterTxn?.amountSnapshot}');
  }

  // ═══════════════════════════════════════════════════════════════
  print('== 10. 【反证】事务内调用公开方法会超时（证明 C-01 缺陷真实存在）==');
  // ═══════════════════════════════════════════════════════════════
  {
    Object? caught;
    try {
      await db
          .transaction((txn) async {
        // ❌ 错误用法：事务内调用公开方法（内部再向 _db 申请事务）
        await db.upsertCompany(_company('deadbeef-0000-4000-8000-00000000dead', '死锁探针'));
      })
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      caught = e;
    }
    // 收紧（R2-09 / N-3）：**只认** TimeoutException 或 sqflite **明确的重入/锁定**错误为「死锁」；
    // 其它异常单独报、不计入死锁证据。
    // 注：**主断言（下一条）严格要求 `is TimeoutException`**，此处 `isLockError` **仅为兜底**；
    // 故（N-3）收紧为 `lock` / `reentrant` / `deadlock`，**去掉过宽的裸 `transaction` 子串**
    // （任何含 "transaction" 字样的消息都会被误判）。
    final s = caught?.toString().toLowerCase() ?? '';
    final isTimeout = caught is TimeoutException;
    final isLockError = !isTimeout &&
        caught != null &&
        (s.contains('lock') || s.contains('reentrant') || s.contains('deadlock'));
    check(
        '事务内调用公开方法 → 超时未完成（TimeoutException）',
        isTimeout,
        caught == null
            ? '（竟未抛异常：可能未死锁，需重判）'
            : '实际 ${caught.runtimeType}: $caught');
    check('未出现预期外异常类型（非超时 / 非重入锁定错误）',
        isTimeout || isLockError || caught == null,
        '实际 ${caught.runtimeType}: $caught');
    print('    （对照：同一场景改用 upsertCompanyOn(txn, ...) 已在上文第 2/3/4/6/7/8/9 节正常通过）');
  }

  print('\n结果：$_pass 通过 / $_fail 失败');
  // 第 9 节会留下一个挂起的内部事务，直接退出避免进程悬挂
  exit(_fail > 0 ? 1 : 0);
}
