/// 节假日标记 HolidayMark（基础版 P1·B10，账本级跨公司共享）
/// 对应 03 §2.6
///
/// 倍率纪律（03 §4.6）：rate 为整数「×10」（30 = 3.0 倍）。
library;

import 'types.dart';

class HolidayMark {
  final String id;
  final String ledgerId;
  final DateTime date;
  final HolidayType type;
  final int rate; // 倍率（×10）
  final bool manual; // 来源：用户手动(MVP) / 系统日历(二期)
  final DateTime createdAt;

  const HolidayMark({
    required this.id,
    required this.ledgerId,
    required this.date,
    required this.type,
    required this.rate,
    this.manual = true,
    required this.createdAt,
  });
}
