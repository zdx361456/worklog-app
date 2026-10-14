/// 核心逻辑验证脚本（纯 Dart，无需 Flutter）。
/// 运行：在 app/ 目录下执行 `dart run tool/verify_core.dart`
/// （需 Dart SDK；版本与安装方式见 docs/06-技术选型对比.md）。
///
/// 覆盖：金额引擎整数精度临界算例（R-2）、倍率取最高（Q12）、跨夜（AC-08/AC-11）、
/// 草稿（AC-12）、手工覆盖（Q5）、剩余工资公司维度过滤（R-1）、
/// 导出/导入往返与一致性断言（§6.5）。
library;

import 'dart:convert';

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

void main() {
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
    WorkRecord rec(String id, String c, int amt, {RecordStatus st = RecordStatus.confirmed}) =>
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
          createdAt: now,
          updatedAt: now,
        );
    PaymentRecord pay(String id, String c, int amt) => PaymentRecord(
          id: id,
          paymentDate: now,
          companyId: c,
          amount: amt,
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
    check('导出 JSON 含 format', json.contains('worklog-app-backup'));
    final map = jsonDecode(json) as Map<String, dynamic>;

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

    // 坏文件应被拒绝：缺表
    final bad = Map<String, dynamic>.from(map)..remove('payment_records');
    check('缺表 → 拒绝导入', importer.validate(bad).isNotEmpty);

    // N-2：值域非法（基础单价 ≤ 0）应被拒
    final badRate = jsonDecode(json) as Map<String, dynamic>;
    (badRate['pricing_rules'] as List)[0]['base_unit_price'] = 0;
    check('值域非法(基础单价=0) → 拒绝导入', importer.validate(badRate).isNotEmpty);

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
    check('N-3 类型不符被报告为错误', importer.validate(badType).isNotEmpty);

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
    check('P-1 standard_hours 类型不符被报告', importer.validate(badSh).isNotEmpty);
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
    for (final t in ['ledger', 'company', 'pricing_rule', 'work_record',
        'payment_record', 'holiday_mark']) {
      check('建表含 $t', kCreateTableStatements.any((s) => s.contains('CREATE TABLE IF NOT EXISTS $t')));
    }
    check('节假日唯一约束 (ledger_id, date)',
        kCreateTableStatements.any((s) => s.contains('UNIQUE (ledger_id, date)')));
    check('含归属日索引', kCreateIndexStatements
        .any((s) => s.contains('idx_work_record_attribution_date')));
    check('数据库版本 = 1', kDbVersion == 1);
  }

  print('\n结果：$_pass 通过 / $_fail 失败');
  if (_fail > 0) {
    throw StateError('存在 $_fail 项失败');
  }
}
