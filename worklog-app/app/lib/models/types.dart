/// 基础版公共类型定义（计价 + 账本）
/// 对应文档 03-数据模型与信息架构.md §2/§4
///
/// 金额精度纪律（03 §4.6 / §6.2 规则2）：
///  - 金额一律用整数「分」表示（例：24000 = 240.00 元），禁用浮点。
///  - 倍率一律用整数「×10」表示（例：15 = 1.5 倍），支持 0.1 精度。
///  - 数量 qty 是物理量（时长/天数/件数），保留 double，金额乘积后四舍五入到分。
library;

/// 计价方式（快照固化）
enum PricingMethod { hourly, daily, piece }

/// 工作记录状态
enum RecordStatus { draft, confirmed, settled }

/// 收款方式
enum PaymentMethod { cash, wechat, alipay, bank, other }

/// 金额来源
enum AmountSource { auto, manual }

/// 节假日类型
enum HolidayType { statutory, workingSwap, custom }

/// 账本模式（03 §2.1；基础版恒为 local）
enum LedgerMode { local, cloud }

/// 倍率明细快照：记录落库时命中了哪些倍率、最终取用了哪个。
/// 倍率字段统一用整数「×10」表示（15 = 1.5 倍）。
class RateSnapshot {
  final bool overtime;
  final int overtimeRate;
  final bool weekend;
  final int weekendRate;
  final bool holiday;
  final int holidayRate;
  final int appliedRate;

  const RateSnapshot({
    this.overtime = false,
    this.overtimeRate = 10,
    this.weekend = false,
    this.weekendRate = 10,
    this.holiday = false,
    this.holidayRate = 10,
    required this.appliedRate,
  });
}
