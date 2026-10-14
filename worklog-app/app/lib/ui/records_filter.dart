/// 明细筛选值对象（Wave A · 09 §4.2）。
///
/// **定位**：不可变筛选「唯一真源」，纯数据、不做 IO、不进全局状态。
/// 由 `RecordsPage`（页面壳）持有实例状态；`RecordListView`（列表主源）只读取它。
///
/// **不跨次记忆**：无任何持久化（不引 `shared_preferences`）；每次命令式 push 都是
/// 新 `Route` / 新 `State`，`_filter` 从构造参数重建 → 天然不记忆「上次筛选」（`02 §C.1.3`）。
///
/// **const 约束（编译硬要求）**：本类构造必须 `const`，否则
/// `RecordsPage` 的可选参数默认值 `RecordsFilter.all` 无法成立 → `main.dart` 编译失败（R-1）。
library;

/// 列表范围：单类型（工作 / 收款）或双 tab（both）。
enum RecordsScope { workOnly, paymentOnly, both }

/// 不可变筛选值对象。
class RecordsFilter {
  const RecordsFilter({
    this.scope = RecordsScope.both,
    this.companyId,
    this.startDate,
    this.endDate,
    this.includeDraft = true, // listWorkRecords 默认值；仅 work 相关
    this.includeDeleted = false, // 默认排除软删（§D.0.2-4）
  });

  /// 列表范围。
  final RecordsScope scope;

  /// 公司过滤；null = 全部公司。
  final String? companyId;

  /// 闭区间起（含），按归属日 / 收款日。
  final DateTime? startDate;

  /// 闭区间止（含）。
  final DateTime? endDate;

  /// 工作记录是否含草稿（草稿金额显 `—`、不计入应收）。
  final bool includeDraft;

  /// 是否含软删记录。
  final bool includeDeleted;

  // ── 工厂（写死入口语义，避免各处手写参数漂移）────────────────────────────

  /// 「全部记录」：双 tab、全量、含草稿（台账语义）。
  static const RecordsFilter all =
      RecordsFilter(scope: RecordsScope.both, includeDraft: true);

  /// 「应收下钻」（点应收合计）：仅工作、**不含草稿**（陷阱 1，`02 §C.1.4`）。
  static const RecordsFilter receivableDrill =
      RecordsFilter(scope: RecordsScope.workOnly, includeDraft: false);

  /// 「已收下钻」（点已收合计）：仅收款。
  static const RecordsFilter receivedDrill =
      RecordsFilter(scope: RecordsScope.paymentOnly);

  /// P07 工作 tab：指定公司、仅工作。
  static RecordsFilter companyWork(String cid) =>
      RecordsFilter(scope: RecordsScope.workOnly, companyId: cid);

  /// P07 收款 tab：指定公司、仅收款。
  static RecordsFilter companyPayment(String cid) =>
      RecordsFilter(scope: RecordsScope.paymentOnly, companyId: cid);

  /// P04 日详情（Wave B）：指定单日、仅工作、含草稿。
  static RecordsFilter day(DateTime d) => RecordsFilter(
        scope: RecordsScope.workOnly,
        startDate: d,
        endDate: d,
        includeDraft: true,
      );

  /// 用**显式 clear 标志**表达「清除可空字段」（避免 null 语义歧义）。
  RecordsFilter copyWith({
    RecordsScope? scope,
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool? includeDraft,
    bool? includeDeleted,
    bool clearCompanyId = false,
    bool clearDateRange = false,
  }) =>
      RecordsFilter(
        scope: scope ?? this.scope,
        companyId: clearCompanyId ? null : (companyId ?? this.companyId),
        startDate: clearDateRange ? null : (startDate ?? this.startDate),
        endDate: clearDateRange ? null : (endDate ?? this.endDate),
        includeDraft: includeDraft ?? this.includeDraft,
        includeDeleted: includeDeleted ?? this.includeDeleted,
      );

  /// **值语义**（不可变值对象的本意）：`copyWith` 后字段相同即相等。
  ///
  /// 必要性：`RecordListView.didUpdateWidget` 用 `oldWidget.filter != widget.filter`
  /// 判「筛选是否变化」（`record_list_view.dart`）。若缺 `==`，该比较退化为**引用比较**
  /// → 父级每次重建传入新实例（如 `records_page.dart` 的 `_filter.copyWith(...)`）
  /// 都会误判为「变了」→ 每次重建都触发一次查库。
  ///
  /// `startDate` / `endDate` 直接沿用 `DateTime` 自身的相等（**不做**日期归一化，
  /// 避免语义漂移）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordsFilter &&
          other.scope == scope &&
          other.companyId == companyId &&
          other.startDate == startDate &&
          other.endDate == endDate &&
          other.includeDraft == includeDraft &&
          other.includeDeleted == includeDeleted;

  @override
  int get hashCode => Object.hash(
        scope,
        companyId,
        startDate,
        endDate,
        includeDraft,
        includeDeleted,
      );

  bool get hasCompany => companyId != null;

  bool get hasDateRange => startDate != null || endDate != null;
}
