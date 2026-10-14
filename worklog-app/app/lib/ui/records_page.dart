/// 明细页（Wave A 参数化 · 09 §4.3 / §4.5）。
///
/// **定位**：`RecordsPage` 是「页面壳」——Scaffold + AppBar（可选 TabBar / 筛选 chips）
/// + 可选顶部合计行 + `RecordListView`；**列表与删除逻辑下沉到
/// [RecordListView]**（列表主源）。
///
/// **三种入口**（均由构造参数决定；`title` 为**必填**，见下）：
/// - 「全部记录」：`RecordsPage(filter: RecordsFilter.all, title: '全部记录')`（双 tab，全量含草稿）
/// - 「应收下钻」：`RecordsPage(filter: receivableDrill, title: '应收明细', showAggregateHeader: true)`
/// - 「已收下钻」：`RecordsPage(filter: receivedDrill, title: '收款明细', showAggregateHeader: true)`
///
/// **`title` 为何在 Wave A2 改为必填**：它原先带默认值 `'明细'`，唯一理由是"与**当时的**
/// 底栏第 2 个 Tab 标签保持一致"——`09-WaveA-实现设计.md:234` 设计注释原文已预言：
/// 「与本波 MainShell 第 2 个 Tab 标签「明细」一致；**A2 换 Tab 后该默认值随之消失**」。
/// Wave A2 已把第 2 个 Tab 换成「日历」，且本页**最后一处无参构造点**
/// （`main.dart` 的 `case Routes.records` → `const RecordsPage()`）**已随死路由同批删除**
/// → 默认值不再有任何调用方依赖，按设计原意**移除**，改为必填，
/// 以免后续"漏传 `title` 即得一个语义错误的标题"。
///
/// **金额纪律**：整数「分」；显示一律 [fenToYuan]；顶部合计取 `aggregate()`（单一真源），
/// 禁本地求和冒充真值（`02 §C.1.4` 陷阱 2）。
///
/// **公司名映射**：`listCompanies(includeDisabled: true, includeDeleted: true)`（陷阱 2）。
///
/// **刷新**：`initState` 注册 [dataBus] 监听，`dispose` 注销；push 返回后无条件 `_load()`。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/pricing_rule.dart';
import 'payment_form_page.dart';
import 'quick_add_sheet.dart';
import 'records_filter.dart';
import 'widgets/money.dart';
import 'widgets/record_list_view.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

class RecordsPage extends StatefulWidget {
  /// `title` **必填**（Wave A2 起）；其余参数可选 + `const` 默认。
  /// 原先的无参构造点（`main.dart` 的 `case Routes.records`）已随死路由同批删除，
  /// 详见类文档「`title` 为何在 Wave A2 改为必填」。
  const RecordsPage({
    super.key,
    this.filter = RecordsFilter.all, // both + includeDraft:true ≡ 现状两列表默认口径
    required this.title, // Wave A2 起必填（原默认 '明细' 随 Tab 变更消失）
    this.showAggregateHeader = false, // 下钻列表才为 true
  });

  final RecordsFilter filter;
  final String title;
  final bool showAggregateHeader;

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage>
    with SingleTickerProviderStateMixin {
  final AppDatabase _db = AppDatabase.instance;

  late final TabController _tab = TabController(length: 2, vsync: this);

  /// 筛选实例态：由构造参数重建；chips 交互在本实例内保留；跨次进入不记忆。
  late RecordsFilter _filter = widget.filter;

  bool _loading = true;
  Object? _error;
  Map<String, String> _nameById = const {};
  Map<String, String> _ruleNameById = const {};
  ReceivableAggregate? _headerAgg;
  bool _headerDegraded = false;

  @override
  void initState() {
    super.initState();
    dataBus.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataBus.removeListener(_load);
    _tab.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(RecordsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filter != widget.filter ||
        oldWidget.showAggregateHeader != widget.showAggregateHeader) {
      _filter = widget.filter;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      // 陷阱 2：公司名映射必须双 true；规则全表查一次供工作行显示工序。
      final results = await Future.wait<Object>([
        _db.listCompanies(includeDisabled: true, includeDeleted: true),
        _db.listPricingRules(includeDisabled: true, includeDeleted: true),
      ]);
      final companies = results[0] as List<Company>;
      final rules = results[1] as List<PricingRule>;

      ReceivableAggregate? agg;
      var degraded = false;
      if (widget.showAggregateHeader) {
        try {
          agg = await _db.aggregate(_filter.companyId); // 单一真源
        } on FormatException {
          degraded = true; // 聚合坏值降级：合计显 —，列表仍可渲染
        }
      }

      if (!mounted) return;
      setState(() {
        _nameById = {for (final c in companies) c.id: c.name};
        _ruleNameById = {for (final r in rules) r.id: r.name};
        _headerAgg = agg;
        _headerDegraded = degraded;
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

  // ── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showTabs = _filter.scope == RecordsScope.both;
    final chips = _chips();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: showTabs
            ? TabBar(
                controller: _tab,
                tabs: const [Tab(text: '工作'), Tab(text: '收款')],
              )
            : (chips.isEmpty
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(48),
                    child: SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        children: chips,
                      ),
                    ),
                  )),
      ),
      body: _buildBody(showTabs),
    );
  }

  Widget _buildBody(bool showTabs) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }
    return Column(
      children: [
        _aggregateHeader(),
        Expanded(
          child: showTabs
              ? TabBarView(
                  controller: _tab,
                  children: [
                    _buildList(RecordsScope.workOnly),
                    _buildList(RecordsScope.paymentOnly),
                  ],
                )
              : _buildList(_filter.scope),
        ),
      ],
    );
  }

  /// 顶部合计：仅下钻（`showAggregateHeader: true`）且非双 tab 时渲染；
  /// 数值取 `aggregate(_filter.companyId)`，禁本地求和当真值。
  Widget _aggregateHeader() {
    final scope = _filter.scope;
    if (!widget.showAggregateHeader || scope == RecordsScope.both) {
      return const SizedBox.shrink();
    }
    final label = scope == RecordsScope.workOnly ? '应收合计（不含草稿）' : '已收合计';
    final degraded = _headerDegraded || _headerAgg == null;
    final value = degraded
        ? '—'
        : (scope == RecordsScope.workOnly
            ? fenToYuan(_headerAgg!.receivable)
            : fenToYuan(_headerAgg!.received));
    return Container(
      width: double.infinity,
      color: const Color(0xFFF5F5F5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: Colors.black54)),
          const Spacer(),
          if (_headerDegraded)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text('合计读取失败',
                  style: TextStyle(fontSize: 12, color: _kRedAmount)),
            ),
          Text(value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// 筛选 chips（`02 §C.1.3` 可删除）：
  /// - `workOnly` 且 `includeDraft == false` → 「仅计应收（不含草稿）」；
  ///   点 × → `includeDraft: true`，文案变「含草稿（不计数）」。
  /// - `companyId == null` → 「全部公司」（仅作展示）。
  /// - `hasDateRange` → 「YYYY-MM-DD ~ YYYY-MM-DD」。
  List<Widget> _chips() {
    final chips = <Widget>[];
    if (_filter.scope == RecordsScope.workOnly) {
      final showDraft = _filter.includeDraft;
      chips.add(InputChip(
        label: Text(showDraft ? '含草稿（不计数）' : '仅计应收（不含草稿）'),
        onPressed: () =>
            setState(() => _filter = _filter.copyWith(includeDraft: !showDraft)),
        onDeleted: () =>
            setState(() => _filter = _filter.copyWith(includeDraft: !showDraft)),
      ));
    }
    final cid = _filter.companyId;
    if (cid == null) {
      chips.add(const Chip(label: Text('全部公司')));
    } else {
      chips.add(InputChip(
        label: Text(_nameById[cid] ?? '指定公司'),
        onPressed: () =>
            setState(() => _filter = _filter.copyWith(clearCompanyId: true)),
        onDeleted: () =>
            setState(() => _filter = _filter.copyWith(clearCompanyId: true)),
      ));
    }
    if (_filter.hasDateRange) {
      chips.add(InputChip(
        label: Text(_dateRangeText()),
        onPressed: () =>
            setState(() => _filter = _filter.copyWith(clearDateRange: true)),
        onDeleted: () =>
            setState(() => _filter = _filter.copyWith(clearDateRange: true)),
      ));
    }
    return chips;
  }

  Widget _buildList(RecordsScope scope) {
    final isWork = scope == RecordsScope.workOnly;
    final f = _filter.copyWith(scope: scope);
    final drill = widget.showAggregateHeader;
    final emptyTitle = isWork
        ? (drill ? '还没有已确认的工作记录' : '还没有工作记录')
        : '还没有收款记录';
    final emptyHint = drill
        ? null
        : (isWork
            ? '去「看板」页点「记一笔工作」开始记录'
            : '去「看板」页点「记一笔收款」开始记录');
    final emptyActionLabel = drill ? (isWork ? '记一笔工作' : '记一笔收款') : null;
    final onEmptyAction = drill ? () => _handleEmptyAction(isWork, f) : null;

    return RecordListView(
      // 稳定 key（不随 filter 变化）→ chips 变更走子组件 didUpdateWidget，不重建 State。
      key: ValueKey<String>('rlv-${scope.name}'),
      filter: f,
      companyNameById: _nameById,
      ruleNameById: _ruleNameById,
      showCompanyName: true,
      showRuleName: true,
      emptyTitle: emptyTitle,
      emptyHint: emptyHint,
      emptyActionLabel: emptyActionLabel,
      onEmptyAction: onEmptyAction,
    );
  }

  /// 空态主按钮：工作分支 → P02 秒级快记弹层；收款分支 → P10 收款登记。返回后无条件 `_load()`。
  Future<void> _handleEmptyAction(bool isWork, RecordsFilter f) async {
    if (isWork) {
      // 预置公司 = f.companyId（可空 → 弹层走默认，AC-P02-10）。
      await QuickAddSheet.show(context, companyId: f.companyId);
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PaymentFormPage(companyId: f.companyId),
        ),
      );
    }
    if (!mounted) return;
    await _load();
  }

  String _dateRangeText() {
    final s = _filter.startDate;
    final e = _filter.endDate;
    final a = s == null ? '…' : _fmtDate(s);
    final b = e == null ? '…' : _fmtDate(e);
    return '$a ~ $b';
  }
}

String _fmtDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
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
