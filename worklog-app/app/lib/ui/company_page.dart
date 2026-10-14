/// 公司列表页 P06（增 / 改 / 停用 / 软删 · Wave A 收口 `09 §9`）。
///
/// **数据源**（`09 §9.1`，两次查询**全并发**）：
/// - `aggregateByCompany()` —— 各公司「剩余 / 应收 / 已收」（**一次查完，零 N+1**）；
///   未出现在结果里的公司按**全 0** 补齐（`database.dart:329-332`），**不得**判为不存在。
/// - `listCompanies(includeDisabled: true, includeDeleted: true)` —— 元数据全集。
///   **必须双 `true`**：默认只返回 `enabled = 1` 且未软删的公司（`database.dart:446-449`），
///   漏传会让停用 / 已归档公司从列表消失，本页就再也无法「重新启用」它们
///   （`07 §4.1` 陷阱 2 / 强制约束 1 · AC-P06-03）。
///
/// **空态**：判据为 `_companies.isEmpty`（**含停用 / 归档**）；按 `02 AC-P06-06`
/// **不自作折叠**（`07 §4.1 D3 ④` 的"折叠"口径已由主理人裁定让位于 AC-P06-06，
/// 见 `11 §5.2 m13` / 回流 R9）。
///
/// **交互**（`09 §9.2`）：**点行 → P07 公司详情**（不再是编辑对话框）；行尾「⋯」菜单
/// 与长按提供「编辑 / 停用·启用 / 删除」入口（R-3 可发现性补偿：行点击改了去向，
/// 编辑入口会变隐蔽，「⋯」菜单**必须保留**）。
///
/// **刷新**：`initState` 里监听全局 [dataBus]（`dispose` 成对移除），写操作后自动重载；
/// 每个 push 点 `await` 返回后**无条件** `_load()`（`09 §10`）。
///
/// **删除策略**：本页只做**软删**（softDeleteCompany），绝不物理删除，也不级联删
/// 该公司名下的工作记录 / 收款记录 —— 用户的历史应收已收必须保留。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/payment_record.dart';
import '../models/pricing_rule.dart';
import '../models/work_record.dart';
import '../services/enum_codec.dart';
import '../services/id_gen.dart';
import 'company_detail_page.dart';
import 'widgets/money.dart';
import 'widgets/receivable_status.dart';

/// 内置 **12 色**调色板（`07 §1.4`：12 预设色、高对比、色盲友好）。
/// 公司色约定为 **RGB（不含 alpha）**，渲染时统一补 `0xFF000000`。
const List<int> _kPalette = <int>[
  0xE53935, // 红
  0xFB8C00, // 橙
  0xFDD835, // 黄
  0x43A047, // 绿
  0x00ACC1, // 青
  0x3949AB, // 蓝
  0x8E24AA, // 紫
  0x6D4C41, // 棕
  0xD81B60, // 玫红
  0x00897B, // 青绿
  0x546E7A, // 蓝灰
  0x7CB342, // 草绿
];

/// 把模型里的「RGB 不含 alpha」色值补成可渲染的 [Color]。
Color _renderColor(int rgb) => Color(0xFF000000 | (rgb & 0xFFFFFF));

class CompanyPage extends StatefulWidget {
  const CompanyPage({super.key});

  @override
  State<CompanyPage> createState() => _CompanyPageState();
}

class _CompanyPageState extends State<CompanyPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;
  List<Company> _companies = const [];

  /// 各公司金额（`aggregateByCompany()` 一次查完）；未出现 = 全 0（`09 §9.1`）。
  Map<String, ReceivableAggregate> _aggById = const {};

  @override
  void initState() {
    super.initState();
    dataBus.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    // 必须成对移除，否则页面销毁后 dataBus 仍持有 _load → 内存泄漏 + 对已卸载 State 调 setState。
    dataBus.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // §9.1：两次查询**全并发** ——
      // q1 公司元数据全集（**双 true**：含停用 + 已归档）；q2 各公司金额（一次查完，零 N+1）。
      final results = await Future.wait<Object>([
        _db.listCompanies(includeDisabled: true, includeDeleted: true),
        _db.aggregateByCompany(),
      ]);
      final companies = results[0] as List<Company>;
      final agg = results[1] as List<ReceivableAggregate>;
      if (!mounted) return;
      setState(() {
        _companies = companies;
        // 未出现在 aggregateByCompany() 的公司 = 全 0（database.dart:329-332），**不得**判为不存在。
        _aggById = <String, ReceivableAggregate>{
          for (final a in agg)
            if (a.companyId != null) a.companyId!: a,
        };
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

  /// 取某公司金额；未出现在聚合结果里 → **全 0 补齐**（AC-P06-02，`09 §9.1`）。
  ReceivableAggregate _aggOf(Company c) =>
      _aggById[c.id] ??
      ReceivableAggregate(
        companyId: c.id,
        receivable: 0,
        received: 0,
        remaining: 0,
      );

  /// 点行 → P07 公司详情（命令式 push · `09 §8`/§9.2）；返回后无条件重载（§10）。
  Future<void> _openDetail(Company c) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CompanyDetailPage(companyId: c.id),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// 统一的错误提示：弹 SnackBar，绝不让异常冒泡导致页面崩溃。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 新建公司取色（`07 §1.4` / AC-P08-03）：**按「已用色」轮转** ——
  /// 从 12 色调色板里取**第一个未被任何公司使用**的色；全部用满 → 按「已用色数」轮转兜底。
  /// （语义不等价于「按公司数取模」：前者保证同一时刻各公司不撞色。）
  int _pickColor() {
    final used = <int>{for (final c in _companies) c.color};
    for (final c in _kPalette) {
      if (!used.contains(c)) return c;
    }
    return _kPalette[used.length % _kPalette.length];
  }

  Future<void> _onAdd() async {
    final now = DateTime.now();
    final result = await showDialog<_CompanyEditResult>(
      context: context,
      builder: (_) => const _CompanyEditDialog(
        title: '添加公司',
        showEnabled: false, // 新建必然是启用的，不给开关
      ),
    );
    if (result == null) return;
    final name = result.name.trim();
    if (name.isEmpty) return; // 对话框已保证非空，此处再兜一层

    // AC-P08-09：新建公司 `ledgerId` 必须取当前账本；无账本 → **显式失败**（不写空串）。
    final ledgerId = AppState.ledgerId;
    if (ledgerId == null) {
      _toast('账本尚未初始化，无法新建公司');
      return;
    }

    // 取色：按「已用色」轮转，避免强制用户每家都选色。
    final color = _pickColor();
    final company = Company(
      id: newId('co'),
      ledgerId: ledgerId,
      name: name,
      shortName:
          result.shortName.trim().isEmpty ? null : result.shortName.trim(),
      color: color,
      defaultRuleId: result.defaultRuleId,
      enabled: true,
      contact: result.contact.trim().isEmpty ? null : result.contact.trim(),
      currency: 'CNY',
      note: result.note.trim().isEmpty ? null : result.note.trim(),
      createdAt: now,
      updatedAt: now,
    );

    try {
      await _db.upsertCompany(company);
      dataBus.dataChanged(); // 广播：总览/明细等页面随之刷新
    } catch (e) {
      _toast('添加公司失败：$e');
    }
  }

  Future<void> _onEdit(Company c) async {
    final result = await showDialog<_CompanyEditResult>(
      context: context,
      builder: (_) => _CompanyEditDialog(
        title: '编辑公司',
        companyId: c.id, // defaultRuleId 下拉的数据源（listPricingRules{companyId, includeDisabled: true}）
        initialName: c.name,
        initialShortName: c.shortName ?? '',
        initialNote: c.note ?? '',
        initialContact: c.contact ?? '',
        initialDefaultRuleId: c.defaultRuleId,
        initialEnabled: c.enabled,
        showEnabled: true,
      ),
    );
    if (result == null) return;
    final name = result.name.trim();
    if (name.isEmpty) return;

    // 关键：保留原 id / ledgerId / createdAt / color —— 改的只是可编辑字段。
    final updated = Company(
      id: c.id,
      ledgerId: c.ledgerId,
      name: name,
      shortName:
          result.shortName.trim().isEmpty ? null : result.shortName.trim(),
      color: c.color,
      defaultRuleId: result.defaultRuleId,
      enabled: result.enabled,
      contact: result.contact.trim().isEmpty ? null : result.contact.trim(),
      currency: c.currency,
      note: result.note.trim().isEmpty ? null : result.note.trim(),
      createdAt: c.createdAt,
      updatedAt: DateTime.now(),
      deletedAt: c.deletedAt,
    );

    try {
      await _db.updateCompany(updated);
      dataBus.dataChanged();
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  /// 删除前的确认（AC-20 / **Wave A 提前项**：文案须含**影响条数**，`07:489`）。
  ///
  /// 计数（A5/A6 按公司过滤）**失败时退回不带条数的原文案**——不得抛异常、不得中断删除流程；
  /// 二次确认本身任何情况下都不可省。R-14：本方法只读聚合之外的两张表，不改 `database.dart`。
  Future<bool> _confirmDelete(Company c) async {
    // 计数窗口内任何异常都不能让对话框或删除流程崩（team-lead 明确要求）。
    // countsLine 为空串 = 「退回不带条数的原文案」，两种情形：
    //   ① 计数抛异常；② 计数成功但工作与收款**都为 0**（无连带影响可警示）。
    var countsLine = '';
    try {
      final counts = await Future.wait<Object>([
        _db.listWorkRecords(companyId: c.id),
        _db.listPaymentRecords(companyId: c.id),
      ]);
      final workCount = (counts[0] as List<WorkRecord>).length;
      final payCount = (counts[1] as List<PaymentRecord>).length;
      countsLine = (workCount == 0 && payCount == 0)
          ? ''
          : '将连同 $workCount 条工作记录、$payCount 笔收款一并归档，是否继续？';
    } catch (_) {
      // 计数异常 → 保持空串，退回不带条数文案，不抛异常、不阻断删除流程。
    }
    if (!mounted) return false;

    final content = countsLine.isEmpty
        ? '删除公司「${c.name}」？该公司名下的工作记录与收款记录不会被删除，'
            '仍会计入看板的应收/已收。'
        : '$countsLine\n归档后记录不会被删除，仍会计入看板的应收/已收。';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除公司'),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _onDelete(Company c) async {
    final ok = await _confirmDelete(c);
    if (!ok) return;
    try {
      // 软删：只置 deleted_at，历史工作/收款记录仍可解析到该公司（getCompany 不过滤软删）。
      await _db.softDeleteCompany(c.id, DateTime.now());
      dataBus.dataChanged();
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  /// 长按菜单：给不便滑动删除的场景（鼠标 / 桌面）一个入口。
  Future<void> _onLongPress(Company c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'edit') {
      await _onEdit(c);
    } else if (action == 'delete') {
      await _onDelete(c);
    }
  }

  /// 行尾「⋯」菜单：**编辑 / 停用·启用 / 删除** 三入口（AC-P06-04，`09 §9.2`）。
  ///
  /// R-3 可发现性补偿：行点击已改为进详情页，编辑入口变隐蔽 → 本菜单**必须保留**。
  /// 「停用 / 启用」是既有 [_onLongPress]（编辑/删除）之外补齐的第三项。
  Future<void> _onMenu(Company c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(
                c.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
              ),
              title: Text(c.enabled ? '停用' : '启用'),
              onTap: () => Navigator.pop(ctx, 'toggle'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _onEdit(c);
    } else if (action == 'toggle') {
      await _onToggleEnabled(c);
    } else if (action == 'delete') {
      await _onDelete(c);
    }
  }

  /// 停用前的二次确认。文案依 `07:488`（含「历史账目不受影响，只是不再出现在快记里」）。
  Future<bool> _confirmDisable(Company c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('停用公司'),
        content: Text('停用公司「${c.name}」？历史账目不受影响，只是不再出现在快记里。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('停用')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 停用 / 启用切换（AC-P06-04）。
  ///
  /// ⚠️ **E-6 / M-13①**：写方法真实签名是 `updateCompany(Company x)`（**整对象**，
  /// `database.dart:488`），且 `Company` **没有 `copyWith`** → 必须**逐字段构造整个对象**
  /// （范例见本文件 [_onEdit]），**仅改 `enabled` 与 `updatedAt`**，其余字段原样带上。
  Future<void> _onToggleEnabled(Company c) async {
    if (c.enabled) {
      final ok = await _confirmDisable(c);
      if (!ok) return;
    }
    final updated = Company(
      id: c.id,
      ledgerId: c.ledgerId,
      name: c.name,
      shortName: c.shortName,
      color: c.color,
      defaultRuleId: c.defaultRuleId,
      enabled: !c.enabled,
      contact: c.contact,
      currency: c.currency,
      note: c.note,
      createdAt: c.createdAt,
      updatedAt: DateTime.now(),
      deletedAt: c.deletedAt,
    );
    try {
      await _db.updateCompany(updated);
      dataBus.dataChanged(); // §10：写库成功后广播
    } catch (e) {
      _toast(c.enabled ? '停用失败：$e' : '启用失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('公司管理')),
      body: ListenableBuilder(
        listenable: dataBus,
        builder: (context, _) => _buildBody(),
      ),
      // FAB 始终存在：空态时它是「添加第一家」的唯一入口。
      floatingActionButton: FloatingActionButton(
        onPressed: _onAdd,
        tooltip: '添加公司',
        child: const Icon(Icons.add),
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
    if (_companies.isEmpty) {
      return const _EmptyView();
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88), // 给 FAB 留出空间
      itemCount: _companies.length,
      itemBuilder: (context, index) {
        final c = _companies[index];
        return Dismissible(
          key: ValueKey<String>(c.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            color: Colors.red,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          // 先弹确认框再松手删除：用户滑一下不会被直接删掉。
          // 关键：删除动作放在 confirmDismiss 内并**同步**把该行移出本地列表，
          // 最后返回 false —— 避免「onDismissed 里异步删库」导致的
          // 「A dismissed Dismissible widget is still part of the tree」断言。
          confirmDismiss: (_) async {
            final ok = await _confirmDelete(c);
            if (!ok) return false;
            try {
              await _db.softDeleteCompany(c.id, DateTime.now());
            } catch (e) {
              _toast('删除失败：$e');
              return false;
            }
            if (mounted) {
              setState(() {
                _companies =
                    _companies.where((x) => x.id != c.id).toList(growable: false);
              });
            }
            dataBus.dataChanged();
            return false;
          },
          child: _CompanyTile(
            company: c,
            agg: _aggOf(c),
            // AC-P06-01：点行进 P07 公司详情（原来弹编辑对话框）。
            onTap: () => _openDetail(c),
            // 长按菜单保留（编辑 / 删除），与「⋯」菜单共同保证可发现性。
            onLongPress: () => _onLongPress(c),
            onMenu: () => _onMenu(c),
          ),
        );
      },
    );
  }
}

/// 公司行（`09 §9.2`）：
/// `title` = 显示名 + 收款状态角标；`subtitle` = 剩余 / 应收 / 已收；
/// `trailing` = 停用·已删除灰角标 + 「⋯」菜单（编辑 / 停用·启用 / 删除）。
class _CompanyTile extends StatelessWidget {
  const _CompanyTile({
    required this.company,
    required this.agg,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final Company company;

  /// 该公司金额（分）；未出现在 `aggregateByCompany()` 时由调用方补齐为全 0。
  final ReceivableAggregate agg;

  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    // 公司名用**全名** `name`（简称非空时附「（简称）」）。
    // 禁用「简称→否则取 name 前 2 字」的截断口径：它会把全名显示成前 2 字
    // （`shortName` 无 UI 可设、恒为 null），故本页不采用（R-14）。
    final label = (company.shortName == null || company.shortName!.isEmpty)
        ? company.name
        : '${company.name}（${company.shortName}）';
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          // color 约定为 RGB（不含 alpha），渲染时补 0xFF。
          color: _renderColor(company.color),
          shape: BoxShape.circle,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              // 已停用公司用弱化色显示，与「已停用」角标呼应。
              style: TextStyle(color: company.enabled ? null : Colors.black45),
            ),
          ),
          const SizedBox(width: 8),
          // PRD §5.2 五态角标（整数严格等号，P01/P06/P07/P-DEBT 共用）。
          ReceivableStatusChip(
            receivable: agg.receivable,
            received: agg.received,
          ),
        ],
      ),
      // 行内金额：整数「分」，一律 fenToYuan（AC-P06-02）。
      subtitle: Text(
        '剩余 ${fenToYuan(agg.remaining)} · 应收 ${fenToYuan(agg.receivable)} / '
        '已收 ${fenToYuan(agg.received)}',
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 停用 / 已删除灰角标（AC-P06-03）；正常公司不产生任何角标。
          CompanyFlagChips(company: company),
          IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: '更多操作',
            onPressed: onMenu,
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.business_outlined, size: 56, color: Colors.black26),
            SizedBox(height: 16),
            Text('还没有公司', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text('点击右下角 ＋ 添加第一家',
                style: TextStyle(color: Colors.black54), textAlign: TextAlign.center),
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
            const Icon(Icons.error_outline, size: 48, color: Color(0xFFD32F2F)),
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

/// 编辑对话框的返回值（与 [Company] 解耦：这里只承载用户可改的字段）。
class _CompanyEditResult {
  const _CompanyEditResult({
    required this.name,
    required this.shortName,
    required this.note,
    required this.contact,
    required this.defaultRuleId,
    required this.enabled,
  });

  final String name;
  final String shortName;
  final String note;
  final String contact;
  final String? defaultRuleId;
  final bool enabled;
}

/// 「不指定默认规则」哨兵值（下拉需要可返回的"空"选项）。
const String _kNoRule = '__no_rule__';

/// 公司新增/编辑对话框。自己持有 TextEditingController 并在 [dispose] 释放，
/// 避免把 controller 生命周期外泄给调用方。
class _CompanyEditDialog extends StatefulWidget {
  const _CompanyEditDialog({
    required this.title,
    this.companyId,
    this.initialName = '',
    this.initialShortName = '',
    this.initialNote = '',
    this.initialContact = '',
    this.initialDefaultRuleId,
    this.initialEnabled = true,
    required this.showEnabled,
  });

  final String title;

  /// 编辑态公司 id（`defaultRuleId` 下拉的数据源）；新建态为 `null`（公司尚未存在，无候选）。
  final String? companyId;
  final String initialName;
  final String initialShortName;
  final String initialNote;
  final String initialContact;
  final String? initialDefaultRuleId;
  final bool initialEnabled;
  final bool showEnabled;

  @override
  State<_CompanyEditDialog> createState() => _CompanyEditDialogState();
}

class _CompanyEditDialogState extends State<_CompanyEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _shortCtrl;
  late final TextEditingController _noteCtrl;
  late final TextEditingController _contactCtrl;
  late bool _enabled;

  /// 默认计价规则候选：`listPricingRules({companyId, includeDisabled: true})`
  /// （含停用、**不含归档**；`includeDeleted` 保持默认 false，AC-P08-04）。
  List<PricingRule> _rules = const <PricingRule>[];

  /// 当前选中的默认规则（[_kNoRule] = 不指定）。
  late String _ruleValue;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _shortCtrl = TextEditingController(text: widget.initialShortName);
    _noteCtrl = TextEditingController(text: widget.initialNote);
    _contactCtrl = TextEditingController(text: widget.initialContact);
    _enabled = widget.initialEnabled;
    _ruleValue = widget.initialDefaultRuleId ?? _kNoRule;
    _loadRules();
  }

  Future<void> _loadRules() async {
    final cid = widget.companyId;
    if (cid == null) return; // 新建态：无公司即无规则候选
    try {
      final rules = await AppDatabase.instance
          .listPricingRules(companyId: cid, includeDisabled: true);
      if (!mounted) return;
      setState(() => _rules = rules);
    } catch (_) {
      if (!mounted) return;
      setState(() => _rules = const <PricingRule>[]);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _shortCtrl.dispose();
    _noteCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  /// 名称必填（AC-P08-01）：**字段内联红字**；保存按钮空名时**置灰**；
  /// **不弹全局 Toast**（原 SnackBar 实现已移除）。
  String? get _nameError =>
      _nameCtrl.text.trim().isEmpty ? '请填写公司名' : null;

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return; // 双保险：保存按钮在空名时已置灰
    Navigator.pop(
      context,
      _CompanyEditResult(
        name: name,
        shortName: _shortCtrl.text,
        note: _noteCtrl.text,
        contact: _contactCtrl.text,
        defaultRuleId: _ruleValue == _kNoRule ? null : _ruleValue,
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _nameCtrl.text.trim().isNotEmpty;
    final ids = _rules.map((r) => r.id).toSet();
    // 编辑态若原 defaultRuleId 指向已归档规则（不在候选里）→ 补一条占位项，避免下拉断言。
    final orphan =
        (_ruleValue != _kNoRule && !ids.contains(_ruleValue)) ? _ruleValue : null;

    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '公司名 *',
                hintText: '例如：某某工厂',
                errorText: _nameError,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            // AC-P08-02：简称可空输入（空则展示侧取名称前 2 字，见 Company.displayName）。
            TextField(
              controller: _shortCtrl,
              decoration: const InputDecoration(labelText: '简称（可选）'),
            ),
            const SizedBox(height: 12),
            // AC-P08-05：联系方式**始终渲染**（新建态也可填；编辑态回填）。
            TextField(
              controller: _contactCtrl,
              decoration: const InputDecoration(labelText: '联系方式（可选）'),
            ),
            const SizedBox(height: 12),
            _buildRuleDropdown(orphan),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              decoration: const InputDecoration(labelText: '备注（可选）'),
              maxLines: 2,
            ),
            if (widget.showEnabled) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用'),
                subtitle: const Text('停用后不影响历史记录，仅不再出现在新建记录的选择里'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: canSave ? _submit : null, child: const Text('保存')),
      ],
    );
  }

  Widget _buildRuleDropdown(String? orphan) {
    return DropdownButtonFormField<String>(
      initialValue: _ruleValue,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '默认计价规则（可选）',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<String>(value: _kNoRule, child: Text('（不指定）')),
        for (final r in _rules)
          DropdownMenuItem<String>(
            value: r.id,
            child: Text(
              '${r.name} · ${EnumCodec.pricingMethod(r.method)} · ${fenToYuan(r.baseRate)}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (orphan != null)
          DropdownMenuItem<String>(
              value: orphan, child: const Text('（已删除的规则）')),
      ],
      onChanged: (v) => setState(() => _ruleValue = v ?? _kNoRule),
    );
  }
}
