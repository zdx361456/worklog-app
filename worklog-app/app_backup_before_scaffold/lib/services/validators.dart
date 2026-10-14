/// 实体校验器（§8 数据完整性约束清单落地）
/// 对应 03 §8。
///
/// 分两层：
///  - 基础谓词（validXxx）：供导入校验（对原始 map 取值）与 UI（对模型）**共用同一判据**；
///  - 模型级校验（xxx()→List<String>）：供 UI 保存前调用。
library;

import '../models/company.dart';
import '../models/pricing_rule.dart';
import '../models/work_record.dart';
import '../models/payment_record.dart';
import '../models/holiday_mark.dart';
import '../models/ledger.dart';

class Validators {
  const Validators._();

  /// 倍率下限：1.0（×10 = 10）。
  static const int minRate = 10;

  /// 半天折算比取值范围（×10）：0.1~0.9。
  static const int minHalfDayRatio = 1;
  static const int maxHalfDayRatio = 9;

  // ── 基础谓词（无副作用、不抛异常）──

  /// 基础单价 > 0（分）。
  static bool validBaseRate(int fen) => fen > 0;

  /// 倍率 ≥ 1.0（×10 ≥ 10）。
  static bool validRate(int x10) => x10 >= minRate;

  /// 半天折算比 0<x<1（1~9）。
  static bool validHalfDayRatio(int x10) =>
      x10 >= minHalfDayRatio && x10 <= maxHalfDayRatio;

  /// 金额 > 0（分）——用于收款（AC-25）。
  static bool validPositiveAmount(int fen) => fen > 0;

  /// 金额 ≥ 0（分）——用于金额快照（草稿可为 0）。
  static bool validNonNegativeAmount(int fen) => fen >= 0;

  /// 名称非空。
  static bool validName(String? name) => name != null && name.trim().isNotEmpty;

  // ── 模型级校验（UI 保存前）──

  /// 计价规则：基础单价 > 0；倍率 ≥ 1；半天折算比 0<x<1。
  static List<String> pricingRule(PricingRule r) {
    final e = <String>[];
    if (!validBaseRate(r.baseRate)) e.add('基础单价必须 > 0');
    if (!validRate(r.overtimeRate)) e.add('加班倍率必须 ≥ 1.0');
    if (!validRate(r.weekendRate)) e.add('周末倍率必须 ≥ 1.0');
    if (!validRate(r.holidayRate)) e.add('节假日倍率必须 ≥ 1.0');
    if (!validHalfDayRatio(r.halfDayRatio)) e.add('半天折算比必须在 0~1 之间（1~9）');
    return e;
  }

  /// 收款记录：金额 > 0（AC-25：≤0 阻止保存）。
  static List<String> payment(PaymentRecord p) {
    final e = <String>[];
    if (!validPositiveAmount(p.amount)) e.add('收款金额必须 > 0');
    return e;
  }

  /// 工作记录：金额/单价快照 ≥ 0。
  static List<String> workRecord(WorkRecord w) {
    final e = <String>[];
    if (!validNonNegativeAmount(w.amountSnapshot)) e.add('金额快照不能为负');
    if (!validNonNegativeAmount(w.rateSnapshot)) e.add('单价快照不能为负');
    return e;
  }

  /// 公司：名称非空；币种与账本一致（§8 约束#7）。
  static List<String> company(Company c, {Ledger? ledger}) {
    final e = <String>[];
    if (!validName(c.name)) e.add('公司名称不能为空');
    if (ledger != null && c.currency != ledger.currency) {
      e.add('公司币种(${c.currency})与账本币种(${ledger.currency})不一致');
    }
    return e;
  }

  /// 节假日标记：倍率 ≥ 1。
  static List<String> holidayMark(HolidayMark h) {
    final e = <String>[];
    if (!validRate(h.rate)) e.add('节假日倍率必须 ≥ 1.0');
    return e;
  }
}
