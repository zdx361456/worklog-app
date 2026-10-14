/// P12 · 设置页（**Wave C1 原位填充**，保留 Wave A2 的 `Scaffold`/`AppBar` 外壳与构造签名）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.12（`07:596-636`）；
/// `02-需求与验收.md` §D.10（`AC-P12-01~05`）；实现设计：`14-WaveC1-实现设计.md` §3。
///
/// **四个出口**：
///   - 节假日标记 → P12a `HolidayMarkPage`；
///   - **公司列表** → P06（**M-2：一律 `pushNamed(Routes.companies)`，不得改命令式**）；
///   - 导出备份（带角标）→ P13 `ExportBackupPage`（**主理人裁定：直接接线**，见 `14 §9 G-C1-D` / `14 §10 R40`）；
///   - 关于 / 数据说明 → P12b `AboutPage`。
///
/// **导出角标（AC-P12-03 / E-18 / `07:604`）**：G-07 本地偏好存储未落地、U-1 未批 `shared_preferences`
/// → 本轮无持久化"上次备份时间"的介质 → **右侧（`trailing` 角标位）恒显红色「从未备份」**（走"无记录"分支，
/// 与 `02 §D.10:713` 逐字一致；登记缺口 G-C1-B）。**不伪造**"X 天前"。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/data_bus.dart';
import '../app/routes.dart';
import '../db/database.dart';
import '../models/ledger.dart';
import 'about_page.dart';
import 'export_backup_page.dart';
import 'holiday_mark_page.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;

  Ledger? _ledger;

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
    final ledgerId = AppState.ledgerId;
    if (ledgerId == null) {
      if (!mounted) return;
      setState(() {
        _ledger = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    try {
      final ledger = await _db.getLedger(ledgerId);
      if (!mounted) return;
      setState(() {
        _ledger = ledger;
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

  // ── 出口跳转 ──────────────────────────────────────────────────────────

  Future<void> _openHolidayMarks() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HolidayMarkPage()),
    );
    if (mounted) await _load();
  }

  /// **M-2**：目标为 P06 的跳转一律 `pushNamed`，保留 `Routes.companies` 为活路由。
  Future<void> _openCompanies() async {
    await Navigator.of(context).pushNamed(Routes.companies);
    if (mounted) await _load();
  }

  Future<void> _openExport() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ExportBackupPage()),
    );
    if (mounted) await _load();
  }

  Future<void> _openAbout() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AboutPage()),
    );
    if (mounted) await _load();
  }

  // ── 账本名称编辑（AC-P12-05）────────────────────────────────────────────

  Future<void> _editLedgerName() async {
    final ledger = _ledger;
    final ledgerId = AppState.ledgerId;
    if (ledger == null || ledgerId == null) return;

    // 账本名编辑：保存逻辑**在对话框内**执行（`_LedgerNameDialog.onSave`），
    // 失败时对话框**保持打开且保留输入**（`02 §D.0.3:338` 写入失败不得清空表单）。
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _LedgerNameDialog(
        initialName: ledger.name,
        // 返回 null = 成功；返回字符串 = 失败原因。
        onSave: (name) async {
          try {
            await _db.upsertLedger(Ledger(
              id: ledger.id,
              name: name,
              currency: ledger.currency, // 币种只读（Q7）
              mode: ledger.mode,
              createdAt: ledger.createdAt,
            ));
            dataBus.dataChanged();
            return null;
          } catch (e) {
            return '保存失败：$e';
          }
        },
      ),
    );
    if (saved == true && mounted) await _load();
  }

  // ── 渲染 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
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

    final currency = _ledger?.currency ?? 'CNY';
    final name = _ledger?.name ?? AppState.defaultLedgerName;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.event_available_outlined),
                title: const Text('节假日标记'),
                subtitle: const Text('标记节假日，当天记工自动按节假日倍率算'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openHolidayMarks,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.business_outlined),
                title: const Text('公司列表'),
                subtitle: const Text('管理全部公司（含停用 / 已归档）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openCompanies,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.save_alt_outlined),
                title: const Text('导出备份'),
                // AC-P12-03 / E-18 / `07:604`：**右侧（角标位）**显示；无记录 → 红色「从未备份」。
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      '从未备份',
                      style: TextStyle(
                        color: _kRedAmount,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    SizedBox(width: 4),
                    Icon(Icons.chevron_right),
                  ],
                ),
                onTap: _openExport,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('关于 / 数据说明'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openAbout,
              ),
            ],
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.book_outlined),
                title: const Text('账本名称'),
                subtitle: Text(name),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: _editLedgerName,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.currency_yen_outlined),
                title: const Text('币种'),
                subtitle: Text(currency),
                // Q7 预留：基础版币种只读，不可改。
                enabled: false,
              ),
            ],
          ),
        ),
      ],
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

/// 账本名称编辑对话框：**保存失败时保持打开、保留用户输入**（`02 §D.0.3:338`）。
///
/// 与 P12a 弹层同构：`onSave` 返回 `null` = 成功（才 `pop(true)`）；
/// 返回字符串 = 失败原因（setState 就地显示，**不 pop** → 输入不丢）。
class _LedgerNameDialog extends StatefulWidget {
  const _LedgerNameDialog({required this.initialName, required this.onSave});

  final String initialName;
  final Future<String?> Function(String name) onSave;

  @override
  State<_LedgerNameDialog> createState() => _LedgerNameDialogState();
}

class _LedgerNameDialogState extends State<_LedgerNameDialog> {
  late final TextEditingController _ctrl;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final trimmed = _ctrl.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _saveError = '账本名称不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final err = await widget.onSave(trimmed);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true); // 仅成功才关闭
    } else {
      setState(() {
        _saving = false;
        _saveError = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('账本名称'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: AppState.defaultLedgerName,
            ),
          ),
          if (_saveError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _saveError!,
                style: const TextStyle(fontSize: 13, color: _kRedAmount),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
