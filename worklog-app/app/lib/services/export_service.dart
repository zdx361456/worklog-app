/// 数据导出与备份服务（基础版新增功能）
/// 对应 03 §6。
///
/// 设计底线：导出原始记录（含快照与软删），不导出派生值；导入恢复后快照不被重算。
/// 金额一律整数「分」序列化（§6.2 规则2），倍率整数「×10」。
/// 枚举文案经 EnumCodec 统一，与导入校验共用同一映射（避免两处耦合）。
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
import 'receivable_service.dart';

/// 备份文件格式标识与版本（§6.2）。
const String kBackupFormat = 'worklog-app-backup';
const int kBackupSchemaVersion = 1;

/// 全量备份的数据容器（六实体，逐表全量，含软删）。
class BackupData {
  final Ledger ledger;
  final List<Company> companies;
  final List<PricingRule> pricingRules;
  final List<WorkRecord> workRecords;
  final List<PaymentRecord> paymentRecords;
  final List<HolidayMark> holidayMarks;

  const BackupData({
    required this.ledger,
    required this.companies,
    required this.pricingRules,
    required this.workRecords,
    required this.paymentRecords,
    required this.holidayMarks,
  });
}

/// 导出服务。
class ExportService {
  static const String formatTag = kBackupFormat;
  static const int schemaVersion = kBackupSchemaVersion;

  const ExportService();

  // ───────────────────────── JSON 全量备份 ─────────────────────────

  /// 序列化为 JSON 全量备份字符串（UTF-8，无 BOM）。
  /// 金额以整数「分」，倍率以整数「×10」（§6.2 规则2）。
  String toJson(BackupData data, {DateTime? exportedAt, String appVersion = '1.0.0'}) {
    final map = <String, dynamic>{
      'format': formatTag,
      'schema_version': schemaVersion,
      'exported_at': (exportedAt ?? DateTime.now()).toIso8601String(),
      'app_version': appVersion,
      'ledger': _ledgerToMap(data.ledger),
      'companies': data.companies.map(_companyToMap).toList(),
      'pricing_rules': data.pricingRules.map(_ruleToMap).toList(),
      'work_records': data.workRecords.map(_recordToMap).toList(),
      'payment_records': data.paymentRecords.map(_paymentToMap).toList(),
      'holiday_marks': data.holidayMarks.map(_holidayToMap).toList(),
    };
    return jsonEncode(map);
  }

  /// 序列化为已解析的 Map（供导入校验断言使用）。
  Map<String, dynamic> toMap(BackupData data,
          {DateTime? exportedAt, String appVersion = '1.0.0'}) =>
      jsonDecode(toJson(data, exportedAt: exportedAt, appVersion: appVersion))
          as Map<String, dynamic>;

  Map<String, dynamic> _ledgerToMap(Ledger l) => {
        'id': l.id,
        'nickname': l.name,
        'currency': l.currency,
        'mode': EnumCodec.ledgerMode(l.mode),
        'created_at': l.createdAt.toIso8601String(),
      };

  Map<String, dynamic> _companyToMap(Company c) => {
        'id': c.id,
        'ledger_id': c.ledgerId,
        'name': c.name,
        'short_name': c.shortName,
        'tag_color': _colorToHex(c.color),
        'default_rule_id': c.defaultRuleId,
        'contact': c.contact,
        'status': EnumCodec.enabled(c.enabled),
        'currency': c.currency,
        'note': c.note,
        'deleted_at': c.deletedAt?.toIso8601String(),
        'created_at': c.createdAt.toIso8601String(),
        'updated_at': c.updatedAt.toIso8601String(),
      };

  Map<String, dynamic> _ruleToMap(PricingRule r) => {
        'id': r.id,
        'company_id': r.companyId,
        'name': r.name,
        'pricing_mode': EnumCodec.pricingMethod(r.method),
        'base_unit_price': r.baseRate, // 分
        'unit': r.unit,
        'standard_hours': r.standardHours,
        'half_day_ratio': r.halfDayRatio, // ×10
        'overtime_rate': r.overtimeRate, // ×10
        'weekend_rate': r.weekendRate, // ×10
        'holiday_rate': r.holidayRate, // ×10
        'effective_date': r.effectiveDate?.toIso8601String(),
        'status': EnumCodec.enabled(r.enabled),
        'created_at': r.createdAt.toIso8601String(),
        'updated_at': r.updatedAt.toIso8601String(),
        'deleted_at': r.deletedAt?.toIso8601String(),
      };

  Map<String, dynamic> _recordToMap(WorkRecord w) => {
        'id': w.id,
        'company_id': w.companyId,
        'pricing_rule_id': w.pricingRuleId,
        'attribution_date': _dateOnly(w.workDate),
        'mode_snapshot': EnumCodec.pricingMethod(w.methodSnapshot),
        'quantity': w.qtySnapshot,
        'quantity_unit_snapshot': w.qtyUnitSnapshot,
        'start_time': w.startTime == null ? null : _hhmm(w.startTime!),
        'end_time': w.endTime == null ? null : _hhmm(w.endTime!),
        'is_overnight': w.overnight,
        'unit_price_snapshot': w.rateSnapshot, // 分
        'rate_detail_snapshot': _rateDetailToMap(w.rateDetailSnapshot),
        'amount_snapshot': w.amountSnapshot, // 分
        'amount_source': EnumCodec.amountSource(w.amountSource),
        'auto_reference': w.autoReferenceAmount, // 分
        'currency': w.currencySnapshot,
        'note': w.note,
        'status': EnumCodec.recordStatus(w.status),
        'created_at': w.createdAt.toIso8601String(),
        'updated_at': w.updatedAt.toIso8601String(),
        'deleted_at': w.deletedAt?.toIso8601String(),
      };

  Map<String, dynamic> _rateDetailToMap(RateSnapshot r) {
    final hits = <String>[];
    if (r.overtime) hits.add('加班');
    if (r.weekend) hits.add('周末');
    if (r.holiday) hits.add('节假日');
    return {
      '命中项': hits,
      '各倍率': {
        '加班': r.overtimeRate,
        '周末': r.weekendRate,
        '节假日': r.holidayRate,
      },
      '取用倍率': r.appliedRate,
    };
  }

  Map<String, dynamic> _paymentToMap(PaymentRecord p) => {
        'id': p.id,
        'company_id': p.companyId,
        'pay_date': _dateOnly(p.paymentDate),
        'amount': p.amount, // 分
        'method': EnumCodec.paymentMethod(p.method),
        'note': p.note,
        'created_at': p.createdAt.toIso8601String(),
        'updated_at': p.updatedAt.toIso8601String(),
        'deleted_at': p.deletedAt?.toIso8601String(),
      };

  Map<String, dynamic> _holidayToMap(HolidayMark h) => {
        'id': h.id,
        'ledger_id': h.ledgerId,
        'date': _dateOnly(h.date),
        'type': EnumCodec.holidayType(h.type),
        'rate': h.rate, // ×10
        'source': EnumCodec.holidaySource(h.manual),
        'created_at': h.createdAt.toIso8601String(),
      };

  // ───────────────────────── CSV 导出（面向人看） ─────────────────────────

  /// 生成工作记录 CSV（UTF-8 带 BOM，金额两位小数）。
  String workRecordsCsv(List<WorkRecord> records, Map<String, String> companyNames,
      Map<String, String> ruleNames) {
    final buf = StringBuffer();
    buf.write('\uFEFF'); // BOM，Excel 打开不乱码
    buf.writeln('归属日,公司,规则名,计价方式,数量,单位,实际单价(元),倍率命中,取用倍率,金额(元),金额来源,状态,备注,创建时间');
    for (final w in records) {
      final hitNames = <String>[];
      if (w.rateDetailSnapshot.overtime) hitNames.add('加班');
      if (w.rateDetailSnapshot.weekend) hitNames.add('周末');
      if (w.rateDetailSnapshot.holiday) hitNames.add('节假日');
      // 备注原文交给 _csvLine 按 RFC 4180 转义，不做替换（保持原文）。
      final fields = [
        _dateOnly(w.workDate),
        companyNames[w.companyId] ?? w.companyId,
        ruleNames[w.pricingRuleId ?? ''] ?? '',
        EnumCodec.pricingMethod(w.methodSnapshot),
        _num(w.qtySnapshot),
        w.qtyUnitSnapshot ?? '',
        _yuan(w.rateSnapshot),
        hitNames.join('/'),
        _rate(w.rateDetailSnapshot.appliedRate),
        _yuan(w.amountSnapshot),
        EnumCodec.amountSource(w.amountSource),
        EnumCodec.recordStatus(w.status),
        w.note ?? '',
        w.createdAt.toIso8601String(),
      ];
      buf.writeln(_csvLine(fields));
    }
    return buf.toString();
  }

  /// 生成收款记录 CSV（UTF-8 带 BOM，金额两位小数）。
  String paymentRecordsCsv(List<PaymentRecord> payments, Map<String, String> companyNames) {
    final buf = StringBuffer();
    buf.write('\uFEFF');
    buf.writeln('收款日期,公司,金额(元),收款方式,备注,创建时间');
    for (final p in payments) {
      final fields = [
        _dateOnly(p.paymentDate),
        companyNames[p.companyId] ?? p.companyId,
        _yuan(p.amount),
        EnumCodec.paymentMethod(p.method),
        p.note ?? '',
        p.createdAt.toIso8601String(),
      ];
      buf.writeln(_csvLine(fields));
    }
    return buf.toString();
  }

  String _csvLine(List<String> fields) {
    return fields
        .map((f) => f.contains(',') || f.contains('"') || f.contains('\n')
            ? '"${f.replaceAll('"', '""')}"'
            : f)
        .join(',');
  }

  // ───────────────────────── 一致性断言（§6.5） ─────────────────────────

  /// 断言：导出文件内有效记录/收款合计 == App 内应收/已收合计（定点精确相等）。
  ///
  /// - 应收口径：status ∈ {已确认, 已结算} 且 deleted_at == null（AC-32 / §8#1/#3）。
  /// - 已收口径：deleted_at == null。
  /// - 状态判断走 EnumCodec 映射（非中文字面量硬编码），避免文案改动破坏断言。
  bool assertExportConsistency({
    required List<WorkRecord> workRecords,
    required List<PaymentRecord> paymentRecords,
    required Map<String, dynamic> exportedJson,
  }) {
    final svc = const ReceivableService();
    final draftTag = EnumCodec.recordStatus(RecordStatus.draft);

    final modelReceivable = svc.receivable(workRecords);
    final modelReceived = svc.received(paymentRecords);

    final jsonRecords = (exportedJson['work_records'] as List? ?? const []);
    var jsonReceivable = 0;
    for (final r in jsonRecords.cast<Map>()) {
      if (r['deleted_at'] != null) continue;
      if (r['status'] == draftTag) continue;
      jsonReceivable += (r['amount_snapshot'] as num).toInt();
    }

    final jsonPayments = (exportedJson['payment_records'] as List? ?? const []);
    var jsonReceived = 0;
    for (final p in jsonPayments.cast<Map>()) {
      if (p['deleted_at'] != null) continue;
      jsonReceived += (p['amount'] as num).toInt();
    }

    return modelReceivable == jsonReceivable && modelReceived == jsonReceived;
  }

  // ───────────────────────── 工具 ─────────────────────────

  String _colorToHex(int color) =>
      '#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

  String _hhmm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  String _two(int n) => n.toString().padLeft(2, '0');

  /// 分 → 元（两位小数，人类可读）。
  String _yuan(int fen) => (fen / 100).toStringAsFixed(2);

  /// ×10 → 倍率（一位小数）。
  String _rate(int x10) => (x10 / 10).toStringAsFixed(1);

  String _num(double v) => v == v.roundToDouble()
      ? v.toInt().toString()
      : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
