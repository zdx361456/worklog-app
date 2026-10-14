/// P09 · 计价规则编辑页（**新建 / 编辑共用**，Wave D1-a 新建）。
///
/// 契约来源：`docs/07-UI实现规格.md §3.9`（`:501-528` 控件清单逐字）；
/// `02-需求与验收.md §D.8`（AC-P09-01~14，P09「Q30 已裁定：采用 `07 §3.9` 用户可见页」）；
/// 实现设计：`16-WaveD1-实现设计.md §2.1`。
///
/// **定位（U-3 / D-7）**：本页是「用户可见的价目表管理页」——用户在此把三档倍率
/// （加班 / 周末 / 节假日）配成想要的值。`ensureRule`（`pricing_bootstrap.dart`）**保留为兜底**，
/// 与手工规则**共存**（共存规则见 `02 §D.8`）；本页**不改** `pricing_bootstrap.dart`。
///
/// **写库双分支（`02 §D.8:635`）**：
///   - 新建（`ruleId == null`）→ `upsertPricingRule(x)`，`id = newId('rule')`；
///   - 编辑（`ruleId != null`）→ `updatePricingRule(x)`，**复用原 id** 且保留 `createdAt`。
///   - 归档 → `softDeletePricingRule(id, now)`（二次确认，文案逐字见 `_confirmArchive`）。
///
/// **红线（AC-P09-13）**：写库路径**只写 `pricing_rule` 表**，**绝不触碰 `work_record`**
/// （`database.dart:571` 注释「绝不可在此重算历史 work_record」）→ 改价不回改历史。
///
/// **金额/倍率纪律（`03 §4.6`）**：金额整数「分」（`yuanToFen` / `fenToYuanPlain`）；
/// 倍率整数「×10」（`_parseRateX10` / `_rateText`，**全整数，禁 `double.parse`、禁 `x / 10`**）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/pricing_rule.dart';
import '../models/types.dart';
import '../services/enum_codec.dart';
import '../services/id_gen.dart';
import '../services/validators.dart';
import 'widgets/money.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

/// 三档倍率（加班 / 周末 / 节假日，≥ 1.0）字段的非法提示文案。
const String _kRateMsg = '需为 ≥ 1.0 的数字（最多 1 位小数）';

class RuleEditPage extends StatefulWidget {
  const RuleEditPage({super.key, required this.companyId, this.ruleId});

  /// P07 固定公司（`company_detail_page.dart:44-45` 上行注入）。
  final String companyId;

  /// `null` = 新建态；非空 = 编辑态（复用原 id）。
  final String? ruleId;

  @override
  State<RuleEditPage> createState() => _RuleEditPageState();
}

class _RuleEditPageState extends State<RuleEditPage> {
  final AppDatabase _db = AppDatabase.instance;

  // ── 文本控制器 ──
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _rateCtrl = TextEditingController();
  final TextEditingController _unitCtrl = TextEditingController();
  final TextEditingController _stdHoursCtrl = TextEditingController();
  final TextEditingController _halfDayCtrl = TextEditingController();
  final TextEditingController _otCtrl = TextEditingController();
  final TextEditingController _wkCtrl = TextEditingController();
  final TextEditingController _hdCtrl = TextEditingController();

  // ── 载入态 ──
  bool _loading = true;
  Object? _error;
  bool _missing = false; // 编辑态：id 查不到规则

  // ── 表单态 ──
  /// 当前规则 id（`null` = 新建态）。可变：撞同类规则转编辑时复用原 id。
  String? _ruleId;
  PricingRule? _existing; // 编辑态原对象（保留 createdAt / 兼容读回）
  PricingMethod _method = PricingMethod.hourly;
  DateTime? _effectiveDate;
  bool _enabled = true;
  bool _saving = false;

  /// 是否已尝试过保存（仅在第一次点保存后才给字段级红字，避免空白页就飘红）。
  bool _submitted = false;

  bool get _isEdit => _ruleId != null;

  @override
  void initState() {
    super.initState();
    _ruleId = widget.ruleId;
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rateCtrl.dispose();
    _unitCtrl.dispose();
    _stdHoursCtrl.dispose();
    _halfDayCtrl.dispose();
    _otCtrl.dispose();
    _wkCtrl.dispose();
    _hdCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.ruleId;
    if (id == null) {
      // 新建态：默认值（倍率 15/10/10/5 与模型默认一致）。
      _setDefaults();
      setState(() => _loading = false);
      return;
    }
    try {
      final r = await _db.getPricingRule(id);
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _loading = false;
          _missing = true;
        });
        return;
      }
      setState(() {
        _applyRuleToForm(r);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  void _setDefaults() {
    _halfDayCtrl.text = _rateText(5);
    _otCtrl.text = _rateText(15);
    _wkCtrl.text = _rateText(10);
    _hdCtrl.text = _rateText(10);
    _effectiveDate = null;
    _enabled = true;
  }

  void _applyRuleToForm(PricingRule r) {
    _existing = r;
    _ruleId = r.id;
    _nameCtrl.text = r.name;
    _method = r.method;
    _rateCtrl.text = fenToYuanPlain(r.baseRate);
    _unitCtrl.text = r.unit ?? '';
    _stdHoursCtrl.text =
        r.standardHours == null ? '' : _fmtHours(r.standardHours!);
    _halfDayCtrl.text = _rateText(r.halfDayRatio);
    _otCtrl.text = _rateText(r.overtimeRate);
    _wkCtrl.text = _rateText(r.weekendRate);
    _hdCtrl.text = _rateText(r.holidayRate);
    _effectiveDate = r.effectiveDate;
    _enabled = r.enabled;
  }

  // ══════════════════════════════════════════════════════════════════════
  // 交互
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _pickEffectiveDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() =>
        _effectiveDate = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _clearEffectiveDate() async {
    setState(() => _effectiveDate = null);
  }

  // ══════════════════════════════════════════════════════════════════════
  // 保存 / 归档
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _submitted = true);
    final block = _blockReason();
    if (block != null) {
      _snack(block);
      return;
    }

    final rateFen = yuanToFen(_rateCtrl.text)!;
    final unit = _unitValue();

    // 共存规则判据（`02 §D.8:646` / AC-P09-11）：与 `pricing_bootstrap.dart:30` **完全一致**。
    // 仅新建态判重（编辑态改的是同一条，不存在"撞已有"）。
    if (!_isEdit) {
      final dup = await _findSameKind(rateFen, unit);
      if (dup != null && mounted) {
        final goEdit = await _confirmSameKind(dup);
        if (goEdit == true) {
          await _switchToEdit(dup.id);
        }
        return; // 无论选直接编辑还是取消，本次保存都不落库
      }
    }

    final rule = _buildRule(rateFen, unit);
    final errs = Validators.pricingRule(rule);
    if (errs.isNotEmpty) {
      _snack(errs.join('；'));
      return;
    }

    setState(() => _saving = true);
    var popped = false;
    try {
      if (_isEdit) {
        await _db.updatePricingRule(rule); // 编辑：复用原 id（AC-P09-07/08）
      } else {
        await _db.upsertPricingRule(rule); // 新建：newId('rule')
      }
      dataBus.dataChanged(); // 广播：P07 规则区块 / P02 规则下拉随之刷新
      if (!mounted) return;
      Navigator.of(context).pop();
      popped = true;
    } catch (e) {
      // 写入失败 → 保留用户输入（不 pop），仅提示可读原因（`02 §D.0.3:338`）。
      _snack('保存失败：$e');
    } finally {
      if (!popped && mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmArchive() async {
    final id = _ruleId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条计价规则？'),
        // 文案逐字（AC-P09-10 / AC-P09-14；`16 §2.1.7`）。
        content: const Text(
          '删除后该规则不再出现。若以后用相同的计价方式和单价记账，会重新创建一条（避免金额无据可溯）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不删除'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kRedAmount),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除规则'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    var popped = false;
    try {
      await _db.softDeletePricingRule(id, DateTime.now());
      dataBus.dataChanged();
      if (!mounted) return;
      Navigator.of(context).pop();
      popped = true;
    } catch (e) {
      _snack('删除失败：$e');
    } finally {
      if (!popped && mounted) setState(() => _saving = false);
    }
  }

  /// 撞同类规则 → 转编辑（复用命中规则 id 与内容，跳回编辑态）。
  Future<void> _switchToEdit(String id) async {
    try {
      final r = await _db.getPricingRule(id);
      if (!mounted) return;
      if (r == null) {
        _snack('该规则已不存在，请刷新后重试');
        return;
      }
      setState(() => _applyRuleToForm(r));
      _snack('已切换为编辑「${r.name}」');
    } catch (e) {
      _snack('加载规则失败：$e');
    }
  }

  /// 命中该公司**启用**规则中 `(method, baseRate, unit)` 相同的一条（判据同 `ensureRule`）。
  Future<PricingRule?> _findSameKind(int rateFen, String? unit) async {
    try {
      final rules = await _db.listPricingRules(companyId: widget.companyId);
      for (final r in rules) {
        if (r.method == _method && r.baseRate == rateFen && r.unit == unit) {
          return r;
        }
      }
      return null;
    } catch (_) {
      // 判重失败不阻塞新建（退化为「不提示、直接新建」）。
      return null;
    }
  }

  Future<bool?> _confirmSameKind(PricingRule dup) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已有同类规则'),
        content: Text(
          '该公司已有一条相同「计价方式 + 单价 + 单位」的规则「${dup.name}」。是否改为直接编辑它？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('直接编辑'),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // 构造对象 / 校验
  // ══════════════════════════════════════════════════════════════════════

  PricingRule _buildRule(int rateFen, String? unit) {
    final now = DateTime.now();
    return PricingRule(
      id: _ruleId ?? newId('rule'),
      companyId: widget.companyId,
      name: _nameCtrl.text.trim(),
      method: _method,
      baseRate: rateFen,
      unit: unit,
      standardHours: double.tryParse(_stdHoursCtrl.text.trim()),
      halfDayRatio: _parseRateX10(_halfDayCtrl.text) ?? 5,
      overtimeRate: _parseRateX10(_otCtrl.text) ?? 15,
      weekendRate: _parseRateX10(_wkCtrl.text) ?? 10,
      holidayRate: _parseRateX10(_hdCtrl.text) ?? 10,
      effectiveDate: _effectiveDate,
      enabled: _enabled,
      createdAt: _existing?.createdAt ?? now, // 编辑态保留首次创建时间
      updatedAt: now,
    );
  }

  /// 保存按钮的禁用原因（null = 可保存）。所有「硬要求」收敛到一处，
  /// 保证按钮状态与提示文案永远一致。
  String? _blockReason() {
    if (_nameCtrl.text.trim().isEmpty) return '请填写规则名 / 工序';
    final fen = yuanToFen(_rateCtrl.text);
    if (fen == null || fen <= 0) return '请填写有效基础单价（> 0）';
    if (_method == PricingMethod.piece && _unitCtrl.text.trim().isEmpty) {
      return '计件必须填写计价单位（如「趟」「㎡」）';
    }
    if (!_validRateText(_otCtrl.text)) return '加班倍率需为 ≥ 1.0 的数字（最多 1 位小数）';
    if (!_validRateText(_wkCtrl.text)) return '周末倍率需为 ≥ 1.0 的数字（最多 1 位小数）';
    if (!_validRateText(_hdCtrl.text)) return '节假日倍率需为 ≥ 1.0 的数字（最多 1 位小数）';
    if (_method == PricingMethod.daily) {
      final h = _parseRateX10(_halfDayCtrl.text);
      if (h == null || !Validators.validHalfDayRatio(h)) {
        return '半天折算比需为 0~1 的数字（最多 1 位小数）';
      }
    }
    return null;
  }

  bool _validRateText(String text) {
    final x = _parseRateX10(text);
    return x != null && Validators.validRate(x);
  }

  /// 计价单位（写入规则的 `unit`）：时价=小时、日价=天、计件=用户填写（可为空）。
  String? _unitValue() {
    switch (_method) {
      case PricingMethod.hourly:
        return '小时';
      case PricingMethod.daily:
        return '天';
      case PricingMethod.piece:
        final u = _unitCtrl.text.trim();
        return u.isEmpty ? null : u;
    }
  }

  /// 基础单价的单位标签（跟随计价方式）。
  String _baseRateUnit() {
    switch (_method) {
      case PricingMethod.hourly:
        return '小时';
      case PricingMethod.daily:
        return '天';
      case PricingMethod.piece:
        return '件';
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }

  // ══════════════════════════════════════════════════════════════════════
  // 构建
  // ══════════════════════════════════════════════════════════════════════

  String get _title => _isEdit ? '编辑计价规则' : '新建计价规则';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('加载失败：$_error', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('该规则不存在或已被删除', textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final block = _blockReason();
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_isEdit) _editBanner(),
          _sectionTitle('基本信息'),
          _card([
            _label('规则名 / 工序', required: true),
            TextField(
              controller: _nameCtrl,
              enabled: !_saving,
              decoration: InputDecoration(
                hintText: '如：木工 / 司机趟次 / 拆墙',
                errorText: _nameError,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _label('计价方式', required: true),
            SegmentedButton<PricingMethod>(
              segments: [
                for (final m in PricingMethod.values)
                  ButtonSegment(
                    value: m,
                    label: Text(EnumCodec.pricingMethod(m)), // 枚举文案走 EnumCodec
                  ),
              ],
              selected: {_method},
              onSelectionChanged: _saving
                  ? null
                  : (s) => setState(() => _method = s.first),
            ),
          ]),
          const SizedBox(height: 16),
          _sectionTitle('单价与单位'),
          _card([
            TextField(
              controller: _rateCtrl,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '基础单价（元/${_baseRateUnit()}）',
                hintText: '如 40 或 40.5',
                prefixText: '¥ ',
                errorText: _rateError,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_method == PricingMethod.piece) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _unitCtrl,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: '计价单位（计件必填）',
                  hintText: '如 趟 / ㎡ / 件',
                  errorText: _unitError,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _stdHoursCtrl,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '标准工时（小时，可空）',
                hintText: '仅用于加班判定提示，如 8',
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _sectionTitle('倍率'),
          _card([
            _rateField('加班倍率', _otCtrl, '如 1.5',
                valid: Validators.validRate, invalidMsg: _kRateMsg),
            const SizedBox(height: 12),
            _rateField('周末倍率', _wkCtrl, '如 1.0',
                valid: Validators.validRate, invalidMsg: _kRateMsg),
            const SizedBox(height: 12),
            _rateField('节假日倍率', _hdCtrl, '如 3.0',
                valid: Validators.validRate, invalidMsg: _kRateMsg),
            if (_method == PricingMethod.daily) ...[
              const SizedBox(height: 12),
              _rateField('半天折算比', _halfDayCtrl, '如 0.5',
                  valid: Validators.validHalfDayRatio,
                  invalidMsg: '需为 0~1 的数字（精度 0.1，如 0.5）'),
            ],
            const SizedBox(height: 12),
            // 倍率口径说明（AC-P09-05，固定文案逐字）。
            const Text(
              '同时命中多个倍率时取最高档，不叠加。倍率只作用于本条规则。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ]),
          const SizedBox(height: 16),
          _sectionTitle('生效与状态'),
          _card([
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('生效日期'),
              subtitle: Text(
                _effectiveDate == null
                    ? '未设置（仅作提示，不影响历史记录）'
                    : '${_fmtDate(_effectiveDate!)}（仅作提示，不影响历史记录）',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_effectiveDate != null)
                    IconButton(
                      tooltip: '清除',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: _saving ? null : _clearEffectiveDate,
                    ),
                  const Icon(Icons.event),
                ],
              ),
              onTap: _saving ? null : _pickEffectiveDate,
            ),
            const Divider(height: 1),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: _saving ? null : (v) => setState(() => _enabled = v),
              title: const Text('启用'),
              subtitle: const Text('停用后不出现在记一笔的规则下拉里；历史记录不受影响'),
            ),
          ]),
          if (block != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 18, color: _kRedAmount),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    block,
                    style: const TextStyle(color: _kRedAmount, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      bottomNavigationBar: _buildBottomBar(block),
    );
  }

  /// 编辑态横幅（AC-P09-06 / AC-13）：改动只影响以后新建的记录 + 归档后重建行为明示
  /// （AC-P09-14 / `02 §D.8:648`）。
  Widget _editBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFE082)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline, size: 18, color: Color(0xFFF57F17)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '改动只影响以后新建的记录，已记的历史金额不会变。'
              '倍率只作用于本条规则：用相同的计价方式与单价记账时，'
              '若未命中本规则，会自动新建一条（默认倍率 1.0）。',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF5D4037)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rateField(
    String label,
    TextEditingController ctrl,
    String hint, {
    required bool Function(int x10) valid,
    required String invalidMsg,
  }) {
    final x = _parseRateX10(ctrl.text);
    final bad = _submitted && (x == null || !valid(x));
    return TextField(
      controller: ctrl,
      enabled: !_saving,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(
        labelText: '$label（×10，如 $hint）',
        errorText: bad ? invalidMsg : null,
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _buildBottomBar(String? block) {
    final canSave = !_saving && block == null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            if (_isEdit) ...[
              OutlinedButton.icon(
                onPressed: _saving ? null : _confirmArchive,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除规则'),
                style: OutlinedButton.styleFrom(foregroundColor: _kRedAmount),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: FilledButton(
                onPressed: canSave ? _save : null,
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isEdit ? '保存修改' : '保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 小部件 ────────────────────────────────────────────────────────────

  Widget _card(List<Widget> children) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      );

  Widget _label(String text, {bool required = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text.rich(
          TextSpan(
            text: text,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
            children: [
              if (required)
                const TextSpan(text: ' *', style: TextStyle(color: _kRedAmount)),
            ],
          ),
        ),
      );

  // ── 字段级错误 ────────────────────────────────────────────────────────

  String? get _nameError =>
      (_submitted && _nameCtrl.text.trim().isEmpty) ? '规则名不能为空' : null;

  String? get _rateError {
    if (_rateCtrl.text.trim().isEmpty) return _submitted ? '请填写基础单价' : null;
    final fen = yuanToFen(_rateCtrl.text);
    if (fen == null) return '金额格式不正确（最多两位小数）';
    if (fen <= 0) return '基础单价必须大于 0';
    return null;
  }

  /// AC-P09-09：计件未填单位 → 字段红字（无需等提交即可见）。
  String? get _unitError =>
      (_method == PricingMethod.piece && _unitCtrl.text.trim().isEmpty)
          ? '计件必须填写计价单位'
          : null;

  // ── 文案 / 格式化（全整数，禁浮点）────────────────────────────────────

  /// 倍率显示：整数「×10」→ `3.0` 形式（**禁** `x / 10`）。
  static String _rateText(int x10) => '${x10 ~/ 10}.${x10 % 10}';

  /// 解析倍率文本（如 `3.0`）→ 整数「×10」。**全整数运算，禁 `double.parse`**。
  /// 非法（空 / 含非数字 / 小数位 > 1）→ `null`（由调用方给校验提示，不静默兜底）。
  static int? _parseRateX10(String text) {
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

  static bool _isDigits(String s) {
    if (s.isEmpty) return false;
    for (final c in s.codeUnits) {
      if (c < 0x30 || c > 0x39) return false;
    }
    return true;
  }

  /// 标准工时（物理量）显示：整数不带小数点（8.0 → '8'）。
  static String _fmtHours(double h) {
    final s = h.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _two(int n) => n < 10 ? '0$n' : '$n';
}
