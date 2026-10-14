/// 记一笔收款页 / 编辑收款（Wave 2 完整实现 · Wave A 收口）。
///
/// 入口签名：`PaymentFormPage({super.key, this.id, this.companyId})`；
/// `id == null` 为新建，`id != null` 为编辑（`main.dart` 以 `arguments: id` 传入）；
/// `companyId` 为**可选**预置（T-1：P07「+ 记一笔收款」带公司进入，新建态预置并锁定）。
///
/// 金额纪律：输入元 → 一律经 [yuanToFen] 字符串解析为「分」，**禁止** double 乘 100；
/// 展示一律 [fenToYuan]。金额必须 > 0，否则禁存并内联报错。
///
/// 剩余口径（Wave A §11）：一律取 `aggregate(companyId).remaining`（唯一来源），
/// 用于①「实时剩余提示」（§11.2）；② AC-24「输入金额 > 剩余」二次确认（§11.3，阈值严格 `>`）。
///
/// 编辑态：`getPaymentRecord(id)` 回填，保存走 `updatePaymentRecord` 并**保留原 createdAt**、
/// 仅刷新 updatedAt（避免「编辑即新建」的时间语义漂移）；另提供删除（软删）。
///
/// 异常处理：所有 async 落库均 catch 后用 SnackBar 提示，绝不让异常冒泡崩溃；
/// 每次 async 之后、`setState` 之前判 `mounted`。
library;

import 'package:flutter/material.dart';

import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/payment_record.dart';
import '../models/types.dart';
import '../services/enum_codec.dart';
import '../services/id_gen.dart';
import 'widgets/company_picker.dart';
import 'widgets/money.dart';

class PaymentFormPage extends StatefulWidget {
  /// 编辑模式传入被编辑记录 id；新建时为 `null`。
  const PaymentFormPage({super.key, this.id, this.companyId});

  final String? id;

  /// 新建态预置公司（T-1：P07「+ 记一笔收款」）；**编辑态忽略**（由 DB 回填）。
  final String? companyId;

  @override
  State<PaymentFormPage> createState() => _PaymentFormPageState();
}

class _PaymentFormPageState extends State<PaymentFormPage> {
  final AppDatabase _db = AppDatabase.instance;

  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();

  List<Company> _companies = const [];

  String? _companyId;
  DateTime _paymentDate = DateTime.now();
  PaymentMethod? _method;

  /// 编辑态回填的原始记录：用于保留 `createdAt` 与取得「删除」目标 id。
  PaymentRecord? _existing;

  bool _loading = true;
  Object? _error;

  /// 记录在加载时已不存在（编辑态被别处删除）：给一个明确的占位而非白屏。
  bool _missing = false;

  bool _saving = false;

  /// 金额是否已通过校验（> 0 的合法元值）。用于禁用保存按钮。
  bool _amountOk = false;

  /// 保存按钮点击后暴露的公司校验错误（CompanyPicker 无内建错误显示）。
  String? _companyError;

  /// 从 P07 预置进入：公司预置且锁定（`07:540`）；仅**新建态预置成功**时置位。
  bool _lockCompany = false;

  /// 当前选中公司的剩余（分）= `aggregate(companyId).remaining`，**唯一口径**（§11.1）。
  /// `null` = 未选公司 / 尚未取到 / 取失败（降级）。
  int? _remainingFen;

  /// 当前选中公司的应收（分）= `aggregate(companyId).receivable`，用于「还没有工作记录」文案（`07:558`）。
  int? _receivableFen;

  /// `aggregate` 取值失败（如脏金额 FormatException）：**不静默**，提示降级并跳过 AC-24 比较（§11.1）。
  bool _remainingDegraded = false;

  /// 编辑态改公司时「原公司」一次性提示是否已给过（§11.3 N-D3）。
  bool _movedOutHinted = false;

  bool get _isEditing => widget.id != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final companies = await _db.listCompanies();
      PaymentRecord? existing;
      if (_isEditing) {
        existing = await _db.getPaymentRecord(widget.id!);
      }
      if (!mounted) return;

      // 编辑目标不存在：不静默当作「新建」，明确提示（可能是并发删除）。
      if (_isEditing && existing == null) {
        setState(() {
          _companies = companies;
          _missing = true;
          _loading = false;
        });
        return;
      }

      // 预置公司已停用/已删（MF-3）：**不回退**到别的公司（否则会静默把钱记到错的公司），
      // 保持「未选」+ 首帧后一次性提示（`AC-P10-05` / `07:557`）。
      var presetMissing = false;
      setState(() {
        _companies = companies;
        _existing = existing;
        if (existing != null) {
          _companyId = existing.companyId;
          _paymentDate = existing.paymentDate;
          _method = existing.method;
          _amountCtrl.text = fenToYuanPlain(existing.amount);
          _noteCtrl.text = existing.note ?? '';
          _amountOk = existing.amount > 0;
        }
        // T-1（§3.3 / §11.1）：**仅新建态**预置公司；编辑态忽略（由 DB 回填，且公司下拉可改）。
        if (!_isEditing && widget.companyId != null) {
          final preset = widget.companyId!;
          if (companies.any((c) => c.id == preset)) {
            _companyId = preset;
            _lockCompany = true; // 预置且锁定（`07:540`）
          } else {
            _companyId = null; // 不回退：保持未选，由用户显式重选
            presetMissing = true;
          }
        }
        _loading = false;
        _error = null;
      });
      if (presetMissing) {
        // 一家公司都没有时（预置公司缺失 + 列表为空）→ 措辞改为「先建公司」（与 `_companyError` 一致）。
        final missingMsg = companies.isEmpty
            ? '还没有公司，先建一个公司'
            : '该公司已停用或已删除，请重新选择公司';
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(missingMsg)),
          );
        });
      }
      // 公司确定后立即取剩余（编辑态回填的公司同样需要：提示 + AC-24 判定基准，§11.1）。
      await _refreshRemaining();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 取当前选中公司的剩余/应收（**唯一口径** `aggregate`，§11.1）。公司一变即重取。
  Future<void> _refreshRemaining() async {
    final cid = _companyId;
    if (cid == null) {
      if (!mounted) return;
      setState(() {
        _remainingFen = null;
        _receivableFen = null;
        _remainingDegraded = false;
      });
      return;
    }
    try {
      final agg = await _db.aggregate(cid);
      if (!mounted || cid != _companyId) return; // MF-1：丢弃过期响应（快速连切公司）
      setState(() {
        _remainingFen = agg.remaining;
        _receivableFen = agg.receivable;
        _remainingDegraded = false;
      });
    } catch (_) {
      if (!mounted || cid != _companyId) return; // MF-1：过期请求的失败同样丢弃
      // 脏金额等取值失败：不静默；标记降级 → 跳过 AC-24 比较（无法核对），但仍允许保存（有告警）。
      setState(() {
        _remainingFen = null;
        _receivableFen = null;
        _remainingDegraded = true;
      });
    }
  }

  /// 公司选择变化：重取剩余；编辑态改公司时对**原公司**一次性提示（§11.3 N-D3，不阻断保存）。
  void _onCompanyChanged(String? id) {
    setState(() {
      _companyId = id;
      if (id != null) _companyError = null;
      // MF-1：切换窗口内清空旧公司剩余 → 期间 `_compareBase()` 返回 null（安全跳过 AC-24），
      // 避免「用旧公司的剩余配新选的公司」算 T。
      _remainingFen = null;
      _receivableFen = null;
      _remainingDegraded = false;
    });
    _refreshRemaining();

    final original = _existing?.companyId;
    if (_isEditing &&
        !_movedOutHinted &&
        original != null &&
        id != null &&
        id != original) {
      _movedOutHinted = true;
      _hintMovedOutOfOriginal(original);
    }
  }

  /// 编辑态改公司：对**原公司**额外取一次 `aggregate`，仅用于一次性提示（§11.3，非 N+1）。
  ///
  /// MF-2（勘误）：`aggregate(原公司)` 是在**移出前**取的，其 `remaining` **已含本条收款**；
  /// 本条移出后原公司的剩余 = `remaining + 本条金额`（收款减少 → 剩余增大）。
  /// 故用该「移出后」推算值判定是否真的变成多收，避免把「移出后其实不欠多收」误报为多收。
  Future<void> _hintMovedOutOfOriginal(String originalCompanyId) async {
    try {
      final agg = await _db.aggregate(originalCompanyId);
      if (!mounted) return;
      final afterMove = agg.remaining + (_existing?.amount ?? 0); // 移出后原公司的剩余
      if (afterMove < 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '该笔收款改到别的公司后，原公司将变成多收 ${fenToYuan(-afterMove)}，请注意核对'),
        ));
      }
    } catch (_) {
      // 脏值：忽略提示，不影响保存。
    }
  }

  /// 实时剩余提示文案（AC-P10-02，§11.2，**整数「分」运算**）。`null` = 不显示。
  String? _remainingHint() {
    if (_companyId == null) return null;
    if (_remainingDegraded) return '账目数字可能不完整，暂时无法核对剩余';
    final x = _remainingFen;
    // MF-1：未取到（含公司切换窗口）→ 中性提示；**不得**显示 ¥0.00 或空白。
    if (x == null) return '正在核对该公司剩余…';
    final a = yuanToFen(_amountCtrl.text);
    if (a == null || a <= 0) {
      // 仅未输入有效金额时：显示当前欠款。
      if (x > 0) return '该公司现在还欠 ${fenToYuan(x)}';
      if (x == 0) return '该公司目前不欠钱（剩余 ${fenToYuan(0)}）';
      return '该公司已多收 ${fenToYuan(-x)}，请核对是否记错';
    }
    final y = x - a; // 整数分
    if (y > 0) return '记完这笔后将剩 ${fenToYuan(y)}';
    if (y == 0) return '记完这笔后将结清（剩余 ${fenToYuan(0)}）';
    return '记完这笔后将多收 ${fenToYuan(-y)}'; // Y 为负 → 取正 + 「将多收」
  }

  /// AC-24 的判定基准 `T`（§11.3，主理人裁定 M-12），**单函数隔离阈值计算**：
  /// - 新建 → `T = 当前公司 remaining`；
  /// - 编辑·公司未变 → `T = remaining + 本条原金额`（remaining 已含本条，须先剔除自身再比较）；
  /// - 编辑·公司变更 → `old = 0`（不把原公司金额累加进来），`T = 目标公司 remaining`。
  int? _compareBase() {
    final x = _remainingFen; // 恒为「当前选中公司」的 remaining（公司变更后已重取）
    if (x == null) return null;
    if (!_isEditing) return x;
    final sameCompany = _existing!.companyId == _companyId;
    final old = sameCompany ? _existing!.amount : 0;
    return x + old;
  }

  /// AC-24：`输入金额 > T` → 二次确认；**阈值严格 `>`，`==` 不弹**（AC-P10-01）。
  /// 剩余不可用（降级）→ 不阻断保存（已有降级告警）。
  Future<bool> _confirmIfOverpay(int amountFen) async {
    final t = _compareBase();
    if (t == null) return true; // 无法核对 → 不阻断
    if (!(amountFen > t)) return true; // 严格大于才弹
    if (!mounted) return true;
    final noWork = (_receivableFen ?? 0) == 0; // `07:558` 先收钱后干活
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认收款金额？'),
        content: Text(noWork
            ? '该公司还没有工作记录，确认是真收到钱？'
            : '这次收的钱比公司欠的还多，确认吗？（可能"多给"或"记错"）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再核对一下'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认，就收这么多'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 金额输入变化：仅用字符串解析判定合法性（禁止 double）。
  /// **每次击键都 setState**：实时剩余提示依赖当前输入金额（§11.2）。
  void _onAmountChanged(String text) {
    final fen = yuanToFen(text);
    final ok = fen != null && fen > 0;
    setState(() => _amountOk = ok);
  }

  /// 金额字段内联校验文案（配合 `autovalidateMode.onUserInteraction`）。
  String? _validateAmount(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return '请输入金额';
    final fen = yuanToFen(t);
    if (fen == null) return '金额格式不正确';
    if (fen <= 0) return '金额需大于 0';
    return null;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _paymentDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _paymentDate = picked);
  }

  Future<void> _save() async {
    if (_saving) return; // 防御：防「回车提交」等旁路重复触发（与 work_form 一致）
    final amountFen = yuanToFen(_amountCtrl.text);
    final companyOk = _companyId != null;
    final amountOk = amountFen != null && amountFen > 0;

    setState(() {
      // AC-P10-05（`07:557`）：无公司时提示「先建公司」；有公司但未选→「请选择公司」。
      _companyError = companyOk
          ? null
          : (_companies.isEmpty ? '还没有公司，先建一个公司' : '请选择公司');
      _amountOk = amountOk;
    });
    if (!companyOk || !amountOk) return;

    // AC-24：写库前二次确认（取消 → 保留用户输入，不写库）。§11.3 插入点。
    if (!await _confirmIfOverpay(amountFen!)) return;
    if (!mounted) return;

    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final note = _noteCtrl.text.trim();
      final record = PaymentRecord(
        id: _existing?.id ?? newId('pm'),
        paymentDate: _paymentDate,
        companyId: _companyId!,
        amount: amountFen!,
        method: _method,
        note: note.isEmpty ? null : note,
        // 编辑保留原创建时间，只推进 updatedAt。
        createdAt: _existing?.createdAt ?? now,
        updatedAt: now,
        deletedAt: _existing?.deletedAt,
      );
      // AC-P10-08：编辑分支走 `updatePaymentRecord`（`database.dart:983`）；
      // 新建分支走 `upsertPaymentRecord`（`database.dart:890`）。二者均为 `_write` 全行 replace，功能等价。
      if (_isEditing) {
        await _db.updatePaymentRecord(record);
      } else {
        await _db.upsertPaymentRecord(record);
      }
      if (!mounted) return;
      // 先广播再 pop：确保总览/明细页在返回前已收到刷新信号。
      dataBus.dataChanged();
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  Future<void> _delete() async {
    final id = _existing?.id;
    if (id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这笔收款？'),
        content: const Text('删除后该记录将从明细与统计中移除（可后续恢复）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await _db.softDeletePaymentRecord(id, DateTime.now());
      if (!mounted) return;
      dataBus.dataChanged();
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }

  /// 选择器内「＋ 新建公司」回调：本页负责落库，并把新公司并入本地候选列表。
  Future<void> _onCompanyCreated(Company company) async {
    try {
      await _db.upsertCompany(company);
      if (!mounted) return;
      setState(() => _companies = [..._companies, company]);
      // 新公司剩余为 0：重取剩余（§11.1 触发点）。
      _refreshRemaining();
      // 通知总览/公司页等展示端刷新。
      dataBus.dataChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新建公司失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑收款' : '记一笔收款'),
        actions: [
          if (_isEditing && !_missing && !_loading && _error == null)
            IconButton(
              tooltip: '删除',
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
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
    if (_missing) {
      return const _MissingView();
    }
    final remainingHint = _remainingHint(); // §11.2 实时剩余提示
    return Form(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          InputDecorator(
            decoration: InputDecoration(
              labelText: '公司 *',
              border: const OutlineInputBorder(),
              errorText: _companyError,
            ),
            isEmpty: _companyId == null,
            // 从 P07 预置进入 → 公司锁定（`07:540`）；编辑态可改公司（M-12 前提）。
            child: IgnorePointer(
              ignoring: _lockCompany,
              child: CompanyPicker(
                companies: _companies,
                value: _companyId,
                allowCreate: !_lockCompany,
                onCreated: _onCompanyCreated,
                onChanged: _onCompanyChanged,
              ),
            ),
          ),
          if (_lockCompany) ...[
            const SizedBox(height: 4),
            const Text('已锁定：从公司详情页进入',
                style: TextStyle(fontSize: 12, color: Colors.black45)),
          ],
          const SizedBox(height: 16),
          InkWell(
            onTap: _saving ? null : _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: '收款日期',
                border: OutlineInputBorder(),
                suffixIcon: Icon(Icons.calendar_today),
              ),
              child: Text(_formatDate(_paymentDate)),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _amountCtrl,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: const InputDecoration(
              labelText: '金额（元）*',
              hintText: '如：1234.56',
              prefixText: '¥ ',
              border: OutlineInputBorder(),
            ),
            validator: _validateAmount,
            onChanged: _onAmountChanged,
          ),
          if (remainingHint != null) ...[
            const SizedBox(height: 6),
            Text(
              remainingHint,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
          const SizedBox(height: 16),
          DropdownButtonFormField<PaymentMethod?>(
            initialValue: _method,
            hint: const Text('不记录'),
            decoration: const InputDecoration(
              labelText: '收款方式',
              border: OutlineInputBorder(),
            ),
            items: [
              // 允许不选（null）：基础版不强制记录收款方式。
              const DropdownMenuItem<PaymentMethod?>(
                value: null,
                child: Text('不记录'),
              ),
              for (final m in PaymentMethod.values)
                DropdownMenuItem<PaymentMethod?>(
                  value: m,
                  child: Text(EnumCodec.paymentMethod(m)),
                ),
            ],
            onChanged: _saving ? null : (m) => setState(() => _method = m),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _noteCtrl,
            enabled: !_saving,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_saving || !_amountOk) ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
          if (!_amountOk && _amountCtrl.text.trim().isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('填写有效金额后即可保存',
                  style: TextStyle(fontSize: 12, color: Colors.black45)),
            ),
        ],
      ),
    );
  }
}

class _MissingView extends StatelessWidget {
  const _MissingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 48, color: Colors.black26),
            const SizedBox(height: 12),
            const Text('记录不存在或已被删除',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回'),
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
            const Icon(Icons.error_outline, size: 48, color: Color(0xFFD32F2F)),
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

String _formatDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
