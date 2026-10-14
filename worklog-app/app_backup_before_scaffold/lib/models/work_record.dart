/// 工作记录 WorkRecord（计薪单元，快照五件套）
/// 对应 03 §2.4
/// 核心纪律：金额所需一切参数落库即固化，改价不回改历史。
///
/// 金额纪律（03 §4.6）：rateSnapshot 为整数「分」、amountSnapshot/autoReferenceAmount
/// 为整数「分」；倍率明细快照见 RateSnapshot（整数「×10」）。
///
/// 弱引用说明：pricingRuleId 设计 §2.4 标"必填"，但按 §3.3 弱引用语义，
/// 记录金额完全由快照固化、不依赖规则存在，故实现层允许为空（溯源降级，
/// 不因规则被删/停用而算不出金额）。已在实现台账登记为偏离项。
library;

import 'types.dart';

class WorkRecord {
  final String id;
  final DateTime workDate; // 归属日（跨夜默认归开始日，Q6）
  final String companyId;
  final String? pricingRuleId; // 弱引用，仅溯源/分组，不参与重算
  final PricingMethod methodSnapshot; // 计价方式快照
  final double qtySnapshot; // 数量快照（时长/天数/件数，物理量）
  final String? qtyUnitSnapshot; // 数量单位快照（计件的"趟/㎡"）
  final DateTime? startTime; // 起止时间，可选（仅时间部分有意义）
  final DateTime? endTime;
  final bool overnight; // 跨夜标记
  final int rateSnapshot; // 实际单价快照（分，倍率已展开）
  final RateSnapshot rateDetailSnapshot; // 倍率明细快照
  final int amountSnapshot; // 计入应收的最终金额（分）
  final AmountSource amountSource; // 自动/手工
  final int? autoReferenceAmount; // 手工覆盖时保留的自动值（分，Q5）
  final String? currencySnapshot; // 币种快照，继承账本（03 §2.4）
  final String? note;
  final RecordStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  const WorkRecord({
    required this.id,
    required this.workDate,
    required this.companyId,
    this.pricingRuleId,
    required this.methodSnapshot,
    required this.qtySnapshot,
    this.qtyUnitSnapshot,
    this.startTime,
    this.endTime,
    this.overnight = false,
    required this.rateSnapshot,
    required this.rateDetailSnapshot,
    required this.amountSnapshot,
    required this.amountSource,
    this.autoReferenceAmount,
    this.currencySnapshot,
    this.note,
    this.status = RecordStatus.confirmed,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  /// 是否计入应收：草稿不计入（AC-32）
  bool get countsTowardReceivable => status != RecordStatus.draft;
}
