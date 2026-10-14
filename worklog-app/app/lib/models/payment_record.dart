/// 收款记录 PaymentRecord（基础版：无冲抵周期，按公司累计）
/// 对应 03 §2.5
///
/// 金额纪律（03 §4.6）：amount 为整数「分」。
library;

import 'types.dart';

class PaymentRecord {
  final String id;
  final DateTime paymentDate;
  final String companyId;
  final int amount; // 金额（分）
  final PaymentMethod? method;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  const PaymentRecord({
    required this.id,
    required this.paymentDate,
    required this.companyId,
    required this.amount,
    this.method,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;
}
