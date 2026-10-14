/// 计价规则 PricingRule（基础版：无提成/固定扣款，随二期）
/// 对应 03 §2.3
///
/// 金额/倍率纪律（03 §4.6）：
///  - baseRate 为整数「分」（例：4000 = 40.00 元/小时）。
///  - overtimeRate / weekendRate / holidayRate 为整数「×10」（15 = 1.5 倍）。
///  - halfDayRatio 为整数「×10」（5 = 0.5），范围 1~9。
library;

import 'types.dart';

class PricingRule {
  final String id;
  final String companyId;
  final String name; // = 工序/岗位名，如"砌墙""司机趟次"
  final PricingMethod method;
  final int baseRate; // 基础单价（分/小时、分/天、分/件）
  final String? unit; // 小时/天/件/㎡/趟（计件必填）
  final double? standardHours; // 判定加班的阈值（小时，物理量）
  final int halfDayRatio; // 半天折算比（×10），默认 5 = 0.5
  final int overtimeRate; // 默认 15 = 1.5 倍
  final int weekendRate; // 默认 10 = 1.0 倍
  final int holidayRate; // 默认 10 = 1.0 倍
  final DateTime? effectiveDate; // 仅提示，不改历史
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  const PricingRule({
    required this.id,
    required this.companyId,
    required this.name,
    required this.method,
    required this.baseRate,
    this.unit,
    this.standardHours,
    this.halfDayRatio = 5,
    this.overtimeRate = 15,
    this.weekendRate = 10,
    this.holidayRate = 10,
    this.effectiveDate,
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;
}
