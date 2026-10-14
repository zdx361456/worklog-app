/// P12a · 节假日标记页（**Wave C1 新建**，P12 从属子页，`07:907` 不计入 13 页）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.12「节假日标记子页」（`07:615-625`）；
/// `02-需求与验收.md` §D.10 `AC-P12-06~10`（`02:724-728`）；
/// 实现设计：`14-WaveC1-实现设计.md` §4。
///
/// **G-13 硬契约（`07:623` / `database.dart:1005-1016`）**：
///   `upsertHolidayMark` 为 `INSERT OR REPLACE` → 同 `(ledger_id, date)` 会**换 id**。
///   → **新建前先 `getHolidayMarkByDate` 判重**，命中则转为编辑；
///   → **编辑一律走 `updateHolidayMark`（复用原 id，id 不漂移）**。
///
/// **删除为硬删**（`database.dart:1110-1112`，本表无软删）→ 二次确认（AC-P12-07）。
///
/// 倍率纪律（`07 §1.2`）：存储整数「×10」，显示 `${x ~/ 10}.${x % 10}`，**禁** `x / 10`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/holiday_mark.dart';
import '../models/pricing_rule.dart';
import '../models/types.dart';
import '../services/enum_codec.dart';
import '../services/id_gen.dart';
import '../services/validators.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

class HolidayMarkPage extends StatefulWidget {
  const HolidayMarkPage({super.key});

  @override
  State<HolidayMarkPage> createState() => _HolidayMarkPageState();
}

class _HolidayMarkPageState extends State<HolidayMarkPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;

  List<HolidayMark> _marks = const [];

  /// 新建时的默认倍率（×10）：取首个启用规则的 `holidayRate`，无则 10（= 1.0）。
  /// 见 `14 §4.3` / 缺口 G-C1-C。
  int _defaultRate = Validators.minRate;

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
        _error = StateError('账本尚未初始化');
        _loading = false;
      });
      return;
    }
    try {
      final results = await Future.wait<Object>([
        _db.listHolidayMarks(ledgerId: ledgerId),
        _db.listPricingRules(includeDisabled: false),
      ]);
      final marks = results[0] as List<HolidayMark>;
      final rules = results[1] as List<PricingRule>;
      if (!mounted) return;
      setState(() {
        _marks = marks;
        _defaultRate = rules.isEmpty ? Validators.minRate : rules.first.holidayRate;
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

  // ── 写操作（G-13 三分支）──────────────────────────────────────────────

  Future<void> _openEditor({HolidayMark? editing}) async {
    final ledgerId = AppState.ledgerId;
    if (ledgerId == null) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MarkEditorSheet(
        editing: editing,
        defaultRate: _defaultRate,
        // 保存回调：返回 null = 成功；返回字符串 = 失败原因。
        // 弹层据此**保持打开并保留输入**（`02 §D.0.3:338` 写入失败不得清空表单）。
        onSave: (draft) => _save(draft, editing: editing, ledgerId: ledgerId),
      ),
    );
    if (saved == true) _snack('已保存');
  }

  /// 保存：新建先判重（命中转编辑）→ 走 `updateHolidayMark`；否则 `upsertHolidayMark`；
  /// 编辑走 `updateHolidayMark`（原 id）；日期与别的标记冲突 → **返回错误串（不关闭弹层）**。
  ///
  /// 返回 `null` = 成功；返回字符串 = 失败原因。**失败不丢输入**：调用方（弹层）在收到
  /// 非 `null` 时**不 pop**，就地显示错误并保留原 `_DraftMark`（`02 §D.0.3:338`）。
  Future<String?> _save(
    _DraftMark draft, {
    required HolidayMark? editing,
    required String ledgerId,
  }) async {
    try {
      if (editing != null) {
        final other = await _db.getHolidayMarkByDate(ledgerId, draft.date);
        if (other != null && other.id != editing.id) {
          return '该日期已有标记，请直接编辑或删除它';
        }
        await _db.updateHolidayMark(HolidayMark(
          id: editing.id, // 复用原 id → id 不漂移（G-13）
          ledgerId: ledgerId,
          date: draft.date,
          type: draft.type,
          rate: draft.rate,
          manual: true,
          createdAt: editing.createdAt,
        ));
      } else {
        final existing = await _db.getHolidayMarkByDate(ledgerId, draft.date);
        if (existing != null) {
          // 命中判重 → 转为编辑（复用旧 id，禁 upsert 换 id）
          await _db.updateHolidayMark(HolidayMark(
            id: existing.id,
            ledgerId: ledgerId,
            date: draft.date,
            type: draft.type,
            rate: draft.rate,
            manual: true,
            createdAt: existing.createdAt,
          ));
        } else {
          await _db.upsertHolidayMark(HolidayMark(
            id: newId('hm'),
            ledgerId: ledgerId,
            date: draft.date,
            type: draft.type,
            rate: draft.rate,
            manual: true,
            createdAt: DateTime.now(),
          ));
        }
      }
      dataBus.dataChanged();
      await _load();
      return null;
    } catch (e) {
      return '保存失败：$e';
    }
  }

  Future<void> _confirmDelete(HolidayMark m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个节假日标记？'),
        content: const Text(
          // AC-P12-07：确认按钮文案逐字写明后果（不用"确定/取消"）。
          '删除后该日新建记录将不再套用节假日倍率。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不删除'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kRedAmount),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除标记'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _db.deleteHolidayMark(m.id);
      dataBus.dataChanged();
      await _load();
      _snack('已删除');
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 渲染 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('节假日标记')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.event_available_outlined),
        label: const Text('标记节假日'),
      ),
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

    // AC-P12-09：效果说明（只读，常显），文案逐字。
    final items = _buildItems();
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Colors.blue.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: const Text(
            '标记只影响以后新建的记录；已记的历史金额不变。',
            style: TextStyle(fontSize: 13, color: Colors.black87),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const _EmptyView()
              : ListView.builder(
                  // MIN-6：≥200 行惰性构建。
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    if (it.isHeader) return _MonthHeader(label: it.header!);
                    return _MarkTile(
                      mark: it.mark!,
                      onEdit: () => _openEditor(editing: it.mark),
                      onDelete: () => _confirmDelete(it.mark!),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 按月分组（`07:622`「标记列表（按月）」）：倒序（新在前），每月一个表头。
  List<_ListItem> _buildItems() {
    final sorted = [..._marks]
      ..sort((a, b) => b.date.compareTo(a.date));
    final items = <_ListItem>[];
    String? cur;
    for (final m in sorted) {
      final key = '${m.date.year} 年 ${m.date.month} 月';
      if (key != cur) {
        cur = key;
        items.add(_ListItem.header(key));
      }
      items.add(_ListItem.mark(m));
    }
    return items;
  }
}

/// 列表项：月份表头 或 标记行。
class _ListItem {
  const _ListItem.header(this.header) : mark = null, isHeader = true;
  const _ListItem.mark(this.mark) : header = null, isHeader = false;
  final String? header;
  final HolidayMark? mark;
  final bool isHeader;
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black54)),
    );
  }
}

class _MarkTile extends StatelessWidget {
  const _MarkTile({required this.mark, required this.onEdit, required this.onDelete});

  final HolidayMark mark;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onEdit,
        leading: const Icon(Icons.event_outlined),
        title: Text(_formatDate(mark.date)),
        subtitle: Text('${EnumCodec.holidayType(mark.type)} · ${_rateText(mark.rate)} 倍'),
        trailing: IconButton(
          tooltip: '删除',
          icon: const Icon(Icons.delete_outline, color: _kRedAmount),
          onPressed: onDelete,
        ),
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
            Icon(Icons.event_busy_outlined, size: 56, color: Colors.black26),
            SizedBox(height: 16),
            // AC-P12-10 / E-05：逐字。
            Text('标了节假日，当天记工自动按节假日倍率算',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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

/// 编辑器返回的草稿（尚未落库）。
class _DraftMark {
  const _DraftMark({required this.date, required this.type, required this.rate});
  final DateTime date;
  final HolidayType type;
  final int rate; // ×10
}

/// 新增 / 编辑弹层（`07 §1.7`：高频轻量录入用弹层）。
///
/// **失败不丢输入（`02 §D.0.3:338`）**：`onSave` 返回非 null 错误串时**不 pop**，
/// 就地显示错误并保留当前输入与 `_DraftMark`；仅成功（返回 null）才关闭。
class _MarkEditorSheet extends StatefulWidget {
  const _MarkEditorSheet({
    required this.editing,
    required this.defaultRate,
    required this.onSave,
  });

  final HolidayMark? editing;
  final int defaultRate;

  /// 保存回调：返回 `null` = 成功；返回字符串 = 失败原因。
  final Future<String?> Function(_DraftMark draft) onSave;

  @override
  State<_MarkEditorSheet> createState() => _MarkEditorSheetState();
}

class _MarkEditorSheetState extends State<_MarkEditorSheet> {
  late DateTime _date;
  late HolidayType _type;
  late TextEditingController _rateCtrl;
  String? _rateError;

  /// 提交中（禁用按钮，防重复提交）。
  bool _saving = false;

  /// 保存失败原因（非空时**弹层保持打开**，输入不丢）。
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _date = e?.date ?? DateTime.now();
    _type = e?.type ?? HolidayType.statutory;
    final rate = e?.rate ?? widget.defaultRate;
    _rateCtrl = TextEditingController(text: _rateText(rate));
  }

  @override
  void dispose() {
    _rateCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _submit() async {
    final rate = _parseRateX10(_rateCtrl.text);
    if (rate == null || !Validators.validRate(rate)) {
      setState(() => _rateError = '倍率需为 ≥ 1.0 的数字（1 位小数）');
      return;
    }
    final draft = _DraftMark(date: _date, type: _type, rate: rate);
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final err = await widget.onSave(draft);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true); // 仅成功才关闭 → 失败保留输入
    } else {
      setState(() {
        _saving = false;
        _saveError = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.editing == null ? '标记节假日' : '编辑节假日标记',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            const Text('日期', style: TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.edit_calendar_outlined),
              label: Text(_formatDate(_date)),
            ),
            const SizedBox(height: 16),
            const Text('类型', style: TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final t in HolidayType.values)
                  ChoiceChip(
                    label: Text(EnumCodec.holidayType(t)),
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('倍率（×10，例：3.0）',
                style: TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 6),
            TextField(
              controller: _rateCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: '3.0',
                errorText: _rateError,
              ),
            ),
            const SizedBox(height: 20),
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _saveError!,
                  style: const TextStyle(fontSize: 13, color: _kRedAmount),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── 工具 ────────────────────────────────────────────────────────────────

/// 倍率显示：整数「×10」→ `3.0` 形式（`07 §1.2`，**禁** `x / 10`）。
String _rateText(int x10) => '${x10 ~/ 10}.${x10 % 10}';

/// 解析用户输入的倍率文本（如 `3.0`）→ 整数「×10」。**全整数运算，禁 `double.parse`**。
/// 非法（空 / 含非数字 / 小数位 > 1）→ `null`（由调用方给校验提示，不静默兜底）。
int? _parseRateX10(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final parts = t.split('.');
  if (parts.length > 2) return null;
  final intPart = parts[0].isEmpty ? '0' : parts[0];
  final fracPart = parts.length == 2 ? parts[1] : '';
  if (!_isDigits(intPart)) return null;
  if (fracPart.isNotEmpty && !_isDigits(fracPart)) return null;
  if (fracPart.length > 1) return null; // 超过 1 位小数：非法
  final yuan = int.tryParse(intPart);
  if (yuan == null) return null;
  final tenth = fracPart.isEmpty ? 0 : int.parse(fracPart);
  return yuan * 10 + tenth;
}

bool _isDigits(String s) {
  if (s.isEmpty) return false;
  for (final c in s.codeUnits) {
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

String _formatDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
