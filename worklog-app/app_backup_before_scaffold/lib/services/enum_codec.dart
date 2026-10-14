/// 枚举 ↔ 中文标识 双向编解码（唯一映射源）
/// 对应 03 §6.2 序列化/§6.4 校验。
///
/// 目的：导出序列化与导入校验**共用同一映射**，避免两处字符串↔枚举耦合
/// （任一改文案即破坏一致性断言）。
library;

import '../models/types.dart';

class EnumCodec {
  const EnumCodec._();

  // ── 计价方式 ──
  static String pricingMethod(PricingMethod m) => switch (m) {
        PricingMethod.hourly => '时价',
        PricingMethod.daily => '日价',
        PricingMethod.piece => '计件',
      };

  static PricingMethod? pricingMethodFrom(String? s) => switch (s) {
        '时价' => PricingMethod.hourly,
        '日价' => PricingMethod.daily,
        '计件' => PricingMethod.piece,
        _ => null,
      };

  // ── 工作记录状态 ──
  static String recordStatus(RecordStatus s) => switch (s) {
        RecordStatus.draft => '草稿',
        RecordStatus.confirmed => '已确认',
        RecordStatus.settled => '已结算',
      };

  static RecordStatus? recordStatusFrom(String? s) => switch (s) {
        '草稿' => RecordStatus.draft,
        '已确认' => RecordStatus.confirmed,
        '已结算' => RecordStatus.settled,
        _ => null,
      };

  // ── 金额来源 ──
  static String amountSource(AmountSource a) => switch (a) {
        AmountSource.auto => '自动',
        AmountSource.manual => '手工覆盖',
      };

  static AmountSource? amountSourceFrom(String? s) => switch (s) {
        '自动' => AmountSource.auto,
        '手工覆盖' => AmountSource.manual,
        _ => null,
      };

  // ── 收款方式 ──
  static String paymentMethod(PaymentMethod? m) => switch (m) {
        PaymentMethod.cash => '现金',
        PaymentMethod.wechat => '微信',
        PaymentMethod.alipay => '支付宝',
        PaymentMethod.bank => '银行',
        PaymentMethod.other => '其他',
        null => '',
      };

  static PaymentMethod? paymentMethodFrom(String? s) {
    switch (s) {
      case '现金':
        return PaymentMethod.cash;
      case '微信':
        return PaymentMethod.wechat;
      case '支付宝':
        return PaymentMethod.alipay;
      case '银行':
        return PaymentMethod.bank;
      case '其他':
        return PaymentMethod.other;
      case null:
      case '':
        return null; // 可空
      default:
        return null;
    }
  }

  // ── 节假日类型（设计 §2.6：法定节假日 / 调休上班 / 自定义）──
  static String holidayType(HolidayType t) => switch (t) {
        HolidayType.statutory => '法定节假日',
        HolidayType.workingSwap => '调休上班',
        HolidayType.custom => '自定义',
      };

  static HolidayType? holidayTypeFrom(String? s) => switch (s) {
        '法定节假日' => HolidayType.statutory,
        '调休上班' => HolidayType.workingSwap,
        '自定义' => HolidayType.custom,
        _ => null,
      };

  // ── 账本模式 ──
  static String ledgerMode(LedgerMode m) => switch (m) {
        LedgerMode.local => '本地',
        LedgerMode.cloud => '云端',
      };

  static LedgerMode? ledgerModeFrom(String? s) => switch (s) {
        '本地' => LedgerMode.local,
        '云端' => LedgerMode.cloud,
        _ => null,
      };

  // ── 启用/停用（公司、规则共用）──
  static String enabled(bool on) => on ? '启用' : '停用';

  static bool enabledFrom(String? s) => s == '启用';

  // ── 节假日来源 ──
  static String holidaySource(bool manual) => manual ? '用户手动' : '系统日历';
}
