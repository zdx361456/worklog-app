/// 核心逻辑验证脚本（纯 Dart，无需 Flutter）。
///
/// **本机可复现的运行命令**（与 `verify_db.dart` 同口径，实测 104/0）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// "D:\workspace\software\installed\tools\FlyEnv-Data\app\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev tool\verify_core.dart
/// ```
/// **不要用 `dart run`**：本机 Dart VM 存在进程创建缺陷（`CreateFile failed 231` /
/// `process_win.cc:744`），`dart run` 触发的 native-assets 构建钩子必然失败。
/// `--disable-dart-dev` 直跑 VM 可跳过该钩子（理由详见 `verify_db.dart` 头部）。
///
/// 覆盖：金额引擎整数精度临界算例（R-2）、倍率取最高（Q12）、跨夜（AC-08/AC-11）、
/// 草稿（AC-12）、手工覆盖（Q5）、剩余工资公司维度过滤（R-1）、
/// 导出/导入往返与一致性断言（§6.5）。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/models/types.dart';
import '../lib/models/pricing_rule.dart';
import '../lib/models/ledger.dart';
import '../lib/models/company.dart';
import '../lib/models/work_record.dart';
import '../lib/models/payment_record.dart';
import '../lib/models/holiday_mark.dart';
import '../lib/services/amount_engine.dart';
import '../lib/services/receivable_service.dart';
import '../lib/services/export_service.dart';
import '../lib/services/import_service.dart';
import '../lib/db/database_schema.dart';

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

/// A4 健壮性：执行 [body] 并对「抛异常」做显式捕获。
///
/// 与裸 `check(name, body())` 的区别：body 抛异常时**不再让整脚本崩溃**，
/// 而是记一条失败并继续（保证末尾 `结果：N 通过 / M 失败` 一定被打印，不丢尾）。
bool checkNoThrow(String name, bool Function() body) {
  try {
    final ok = body();
    check(name, ok);
    return ok;
  } catch (e) {
    check(name, false, '抛出异常: ${e.runtimeType}: $e');
    return false;
  }
}

PricingRule rule({
  required PricingMethod method,
  required int baseRate,
  int halfDayRatio = 5,
  int overtimeRate = 15,
  int weekendRate = 10,
  int holidayRate = 10,
  String? unit,
}) =>
    PricingRule(
      id: 'r1',
      companyId: 'c1',
      name: 'test',
      method: method,
      baseRate: baseRate,
      unit: unit,
      halfDayRatio: halfDayRatio,
      overtimeRate: overtimeRate,
      weekendRate: weekendRate,
      holidayRate: holidayRate,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

/// A4 兜底包装：任何**未捕获**异常都不会让脚本「崩溃且不打印结果」。
///
/// 无论 `_run()` 正常还是抛异常，末尾的 `结果：N 通过 / M 失败` 一定被打印；
/// 崩溃会被计入失败（`_fail` 至少 +1），再以非零退出码置红。
void main() {
  try {
    _run();
  } catch (e, st) {
    if (_fail == 0) _fail = 1; // 崩溃即至少一条失败
    print('  ✗ 未捕获异常导致中断: ${e.runtimeType}: $e');
    print(st);
  }
  print('\n结果：$_pass 通过 / $_fail 失败');
  // 用 `exit(1)` 而非 `throw StateError`：后者会在**已打印结果行之后**再吐一段
  // `Unhandled exception ... #0 main` 堆栈，读者容易把「干净置红」误认成「脚本崩了」，
  // 与 A4 想消除的「崩溃混淆」自相矛盾。`exit` 会先冲刷 stdout，结果行必定可见。
  exit(_fail > 0 ? 1 : 0);
}

void _run() {
  const eng = AmountEngine();

  print('== 金额引擎：基础与整数精度 ==');
  // 时价 40 元/时（4000 分），4 小时 = 160 元
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: const AmountInput(manualHours: 4),
    );
    check('时价 4000分 × 4h = 16000分', r.amount == 16000, '实际 ${r.amount}');
  }
  // R-2 临界：300.03 元/时 × 10 分钟 → 5000.5 分，应进位 5001（旧 double 实现会得 5000）
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 30003),
      input: const AmountInput(manualHours: 10 / 60),
    );
    check('R-2 临界 30003分 × 10min = 5001分（半入）', r.amount == 5001, '实际 ${r.amount}');
  }
  // R-2 日价半天临界：300.05 元/天 × 0.3 折算 = 9001.5 分 → 9002
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.daily, baseRate: 30005, halfDayRatio: 3),
      input: const AmountInput(fullDay: false),
    );
    check('R-2 临界 日价30005分 × 0.3 = 9002分', r.amount == 9002, '实际 ${r.amount}');
  }
  // 日价整天
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.daily, baseRate: 30000),
      input: const AmountInput(fullDay: true),
    );
    check('日价整天 300分 = 30000分', r.amount == 30000, '实际 ${r.amount}');
  }
  // 日价半天默认 0.5
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.daily, baseRate: 30000),
      input: const AmountInput(fullDay: false),
    );
    check('日价半天 300分 × 0.5 = 15000分', r.amount == 15000, '实际 ${r.amount}');
  }
  // 计件
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.piece, baseRate: 500, unit: '趟'),
      input: const AmountInput(pieceCount: 12),
    );
    check('计件 5元/趟 × 12 = 6000分', r.amount == 6000, '实际 ${r.amount}');
  }

  print('== 倍率：取最高不叠乘（Q12）==');
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: const AmountInput(manualHours: 4, isOvertime: true, isWeekend: true),
    );
    check('加班1.5 + 周末1.0 → 取 1.5', r.rateDetail.appliedRate == 15, '实际 ${r.rateDetail.appliedRate}');
    check('倍率后单价 = 6000分', r.actualRate == 6000, '实际 ${r.actualRate}');
    check('金额 = 6000 × 4 = 24000分', r.amount == 24000, '实际 ${r.amount}');
  }
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000, holidayRate: 30),
      input: const AmountInput(manualHours: 4, isHoliday: true, isOvertime: true),
    );
    check('节假日3.0 + 加班1.5 → 取 3.0', r.rateDetail.appliedRate == 30, '实际 ${r.rateDetail.appliedRate}');
  }

  print('== 跨夜 / 草稿 / 手工覆盖 ==');
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: AmountInput(
        start: DateTime(2026, 9, 30, 22, 0),
        end: DateTime(2026, 10, 1, 6, 0), // 日期不同也不双计（只比 hour/minute）
        overnight: true,
      ),
    );
    check('跨夜 22:00→06:00 = 8h = 32000分', r.amount == 32000, '实际 ${r.amount}');
  }
  // ── GAP-05：跨夜边界算例补密（原有 1 例 + AC-11 1 例，密度不足）──────────────
  //   引擎口径来自 `amount_engine.dart:204-212`：**只比较 hour/minute**（忽略日期），
  //   `overnight: true` 时 `mins += 24*60`；`mins < 0` → needsOvernightConfirm；
  //   `mins == 0` → `_draft`（AC-12）。下面四条把这三条分支的**边界**各钉一次。
  {
    // ① 跨午夜但两端都不是整点：23:00 → 01:00 = 2h（验证 +1440 后仍按分钟计）
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: AmountInput(
        start: DateTime(2026, 9, 30, 23, 0),
        end: DateTime(2026, 9, 30, 1, 0), // 同日 DateTime！只差时分
        overnight: true,
      ),
    );
    check('GAP-05① 跨夜 23:00→01:00（同日 DateTime）= 2h = 8000分', r.amount == 8000,
        '实际 ${r.amount}');
  }
  {
    // ② 同刻 + 勾跨夜 = 整 24h（1440 分钟）—— 语义直接来自 `mins += 24*60`
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: AmountInput(
        start: DateTime(2026, 9, 30, 8, 0),
        end: DateTime(2026, 9, 30, 8, 0),
        overnight: true,
      ),
    );
    check('GAP-05② 同刻 08:00→08:00 + 跨夜 = 24h = 96000分（不是 0）', r.amount == 96000,
        '实际 ${r.amount}');
  }
  {
    // ③ 同刻 + 不勾跨夜 = 0 → `_draft`（AC-12「0 时长不产生金额」）
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: AmountInput(
        start: DateTime(2026, 9, 30, 8, 0),
        end: DateTime(2026, 9, 30, 8, 0),
        overnight: false,
      ),
    );
    check('GAP-05③ 同刻 08:00→08:00 未跨夜 → isDraft 且 amount == 0（AC-12）',
        r.isDraft && r.amount == 0, 'isDraft=${r.isDraft} amount=${r.amount}');
  }
  {
    // ④ 典型跨夜时段但**漏勾**跨夜 → 负时长 → 必须走「请确认跨夜」而不是算出负数金额
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: AmountInput(
        start: DateTime(2026, 9, 30, 22, 0),
        end: DateTime(2026, 9, 30, 6, 0),
        overnight: false,
      ),
    );
    check('GAP-05④ 22:00→06:00 漏勾跨夜 → needsOvernightConfirm（AC-11），不得出负数金额',
        r.needsOvernightConfirm && r.amount == 0,
        'flag=${r.needsOvernightConfirm} amount=${r.amount}');
  }
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: AmountInput(
        start: DateTime(2026, 9, 30, 12, 0),
        end: DateTime(2026, 9, 30, 8, 0),
        overnight: false,
      ),
    );
    check('AC-11 结束<开始未跨夜 → needsOvernightConfirm', r.needsOvernightConfirm, '实际 ${r.needsOvernightConfirm}');
  }
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: const AmountInput(manualHours: 0),
    );
    check('AC-12 时长为0 → isDraft', r.isDraft, '实际 ${r.isDraft}');
  }
  {
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: const AmountInput(manualHours: 4, manualAmount: 12345),
    );
    check('Q5 手工覆盖 → 金额=12345、来源=manual', r.amount == 12345 && r.source == AmountSource.manual);
    check('Q5 自动参考值 = 16000', r.autoReference == 16000, '实际 ${r.autoReference}');
  }

  print('== 剩余工资：公司维度过滤（R-1）==');
  {
    const svc = ReceivableService();
    final now = DateTime(2026, 9, 30);
    WorkRecord rec(String id, String c, int amt,
            {RecordStatus st = RecordStatus.confirmed, DateTime? deletedAt}) =>
        WorkRecord(
          id: id,
          workDate: now,
          companyId: c,
          methodSnapshot: PricingMethod.hourly,
          qtySnapshot: 1,
          rateSnapshot: amt,
          rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
          amountSnapshot: amt,
          amountSource: AmountSource.auto,
          status: st,
          deletedAt: deletedAt,
          createdAt: now,
          updatedAt: now,
        );
    PaymentRecord pay(String id, String c, int amt, {DateTime? deletedAt}) =>
        PaymentRecord(
          id: id,
          paymentDate: now,
          companyId: c,
          amount: amt,
          deletedAt: deletedAt,
          createdAt: now,
          updatedAt: now,
        );

    final records = [
      rec('w1', 'c1', 10000),
      rec('w2', 'c2', 20000),
      rec('w3', 'c1', 9999, st: RecordStatus.draft), // 草稿不计
    ];
    final payments = [pay('p1', 'c1', 5000)];

    final s1 = svc.companySummary(companyId: 'c1', records: records, payments: payments);
    check('c1 应收 = 10000（草稿排除）', s1.receivable == 10000, '实际 ${s1.receivable}');
    check('c1 已收 = 5000', s1.received == 5000, '实际 ${s1.received}');
    check('c1 剩余 = 5000', s1.remaining == 5000, '实际 ${s1.remaining}');
    final s2 = svc.companySummary(companyId: 'c2', records: records, payments: payments);
    check('c2 剩余 = 20000（不被 c1 污染）', s2.remaining == 20000, '实际 ${s2.remaining}');
    check('全局剩余 = 25000', svc.globalRemaining(records: records, payments: payments) == 25000);

    // A3 软删排除口径（§8 约束#3）：软删的「已确认」记录 / 收款不得计入应收/已收。
    // 原脚本夹具里没有软删记录 → 删掉 receivable_service 里的 `if (isDeleted) continue;`
    // 仍 81/0 全绿（假覆盖）。这里用**差值式**把它钉死：加入软删项后合计必须**不变**。
    final delAt = DateTime(2026, 9, 29);
    final delRecord = rec('w-del', 'c1', 77777, deletedAt: delAt); // 已确认但已软删
    final delPayment = pay('p-del', 'c1', 12345, deletedAt: delAt); // 已软删收款

    final s1WithDeleted = svc.companySummary(
      companyId: 'c1',
      records: [...records, delRecord],
      payments: [...payments, delPayment],
    );
    check('软删记录不计入应收（receivable 不变）',
        s1WithDeleted.receivable == s1.receivable, '实际 ${s1WithDeleted.receivable}');
    check('软删收款不计入已收（received 不变）',
        s1WithDeleted.received == s1.received, '实际 ${s1WithDeleted.received}');
    check('软删记录不计入剩余（剩余不变）',
        s1WithDeleted.remaining == s1.remaining, '实际 ${s1WithDeleted.remaining}');
    // 差值式直击 receivable()/received() 两个分支（不经 companySummary 的 where 过滤）。
    check('receivable() 跳过软删记录',
        svc.receivable([...records, delRecord]) == svc.receivable(records));
    check('received() 跳过软删收款',
        svc.received([...payments, delPayment]) == svc.received(payments));
  }

  print('== 导出 / 导入往返 + 断言（§6.5）==');
  {
    const exporter = ExportService();
    const importer = ImportService();
    final now = DateTime(2026, 9, 30);
    // 全部使用合法 UUID（设计 §3.2：所有实体 id 为全局唯一标识）。
    const idLedger = '11111111-1111-4111-8111-111111111111';
    const idCompany = '22222222-2222-4222-8222-222222222222';
    const idRule = '33333333-3333-4333-8333-333333333333';
    const idWork = '44444444-4444-4444-8444-444444444444';
    const idPay = '55555555-5555-4555-8555-555555555555';
    const idHoliday = '66666666-6666-4666-8666-666666666666';

    final data = BackupData(
      ledger: Ledger(id: idLedger, name: '我的账本', createdAt: now),
      companies: [
        Company(id: idCompany, ledgerId: idLedger, name: '装修队', color: 0xE53935,
            defaultRuleId: idRule, createdAt: now, updatedAt: now),
      ],
      pricingRules: [
        PricingRule(id: idRule, companyId: idCompany, name: '木工',
            method: PricingMethod.hourly, baseRate: 4000, unit: '小时',
            createdAt: now, updatedAt: now),
      ],
      workRecords: [
        WorkRecord(
          id: idWork, workDate: now, companyId: idCompany, pricingRuleId: idRule,
          methodSnapshot: PricingMethod.hourly, qtySnapshot: 4, qtyUnitSnapshot: '小时',
          startTime: DateTime(1970, 1, 1, 8, 0), endTime: DateTime(1970, 1, 1, 12, 0),
          rateSnapshot: 4000, rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
          amountSnapshot: 16000, amountSource: AmountSource.auto,
          currencySnapshot: 'CNY', status: RecordStatus.confirmed,
          createdAt: now, updatedAt: now,
        ),
      ],
      paymentRecords: [
        PaymentRecord(id: idPay, paymentDate: now, companyId: idCompany, amount: 5000,
            method: PaymentMethod.wechat, createdAt: now, updatedAt: now),
      ],
      holidayMarks: [
        HolidayMark(id: idHoliday, ledgerId: idLedger, date: DateTime(2026, 10, 1),
            type: HolidayType.statutory, rate: 30, createdAt: now),
      ],
    );

    final json = exporter.toJson(data, exportedAt: now);
    // A2 结构断言（原写法 `json.contains('worklog-app-backup')` 只查值不查键：
    // 把 json 里的键名 `format` 改成 `fmt` 后该断言仍绿 → 假覆盖）。
    final map = jsonDecode(json) as Map<String, dynamic>;
    check('导出 JSON 顶层含键 format', map.containsKey('format'),
        '顶层键: ${map.keys.toList()}');
    check('导出 JSON format 值 == 期望 tag', map['format'] == kBackupFormat,
        '实际 ${map['format']}');

    final errors = importer.validate(map);
    check('导入校验无硬错误', errors.isEmpty, '错误: $errors');

    final parsed = importer.parse(map);
    check('往返：工作记录金额一致', parsed.workRecords.first.amountSnapshot == 16000);
    check('往返：公司默认规则保留', parsed.companies.first.defaultRuleId == idRule);
    check('往返：节假日类型=法定节假日', parsed.holidayMarks.first.type == HolidayType.statutory);

    check('断言 §6.5：导出合计 == App 合计',
        exporter.assertExportConsistency(
          workRecords: data.workRecords,
          paymentRecords: data.paymentRecords,
          exportedJson: map,
        ));

    // 坏文件应被拒绝：缺表（A4：包 checkNoThrow，实现抛异常时置红而非崩溃丢尾）
    final bad = Map<String, dynamic>.from(map)..remove('payment_records');
    checkNoThrow('缺表 → 拒绝导入', () => importer.validate(bad).isNotEmpty);

    // N-2：值域非法（基础单价 ≤ 0）应被拒
    final badRate = jsonDecode(json) as Map<String, dynamic>;
    (badRate['pricing_rules'] as List)[0]['base_unit_price'] = 0;
    checkNoThrow('值域非法(基础单价=0) → 拒绝导入',
        () => importer.validate(badRate).isNotEmpty);

    // N-3：类型不符不应抛异常，而应转成错误清单
    final badType = jsonDecode(json) as Map<String, dynamic>;
    badType['ledger']['mode'] = 123; // 期望 String，给了 int
    var threw = false;
    try {
      importer.validate(badType);
    } catch (_) {
      threw = true;
    }
    check('N-3 类型不符不抛异常（返回错误清单）', !threw);
    // A4：此处原为裸 `check(..., importer.validate(badType).isNotEmpty)`，
    // 实现若抛异常会让整脚本崩溃 exit=255、连末尾结果行都打不出（丢尾）。
    checkNoThrow('N-3 类型不符被报告为错误',
        () => importer.validate(badType).isNotEmpty);

    // P-1：standard_hours 类型不符须被 validate 拦下（否则 parse 的 as num? 会抛异常）
    final badSh = jsonDecode(json) as Map<String, dynamic>;
    (badSh['pricing_rules'] as List)[0]['standard_hours'] = 'abc';
    var threwSh = false;
    try {
      importer.validate(badSh);
    } catch (_) {
      threwSh = true;
    }
    check('P-1 standard_hours 类型不符不抛异常', !threwSh);
    checkNoThrow('P-1 standard_hours 类型不符被报告',
        () => importer.validate(badSh).isNotEmpty);
  }

  print('== 非法输入语义（N-9）==');
  {
    const eng = AmountEngine();
    final r = eng.compute(
      rule: rule(method: PricingMethod.hourly, baseRate: 4000),
      input: const AmountInput(manualHours: -2),
    );
    check('手填负数时长 → isInvalidInput', r.isInvalidInput, '实际 ${r.isInvalidInput}');
    check('手填负数时长 → 非跨夜确认', !r.needsOvernightConfirm);
  }
  {
    const eng = AmountEngine();
    final r = eng.compute(
      rule: rule(method: PricingMethod.daily, baseRate: 30000, halfDayRatio: 0),
      input: const AmountInput(fullDay: false),
    );
    check('N-8 半天折算比=0 → isInvalidInput', r.isInvalidInput, '实际 ${r.isInvalidInput}');
  }

  print('== 导入必填字段覆盖（防同类缺陷回归）==');
  {
    const exporter = ExportService();
    const importer = ImportService();
    final now = DateTime(2026, 9, 30);
    const L = '11111111-1111-4111-8111-111111111111';
    const C = '22222222-2222-4222-8222-222222222222';
    const R = '33333333-3333-4333-8333-333333333333';
    const W = '44444444-4444-4444-8444-444444444444';
    const P = '55555555-5555-4555-8555-555555555555';
    const H = '66666666-6666-4666-8666-666666666666';

    final base = exporter.toJson(BackupData(
      ledger: Ledger(id: L, name: '账本', createdAt: now),
      companies: [
        Company(id: C, ledgerId: L, name: '公司', color: 0x112233, createdAt: now, updatedAt: now),
      ],
      pricingRules: [
        PricingRule(id: R, companyId: C, name: '规则', method: PricingMethod.hourly,
            baseRate: 1000, createdAt: now, updatedAt: now),
      ],
      workRecords: [
        WorkRecord(id: W, workDate: now, companyId: C, methodSnapshot: PricingMethod.hourly,
            qtySnapshot: 1, rateSnapshot: 1000,
            rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
            amountSnapshot: 1000, amountSource: AmountSource.auto,
            createdAt: now, updatedAt: now),
      ],
      paymentRecords: [
        PaymentRecord(id: P, paymentDate: now, companyId: C, amount: 100, createdAt: now, updatedAt: now),
      ],
      holidayMarks: [
        HolidayMark(id: H, ledgerId: L, date: now, type: HolidayType.statutory, rate: 30, createdAt: now),
      ],
    ));

    final cases = <String, void Function(Map<String, dynamic>)>{
      'ledger.id 类型错': (m) => m['ledger']['id'] = 123,
      'ledger.nickname 缺失': (m) => (m['ledger'] as Map).remove('nickname'),
      'ledger.currency 缺失': (m) => (m['ledger'] as Map).remove('currency'),
      'ledger.mode 类型错': (m) => m['ledger']['mode'] = 1,
      'company.id 类型错': (m) => (m['companies'] as List)[0]['id'] = 1,
      'company.ledger_id 缺失': (m) => (m['companies'] as List)[0].remove('ledger_id'),
      'company.name 缺失': (m) => (m['companies'] as List)[0].remove('name'),
      'rule.id 类型错': (m) => (m['pricing_rules'] as List)[0]['id'] = 1,
      'rule.company_id 缺失': (m) => (m['pricing_rules'] as List)[0].remove('company_id'),
      'rule.name 缺失': (m) => (m['pricing_rules'] as List)[0].remove('name'),
      'rule.pricing_mode 非法': (m) => (m['pricing_rules'] as List)[0]['pricing_mode'] = '???',
      'rule.base_unit_price 类型错': (m) => (m['pricing_rules'] as List)[0]['base_unit_price'] = 'x',
      'rule.standard_hours 类型错': (m) => (m['pricing_rules'] as List)[0]['standard_hours'] = 'x',
      'rule.half_day_ratio 越界': (m) => (m['pricing_rules'] as List)[0]['half_day_ratio'] = 99,
      'rule.overtime_rate 越界': (m) => (m['pricing_rules'] as List)[0]['overtime_rate'] = 1,
      'record.id 类型错': (m) => (m['work_records'] as List)[0]['id'] = 1,
      'record.company_id 缺失': (m) => (m['work_records'] as List)[0].remove('company_id'),
      'record.quantity 类型错': (m) => (m['work_records'] as List)[0]['quantity'] = 'x',
      'record.attribution_date 缺失': (m) => (m['work_records'] as List)[0].remove('attribution_date'),
      'record.mode_snapshot 非法': (m) => (m['work_records'] as List)[0]['mode_snapshot'] = '???',
      'record.unit_price_snapshot 类型错': (m) => (m['work_records'] as List)[0]['unit_price_snapshot'] = 'x',
      'record.amount_snapshot 类型错': (m) => (m['work_records'] as List)[0]['amount_snapshot'] = 'x',
      'record.amount_source 非法': (m) => (m['work_records'] as List)[0]['amount_source'] = '???',
      'record.status 非法': (m) => (m['work_records'] as List)[0]['status'] = '???',
      'payment.id 类型错': (m) => (m['payment_records'] as List)[0]['id'] = 1,
      'payment.company_id 缺失': (m) => (m['payment_records'] as List)[0].remove('company_id'),
      'payment.amount 类型错': (m) => (m['payment_records'] as List)[0]['amount'] = 'x',
      'payment.amount ≤0': (m) => (m['payment_records'] as List)[0]['amount'] = 0,
      'payment.pay_date 缺失': (m) => (m['payment_records'] as List)[0].remove('pay_date'),
      'payment.method 非法': (m) => (m['payment_records'] as List)[0]['method'] = '???',
      'holiday.id 类型错': (m) => (m['holiday_marks'] as List)[0]['id'] = 1,
      'holiday.ledger_id 缺失': (m) => (m['holiday_marks'] as List)[0].remove('ledger_id'),
      'holiday.date 缺失': (m) => (m['holiday_marks'] as List)[0].remove('date'),
      'holiday.type 非法': (m) => (m['holiday_marks'] as List)[0]['type'] = '???',
      'holiday.rate 类型错': (m) => (m['holiday_marks'] as List)[0]['rate'] = 'x',
    };

    var allCaught = true;
    cases.forEach((label, mutate) {
      final m = jsonDecode(base) as Map<String, dynamic>;
      mutate(m);
      var threw = false;
      var errs = <String>[];
      try {
        errs = importer.validate(m);
      } catch (_) {
        threw = true;
      }
      final ok = !threw && errs.isNotEmpty;
      if (!ok) allCaught = false;
      check('$label → 报错不抛异常', ok, 'threw=$threw errs=$errs');
    });
    check('必填字段覆盖：全部被拦下（无漏网）', allCaught);
  }

  print('== DB Schema ==');
  {
    check('六张建表语句', kCreateTableStatements.length == 6);

    // A1 加固：原写法 `s.contains('CREATE TABLE IF NOT EXISTS $t')` 是**子串**匹配，
    // 两处逃逸已被实测：
    //   ① 把 `work_record (` 改成 `work_records (` → 子串仍命中 → 仍 81/0；
    //   ② 删掉 `work_record` 的 `amount_snapshot` 整列 → 脚本完全不校验列 → 仍 81/0。
    // 修法：① 表名后强制词边界（紧跟 `(`）；② 每表断言关键列存在（列名按行首词边界匹配）。
    String? createStmtOf(String t) {
      final re = RegExp(
          'CREATE TABLE IF NOT EXISTS\\s+${RegExp.escape(t)}\\s*\\(');
      for (final s in kCreateTableStatements) {
        if (re.hasMatch(s)) return s;
      }
      return null;
    }

    bool hasColumn(String stmt, String col) =>
        RegExp('^\\s*${RegExp.escape(col)}\\s', multiLine: true).hasMatch(stmt);

    // 每表 1~3 个关键列（含审计列与口径金额列）。
    const keyColumns = <String, List<String>>{
      'ledger': ['id', 'mode'],
      'company': ['id', 'ledger_id', 'tag_color'],
      'pricing_rule': ['id', 'base_rate'],
      'work_record': ['id', 'attribution_date', 'unit_price_snapshot', 'amount_snapshot'],
      'payment_record': ['id', 'pay_date', 'amount'],
      'holiday_mark': ['id', 'ledger_id', 'rate'],
    };

    keyColumns.forEach((t, cols) {
      final stmt = createStmtOf(t);
      check('建表含 $t（词边界）', stmt != null,
          stmt == null ? '未找到 CREATE TABLE IF NOT EXISTS $t (' : null);
      for (final c in cols) {
        check('  $t 含列 $c', stmt != null && hasColumn(stmt, c));
      }
    });

    check('节假日唯一约束 (ledger_id, date)',
        kCreateTableStatements.any((s) => s.contains('UNIQUE (ledger_id, date)')));
    check('含归属日索引', kCreateIndexStatements
        .any((s) => s.contains('idx_work_record_attribution_date')));
    check('数据库版本 = 1', kDbVersion == 1);
  }
}
