/// P11 · 统计页（**Wave C1 原位填充**，保留 Wave A2 的 `Scaffold`/`AppBar` 外壳与构造签名）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.11（`07:567-595`）；
/// `docs/04-迭代/2026-10-05/补齐规格07剩余页/02-需求与验收.md` §D.9（`AC-P11-01~08`）；
/// 实现设计：`14-WaveC1-实现设计.md` §2。
///
/// **四维度定义（本文唯一权威，14 §2.2）**：
///   - 按公司：取 `aggregateByCompany().receivable`（**AC-P11-03 明文 == A2 应收**），行点击 → P07；
///   - 按月：全时段按 `workDate` 的 `yyyy-MM` 分组；
///   - 按时间段：选定区间内按 `yyyy-MM-dd` **日**分组（依据 MIN-6「≥200 行」+ 与"按月"区分）；
///   - 按计价方式：按 `methodSnapshot` 分组（AC-P11-04，AC-38）。
///
/// **口径纪律（`02 §D.0.2`）**：统计取数 `listWorkRecords(includeDraft: false)`
/// （≡`status IN ('confirmed','settled')`，与聚合 `database.dart:304` 逐字相同）
/// → **排除草稿与软删**（AC-32）；合计恒 == 明细之和（AC-37）。
///
/// **降级（D-6 / `02 §D.0.3:341`）**：聚合坏值/脏行（`FormatException`）→ 顶部黄条
/// 「账目数字可能不完整，请勿据此对账」+ 导出备份引导 + 重试，**不白屏**。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../app/routes.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/types.dart';
import '../models/work_record.dart';
import '../services/enum_codec.dart';
import 'company_detail_page.dart';
import 'export_backup_page.dart';
import 'widgets/money.dart';

// 金额着色（契约 §3，中国习惯：涨红跌绿）。
const Color _kRedAmount = Color(0xFFD32F2F);

/// 四个统计维度（`07:575`）。
enum _Dim { company, month, range, method }

extension on _Dim {
  String get label => switch (this) {
        _Dim.company => '按公司',
        _Dim.month => '按月',
        _Dim.range => '按时间段',
        _Dim.method => '按计价方式',
      };
}

/// 一行统计结果：维度值 + 金额（分）+ 可选公司 id（按公司维度用于跳转）。
class _Row {
  const _Row({required this.label, required this.amountFen, this.companyId});
  final String label;
  final int amountFen;
  final String? companyId;
}

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;

  /// 是否处于降级态（任一查询遭遇聚合坏值/脏行 `FormatException`）。
  bool _degraded = false;

  /// 统计源（q2）是否可得 → 决定月/时间段/计价方式维度是否可算。
  bool _recordsAvailable = true;

  /// 按公司权威源（q3）是否可得 → 决定按公司维度是否可算。
  bool _companyAggAvailable = true;

  /// 全时段、非草稿、非软删的工作记录（stats 统一数据源）。
  List<WorkRecord> _records = const [];

  /// 公司元数据全集（含停用/归档，D-5 禁裸调）。
  List<Company> _companies = const [];

  /// 各公司应收权威源（A2）。
  List<ReceivableAggregate> _aggByCompany = const [];

  _Dim _dim = _Dim.company;

  /// 时间段维度默认本月（`07:576`）。
  DateTime _start = _monthStart(DateTime.now());
  DateTime _end = _monthEnd(DateTime.now());

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

  /// 单查询降级包装：**只把聚合坏值/脏行（`FormatException`）降级为 `null`**，
  /// 其余异常原样上抛 → 外层 `catch` 走整页 [_ErrorView]（与 P01 同款，`overview_page.dart:87-93`）。
  Future<T?> _guard<T>(Future<T> future) async {
    try {
      return await future;
    } on FormatException {
      return null;
    }
  }

  Future<void> _load() async {
    try {
      final res = await Future.wait<Object?>([
        // q1 公司元数据全集（双 true，D-5 / 07 §4.1 约束 1）
        _guard(_db.listCompanies(includeDisabled: true, includeDeleted: true)),
        // q2 统计源：全时段 + 非草稿 + 非软删（includeDraft:false）
        _guard(_db.listWorkRecords(includeDraft: false)),
        // q3 按公司应收权威源（A2）
        _guard(_db.aggregateByCompany()),
      ]);

      final companies = (res[0] as List<Company>?) ?? const <Company>[];
      final records = (res[1] as List<WorkRecord>?) ?? const <WorkRecord>[];
      final byCompany =
          (res[2] as List<ReceivableAggregate>?) ?? const <ReceivableAggregate>[];

      // 开发期断言（AC-P11-03 / AC-37）：
      // ① aggregate(null).receivable == Σ records.amountSnapshot（全时段维度合计）
      // ② Σ aggregateByCompany().receivable == aggregate(null).receivable
      // 降级态前置不成立 → 跳过（避免 null 击穿）。
      if (res[1] != null && res[2] != null) {
        final recordSum =
            records.fold<int>(0, (s, r) => s + r.amountSnapshot);
        final companySum =
            byCompany.fold<int>(0, (s, a) => s + a.receivable);
        assert(
          recordSum == companySum,
          'P11 断言失败：Σ records.amountSnapshot($recordSum) != '
          'Σ aggregateByCompany().receivable($companySum)',
        );
      }

      if (!mounted) return;
      setState(() {
        _companies = companies;
        _records = records;
        _aggByCompany = byCompany;
        _degraded = res[0] == null || res[1] == null || res[2] == null;
        _recordsAvailable = res[1] != null;
        _companyAggAvailable = res[2] != null;
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

  // ── 维度计算 ──────────────────────────────────────────────────────────

  /// 当前维度行集合（未排序）。
  List<_Row> _computeRows() {
    switch (_dim) {
      case _Dim.company:
        return _companyRows();
      case _Dim.month:
        return _groupedRows(_records, (r) => _ymKey(r.workDate), _recordsAvailable);
      case _Dim.range:
        if (_rangeInvalid) return const [];
        final inRange = _records.where((r) {
          final d = DateTime(r.workDate.year, r.workDate.month, r.workDate.day);
          return !d.isBefore(_start) && !d.isAfter(_end);
        }).toList(growable: false);
        return _groupedRows(inRange, (r) => _ymdKey(r.workDate), _recordsAvailable);
      case _Dim.method:
        if (!_recordsAvailable) return const [];
        final map = <PricingMethod, int>{};
        for (final r in _records) {
          map[r.methodSnapshot] = (map[r.methodSnapshot] ?? 0) + r.amountSnapshot;
        }
        final rows = map.entries
            .map((e) => _Row(
                  label: EnumCodec.pricingMethod(e.key),
                  amountFen: e.value,
                ))
            .toList(growable: false);
        rows.sort((a, b) => b.amountFen.compareTo(a.amountFen));
        return rows;
    }
  }

  /// 按公司维度：**权威取 A2 应收**（AC-P11-03），名称走全名映射（D-5）。
  List<_Row> _companyRows() {
    if (!_companyAggAvailable) return const [];
    final nameById = {for (final c in _companies) c.id: c};
    final rows = <_Row>[];
    for (final a in _aggByCompany) {
      final cid = a.companyId;
      if (cid == null) continue; // 全局合计项不进明细行
      final c = nameById[cid];
      rows.add(_Row(
        label: c == null ? '未知公司' : _companyLabel(c),
        amountFen: a.receivable,
        companyId: cid,
      ));
    }
    rows.sort((a, b) => b.amountFen.compareTo(a.amountFen));
    return rows;
  }

  /// 通用分组求和（时间维度用）：`keyOf` 产出分组键，倒序（新在前）。
  List<_Row> _groupedRows(
    List<WorkRecord> src,
    String Function(WorkRecord) keyOf,
    bool available,
  ) {
    if (!available) return const [];
    final map = <String, int>{};
    for (final r in src) {
      final k = keyOf(r);
      map[k] = (map[k] ?? 0) + r.amountSnapshot;
    }
    final rows = map.entries
        .map((e) => _Row(label: e.key, amountFen: e.value))
        .toList(growable: false);
    rows.sort((a, b) => b.label.compareTo(a.label)); // yyyy-MM / yyyy-MM-dd 字符串倒序 = 时间倒序
    return rows;
  }

  String _companyLabel(Company c) =>
      (c.shortName == null || c.shortName!.isEmpty)
          ? c.name
          : '${c.name}（${c.shortName}）';

  bool get _rangeInvalid =>
      DateTime(_start.year, _start.month, _start.day)
          .isAfter(DateTime(_end.year, _end.month, _end.day));

  /// 当前维度是否因数据源降级而不可用（用于空态 vs "读取失败"区分）。
  bool get _dimUnavailable => switch (_dim) {
        _Dim.company => !_companyAggAvailable,
        _Dim.month || _Dim.range || _Dim.method => !_recordsAvailable,
      };

  // ── 出口 ──────────────────────────────────────────────────────────────

  Future<void> _openCompanyDetail(String companyId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CompanyDetailPage(companyId: companyId),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openWorkForm() async {
    await Navigator.of(context).pushNamed(Routes.workForm);
    if (mounted) await _load();
  }

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _start = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _pickEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _end,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _end = DateTime(picked.year, picked.month, picked.day));
    }
  }

  /// 降级态「导出备份」引导：**直接接线到 `ExportBackupPage`**（P13 骨架已落盘，
  /// 主理人裁定，见 `14 §9 G-C1-D` / `14 §10 R40`）。
  void _onExportGuide() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ExportBackupPage()),
    );
  }

  // ── 渲染 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('统计')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }

    final content = Column(
      children: [
        _DimensionSelector(
          value: _dim,
          onChanged: (d) => setState(() => _dim = d),
        ),
        if (_dim == _Dim.range)
          _TimeRangeBar(
            start: _start,
            end: _end,
            invalid: _rangeInvalid,
            onPickStart: _pickStart,
            onPickEnd: _pickEnd,
          ),
        Expanded(child: _buildResults()),
      ],
    );

    if (!_degraded) return content;
    return Column(
      children: [
        _DegradedBar(onRetry: _load, onExportGuide: _onExportGuide),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildResults() {
    if (_dim == _Dim.range && _rangeInvalid) {
      return const _Hint(
        icon: Icons.event_busy_outlined,
        text: '结束日期早于开始日期，请调整后再查看',
      );
    }
    final rows = _computeRows();
    if (rows.isEmpty) {
      if (_dimUnavailable) {
        return const _Hint(icon: Icons.error_outline, text: '读取失败，请重试');
      }
      return _EmptyView(onAddWork: _openWorkForm);
    }
    final total = rows.fold<int>(0, (s, r) => s + r.amountFen);
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            // MIN-6：≥200 行惰性构建。
            itemCount: rows.length,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemBuilder: (context, i) => _RowTile(
              row: rows[i],
              totalFen: total,
              tappable: _dim == _Dim.company && rows[i].companyId != null,
              onTap: rows[i].companyId == null
                  ? null
                  : () => _openCompanyDetail(rows[i].companyId!),
            ),
          ),
        ),
        _TotalBar(totalFen: total, count: rows.length),
      ],
    );
  }
}

/// 维度分段控件（4 项，`07:575`）。
class _DimensionSelector extends StatelessWidget {
  const _DimensionSelector({required this.value, required this.onChanged});

  final _Dim value;
  final ValueChanged<_Dim> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: SegmentedButton<_Dim>(
        segments: [
          for (final d in _Dim.values)
            ButtonSegment<_Dim>(value: d, label: Text(d.label)),
        ],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

/// 时间段选择（仅"按时间段"维度可见；结束<开始 → 红字 + 不查询）。
class _TimeRangeBar extends StatelessWidget {
  const _TimeRangeBar({
    required this.start,
    required this.end,
    required this.invalid,
    required this.onPickStart,
    required this.onPickEnd,
  });

  final DateTime start;
  final DateTime end;
  final bool invalid;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;

  @override
  Widget build(BuildContext context) {
    final accent = invalid ? _kRedAmount : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _DateField(label: '开始', date: start, color: accent, onTap: onPickStart),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('至'),
              ),
              _DateField(label: '结束', date: end, color: accent, onTap: onPickEnd),
            ],
          ),
          if (invalid)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '结束日期不能早于开始日期',
                style: TextStyle(fontSize: 12, color: _kRedAmount),
              ),
            ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.date,
    required this.onTap,
    this.color,
  });

  final String label;
  final DateTime date;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: color ?? Colors.black26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Text('$label ', style: TextStyle(fontSize: 12, color: color)),
              Expanded(
                child: Text(
                  _formatDate(date),
                  style: TextStyle(fontSize: 14, color: color),
                ),
              ),
              Icon(Icons.edit_calendar_outlined, size: 16, color: color ?? Colors.black45),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单行：维度值 + 金额 + 占比条（`07:577`）。
class _RowTile extends StatelessWidget {
  const _RowTile({
    required this.row,
    required this.totalFen,
    required this.tappable,
    this.onTap,
  });

  final _Row row;
  final int totalFen;
  final bool tappable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 占比为**布局比例**（非金额运算与比较）；金额本身全程整数「分」。
    final ratio = totalFen == 0 ? 0.0 : row.amountFen / totalFen;
    final barValue = ratio < 0 ? 0.0 : (ratio > 1 ? 1.0 : ratio);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  fenToYuan(row.amountFen),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _kRedAmount,
                  ),
                ),
                if (tappable)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.chevron_right, size: 18, color: Colors.black38),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: barValue,
                minHeight: 5,
                backgroundColor: Colors.black12,
                valueColor: const AlwaysStoppedAnimation<Color>(_kRedAmount),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 合计行（固定底部，`07:578`）：合计恒 == 明细之和（AC-37）。
class _TotalBar extends StatelessWidget {
  const _TotalBar({required this.totalFen, required this.count});

  final int totalFen;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text('合计（$count 项）', style: const TextStyle(fontSize: 15, color: Colors.black54)),
              const Spacer(),
              Text(
                fenToYuan(totalFen),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _kRedAmount,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 降级态顶部告警条（D-6 / `02 §D.0.3:341`）：文案与 P01 **逐字一致**。
class _DegradedBar extends StatelessWidget {
  const _DegradedBar({required this.onRetry, required this.onExportGuide});

  final Future<void> Function() onRetry;
  final VoidCallback onExportGuide;

  @override
  Widget build(BuildContext context) {
    final fg = Colors.amber.shade900;
    return Container(
      color: Colors.amber.shade100,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '账目数字可能不完整，请勿据此对账',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text(
              '读取账目时遇到异常数据（可能有其它工具改过数据库文件）',
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: onExportGuide, child: const Text('导出备份')),
                TextButton(onPressed: () => onRetry(), child: const Text('重试')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onAddWork});
  final VoidCallback onAddWork;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bar_chart_outlined, size: 56, color: Colors.black26),
            const SizedBox(height: 16),
            // AC-P11-07：**禁用**"暂无数据"；文案逐字「这段时间还没记工」。
            const Text('这段时间还没记工',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('换个时间段或维度看看，也可以现在记一笔',
                style: TextStyle(color: Colors.black54), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAddWork,
              icon: const Icon(Icons.add_task),
              label: const Text('记一笔工作'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.black26),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: Colors.black54)),
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

// ── 日期工具（业务日期只到日，`07 §1.3`）──────────────────────────────────

DateTime _monthStart(DateTime d) => DateTime(d.year, d.month, 1);

DateTime _monthEnd(DateTime d) => DateTime(d.year, d.month + 1, 0);

String _ymKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

String _ymdKey(DateTime d) => _formatDate(d);

String _formatDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
