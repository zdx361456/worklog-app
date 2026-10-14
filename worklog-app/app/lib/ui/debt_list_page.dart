/// P-DEBT 公司欠款列表页（「谁还欠我钱」，Wave A · 09 §7）。
///
/// **入口**：P01 顶部「剩余工资」大数字点入（`overview_page.dart` → `CompanyDebtListPage()`，
/// 无参构造，入口不携带筛选）。**出口**：行点击 → P07 `CompanyDetailPage(companyId:)`；
/// 返回 → P01（P01 侧 `await push` 后无条件 `_load()`）。
///
/// **数据装配（09 §7.2，3 读全并发，零 N+1）**：
/// - q1 `aggregateByCompany()` —— 各公司应收/已收/剩余（一次查完）。
/// - q2 `listCompanies(includeDisabled: true, includeDeleted: true)` —— 公司名 + 停用/归档
///   角标（**陷阱 2**：必须双 `true`，否则停用/归档公司显示「未知公司」；**禁裸调** `listCompanies`（不带参数））。
/// - q3 `aggregate(null)` —— **仅用于口径标注 + 恒等式断言**，**不当作「欠款合计」**。
///
/// **「欠款合计」独立口径（09 §7.3 / AC-PDBT-05 / `02 §C.1.2` 口径禁令）**：
/// - 列表**仅含 `remaining > 0`** 的公司，按 `remaining` **倒序**（AC-PDBT-02）。
///   「欠款合计」= **Σ 列表内 remaining**，语义 = 「别人总共还欠我多少」。
/// - 「多收合计的绝对值」= Σ `remaining < 0` 公司的 `(-remaining)`。
/// - **禁**把「欠款合计」当作 `aggregate(null).remaining`（后者是**扣除多收后的净值**）。
///   两者唯一关系式（开发期断言）：`欠款合计 − |多收合计| == aggregate(null).remaining`。
///   > 自造数验算：A 欠 ¥10.00 / B 欠 ¥5.00 / C 多收 ¥2.00 →
///   > `1500 − 200 = 1300`，应等于 `aggregate(null).remaining`（分）。
///
/// **多收核对视图**：仅在「无欠款且有 `remaining < 0`」的空态下，点「点此核对」就地
/// 切换 `_showAll`（**无跳转**）。该视图**行集 = `remaining < 0`（与提示计数同口径，M-13④ /
/// `§5.2 E-5` 裁定）**，按 `remaining` **升序**；`remaining == 0`（已结清）**两处均不显示**。
/// `_showAll` 仅存在于**页面实例内**，跨次进入不记忆（AC-PDBT-08）。
///
/// **金额纪律**：一切金额为整数「分」，比较/相减全用 `int`；显示一律 [fenToYuan]；**无浮点**。
///
/// **刷新**：`initState` → `dataBus.addListener(_load); _load();`；`dispose` →
/// `dataBus.removeListener(_load);`（成对，09 §10）。本页只读，除降级态「导出备份」引导外无写。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import 'company_detail_page.dart';
import 'widgets/money.dart';
import 'widgets/receivable_status.dart';

const Color _kRedAmount = Color(0xFFD32F2F);
const Color _kGreenAmount = Color(0xFF2E7D32);

class CompanyDebtListPage extends StatefulWidget {
  /// 无参构造（09 §7.1：入口不携带筛选；`_showAll` 为页内状态）。
  const CompanyDebtListPage({super.key});

  @override
  State<CompanyDebtListPage> createState() => _CompanyDebtListPageState();
}

/// 单行债务实体：公司元数据 + 该公司聚合（不可变）。
class _DebtRow {
  const _DebtRow({required this.company, required this.agg});

  final Company company;
  final ReceivableAggregate agg;
}

class _CompanyDebtListPageState extends State<CompanyDebtListPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;

  /// 整页错误（非 `FormatException` 的致命错误）→ 全屏错误态。
  Object? _error;

  /// q1 / q3 遭遇 `FormatException`（脏金额）→ 降级呈现（不白屏，AC-PDBT-07）。
  bool _degraded = false;

  /// 欠款行（`remaining > 0`，倒序）。
  List<_DebtRow> _rows = const [];

  /// 多收行（`remaining < 0`，升序）。
  List<_DebtRow> _overpaidRows = const [];

  /// 「欠款合计」= Σ 列表内 remaining（分）。
  int _debtTotal = 0;

  /// 「多收合计的绝对值」= Σ (-remaining)（分）。
  int _overpaidAbs = 0;

  /// 全局聚合（q3）；仅用于口径标注 + 恒等式断言，**不当欠款合计**。
  ReceivableAggregate? _globalAgg;

  /// 多收核对视图开关（页内状态，跨次进入不记忆，AC-PDBT-08）。
  bool _showAll = false;

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

  /// 单查询降级包装：仅脏金额 `FormatException` 降级为 `null`（不使整批并发查询抛出）；
  /// 其余异常原样上抛 → 外层 `catch` 走整页错误态。
  Future<Object?> _degradeOnFormat(Future<Object?> future) async {
    try {
      return await future;
    } on FormatException {
      return null;
    }
  }

  Future<void> _load() async {
    try {
      // 09 §7.2：3 读全并发。
      final res = await Future.wait<Object?>([
        _degradeOnFormat(_db.aggregateByCompany()), // q1 各公司聚合
        _db.listCompanies(includeDisabled: true, includeDeleted: true), // q2 陷阱2：双 true
        _degradeOnFormat(_db.aggregate(null)), // q3 仅口径标注 / 恒等式
      ]);

      if (!mounted) return;

      final rawAgg = res[0];
      final companies = res[1] as List<Company>;
      final globalAgg = res[2] as ReceivableAggregate?;
      final degraded = rawAgg == null;
      final aggByCompany =
          degraded ? const <ReceivableAggregate>[] : (rawAgg as List<ReceivableAggregate>);

      final byId = <String, Company>{for (final c in companies) c.id: c};

      // 行集：仅 remaining > 0（倒序）/ remaining < 0（升序）；remaining == 0 两处都不显示。
      final rows = <_DebtRow>[];
      final overpaid = <_DebtRow>[];
      for (final a in aggByCompany) {
        final cid = a.companyId;
        final c = cid == null ? null : byId[cid];
        if (c == null) continue; // 双 true 下不应发生；防御性跳过（不伪造「未知公司」）
        final row = _DebtRow(company: c, agg: a);
        if (a.remaining > 0) {
          rows.add(row);
        } else if (a.remaining < 0) {
          overpaid.add(row);
        }
      }
      rows.sort((a, b) => b.agg.remaining.compareTo(a.agg.remaining)); // AC-PDBT-02
      overpaid.sort((a, b) => a.agg.remaining.compareTo(b.agg.remaining)); // 最负在前

      final debtTotal = rows.fold<int>(0, (s, r) => s + r.agg.remaining);
      final overpaidAbs = overpaid.fold<int>(0, (s, r) => s + (-r.agg.remaining));

      // 开发期断言（AC-PDBT-05）：欠款合计 − |多收合计| == 全局剩余。
      // 自造数：A 欠 1000 / B 欠 500 / C 多收 200 → 1500 − 200 == 1300（= 全局剩余）。
      if (globalAgg != null) {
        assert(
          debtTotal - overpaidAbs == globalAgg.remaining,
          'P-DEBT 恒等式被破坏：欠款合计 − 多收合计的绝对值 != aggregate(null).remaining',
        );
      }

      setState(() {
        _rows = rows;
        _overpaidRows = overpaid;
        _debtTotal = debtTotal;
        _overpaidAbs = overpaidAbs;
        _globalAgg = globalAgg;
        _degraded = degraded;
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

  // ── push 点（§8/§10：`await` 后无条件 `_load()`）─────────────────────────────

  Future<void> _openDetail(Company company) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CompanyDetailPage(companyId: company.id),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// 降级态「导出备份」引导（P13 导出备份页尚未交付 → 仅给指引，不新增跳转接口）。
  void _onExportGuide() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('建议先导出备份再核对：导出备份页将在后续版本上线，可先重试或稍后再试。'),
      ),
    );
  }

  // ── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('谁还欠我钱')),
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
    if (_degraded) {
      return _DegradedView(onRetry: _load, onExportGuide: _onExportGuide);
    }
    // 「多收核对」是**空态（无欠款）专属**视图；一旦出现欠款行，必须回到欠款列表。
    if (_showAll && _rows.isEmpty && _overpaidRows.isNotEmpty) {
      return _buildOverpaid();
    }
    return _buildDebt();
  }

  /// 欠款列表视图（`remaining > 0`，倒序）。
  Widget _buildDebt() {
    final rows = _rows;
    return Column(
      children: [
        _HeaderLine(
          text: '共 ${rows.length} 家公司 · 欠款合计 ${fenToYuan(_debtTotal)}',
        ),
        const _CaliberNote(),
        if (rows.isEmpty)
          Expanded(child: _EmptyDebtView(
            overpaidCount: _overpaidRows.length,
            onCheckOverpaid: () => setState(() => _showAll = true),
          ))
        else
          Expanded(
            child: ListView.builder(
              // AC-PDBT-09：≥100 家惰性构建。
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                return _DebtRowTile(
                  row: row,
                  onTap: () => _openDetail(row.company),
                );
              },
            ),
          ),
        _footerCaliber(),
      ],
    );
  }

  /// 多收核对视图（`remaining < 0`，升序；与提示计数同口径）。
  Widget _buildOverpaid() {
    final rows = _overpaidRows;
    return Column(
      children: [
        _HeaderLine(
          text: '多收核对 · 共 ${rows.length} 家 · 多收合计 ${fenToYuan(_overpaidAbs)}',
        ),
        const _CaliberNote(),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final row = rows[i];
              return _DebtRowTile(
                row: row,
                onTap: () => _openDetail(row.company),
              );
            },
          ),
        ),
        _footerCaliber(),
      ],
    );
  }

  /// 口径标注底行（09 §7.3：底部一行「看板剩余（已扣多收）：¥X」）。
  Widget _footerCaliber() {
    final g = _globalAgg;
    if (g == null) return const SizedBox.shrink();
    return Column(
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '看板剩余（已扣多收）：${fenToYuan(g.remaining)}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ),
      ],
    );
  }
}

/// 顶部一行「共 N 家公司 · 欠款合计 ¥X」。
class _HeaderLine extends StatelessWidget {
  const _HeaderLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 口径差异标注（AC-PDBT-05：页面须显式标注「欠款合计」≠ 看板「剩余工资」）。
class _CaliberNote extends StatelessWidget {
  const _CaliberNote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '欠款合计 ≠ 看板「剩余工资」（看板扣除多收）',
          style: TextStyle(fontSize: 12, color: Colors.black45),
        ),
      ),
    );
  }
}

/// 债务行：色点 + 公司全名（简称存在时附「（简称）」）+ 状态角标 + 停用/归档角标
/// + 「应收 − 已收 = 剩余」。
class _DebtRowTile extends StatelessWidget {
  const _DebtRowTile({required this.row, required this.onTap});

  final _DebtRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = row.agg;
    final c = row.company;
    // R-14：公司名用全名 name（简称非空时附「（简称）」）。
    final label = (c.shortName == null || c.shortName!.isEmpty)
        ? c.name
        : '${c.name}（${c.shortName}）';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap, // AC-PDBT-04：行点击 → P07
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
                      color: Color(0xFF000000 | row.company.color),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 公司名用全名 name（简称存在时附「（简称）」）。`models/company.dart`
                  // 的「短名截取」会截成前 2 字（shortName 无 UI 可设、恒为 null），展示禁用（R-14）。
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ReceivableStatusChip(
                    receivable: a.receivable,
                    received: a.received,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 停用 / 已删除灰角标（正常公司此件为空）。
              CompanyFlagChips(company: row.company),
              const SizedBox(height: 6),
              Text(
                '应收 ${fenToYuan(a.receivable)} − 已收 ${fenToYuan(a.received)} '
                '= 剩余 ${fenToYuan(a.remaining)}',
                style: TextStyle(
                  fontSize: 14,
                  color: a.remaining < 0 ? _kGreenAmount : _kRedAmount,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态：无欠款公司（AC-PDBT-06）。
class _EmptyDebtView extends StatelessWidget {
  const _EmptyDebtView({
    required this.overpaidCount,
    required this.onCheckOverpaid,
  });

  final int overpaidCount;
  final VoidCallback onCheckOverpaid;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 48, color: _kGreenAmount),
            const SizedBox(height: 12),
            const Text(
              '太好了，没有公司欠你钱',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            if (overpaidCount > 0) ...[
              const SizedBox(height: 12),
              // 就地切换 `_showAll`（无跳转，Q-D10）。
              InkWell(
                onTap: onCheckOverpaid,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '有 $overpaidCount 家「多收 / 记错」，点此核对',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 降级态（q1/q3 脏金额 `FormatException`）：黄色告警条 + 导出备份引导 + 重试（AC-PDBT-07）。
class _DegradedView extends StatelessWidget {
  const _DegradedView({required this.onRetry, required this.onExportGuide});

  final Future<void> Function() onRetry;
  final VoidCallback onExportGuide;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Colors.amber.shade100,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
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
                onPressed: onExportGuide,
                child: const Text('导出备份'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '部分账目存在异常数值，已降级显示。',
                    style: TextStyle(fontSize: 14, color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => onRetry(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 致命错误态（非 `FormatException`）：不白屏，给原因 + 重试。
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
            const Text(
              '数据加载失败',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
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
