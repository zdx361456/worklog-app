/// P13 · 导出备份页（Wave C2 原位填充）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.13（`07:637-706`）与 **§4.3 I-4 全量读**
///（`07:803-843`，核心裁决：**逐表显式传参 + 全量断言 + 失败即中止**）；
/// `docs/04-迭代/2026-10-05/补齐规格07剩余页/02-需求与验收.md` §D.11（`AC-P13-*`）。
///
/// **本文件为何由主理人先行落盘**（而非 C2 自己新建）：
/// Wave C1 的 P12 设置页需要「导出备份」入口指向本页。若 C1 先接线、C2 后建文件，
/// C1 的**全量类型编译**会因缺文件而失败（rc=254）。故先把骨架落下来，
/// 让 C1 可安全接线、C2 **原位填充**——与 Wave A2 的「占位骨架 → 原位填充」同一手法。
///
/// **构造签名冻结**：`const ExportBackupPage({super.key})` 被 Wave C1 的 P12 接线依赖，**不得改**。
///
/// **依赖（U-1 批准，用途限本页）**：`path_provider`（落盘目录）+ `share_plus`（分享）+
/// `file_picker`（选文件导入）。**除这 3 个库外，本页不新增任何依赖**。
///
/// **纪律**：金额一律整数「分」——本页**零浮点**（无 `fen/100` / `double.parse` / `.round()`）。
/// 金额仅经既有 `ExportService._yuan`（导出层 CSV 格式化，`07 §1.1` 规则 2 例外条款）落 CSV。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_state.dart';
import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/pricing_rule.dart';
import '../models/work_record.dart';
import '../models/payment_record.dart';
import '../models/holiday_mark.dart';
import '../services/export_service.dart';
import '../services/import_service.dart';

class ExportBackupPage extends StatefulWidget {
  const ExportBackupPage({super.key});

  @override
  State<ExportBackupPage> createState() => _ExportBackupPageState();
}

class _ExportBackupPageState extends State<ExportBackupPage> {
  /// App 版本号（供备份文件 `app_version` 字段）。
  /// 不引 `package_info_plus`（**U-1：不新增依赖**）→ 与 `pubspec.yaml` 主版本对齐。
  static const String _appVersion = '1.0.0';

  bool _loading = true;
  Object? _error;
  bool _busy = false;

  /// 「上次备份时间」——**G-07 本地偏好存储未落地**（U-1 未批准 `shared_preferences`，
  /// 且不得新增表）→ 仅**会话内存态**；重启回到「从未备份」。见设计 §11 缺口 1。
  DateTime? _lastBackupAt;

  /// 坏行计数（`07:865` / AC-P13-11）：经容错读检测，供黄色提示条。
  int _badRowCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ledgerId = AppState.ledgerId;
      if (ledgerId == null) {
        throw StateError('账本尚未初始化（AppState.ledgerId 为空）');
      }
      final db = AppDatabase.instance;
      // 坏行检测：容错读（跳过坏行并计数），不因单行脏值致整页失败。
      final w = await db.listWorkRecordsLenient(
        includeDeleted: true,
        includeDraft: true,
      );
      final p = await db.listPaymentRecordsLenient(includeDeleted: true);
      if (!mounted) return;
      setState(() {
        _badRowCount = w.skippedCount + p.skippedCount;
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

  // ───────────────────────── 导出：BackupData 全量组装 ─────────────────────────

  /// **§4.3 I-4 唯一写法**（`07:809-821`）：**逐表显式传参**，任一漏参 → 备份非全量。
  Future<BackupData> _buildBackupData() async {
    final db = AppDatabase.instance;
    final ledgerId = AppState.ledgerId;
    if (ledgerId == null) {
      throw StateError('账本尚未初始化（AppState.ledgerId 为空）');
    }
    final ledger = await db.getLedger(ledgerId);
    if (ledger == null) {
      throw StateError('账本不存在（id=$ledgerId）');
    }
    return BackupData(
      ledger: ledger,
      companies: await db.listCompanies(
        ledgerId: ledgerId,
        includeDeleted: true,
        includeDisabled: true,
      ),
      pricingRules: await db.listPricingRules(
        includeDeleted: true,
        includeDisabled: true,
      ),
      workRecords: await db.listWorkRecords(
        includeDeleted: true,
        includeDraft: true,
      ),
      paymentRecords: await db.listPaymentRecords(includeDeleted: true),
      holidayMarks: await db.listHolidayMarks(ledgerId: ledgerId),
    );
  }

  /// **全量断言 A1~A4**（`07:824-831`）：任一失败即中止，不产出半份文件。
  ///
  /// 断言右值 = **显式传参**版全量读 → 若组装左值被误改为默认参数（漏 `includeDisabled` /
  /// `includeDeleted` / `includeDraft`），左值会小于右值 → 断言失败（**非空转**）。
  Future<void> _assertFullExportCounts(BackupData data) async {
    final db = AppDatabase.instance;
    final ledgerId = AppState.ledgerId;
    final companies = await db.listCompanies(
      ledgerId: ledgerId,
      includeDeleted: true,
      includeDisabled: true,
    );
    final rules = await db.listPricingRules(
      includeDeleted: true,
      includeDisabled: true,
    );
    final works = await db.listWorkRecords(
      includeDeleted: true,
      includeDraft: true,
    );
    final payments = await db.listPaymentRecords(includeDeleted: true);

    final problems = <String>[];
    if (data.companies.length != companies.length) {
      problems.add('公司 ${data.companies.length}≠${companies.length}');
    }
    if (data.pricingRules.length != rules.length) {
      problems.add('规则 ${data.pricingRules.length}≠${rules.length}');
    }
    if (data.workRecords.length != works.length) {
      problems.add('工作记录 ${data.workRecords.length}≠${works.length}');
    }
    if (data.paymentRecords.length != payments.length) {
      problems.add('收款 ${data.paymentRecords.length}≠${payments.length}');
    }
    if (problems.isNotEmpty) {
      throw StateError('导出全量断言失败（可能误用默认参数）：${problems.join('；')}');
    }
  }

  Future<void> _exportJson() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final data = await _buildBackupData();
      await _assertFullExportCounts(data);

      final export = const ExportService();
      final now = DateTime.now();
      final jsonStr =
          export.toJson(data, exportedAt: now, appVersion: _appVersion);

      // A5（AC-61）：导出文件有效记录/收款合计 == App 内应收/已收合计（定点精确相等）。
      final consistent = export.assertExportConsistency(
        workRecords: data.workRecords,
        paymentRecords: data.paymentRecords,
        exportedJson:
            export.toMap(data, exportedAt: now, appVersion: _appVersion),
      );
      if (!consistent) {
        _snack('导出校验未通过（金额合计与 App 不一致），已中止，未产生文件');
        return; // 失败 → **不更新**「上次备份时间」
      }

      final dir = await getApplicationDocumentsDirectory();
      final name = 'worklog-backup-${_stamp(now)}.json';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsString(jsonStr, encoding: utf8);

      await Share.shareXFiles([XFile(file.path)], text: '工时记账备份 $name');

      if (!mounted) return;
      setState(() => _lastBackupAt = now); // 会话内存态（G-07 未落地）
      _snack('备份完成，建议存到微信/网盘');
    } catch (e) {
      _snack('保存失败，请检查存储权限：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportCsv() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final db = AppDatabase.instance;
      final ledgerId = AppState.ledgerId;
      final companies = await db.listCompanies(
        ledgerId: ledgerId,
        includeDeleted: true,
        includeDisabled: true,
      );
      final rules = await db.listPricingRules(
        includeDeleted: true,
        includeDisabled: true,
      );
      // CSV 与 JSON 同源取全量（含软删/草稿）——守「导出即全量」一致口径（设计 §11 偏差 3）。
      final works = await db.listWorkRecords(
        includeDeleted: true,
        includeDraft: true,
      );
      final payments = await db.listPaymentRecords(includeDeleted: true);

      final companyNames = {for (final c in companies) c.id: c.name};
      final ruleNames = {for (final r in rules) r.id: r.name};

      final export = const ExportService();
      final workCsv = export.workRecordsCsv(works, companyNames, ruleNames);
      final payCsv = export.paymentRecordsCsv(payments, companyNames);

      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final stamp = _stamp(now);
      final wf = File('${dir.path}${Platform.pathSeparator}worklog-records-$stamp.csv');
      final pf = File('${dir.path}${Platform.pathSeparator}worklog-payments-$stamp.csv');
      await wf.writeAsString(workCsv, encoding: utf8);
      await pf.writeAsString(payCsv, encoding: utf8);

      await Share.shareXFiles(
        [XFile(wf.path), XFile(pf.path)],
        text: '工时记账明细（CSV 只能看，不能用来恢复）',
      );
      _snack('已导出 2 个 CSV 文件');
    } catch (e) {
      _snack('保存失败，请检查存储权限：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ───────────────────────── 导入：破坏性操作，逐步确认 ─────────────────────────

  Future<void> _startImport() async {
    if (_busy) return;
    // MIN-3：整段「选文件 → 校验 → 策略 → 确认 → 事务」期间持 `_busy`，
    // 防并发触发第二次导入/导出（与 `_exportJson` / `_exportCsv` 同款）。
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null) return; // 用户取消
      final path = picked.files.single.path;
      if (path == null) {
        _snack('无法读取所选文件');
        return;
      }
      if (!path.toLowerCase().endsWith('.json')) {
        _snack('CSV 只能看，不能用来恢复');
        return;
      }
      final content = await File(path).readAsString();
      final dynamic decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        _snack('这个文件不是备份文件');
        return;
      }
      await _runImport(decoded);
    } on FormatException {
      _snack('这个文件不是备份文件');
    } catch (e) {
      _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runImport(Map<String, dynamic> map) async {
    final imp = const ImportService();

    // ① 结构 + 字段 + 值域校验：有错误 → 全屏错误页，**绝不部分导入**（AC-64）。
    final errors = imp.validate(map);
    if (errors.isNotEmpty) {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _ImportErrorPage(errors: errors),
        ),
      );
      return;
    }

    final data = imp.parse(map);
    final warnings = imp.softWarnings(data);

    // ② 预览 + 软警告 + 冲突策略三选（默认覆盖）。
    final strategy = await _showStrategyDialog(
      data: data,
      exportedAt: map['exported_at'],
      appVersion: map['app_version'],
      warnings: warnings,
    );
    if (strategy == null) return; // 用户取消

    // ③ 冲突规划：`localIds` 取**六表全量 id 并集且 includeDeleted: true**（`07:678`）。
    final localIds = await _collectLocalIds();
    final incomingIds = _collectIncomingIds(data);
    final plan = imp.planImport(
      localIds: localIds,
      incomingIds: incomingIds,
      strategy: strategy,
      warnings: warnings,
    );
    if (plan.abort) {
      if (!mounted) return;
      await _showConflictDialog(plan.conflicts, aborted: true);
      return;
    }
    if (plan.conflicts.isNotEmpty) {
      if (!mounted) return;
      await _showConflictDialog(plan.conflicts, aborted: false);
    }

    // ④ 覆盖策略 → 先自动导出当前数据一份（文件名带时间戳）。
    //    **MAJ-2 / R56**：自动备份是「覆盖」唯一 undo 通道；失败**必须在破坏性写入前中止**
    //    （旧实现吞掉失败仍继续 + 确认文案谎称已备份 → 安全网缺失 + 误导）。
    var backedUp = false;
    if (strategy == ImportStrategy.overwrite) {
      backedUp = await _autoBackupBeforeOverwrite();
      if (!backedUp) {
        _snack('自动备份当前数据失败，已中止导入（本机数据未改动）');
        return; // 未确认、未写入
      }
    }

    // ④.5 导入前快照（供导入后不变量校验；R55）。
    final preSnap = await _snapshot();

    // ⑤ 二次确认（文案与「是否已自动备份」一致；MAJ-2）。
    final go = await _confirmImport(backedUp: backedUp);
    if (go != true) return;

    // ⑥ 事务内批量 upsert（全成或全回滚）+ 导入后断言。
    await _doImportTransaction(data, strategy, localIds, preSnap);
  }

  /// 读取本机**导入前/后快照**（五张实体表 + 六表 id 并集），供 [ImportService.verifyImportInvariants]。
  ///
  /// 口径与 `_buildBackupData` 对齐：公司按 `ledgerId` 过滤、规则/工作/收款全量、节假日全量
  /// （不按账本过滤——跨账本备份导入不该被本断言误报，属既有口径）。工作/收款走**容错读**
  /// （坏行跳过并计数），与 `_collectLocalIds` 一致。
  Future<ImportSnapshot> _snapshot() async {
    final db = AppDatabase.instance;
    final ledgerId = AppState.ledgerId;
    final companies = await db.listCompanies(
      ledgerId: ledgerId,
      includeDeleted: true,
      includeDisabled: true,
    );
    final rules = await db.listPricingRules(
      includeDeleted: true,
      includeDisabled: true,
    );
    final works = await db.listWorkRecordsLenient(
      includeDeleted: true,
      includeDraft: true,
    );
    final pays = await db.listPaymentRecordsLenient(includeDeleted: true);
    final holidays = await db.listHolidayMarks();
    return _snapshotFromLists(
      ledgerId: ledgerId,
      companies: companies,
      pricingRules: rules,
      workRecords: works.rows,
      paymentRecords: pays.rows,
      holidayMarks: holidays,
    );
  }

  ImportSnapshot _snapshotFromLists({
    required String? ledgerId,
    required List<Company> companies,
    required List<PricingRule> pricingRules,
    required List<WorkRecord> workRecords,
    required List<PaymentRecord> paymentRecords,
    required List<HolidayMark> holidayMarks,
  }) {
    final ids = <String>{
      if (ledgerId != null) ledgerId,
      ...companies.map((e) => e.id),
      ...pricingRules.map((e) => e.id),
      ...workRecords.map((e) => e.id),
      ...paymentRecords.map((e) => e.id),
      ...holidayMarks.map((e) => e.id),
    };
    return ImportSnapshot(
      companies: companies,
      pricingRules: pricingRules,
      workRecords: workRecords,
      paymentRecords: paymentRecords,
      holidayMarks: holidayMarks,
      ids: ids,
    );
  }

  Future<Set<String>> _collectLocalIds() async {
    final db = AppDatabase.instance;
    final ledgerId = AppState.ledgerId;
    final ids = <String>{};
    if (ledgerId != null) ids.add(ledgerId);
    for (final c in await db.listCompanies(
      ledgerId: ledgerId,
      includeDeleted: true,
      includeDisabled: true,
    )) {
      ids.add(c.id);
    }
    for (final r in await db.listPricingRules(
      includeDeleted: true,
      includeDisabled: true,
    )) {
      ids.add(r.id);
    }
    final w = await db.listWorkRecordsLenient(
      includeDeleted: true,
      includeDraft: true,
    );
    for (final e in w.rows) {
      ids.add(e.id);
    }
    for (final s in w.skipped) {
      if (s.id != null) ids.add(s.id!); // 坏行尽力取 id，防冲突集算漏
    }
    final p = await db.listPaymentRecordsLenient(includeDeleted: true);
    for (final e in p.rows) {
      ids.add(e.id);
    }
    for (final s in p.skipped) {
      if (s.id != null) ids.add(s.id!);
    }
    for (final h in await db.listHolidayMarks(ledgerId: ledgerId)) {
      ids.add(h.id);
    }
    return ids;
  }

  static Set<String> _collectIncomingIds(BackupData data) => {
        data.ledger.id,
        ...data.companies.map((e) => e.id),
        ...data.pricingRules.map((e) => e.id),
        ...data.workRecords.map((e) => e.id),
        ...data.paymentRecords.map((e) => e.id),
        ...data.holidayMarks.map((e) => e.id),
      };

  /// 覆盖前自动备份当前数据（**「覆盖」策略唯一 undo 通道**）。
  ///
  /// **返回是否成功**——**MAJ-2 / R56**：失败必须由调用方**中止导入**（不再吞掉失败继续写入）。
  Future<bool> _autoBackupBeforeOverwrite() async {
    try {
      final data = await _buildBackupData();
      final now = DateTime.now();
      final jsonStr = const ExportService()
          .toJson(data, exportedAt: now, appVersion: _appVersion);
      final dir = await getApplicationDocumentsDirectory();
      final name = 'worklog-auto-backup-${_stamp(now)}.json';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsString(jsonStr, encoding: utf8);
      _snack('已自动备份当前数据：$name');
      return true;
    } catch (e) {
      _snack('自动备份当前数据失败：$e');
      return false;
    }
  }

  Future<void> _doImportTransaction(
    BackupData data,
    ImportStrategy strategy,
    Set<String> localIds,
    ImportSnapshot preSnap,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final db = AppDatabase.instance;
      final ledgerId = AppState.ledgerId;
      var imported = 0;
      await db.transaction((txn) async {
        // 事务内**必须**用 `...On(txn, …)`（`database.dart:248-266`），否则死锁。
        await db.upsertLedgerOn(txn, data.ledger);
        imported++;

        for (final c in data.companies) {
          if (strategy == ImportStrategy.merge && localIds.contains(c.id)) {
            continue;
          }
          await db.upsertCompanyOn(txn, c);
          imported++;
        }
        for (final r in data.pricingRules) {
          if (strategy == ImportStrategy.merge && localIds.contains(r.id)) {
            continue;
          }
          await db.upsertPricingRuleOn(txn, r);
          imported++;
        }
        for (final w in data.workRecords) {
          if (strategy == ImportStrategy.merge && localIds.contains(w.id)) {
            continue;
          }
          await db.upsertWorkRecordOn(txn, w);
          imported++;
        }
        for (final p in data.paymentRecords) {
          if (strategy == ImportStrategy.merge && localIds.contains(p.id)) {
            continue;
          }
          await db.upsertPaymentRecordOn(txn, p);
          imported++;
        }
        for (final h in data.holidayMarks) {
          if (strategy == ImportStrategy.merge && localIds.contains(h.id)) {
            continue;
          }
          await db.upsertHolidayMarkOn(txn, h);
          imported++;
        }

        // 导入后**不变量校验**（事务内 → 失败即回滚，不留半成品）。
        // R55：断言口径**按策略分派**（`overwrite` 全量比对；`merge` 走 (A)(B)(C)），
        //      由 `ImportService.verifyImportInvariants` 统一实现（UI 与脚本**共用同一函数**）。
        // R57：校验覆盖 公司/规则/工作记录/收款/节假日**五表**（旧断言仅 work+payment）。
        final postSnap = _snapshotFromLists(
          ledgerId: ledgerId,
          companies: await db.listCompaniesOn(
            txn,
            ledgerId: ledgerId,
            includeDeleted: true,
            includeDisabled: true,
          ),
          pricingRules: await db.listPricingRulesOn(
            txn,
            includeDeleted: true,
            includeDisabled: true,
          ),
          workRecords: (await db.listWorkRecordsLenientOn(
            txn,
            includeDeleted: true,
            includeDraft: true,
          ))
              .rows,
          paymentRecords: (await db.listPaymentRecordsLenientOn(
            txn,
            includeDeleted: true,
          ))
              .rows,
          holidayMarks: await db.listHolidayMarksOn(txn),
        );
        final newIds = _collectIncomingIds(data).difference(localIds)
          ..remove(data.ledger.id);
        final verdict = const ImportService().verifyImportInvariants(
          strategy: strategy,
          pre: preSnap,
          post: postSnap,
          data: data,
          newIds: newIds,
        );
        if (!verdict.ok) {
          throw StateError('导入后断言失败：${verdict.all.take(5).join('；')}');
        }
      });

      dataBus.dataChanged();
      _snack('导入完成，已导入 $imported 条记录');
    } catch (e) {
      _snack('导入失败，已回滚：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // 注：旧私有方法 `_assertImportResult`（仅比 work+payment 且对 merge 误判 → 整体回滚）
  // 已**删除**，其职责迁至 `ImportService.verifyImportInvariants`（R55/R57）——
  // 断言口径**按策略分派**，且 UI 与测试脚本**共用同一函数**（避免同构复刻）。

  // ───────────────────────── 对话框 ─────────────────────────

  Future<ImportStrategy?> _showStrategyDialog({
    required BackupData data,
    required Object? exportedAt,
    required Object? appVersion,
    required List<String> warnings,
  }) {
    return showDialog<ImportStrategy>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportStrategyDialog(
        data: data,
        exportedAt: exportedAt,
        appVersion: appVersion,
        warnings: warnings,
      ),
    );
  }

  Future<void> _showConflictDialog(List<String> conflicts,
      {required bool aborted}) async {
    if (!mounted) return;
    final shown = conflicts.take(10).map((e) => '· $e').join('\n');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(aborted ? '发现重复记录，已中止' : '发现重复记录'),
        content: SingleChildScrollView(
          child: Text(
            aborted
                ? '发现 ${conflicts.length} 条重复记录，已按「拒绝」策略中止。\n\n$shown'
                    '${conflicts.length > 10 ? '\n…共 ${conflicts.length} 条' : ''}'
                : '有 ${conflicts.length} 条重复，将按所选策略处理。\n\n$shown'
                    '${conflicts.length > 10 ? '\n…共 ${conflicts.length} 条' : ''}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }

  /// 二次确认。`backedUp` = 「覆盖」策略下自动备份**是否已成功**（MAJ-2 / R56）——
  /// 文案须与事实一致：只有真备份成功才可声称"已自动备份"。
  Future<bool?> _confirmImport({required bool backedUp}) {
    if (!mounted) return Future<bool?>.value(null);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入将改变本机账目'),
        content: Text(backedUp
            ? '导入会覆盖本机的同一条记录（若选「覆盖」），操作前已自动备份当前数据。是否继续？'
            : '将按「合并/拒绝」策略导入，本机已有记录不会被改动，因此未做自动备份。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续导入'),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导出备份')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 上次备份时间（大字）
            Text('上次备份', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              _lastBackupAt == null ? '从未备份' : '刚刚备份',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: _lastBackupAt == null ? theme.colorScheme.error : null,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),

            // 坏行黄色提示（AC-P13-11）：导出走严格全量读，遇坏行 Fail-loud 中止
            //（不会"原样导出"）——文案须与实现一致（MAJ-3 / R52）。
            if (_badRowCount > 0)
              _warnBar('备份包含 $_badRowCount 条异常数据，导出将被中止，请先处理异常行'),
            const SizedBox(height: 8),

            FilledButton.icon(
              onPressed: _busy ? null : _exportJson,
              icon: const Icon(Icons.save_alt),
              label: const Text('导出全量备份（JSON）'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _exportCsv,
              icon: const Icon(Icons.table_chart_outlined),
              label: const Text('导出明细（CSV）'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _startImport,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              icon: const Icon(Icons.restore),
              label: const Text('导入恢复'),
            ),
            const SizedBox(height: 24),

            Text(
              'JSON = 完整备份，可用来恢复；CSV = 表格明细，只能看、不能用来恢复',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('恢复会覆盖本机数据，操作前会自动备份一份当前数据'),
            ),
          ],
        ),
        if (_busy)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Widget _warnBar(String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Color(0xFF8A6D3B), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: Color(0xFF8A6D3B))),
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// `yyyyMMdd-HHmmss`（文件名时间戳；全整数、无浮点）。
  static String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}${two(d.month)}${two(d.day)}'
        '-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }
}

// ───────────────────────── 错误页 / 策略弹层 ─────────────────────────

/// 导入错误全屏页（`07:666` / AC-P13-05）：**绝不部分导入**。
class _ImportErrorPage extends StatelessWidget {
  const _ImportErrorPage({required this.errors});

  final List<String> errors;

  @override
  Widget build(BuildContext context) {
    final tooNew = errors.any(
      (e) => e.contains('schema_version') && e.contains('升级'),
    );
    final shown = errors.take(10).map((e) => '· $e').join('\n');
    return Scaffold(
      appBar: AppBar(title: const Text('备份文件有问题')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '未导入任何数据',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (tooNew)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('备份文件来自更新版本，请先升级 App',
                    style: TextStyle(color: Color(0xFF8A6D3B))),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  '$shown\n\n共 ${errors.length} 条',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 预览 + 软警告 + 冲突策略三选（默认覆盖）。
class _ImportStrategyDialog extends StatefulWidget {
  const _ImportStrategyDialog({
    required this.data,
    required this.exportedAt,
    required this.appVersion,
    required this.warnings,
  });

  final BackupData data;
  final Object? exportedAt;
  final Object? appVersion;
  final List<String> warnings;

  @override
  State<_ImportStrategyDialog> createState() => _ImportStrategyDialogState();
}

class _ImportStrategyDialogState extends State<_ImportStrategyDialog> {
  ImportStrategy _selected = ImportStrategy.overwrite;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('确认导入'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('导出于 ${widget.exportedAt ?? '未知'}', style: theme.textTheme.bodySmall),
            Text('App 版本 ${widget.appVersion ?? '未知'}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              '账本 1 条 · 公司 ${d.companies.length} · 规则 ${d.pricingRules.length} · '
              '工作记录 ${d.workRecords.length} · 收款 ${d.paymentRecords.length} · '
              '节假日 ${d.holidayMarks.length}',
              style: theme.textTheme.bodyMedium,
            ),
            if (widget.warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.warnings.map((w) => '· $w').join('\n'),
                  style: const TextStyle(color: Color(0xFF8A6D3B)),
                ),
              ),
            ],
            const SizedBox(height: 12),
            RadioListTile<ImportStrategy>(
              value: ImportStrategy.overwrite,
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v!),
              contentPadding: EdgeInsets.zero,
              title: const Text('覆盖（推荐）'),
              subtitle: const Text('用备份文件里的版本覆盖本机同一条记录；操作前自动把当前数据备份一份'),
            ),
            RadioListTile<ImportStrategy>(
              value: ImportStrategy.merge,
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v!),
              contentPadding: EdgeInsets.zero,
              title: const Text('合并'),
              subtitle: const Text('本机已有的不动，只导入本机没有的'),
            ),
            RadioListTile<ImportStrategy>(
              value: ImportStrategy.reject,
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v!),
              contentPadding: EdgeInsets.zero,
              title: const Text('拒绝'),
              subtitle: const Text('只要发现重复就中止，先给我看看清单（最安全）'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('开始导入'),
        ),
      ],
    );
  }
}

/// 加载失败错误态（`07 §1.6`：错误态 + 重试按钮，不白屏）。
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
            Text('$error', textAlign: TextAlign.center),
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
