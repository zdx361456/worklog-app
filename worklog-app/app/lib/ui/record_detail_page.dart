/// P05 · 记录详情 / 编辑页（**Wave B 新建 · I-8 快照护栏唯一触发点**）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.5（`07:362-408`）+ §4.2（I-8 拆签名 / U1~U5 /
/// `null` 语义硬契约 / 字段分组表）；`02-需求与验收.md` §D.5（`AC-P05-01~13`）。
/// 设计落点：`13-WaveB-实现设计.md` §1.3。
///
/// **快照护栏（D-3 / 底线 2）**：
///  - **不复用 `WorkRecord` 作表单模型**（U1）→ 本页自持可编辑态；
///  - 保存**按变更分组调用**（U2）：仅 Meta → `updateWorkRecordMeta`；有金额相关 →
///    `replaceWorkRecordSnapshot`；两类都变 → `transaction` 内先 Meta 后 Snapshot（原子）；
///  - **重算禁止读当前 `pricing_rule`**（U3）：`rule` 由**本条快照重建**
///    （`baseRate` 反推 + `methodSnapshot` + `qtyUnitSnapshot` + 倍率取自 `rateDetailSnapshot`）；
///  - 动作 A（改单价）/ 动作 B（手工覆盖金额）**必须二次确认**（U5）；
///  - `replaceWorkRecordSnapshot` 的**可空列传 `null` = 清空** → **显式传全每个可空字段**。
///
/// **金额纪律**：金额整数「分」，元↔分只走 [yuanToFen]（元→分）/ [fenToYuan]（分→元），
/// **禁** `fen/100` / `double` 金额路径；倍率显示 `${x ~/ 10}.${x % 10}`。
///
/// **证据层级**：保存分组 / 重算 / 快照反推 =【读码级】；交互 / 弹窗 =【真机】。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/pricing_rule.dart';
import '../models/types.dart';
import '../models/work_record.dart';
import '../services/amount_engine.dart';
import '../services/enum_codec.dart';
import 'widgets/money.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

/// 时价的数量输入子模式：手填小时 / 起止时间（二者互斥，见 `work_form_page.dart` 同款说明）。
enum _HourlyMode { manual, range }

class RecordDetailPage extends StatefulWidget {
  const RecordDetailPage({super.key, required this.id});

  final String id;

  @override
  State<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends State<RecordDetailPage> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  Object? _error;
  bool _missing = false;
  bool _saving = false;

  WorkRecord? _rec;

  /// 载入时的**初始目标态**（快照字段基线）。变更判定一律与它比较——
  /// 避免"用落库值反推再重算"的舍入往返造成**假变更**（保存按钮误亮）。
  _Target? _initial;

  /// 规则名（**只看**，不用于重算，`07 §4.2 U3`）。取不到 → 快照兜底。
  String? _ruleName;

  // ── Meta 组 ──
  late DateTime _workDate;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _settled = false; // 是否打标「已结算」

  // ── Snapshot 组（可编辑输入）──
  _HourlyMode _hourlyMode = _HourlyMode.range;
  final TextEditingController _hoursCtrl = TextEditingController();
  TimeOfDay? _start;
  TimeOfDay? _end;
  bool _fullDay = true;
  final TextEditingController _pieceCtrl = TextEditingController();
  bool _overnight = false;
  final TextEditingController _rateCtrl = TextEditingController(); // 实际单价（元）
  final TextEditingController _amountCtrl = TextEditingController(); // 手工覆盖金额（元）

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _hoursCtrl.dispose();
    _pieceCtrl.dispose();
    _rateCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rec = await _db.getWorkRecord(widget.id);
      if (!mounted) return;
      if (rec == null) {
        setState(() {
          _missing = true;
          _loading = false;
        });
        return;
      }
      // 规则名（只看，不参与重算）。不带 includeDeleted → 已删规则取不到 → 快照兜底。
      String? ruleName;
      final rid = rec.pricingRuleId;
      if (rid != null) {
        final rules = await _db.listPricingRules(
          companyId: rec.companyId,
          includeDisabled: true,
        );
        for (final r in rules) {
          if (r.id == rid) {
            ruleName = r.name;
            break;
          }
        }
      }
      if (!mounted) return;
      _initFrom(rec, ruleName);
      _rec = rec; // 先赋值，供 _target() 取基线
      final initial = _target();
      setState(() {
        _rec = rec;
        _initial = initial;
        _ruleName = ruleName;
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

  void _initFrom(WorkRecord rec, String? ruleName) {
    _workDate = DateTime(rec.workDate.year, rec.workDate.month, rec.workDate.day);
    _noteCtrl.text = rec.note ?? '';
    _settled = rec.status == RecordStatus.settled;

    switch (rec.methodSnapshot) {
      case PricingMethod.hourly:
        final hasRange = rec.startTime != null && rec.endTime != null;
        _hourlyMode = hasRange ? _HourlyMode.range : _HourlyMode.manual;
        if (hasRange) {
          _start = TimeOfDay.fromDateTime(rec.startTime!);
          _end = TimeOfDay.fromDateTime(rec.endTime!);
        } else {
          _hoursCtrl.text = _fmtQty(rec.qtySnapshot);
        }
        break;
      case PricingMethod.daily:
        _fullDay = rec.qtySnapshot >= 1;
        break;
      case PricingMethod.piece:
        _pieceCtrl.text = _fmtQty(rec.qtySnapshot);
        break;
    }
    _overnight = rec.overnight;
    _rateCtrl.text = fenToYuanPlain(rec.rateSnapshot);
    _amountCtrl.text =
        rec.amountSource == AmountSource.manual ? fenToYuanPlain(rec.amountSnapshot) : '';
  }

  // ── 目标态计算（重算：rule 由本条快照重建，禁读当前 pricing_rule）───────────

  _Target _target() {
    final rec = _rec!;
    final rd = rec.rateDetailSnapshot;
    final appliedRate = rd.appliedRate;
    final rateFen = yuanToFen(_rateCtrl.text) ?? rec.rateSnapshot;
    // 反推基础单价（整数，无浮点）：actualRate = roundDiv(baseRate × appliedRate, 10)
    // → baseRate ≈ roundDiv(actualRate × 10, appliedRate)。
    final baseRate = appliedRate > 0 ? _roundDiv(rateFen * 10, appliedRate) : 0;

    final isHourly = rec.methodSnapshot == PricingMethod.hourly;
    final isRange = isHourly && _hourlyMode == _HourlyMode.range;
    final manualHours =
        (isHourly && _hourlyMode == _HourlyMode.manual) ? _parseQty(_hoursCtrl.text) : null;
    final pieceCount =
        rec.methodSnapshot == PricingMethod.piece ? _parseQty(_pieceCtrl.text) : null;

    final rule = PricingRule(
      id: rec.pricingRuleId ?? '_snapshot',
      companyId: rec.companyId,
      name: _ruleName ?? '',
      method: rec.methodSnapshot,
      baseRate: baseRate,
      unit: rec.qtyUnitSnapshot,
      halfDayRatio: _halfDayRatio(rec),
      overtimeRate: rd.overtimeRate,
      weekendRate: rd.weekendRate,
      holidayRate: rd.holidayRate,
      createdAt: rec.createdAt,
      updatedAt: rec.updatedAt,
    );

    final start = isRange ? _combine(_start) : null;
    final end = isRange ? _combine(_end) : null;
    final r = const AmountEngine().compute(
      rule: rule,
      input: AmountInput(
        manualAmount: yuanToFen(_amountCtrl.text),
        manualHours: manualHours,
        start: start,
        end: end,
        overnight: _overnight,
        fullDay: _fullDay,
        pieceCount: pieceCount,
        // 倍率命中上下文取自**冻结快照**（`D` 非运行期函数，R-G05）。
        isOvertime: rd.overtime,
        isWeekend: rd.weekend,
        isHoliday: rd.holiday,
      ),
    );

    return _Target(
      rateFen: rateFen,
      baseRate: baseRate,
      appliedRate: appliedRate,
      // C-01：草稿 / 待确认跨夜 / 非法输入三种分支下，引擎返回的 `r.rateDetail` 是**占位值**
      // （`amount_engine._draft` → `const RateSnapshot(appliedRate: 10)`，三档 rate 全 10、
      // 三命中标记全 false）。若原样写回 `replaceWorkRecordSnapshot`，会**静默清空**本条冻结的
      // 倍率命中上下文（appliedRate 15→10）→ 日后反推基础单价得错值。故这三种分支一律**保留**
      // 本条完整冻结快照 `rd`（含 appliedRate）。
      rateDetail:
          (r.isDraft || r.isInvalidInput || r.needsOvernightConfirm) ? rd : r.rateDetail,
      amountFen: r.amount,
      source: r.source,
      autoReference: r.autoReference,
      qty: r.qty,
      qtyUnit: r.qtyUnit,
      start: start,
      end: end,
      overnight: _overnight,
      isDraft: r.isDraft,
      isInvalid: r.isInvalidInput,
      needsOvernight: r.needsOvernightConfirm,
    );
  }

  /// 半天折算比（×10）由原快照数量反推（整数，不用 `.round()` / `/10`）。
  int _halfDayRatio(WorkRecord rec) {
    if (rec.methodSnapshot != PricingMethod.daily) return 5;
    final t = rec.qtySnapshot * 10; // 物理量，非金额
    for (var r = 1; r <= 9; r++) {
      if ((t - r).abs() < 0.5) return r;
    }
    return 5;
  }

  RecordStatus _targetStatus(_Target t) => t.isDraft
      ? RecordStatus.draft
      : (_settled ? RecordStatus.settled : RecordStatus.confirmed);

  bool _metaChanged(_Target t) {
    final rec = _rec!;
    final dateChanged = !_sameDate(_workDate, rec.workDate);
    // MIN-03：保存时对 note 做 `trim()`（`:301`），故变更判定也须两侧同口径 trim——
    // 否则仅带首尾空白的备注会被误判「已改」（保存键误亮 + 静默 trim）。
    final noteChanged = _noteCtrl.text.trim() != (rec.note ?? '').trim();
    final statusChanged = _targetStatus(t) != rec.status;
    return dateChanged || noteChanged || statusChanged;
  }

  bool _snapshotChanged(_Target t) {
    final o = _initial!;
    return t.rateFen != o.rateFen ||
        t.amountFen != o.amountFen ||
        t.source != o.source ||
        t.autoReference != o.autoReference ||
        t.qty != o.qty ||
        t.qtyUnit != o.qtyUnit ||
        !_sameHhmm(t.start, o.start) ||
        !_sameHhmm(t.end, o.end) ||
        t.overnight != o.overnight;
  }

  // ── 保存（按分组调用；两类都变 → 事务原子）──────────────────────────────

  Future<void> _save() async {
    final rec = _rec!;
    final t = _target();
    if (t.isInvalid || t.needsOvernight) return; // 保存已置灰，双保险
    final metaChanged = _metaChanged(t);
    final snapChanged = _snapshotChanged(t);
    if (!metaChanged && !snapChanged) return;

    // 动作 A（改单价）/ 动作 B（手工覆盖）→ 二次确认（U5）。
    final o = _initial!;
    if (t.rateFen != o.rateFen) {
      if (!await _confirmActionA()) return;
    }
    final manualChanged = t.source == AmountSource.manual &&
        (o.source != AmountSource.manual || t.amountFen != o.amountFen);
    if (manualChanged) {
      if (!await _confirmActionB(o.amountFen)) return;
    }

    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final note = _noteCtrl.text.trim(); // 空串 = 清空（Meta null = 保留，故清空传 ''）
      final status = _targetStatus(t);
      if (metaChanged && snapChanged) {
        await _db.transaction((txn) async {
          await _db.updateWorkRecordMetaOn(txn,
              id: rec.id,
              workDate: _workDate,
              note: note,
              status: status,
              updatedAt: now);
          await _db.replaceWorkRecordSnapshotOn(
            txn,
            id: rec.id,
            rateSnapshot: t.rateFen,
            rateDetailSnapshot: t.rateDetail,
            amountSnapshot: t.amountFen,
            amountSource: t.source,
            // 可空字段**显式传全终态**（null = 清空，漏传即静默丢失）。
            autoReferenceAmount: t.autoReference,
            qtySnapshot: t.qty,
            qtyUnitSnapshot: t.qtyUnit,
            startTime: t.start,
            endTime: t.end,
            overnight: t.overnight,
            updatedAt: now,
          );
        });
      } else if (snapChanged) {
        await _db.replaceWorkRecordSnapshot(
          id: rec.id,
          rateSnapshot: t.rateFen,
          rateDetailSnapshot: t.rateDetail,
          amountSnapshot: t.amountFen,
          amountSource: t.source,
          autoReferenceAmount: t.autoReference,
          qtySnapshot: t.qty,
          qtyUnitSnapshot: t.qtyUnit,
          startTime: t.start,
          endTime: t.end,
          overnight: t.overnight,
          updatedAt: now,
        );
      } else {
        await _db.updateWorkRecordMeta(
          id: rec.id,
          workDate: _workDate,
          note: note,
          status: status,
          updatedAt: now,
        );
      }
      dataBus.dataChanged();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('保存失败：$e'); // 失败保留用户输入（不清空表单）
    }
  }

  Future<void> _confirmDelete() async {
    final rec = _rec!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条工作记录？'),
        content: const Text('删除后不计入应收，且不可在 App 内恢复，是否删除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kRedAmount),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _db.softDeleteWorkRecord(rec.id, DateTime.now());
      dataBus.dataChanged();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('删除失败：$e');
    }
  }

  /// 动作 A 二次确认（`07:764`）：含三点 + 确认按钮「只改这一条」。
  Future<bool> _confirmActionA() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改这条记录的单价？'),
        content: const Text(
          '本次修改：\n'
          '· 只改这一条记录；\n'
          '· 不影响其他历史记录；\n'
          '· 不影响公司/规则的单价设置。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('只改这一条'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 动作 B 二次确认（`07:764`）：原自动值保留，可恢复自动计算。
  Future<bool> _confirmActionB(int autoValueFen) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手工覆盖这条的金额？'),
        content: Text(
            '这会手工覆盖这条的金额（原自动值 ${fenToYuan(autoValueFen)} 会保留，可恢复自动计算）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('手工覆盖'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }

  bool get _hasManualOverride =>
      _amountCtrl.text.trim().isNotEmpty ||
      (_rec?.amountSource == AmountSource.manual);

  /// 恢复自动计算（AC-18）：清掉手工覆盖 → 金额按本条快照单价 × 数量重算。
  void _restoreAuto() {
    setState(() => _amountCtrl.text = '');
  }

  // ── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记录详情')),
      body: _buildBody(),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_missing) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('该记录不存在', textAlign: TextAlign.center),
        ),
      );
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }
    final rec = _rec!;
    final t = _target();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (rec.isDeleted) _deletedBanner(),
        _algorithmSection(t),
        const SizedBox(height: 12),
        _sectionTitle('可修改 · 记录信息'),
        _metaSection(),
        const SizedBox(height: 12),
        _sectionTitle('可修改 · 数量与金额'),
        _snapshotSection(rec, t),
        const SizedBox(height: 12),
        _snapshotReadonly(rec),
      ],
    );
  }

  Widget _deletedBanner() {
    return Container(
      width: double.infinity,
      color: _kRedAmount.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      margin: const EdgeInsets.only(bottom: 12),
      child: const Row(
        children: [
          Icon(Icons.archive_outlined, size: 18, color: _kRedAmount),
          SizedBox(width: 8),
          Expanded(
            child: Text('该记录已删除', style: TextStyle(color: _kRedAmount)),
          ),
        ],
      ),
    );
  }

  // ── 金额算法展开区（AC-P05-01）──────────────────────────────────────────

  Widget _algorithmSection(_Target t) {
    final unit = (t.qtyUnit == null || t.qtyUnit!.isEmpty) ? '' : ' ${t.qtyUnit}';
    final hasRate = t.appliedRate != 10;
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: true,
        title: const Text('金额怎么算出来的', style: TextStyle(fontSize: 15)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '基础单价 ${fenToYuan(t.baseRate)} × 倍率 ${_fmtRate(t.appliedRate)} '
              '= 实际单价 ${fenToYuan(t.rateFen)}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '实际单价 ${fenToYuan(t.rateFen)} × 数量 ${_fmtQty(t.qty)}$unit '
              '= 金额 ${fenToYuan(t.amountFen)}${hasRate ? '' : '（无倍率）'}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ── Meta 组 ────────────────────────────────────────────────────────────

  Widget _metaSection() {
    final t = _target();
    final o = _initial!;
    final deleted = _rec?.isDeleted ?? false; // 软删记录 Meta 亦只读（07:399）
    final rateChanged = t.rateFen != o.rateFen;
    final amountChanged = t.amountFen != o.amountFen || t.source != o.source;
    final changed = _metaChanged(t) || _snapshotChanged(t);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            title: const Text('归属日'),
            subtitle: Text(_fmtDate(_workDate)),
            trailing: const Icon(Icons.calendar_today, size: 18),
            // 改归属日 = 纯 Meta（R-G05）：不重算、不迁起止、不需二次确认。
            onTap: (_saving || deleted) ? null : _pickDate,
          ),
          const Divider(height: 1),
          SwitchListTile(
            title: const Text('标记为已结算'),
            subtitle: const Text('不改变金额、不影响剩余'),
            value: _settled,
            onChanged: (t.isDraft || _saving || deleted)
                ? null
                : (v) => setState(() => _settled = v),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _noteCtrl,
              enabled: !_saving && !deleted,
              onChanged: (_) => setState(() {}),
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '备注',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (rateChanged || amountChanged)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '金额预览：${fenToYuan(o.amountFen)} → ${fenToYuan(t.amountFen)}'
                  '${rateChanged ? '（单价已改，需二次确认）' : ''}'
                  '${t.source == AmountSource.manual ? '（手工覆盖）' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ),
          if (changed)
            const SizedBox(height: 0)
          else
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('未做任何修改',
                    style: TextStyle(fontSize: 12, color: Colors.black38)),
              ),
            ),
        ],
      ),
    );
  }

  // ── Snapshot 组（数量 / 金额）──────────────────────────────────────────

  Widget _snapshotSection(WorkRecord rec, _Target t) {
    final readonly = rec.isDeleted || _saving;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _quantityEditor(rec, readonly),
          const Divider(height: 1),
          _rateEditor(readonly),
          const Divider(height: 1),
          _amountEditor(t, readonly),
          const Divider(height: 1),
          ListTile(
            title: const Text('金额来源'),
            subtitle: Text(EnumCodec.amountSource(t.source)),
          trailing: _hasManualOverride
              ? TextButton(
                  // AC-P05-07：无 autoReferenceAmount（无可恢复的自动值）→ 按钮置灰。
                  onPressed: (readonly || _rec?.autoReferenceAmount == null)
                      ? null
                      : _restoreAuto,
                  child: const Text('恢复自动计算'),
                )
              : null,
          ),
          if (t.isDraft)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('数量为 0，保存后将变为草稿且不计入应收',
                    style: TextStyle(fontSize: 12, color: Colors.orange)),
              ),
            ),
          if (t.needsOvernight)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('结束时间早于开始时间：请调整时间，或打开「跨夜」开关',
                    style: TextStyle(fontSize: 12, color: _kRedAmount)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _quantityEditor(WorkRecord rec, bool readonly) {
    switch (rec.methodSnapshot) {
      case PricingMethod.hourly:
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const Text('数量', style: TextStyle(fontSize: 14)),
                  const Spacer(),
                  SegmentedButton<_HourlyMode>(
                    segments: const [
                      ButtonSegment(value: _HourlyMode.manual, label: Text('手填小时')),
                      ButtonSegment(value: _HourlyMode.range, label: Text('起止时间')),
                    ],
                    selected: {_hourlyMode},
                    onSelectionChanged: readonly
                        ? null
                        : (s) => setState(() => _hourlyMode = s.first),
                  ),
                ],
              ),
            ),
            if (_hourlyMode == _HourlyMode.manual)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: TextField(
                  controller: _hoursCtrl,
                  enabled: !readonly,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '小时数',
                    suffixText: '小时',
                    border: OutlineInputBorder(),
                  ),
                ),
              )
            else ...[
              ListTile(
                title: const Text('开始时间'),
                subtitle: Text(_fmtTod(_start)),
                onTap: readonly ? null : () => _pickTime(isStart: true),
              ),
              ListTile(
                title: const Text('结束时间'),
                subtitle: Text(_fmtTod(_end)),
                onTap: readonly ? null : () => _pickTime(isStart: false),
              ),
              SwitchListTile(
                title: const Text('跨夜'),
                value: _overnight,
                onChanged:
                    readonly ? null : (v) => setState(() => _overnight = v),
              ),
            ],
          ],
        );
      case PricingMethod.daily:
        return SwitchListTile(
          title: const Text('整天'),
          subtitle: Text(_fullDay ? '整天（1 天）' : '半天'),
          value: _fullDay,
          onChanged: readonly ? null : (v) => setState(() => _fullDay = v),
        );
      case PricingMethod.piece:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: TextField(
            controller: _pieceCtrl,
            enabled: !readonly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: '件数',
              suffixText: rec.qtyUnitSnapshot ?? '',
              border: const OutlineInputBorder(),
            ),
          ),
        );
    }
  }

  Widget _rateEditor(bool readonly) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: TextField(
        controller: _rateCtrl,
        enabled: !readonly,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: '实际单价（本条快照）',
          helperText: '改动 = 只改这一条，需二次确认',
          prefixText: '¥ ',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _amountEditor(_Target t, bool readonly) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: TextField(
        controller: _amountCtrl,
        enabled: !readonly,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: '手工覆盖金额（留空 = 自动计算）',
          helperText: t.source == AmountSource.manual
              ? '当前为手工覆盖，需二次确认'
              : '自动计算中',
          prefixText: '¥ ',
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  // ── 五件套只读区（AC-P05-02）────────────────────────────────────────────

  Widget _snapshotReadonly(WorkRecord rec) {
    final rd = rec.rateDetailSnapshot;
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        title: const Text('历史快照（五件套 · 只读）', style: TextStyle(fontSize: 14)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _kv('计价方式', EnumCodec.pricingMethod(rec.methodSnapshot)),
          _kv('数量单位', rec.qtyUnitSnapshot ?? ''),
          _kv('实际单价', fenToYuan(rec.rateSnapshot)),
          _kv(
            '倍率明细',
            '加班 ${rec.rateDetailSnapshot.overtime ? "命中" : "无"}×${_fmtRate(rd.overtimeRate)}'
            ' · 周末 ${rd.weekend ? "命中" : "无"}×${_fmtRate(rd.weekendRate)}'
            ' · 节假日 ${rd.holiday ? "命中" : "无"}×${_fmtRate(rd.holidayRate)}'
            ' · 取用 ×${_fmtRate(rd.appliedRate)}',
          ),
          _kv('金额', fenToYuan(rec.amountSnapshot)),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(k, style: const TextStyle(color: Colors.black54)),
          ),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }

  // ── 底部动作条 ──────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    if (_loading || _missing || _error != null) return const SizedBox.shrink();
    final rec = _rec!;
    final t = _target();
    final changed = _metaChanged(t) || _snapshotChanged(t);
    final canSave = !_saving &&
        !rec.isDeleted &&
        changed &&
        !t.isInvalid &&
        !t.needsOvernight;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: canSave ? _save : null,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed:
                  (_saving || rec.isDeleted) ? null : _confirmDelete,
              style: TextButton.styleFrom(foregroundColor: _kRedAmount),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: const TextStyle(fontSize: 13, color: Colors.black54)),
      );

  // ── 交互 ────────────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _workDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _workDate = DateTime(picked.year, picked.month, picked.day));
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
    });
  }

  // ── 纯函数工具 ──────────────────────────────────────────────────────────

  /// 起止时间：日期部分统一挂「归属日」，只保留 hh:mm（引擎只比较时分）。
  DateTime? _combine(TimeOfDay? t) {
    if (t == null) return null;
    return DateTime(_workDate.year, _workDate.month, _workDate.day, t.hour, t.minute);
  }

  static double? _parseQty(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  /// 唯一舍入规则（与 `amount_engine.dart` 同规，整数，无浮点）。
  static int _roundDiv(int numerator, int denominator) {
    if (numerator < 0 || denominator <= 0) return 0;
    return (numerator + denominator ~/ 2) ~/ denominator;
  }

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static bool _sameHhmm(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.hour == b.hour && a.minute == b.minute;
  }

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _fmtTod(TimeOfDay? t) =>
      t == null ? '未设置' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 数量展示：整数不带小数点，小数原样（3.5 → '3.5'）。
  /// **纯字符串处理**（不涉金额，亦不用 `roundToDouble`/`toInt` 等浮点转换）。
  static String _fmtQty(double q) {
    final s = q.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// 倍率（×10）→ '1.5'（整数运算，**禁** `x / 10`）。
  static String _fmtRate(int x10) => '${x10 ~/ 10}.${x10 % 10}';
}

/// 重算目标态（全整数金额；`start`/`end` 为挂好归属日的 `DateTime`）。
class _Target {
  const _Target({
    required this.rateFen,
    required this.baseRate,
    required this.appliedRate,
    required this.rateDetail,
    required this.amountFen,
    required this.source,
    required this.autoReference,
    required this.qty,
    required this.qtyUnit,
    required this.start,
    required this.end,
    required this.overnight,
    required this.isDraft,
    required this.isInvalid,
    required this.needsOvernight,
  });

  final int rateFen;
  final int baseRate;
  final int appliedRate;
  final RateSnapshot rateDetail;
  final int amountFen;
  final AmountSource source;
  final int? autoReference;
  final double qty;
  final String? qtyUnit;
  final DateTime? start;
  final DateTime? end;
  final bool overnight;
  final bool isDraft;
  final bool isInvalid;
  final bool needsOvernight;
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
