/// 剩余工资计算服务（基础版唯一口径）
/// 对应 03 §5.1：剩余 = Σ 已确认/已结算记录金额 − Σ 收款金额。
///
/// 设计底线 1/3：剩余为派生值，不落库；四处显示共用本服务同一查询函数
/// （同过滤器、同金额字段），保证显示一致性（AC-33）。
///
/// 口径纪律：草稿不计入应收（AC-32）；软删记录/收款不计入（§8 约束#3）。
library;

import '../models/work_record.dart';
import '../models/payment_record.dart';

/// 某公司维度的应收 / 已收 / 剩余汇总（分）。
class ReceivableSummary {
  final String companyId;
  final int receivable; // 应收（分）
  final int received; // 已收（分）
  final int remaining; // 剩余（分）= 应收 − 已收

  const ReceivableSummary({
    required this.companyId,
    required this.receivable,
    required this.received,
    required this.remaining,
  });
}

/// 剩余工资计算服务（纯函数，无状态，便于单测与四处复用）。
class ReceivableService {
  const ReceivableService();

  /// 计算单公司应收 / 已收 / 剩余。**内部按 companyId 过滤**，调用方可传全量集合。
  ReceivableSummary companySummary({
    required String companyId,
    required Iterable<WorkRecord> records,
    required Iterable<PaymentRecord> payments,
  }) {
    final receivable = this.receivable(
      records.where((r) => r.companyId == companyId),
    );
    final received = this.received(
      payments.where((p) => p.companyId == companyId),
    );
    return ReceivableSummary(
      companyId: companyId,
      receivable: receivable,
      received: received,
      remaining: receivable - received,
    );
  }

  /// 全局剩余 = Σ 各公司剩余（基础版口径）。
  int globalRemaining({
    required Iterable<WorkRecord> records,
    required Iterable<PaymentRecord> payments,
  }) {
    return receivable(records) - received(payments);
  }

  /// 应收：状态 ∈ {已确认, 已结算} 且未软删的记录金额之和（分）。
  int receivable(Iterable<WorkRecord> records) {
    var sum = 0;
    for (final r in records) {
      if (r.isDeleted) continue;
      if (!r.countsTowardReceivable) continue;
      sum += r.amountSnapshot;
    }
    return sum;
  }

  /// 已收：未软删的收款金额之和（分）。
  int received(Iterable<PaymentRecord> payments) {
    var sum = 0;
    for (final p in payments) {
      if (p.isDeleted) continue;
      sum += p.amount;
    }
    return sum;
  }
}
