/// 账本 Ledger（基础版单账本）
/// 对应 03 §2.1
library;

import 'types.dart';

class Ledger {
  final String id;
  final String name; // 昵称，默认"我的账本"
  final String currency; // 默认 CNY，Q7 预留
  final LedgerMode mode; // 基础版恒为 local
  final DateTime createdAt;

  const Ledger({
    required this.id,
    required this.name,
    this.currency = 'CNY',
    this.mode = LedgerMode.local,
    required this.createdAt,
  });
}
