/// 记一笔工作页（新建 / 编辑）。
///
/// 契约来源：`_scratch/_ui/UI_BASE_CONTRACT.md`（Wave 1 冻结）与 03 §4。
///
/// 设计要点（为什么这么做）：
///  - **元↔分只走 `yuanToFen` 字符串解析**：避免 `double × 100` 的浮点 ±1 分误差（契约 §2 纪律）。
///  - **保存时才 `ensureRule`**：预览阶段用内存里的临时规则算数，避免「每敲一个字符就写一次库」；
///    正式保存时以落库规则重算，保证 `WorkRecord` 的快照与规则本身同源。
///  - **引擎三个特殊返回不静默**：`isInvalidInput` / `needsOvernightConfirm` / `isDraft`
///    一律「提示 + 禁用保存」，绝不让负数或 0 金额悄悄落库（AC-11 / AC-12）。
///  - **编辑态只改「备注 + 归属日」**：金额快照是历史，改价不回改历史（底线 2）。
///    走 `updateWorkRecordMeta`（其 SQL 语句层就不含快照列，物理上改不到金额）。
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
import '../services/pricing_bootstrap.dart';
import '../services/validators.dart';
import 'widgets/company_picker.dart';
import 'widgets/money.dart';

/// 时价的「数量输入」子模式：手填小时 / 起止时间。
///
/// 二者必须互斥：引擎里 `manualHours` 优先于起止时间，若两路同时喂入，
/// 用户看到的「起止时间」会被静默忽略——所以 UI 强制只走一路。
enum _HourlyMode { manual, range }

/// 表单校验失败的内部信号（只用于把「校验拒绝」与「真异常」分开处理）。
class _FormReject implements Exception {
  _FormReject(this.message);
  final String message;
  @override
  String toString() => message;
}

class WorkFormPage extends StatefulWidget {
  /// 编辑模式传入被编辑记录 id；新建时为 `null`。
  const WorkFormPage({super.key, this.id, this.companyId, this.initialDate});

  final String? id;

  /// 新建态预置公司（T-1：P07「+ 记一笔工作」）；**编辑态忽略**（由 DB 回填）。
  final String? companyId;

  /// 新建态预置归属日（T-1：P04「+ 记一笔」）；**编辑态忽略**（由 DB 回填）。
  final DateTime? initialDate;

  @override
  State<WorkFormPage> createState() => _WorkFormPageState();
}

class _WorkFormPageState extends State<WorkFormPage> {
  // ── 文本控制器 ──
  final TextEditingController _hoursCtrl = TextEditingController();
  final TextEditingController _pieceCtrl = TextEditingController();
  final TextEditingController _unitCtrl = TextEditingController();
  final TextEditingController _rateCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();

  // ── 载入态 ──
  bool _loading = true;
  String? _loadError; // 载入抛异常时的文案
  bool _missing = false; // 编辑态：id 查不到记录

  // ── 表单态 ──
  List<Company> _companies = const <Company>[];
  String? _companyId;

  /// 该公司**启用**规则（D1-b 规则下拉；`listPricingRules(companyId:)` 默认参数=仅启用）。
  List<PricingRule> _rules = const <PricingRule>[];

  /// 日期上下文 `D`（D1-c）：`isWeekend` / `isHoliday` 的**唯一构造点**在 `day_context.dart`。
  /// 仅在**新建路径**随 `_workDate` 刷新；编辑态不重算（读回冻结快照，R-G05）。
  DayContext _dayCtx = DayContext.none;

  DateTime _workDate = _today();
  PricingMethod _method = PricingMethod.hourly;
  _HourlyMode _hourlyMode = _HourlyMode.manual;
  TimeOfDay? _start;
  TimeOfDay? _end;
  bool _fullDay = true;
  bool _isOvertime = false;

  /// 跨夜：只有用户在弹窗里选「是」之后才置 true（AC-11）。
  bool _overnight = false;

  /// 用户在弹窗里明确选了「否」→ 提示并禁用保存，绝不静默算负数。
  bool _overnightDeclined = false;

  /// 已弹过跨夜确认的「起止时间组合」指纹，防止同一组时间反复弹窗。
  String? _overnightPromptKey;

  // ── 编辑态 ──
  WorkRecord? _existing;
  String? _companyName;

  bool _saving = false;

  bool get _isEdit => widget.id != null;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hoursCtrl.dispose();
    _pieceCtrl.dispose();
    _unitCtrl.dispose();
    _rateCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════
  // 载入
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _load() async {
    try {
      final companies = await AppDatabase.instance.listCompanies();
      WorkRecord? rec;
      String? companyName;
      if (widget.id != null) {
        rec = await AppDatabase.instance.getWorkRecord(widget.id!);
        if (rec != null) {
          companyName = _nameOf(companies, rec.companyId);
          // 公司可能已软删而不在列表里：按 id 直取（getCompany 不过滤软删），保证编辑态能显示名字。
          companyName ??= (await AppDatabase.instance.getCompany(rec.companyId))?.name;
        }
      }
      if (!mounted) return;
      // 预置公司已停用/已删（MF-3）：**不回退**（避免静默记到错的公司），保持未选 + 首帧后一次性提示。
      var presetMissing = false;
      setState(() {
        _companies = companies;
        _existing = rec;
        _companyName = companyName;
        _missing = widget.id != null && rec == null;
        if (rec != null) {
          _workDate =
              DateTime(rec.workDate.year, rec.workDate.month, rec.workDate.day);
          _noteCtrl.text = rec.note ?? '';
        }
        // T-1（§3.3）：**仅新建态**生效；编辑态整体跳过（由 DB 回填，AC-P02-10）。
        if (widget.id == null) {
          final presetCompany = widget.companyId;
          if (presetCompany != null) {
            if (companies.any((c) => c.id == presetCompany)) {
              _companyId = presetCompany;
            } else {
              _companyId = null; // 不回退：保持未选，由用户显式重选
              presetMissing = true;
            }
          }
          final presetDate = widget.initialDate;
          if (presetDate != null) {
            _workDate =
                DateTime(presetDate.year, presetDate.month, presetDate.day);
          }
        }
        _loading = false;
      });
      if (widget.id == null) {
        // D1-b：仅新建态需规则下拉（编辑态只改「备注 + 归属日」）。
        await _loadRulesForCompany(_companyId);
        // D1-c：按归属日解析日期上下文 D（「首次固化时点」算好，R-G05）。
        await _refreshDayContext();
      }
      if (presetMissing) {
        // 一家公司都没有时（预置公司缺失 + 列表为空）→ 措辞改为「先建公司」。
        final missingMsg = companies.isEmpty
            ? '还没有公司，先建一个公司'
            : '该公司已停用或已删除，请重新选择公司';
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _snack(missingMsg);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  Future<void> _reloadCompanies() async {
    try {
      final list = await AppDatabase.instance.listCompanies();
      if (!mounted) return;
      setState(() => _companies = list);
    } catch (e) {
      _snack('加载公司列表失败：$e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // 规则下拉（D1-b）+ 日期上下文 D（D1-c）
  // ══════════════════════════════════════════════════════════════════════

  /// 加载该公司**启用**规则（`listPricingRules(companyId:)` 默认参数 = 仅启用）。
  ///
  /// 默认值「**上次规则优先**」（`07:261`）：读最近一条工作记录的 `pricingRuleId`；
  /// 命中且仍在**当前启用集**内 → 选中；否则取第一条启用规则；无启用规则 → 不选
  /// （保存时退回 `ensureRule` 兜底，D1-d 定案 A）。
  Future<void> _loadRulesForCompany(String? companyId) async {
    if (companyId == null || companyId.isEmpty) {
      if (!mounted) return;
      setState(() => _rules = const <PricingRule>[]);
      return;
    }
    try {
      final rules =
          await AppDatabase.instance.listPricingRules(companyId: companyId);
      String? preferred;
      try {
        final recent = await AppDatabase.instance.listWorkRecords();
        for (final w in recent) {
          if (w.pricingRuleId != null) {
            preferred = w.pricingRuleId;
            break;
          }
        }
      } catch (_) {
        // 「上次记录」读失败只影响默认选中项，不阻塞规则下拉。
      }
      PricingRule? sel;
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
      setState(() => _rules = rules);
      if (sel != null) _applyRule(sel);
    } catch (e) {
      _snack('加载计价规则失败：$e');
    }
  }

  /// 选中规则 → 联动回填「计价方式 + 单价 + 计件单位」（§2.2.2；三字段仍**可微调**）。
  void _applyRule(PricingRule r) {
    setState(() {
      _method = r.method;
      _rateCtrl.text = fenToYuanPlain(r.baseRate);
      _unitCtrl.text = r.unit ?? '';
      _resetOvernight(); // 换算法 → 旧的跨夜结论作废
    });
  }

  /// 规则下拉 onChanged：按 id 应用对应规则（联动回填）。
  void _selectRuleById(String? id) {
    if (id == null) return;
    for (final r in _rules) {
      if (r.id == id) {
        _applyRule(r);
        return;
      }
    }
  }

  /// 规则单价的单位后缀（下拉展示用）。
  String _unitSuffix(PricingRule r) {
    final u = r.unit?.trim() ?? '';
    return u.isEmpty ? '' : '/$u';
  }

  /// 命中当前表单字段的规则：仅当 `(method, baseRate, unit)` 与该规则**完全一致**时命中。
  ///
  /// 用户微调字段后自动失配 → 预览取模型默认倍率、保存退回 `ensureRule`（新建的规则亦为
  /// 模型默认倍率）→ **预览与落库始终同源**（杜绝「预览一套、落库一套」，D1-b 目标）。
  PricingRule? get _matchedRule {
    final fen = yuanToFen(_rateCtrl.text);
    if (fen == null) return null;
    for (final r in _rules) {
      if (r.method == _method &&
          r.baseRate == fen &&
          r.unit == _unitFor(_method)) {
        return r;
      }
    }
    return null;
  }

  /// 刷新日期上下文 `D`（D1-c）：按当前 `_workDate` 调 `day_context.dart` 的**唯一构造点**。
  /// 结果随 `AmountInput` 进引擎 → 写入 `rateDetailSnapshot` 冻结（`03:328`）。
  Future<void> _refreshDayContext() async {
    final ledgerId = AppState.ledgerId;
    if (ledgerId == null) {
      if (mounted) setState(() => _dayCtx = DayContext.none);
      return;
    }
    try {
      final ctx =
          await resolveDayContext(ledgerId: ledgerId, workDate: _workDate);
      if (!mounted) return;
      setState(() => _dayCtx = ctx);
    } catch (_) {
      // 判定失败 → 保守兜底 none（不阻塞表单）。
      if (mounted) setState(() => _dayCtx = DayContext.none);
    }
  }

  static String? _nameOf(List<Company> list, String id) {
    for (final c in list) {
      if (c.id == id) return c.name;
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════
  // 金额预览（新建态）
  // ══════════════════════════════════════════════════════════════════════

  /// 预览用规则：**从选中规则取三档倍率与半天折算比**；无匹配规则时退回模型默认
  /// （加班 15 / 周末 10 / 节假日 10 / 半天 5，与 `ensureRule` 新建的规则一致）。
  ///
  /// 故预览金额与保存金额一致。**基础版本波（Wave D1）已交付 P09 规则管理页**
  /// （`07 §3.9` / U-3）；同 (公司,方式,单价,单位) 仍复用同一条规则，
  /// 但**规则倍率随所选规则生效**（D1-b），杜绝「预览一套、落库一套」。
  PricingRule _previewRule(int baseRateFen) {
    final now = DateTime.now();
    final r = _matchedRule;
    return PricingRule(
      id: r?.id ?? '__preview__',
      companyId: _companyId ?? '',
      name: r?.name ?? '预览',
      method: _method,
      baseRate: baseRateFen,
      unit: _unitFor(_method),
      standardHours: r?.standardHours,
      halfDayRatio: r?.halfDayRatio ?? 5,
      overtimeRate: r?.overtimeRate ?? 15,
      weekendRate: r?.weekendRate ?? 10,
      holidayRate: r?.holidayRate ?? 10,
      effectiveDate: r?.effectiveDate,
      enabled: r?.enabled ?? true,
      createdAt: r?.createdAt ?? now,
      updatedAt: now,
    );
  }

  /// 单价单位（写入规则的 `unit`）：时价=小时、日价=天、计件=用户填写的单位。
  String? _unitFor(PricingMethod m) {
    switch (m) {
      case PricingMethod.hourly:
        return '小时';
      case PricingMethod.daily:
        return '天';
      case PricingMethod.piece:
        final u = _unitCtrl.text.trim();
        return u.isEmpty ? null : u;
    }
  }

  /// 构造引擎输入。**同一时刻只喂一路数量来源**（见 [_HourlyMode] 注释）。
  ///
  /// **D1-c**：4 处 `AmountInput` 各处均喂 `isWeekend` / `isHoliday`（取自 `_dayCtx`，
  /// 由 `day_context.dart` 在 `_workDate` 变化时算好）。本方法为**预览与保存共用**
  /// （`_previewResult` 与 `_saveNew` 同调）→ 改一处两处同时生效（`16 §3.3.3`）。
  AmountInput _buildInput({required bool overnight}) {
    switch (_method) {
      case PricingMethod.hourly:
        if (_hourlyMode == _HourlyMode.manual) {
          return AmountInput(
            manualHours: double.tryParse(_hoursCtrl.text.trim()),
            overnight: overnight,
            isOvertime: _isOvertime,
            isWeekend: _dayCtx.isWeekend,
            isHoliday: _dayCtx.isHoliday,
          );
        }
        return AmountInput(
          start: _combineTime(_start),
          end: _combineTime(_end),
          overnight: overnight,
          isOvertime: _isOvertime,
          isWeekend: _dayCtx.isWeekend,
          isHoliday: _dayCtx.isHoliday,
        );
      case PricingMethod.daily:
        return AmountInput(
          fullDay: _fullDay,
          isOvertime: _isOvertime,
          isWeekend: _dayCtx.isWeekend,
          isHoliday: _dayCtx.isHoliday,
        );
      case PricingMethod.piece:
        return AmountInput(
          pieceCount: double.tryParse(_pieceCtrl.text.trim()),
          isOvertime: _isOvertime,
          isWeekend: _dayCtx.isWeekend,
          isHoliday: _dayCtx.isHoliday,
        );
    }
  }

  /// 起止时间：日期部分统一用「归属日」，只保留 hh:mm（引擎只比较时分）。
  DateTime? _combineTime(TimeOfDay? t) {
    if (t == null) return null;
    return DateTime(_workDate.year, _workDate.month, _workDate.day, t.hour,
        t.minute);
  }

  /// 数量输入框的「格式」错误（区别于引擎的语义错误：负数件数等由引擎判）。
  String? get _qtyTextError {
    final raw = _method == PricingMethod.hourly && _hourlyMode == _HourlyMode.manual
        ? _hoursCtrl.text.trim()
        : _method == PricingMethod.piece
            ? _pieceCtrl.text.trim()
            : '';
    if (raw.isEmpty) return null;
    if (double.tryParse(raw) == null) {
      return _method == PricingMethod.piece ? '件数格式不正确' : '小时数格式不正确';
    }
    return null;
  }

  AmountResult? _previewResult() {
    final fen = yuanToFen(_rateCtrl.text);
    if (fen == null || fen <= 0) return null; // 单价没填对 → 无法算，不硬凑
    final rule = _previewRule(fen);
    return const AmountEngine().compute(
      rule: rule,
      input: _buildInput(overnight: _overnight),
    );
  }

  /// 保存按钮的禁用原因（null = 可保存）。所有「硬要求」都收敛到这里，
  /// 保证按钮状态与提示文案永远一致。
  String? _blockReason(AmountResult? r, String? qtyTextError) {
    if (_companyId == null) return '请选择公司';
    final fen = yuanToFen(_rateCtrl.text);
    if (fen == null || fen <= 0) return '请填写有效单价（> 0）';
    if (qtyTextError != null) return qtyTextError;
    if (_method == PricingMethod.piece && _unitCtrl.text.trim().isEmpty) {
      return '请填写计件单位（如「趟」「㎡」）';
    }
    if (r == null) return '请完善数量';
    if (r.isInvalidInput) return '输入不合法，请检查数量与单价';
    if (r.needsOvernightConfirm) {
      return _overnightDeclined
          ? '结束时间早于开始时间（已选择不跨夜），请调整时间'
          : '待确认是否跨夜（见弹窗）';
    }
    if (r.isDraft) return '数量为 0，请填写数量';
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════
  // 交互
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _workDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _workDate = DateTime(picked.year, picked.month, picked.day);
      // 归属日变了，起止时间的日期部分随之改变 → 之前确认过的跨夜结论作废，重新确认。
      _resetOvernight();
    });
    // D1-c：归属日变化 → 重算日期上下文 D（仅新建路径；编辑态不重算）。
    if (!_isEdit) await _refreshDayContext();
  }

  Future<void> _pickTime({required bool isStart}) async {
    final t = await showTimePicker(
      context: context,
      initialTime: isStart
          ? (_start ?? const TimeOfDay(hour: 8, minute: 0))
          : (_end ?? const TimeOfDay(hour: 17, minute: 0)),
    );
    if (t == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = t;
      } else {
        _end = t;
      }
      _resetOvernight();
    });
  }

  /// 起止时间/归属日变化 → 清空跨夜结论与弹窗指纹，让用户能重新被询问（AC-11）。
  void _resetOvernight() {
    _overnight = false;
    _overnightDeclined = false;
    _overnightPromptKey = null;
  }

  Future<void> _promptOvernight(String key) async {
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
    setState(() {
      if (yes == true) {
        _overnight = true;
        _overnightDeclined = false;
      } else if (yes == false) {
        // 不跨夜 → 保持 _overnight=false，由 _blockReason 提示并禁用保存（不得静默算负数）。
        _overnight = false;
        _overnightDeclined = true;
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════
  // 保存 / 删除
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _save() async {
    if (_saving) return;
    if (_isEdit) {
      await _saveEdit();
    } else {
      await _saveNew();
    }
  }

  Future<void> _saveNew() async {
    // 前置校验（与按钮禁用条件同源，双保险：防「回车提交」等旁路）。
    final rateFen = yuanToFen(_rateCtrl.text);
    if (rateFen == null || rateFen <= 0) {
      _snack('请填写有效单价（> 0）');
      return;
    }
    if (_companyId == null) {
      _snack('请选择公司');
      return;
    }
    if (_method == PricingMethod.piece && _unitCtrl.text.trim().isEmpty) {
      _snack('请填写计件单位（如「趟」「㎡」）');
      return;
    }
    final qtyErr = _qtyTextError;
    if (qtyErr != null) {
      _snack(qtyErr);
      return;
    }

    setState(() => _saving = true);
    var popped = false;
    try {
      // D1-b：命中选中规则 → 直接以该**落库规则**重算（倍率随所选规则生效）；
      // 未命中（用户微调后无对应启用规则 / 公司下无启用规则）→ 退回 `ensureRule` 兜底
      // （D1-d 定案 A：自动建规则沿用模型默认倍率，与预览同源）。
      final matched = _matchedRule;
      final rule = matched ??
          await ensureRule(
            companyId: _companyId!,
            method: _method,
            baseRate: rateFen,
            unit: _unitFor(_method),
          );
      final r = const AmountEngine().compute(
        rule: rule,
        input: _buildInput(overnight: _overnight),
      );

      // 引擎三个特殊返回：一律拒绝落库并如实提示（硬要求）。
      if (r.isInvalidInput) {
        throw _FormReject('输入不合法，请检查数量与单价');
      }
      if (r.needsOvernightConfirm) {
        throw _FormReject('结束时间早于开始时间，请确认是否跨夜，或调整时间');
      }
      if (r.isDraft) {
        throw _FormReject('数量为 0，请填写数量后再保存');
      }

      final now = DateTime.now();
      final isHourlyRange =
          _method == PricingMethod.hourly && _hourlyMode == _HourlyMode.range;
      final note = _noteCtrl.text.trim();
      final rec = WorkRecord(
        id: newId('wr'),
        workDate: _workDate,
        companyId: _companyId!,
        pricingRuleId: rule.id,
        methodSnapshot: rule.method,
        qtySnapshot: r.qty,
        qtyUnitSnapshot: r.qtyUnit,
        startTime: isHourlyRange ? _combineTime(_start) : null,
        endTime: isHourlyRange ? _combineTime(_end) : null,
        overnight: _overnight,
        rateSnapshot: r.actualRate,
        rateDetailSnapshot: r.rateDetail,
        amountSnapshot: r.amount,
        amountSource: r.source,
        autoReferenceAmount: r.autoReference,
        currencySnapshot: 'CNY',
        note: note.isEmpty ? null : note,
        status: RecordStatus.confirmed,
        createdAt: now,
        updatedAt: now,
      );

      // 复用冻结校验器（与导入/其他写入路径同一判据），不自己发明规则。
      final errs = Validators.workRecord(rec);
      if (errs.isNotEmpty) throw _FormReject(errs.join('；'));

      await AppDatabase.instance.upsertWorkRecord(rec);
      dataBus.dataChanged();
      if (!mounted) return;
      Navigator.of(context).pop();
      popped = true;
    } on _FormReject catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('保存失败：$e');
    } finally {
      if (!popped && mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveEdit() async {
    setState(() => _saving = true);
    var popped = false;
    try {
      // 只改「备注 + 归属日」：走 Meta 补丁路径。
      // 注意补丁语义：note 传 null = 保留库内现值，故「清空备注」必须传空串（''）。
      await AppDatabase.instance.updateWorkRecordMeta(
        id: widget.id!,
        workDate: _workDate,
        note: _noteCtrl.text.trim(),
        updatedAt: DateTime.now(),
      );
      dataBus.dataChanged();
      if (!mounted) return;
      Navigator.of(context).pop();
      popped = true;
    } catch (e) {
      _snack('保存失败：$e');
    } finally {
      if (!popped && mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条工作记录？'),
        content: const Text('删除后不再计入应收。记录会以软删除方式保留在本地，随时可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    var popped = false;
    try {
      await AppDatabase.instance.softDeleteWorkRecord(widget.id!, DateTime.now());
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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }

  // ══════════════════════════════════════════════════════════════════════
  // 构建
  // ══════════════════════════════════════════════════════════════════════

  String get _title => _isEdit ? '编辑工作记录' : '记一笔工作';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('加载失败：$_loadError', textAlign: TextAlign.center),
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
            child: Text('该记录不存在或已被删除', textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final preview = _isEdit ? null : _previewResult();
    final qtyErr = _isEdit ? null : _qtyTextError;
    final block = _isEdit ? null : _blockReason(preview, qtyErr);

    // 跨夜确认（AC-11）：进入「结束<开始且未开跨夜」状态时弹一次；
    // 用指纹去重，避免每帧 rebuild 都弹。赋值不调 setState——本帧输出不受它影响。
    if (!_isEdit &&
        preview != null &&
        preview.needsOvernightConfirm &&
        !_overnight &&
        !_overnightDeclined) {
      final key = '${_start?.hour}:${_start?.minute}-${_end?.hour}:${_end?.minute}';
      if (_overnightPromptKey != key) {
        _overnightPromptKey = key;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _promptOvernight(key);
        });
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _isEdit
          ? _buildEditBody()
          : _buildCreateBody(preview: preview, qtyErr: qtyErr, block: block),
      bottomNavigationBar: _buildBottomBar(block),
    );
  }

  // ── 新建态 ────────────────────────────────────────────────────────────

  Widget _buildCreateBody({
    required AmountResult? preview,
    required String? qtyErr,
    required String? block,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _notice(
          '加班 / 周末 / 节假日倍率按所选计价规则自动套用（加班开关控制是否命中加班倍率；'
          '三档倍率可在公司详情 → 计价规则里配置，同时命中时取最高档、不叠加）。'
          '保存后金额与单价即为历史快照，日后改单价不会回改本条记录。',
        ),
        const SizedBox(height: 16),
        _sectionTitle('基本信息'),
        _card([
          _label('公司', required: true),
          CompanyPicker(
            companies: _companies,
            value: _companyId,
            onChanged: (id) async {
              setState(() => _companyId = id);
              // D1-b：换公司 → 重拉该公司启用规则（默认选中「上次规则」或首条）。
              await _loadRulesForCompany(id);
            },
            allowCreate: true,
            // 组件只负责取名，落库归本页（写路径单一）。
            onCreated: (c) async {
              try {
                await AppDatabase.instance.upsertCompany(c);
                dataBus.dataChanged();
                await _reloadCompanies();
              } catch (e) {
                _snack('新建公司失败：$e');
              }
            },
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('归属日'),
            subtitle: Text(_fmtDate(_workDate)),
            trailing: const Icon(Icons.event),
            onTap: _saving ? null : _pickDate,
          ),
        ]),
        const SizedBox(height: 16),
        _sectionTitle('计价规则'),
        _card([
          DropdownButton<String>(
            value: _matchedRule?.id,
            isExpanded: true,
            hint: const Text('（自定义：不套用已有规则）'),
            items: [
              for (final r in _rules)
                DropdownMenuItem<String>(
                  value: r.id,
                  child: Text(
                    '${r.name} · ${EnumCodec.pricingMethod(r.method)} · '
                    '${fenToYuan(r.baseRate)}${_unitSuffix(r)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _saving ? null : _selectRuleById,
          ),
          const SizedBox(height: 6),
          Text(
            _rules.isEmpty
                ? '该公司还没配计价规则。保存时会按「计价方式 + 单价 + 单位」自动建一条'
                    '（默认倍率 1.0）；可在公司详情 → 计价规则里配置。'
                : '选中规则会自动带出「计价方式 / 单价 / 单位」，可再微调；'
                    '倍率（加班 / 周末 / 节假日）取所选规则。',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]),
        const SizedBox(height: 16),
        _sectionTitle('计价方式'),
        _card([
          SegmentedButton<PricingMethod>(
            segments: const [
              ButtonSegment(value: PricingMethod.hourly, label: Text('时价')),
              ButtonSegment(value: PricingMethod.daily, label: Text('日价')),
              ButtonSegment(value: PricingMethod.piece, label: Text('计件')),
            ],
            selected: {_method},
            onSelectionChanged: (s) => setState(() {
              _method = s.first;
              _resetOvernight(); // 换算法 → 旧的跨夜结论作废
            }),
          ),
          const SizedBox(height: 12),
          ..._buildQtyFields(),
        ]),
        const SizedBox(height: 16),
        _sectionTitle('单价'),
        _card([
          TextField(
            controller: _rateCtrl,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '单价（元/${_rateUnitLabel()}）',
              hintText: '如 40 或 40.5',
              prefixText: '¥ ',
              errorText: _rateFieldError,
            ),
            onChanged: (_) => setState(() {}), // 驱动实时预览
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isOvertime,
            onChanged: _saving ? null : (v) => setState(() => _isOvertime = v),
            title: const Text('加班'),
            subtitle: const Text('按所选规则的加班倍率计（倍率可在公司详情 → 计价规则里配置）'),
          ),
        ]),
        const SizedBox(height: 16),
        _sectionTitle('金额预览'),
        _previewCard(preview, qtyErr),
        const SizedBox(height: 16),
        _sectionTitle('备注（可选）'),
        _card([
          TextField(
            controller: _noteCtrl,
            enabled: !_saving,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: '如：3 号楼外墙，含材料搬运',
              border: OutlineInputBorder(),
            ),
          ),
        ]),
        if (block != null) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 18, color: Colors.red),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  block,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 数量输入区：随计价方式切换。返回多个 widget 便于直接铺进卡片。
  List<Widget> _buildQtyFields() {
    switch (_method) {
      case PricingMethod.hourly:
        return [
          SegmentedButton<_HourlyMode>(
            segments: const [
              ButtonSegment(value: _HourlyMode.manual, label: Text('手填小时')),
              ButtonSegment(value: _HourlyMode.range, label: Text('起止时间')),
            ],
            selected: {_hourlyMode},
            onSelectionChanged: (s) => setState(() {
              _hourlyMode = s.first;
              _resetOvernight();
            }),
          ),
          const SizedBox(height: 12),
          if (_hourlyMode == _HourlyMode.manual)
            TextField(
              controller: _hoursCtrl,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '小时数',
                hintText: '如 8 或 7.5',
                suffixText: '小时',
                errorText: _qtyTextError,
              ),
              onChanged: (_) => setState(() {}),
            )
          else ...[
            _timeTile('开始时间', _start, () => _pickTime(isStart: true)),
            const SizedBox(height: 8),
            _timeTile('结束时间', _end, () => _pickTime(isStart: false)),
          ],
        ];
      case PricingMethod.daily:
        return [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('整天')),
              ButtonSegment(value: false, label: Text('半天')),
            ],
            selected: {_fullDay},
            onSelectionChanged: (s) => setState(() => _fullDay = s.first),
          ),
          const SizedBox(height: 8),
          const Text(
            '半天按规则的折算比计（可在公司详情 → 计价规则里调整）。',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ];
      case PricingMethod.piece:
        return [
          TextField(
            controller: _pieceCtrl,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '件数',
              hintText: '如 12 或 12.5',
              errorText: _qtyTextError,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _unitCtrl,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: '单位',
              hintText: '如 趟 / ㎡ / 件',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ];
    }
  }

  Widget _timeTile(String label, TimeOfDay? value, VoidCallback onTap) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(
        value == null
            ? '未设置'
            : MaterialLocalizations.of(context)
                .formatTimeOfDay(value, alwaysUse24HourFormat: true),
      ),
      trailing: const Icon(Icons.schedule),
      onTap: _saving ? null : onTap,
    );
  }

  Widget _previewCard(AmountResult? r, String? qtyErr) {
    if (r == null) {
      return _card([
        const Text(
          '填写公司、单价与数量后，这里会实时显示金额。',
          style: TextStyle(color: Colors.black54),
        ),
      ]);
    }
    if (r.isInvalidInput) {
      return _card([
        const Text(
          '输入不合法：请检查数量/单价（不能为负数，半天折算比需在 0~1 之间）。',
          style: TextStyle(color: Colors.red),
        ),
      ]);
    }
    if (r.needsOvernightConfirm && !_overnight) {
      return _card([
        Text(
          _overnightDeclined
              ? '结束时间早于开始时间，已选择不跨夜 → 无法计算，请调整时间。'
              : '结束时间早于开始时间，请在弹出的对话框中选择是否跨夜。',
          style: const TextStyle(color: Colors.red),
        ),
      ]);
    }
    if (r.isDraft) {
      return _card([
        const Text(
          '数量为 0，请填写数量（基础版不产生草稿记录）。',
          style: TextStyle(color: Colors.red),
        ),
      ]);
    }

    final unit = (r.qtyUnit == null || r.qtyUnit!.isEmpty) ? '' : ' ${r.qtyUnit}';
    final rateNote = r.rateDetail.appliedRate == 10
        ? '无倍率'
        : '含倍率 ×${_fmtRate(r.rateDetail.appliedRate)}';
    return _card([
      Text(
        fenToYuan(r.amount),
        style: const TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: Color(0xFFD32F2F), // 应收 → 红（契约 §3）
        ),
      ),
      const SizedBox(height: 6),
      Text(
        '实际单价 ${fenToYuan(r.actualRate)} × 数量 ${_fmtQty(r.qty)}$unit '
        '= ${fenToYuan(r.amount)}（$rateNote）',
        style: const TextStyle(fontSize: 13, color: Colors.black87),
      ),
      if (r.autoReference != null) ...[
        const SizedBox(height: 4),
        Text(
          '手工金额参考值：${fenToYuan(r.autoReference!)}',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ],
    ]);
  }

  // ── 编辑态 ────────────────────────────────────────────────────────────

  Widget _buildEditBody() {
    final w = _existing!;
    final isHourlyRange =
        w.methodSnapshot == PricingMethod.hourly && w.startTime != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _notice(
          '金额与单价为历史快照，本版不支持修改（改价不回改历史）；如需修正请删除后重新记录。'
          '本版仅允许修改「备注」与「归属日」。',
        ),
        const SizedBox(height: 16),
        _sectionTitle('记录内容（只读）'),
        _card([
          _kv('公司', _companyName ?? '（公司不可读，id：${w.companyId}）'),
          const Divider(height: 20),
          _kv('计价方式', _methodLabel(w.methodSnapshot)),
          const Divider(height: 20),
          _kv(
            '数量',
            '${_fmtQty(w.qtySnapshot)}${(w.qtyUnitSnapshot == null || w.qtyUnitSnapshot!.isEmpty) ? '' : ' ${w.qtyUnitSnapshot}'}',
          ),
          if (isHourlyRange) ...[
            const Divider(height: 20),
            _kv(
              '起止时间',
              '${_fmtTime(w.startTime)} ~ ${_fmtTime(w.endTime)}'
              '${w.overnight ? '（跨夜）' : ''}',
            ),
          ],
          const Divider(height: 20),
          _kv('单价（快照）', fenToYuan(w.rateSnapshot)),
          const Divider(height: 20),
          _kv('金额（快照）', fenToYuan(w.amountSnapshot)),
        ]),
        const SizedBox(height: 16),
        _sectionTitle('可修改'),
        _card([
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('归属日'),
            subtitle: Text(_fmtDate(_workDate)),
            trailing: const Icon(Icons.event),
            onTap: _saving ? null : _pickDate,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteCtrl,
            enabled: !_saving,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '备注',
              hintText: '留空将清空备注',
              border: OutlineInputBorder(),
            ),
          ),
        ]),
      ],
    );
  }

  // ── 底部操作栏 ────────────────────────────────────────────────────────

  Widget _buildBottomBar(String? block) {
    final canSave = !_saving && (_isEdit || block == null);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            if (_isEdit) ...[
              OutlinedButton.icon(
                onPressed: _saving ? null : _confirmDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
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
                const TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      );

  Widget _kv(String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(k, style: const TextStyle(color: Colors.black54)),
          ),
          Expanded(
            child: Text(v, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      );

  Widget _notice(String text) => Container(
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
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF5D4037)),
              ),
            ),
          ],
        ),
      );

  // ── 文案 / 格式化 ─────────────────────────────────────────────────────

  /// 单价字段的行内错误（只在用户已经开始输入时才报，避免空白页就飘红）。
  String? get _rateFieldError {
    final raw = _rateCtrl.text.trim();
    if (raw.isEmpty) return null;
    final fen = yuanToFen(raw);
    if (fen == null) return '金额格式不正确（最多两位小数）';
    if (fen <= 0) return '单价必须大于 0';
    return null;
  }

  String _rateUnitLabel() {
    switch (_method) {
      case PricingMethod.hourly:
        return '小时';
      case PricingMethod.daily:
        return '天';
      case PricingMethod.piece:
        return _unitCtrl.text.trim().isEmpty ? '件' : _unitCtrl.text.trim();
    }
  }

  static String _methodLabel(PricingMethod m) {
    switch (m) {
      case PricingMethod.hourly:
        return '时价（按小时）';
      case PricingMethod.daily:
        return '日价（按天）';
      case PricingMethod.piece:
        return '计件（按件）';
    }
  }

  /// 数量展示：整数不带小数点，小数原样（3.5 → '3.5'）。
  static String _fmtQty(double q) {
    if (q == q.roundToDouble()) return q.toInt().toString();
    return q.toString();
  }

  /// 倍率（×10）→ '1.5'。
  static String _fmtRate(int x10) {
    final s = (x10 / 10).toString();
    return s;
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _fmtTime(DateTime? t) {
    if (t == null) return '--:--';
    return '${_two(t.hour)}:${_two(t.minute)}';
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';
}
