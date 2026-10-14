/// P02 · 秒级快记弹层（Wave D1 新建，`16-WaveD1-实现设计.md §2.3`）。
///
/// **形态**：底部弹层 `showModalBottomSheet`（`07:254` / `:394`：「高频轻量录入用弹层」）。
/// 自下而上：公司（默认上次）→ 规则（默认上次）→ **大字数量输入**（打开即聚焦数字键盘，≥32sp）
/// → 实时金额预览 → `保存`。归属日**默认今天**，可由入口预置（P04）；要改日期 → 「展开」切 P02b 完整表单。
///
/// **默认值（AC-P02-02，零依赖派生）**：读 `listWorkRecords()`（`database.dart:619-633`，
/// `ORDER BY attribution_date DESC, created_at DESC`）**首条**的 `companyId` / `pricingRuleId` /
/// `qtySnapshot` 作默认；命中公司已停用/已删（不在 `listCompanies()` 默认结果里）→ 回退
/// 「第一个启用公司」，**不报错**（`07:283`）。
///
/// **下拉数据源（默认参数 = 仅启用项）**：
///   - 公司：`listCompanies()`（停用/已删不进快记，AC-P02-07 / AC-19）；
///   - 规则：`listPricingRules({companyId})`（仅启用规则）。
///
/// **草稿分支（主理人 Q-2 = A）**：数量为 0/空 → **允许落草稿**
/// （`status: RecordStatus.draft`、`amountSnapshot: 0`）+ 提示「已存为草稿，补上时长再算金额」。
///
/// **★ 日期上下文 `D`（D1-c 口径，补设计 §2.3 接线表之漏）**：弹层是**新建路径的第二个入口**
/// （另一个是 `work_form_page.dart`）。依 `03:327`「引擎只读 `D.isWeekend`/`D.isHoliday`，
/// 标记由**调用方**在构造输入时算好」——本弹层即那个调用方，故**必须**调 `day_context.dart` 的
/// **唯一构造点** [resolveDayContext]，并把结果经 `AmountInput.isWeekend`/`isHoliday` 传入引擎。
/// 否则**节假日倍率在弹层这条路径上完全不生效**（用户诉求「节假日倍率配 3.0，那天按 3.0 算」
/// 会在弹层路径上回归）。
///
/// **红线**：写库只走 `upsertWorkRecord`（`database.dart:596-600`），**不触碰历史记录**
/// （改价不回改历史）；金额整数「分」、倍率整数「×10」，**全整数运算，禁浮点**。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/pricing_rule.dart';
import '../models/types.dart';
import '../models/work_record.dart';
import '../services/amount_engine.dart';
import '../services/day_context.dart';
import '../services/enum_codec.dart';
import '../services/id_gen.dart';
import '../services/validators.dart';
import 'company_page.dart';
import 'rule_edit_page.dart';
import 'widgets/money.dart';
import 'work_form_page.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

class QuickAddSheet extends StatefulWidget {
  const QuickAddSheet({super.key, this.initialCompanyId, this.initialDate});

  /// 入口预置公司（T-1，可空）：P07「+ 记一笔」等入口传入；命中已停用/已删则忽略。
  final String? initialCompanyId;

  /// 入口预置归属日（T-1，可空）：P04「+ 记一笔」传入；为空 = 今天。
  final DateTime? initialDate;

  /// 以底部弹层形式展示秒级快记（`showModalBottomSheet`）。
  ///
  /// [companyId] 入口预置公司（可空）；[date] 入口预置归属日（可空，为空 = 今天）。
  static Future<void> show(BuildContext context,
      {String? companyId, DateTime? date}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => QuickAddSheet(initialCompanyId: companyId, initialDate: date),
    );
  }

  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<QuickAddSheet> {
  final AppDatabase _db = AppDatabase.instance;

  // ── 文本控制器 ──
  final TextEditingController _qtyCtrl = TextEditingController();

  // ── 载入态 ──
  bool _loading = true;
  Object? _loadError;

  // ── 表单态 ──
  List<Company> _companies = const <Company>[];
  String? _companyId;

  /// 该公司**启用**规则（`listPricingRules(companyId:)` 默认参数 = 仅启用）。
  List<PricingRule> _rules = const <PricingRule>[];
  String? _ruleId;

  /// 「上次规则」默认项（来自 `listWorkRecords()` 首条）。
  String? _preferredRuleId;

  /// 日期上下文 `D`（D1-c）：唯一构造点在 `day_context.dart`。弹层归属日默认今天，可由入口预置（P04）。
  DayContext _dayCtx = DayContext.none;

  /// 日价：整天 / 半天。
  bool _fullDay = true;

  /// 跨夜结论（AC-11）。
  bool _overnight = false;

  bool _saving = false;

  PricingRule? get _selectedRule {
    final id = _ruleId;
    if (id == null) return null;
    for (final r in _rules) {
      if (r.id == id) return r;
    }
    return null;
  }

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// 归属日（归一到日）：入口预置优先，为空 = 今天（与 [_today] 同口径）。
  DateTime get _workDate {
    final d = widget.initialDate ?? _today();
    return DateTime(d.year, d.month, d.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════
  // 载入
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _load() async {
    try {
      final companies = await _db.listCompanies();
      // 「上次记录」读失败只影响默认项，不阻塞弹层。
      List<WorkRecord> recent = const <WorkRecord>[];
      try {
        recent = await _db.listWorkRecords();
      } catch (_) {
        // 忽略：默认项缺失不影响可用性。
      }
      final last = recent.isEmpty ? null : recent.first;

      // 公司：上次（若仍启用）→ 入口预置（若启用）→ 第一个启用公司。
      String? cid = last?.companyId;
      if (cid == null || !companies.any((c) => c.id == cid)) {
        cid = widget.initialCompanyId;
        if (cid == null || !companies.any((c) => c.id == cid)) {
          cid = companies.isEmpty ? null : companies.first.id;
        }
      }
      _preferredRuleId = last?.pricingRuleId;

      // 日期上下文 D（唯一构造点；归属日 = 默认今天，可由入口预置）。
      final ledgerId = AppState.ledgerId;
      DayContext ctx = DayContext.none;
      if (ledgerId != null) {
        try {
          ctx = await resolveDayContext(ledgerId: ledgerId, workDate: _workDate);
        } catch (_) {
          ctx = DayContext.none;
        }
      }

      if (!mounted) return;
      setState(() {
        _companies = companies;
        _companyId = cid;
        _dayCtx = ctx;
        _loading = false;
      });

      // 上次数量回填（AC-P02-02）：仅在正数时回填，0 留空。
      final lastQty = last?.qtySnapshot;
      if (lastQty != null && lastQty > 0) {
        _qtyCtrl.text = _fmtQty(lastQty);
      }

      await _loadRules(cid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e;
      });
    }
  }

  /// 加载该公司**启用**规则，并按「上次规则优先」选中（`07:261`）。
  Future<void> _loadRules(String? companyId) async {
    if (companyId == null) {
      if (!mounted) return;
      setState(() {
        _rules = const <PricingRule>[];
        _ruleId = null;
      });
      return;
    }
    try {
      final rules = await _db.listPricingRules(companyId: companyId);
      PricingRule? sel;
      final preferred = _preferredRuleId;
      if (preferred != null) {
        for (final r in rules) {
          if (r.id == preferred) {
            sel = r;
            break;
          }
        }
      }
      sel ??= rules.isEmpty ? null : rules.first;
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _ruleId = sel?.id;
      });
    } catch (e) {
      if (mounted) _snack('加载计价规则失败：$e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // 引擎输入（D 接线：★ 弹层必须传 isWeekend/isHoliday）
  // ══════════════════════════════════════════════════════════════════════

  AmountInput _buildInput() {
    final ctx = _dayCtx;
    final method = _selectedRule?.method ?? PricingMethod.hourly;
    switch (method) {
      case PricingMethod.hourly:
        return AmountInput(
          manualHours: double.tryParse(_qtyCtrl.text.trim()),
          overnight: _overnight,
          isWeekend: ctx.isWeekend,
          isHoliday: ctx.isHoliday,
        );
      case PricingMethod.daily:
        return AmountInput(
          fullDay: _fullDay,
          isWeekend: ctx.isWeekend,
          isHoliday: ctx.isHoliday,
        );
      case PricingMethod.piece:
        return AmountInput(
          pieceCount: double.tryParse(_qtyCtrl.text.trim()),
          isWeekend: ctx.isWeekend,
          isHoliday: ctx.isHoliday,
        );
    }
  }

  AmountResult? _preview() {
    final rule = _selectedRule;
    if (rule == null || _companyId == null) return null;
    return const AmountEngine().compute(rule: rule, input: _buildInput());
  }

  /// 数量输入框的格式/符号错误（**字段红字，不用 Toast**，`07:268`）。
  String? get _qtyTextError {
    if (_selectedRule?.method == PricingMethod.daily) return null;
    final raw = _qtyCtrl.text.trim();
    if (raw.isEmpty) return null;
    final v = double.tryParse(raw);
    if (v == null) {
      return _selectedRule?.method == PricingMethod.piece ? '件数格式不正确' : '小时数格式不正确';
    }
    if (v < 0) return '不能为负数';
    return null;
  }

  /// 保存按钮的禁用原因（null = 可保存）。所有结构性硬要求收敛到一处。
  String? get _blockReason {
    if (_companies.isEmpty) return '还没有公司，先建一个';
    if (_companyId == null) return '请选择公司';
    if (_rules.isEmpty) return '该公司还没配计价规则';
    final q = _qtyTextError;
    if (q != null) return q;
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════
  // 保存
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _save() async {
    if (_saving) return;
    final block = _blockReason;
    if (block != null) {
      _snack(block);
      return;
    }
    final rule = _selectedRule;
    if (rule == null) return;

    setState(() => _saving = true);
    var closed = false;
    try {
      final r = const AmountEngine().compute(rule: rule, input: _buildInput());

      // 跨夜（AC-11）：结束<开始且未开跨夜 → 弹确认，**不静默算负数**。
      if (r.needsOvernightConfirm) {
        setState(() => _saving = false);
        await _promptOvernight();
        return;
      }
      if (r.isInvalidInput) {
        // 字段红字（不用 Toast）：置回可编辑态，由 _qtyTextError 呈现。
        setState(() => _saving = false);
        return;
      }

      // 草稿分支（Q-2 = A）：数量为 0/空 → 落草稿（status=draft、amount=0）。
      final isDraft = r.isDraft;
      final now = DateTime.now();
      final rec = WorkRecord(
        id: newId('wr'),
        workDate: _workDate,
        companyId: _companyId!,
        pricingRuleId: rule.id,
        methodSnapshot: rule.method,
        qtySnapshot: r.qty,
        qtyUnitSnapshot: r.qtyUnit,
        overnight: _overnight,
        rateSnapshot: r.actualRate,
        rateDetailSnapshot: r.rateDetail,
        amountSnapshot: r.amount,
        amountSource: r.source,
        autoReferenceAmount: r.autoReference,
        currencySnapshot: 'CNY',
        status: isDraft ? RecordStatus.draft : RecordStatus.confirmed,
        createdAt: now,
        updatedAt: now,
      );

      // 复用冻结校验器（与其它写入路径同一判据），不自己发明规则。
      final errs = Validators.workRecord(rec);
      if (errs.isNotEmpty) {
        setState(() => _saving = false);
        _snack(errs.join('；'));
        return;
      }

      await _db.upsertWorkRecord(rec);
      dataBus.dataChanged(); // 广播：P01/P03/P11 随之刷新（AC-P02-06）
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      closed = true;
      messenger.showSnackBar(SnackBar(
        content: Text(isDraft ? '已存为草稿，补上时长再算金额' : '已记上'),
      ));
    } catch (e) {
      // 写入失败 → SnackBar + **保留用户输入**（不 pop、不清空，AC-P02-09）。
      if (mounted) {
        setState(() => _saving = false);
        _snack('保存失败：$e');
      }
    } finally {
      if (!closed && mounted && _saving) setState(() => _saving = false);
    }
  }

  Future<void> _promptOvernight() async {
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('是否跨夜？'),
        content: const Text('结束时间早于开始时间。是否按「跨夜」计算（结束时间算作次日）？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('否'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('是'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (yes == true) {
      setState(() => _overnight = true);
      await _save();
    } else {
      _snack('结束时间早于开始时间（未按跨夜），请调整时间');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // 出口：展开 P02b / 去 P08 / 去 P09
  // ══════════════════════════════════════════════════════════════════════

  void _expandToFullForm() {
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => WorkFormPage(companyId: _companyId, initialDate: _workDate),
    ));
  }

  Future<void> _gotoCompanyPage() async {
    final navigator = Navigator.of(context);
    navigator.pop();
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => const CompanyPage(),
    ));
  }

  Future<void> _gotoRuleEditor() async {
    final cid = _companyId;
    if (cid == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RuleEditPage(companyId: cid),
    ));
    if (!mounted) return;
    await _loadRules(cid); // 返回后规则下拉同步刷新
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }

  // ══════════════════════════════════════════════════════════════════════
  // 构建
  // ══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _loading
          ? const SizedBox(
              height: 220,
              child: Center(child: CircularProgressIndicator()),
            )
          : _loadError != null
              ? _errorView()
              : _body(),
    );
  }

  Widget _errorView() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: _kRedAmount),
            const SizedBox(height: 12),
            Text('加载失败：$_loadError', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );

  Widget _body() {
    final preview = _preview();
    final block = _blockReason;
    final canSave = !_saving && block == null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('快记一笔',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  // 归属日默认今天（只读），可由入口预置（P04）；改日期 → 展开完整表单。
                  Text(
                      _workDate == _today()
                          ? '今天 ${_fmtDate(_workDate)}'
                          : _fmtDate(_workDate),
                      style: const TextStyle(fontSize: 13, color: Colors.black54)),
                ],
              ),
              const SizedBox(height: 12),

              // 无公司 → 顶部提示 + 去 P08 入口，阻止保存。
              if (_companies.isEmpty) _emptyCompanyBanner(),

              _label('公司', required: true),
              DropdownButtonFormField<String>(
                initialValue: _companyId,
                isExpanded: true,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: [
                  for (final c in _companies)
                    DropdownMenuItem<String>(
                      value: c.id,
                      child: Text(c.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _saving || _companies.isEmpty
                    ? null
                    : (id) async {
                        setState(() => _companyId = id);
                        await _loadRules(id);
                      },
              ),
              const SizedBox(height: 12),

              _label('计价规则', required: true),
              DropdownButtonFormField<String>(
                initialValue: _ruleId,
                isExpanded: true,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                hint: const Text('（无启用规则）'),
                items: [
                  for (final r in _rules)
                    DropdownMenuItem<String>(
                      value: r.id,
                      child: Text(
                        '${r.name} · ${EnumCodec.pricingMethod(r.method)} · '
                        '${fenToYuan(r.baseRate)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving || _rules.isEmpty
                    ? null
                    : (id) => setState(() => _ruleId = id),
              ),
              if (_rules.isEmpty && _companyId != null) ...[
                const SizedBox(height: 6),
                _noRuleBanner(),
              ],
              const SizedBox(height: 16),

              // ── 大字数量输入（打开即聚焦数字键盘）──
              _qtyField(),
              const SizedBox(height: 16),

              // ── 实时金额预览 ──
              _previewCard(preview),
              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : _expandToFullForm,
                      child: const Text('展开（补时间/备注）'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: canSave ? _save : null,
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyCompanyBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kRedAmount),
      ),
      child: Row(
        children: [
          const Expanded(child: Text('还没有公司，先建一个', style: TextStyle(color: _kRedAmount))),
          TextButton(onPressed: _saving ? null : _gotoCompanyPage, child: const Text('去新建')),
        ],
      ),
    );
  }

  Widget _noRuleBanner() {
    return Row(
      children: [
        const Expanded(
          child: Text('该公司还没配计价规则',
              style: TextStyle(fontSize: 12, color: _kRedAmount)),
        ),
        TextButton(onPressed: _saving ? null : _gotoRuleEditor, child: const Text('去配置')),
      ],
    );
  }

  Widget _qtyField() {
    final rule = _selectedRule;
    if (rule?.method == PricingMethod.daily) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('数量'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('整天')),
              ButtonSegment(value: false, label: Text('半天')),
            ],
            selected: {_fullDay},
            onSelectionChanged: _saving
                ? null
                : (s) => setState(() => _fullDay = s.first),
          ),
        ],
      );
    }
    final isPiece = rule?.method == PricingMethod.piece;
    return TextField(
      controller: _qtyCtrl,
      enabled: !_saving,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      // 大字数量输入（≥32sp，AC-P02-01）。
      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: isPiece ? '件数' : '小时数',
        hintText: '0',
        suffixText: isPiece ? (rule?.unit ?? '件') : '小时',
        errorText: _qtyTextError,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _previewCard(AmountResult? r) {
    if (r == null) {
      return _card([
        const Text('选择公司与规则后，这里会实时显示金额。',
            style: TextStyle(color: Colors.black54)),
      ]);
    }
    if (r.isInvalidInput) {
      return _card([
        const Text('输入不合法：请检查数量（不能为负数）。',
            style: TextStyle(color: _kRedAmount)),
      ]);
    }
    if (r.needsOvernightConfirm && !_overnight) {
      return _card([
        const Text('结束时间早于开始时间，请确认是否跨夜。',
            style: TextStyle(color: _kRedAmount)),
      ]);
    }
    if (r.isDraft) {
      return _card([
        const Text('数量为 0，保存后将存为草稿（补上时长再算金额）。',
            style: TextStyle(color: _kRedAmount)),
      ]);
    }
    final unit = (r.qtyUnit == null || r.qtyUnit!.isEmpty) ? '' : ' ${r.qtyUnit}';
    final rateNote =
        r.rateDetail.appliedRate == 10 ? '无倍率' : '含倍率 ×${_fmtRate(r.rateDetail.appliedRate)}';
    return _card([
      Text(
        fenToYuan(r.amount),
        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: _kRedAmount),
      ),
      const SizedBox(height: 6),
      Text(
        '实际单价 ${fenToYuan(r.actualRate)} × 数量 ${_fmtQty(r.qty)}$unit = ${fenToYuan(r.amount)}（$rateNote）',
        style: const TextStyle(fontSize: 13, color: Colors.black87),
      ),
    ]);
  }

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

  // ── 文案 / 格式化（全整数，禁浮点）────────────────────────────────────

  /// 数量展示：整数不带小数点（8.0 → '8'）。
  static String _fmtQty(double q) {
    final s = q.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// 倍率（×10）→ '3.0'（**禁** `x / 10`）。
  static String _fmtRate(int x10) => '${x10 ~/ 10}.${x10 % 10}';

  static String _fmtDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _two(int n) => n < 10 ? '0$n' : '$n';
}
