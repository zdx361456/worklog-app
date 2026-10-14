/// 公司选择器（共享件，Wave 1 冻结，Wave 2 只调用不改）。
///
/// - 下拉列出传入的 [companies]；
/// - [allowCreate] = true 时，末项固定为「＋ 新建公司…」，选中后内建一个极简命名弹窗，
///   生成 [Company] 并通过 [onCreated] 交回调用方**落库**（本组件不直接写库，避免与
///   公司管理页面的写路径重复）。
library;

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../models/company.dart';
import '../../services/id_gen.dart';

/// 「新建公司」哨兵值（非真实公司 id；真实 id 形如 `co-...`，不可能相撞）。
const String _createSentinel = '__create_company__';

/// 新建公司时用的默认标记色（RGB，不含 alpha；与 `Company.color` 约定一致）。
const int _defaultCompanyColor = 0xFFE53935;

class CompanyPicker extends StatelessWidget {
  const CompanyPicker({
    super.key,
    required this.companies,
    required this.value,
    required this.onChanged,
    this.allowCreate = true,
    this.onCreated,
  });

  /// 候选公司列表（调用方负责过滤：通常传 `listCompanies()` 结果）。
  final List<Company> companies;

  /// 当前选中公司 id（`null` = 未选）。
  final String? value;

  /// 选中变化回调（含「新建」流程完成后的回填）。
  final ValueChanged<String?> onChanged;

  /// 是否显示「＋ 新建公司…」末项。
  final bool allowCreate;

  /// 新建公司成功后的回调（调用方在此落库）；为 `null` 时「新建」项仅提示前往公司管理页。
  final ValueChanged<Company>? onCreated;

  @override
  Widget build(BuildContext context) {
    final items = <DropdownMenuItem<String?>>[
      for (final c in companies)
        DropdownMenuItem<String?>(
          value: c.id,
          child: Text(c.name, overflow: TextOverflow.ellipsis),
        ),
      if (allowCreate)
        const DropdownMenuItem<String?>(
          value: _createSentinel,
          child: Text('＋ 新建公司…'),
        ),
    ];

    final hasValue = value != null && companies.any((c) => c.id == value);

    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        isExpanded: true,
        value: hasValue ? value : null,
        hint: const Text('请选择公司'),
        items: items,
        onChanged: (selected) async {
          if (selected == _createSentinel) {
            await _handleCreate(context);
          } else {
            onChanged(selected);
          }
        },
      ),
    );
  }

  Future<void> _handleCreate(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);

    if (onCreated == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('请先在公司管理页新建公司')),
      );
      return;
    }
    if (AppState.ledgerId == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('账本尚未初始化，无法新建公司')),
      );
      return;
    }

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _CompanyNameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;

    final now = DateTime.now();
    final company = Company(
      id: newId('co'),
      ledgerId: AppState.ledgerId!,
      name: name.trim(),
      color: _defaultCompanyColor,
      createdAt: now,
      updatedAt: now,
    );
    onCreated?.call(company);
    onChanged(company.id);
  }
}

/// 极简公司命名弹窗（仅取名；其余字段（备注/联系方式）在二期公司管理页完善）。
class _CompanyNameDialog extends StatefulWidget {
  const _CompanyNameDialog();

  @override
  State<_CompanyNameDialog> createState() => _CompanyNameDialogState();
}

class _CompanyNameDialogState extends State<_CompanyNameDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建公司'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: '公司名称', hintText: '如：张老板工队'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}
