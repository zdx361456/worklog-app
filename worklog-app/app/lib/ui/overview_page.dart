/// 总览页（本轮核心，完整实现）。
///
/// 内容：剩余工资大字（按契约 §3 着色）→ 应收/已收合计 → **公司卡片区**
/// （公司名 / 色点 / 剩余 / 应收已收 / 状态角标 / 停用·已删角标 / 最近收款 /
/// 「全部公司」）→ **「查看全部记录」入口** → 两个「记一笔」按钮。
/// 数据源：`aggregate(null)`（全局权威）+ `aggregateByCompany()`（各公司金额）+
/// `listCompanies(includeDisabled: true, includeDeleted: true)`（元数据全集，禁裸调）+
/// `listPaymentRecords()`（最近收款，**全量 + UI 分组**，禁逐卡查询）。
/// 刷新：监听全局 [dataBus]，任何写操作后自动重载；`initState` 先加载一次；
/// 每个 push 点 `await` 后无条件 `_load()`。
///
/// **降级（`02 §D.1:363` / `02 §D.0.3:341` / `07 §4.4 D3/D5`）**：任一查询遭遇
/// **聚合坏值**（`FormatException`）时**不白屏**——顶部黄色告警条
/// （「账目数字可能不完整，请勿据此对账」+「导出备份」引导 +「重试」），
/// 金额位显示 `—` +「读取失败」，**卡片区照常渲染**（公司名/角标/最近收款等非金额信息仍可见）；
/// 非 `FormatException` 的异常照旧冒泡到整页 [_ErrorView]。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../app/routes.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/payment_record.dart';
import 'company_detail_page.dart';
import 'debt_list_page.dart';
import 'quick_add_sheet.dart';
import 'records_filter.dart';
import 'records_page.dart';
import 'widgets/money.dart';
import 'widgets/receivable_status.dart';

// 金额着色（契约 §3，中国习惯：涨红跌绿）。
const Color _kRedAmount = Color(0xFFD32F2F);
const Color _kGreenAmount = Color(0xFF2E7D32);

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;

  /// 全局聚合（q1）；**降级时为 `null`**（金额不可得）。
  ReceivableAggregate? _agg;

  /// 各公司金额（q2）；未出现的公司按全 0 处理。
  Map<String, ReceivableAggregate> _aggById = const {};

  /// 公司元数据全集（q3，含停用/归档）；空态判据用它的 `isEmpty`。
  List<Company> _companies = const [];

  /// 各公司最近一次收款日期（q4 全量 + UI 分组）。
  Map<String, DateTime> _latestPaymentByCompany = const {};

  /// 是否处于降级态（任一查询遭遇聚合坏值 `FormatException`）→ 顶部黄色告警条。
  bool _degraded = false;

  /// `aggregateByCompany()` 是否可得 → 决定**卡片金额位**是否显示 `—`/「读取失败」。
  bool _companyAmountsAvailable = true;

  /// `listPaymentRecords()` 是否可得 → 决定「从未收款」文案是否可信。
  bool _paymentsAvailable = true;

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

  /// 单查询降级包装：**只把聚合坏值（`FormatException`）降级为 `null`**，
  /// 使同批其它查询不受影响；其余异常**原样上抛** → 外层 `catch` 走整页 `_ErrorView`
  /// （保持既有行为不变）。
  Future<T?> _guard<T>(Future<T> future) async {
    try {
      return await future;
    } on FormatException {
      return null; // 脏金额 → 该查询降级为「不可用」
    }
  }

  Future<void> _load() async {
    try {
      // §6.4：4 次查询**全并发**——q1 全局剩余（权威）/ q2 各公司金额 /
      // q3 公司元数据全集（陷阱 2）/ q4 最近收款；逐个 `_guard` 做错误隔离。
      final res = await Future.wait<Object?>([
        _guard(_db.aggregate(null)), // q1
        _guard(_db.aggregateByCompany()), // q2
        _guard(_db.listCompanies(includeDisabled: true, includeDeleted: true)), // q3 陷阱2
        _guard(_db.listPaymentRecords()), // q4 最近收款（全量 + UI 分组）
      ]);
      final rawAgg = res[0];
      final rawByCompany = res[1];
      final rawCompanies = res[2];
      final rawPayments = res[3];

      final agg = rawAgg as ReceivableAggregate?;
      final aggByCompany =
          (rawByCompany as List<ReceivableAggregate>?) ?? const <ReceivableAggregate>[];
      final companies = (rawCompanies as List<Company>?) ?? const <Company>[];
      final payments = (rawPayments as List<PaymentRecord>?) ?? const <PaymentRecord>[];

      // 未出现在 aggregateByCompany() 的公司 = 全 0（database.dart:329-332）。
      final aggById = <String, ReceivableAggregate>{
        for (final a in aggByCompany)
          if (a.companyId != null) a.companyId!: a,
      };

      // 开发期断言（AC-P01-13）：全局剩余 == Σ 各公司剩余（仅 debug，release 自动关闭）。
      // **降级态前置条件不成立 → 跳过**，避免 `null` 空指针击穿。
      if (agg != null && rawByCompany != null) {
        assert(
          agg.remaining == aggById.values.fold<int>(0, (s, a) => s + a.remaining),
          'P01 断言失败：aggregate(null).remaining != Σ aggregateByCompany().remaining',
        );
      }

      // 最近收款：一次全量读 + UI 分组取每公司最大 paymentDate（M-6：禁逐卡查询）。
      final latest = <String, DateTime>{};
      for (final p in payments) {
        final cur = latest[p.companyId];
        if (cur == null || p.paymentDate.isAfter(cur)) {
          latest[p.companyId] = p.paymentDate;
        }
      }

      if (!mounted) return;
      setState(() {
        _agg = agg;
        _aggById = aggById;
        _companies = companies;
        _latestPaymentByCompany = latest;
        _degraded =
            rawAgg == null || rawByCompany == null || rawCompanies == null || rawPayments == null;
        _companyAmountsAvailable = rawByCompany != null;
        _paymentsAvailable = rawPayments != null;
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

  // ── push 点（§8/§10：每个 `await` 后无条件 `_load()`）────────────────────────

  Future<void> _openDebtList() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CompanyDebtListPage()),
    );
    if (mounted) await _load();
  }

  Future<void> _openReceivableDrill() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RecordsPage(
          filter: RecordsFilter.receivableDrill,
          title: '应收明细',
          showAggregateHeader: true,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openReceivedDrill() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RecordsPage(
          filter: RecordsFilter.receivedDrill,
          title: '收款明细',
          showAggregateHeader: true,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openAllRecords() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RecordsPage(
          filter: RecordsFilter.all,
          title: '全部记录',
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openCompanyDetail(Company c) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CompanyDetailPage(companyId: c.id),
      ),
    );
    if (mounted) await _load();
  }

  /// P01「全部公司」→ P06。**M-2**：目标为 P06 的跳转一律 `pushNamed`，
  /// 保留 `Routes.companies` 为活路由（不得改命令式）。
  Future<void> _openAllCompanies() async {
    await Navigator.of(context).pushNamed(Routes.companies);
    if (mounted) await _load();
  }

  /// P01 空态主按钮 → P06 公司列表（P08 = `company_page.dart` 内 `_CompanyEditDialog`，Wave D1 已交付）。
  Future<void> _goCreateCompany() async {
    // 出口沿用命名路由（M-2）：`Routes.companies` 为活路由。
    await Navigator.of(context).pushNamed(Routes.companies);
    if (mounted) await _load();
  }

  /// P01「记一笔工作」→ P02 秒级快记弹层（Wave D2 入口闭合）。
  Future<void> _openWorkForm() async {
    await QuickAddSheet.show(context);
    if (mounted) await _load();
  }

  /// P01「记一笔收款」→ P10 收款登记（`PaymentFormPage`）。
  ///
  /// **本就不属弹层替换范围**（`02 §A.3:114` N-4/N-5：该入口指向 P10，非 P02）。
  Future<void> _openPaymentForm() async {
    await Navigator.of(context).pushNamed(Routes.paymentForm);
    if (mounted) await _load();
  }

  /// 降级态「导出备份」引导：**不新增路由、不 push 任何页面**（P13 属 Wave D）；
  /// 与 P-DEBT 同款 SnackBar 指引。
  void _onExportGuide() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('建议先导出备份再核对：导出备份页将在后续版本上线，可先重试或稍后再试。'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('看板')),
      // 刷新：ListenableBuilder 负责「广播驱动的重建」；真正的「重载」由
      // initState 注册的 dataBus 监听（_load→setState）完成——二者配合，
      // 保证任何写操作后总览数字与卡片都取到最新值。
      body: ListenableBuilder(
        listenable: dataBus,
        builder: (context, _) => _buildBody(),
      ),
      // P01「+ 记一笔」= 右下悬浮主按钮（`02:392` / `07:209` / `07:226`）。
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openWorkForm,
        icon: const Icon(Icons.add_task),
        label: const Text('记一笔工作'),
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

    // AC-P01-07：判据用**含停用/归档**的全集，避免唯一公司被停用后落进「无公司」空态。
    final content = _companies.isEmpty
        ? _EmptyView(onCreateCompany: _goCreateCompany)
        : _buildList();

    if (!_degraded) return content;
    // 降级态：顶部黄色告警条 + 正常内容（卡片照常渲染，金额位标「读取失败」）。
    return Column(
      children: [
        _DegradedBar(onRetry: _load, onExportGuide: _onExportGuide),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildList() {
    final agg = _agg;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _RemainingCard(agg: agg, onTap: _openDebtList),
        const SizedBox(height: 12),
        _ReceivableReceivedRow(
          agg: agg,
          onReceivableTap: _openReceivableDrill,
          onReceivedTap: _openReceivedDrill,
        ),
        const SizedBox(height: 16),
        _CompanyCardSection(
          companies: _companies,
          aggById: _aggById,
          amountsAvailable: _companyAmountsAvailable,
          latestPaymentByCompany: _latestPaymentByCompany,
          paymentsAvailable: _paymentsAvailable,
          onCompanyTap: _openCompanyDetail,
          onAllCompaniesTap: _openAllCompanies,
        ),
        const SizedBox(height: 12),
        _ViewAllCard(onTap: _openAllRecords),
        const SizedBox(height: 20),
        _ActionButtons(onPaymentTap: _openPaymentForm),
        const SizedBox(height: 20),
        const _VersionNote(),
      ],
    );
  }
}

/// 降级态顶部告警条（`02 §D.0.3:341` / `07 §4.4 D5`）：黄条 + 导出备份引导 + 重试。
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

/// AC-P01-03：剩余工资大字 → 公司欠款列表（P-DEBT）。降级时 `agg == null` → `—`。
class _RemainingCard extends StatelessWidget {
  const _RemainingCard({required this.agg, required this.onTap});
  final ReceivableAggregate? agg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final available = agg != null;
    final remaining = agg?.remaining ?? 0;
    final color = remaining > 0
        ? _kRedAmount
        : (remaining < 0 ? _kGreenAmount : Colors.grey.shade600);
    return Card(
      clipBehavior: Clip.antiAlias, // 让 InkWell 水波被 Card 裁剪
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            children: [
              const Text('剩余工资', style: TextStyle(fontSize: 15, color: Colors.black54)),
              const SizedBox(height: 8),
              if (available)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    fenToYuan(remaining),
                    style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: color),
                  ),
                )
              else
                const Text(
                  '—',
                  style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
              if (available && remaining < 0)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('（多收）', style: TextStyle(fontSize: 13, color: Colors.black45)),
                ),
              if (!available)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('读取失败', style: TextStyle(fontSize: 13, color: Colors.black45)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// AC-P01-04/05：点「应收合计」→ 工作记录（不含草稿）；点「已收合计」→ 收款记录。
class _ReceivableReceivedRow extends StatelessWidget {
  const _ReceivableReceivedRow({
    required this.agg,
    required this.onReceivableTap,
    required this.onReceivedTap,
  });
  final ReceivableAggregate? agg;
  final VoidCallback onReceivableTap;
  final VoidCallback onReceivedTap;

  @override
  Widget build(BuildContext context) {
    final unavailable = agg == null;
    return Row(
      children: [
        Expanded(
          child: _MiniStat(
            label: '应收合计',
            value: unavailable ? '—' : fenToYuan(agg!.receivable),
            color: _kRedAmount,
            unavailable: unavailable,
            onTap: onReceivableTap,
          ),
        ),
        Expanded(
          child: _MiniStat(
            label: '已收合计',
            value: unavailable ? '—' : fenToYuan(agg!.received),
            color: _kGreenAmount,
            unavailable: unavailable,
            onTap: onReceivedTap,
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
    required this.onTap,
    this.unavailable = false,
  });
  final String label;
  final String value;
  final Color color;
  final VoidCallback onTap;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.black54)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: color),
            ),
          ),
          if (unavailable)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('读取失败', style: TextStyle(fontSize: 11, color: Colors.black45)),
            ),
        ],
      ),
    );
  }
}

/// P01 公司卡片区（Wave A **从零新增**，09 §6.3；Q-D11：非"改造既有卡片"）。
///
/// **禁逐卡查询**（M-6）：金额来自 `aggregateByCompany()`（q2），最近收款来自
/// 一次全量 `listPaymentRecords()` + UI 分组（q4）；本组件不做任何 IO。
/// **降级**：`amountsAvailable == false` 时各卡金额位显示 `—`，但卡片仍照常渲染。
class _CompanyCardSection extends StatelessWidget {
  const _CompanyCardSection({
    required this.companies,
    required this.aggById,
    required this.amountsAvailable,
    required this.latestPaymentByCompany,
    required this.paymentsAvailable,
    required this.onCompanyTap,
    required this.onAllCompaniesTap,
  });

  final List<Company> companies;
  final Map<String, ReceivableAggregate> aggById;
  final bool amountsAvailable;
  final Map<String, DateTime> latestPaymentByCompany;
  final bool paymentsAvailable;
  final void Function(Company company) onCompanyTap;
  final VoidCallback onAllCompaniesTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final c in companies)
          _CompanyCard(
            company: c,
            // 金额不可得（降级）→ null（卡片金额位显 `—`，不伪造 0）。
            agg: amountsAvailable
                ? (aggById[c.id] ??
                    ReceivableAggregate(
                      companyId: c.id,
                      receivable: 0,
                      received: 0,
                      remaining: 0,
                    ))
                : null,
            latestPaymentDate: latestPaymentByCompany[c.id],
            paymentsAvailable: paymentsAvailable,
            onTap: () => onCompanyTap(c),
          ),
        const SizedBox(height: 4),
        // AC-P01-08 / 07:229：P06 的第一条入边（M-2：保留命名路由 `Routes.companies`）。
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: const Icon(Icons.business_outlined),
            title: const Text('全部公司'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onAllCompaniesTap,
          ),
        ),
      ],
    );
  }
}

/// 单张公司卡片（09 §6.3 元素表）。`agg == null` = 金额不可得（降级）。
class _CompanyCard extends StatelessWidget {
  const _CompanyCard({
    required this.company,
    required this.agg,
    required this.latestPaymentDate,
    required this.paymentsAvailable,
    required this.onTap,
  });

  final Company company;
  final ReceivableAggregate? agg;
  final DateTime? latestPaymentDate;
  final bool paymentsAvailable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = agg; // 局部变量（可空提升）
    final amountsAvailable = a != null;
    final remaining = a?.remaining ?? 0;
    final remainingColor = remaining > 0
        ? _kRedAmount
        : (remaining < 0 ? _kGreenAmount : Colors.grey.shade600);
    // 07:241：应收/已收全 0 → 「还没记过账」（零额外读，复用 q2 派生值）。
    // 金额不可得时**不显示**（无法判定，避免误导）。
    final neverRecorded = a != null && a.receivable == 0 && a.received == 0;
    // 07:223-224：最近收款行**仅在 remaining > 0** 时显示（金额不可得时退化为「有日期即显示」）。
    final showLastPayment = amountsAvailable && remaining > 0;
    // 07:218「公司名 + 短名」：概览/列表必须用**全名**（模型里的短名缩写 getter 会截成
    // 名称前 2 字，两家前两字相同的公司无法区分；shortName 无 UI 可设、恒为 null）。R-14
    final label = (company.shortName == null || company.shortName!.isEmpty)
        ? company.name
        : '${company.name}（${company.shortName}）';

    String? paymentNote;
    if (amountsAvailable) {
      if (showLastPayment) {
        paymentNote = latestPaymentDate == null
            ? (paymentsAvailable ? '从未收款' : null)
            : _lastPaymentText(latestPaymentDate!, withDays: true);
      }
    } else if (latestPaymentDate != null) {
      // 降级：金额不可得，但「最近收款日期」属非金额信息 → 显示日期（不带「已 X 天」）。
      paymentNote = _lastPaymentText(latestPaymentDate!, withDays: false);
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap, // AC-P01-06：点卡片 → P07 公司详情（U-1 直接验收点）
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      // 07 §1.4：色点补 alpha 0xFF（**禁** Color(company.color)）。
                      color: Color(0xFF000000 | company.color),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 公司名用全名 name（简称存在时附「（简称）」）。短名缩写 getter 会截成前 2 字，展示禁用（R-14）。
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (a != null) ...[
                    const SizedBox(width: 8),
                    ReceivableStatusChip(
                      receivable: a.receivable,
                      received: a.received,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (amountsAvailable && remaining < 0) ...[
                    const Text('多收', style: TextStyle(fontSize: 13, color: Colors.black45)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        amountsAvailable ? fenToYuan(remaining) : '—',
                        style: TextStyle(
                          fontSize: 28, // ≥28sp（07:220）
                          fontWeight: FontWeight.bold,
                          color: amountsAvailable ? remainingColor : Colors.grey,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                a == null
                    ? '读取失败'
                    : '${fenToYuan(a.receivable)} · ${fenToYuan(a.received)}',
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
              if (neverRecorded)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text('还没记过账', style: TextStyle(fontSize: 12, color: Colors.black45)),
                ),
              if (paymentNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    paymentNote,
                    style: const TextStyle(fontSize: 12, color: Colors.black45),
                  ),
                ),
              const SizedBox(height: 6),
              CompanyFlagChips(company: company),
            ],
          ),
        ),
      ),
    );
  }
}

/// AC-P01-09：全量记录入口（双 tab、**不截断**、`includeDraft: true`）。
class _ViewAllCard extends StatelessWidget {
  const _ViewAllCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.receipt_long_outlined),
        title: const Text('查看全部记录'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// P01 底部动作区：仅保留「记一笔收款」（工作按钮已上移为右下 FAB，见 `Scaffold.floatingActionButton`）。
class _ActionButtons extends StatelessWidget {
  const _ActionButtons({required this.onPaymentTap});
  final VoidCallback onPaymentTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: onPaymentTap,
            icon: const Icon(Icons.payments_outlined),
            label: const Text('记一笔收款'),
          ),
        ),
      ],
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onCreateCompany});
  final VoidCallback onCreateCompany;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.business_outlined, size: 56, color: Colors.black26),
            const SizedBox(height: 16),
            // AC-P01-11：标题「还没有公司」；按钮文案沿用 07:240「先建一个公司」（两处不同字）。
            const Text('还没有公司', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('添加公司后即可开始记录工作与收款',
                style: TextStyle(color: Colors.black54), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            // P08 = `company_page.dart` 内 `_CompanyEditDialog`（Wave D1 已交付）；出口沿用 `pushNamed(Routes.companies)`（M-2）。
            FilledButton.icon(
              onPressed: onCreateCompany,
              icon: const Icon(Icons.add_business),
              label: const Text('先建一个公司'),
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
            const Text('数据加载失败', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center,
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

class _VersionNote extends StatelessWidget {
  const _VersionNote();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '本版仅支持「加班」倍率（×1.5）；周末/节假日倍率自动判定、导入导出、云同步为后续版本。',
      style: TextStyle(fontSize: 12, color: Colors.black45),
      textAlign: TextAlign.center,
    );
  }
}

String _formatDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// 「最近收款」文案。
///
/// **MIN 修复**：`d` 为**未来日期**（`今天 − d < 0`）时**只返回**「最近收款 YYYY-MM-DD」，
/// **不显示**「已 X 天未收款」半句（不用 `abs()`、不显示 0 天，避免制造新的误导）。
String _lastPaymentText(DateTime d, {required bool withDays}) {
  final base = '最近收款 ${_formatDate(d)}';
  if (!withDays) return base;
  final days = _daysSince(d);
  if (days < 0) return base; // 未来日期 → 去掉「已 X 天未收款」
  return '$base · 已 $days 天未收款';
}

/// `今天 − 收款日` 的**整数天**（按日历日归一，避免时分秒/夏令时误差）。
int _daysSince(DateTime d) {
  final now = DateTime.now();
  final from = DateTime(d.year, d.month, d.day);
  final to = DateTime(now.year, now.month, now.day);
  return to.difference(from).inDays;
}
