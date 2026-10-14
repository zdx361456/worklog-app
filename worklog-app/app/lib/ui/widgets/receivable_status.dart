/// 收款状态角标 / 公司标志角标（Wave A 共享件 · 09 §12）。
///
/// **状态口径（PRD §5.2，整数严格等号）**：全部金额为整数「分」，判定只用
/// `==` / `<` 整数比较，**无浮点**。5 态由 [receivableStatusLabel] 唯一实现，
/// P01 / P06 / P07 / P-DEBT 共用，保证多页一致（AC-33）。
library;

import 'package:flutter/material.dart';

import '../../models/company.dart';

/// PRD §5.2 五态（严格等号）：
/// - `0/0` → 未开工
/// - `>0/0` → 未收
/// - `0 < 已收 < 应收` → 部分收款
/// - `已收 == 应收` → 已结清
/// - `已收 > 应收` → 多收·待核对
String receivableStatusLabel(int receivable, int received) {
  if (receivable == 0 && received == 0) return '未开工';
  if (receivable > 0 && received == 0) return '未收';
  if (received > 0 && received < receivable) return '部分收款';
  if (received == receivable) return '已结清'; // 严格等号
  return '多收·待核对'; // received > receivable
}

/// 状态角标：颜色按 [receivableStatusLabel] 分档。
class ReceivableStatusChip extends StatelessWidget {
  const ReceivableStatusChip({
    super.key,
    required this.receivable,
    required this.received,
  });

  /// 应收（分）。
  final int receivable;

  /// 已收（分）。
  final int received;

  @override
  Widget build(BuildContext context) {
    final label = receivableStatusLabel(receivable, received);
    final color = switch (label) {
      '未开工' => Colors.grey.shade700,
      '未收' => const Color(0xFFD32F2F),
      '部分收款' => Colors.orange.shade800,
      '已结清' => const Color(0xFF2E7D32),
      _ => Colors.purple.shade600, // 多收·待核对
    };
    return _Badge(label: label, color: color);
  }
}

/// 公司标志角标：停用 / 已删除（灰）。正常公司不产生任何角标。
class CompanyFlagChips extends StatelessWidget {
  const CompanyFlagChips({super.key, required this.company});

  final Company company;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (!company.enabled) const _Badge(label: '已停用', color: Colors.grey),
      if (company.deletedAt != null) const _Badge(label: '已删除', color: Colors.grey),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 4, runSpacing: 4, children: chips);
  }
}

/// 统一小角标样式（与 `records_page.dart` 既有 chip 视觉一致）。
class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
