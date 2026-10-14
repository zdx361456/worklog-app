/// P04 · 日详情页（**Wave B 新建**）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.4（`07:326-361`）；
/// `docs/04-迭代/2026-10-05/补齐规格07剩余页/02-需求与验收.md` §D.4（`AC-P04-01~09`）。
/// 设计落点：`13-WaveB-实现设计.md` §1.2。
///
/// **定位**：P03 点某天的落地页——当天各公司分组 → 组内记录列表（可视觉折叠）。
///
/// **口径纪律**：
///  - 当日合计 / 组小计 = `Σ` **有效（非草稿）**记录 `amountSnapshot`（草稿不计入，AC-32）；
///  - 金额整数「分」，显示一律 [fenToYuan]，**禁浮点**；
///  - 分组/排序/合计**全派生**（不落库）；
///  - 剩余不在本页显示，亦不做任何手写「应收 − 已收」。
///
/// **容错读**：用 [AppDatabase.listWorkRecordsLenient]（`database.dart:663-677`）——坏行跳过
/// + 顶部黄色告警条（§D.0.3 / `07 §4.4`）。
///
/// **证据层级**：数据接线 / 分组 / 排序 / 合计 =【读码级】；折叠 / 虚线框 / 滑动删除 =【真机】。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/pricing_rule.dart';
import '../models/types.dart';
import '../models/work_record.dart';
import '../services/enum_codec.dart';
import 'company_detail_page.dart';
import 'quick_add_sheet.dart';
import 'record_detail_page.dart';
import 'widgets/money.dart';
import 'widgets/record_list_view.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

class DayDetailPage extends StatefulWidget {
  const DayDetailPage({super.key, required this.date});

  /// 归属日（只比年月日，§1.3）。
  final DateTime date;

  @override
  State<DayDetailPage> createState() => _DayDetailPageState();
}

class _DayDetailPageState extends State<DayDetailPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;

  List<WorkRecord> _records = const [];
  List<SkippedRow> _skipped = const [];

  Map<String, String> _companyNameById = const {};
  Map<String, String> _ruleNameById = const {};
  Set<String> _deletedRuleIds = const {}; // 已软删规则（悬空 → 标「规则已删除」）

  /// 已折叠的分组（companyId）。
  final Set<String> _collapsed = <String>{};

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

  Future<void> _load() async {
    final d = widget.date;
    try {
      // 容错读（§D.4 数据接线）：坏行跳过 + 计数，不上抛。
      final lenient = await _db.listWorkRecordsLenient(
        startDate: d,
        endDate: d,
        includeDraft: true, // 台账语义：草稿行须显示（AC-P04-06）
      );
      final results = await Future.wait<Object>([
        // 公司名/色（含停用/归档；13 §3 缺口 2 已上报超集）。
        _db.listCompanies(includeDisabled: true, includeDeleted: true),
        // 规则名映射 + 删除判定（07:354 需区分「规则已删除」；§D.4 未列此读，见 13 §3 缺口 6）。
        _db.listPricingRules(includeDisabled: true, includeDeleted: true),
      ]);
      final companies = results[0] as List<Company>;
      final rules = results[1] as List<PricingRule>;
      if (!mounted) return;
      setState(() {
        _records = lenient.rows;
        _skipped = lenient.skipped;
        // 主标签用全名（D-5：禁 displayName）；简称非空附「（简称）」。
        _companyNameById = {
          for (final c in companies)
            c.id: (c.shortName == null || c.shortName!.isEmpty)
                ? c.name
                : '${c.name}（${c.shortName}）',
        };
        _ruleNameById = {for (final r in rules) r.id: r.name};
        _deletedRuleIds = {for (final r in rules) if (r.isDeleted) r.id};
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

  // ── 派生（全整数）────────────────────────────────────────────────────────

  bool get _hasDrafts => _records.any((w) => w.status == RecordStatus.draft);

  int get _draftCount =>
      _records.where((w) => w.status == RecordStatus.draft).length;

  /// 当日合计 = Σ 有效（非草稿）记录的 amountSnapshot（草稿不计入，AC-P04-02）。
  int get _dayTotal => _records
      .where((w) => w.status != RecordStatus.draft)
      .fold<int>(0, (s, w) => s + w.amountSnapshot);

  /// 按公司分组（首见顺序，确定性）。
  List<_CompanyGroup> get _groups {
    final map = <String, List<WorkRecord>>{};
    for (final w in _records) {
      map.putIfAbsent(w.companyId, () => <WorkRecord>[]).add(w);
    }
    return map.entries.map((e) {
      // 组内按 createdAt 升序（07:346）；DB 返回 DESC → UI 重排。
      final list = [...e.value]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return _CompanyGroup(companyId: e.key, records: list);
    }).toList();
  }

  /// 规则名（含悬空/已删兜底）。
  String _ruleLabel(WorkRecord w) {
    final id = w.pricingRuleId;
    final name = id == null ? null : _ruleNameById[id];
    if (name != null && !_deletedRuleIds.contains(id)) return name;
    // 快照兜底：计价方式 + 数量单位（+ 备注）—— 弱引用允许悬空（03 §3.3 / 07:354）。
    final method = EnumCodec.pricingMethod(w.methodSnapshot);
    final unit = w.qtyUnitSnapshot?.trim() ?? '';
    final note = w.note?.trim() ?? '';
    final buf = <String>[if (unit.isEmpty) method else '$method·$unit'];
    if (note.isNotEmpty) buf.add(note);
    final base = buf.join(' · ');
    final deleted = id != null; // 有 id 却取不到/已删 → 标「规则已删除」
    return deleted ? '$base（规则已删除）' : base;
  }

  // ── 动作 ────────────────────────────────────────────────────────────────

  Future<void> _openRecord(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RecordDetailPage(id: id)),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _openCompany(String companyId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CompanyDetailPage(companyId: companyId),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// P04「+ 记一笔」→ P02 秒级快记弹层（Wave D2 入口闭合），预置归属日 = 本日。
  Future<void> _openWorkNew() async {
    await QuickAddSheet.show(context, date: widget.date);
    if (!mounted) return;
    await _load();
  }

  Future<bool> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条工作记录？'),
        // 文案逐字（07:348 / AC-P04-08）。
        content: const Text('删除后不计入应收，且不可在 App 内恢复，是否删除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kRedAmount),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _delete(String id) async {
    try {
      await _db.softDeleteWorkRecord(id, DateTime.now());
      if (!mounted) return;
      dataBus.dataChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
      _load();
    }
  }

  // ── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_fmtDate(widget.date))),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openWorkNew,
        icon: const Icon(Icons.add),
        label: const Text('记一笔'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }
    if (_records.isEmpty) {
      return _EmptyView(onAction: _openWorkNew);
    }

    final groups = _groups;
    // MIN-01：边界数据量 ≥200 行场景用 `ListView.builder` **惰性**构建（`02:340`，
    // 适用清单明确含「P04 分组列表」）。以「行构造闭包」列表驱动 builder ——
    // 闭包体在该行**真正进入视口**时才执行，故 widget 构建按需发生。
    final rows = <Widget Function()>[
      if (_skipped.isNotEmpty) () => _SkippedBanner(count: _skipped.length),
      () => _buildTotalBar(),
      for (final g in groups) ..._groupRowBuilders(g),
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i](),
    );
  }

  Widget _buildTotalBar() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFF5F5F5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('当日合计（不含草稿）',
                  style: TextStyle(fontSize: 14, color: Colors.black54)),
              const Spacer(),
              Text(fenToYuan(_dayTotal),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ],
          ),
          if (_hasDrafts)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              // 防用户以为草稿金额被吞（07:353）。
              child: Text('（不含 $_draftCount 条草稿）',
                  style: const TextStyle(fontSize: 12, color: Colors.black45)),
            ),
        ],
      ),
    );
  }

  /// 组内各行（组头 + 记录行 / 折叠行）的**惰性构造闭包**（MIN-01：驱动 `ListView.builder`）。
  List<Widget Function()> _groupRowBuilders(_CompanyGroup g) {
    final collapsed = _collapsed.contains(g.companyId);
    // 折叠开关仅在「同公司同规则多段」时出现（07:337 / AC-P04-03）。
    final hasMultiSeg = _ruleSegCounts(g).values.any((n) => n >= 2);
    final subtotal = g.records
        .where((w) => w.status != RecordStatus.draft)
        .fold<int>(0, (s, w) => s + w.amountSnapshot);

    return [
      () => _GroupHeader(
            companyName: _companyLabel(g.companyId),
            subtotal: subtotal,
            collapsed: collapsed,
            showToggle: hasMultiSeg,
            onToggle: () => setState(() {
              if (collapsed) {
                _collapsed.remove(g.companyId);
              } else {
                _collapsed.add(g.companyId);
              }
            }),
            onTapName: () => _openCompany(g.companyId),
          ),
      if (collapsed)
        for (final row in _buildCollapsedRows(g)) (() => row)
      else
        for (final w in g.records) (() => _buildRecordRow(w)),
    ];
  }

  Widget _buildRecordRow(WorkRecord w) {
    final isDraft = w.status == RecordStatus.draft;
    final row = WorkRecordRow(
      key: ValueKey<String>('p04-work-${w.id}'),
      record: w,
      ruleName: _ruleLabel(w),
      showCompanyName: false, // 组头已显示公司名
      showRuleName: true,
      // AC-P04-01：行内显示数量（复用件可选槽位；P07/明细页不传，行为不变）。
      qtySnapshot: w.qtySnapshot,
      qtyUnitSnapshot: w.qtyUnitSnapshot,
      onTap: () => _openRecord(w.id),
    );
    final dismissible = Dismissible(
      key: ValueKey<String>('p04-dismiss-${w.id}'),
      direction: DismissDirection.endToStart,
      background: _deleteBackground(),
      confirmDismiss: (_) => _confirmDelete(),
      onDismissed: (_) => _delete(w.id),
      child: row,
    );
    // 草稿行：外加虚线边框（AC-P04-06）。
    return isDraft ? _DashedBorder(child: dismissible) : dismissible;
  }

  /// 折叠视图：同规则多段合并为一行（**仅视觉折叠，不合并存储**，AC-P04-03）。
  List<Widget> _buildCollapsedRows(_CompanyGroup g) {
    final counts = _ruleSegCounts(g);
    final emitted = <String>{};
    final out = <Widget>[];
    for (final w in g.records) {
      final key = w.pricingRuleId ?? '__null__${w.id}';
      if (emitted.contains(key)) continue;
      emitted.add(key);
      final n = counts[key] ?? 1;
      if (n < 2) {
        out.add(_buildRecordRow(w));
        continue;
      }
      final segs = g.records
          .where((x) => (x.pricingRuleId ?? '__null__${x.id}') == key)
          .toList();
      final sum = segs
          .where((x) => x.status != RecordStatus.draft)
          .fold<int>(0, (s, x) => s + x.amountSnapshot);
      out.add(_CollapsedRuleRow(
        key: ValueKey<String>('p04-merged-$key'),
        label: _ruleLabel(w),
        segments: n,
        amount: sum,
      ));
    }
    return out;
  }

  Map<String, int> _ruleSegCounts(_CompanyGroup g) {
    final m = <String, int>{};
    for (final w in g.records) {
      // 仅 `pricingRuleId` 非空者参与折叠判定（null 无规则，不折叠）。
      final id = w.pricingRuleId;
      if (id == null) continue;
      m[id] = (m[id] ?? 0) + 1;
    }
    return m;
  }

  String _companyLabel(String companyId) => _companyNameById[companyId] ?? '未知公司';
}

/// 顶部坏行告警条（§D.0.3 / `07 §4.4` D2）。
class _SkippedBanner extends StatelessWidget {
  const _SkippedBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 20, color: Colors.amber.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '有 $count 条数据异常，未显示也未计入剩余',
              style: TextStyle(fontSize: 13, color: Colors.amber.shade900),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompanyGroup {
  _CompanyGroup({required this.companyId, required this.records});
  final String companyId;
  final List<WorkRecord> records;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.companyName,
    required this.subtotal,
    required this.collapsed,
    required this.showToggle,
    required this.onToggle,
    required this.onTapName,
  });

  final String companyName;
  final int subtotal;
  final bool collapsed;
  final bool showToggle;
  final VoidCallback onToggle;
  final VoidCallback onTapName;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFAFAFA),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTapName, // 点公司名 → P07（07:356）
              child: Row(
                children: [
                  Flexible(
                    child: Text(companyName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Text('· ${fenToYuan(subtotal)}',
                      style: const TextStyle(
                          fontSize: 13, color: Colors.black54)),
                ],
              ),
            ),
          ),
          if (showToggle)
            TextButton(
              onPressed: onToggle,
              child: Text(collapsed ? '展开' : '折叠'),
            ),
        ],
      ),
    );
  }
}

/// 折叠后的合并行（同公司同规则多段；仅视觉折叠）。
class _CollapsedRuleRow extends StatelessWidget {
  const _CollapsedRuleRow({
    super.key,
    required this.label,
    required this.segments,
    required this.amount,
  });

  final String label;
  final int segments;
  final int amount;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label, overflow: TextOverflow.ellipsis),
      subtitle: Text('$segments 段 · 合并显示'),
      trailing: Text(fenToYuan(amount),
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: _kRedAmount)),
    );
  }
}

/// 虚线边框（草稿行，AC-P04-06）：无依赖自绘。
class _DashedBorder extends StatelessWidget {
  const _DashedBorder({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRectPainter(Colors.grey.shade400),
      child: child,
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = 5.0;
    const gap = 3.0;
    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) =>
      oldDelegate.color != color;
}

Widget _deleteBackground() {
  return Container(
    color: _kRedAmount,
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: const Icon(Icons.delete, color: Colors.white),
  );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onAction});

  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.work_off_outlined, size: 56, color: Colors.black26),
            const SizedBox(height: 16),
            const Text('这天还没记工',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add),
              label: const Text('记一笔'),
            ),
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

String _fmtDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
