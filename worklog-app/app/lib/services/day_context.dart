/// 日期上下文 D 的唯一构造点（`03 §4.1` R-G05，Wave D1-c 新建）。
///
/// **上游口径（逐字）**：`03-数据模型与信息架构.md:327` —— 「`D` 只含两个布尔量
/// `D.isWeekend` / `D.isHoliday`（与 `AmountInput` 一致，`amount_engine.dart:42-44`）；
/// 引擎**只读**这两个量，**不查日历、不查 `holiday_mark`**（标记由**调用方**在构造输入时
/// 算好）。」→ 本文件即那个「调用方」，把「算」收敛为一处，供 P02b 完整表单复用。
///
/// **时点语义（写死）**：`03:328` —— 「`D` 由记录「**首次固化**」时点的 `workDate` 推出…
/// 固化时写入 `rateDetailSnapshot` 并**冻结**。⇒ `D` 不是运行期函数，是"首次固化时点"的快照。」
///   - **新建路径**：按 `workDate` 调 [resolveDayContext] 构造 `D` 后随 `AmountInput` 传入引擎；
///   - **编辑重算路径（P05）**：一律**读回**冻结快照的 `D`，**重算不重新判定**（故本文件
///     **只被新建路径引用**，编辑态不调用）。
///
/// 判定口径（唯一，不得自创）：
///   - `isWeekend` = 该日是否**周六/周日**（`03:328` 逐字）；
///   - `isHoliday` = 该日是否**命中** `holiday_mark`（`03:328` 逐字）——
///     **非** `HolidayMark.rate`（该字段不参与金额计算，见 `16 §3.5 R48`）。
///
/// 金额纪律：本文件**不含任何浮点运算**（只做布尔判定与一次性 DB 存在性查询）。
library;

import '../db/database.dart';

/// 一次记工的日期上下文（`D`）：两个布尔量，与 `AmountInput.isWeekend/isHoliday` 同构。
class DayContext {
  /// 该 `workDate` 是否周六/周日。
  final bool isWeekend;

  /// 该 `workDate` 是否命中 `holiday_mark`（存在性，不看 `rate`）。
  final bool isHoliday;

  const DayContext({required this.isWeekend, required this.isHoliday});

  /// 两量皆否（账本尚未初始化 / 判定失败时的保守兜底）。
  static const DayContext none = DayContext(isWeekend: false, isHoliday: false);

  @override
  String toString() => 'DayContext(isWeekend: $isWeekend, isHoliday: $isHoliday)';
}

/// `isWeekend` 判定：该日是否**周六/周日**（`03:328` 逐字口径）。
/// `DateTime.weekday`：1=周一 … 6=周六 … 7=周日。
bool isWeekendDate(DateTime d) =>
    d.weekday == DateTime.saturday || d.weekday == DateTime.sunday;

/// `isHoliday` 判定：该日是否**命中** `holiday_mark`（`03:328` 逐字口径）。
///
/// 由**录入路径**在「首次固化时点」调用一次（`03:327`）；结果随 `AmountInput` 进引擎，
/// 写入 `rateDetailSnapshot` 后**冻结**，此后编辑不重算（`03:328`）。
Future<DayContext> resolveDayContext({
  required String ledgerId,
  required DateTime workDate,
}) async {
  final mark =
      await AppDatabase.instance.getHolidayMarkByDate(ledgerId, workDate);
  return DayContext(
    isWeekend: isWeekendDate(workDate),
    isHoliday: mark != null,
  );
}
