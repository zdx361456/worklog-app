/// 金额引擎（基础版）
/// 对应 03 §4 金额引擎规则。
///
/// 输出为「快照五件套」计算结果，供落库固化（改价不回改历史）。
///
/// 精度纪律（03 §4.6，**全整数运算，禁用浮点中间值**）：
///  - 金额为整数「分」，倍率为整数「×10」。
///  - 数量以整数对 (分子, 分母) 表示：时价 = 分钟/60、日价 = 1/1 或 halfDayRatio/10、
///    计件 = 件数×100/100。金额 = roundDiv(实际单价 × 分子, 分母)。
///  - 唯一舍入规则：四舍五入到分（roundDiv，半入）。
library;

import '../models/types.dart';
import '../models/pricing_rule.dart';
import 'validators.dart';

/// 金额引擎的输入：一次记工需要提供的一切原始参数。
class AmountInput {
  /// 手工覆盖金额（分）；非空则跳过自动计算（Q5）。
  final int? manualAmount;

  /// 手填时长（小时）；时价优先于起止时间推算。
  final double? manualHours;

  /// 起止时间。**契约：日期部分必须一致，仅时间部分有意义**；
  /// 跨夜靠 overnight 显式标记（AC-08），引擎只比较 hour/minute。
  final DateTime? start;
  final DateTime? end;

  /// 跨夜标记。
  final bool overnight;

  /// 日价：是否整天（false = 半天）。
  final bool fullDay;

  /// 计件：件数。
  final double? pieceCount;

  /// 是否命中加班（由调用方结合标准工时判定）。
  final bool isOvertime;

  /// 日期上下文：是否周末 / 是否节假日（倍率取最高档，Q12）。
  final bool isWeekend;
  final bool isHoliday;

  const AmountInput({
    this.manualAmount,
    this.manualHours,
    this.start,
    this.end,
    this.overnight = false,
    this.fullDay = true,
    this.pieceCount,
    this.isOvertime = false,
    this.isWeekend = false,
    this.isHoliday = false,
  });
}

/// 金额引擎计算结果（快照五件套 + 辅助信息）。
class AmountResult {
  final double qty; // 数量快照（物理量，仅展示用）
  final String? qtyUnit;
  final int actualRate; // 实际单价快照（分）
  final RateSnapshot rateDetail; // 倍率明细快照
  final int amount; // 金额快照（分）
  final AmountSource source; // 自动/手工
  final int? autoReference; // 手工覆盖时的自动值（分）

  /// 时价/计件数量为 0 → 草稿，不计入应收（AC-12）。
  final bool isDraft;

  /// 结束 < 开始且未开跨夜 → 需提示"是否跨夜？"（AC-11），不静默算负值。
  final bool needsOvernightConfirm;

  /// 输入非法（如手填负数时长、半天折算比配置非法）→ 应提示校验错误。
  final bool isInvalidInput;

  const AmountResult({
    required this.qty,
    this.qtyUnit,
    required this.actualRate,
    required this.rateDetail,
    required this.amount,
    required this.source,
    this.autoReference,
    this.isDraft = false,
    this.needsOvernightConfirm = false,
    this.isInvalidInput = false,
  });
}

/// 金额引擎：按 03 §4.1 伪代码实现（全整数运算）。
class AmountEngine {
  const AmountEngine();

  /// 计算金额。返回快照五件套。
  AmountResult compute({
    required PricingRule rule,
    required AmountInput input,
  }) {
    // ── 1. 定数量（分子/分母 整数对）──
    // 注意：不使用 num 作变量名（会遮蔽 Dart 内置类型 num）。
    var qNum = 0; // 数量分子
    var qDen = 1; // 数量分母
    var qtyView = 0.0; // 数量物理量，仅展示

    switch (rule.method) {
      case PricingMethod.hourly:
        if (input.manualHours != null) {
          final minutes = (input.manualHours! * 60).round();
          if (minutes < 0) return _invalid(rule); // 手填负数时长 → 非法输入
          if (minutes == 0) return _draft(rule); // AC-12
          qNum = minutes;
          qDen = 60;
          qtyView = minutes / 60.0;
        } else {
          final minutes = _durationMinutes(input);
          if (minutes < 0) {
            // AC-11：结束<开始且未跨夜 → 提示是否跨夜，不静默算负数。
            return _pendingOvernight(rule);
          }
          if (minutes == 0) return _draft(rule); // AC-12
          qNum = minutes;
          qDen = 60;
          qtyView = minutes / 60.0;
        }
        break;

      case PricingMethod.daily:
        // AC-04/AC-05：整天 = 1，半天 = 折算比（halfDayRatio/10）。
        if (input.fullDay) {
          qNum = 1;
          qDen = 1;
          qtyView = 1;
        } else {
          // 折算比配置非法（≤0）→ 非法输入，不静默得 0 金额（N-8）。
          if (!Validators.validHalfDayRatio(rule.halfDayRatio)) {
            return _invalid(rule);
          }
          qNum = rule.halfDayRatio;
          qDen = 10;
          qtyView = rule.halfDayRatio / 10;
        }
        break;

      case PricingMethod.piece:
        final pc = input.pieceCount ?? 0;
        if (pc < 0) return _invalid(rule); // 负数件数 → 非法输入
        if (pc == 0) return _draft(rule); // AC-06 / AC-12
        qNum = (pc * 100).round();
        qDen = 100;
        qtyView = pc;
        break;
    }

    // ── 2. 定倍率（当日取最高档，不叠乘；Q12）──
    final hits = <int>[];
    if (input.isOvertime) hits.add(rule.overtimeRate);
    if (input.isWeekend) hits.add(rule.weekendRate);
    if (input.isHoliday) hits.add(rule.holidayRate);
    final appliedRate = hits.isEmpty ? 10 : hits.reduce((a, b) => a > b ? a : b);

    final rateDetail = RateSnapshot(
      overtime: input.isOvertime,
      overtimeRate: rule.overtimeRate,
      weekend: input.isWeekend,
      weekendRate: rule.weekendRate,
      holiday: input.isHoliday,
      holidayRate: rule.holidayRate,
      appliedRate: appliedRate,
    );

    // ── 3. 实际单价与主金额（全整数，唯一舍入规则）──
    // 实际单价 = 基础单价(分) × 倍率(×10) ÷ 10
    final actualRate = _roundDiv(rule.baseRate * appliedRate, 10);
    // 主金额 = 实际单价(分) × (分子/分母)
    final mainAmount = _roundDiv(actualRate * qNum, qDen);

    // ── 4. 手工覆盖（外层，Q5）──
    if (input.manualAmount != null) {
      return AmountResult(
        qty: qtyView,
        qtyUnit: rule.unit,
        actualRate: actualRate,
        rateDetail: rateDetail,
        amount: input.manualAmount!,
        source: AmountSource.manual,
        autoReference: mainAmount,
      );
    }

    return AmountResult(
      qty: qtyView,
      qtyUnit: rule.unit,
      actualRate: actualRate,
      rateDetail: rateDetail,
      amount: mainAmount,
      source: AmountSource.auto,
    );
  }

  /// 起止时间推时长（分钟整数，半入到分钟）。跨夜 +24h（AC-08）。
  /// 只比较 hour/minute（忽略日期部分），避免"跨天 DateTime + overnight"双计 24h。
  /// 返回负值表示 结束<开始 且未开跨夜（AC-11）。
  int _durationMinutes(AmountInput input) {
    if (input.start == null || input.end == null) return 0;
    final startMin = input.start!.hour * 60 + input.start!.minute;
    final endMin = input.end!.hour * 60 + input.end!.minute;
    var mins = endMin - startMin;
    if (input.overnight) mins += 24 * 60;
    return mins;
  }

  AmountResult _draft(PricingRule rule) => AmountResult(
        qty: 0,
        qtyUnit: rule.unit,
        actualRate: 0,
        rateDetail: const RateSnapshot(appliedRate: 10),
        amount: 0,
        source: AmountSource.auto,
        isDraft: true,
      );

  AmountResult _pendingOvernight(PricingRule rule) => AmountResult(
        qty: 0,
        qtyUnit: rule.unit,
        actualRate: 0,
        rateDetail: const RateSnapshot(appliedRate: 10),
        amount: 0,
        source: AmountSource.auto,
        needsOvernightConfirm: true,
      );

  AmountResult _invalid(PricingRule rule) => AmountResult(
        qty: 0,
        qtyUnit: rule.unit,
        actualRate: 0,
        rateDetail: const RateSnapshot(appliedRate: 10),
        amount: 0,
        source: AmountSource.auto,
        isInvalidInput: true,
      );
}

/// 唯一舍入规则（03 §4.6）：四舍五入到整数（半入），用于分。
/// 显式校验前置条件（不依赖 assert——Release 构建会剥离 assert）。
int _roundDiv(int numerator, int denominator) {
  if (numerator < 0 || denominator <= 0) {
    throw ArgumentError('金额计算非法前置条件：分子=$numerator 分母=$denominator');
  }
  return (numerator + denominator ~/ 2) ~/ denominator;
}
