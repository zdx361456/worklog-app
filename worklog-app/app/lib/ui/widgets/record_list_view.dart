/// 记录列表组件（Wave A 共享件 · 09 §4.4）：**列表主源**。
///
/// **定位**：单类型列表（工作 / 收款二选一），自持加载 + 空/错/加载态 + 行渲染 + 滑动删除；
/// **不含 Scaffold**。谁要显示列表谁用它：
/// - `RecordsPage`（页面壳）→ 双 tab 各嵌一个；下钻单嵌一个。
/// - P07 `CompanyDetailPage` → 两个 tab 各嵌一个（`showCompanyName: false`）。
/// - P04（Wave B）→ 复用（追加 `groupByCompany` 时**不改本 API**）。
///
/// **排序**：DB 已 `ORDER BY attribution_date DESC, created_at DESC` / `pay_date DESC,
/// created_at DESC` → UI **不再重复排序**（避免"双排序口径"）。
///
/// **金额纪律**：一律 [fenToYuan] 展示；草稿行金额显 `—`（`07:340`）；禁浮点。
///
/// **刷新**：`initState` 注册 [dataBus] 监听，`dispose` 注销；父级传入新 `filter` 时走
/// `didUpdateWidget` → `_load()`。
library;

import 'package:flutter/material.dart';

import '../../app/data_bus.dart';
import '../../db/database.dart';
import '../../models/payment_record.dart';
import '../../models/types.dart';
import '../../models/work_record.dart';
import '../../services/enum_codec.dart';
import '../payment_form_page.dart';
import '../record_detail_page.dart';
import '../records_filter.dart';
import 'money.dart';

// 金额着色（契约 §3，中国习惯：涨红跌绿）。
const Color _kRedAmount = Color(0xFFD32F2F);
const Color _kGreenAmount = Color(0xFF2E7D32);

class RecordListView extends StatefulWidget {
  /// [filter] 的 `scope` **必须**为单类型（`workOnly` / `paymentOnly`）；
  /// `both` 由壳层拆成两个实例（双 tab），本组件不处理 `both`。
  const RecordListView({
    super.key,
    required this.filter,
    this.companyNameById = const {},
    this.ruleNameById = const {},
    this.showCompanyName = true,
    this.showRuleName = true,
    this.emptyTitle = '还没有记录',
    this.emptyHint,
    this.emptyActionLabel,
    this.onEmptyAction,
    this.enableDismissDelete = true,
  });

  final RecordsFilter filter;

  /// `companyId → 公司名` 映射（`showCompanyName: true` 时使用）。
  final Map<String, String> companyNameById;

  /// `pricingRuleId → 规则名（工序）` 映射（工作行显示工序用）。
  final Map<String, String> ruleNameById;

  /// 是否显示公司名（全部记录 / 下钻 = true；P07 = false，公司固定）。
  final bool showCompanyName;

  /// 工作行是否显示工序名。
  final bool showRuleName;

  final String emptyTitle;
  final String? emptyHint;

  /// 空态主按钮文案；null → 不显示主按钮。
  final String? emptyActionLabel;

  /// 空态主按钮回调（由壳层注入跳转）。
  final VoidCallback? onEmptyAction;

  /// 是否允许滑动删除（P07 也需要删除，`07:461`）。
  final bool enableDismissDelete;

  @override
  State<RecordListView> createState() => _RecordListViewState();
}

class _RecordListViewState extends State<RecordListView> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;
  List<Object> _data = const [];

  @override
  void initState() {
    super.initState();
    dataBus.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataBus.removeListener(_load);
    super.dispose();
  }

  @override
  void didUpdateWidget(RecordListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filter != widget.filter) {
      _load();
    }
  }

  Future<void> _load() async {
    assert(widget.filter.scope != RecordsScope.both,
        'RecordListView 为单类型列表，scope 不可为 both');
    try {
      final f = widget.filter;
      final List<Object> data;
      if (f.scope == RecordsScope.workOnly) {
        data = await _db.listWorkRecords(
          companyId: f.companyId,
          startDate: f.startDate,
          endDate: f.endDate,
          includeDeleted: f.includeDeleted,
          includeDraft: f.includeDraft, // 陷阱 1 落点：receivableDrill = false
        );
      } else {
        data = await _db.listPaymentRecords(
          companyId: f.companyId,
          startDate: f.startDate,
          endDate: f.endDate,
          includeDeleted: f.includeDeleted,
        );
      }
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  // ── 删除（沿用既有「乐观移除 + 确认对话框 + 失败回滚」写法）────────────────

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _handleDismissed(String id) {
    setState(() =>
        _data = _data.where((e) => _idOf(e) != id).toList(growable: false));
    _delete(id);
  }

  String _idOf(Object e) =>
      e is WorkRecord ? e.id : (e as PaymentRecord).id;

  Future<void> _delete(String id) async {
    try {
      final isWork = widget.filter.scope == RecordsScope.workOnly;
      if (isWork) {
        await _db.softDeleteWorkRecord(id, DateTime.now());
      } else {
        await _db.softDeletePaymentRecord(id, DateTime.now());
      }
      if (!mounted) return;
      dataBus.dataChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
      _load(); // 回滚乐观移除
    }
  }

  // ── 行点击（工作行 → P05 记录详情；收款行 → P10 收款登记）─────────────────────────

  Future<void> _openWork(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RecordDetailPage(id: id)),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _openPayment(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PaymentFormPage(id: id)),
    );
    if (!mounted) return;
    await _load();
  }

  // ── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }
    if (_data.isEmpty) {
      return _EmptyView(
        icon: widget.filter.scope == RecordsScope.workOnly
            ? Icons.work_off_outlined
            : Icons.payments_outlined,
        title: widget.emptyTitle,
        hint: widget.emptyHint,
        actionLabel: widget.emptyActionLabel,
        onAction: widget.onEmptyAction,
      );
    }

    return ListView.builder(
      itemCount: _data.length,
      itemBuilder: (context, index) {
        final e = _data[index];
        if (e is WorkRecord) {
          final row = WorkRecordRow(
            key: ValueKey('work-${e.id}'),
            record: e,
            companyName: widget.companyNameById[e.companyId],
            ruleName: widget.ruleNameById[e.pricingRuleId],
            showCompanyName: widget.showCompanyName,
            showRuleName: widget.showRuleName,
            onTap: () => _openWork(e.id),
          );
          return _maybeDismissible(
            id: e.id,
            key: ValueKey('dismiss-work-${e.id}'),
            title: '删除这条工作记录？',
            message: '删除后该记录将从明细与统计中移除。',
            child: row,
          );
        }
        final p = e as PaymentRecord;
        final row = PaymentRecordRow(
          key: ValueKey('payment-${p.id}'),
          record: p,
          companyName: widget.companyNameById[p.companyId],
          showCompanyName: widget.showCompanyName,
          onTap: () => _openPayment(p.id),
        );
        return _maybeDismissible(
          id: p.id,
          key: ValueKey('dismiss-payment-${p.id}'),
          title: '删除这笔收款？',
          message: '删除后该记录将从明细与统计中移除。',
          child: row,
        );
      },
    );
  }

  Widget _maybeDismissible({
    required String id,
    required Key key,
    required String title,
    required String message,
    required Widget child,
  }) {
    if (!widget.enableDismissDelete) return child;
    return Dismissible(
      key: key,
      direction: DismissDirection.endToStart,
      background: _deleteBackground(),
      confirmDismiss: (_) => _confirmDelete(title: title, message: message),
      onDismissed: (_) => _handleDismissed(id),
      child: child,
    );
  }
}

/// 滑动删除的红色背景（从右往左滑）。
Widget _deleteBackground() {
  return Container(
    color: _kRedAmount,
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: const Icon(Icons.delete, color: Colors.white),
  );
}

/// 工作记录行（公开件，供 P07 / P04 复用）。
class WorkRecordRow extends StatelessWidget {
  const WorkRecordRow({
    super.key,
    required this.record,
    required this.onTap,
    this.companyName,
    this.ruleName,
    this.showCompanyName = true,
    this.showRuleName = true,
    this.qtySnapshot,
    this.qtyUnitSnapshot,
  });

  final WorkRecord record;
  final VoidCallback onTap;
  final String? companyName;
  final String? ruleName;
  final bool showCompanyName;
  final bool showRuleName;

  /// **可选**数量槽位（`AC-P04-01`：P04 组内行含「工序/规则名 + 数量 + 金额 + 状态角标」）。
  /// 默认 `null` ⇒ **不渲染** → P07 / 明细页等既有调用点行为**零变化**。
  final double? qtySnapshot;

  /// 数量单位（`qtySnapshot` 非空时随数量一并显示，如「2 小时」）。
  final String? qtyUnitSnapshot;

  @override
  Widget build(BuildContext context) {
    final isDraft = record.status == RecordStatus.draft;
    final dateText = formatDate(record.workDate);
    final ruleLabel = ruleName ?? '—';
    final title = showCompanyName
        ? (companyName ?? '未知公司')
        : (showRuleName ? ruleLabel : dateText);
    return ListTile(
      onTap: onTap,
      title: Text(
        title,
        overflow: TextOverflow.ellipsis,
        style: isDraft ? const TextStyle(color: Colors.black45) : null,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(dateText),
            if (showCompanyName && showRuleName) Text(ruleLabel),
            if (qtySnapshot != null)
              Text(_qtyLabel(qtySnapshot!, qtyUnitSnapshot)),
            RecordStatusChip(status: record.status),
          ],
        ),
      ),
      trailing: Text(
        isDraft ? '—' : fenToYuan(record.amountSnapshot),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: isDraft ? Colors.black38 : _kRedAmount,
        ),
      ),
    );
  }
}

/// 数量展示：整数不带小数点，小数原样（3.5 → '3.5'）；**纯字符串处理，不涉金额浮点**。
String _qtyLabel(double qty, String? unit) {
  final s = qty.toString();
  final n = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  final u = unit?.trim() ?? '';
  return u.isEmpty ? n : '$n $u';
}

/// 收款记录行（公开件，供 P07 / P04 复用）。
class PaymentRecordRow extends StatelessWidget {
  const PaymentRecordRow({
    super.key,
    required this.record,
    required this.onTap,
    this.companyName,
    this.showCompanyName = true,
  });

  final PaymentRecord record;
  final VoidCallback onTap;
  final String? companyName;
  final bool showCompanyName;

  @override
  Widget build(BuildContext context) {
    final methodLabel = EnumCodec.paymentMethod(record.method); // 枚举文案走 EnumCodec
    final dateText = formatDate(record.paymentDate);
    final note = record.note?.trim() ?? '';
    final metaParts = <String>[
      dateText,
      if (methodLabel.isNotEmpty) methodLabel,
      if (note.isNotEmpty) note,
    ];
    final title = showCompanyName ? (companyName ?? '未知公司') : dateText;
    return ListTile(
      onTap: onTap,
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: Text(metaParts.join(' · ')),
      trailing: Text(
        '+${fenToYuan(record.amount)}',
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: _kGreenAmount,
        ),
      ),
    );
  }
}

/// 工作记录状态角标（公开件；由 `records_page.dart` 私有件上提）。
class RecordStatusChip extends StatelessWidget {
  const RecordStatusChip({super.key, required this.status});

  final RecordStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      // 展示走 recordStatusDisplay（草稿 →「草稿·未完成」，MIN-02）；序列化 token 不变。
      RecordStatus.draft => (Colors.grey.shade700, EnumCodec.recordStatusDisplay(status)),
      RecordStatus.confirmed =>
        (Colors.blue.shade700, EnumCodec.recordStatusDisplay(status)),
      RecordStatus.settled => (_kGreenAmount, EnumCodec.recordStatusDisplay(status)),
    };
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

class _EmptyView extends StatelessWidget {
  const _EmptyView({
    required this.icon,
    required this.title,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.black26),
            const SizedBox(height: 16),
            Text(title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(hint!,
                  style: const TextStyle(color: Colors.black54),
                  textAlign: TextAlign.center),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: _kRedAmount),
            const SizedBox(height: 12),
            const Text('数据加载失败',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('$error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// `YYYY-MM-DD`。
String formatDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
