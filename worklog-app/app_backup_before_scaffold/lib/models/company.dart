/// 公司 Company
/// 对应 03 §2.2
library;

class Company {
  final String id;
  final String ledgerId;
  final String name;
  final String? shortName;
  final int color; // 标记色，日历着色用。约定为 RGB（不含 alpha），UI 渲染时补 0xFF000000。
  final String? defaultRuleId; // 默认计价规则（快记默认项），弱引用
  final bool enabled;
  final String? contact;
  final String currency; // 继承账本（03 §2.2 / §8 约束#7）
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt; // 软删除标记（Q13）

  const Company({
    required this.id,
    required this.ledgerId,
    required this.name,
    this.shortName,
    required this.color,
    this.defaultRuleId,
    this.enabled = true,
    this.contact,
    this.currency = 'CNY',
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  /// 日历/卡片上显示的短名。按 Unicode **码点**截取（避免截断代理对；
  /// 但不处理 ZWJ/组合符/肤色修饰，如需真正字素簇请引入 package:characters）。
  String get displayName {
    if (shortName != null && shortName!.isNotEmpty) return shortName!;
    final runes = name.runes.toList();
    if (runes.length <= 2) return name;
    return String.fromCharCodes(runes.take(2));
  }
}
