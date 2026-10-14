/// P07 公司详情页（Wave A 全量 · 09 §5.1~§5.6）。
///
/// **定位**：首页「点公司卡片」的落地页——用户在这里看到这家公司的
/// **剩余大字 + 应收/已收 + 工作记录 / 收款记录（全量不截断）+ 计价规则列表**，
/// 并能从这里「记一笔」/「记一笔收款」/「编辑公司」。
///
/// **数据装配（09 §5.2 / M-14）**：q1 `aggregate(companyId)`（权威剩余）
/// + q2 `listCompanies(双 true)`（公司名 + 停用/删除判定）
/// + q3 `listPricingRules(companyId, 双 true)`（规则区块 + `ruleNameById` 溯源）
/// → **q1~q3 首帧 `Future.wait` 并发**；q4/q5 两个列表由 `TabBarView` 子页
/// （`RecordListView`）**按需发起**。**全程 5 次 DB 读、零 N+1（无逐行查询）**。
///
/// **规则区块一次查询服务两用途（Q-D4 裁定）**：展示列表 = 全量集滤 `!isDeleted`
/// （**可见集 ≡ `includeDeleted: false`** 的返回集合，`database.dart:557` 的
/// `deleted_at IS NULL`）；`ruleNameById` 用**全量集（含已归档）**作历史工序名的
/// **显示兜底**（`07:354`，否则引用已归档规则的历史工作行工序名会空）。
///
/// **金额纪律**：一切金额整数「分」，显示一律 [fenToYuan]；剩余不自算，
/// 取 `aggregate()` 唯一真源；负值 → 「多收·待核对」。
///
/// **刷新（09 §10）**：`initState` 注册 [dataBus] 监听并在 `dispose` 注销；
/// 每个 `await Navigator.push(...)` 之后无条件 `if (mounted) _load();`。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../app/routes.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/pricing_rule.dart';
import '../services/enum_codec.dart';
import 'payment_form_page.dart';
import 'quick_add_sheet.dart';
import 'records_filter.dart';
import 'rule_edit_page.dart';
import 'widgets/money.dart';
import 'widgets/receivable_status.dart';
import 'widgets/record_list_view.dart';

// 金额着色（契约 §3，中国习惯：涨红跌绿）。
const Color _kRedAmount = Color(0xFFD32F2F);
const Color _kGreenAmount = Color(0xFF2E7D32);

class CompanyDetailPage extends StatefulWidget {
  const CompanyDetailPage({super.key, required this.companyId});

  final String companyId;

  @override
  State<CompanyDetailPage> createState() => _CompanyDetailPageState();
}

class _CompanyDetailPageState extends State<CompanyDetailPage>
    with SingleTickerProviderStateMixin {
  final AppDatabase _db = AppDatabase.instance;

  late final TabController _tab = TabController(length: 2, vsync: this);

  bool _loading = true;
  Object? _error;

  /// q1 权威聚合（`null` = 脏金额降级，非白屏）。
  ReceivableAggregate? _agg;

  /// q2 命中的本公司（`null` = 未命中，显示「未知公司」兜底）。
  Company? _company;

  /// `pricingRuleId → 规则名`，取 **q3 全量集（含已归档）** 作历史工序名兜底。
  Map<String, String> _ruleNameById = const {};

  /// 规则区块**展示列表** = q3 全量集滤 `!isDeleted`（≡ `includeDeleted: false`）。
  List<PricingRule> _visibleRules = const [];

  bool _reenabling = false;

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

  // ── 数据装配（09 §5.2 / §5.3）────────────────────────────────────────────

  Future<void> _load() async {
    try {
      // q2 / q3：先创建 future（并发启动），供降级分支复用。
      final companiesF = _db.listCompanies(
        includeDisabled: true, // 陷阱 2：公司名映射必须双 true
        includeDeleted: true,
      );
      final rulesF = _db.listPricingRules(
        companyId: widget.companyId,
        includeDisabled: true, // Q-D4：一次查全（含停用）
        includeDeleted: true, // 含已归档，供 ruleNameById 溯源兜底
      );

      ReceivableAggregate? agg;
      var degraded = false;
      List<Company> companies;
      List<PricingRule> rules;
      try {
        // q1~q3 首帧并发。
        final r = await Future.wait<Object>([
          _db.aggregate(widget.companyId), // q1 权威剩余
          companiesF, // q2
          rulesF, // q3
        ]);
        agg = r[0] as ReceivableAggregate;
        companies = r[1] as List<Company>;
        rules = r[2] as List<PricingRule>;
      } on FormatException {
        // 聚合坏值（脏金额）→ 只降级剩余，不白屏（§5.3 / §D.0.3）。
        degraded = true;
        final r = await Future.wait<Object>([companiesF, rulesF]);
        companies = r[0] as List<Company>;
        rules = r[1] as List<PricingRule>;
      }

      Company? company;
      for (final c in companies) {
        if (c.id == widget.companyId) {
          company = c;
          break;
        }
      }

      if (!mounted) return;
      setState(() {
        _agg = degraded ? null : agg;
        _company = company;
        _ruleNameById = {for (final r in rules) r.id: r.name};
        _visibleRules =
            rules.where((r) => !r.isDeleted).toList(growable: false);
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

  /// 停用公司「重新启用」（§5.3 / AC-P07-08）。
  ///
  /// 真实签名是 `updateCompany(Company x)`（整对象），`Company` **无 `copyWith`**
  /// → 逐字段构造，仅改 `enabled` 与 `updatedAt`（M-13①，范例 `company_page.dart:143-157`）。
  Future<void> _reenable() async {
    final c = _company;
    if (c == null || _reenabling) return;
    setState(() => _reenabling = true);
    try {
      final updated = Company(
        id: c.id,
        ledgerId: c.ledgerId,
        name: c.name,
        shortName: c.shortName,
        color: c.color,
        defaultRuleId: c.defaultRuleId,
        enabled: true,
        contact: c.contact,
        currency: c.currency,
        note: c.note,
        createdAt: c.createdAt,
        updatedAt: DateTime.now(),
        deletedAt: c.deletedAt,
      );
      await _db.updateCompany(updated);
      if (!mounted) return;
      dataBus.dataChanged(); // 广播：快记下拉 / 各展示页随之刷新
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('启用失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _reenabling = false);
    }
    if (!mounted) return;
    await _load();
  }

  // ── 动作（09 §5.5 / §8，每个 push 点 await 后无条件 _load）─────────────────

  /// P07「+ 记一笔」→ P02 秒级快记弹层（Wave D2 入口闭合），预置公司 = 本公司。
  Future<void> _openWorkNew() async {
    await QuickAddSheet.show(context, companyId: widget.companyId);
    if (!mounted) return;
    await _load();
  }

  Future<void> _openPaymentNew() async {
    // 不标临时（N-5）：P10 本体即 PaymentFormPage，已在 Wave A 交付。
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PaymentFormPage(companyId: widget.companyId),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _openCompanyEdit() async {
    // P08 = `company_page.dart` 内 `_CompanyEditDialog`（Wave D1 已交付）。M-2 裁定——目标为 P06 的跳转一律 pushNamed，
    // 保留 Routes.companies 为「活路由」（不得改命令式，否则它变新增死路由）。
    await Navigator.of(context).pushNamed(Routes.companies);
    if (!mounted) return;
    await _load();
  }

  // ── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('公司详情')),
      body: _buildBody(),
      bottomNavigationBar:
          (_loading || _error != null) ? null : _buildActionBar(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }
    return Column(
      children: [
        _buildHeader(),
        ..._buildBanners(),
        _buildRulesSection(),
        TabBar(
          controller: _tab,
          tabs: const [Tab(text: '工作记录'), Tab(text: '收款记录')],
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _buildWorkList(),
              _buildPaymentList(),
            ],
          ),
        ),
      ],
    );
  }

  // ── 头部：公司名 + 角标 + 剩余大字 + 应收/已收 + 状态角标（§5.1 / AC-P07-01/02）──

  Widget _buildHeader() {
    final company = _company;
    final agg = _agg;
    final degraded = agg == null; // 脏金额降级 → 剩余位显示「—」+ 告警
    final remaining = agg?.remaining ?? 0;

    // 公司名用全名 name（简称存在时附「（简称）」）。models/company.dart 的简称
    // getter 会截成 name 前 2 字（shortName 无 UI 可设、恒为 null），展示禁用（R-14）。
    final label = (company == null)
        ? '未知公司'
        : ((company.shortName == null || company.shortName!.isEmpty)
            ? company.name
            : '${company.name}（${company.shortName}）');

    // 第 3 种空态（页面级，`07:466` / M-11①）：应收与已收均为 0 → 零额外读（复用 q1）。
    final notStarted =
        agg != null && agg.receivable == 0 && agg.received == 0;

    final bigText = degraded ? '—' : fenToYuan(remaining);
    final bigLabel = degraded
        ? '剩余读取失败'
        : (notStarted
            ? '还没开始记账'
            : (remaining < 0 ? '多收·待核对' : '剩余工资'));

    return Column(
      children: [
        // ★ 顶部告警条（仅降级态）：`02 §D.0.3` / `07 §4.4 D3` 要求「降级 + 告警 +
        // 引导导出备份、不白屏」；本波采 `07 §4.4 D5` 退让档 + 三页一致（同 P-DEBT）。
        if (degraded) _buildDegradedBanner(),
        Container(
          width: double.infinity,
          color: const Color(0xFFFAFAFA),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (company != null) CompanyFlagChips(company: company),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                bigText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: degraded
                      ? Colors.black38
                      : (remaining < 0 ? _kRedAmount : Colors.black87),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                bigLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: degraded ? _kRedAmount : Colors.black54,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // D3 字面「已收标读取失败」：`aggregate()` 整表抛、拿不到
                  // 「应收可信」的半份结果 → 两格都标「读取失败」是唯一诚实做法。
                  _miniStat('应收', degraded ? '—' : fenToYuan(agg.receivable),
                      failed: degraded),
                  const SizedBox(width: 24),
                  _miniStat('已收', degraded ? '—' : fenToYuan(agg.received),
                      failed: degraded),
                  const Spacer(),
                  if (agg != null)
                    ReceivableStatusChip(
                      receivable: agg.receivable,
                      received: agg.received,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 降级态顶部黄色告警条（`07 §4.4 D5`）：文案 + 原因小字 + 「导出备份」/「重试」。
  Widget _buildDegradedBanner() {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 20, color: Colors.amber.shade900),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '账目数字可能不完整，请勿据此对账',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade900,
                  ),
                ),
              ),
              TextButton(
                onPressed: _onExportGuide,
                child: const Text('导出备份'),
              ),
              TextButton(
                onPressed: () => _load(), // 真重新加载（非仅 setState）
                child: const Text('重试'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(
              '读取账目时遇到异常数据（可能有其它工具改过数据库文件）',
              style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
            ),
          ),
        ],
      ),
    );
  }

  /// 降级态「导出备份」引导（P13 导出页属 Wave D → 仅给指引，不新增路由/跳转）。
  /// 文案与 P-DEBT `_onExportGuide` 逐字一致，保持三页一致。
  void _onExportGuide() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('建议先导出备份再核对：导出备份页将在后续版本上线，可先重试或稍后再试。'),
      ),
    );
  }

  Widget _miniStat(String label, String value, {bool failed = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 2),
        Text(value,
            style:
                const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        if (failed)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('读取失败',
                style: TextStyle(fontSize: 11, color: _kRedAmount)),
          ),
      ],
    );
  }

  // ── 停用 / 已删除横幅（§5.3 / AC-P07-08 / AC-P07-09）──────────────────────

  List<Widget> _buildBanners() {
    final c = _company;
    if (c == null) return const <Widget>[];
    final banners = <Widget>[];
    if (!c.enabled) {
      banners.add(_Banner(
        icon: Icons.pause_circle_outline,
        color: Colors.grey.shade700,
        text: '该公司已停用，不再出现在快记里；历史账目不受影响',
        actionLabel: _reenabling ? '启用中…' : '重新启用',
        onAction: _reenabling ? null : _reenable,
      ));
    }
    if (c.deletedAt != null) {
      banners.add(const _Banner(
        icon: Icons.archive_outlined,
        color: _kRedAmount,
        text: '该公司已删除（= 归档），账目仍计入剩余，请处理',
      ));
    }
    return banners;
  }

  // ── ★ 计价规则区块（§5.6 · Wave A ↔ Wave D1 接口契约）────────────────────

  Widget _buildRulesSection() {
    final rules = _visibleRules;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.black12)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '计价规则（${rules.length} 条）',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              // 「新建规则」入口 → 同一 D1 注入点（ruleId 为空 = 新建态）。
              TextButton(
                onPressed: () => _openRuleEditor(),
                child: const Text('新建规则'),
              ),
            ],
          ),
          if (rules.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                '还没有计价规则，点「新建规则」添加',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: rules.length,
                itemBuilder: (context, i) => _ruleRow(rules[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _ruleRow(PricingRule r) {
    final unit = r.unit?.trim() ?? '';
    final rate =
        unit.isEmpty ? fenToYuan(r.baseRate) : '${fenToYuan(r.baseRate)}/$unit';
    return InkWell(
      // 每行可点 → D1 注入点（Wave A = 占位；Wave D1 只换函数体）。
      onTap: () => _openRuleEditor(ruleId: r.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(r.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
            const SizedBox(width: 8),
            Text(EnumCodec.pricingMethod(r.method),
                style:
                    const TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(width: 12),
            Text(rate, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            Text(
              EnumCodec.enabled(r.enabled),
              style: TextStyle(
                fontSize: 12,
                color: r.enabled ? _kGreenAmount : Colors.grey.shade600,
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
          ],
        ),
      ),
    );
  }

  /// ★ 计价规则编辑的**唯一注入点**（§5.6，Wave A ↔ Wave D1 接口契约）。
  ///
  /// **Wave D1 已落地**（原为 Wave A 的 SnackBar 占位；`16 §2.1.4` 只替换函数体，
  /// 页面结构 / 行组件 / 字段绑定 / 入口位置一字不改 —— AC-P07-07c）：
  /// 命令式 push [RuleEditPage]（`ruleId == null` = 新建态）；`await` 后**无条件** `_load()`
  /// 刷新规则列表 / `ruleNameById`（M-11②，否则从规则页返回时 P07 不刷新）。
  ///
  /// 「新建规则」按钮（`:488-491`）与每行点击（`:521-523`）**共用本注入点**，两入口同时生效。
  Future<void> _openRuleEditor({String? ruleId}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RuleEditPage(
        companyId: widget.companyId, // P07 固定公司
        ruleId: ruleId, // null = 新建态
      ),
    ));
    if (!mounted) return;
    await _load(); // 规则列表 / ruleNameById 同步刷新
  }

  // ── 分段切换：两个 RecordListView（§5.4 / AC-P07-03）──────────────────────

  Widget _buildWorkList() {
    // 全量 + 滚动，**不截断**（§C.1.1 补充：禁用限量截断）。
    return RecordListView(
      key: const ValueKey<String>('p07-rlv-work'),
      filter: RecordsFilter.companyWork(widget.companyId),
      companyNameById: const {},
      ruleNameById: _ruleNameById,
      showCompanyName: false, // 公司固定 → 不重复显示
      showRuleName: true, // 工作行显示工序（草稿行金额显 —）
      // 空态 ①（07:464）：无工作记录 → + 记一笔。
      emptyTitle: '还没有工作记录',
      emptyHint: '点下方「记一笔」记下今天的工作',
      emptyActionLabel: '记一笔',
      onEmptyAction: _openWorkNew,
    );
  }

  Widget _buildPaymentList() {
    return RecordListView(
      key: const ValueKey<String>('p07-rlv-payment'),
      filter: RecordsFilter.companyPayment(widget.companyId),
      companyNameById: const {},
      showCompanyName: false,
      showRuleName: false,
      // 空态 ②（07:465）：无收款记录 → 记一笔收款 + 提示。
      emptyTitle: '还没有收款记录',
      emptyHint: '老板给钱后记一笔，剩余会自动减',
      emptyActionLabel: '记一笔收款',
      onEmptyAction: _openPaymentNew,
    );
  }

  // ── 底部动作条（§5.5 / AC-P07-06 / AC-P07-12 / AC-P07-07c）────────────────

  Widget _buildActionBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _openWorkNew,
                icon: const Icon(Icons.add),
                label: const Text('记一笔'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _openPaymentNew,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('记一笔收款'),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _openCompanyEdit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑公司',
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部提示条（停用 / 已删除横幅）。
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
        ],
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
