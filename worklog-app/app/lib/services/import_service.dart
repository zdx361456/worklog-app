/// 导入恢复服务（基础版 P0·B8）
/// 对应 03 §6.4 导入流程与 §6.5 断言。
///
/// 职责边界：本服务负责**纯逻辑**——结构/字段/值域校验、反序列化重建模型、id 冲突策略规划。
/// 实际的"单事务批量写入 + 导入后断言"依赖存储层，由 db 层（**待建**：db/database.dart）
/// 在其事务上下文中调用本服务的 parse/plan 结果并落库。
///
/// 硬校验（§6.4 步骤2，任一不合法 → 整文件拒绝）：
///  - format / schema_version 合法；
///  - 六表齐全；
///  - 必填字段与类型合法；id 为合法 id（本地格式 `<prefix>-<base36>-<base36>` 或 UUID，U-2 放宽）；金额为整数「分」；倍率为整数「×10」；
///  - 枚举值合法（状态/计价方式/金额来源/收款方式/节假日类型）；
///  - **值域合法**（基础单价>0、倍率≥1、半天折算比 1~9、收款金额>0、快照金额≥0）——
///    判据与 UI 侧 `Validators` 共用同一谓词。
///
/// 安全约定：所有校验函数**不抛异常**，类型/取值异常一律转成错误清单（满足 AC-64）。
library;

import 'dart:convert';

import '../models/ledger.dart';
import '../models/company.dart';
import '../models/pricing_rule.dart';
import '../models/work_record.dart';
import '../models/payment_record.dart';
import '../models/holiday_mark.dart';
import '../models/types.dart';
import 'enum_codec.dart';
import 'validators.dart';
import 'receivable_service.dart';
import 'export_service.dart'
    show BackupData, ExportService, kBackupFormat, kBackupSchemaVersion;

/// id 冲突策略（§6.4）。
enum ImportStrategy {
  /// 覆盖（推荐默认）：同 id 以备份文件版本覆盖本地，执行前自动备份当前数据。
  overwrite,

  /// 合并：已存在 id 跳过，仅导入本地没有的。
  merge,

  /// 拒绝：发现任一 id 冲突即中止，输出冲突清单。
  reject,
}

/// 导入规划结果（供 db 层执行事务写入）。
class ImportPlan {
  final ImportStrategy strategy;
  final List<String> conflicts; // 冲突的 id 列表（跨表汇总）
  final bool abort; // 是否应中止（策略=reject 且有冲突）
  final List<String> warnings; // 软警告（弱引用悬空 / 缺自动参考值 / 日期超界等）

  const ImportPlan({
    required this.strategy,
    required this.conflicts,
    required this.abort,
    required this.warnings,
  });
}

/// 导入前 / 后的本机数据快照（五张实体表 + 全量 id 并集）。
///
/// **纯数据容器**（不触 DB）——由调用方（UI / 测试）从存储层读出后填入，
/// 供 [ImportService.verifyImportInvariants] 做不变量校验（R55）。
class ImportSnapshot {
  final List<Company> companies;
  final List<PricingRule> pricingRules;
  final List<WorkRecord> workRecords;
  final List<PaymentRecord> paymentRecords;
  final List<HolidayMark> holidayMarks;

  /// 六表全量 id 并集（含当前账本 id）——**取时必须 `includeDeleted: true`**（`07:678`）。
  final Set<String> ids;

  const ImportSnapshot({
    required this.companies,
    required this.pricingRules,
    required this.workRecords,
    required this.paymentRecords,
    required this.holidayMarks,
    required this.ids,
  });
}

/// 导入后不变量校验结果（R55 / R57）。见 [ImportService.verifyImportInvariants]。
class ImportVerification {
  /// **恒须满足**（策略无关）的失败项：六表来件落库 + 覆盖金额合计 +
  /// （R57）节假日键/关键值 + 覆盖内容逐条相等。
  final List<String> failures;

  /// **仅 `merge`** 须满足的语义失败项（R55：**(A)(B)(C)** 三条，缺一不可）：
  ///  (A) 本机原有 id 逐条不变；(B) 新插入 id 与来件 1:1 相等；
  ///  (C) 四表 id 集合 = 导入前本机集合 ∪ 来件集合。
  final List<String> mergeFailures;

  const ImportVerification({
    required this.failures,
    required this.mergeFailures,
  });

  bool get ok => failures.isEmpty && mergeFailures.isEmpty;

  /// 汇总（供异常文案 / 测试断言）。
  List<String> get all => <String>[...failures, ...mergeFailures];
}

/// 导入服务。
class ImportService {
  const ImportService();

  // id 校验谓词（U-2 放宽，用户 2026-10-05 裁定 · 方案 B；逐字照 `02 §C.3.1`）：
  //   ① 本地格式 `<prefix>-<base36>-<base36>`（`id_gen.dart:15-18`）；
  //   ② 既有 UUID（**兼容分支，勿删** —— `verify_core` / `verify_db` 基线样本为 UUID）。
  static final RegExp _id = RegExp(
    r'^('
    r'[A-Za-z]+-[0-9a-z]+-[0-9a-z]+' // ① 本地格式：<prefix>-<base36>-<base36>
    r'|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' // ② 既有 UUID
    r')$',
  );
  static final RegExp _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  // ───────────────────────── 结构 + 字段 + 值域校验（§6.4 步骤2） ─────────────────────────

  /// 完整校验。返回错误列表（空 = 通过）。**永不抛异常**。
  List<String> validate(Map<String, dynamic> map) {
    final errors = <String>[];

    // 1. 格式与版本
    if (map['format'] != kBackupFormat) {
      errors.add('格式标识不符：期望 "$kBackupFormat"，实际 "${map['format']}"');
    }
    final sv = map['schema_version'];
    if (sv is! int || sv < 1) {
      errors.add('schema_version 缺失或非法');
    } else if (sv > kBackupSchemaVersion) {
      errors.add('schema_version($sv) 高于当前支持版本($kBackupSchemaVersion)，请升级 App');
    }

    // 2. 六表齐全（缺表 → 文件不完整）
    const tables = [
      'ledger',
      'companies',
      'pricing_rules',
      'work_records',
      'payment_records',
      'holiday_marks',
    ];
    for (final t in tables) {
      if (!map.containsKey(t)) errors.add('缺少表：$t');
    }
    if (errors.isNotEmpty) return errors; // 结构不对，不再逐字段

    // 3. 逐表字段 + 值域校验
    _validateLedger(map['ledger'], errors);
    _validateList('companies', map['companies'], errors, _validateCompany);
    _validateList('pricing_rules', map['pricing_rules'], errors, _validateRule);
    _validateList('work_records', map['work_records'], errors, _validateRecord);
    _validateList('payment_records', map['payment_records'], errors, _validatePayment);
    _validateList('holiday_marks', map['holiday_marks'], errors, _validateHoliday);

    return errors;
  }

  void _validateList(
    String table,
    dynamic value,
    List<String> errors,
    void Function(int, Map, List<String>) check,
  ) {
    if (value is! List) {
      errors.add('$table 应为数组');
      return;
    }
    for (var i = 0; i < value.length; i++) {
      final item = value[i];
      if (item is! Map) {
        errors.add('$table[$i] 应为对象');
        continue;
      }
      check(i, item, errors); // Map 的 key 由 jsonDecode 保证为 String
    }
  }

  void _validateLedger(dynamic v, List<String> errors) {
    if (v is! Map) {
      errors.add('ledger 应为对象');
      return;
    }
    _requireUuid('ledger.id', v['id'], errors);
    _requireNonEmpty('ledger.nickname', v['nickname'], errors);
    _requireNonEmpty('ledger.currency', v['currency'], errors);
    if (EnumCodec.ledgerModeFrom(_str(v['mode'])) == null) {
      errors.add('ledger.mode 枚举非法：${v['mode']}');
    }
  }

  void _validateCompany(int i, Map v, List<String> errors) {
    final p = 'companies[$i]';
    _requireUuid('$p.id', v['id'], errors);
    _requireNonEmpty('$p.ledger_id', v['ledger_id'], errors);
    _requireNonEmpty('$p.name', v['name'], errors);
    final status = _str(v['status']);
    if (status != null && status != '启用' && status != '停用') {
      errors.add('$p.status 枚举非法：$status');
    }
    _optionalTimestamp('$p.created_at', v['created_at'], errors);
  }

  void _validateRule(int i, Map v, List<String> errors) {
    final p = 'pricing_rules[$i]';
    _requireUuid('$p.id', v['id'], errors);
    _requireNonEmpty('$p.company_id', v['company_id'], errors);
    _requireNonEmpty('$p.name', v['name'], errors); // 规则名必填（03 §2.3）
    if (EnumCodec.pricingMethodFrom(_str(v['pricing_mode'])) == null) {
      errors.add('$p.pricing_mode 枚举非法：${v['pricing_mode']}');
    }

    // 值域（§2.3 / §8）
    final baseRate = v['base_unit_price'];
    if (baseRate is! int) {
      errors.add('$p.base_unit_price 应为整数「分」');
    } else if (!Validators.validBaseRate(baseRate)) {
      errors.add('$p.base_unit_price 必须 > 0，实际 $baseRate');
    }
    _checkRate('$p.overtime_rate', v['overtime_rate'], errors);
    _checkRate('$p.weekend_rate', v['weekend_rate'], errors);
    _checkRate('$p.holiday_rate', v['holiday_rate'], errors);
    final hd = v['half_day_ratio'];
    if (hd != null) {
      if (hd is! int) {
        errors.add('$p.half_day_ratio 应为整数');
      } else if (!Validators.validHalfDayRatio(hd)) {
        errors.add('$p.half_day_ratio 必须在 0~1 之间（1~9），实际 $hd');
      }
    }
    // standard_hours 为可空数值；类型不符须在此拦下，
    // 与 parse 侧的自守护（is num 再取值）形成双保险。
    final sh = v['standard_hours'];
    if (sh != null && sh is! num) {
      errors.add('$p.standard_hours 应为数值或空，实际 ${sh.runtimeType}');
    }
  }

  void _validateRecord(int i, Map v, List<String> errors) {
    final p = 'work_records[$i]';
    _requireUuid('$p.id', v['id'], errors);
    _requireNonEmpty('$p.company_id', v['company_id'], errors);
    _requireDate('$p.attribution_date', v['attribution_date'], errors);
    if (EnumCodec.pricingMethodFrom(_str(v['mode_snapshot'])) == null) {
      errors.add('$p.mode_snapshot 枚举非法：${v['mode_snapshot']}');
    }
    if (v['quantity'] is! num) errors.add('$p.quantity 应为数值');

    final unitPrice = v['unit_price_snapshot'];
    if (unitPrice is! int) {
      errors.add('$p.unit_price_snapshot 应为整数「分」');
    } else if (!Validators.validNonNegativeAmount(unitPrice)) {
      errors.add('$p.unit_price_snapshot 不能为负，实际 $unitPrice');
    }
    final amount = v['amount_snapshot'];
    if (amount is! int) {
      errors.add('$p.amount_snapshot 应为整数「分」');
    } else if (!Validators.validNonNegativeAmount(amount)) {
      errors.add('$p.amount_snapshot 不能为负，实际 $amount');
    }
    if (EnumCodec.amountSourceFrom(_str(v['amount_source'])) == null) {
      errors.add('$p.amount_source 枚举非法：${v['amount_source']}');
    }
    if (EnumCodec.recordStatusFrom(_str(v['status'])) == null) {
      errors.add('$p.status 枚举非法：${v['status']}');
    }
    if (v['auto_reference'] != null && v['auto_reference'] is! int) {
      errors.add('$p.auto_reference 应为整数「分」');
    }
    final rd = v['rate_detail_snapshot'];
    if (rd != null) {
      if (rd is! Map) {
        errors.add('$p.rate_detail_snapshot 应为对象');
      } else if (rd['取用倍率'] != null && rd['取用倍率'] is! int) {
        errors.add('$p.rate_detail_snapshot.取用倍率 应为整数「×10」');
      }
    }
  }

  void _validatePayment(int i, Map v, List<String> errors) {
    final p = 'payment_records[$i]';
    _requireUuid('$p.id', v['id'], errors);
    _requireNonEmpty('$p.company_id', v['company_id'], errors);
    _requireDate('$p.pay_date', v['pay_date'], errors);
    final amount = v['amount'];
    if (amount is! int) {
      errors.add('$p.amount 应为整数「分」');
    } else if (!Validators.validPositiveAmount(amount)) {
      errors.add('$p.amount 必须 > 0（AC-25），实际 $amount');
    }
    final m = _str(v['method']);
    if (m != null && m != '' && EnumCodec.paymentMethodFrom(m) == null) {
      errors.add('$p.method 枚举非法：$m');
    }
  }

  void _validateHoliday(int i, Map v, List<String> errors) {
    final p = 'holiday_marks[$i]';
    _requireUuid('$p.id', v['id'], errors);
    _requireNonEmpty('$p.ledger_id', v['ledger_id'], errors);
    _requireDate('$p.date', v['date'], errors);
    if (EnumCodec.holidayTypeFrom(_str(v['type'])) == null) {
      errors.add('$p.type 枚举非法：${v['type']}');
    }
    final rate = v['rate'];
    if (rate is! int) {
      errors.add('$p.rate 应为整数「×10」');
    } else if (!Validators.validRate(rate)) {
      errors.add('$p.rate 必须 ≥ 1.0（×10 ≥ 10），实际 $rate');
    }
  }

  void _checkRate(String field, dynamic v, List<String> errors) {
    if (v == null) return;
    if (v is! int) {
      errors.add('$field 应为整数「×10」');
    } else if (!Validators.validRate(v)) {
      errors.add('$field 必须 ≥ 1.0（×10 ≥ 10），实际 $v');
    }
  }

  // ───────────────────────── 反序列化 ─────────────────────────

  /// 将已通过 validate 的 Map 重建为 BackupData。
  /// **调用前必须先跑 [validate]**；此处假定类型已合规。
  BackupData parse(Map<String, dynamic> map) {
    return BackupData(
      ledger: _parseLedger(map['ledger'] as Map),
      companies:
          (map['companies'] as List).map((e) => _parseCompany(e as Map)).toList(),
      pricingRules: (map['pricing_rules'] as List)
          .map((e) => _parseRule(e as Map))
          .toList(),
      workRecords: (map['work_records'] as List)
          .map((e) => _parseRecord(e as Map))
          .toList(),
      paymentRecords: (map['payment_records'] as List)
          .map((e) => _parsePayment(e as Map))
          .toList(),
      holidayMarks: (map['holiday_marks'] as List)
          .map((e) => _parseHoliday(e as Map))
          .toList(),
    );
  }

  Ledger _parseLedger(Map v) => Ledger(
        id: v['id'] as String,
        name: v['nickname'] as String,
        currency: (v['currency'] as String?) ?? 'CNY',
        mode: EnumCodec.ledgerModeFrom(_str(v['mode'])) ?? LedgerMode.local,
        createdAt: _parseDate(v['created_at']) ?? DateTime.now(),
      );

  Company _parseCompany(Map v) => Company(
        id: v['id'] as String,
        ledgerId: v['ledger_id'] as String,
        name: v['name'] as String,
        shortName: _str(v['short_name']),
        color: _parseColor(_str(v['tag_color'])),
        defaultRuleId: _str(v['default_rule_id']),
        enabled: EnumCodec.enabledFrom(_str(v['status'])),
        contact: _str(v['contact']),
        currency: _str(v['currency']) ?? 'CNY',
        note: _str(v['note']),
        createdAt: _parseDate(v['created_at']) ?? DateTime.now(),
        updatedAt: _parseDate(v['updated_at']) ?? DateTime.now(),
        deletedAt: _parseDate(v['deleted_at']),
      );

  PricingRule _parseRule(Map v) => PricingRule(
        id: v['id'] as String,
        companyId: v['company_id'] as String,
        name: v['name'] as String,
        method: EnumCodec.pricingMethodFrom(_str(v['pricing_mode'])) ??
            PricingMethod.hourly,
        baseRate: _asInt(v['base_unit_price']),
        unit: _str(v['unit']),
        standardHours: v['standard_hours'] is num
            ? (v['standard_hours'] as num).toDouble()
            : null,
        halfDayRatio: _asInt(v['half_day_ratio'], fallback: 5),
        overtimeRate: _asInt(v['overtime_rate'], fallback: 15),
        weekendRate: _asInt(v['weekend_rate'], fallback: 10),
        holidayRate: _asInt(v['holiday_rate'], fallback: 10),
        effectiveDate: _parseDate(v['effective_date']),
        enabled: EnumCodec.enabledFrom(_str(v['status'])),
        createdAt: _parseDate(v['created_at']) ?? DateTime.now(),
        updatedAt: _parseDate(v['updated_at']) ?? DateTime.now(),
        deletedAt: _parseDate(v['deleted_at']),
      );

  WorkRecord _parseRecord(Map v) => WorkRecord(
        id: v['id'] as String,
        workDate: _parseDate(v['attribution_date']) ?? DateTime.now(),
        companyId: v['company_id'] as String,
        pricingRuleId: _str(v['pricing_rule_id']),
        methodSnapshot: EnumCodec.pricingMethodFrom(_str(v['mode_snapshot'])) ??
            PricingMethod.hourly,
        qtySnapshot: (v['quantity'] as num).toDouble(),
        qtyUnitSnapshot: _str(v['quantity_unit_snapshot']),
        startTime: _parseHhmm(v['start_time']),
        endTime: _parseHhmm(v['end_time']),
        overnight: v['is_overnight'] == true,
        rateSnapshot: _asInt(v['unit_price_snapshot']),
        rateDetailSnapshot: _parseRateDetail(v['rate_detail_snapshot']),
        amountSnapshot: _asInt(v['amount_snapshot']),
        amountSource: EnumCodec.amountSourceFrom(_str(v['amount_source'])) ??
            AmountSource.auto,
        autoReferenceAmount:
            v['auto_reference'] == null ? null : _asInt(v['auto_reference']),
        currencySnapshot: _str(v['currency']),
        note: _str(v['note']),
        status: EnumCodec.recordStatusFrom(_str(v['status'])) ??
            RecordStatus.confirmed,
        createdAt: _parseDate(v['created_at']) ?? DateTime.now(),
        updatedAt: _parseDate(v['updated_at']) ?? DateTime.now(),
        deletedAt: _parseDate(v['deleted_at']),
      );

  RateSnapshot _parseRateDetail(dynamic v) {
    if (v is! Map) return const RateSnapshot(appliedRate: 10);
    final rates = (v['各倍率'] is Map) ? (v['各倍率'] as Map) : const {};
    final hits = (v['命中项'] is List) ? (v['命中项'] as List) : const [];
    return RateSnapshot(
      overtime: hits.contains('加班'),
      overtimeRate: _asInt(rates['加班'], fallback: 10),
      weekend: hits.contains('周末'),
      weekendRate: _asInt(rates['周末'], fallback: 10),
      holiday: hits.contains('节假日'),
      holidayRate: _asInt(rates['节假日'], fallback: 10),
      appliedRate: _asInt(v['取用倍率'], fallback: 10),
    );
  }

  PaymentRecord _parsePayment(Map v) => PaymentRecord(
        id: v['id'] as String,
        paymentDate: _parseDate(v['pay_date']) ?? DateTime.now(),
        companyId: v['company_id'] as String,
        amount: _asInt(v['amount']),
        method: EnumCodec.paymentMethodFrom(_str(v['method'])),
        note: _str(v['note']),
        createdAt: _parseDate(v['created_at']) ?? DateTime.now(),
        updatedAt: _parseDate(v['updated_at']) ?? DateTime.now(),
        deletedAt: _parseDate(v['deleted_at']),
      );

  HolidayMark _parseHoliday(Map v) => HolidayMark(
        id: v['id'] as String,
        ledgerId: v['ledger_id'] as String,
        date: _parseDate(v['date']) ?? DateTime.now(),
        type: EnumCodec.holidayTypeFrom(_str(v['type'])) ?? HolidayType.custom,
        rate: _asInt(v['rate'], fallback: 10),
        manual: _str(v['source']) != '系统日历',
        createdAt: _parseDate(v['created_at']) ?? DateTime.now(),
      );

  // ───────────────────────── 冲突策略 + 软警告（§6.4 步骤3/4） ─────────────────────────

  /// 规划导入：给定本地已有 id 集合与来件 id 集合，产出冲突清单与执行策略。
  ImportPlan planImport({
    required Set<String> localIds,
    required Set<String> incomingIds,
    ImportStrategy strategy = ImportStrategy.overwrite,
    List<String> warnings = const [],
  }) {
    final conflicts = incomingIds.where(localIds.contains).toList();
    final abort = strategy == ImportStrategy.reject && conflicts.isNotEmpty;
    return ImportPlan(
      strategy: strategy,
      conflicts: conflicts,
      abort: abort,
      warnings: warnings,
    );
  }

  /// 软警告校验（§6.4 步骤3）：弱引用悬空 / 手工覆盖缺自动参考值 / 日期超界。
  /// 返回警告列表；调用方可继续导入。
  List<String> softWarnings(BackupData data, {DateTime? now}) {
    final warnings = <String>[];
    final companyIds = data.companies.map((c) => c.id).toSet();
    final ruleIds = data.pricingRules.map((r) => r.id).toSet();
    final refNow = now ?? DateTime.now();

    for (final w in data.workRecords) {
      if (!companyIds.contains(w.companyId)) {
        warnings.add('工作记录 ${w.id} 指向不存在的公司 ${w.companyId}');
      }
      if (w.pricingRuleId != null && !ruleIds.contains(w.pricingRuleId)) {
        warnings.add('工作记录 ${w.id} 弱引用悬空的规则 ${w.pricingRuleId}（允许，溯源降级）');
      }
      if (w.amountSource == AmountSource.manual && w.autoReferenceAmount == null) {
        warnings.add('工作记录 ${w.id} 手工覆盖但缺自动参考值（允许，对照功能降级）');
      }
      if (w.workDate.isAfter(refNow.add(const Duration(days: 1)))) {
        warnings.add('工作记录 ${w.id} 归属日超界（未来日期 ${w.workDate}）');
      }
    }
    for (final p in data.paymentRecords) {
      if (!companyIds.contains(p.companyId)) {
        warnings.add('收款记录 ${p.id} 指向不存在的公司 ${p.companyId}');
      }
    }
    final softDeleted = data.workRecords.where((w) => w.isDeleted).length +
        data.paymentRecords.where((p) => p.isDeleted).length +
        data.companies.where((c) => c.isDeleted).length;
    if (softDeleted > 0) {
      warnings.add('含软删记录 $softDeleted 条（将原样保留）');
    }
    return warnings;
  }

  // ─────────────── 导入后不变量校验（R55 / R57；纯函数，不触 DB） ───────────────

  /// 导入后不变量校验——**纯函数，不触 DB**，由 UI（事务内）与测试脚本**共用**。
  ///
  /// **不许同构复刻**：规范序列化**复用 [ExportService.toMap]**（与导出写盘同一口径），
  /// 不在此另写一套实体序列化。
  ///
  /// 入参：[pre]/[post] 为调用方从存储层读出的**导入前/后快照**（[ImportSnapshot]）；
  /// [newIds] = 本策略**实际新插入**的 id 集合（`= 来件六表 id 集合 − 导入前本机 id 集合`）。
  ///
  /// 断言分两档（主理人裁定）：
  ///  - [ImportVerification.failures]（**恒须**，策略无关）：六表来件 id 全部落库；
  ///    **覆盖**策略下金额合计逐点相等（原 `_assertImportResult` 口径，`03 §6.5` 断言 2）；
  ///    （R57/MIN-2）节假日 `(ledger_id,date)` 键集合 + `type`/`rate` 一致；覆盖策略下
  ///    公司/规则/工作记录/收款**逐条内容相等**。
  ///  - [ImportVerification.mergeFailures]（**仅 `merge`**，R55）：
  ///    (A) 本机原有 id 逐条不变（四张以 id 为主键的表）；(B) 新插入 id 与来件 1:1 相等；
  ///    (C) 四表 id 集合 = 导入前本机集合 ∪ 来件集合（**不简化**为「只比新插入」）。
  ///
  /// **已知宽容（G-13，`15 §11` 缺口 6）**：`upsertHolidayMarkOn` 为 `INSERT OR REPLACE`
  /// （`(ledger_id,date)` 唯一约束）→ 同 `(ledger_id,date)` 不同 id 会**静默换 id**。故 (A)/(C)
  /// 的 **id 集合恒等式只作用于四张 id 主键表**（公司/规则/工作记录/收款），节假日的等价性改由
  /// **(ledger_id,date) 键 + 关键值**断言覆盖（id 可漂移、键不可漂移）。
  ///
  /// **坏行宽容**：来件 id 若在导入前本机快照 [ImportSnapshot.ids] 中已存在，则「落库」判定通过
  /// （坏行无法序列化，容错读会跳过；此为已知边界，见 `15 §11`）。
  ImportVerification verifyImportInvariants({
    required ImportStrategy strategy,
    required ImportSnapshot pre,
    required ImportSnapshot post,
    required BackupData data,
    required Set<String> newIds,
  }) {
    final inc = const ExportService().toMap(data);
    final preM = _snapshotMaps(pre);
    final postM = _snapshotMaps(post);

    final incCompanies = _byId(inc['companies']);
    final incRules = _byId(inc['pricing_rules']);
    final incWorks = _byId(inc['work_records']);
    final incPays = _byId(inc['payment_records']);
    final incHols = _byId(inc['holiday_marks']);

    final preCompanies = _byId(preM['companies']!);
    final preRules = _byId(preM['pricing_rules']!);
    final preWorks = _byId(preM['work_records']!);
    final prePays = _byId(preM['payment_records']!);

    final postCompanies = _byId(postM['companies']!);
    final postRules = _byId(postM['pricing_rules']!);
    final postWorks = _byId(postM['work_records']!);
    final postPays = _byId(postM['payment_records']!);
    final postHols = _byId(postM['holiday_marks']!);

    final failures = <String>[];
    final mergeFailures = <String>[];

    // ── 恒须 F1：来件六表逐条落库（存在性） ──
    _reportMissing('公司', incCompanies, postCompanies, pre.ids, failures);
    _reportMissing('规则', incRules, postRules, pre.ids, failures);
    _reportMissing('工作记录', incWorks, postWorks, pre.ids, failures);
    _reportMissing('收款', incPays, postPays, pre.ids, failures);
    _reportMissing('节假日', incHols, postHols, pre.ids, failures);

    // ── 恒须 F2：覆盖策略金额合计逐点相等（原 `_assertImportResult` 口径，§6.5 断言 2） ──
    if (strategy == ImportStrategy.overwrite) {
      const svc = ReceivableService();
      final incWorkIds = data.workRecords.map((w) => w.id).toSet();
      final postWorkById = {for (final w in post.workRecords) w.id: w};
      final recvBackup = svc.receivable(data.workRecords);
      final recvLocal = svc.receivable(incWorkIds
          .where(postWorkById.containsKey)
          .map((id) => postWorkById[id]!));
      if (recvBackup != recvLocal) {
        failures.add('覆盖后应收不一致 本机=$recvLocal 备份=$recvBackup');
      }
      final incPayIds = data.paymentRecords.map((p) => p.id).toSet();
      final postPayById = {for (final p in post.paymentRecords) p.id: p};
      final gotBackup = svc.received(data.paymentRecords);
      final gotLocal = svc.received(
          incPayIds.where(postPayById.containsKey).map((id) => postPayById[id]!));
      if (gotBackup != gotLocal) {
        failures.add('覆盖后已收不一致 本机=$gotLocal 备份=$gotBackup');
      }
    }

    // ── 恒须 F3：节假日 (ledger_id,date) 键集合 + 关键值（R57/MIN-2；G-13 宽容 id 漂移） ──
    final incHolKeys = _holidayByKey(inc['holiday_marks']);
    final preHolKeys = _holidayByKey(preM['holiday_marks']!);
    final postHolKeys = _holidayByKey(postM['holiday_marks']!);
    final expectHolKeys = {...preHolKeys.keys, ...incHolKeys.keys};
    final postHolKeySet = postHolKeys.keys.toSet();
    final missHol = expectHolKeys.difference(postHolKeySet);
    final extraHol = postHolKeySet.difference(expectHolKeys);
    if (missHol.isNotEmpty) {
      failures.add('节假日少 ${missHol.length} 个(账本@日期)：${missHol.take(3).join('；')}');
    }
    if (extraHol.isNotEmpty) {
      failures.add('节假日多 ${extraHol.length} 个(账本@日期)：${extraHol.take(3).join('；')}');
    }
    for (final e in incHolKeys.entries) {
      final p = postHolKeys[e.key];
      if (p == null ||
          p['type'] != e.value['type'] ||
          p['rate'] != e.value['rate']) {
        failures.add('节假日 ${e.key} 关键值不符：'
            '本机=${p?['type']}/${p?['rate']} 来件=${e.value['type']}/${e.value['rate']}');
      }
    }

    // ── 恒须 F4：覆盖策略下四表来件逐条内容相等（R57/MIN-2 的"条数 + 关键值"最强形式） ──
    if (strategy == ImportStrategy.overwrite) {
      _reportMismatch('公司', incCompanies, postCompanies, failures);
      _reportMismatch('规则', incRules, postRules, failures);
      _reportMismatch('工作记录', incWorks, postWorks, failures);
      _reportMismatch('收款', incPays, postPays, failures);
    }

    // ── merge (A)(B)(C)（R55） ──
    if (strategy == ImportStrategy.merge) {
      // (A) 本机原有 id 逐条不变（四张 id 主键表）
      _reportMergeA('公司', preCompanies, postCompanies, mergeFailures);
      _reportMergeA('规则', preRules, postRules, mergeFailures);
      _reportMergeA('工作记录', preWorks, postWorks, mergeFailures);
      _reportMergeA('收款', prePays, postPays, mergeFailures);

      // (B) 新插入 id 与来件 1:1 相等（六表，含节假日）
      final incAll = {
        ...incCompanies, ...incRules, ...incWorks, ...incPays, ...incHols,
      };
      final preAll = {
        ...preCompanies, ...preRules, ...preWorks, ...prePays,
        ..._byId(preM['holiday_marks']!),
      };
      final shouldBeNew = incAll.keys.toSet().difference(preAll.keys.toSet());
      final notCovered = shouldBeNew.difference(newIds);
      if (notCovered.isNotEmpty) {
        mergeFailures.add('(B) 来件新 id 未纳入 newIds：${notCovered.take(3).join(',')}');
      }
      final postAll = {
        ...postCompanies, ...postRules, ...postWorks, ...postPays, ...postHols,
      };
      for (final id in newIds) {
        if (!incAll.containsKey(id)) {
          mergeFailures.add('(B) newIds 含非来件 id：$id');
        } else if (postAll[id] != incAll[id]) {
          mergeFailures.add('(B) 新插入 $id 内容≠来件');
        }
      }

      // (C) 四表 id 集合 = 导入前本机集合 ∪ 来件集合（不简化）
      final preFour = {
        ...preCompanies.keys, ...preRules.keys, ...preWorks.keys, ...prePays.keys,
      };
      final incFour = {
        ...incCompanies.keys, ...incRules.keys, ...incWorks.keys, ...incPays.keys,
      };
      final postFour = {
        ...postCompanies.keys, ...postRules.keys, ...postWorks.keys, ...postPays.keys,
      };
      final union = {...preFour, ...incFour};
      final lost = union.difference(postFour);
      final extra = postFour.difference(union);
      if (lost.isNotEmpty) mergeFailures.add('(C) 导入后缺 id：${lost.take(3).join(',')}');
      if (extra.isNotEmpty) mergeFailures.add('(C) 导入后多 id：${extra.take(3).join(',')}');
    }

    return ImportVerification(failures: failures, mergeFailures: mergeFailures);
  }

  /// 快照 → 规范 Map（**复用 [ExportService.toMap]**；ledger 传占位符，仅取五表）。
  Map<String, List<Map<String, dynamic>>> _snapshotMaps(ImportSnapshot s) {
    final m = const ExportService().toMap(
      BackupData(
        ledger: Ledger(
          id: '·snapshot·',
          name: '·snapshot·',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        companies: s.companies,
        pricingRules: s.pricingRules,
        workRecords: s.workRecords,
        paymentRecords: s.paymentRecords,
        holidayMarks: s.holidayMarks,
      ),
    );
    List<Map<String, dynamic>> l(String k) =>
        (m[k] as List).cast<Map<String, dynamic>>();
    return {
      'companies': l('companies'),
      'pricing_rules': l('pricing_rules'),
      'work_records': l('work_records'),
      'payment_records': l('payment_records'),
      'holiday_marks': l('holiday_marks'),
    };
  }

  static Map<String, String> _byId(dynamic maps) => {
        for (final m in (maps as List).cast<Map<String, dynamic>>())
          m['id'] as String: jsonEncode(m),
      };

  static Map<String, Map<String, dynamic>> _holidayByKey(dynamic maps) => {
        for (final m in (maps as List).cast<Map<String, dynamic>>())
          '${m['ledger_id']}@${m['date']}': m,
      };

  static void _reportMissing(
    String label,
    Map<String, String> inc,
    Map<String, String> post,
    Set<String> preIds,
    List<String> out,
  ) {
    final miss = inc.keys
        .where((id) => !post.containsKey(id) && !preIds.contains(id))
        .toList();
    if (miss.isNotEmpty) {
      out.add('$label 缺 ${miss.length} 条（如 ${miss.take(3).join(',')}）');
    }
  }

  static void _reportMismatch(
    String label,
    Map<String, String> inc,
    Map<String, String> post,
    List<String> out,
  ) {
    final bad = inc.entries
        .where((e) => post.containsKey(e.key) && post[e.key] != e.value)
        .map((e) => e.key)
        .toList();
    if (bad.isNotEmpty) {
      out.add('$label 内容与被件不符 ${bad.length} 条（如 ${bad.take(3).join(',')}）');
    }
  }

  static void _reportMergeA(
    String label,
    Map<String, String> pre,
    Map<String, String> post,
    List<String> out,
  ) {
    for (final e in pre.entries) {
      if (!post.containsKey(e.key)) {
        out.add('(A) 本机原有 $label ${e.key} 丢失');
      } else if (post[e.key] != e.value) {
        out.add('(A) 本机原有 $label ${e.key} 被改写');
      }
    }
  }

  // ───────────────────────── 底层校验/解析工具 ─────────────────────────

  /// 安全取字符串（类型不符返回 null，不抛异常）。
  String? _str(dynamic v) => v is String ? v : null;

  void _requireUuid(String field, dynamic v, List<String> errors) {
    if (v is! String || !_id.hasMatch(v)) {
      errors.add('$field 非法 id：$v');
    }
  }

  void _requireNonEmpty(String field, dynamic v, List<String> errors) {
    if (v is! String || v.isEmpty) errors.add('$field 缺失或非文本');
  }

  void _requireDate(String field, dynamic v, List<String> errors) {
    if (v is! String || !_date.hasMatch(v)) errors.add('$field 日期格式非法：$v');
  }

  void _optionalTimestamp(String field, dynamic v, List<String> errors) {
    if (v != null && (v is! String || DateTime.tryParse(v) == null)) {
      errors.add('$field 时间戳非法：$v');
    }
  }

  int _asInt(dynamic v, {int fallback = 0}) =>
      v is int ? v : (v is num ? v.round() : fallback);

  DateTime? _parseDate(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }

  DateTime? _parseHhmm(dynamic v) {
    if (v is! String || !v.contains(':')) return null;
    final parts = v.split(':');
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(1970, 1, 1, h, m); // 仅时间有意义，日期占位
  }

  /// 颜色约定：备份中 `tag_color` 为 **6 位 RGB**（如 "#E53935"，无 alpha）；
  /// 导入还原为不含 alpha 的 RGB 整数，UI 渲染时补 `0xFF000000`。（§6.2 示例一致）
  int _parseColor(String? hex) {
    if (hex == null) return 0;
    final cleaned = hex.replaceFirst('#', '');
    return int.tryParse(cleaned, radix: 16) ?? 0;
  }
}
