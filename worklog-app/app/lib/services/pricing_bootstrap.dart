/// 基础版计价策略：用户只填「单价」，规则自动维护。
///
/// [ensureRule] 在 `(companyId, method, baseRate, unit)` 四元组上复用**已启用**规则；
/// 找不到则新建一条。这样 UI 端（记一笔工作 / 记一笔收款）无需暴露「规则管理」概念，
/// 仍能保证金额快照有据可溯（`WorkRecord.pricingRuleId` 弱引用不悬空）。
library;

import '../db/database.dart';
import '../models/pricing_rule.dart';
import '../models/types.dart';
import 'id_gen.dart';

/// 在 `(companyId, method, baseRate, unit)` 上复用已启用规则；无则新建。
///
/// - 命中且 `standardHours` 未变 → 原样返回；
/// - 命中但传入 `standardHours` 且与现值不同 → 就地更新该字段（不新建、不改金额口径）；
/// - 未命中 → 用 [newId]`('rule')` 新建并落库。
///
/// 金额纪律：`baseRate` 为整数「分」，倍率字段沿用模型默认（加班 ×1.5 = 15）。
Future<PricingRule> ensureRule({
  required String companyId,
  required PricingMethod method,
  required int baseRate, // 分
  String? unit,
  double? standardHours,
}) async {
  final db = AppDatabase.instance;
  final existing = await db.listPricingRules(companyId: companyId);
  for (final r in existing) {
    if (r.method == method && r.baseRate == baseRate && r.unit == unit) {
      if (standardHours != null && r.standardHours != standardHours) {
        final updated = PricingRule(
          id: r.id,
          companyId: r.companyId,
          name: r.name,
          method: r.method,
          baseRate: r.baseRate,
          unit: r.unit,
          standardHours: standardHours,
          halfDayRatio: r.halfDayRatio,
          overtimeRate: r.overtimeRate,
          weekendRate: r.weekendRate,
          holidayRate: r.holidayRate,
          effectiveDate: r.effectiveDate,
          enabled: r.enabled,
          createdAt: r.createdAt,
          updatedAt: DateTime.now(),
        );
        await db.upsertPricingRule(updated);
        return updated;
      }
      return r;
    }
  }

  final now = DateTime.now();
  final rule = PricingRule(
    id: newId('rule'),
    companyId: companyId,
    name: _defaultRuleName(method),
    method: method,
    baseRate: baseRate,
    unit: unit,
    standardHours: standardHours,
    createdAt: now,
    updatedAt: now,
  );
  await db.upsertPricingRule(rule);
  return rule;
}

/// 规则显示名（基础版按计价方式给默认名，用户不感知规则管理）。
String _defaultRuleName(PricingMethod method) {
  switch (method) {
    case PricingMethod.hourly:
      return '时薪';
    case PricingMethod.daily:
      return '日薪';
    case PricingMethod.piece:
      return '计件';
  }
}
