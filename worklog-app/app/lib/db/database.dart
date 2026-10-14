/// SQLite 数据访问层（唯一存储入口）
/// 对应 03 §2（字段）、§3（键与关系）、§5（剩余工资口径）、§7.1（日历聚合）、§8（约束清单）。
///
/// 设计纪律（本文件全部方法都必须遵守）：
///  1. **定点小数**：金额列一律 int「分」，倍率列一律 int「×10」，全程无浮点中间值（03 §4.6）。
///     本层不做任何金额运算，只做存取与 SUM 聚合（SQLite 整数加法精确，无舍入问题）。
///  2. **快照不可变**（底线 2 / §3.3 / §8#4）：work_record 的 `*_snapshot` 字段落库即固化。
///     本层 **不提供**「按 pricing_rule 现值重算金额」的任何路径。工作记录的更新已**拆签名**
///     （I-8 / G-11）：[updateWorkRecordMeta] 只改非金额 Meta（SQL 语句不含快照列 + 运行期断言兜底），
///     [replaceWorkRecordSnapshot] 才**显式**覆盖快照（调用点须二次确认）；[updatePricingRule]
///     不触碰 work_record。改价只影响新记录。
///  3. **剩余工资唯一口径**（§5.1）：剩余 = 应收 − 已收
///       应收 = Σ work_record.amount_snapshot WHERE status ∈ {confirmed, settled} AND deleted_at IS NULL
///       已收 = Σ payment_record.amount          WHERE deleted_at IS NULL
///     由 [AppDatabase.aggregate] 实现，与 services/receivable_service.dart 的纯函数口径
///     逐条件对齐（草稿不计入 / 软删不计入 / 公司维度过滤）。派生值不落库（设计底线 1）。
///  4. **软删**（Q13 / §8#3）：删除一律写 `deleted_at`；业务读路径默认过滤 `deleted_at IS NULL`，
///     导出/备份需带软删时传 `includeDeleted: true`（§6.2 备份含软删）。
///  5. **事务上下文（C-01 修复，2026-09-30）**：本层的每个读写操作都有两套签名——
///     - **公开方法**（如 [upsertCompany]）：自行取 `_db`，**只可在事务外调用**；
///     - **显式 executor 方法**（如 [upsertCompanyOn]）：接收 [DatabaseExecutor]，
///       **事务内必须用它**并把 `txn` 传进去。
///     ⚠️ 事务内直接调公开方法 → 对同一数据库句柄重入事务 → **死锁**（契约见 [transaction]）。
///  6. **可移植性纪律（2026-09-30 修复）**：本文件只依赖 `package:sqflite_common`（纯 Dart，
///     不含 Flutter），**不**依赖 `package:sqflite`。原因：`package:sqflite` 经
///     `package:flutter/foundation.dart` 传递依赖 `dart:ui`，而 `dart:ui` 在纯 Dart VM 下
///     不可用（实测：`Error: Dart library 'dart:ui' is not available on this platform`），
///     会导致本层无法用纯 Dart 做运行时验证。改用 sqflite_common 后，本层可在纯 Dart 下
///     配 `sqflite_common_ffi` 内存库跑通（见 tool/verify_db.dart）。
///     默认 factory 取自 sqflite_common 的全局 `databaseFactory`：Flutter 端由 `package:sqflite`
///     插件注册自动注入（或 main() 显式 `databaseFactory = databaseFactorySqflitePlugin;`）；
///     测试端用 [configureForTest]`(factory: databaseFactoryFfi, path: inMemoryDatabasePath)` 覆盖。
///  7. **兜底方向纪律（M-03；R2-02 收敛；R2-04/B3 行映射硬化；G-03 聚合硬化；M-01 类型前置守卫）**：
///     **口径相关字段不做会「虚增剩余工资」的静默兜底**：
///     - **`status`**：无法识别 → 兜底 `draft`（草稿不计入应收，只少算不多算）——**已硬化**。
///     - **金额列 · 行映射路径**（`_workRecordFromRow` / `_paymentFromRow`）经 [_asAmountColumn]：
///       **非 `num` 类型抛错**；**REAL 非整/非法值（`24000.7` / NaN / Inf）也抛错**（R2-04 硬化，
///       拒绝静默截断）；仅「无损可转 int 的 `num`」放行。→ **该路径已完全硬化**。
///     - **金额列 · 聚合路径**（[_sumInt] 与 `aggregateByCompanyOn`）**双层守卫**：
///       ① **SQL 侧类型前置守卫** [_assertAggregateColumnTypes]（**M-01 修复，2026-10-01**）：
///          `typeof(col) NOT IN ('integer','real')` 命中即抛——**必需**，因 SQLite `SUM()` 会把
///          TEXT/BLOB **洗成 `0.0`（REAL）**，纯 Dart 侧永远看不见「非 num」，该守卫是**唯一**能拦住
///          「TEXT/BLOB 被静默按 0 计入」的点；
///       ② **Dart 侧数值解析** [_asAggregateInt]（**G-03 硬化，2026-09-30**）：REAL 非整/非法值抛
///          [FormatException]（对 `SUM` 结果防御性兜底）。
///       → **该路径已硬化**（R2-02 所记「聚合路径静默兜底 0」的残留已由 G-03 + M-01 闭合）。
///     详见 [_recordStatus] / [_asAmountColumn] / [_asInt] / [_asAggregateInt] / [_assertAggregateColumnTypes] 的各自 doc。
///
/// 字段命名纪律（易错点，务必区分）：
///  本项目存在**两套字段名**，本层写的是**表列名**（database_schema.dart）：
///    - 表列名：`nickname` → `name`、`base_unit_price` → `base_rate`、`unit_price_snapshot` → `rate_snapshot`、
///      `rate_*_rate` → `rate_rate_*`、`method` → `mode_snapshot`、`pay_date` → `paymentDate`；
///    - 备份 JSON 键名（export_service.dart）**不是**表列名，不可照抄。
///  映射集中在 §「私有转换」区块，改列名只需改一处。
library;

import 'package:sqflite_common/sqflite.dart';

import '../models/ledger.dart';
import '../models/company.dart';
import '../models/pricing_rule.dart';
import '../models/work_record.dart';
import '../models/payment_record.dart';
import '../models/holiday_mark.dart';
import '../models/types.dart';
import 'database_schema.dart';

/// 剩余工资汇总（分）。与 services/receivable_service.dart 的 ReceivableSummary 同口径。
///
/// 派生值，**不落库**（设计底线 1）；五处显示必须走同一查询路径（AC-33，导出文件亦算一处，见 02-PRD.md:538）。
class ReceivableAggregate {
  /// 公司维度；null = 全局合计（不分公司）。
  final String? companyId;

  /// 应收（分）= Σ 已确认/已结算且未软删的 work_record.amount_snapshot。
  final int receivable;

  /// 已收（分）= Σ 未软删的 payment_record.amount。
  final int received;

  /// 剩余（分）= 应收 − 已收（可为负：多收）。
  final int remaining;

  const ReceivableAggregate({
    this.companyId,
    required this.receivable,
    required this.received,
    required this.remaining,
  });
}

/// 被跳过的坏行（G-02 脏行隔离，2026-09-30）。
///
/// 仅承载「哪一行、为什么坏」，供上层展示 / 上报 / 引导导出备份；
/// **不参与任何口径运算**（坏行金额不可信，绝不静默按 0 计入）。
class SkippedRow {
  /// 该行 `id` 列（能读出时用于定位；行损坏到连 id 都读不出则为 null）。
  final String? id;

  /// 解析该行时抛出的异常（[FormatException] / `TypeError` 等）。
  final Object error;

  const SkippedRow({this.id, required this.error});

  @override
  String toString() =>
      'SkippedRow(id=${id ?? '(unreadable)'}, ${error.runtimeType}: $error)';
}

/// 容错读结果（G-02 脏行隔离，2026-09-30）：**健康行 + 被跳过的坏行清单**。
///
/// 语义：整表读取时**逐行隔离**——某行解析失败**不**冒泡致整表失败，
/// 而是跳过该行并记录到 [skipped]，其余健康行照常返回。
/// - 用于「列表容错 / 导入后校验」等**可容忍部分坏行**的场景（I-9 / E-11）。
/// - **默认（严格）读法不变**：`listWorkRecords` / `listPaymentRecords` 仍整表抛错，
///   保住「宁可失败，不可静默少行（或算错钱）」的默认契约；只有调用方**显式**选择
///   `*Lenient` 入口才进入容忍模式。
/// - ⚠️ 容忍模式的**口径风险已上抛给调用方**：跳过坏行 = 该行金额未计入，
///   调用方**必须**处理 [skipped]（提示 / 阻断聚合 / 引导修复），不得当无事发生。
class LenientRead<T> {
  /// 成功解析的健康行（顺序与查询一致）。
  final List<T> rows;

  /// 解析失败被跳过的坏行（不上抛；每项含 id 与异常）。
  final List<SkippedRow> skipped;

  const LenientRead({required this.rows, required this.skipped});

  /// 坏行条数（= [skipped].length，便于日志/断言）。
  int get skippedCount => skipped.length;

  /// 是否存在被跳过的坏行（调用方据此决定是否告警 / 阻断）。
  bool get hasSkipped => skipped.isNotEmpty;

  @override
  String toString() =>
      'LenientRead(rows=${rows.length}, skipped=$skippedCount)';
}

/// 数据库门面：开库 / 六表 CRUD / 剩余工资聚合 / 事务。
///
/// 每个读写方法都有「事务外」公开版与「事务内」`...On(DatabaseExecutor, ...)` 版，
/// 事务契约见类头纪律 5 与 [transaction]。
class AppDatabase {
  AppDatabase._();

  /// 懒加载单例（`open()` 自身并发安全，见 [open]）。
  static final AppDatabase instance = AppDatabase._();

  /// 默认库文件名。生产走 `getDatabasesPath()`，测试建议用 `inMemoryDatabasePath`。
  static const String _dbName = 'worklog.db';

  /// 测试可注入的 factory（如 `databaseFactoryFfi`）。为空时用 sqflite_common 的全局 `databaseFactory`。
  DatabaseFactory? _factoryOverride;

  /// 测试可注入的库路径（如 `inMemoryDatabasePath`）。为空时用 `getDatabasesPath()/_dbName`。
  String? _pathOverride;

  Database? _db;

  /// 已打开的原生数据库句柄（未 open 时为 null）。
  /// 事务内由 sqflite 传入的 [Transaction] 使用 `txn.rawQuery/txn.rawUpdate`，
  /// 并通过对应的 `...On(txn, ...)` 方法访问，无需读取本字段。
  Database? get db => _db;

  /// 仅供测试：覆盖 factory 与库路径（须在 [open] 之前调用）。
  /// 传 `path: inMemoryDatabasePath` 可跑纯内存库测试，不落盘。
  ///
  /// 纯 Dart 下典型用法：
  /// ```dart
  /// sqfliteFfiInit();
  /// AppDatabase.instance.configureForTest(
  ///   factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  /// ```
  void configureForTest({DatabaseFactory? factory, String? path}) {
    if (_db != null) {
      throw StateError('数据库已打开，configureForTest 须在 open() 之前调用');
    }
    _factoryOverride = factory;
    _pathOverride = path;
  }

  /// 打开（或复用）数据库。并发调用安全：sqflite 的 `openDatabase` 内部按路径去重
  /// （singleInstance 默认开启），并发 `open()` 得到同一实例。
  ///
  /// - `version: kDbVersion`，`onCreate` 直接复用 [kCreateTableStatements] 与
  ///   [kCreateIndexStatements]（不重写建表 SQL，避免两处 schema 漂移）。
  /// - 开启外键约束（本设计不建物理外键，属前瞻无操作，无副作用）。
  ///
  /// 默认 factory 说明：本层不再 import `package:sqflite`（见类头纪律 6），
  /// 因此 Flutter 端需保证全局 `databaseFactory` 已被 sqflite 插件注册注入；
  /// 未注入时 sqflite_common 会抛出带指引的 `StateError`。
  Future<Database> open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;

    final factory = _factoryOverride ?? databaseFactory;
    final path = _pathOverride ?? '${await factory.getDatabasesPath()}/$_dbName';

    final opened = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kDbVersion,
        onConfigure: (db) async {
          // 本设计不建物理外键（§3.1 全部为弱引用/软引用），开启仅为前瞻约束。
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          for (final sql in kCreateTableStatements) {
            await db.execute(sql);
          }
          for (final sql in kCreateIndexStatements) {
            await db.execute(sql);
          }
        },
        // 迁移登记处：kDbVersion 升版时，在 database_schema.dart 加 _migrations 并在此分发。
        // 基础版 kDbVersion == 1，无迁移分支。
        onUpgrade: (db, oldVersion, newVersion) async {},
      ),
    );
    _db = opened;
    return opened;
  }

  /// 关闭数据库（**幂等**）。关闭后**可以再次 [open]**（M-02 修复：注释与实现一致）。
  ///
  /// **可重开依据（已核源，非猜测）**：sqflite 的
  /// `SqfliteDatabaseFactoryMixin.closeDatabase()` 在数据库以 singleInstance（默认）
  /// 打开时，会执行 `removeDatabaseOpenHelper(path)` —— 即关闭时**主动清除按路径的
  /// 打开缓存**。因此随后 `openDatabase(path)` 会新建句柄，不会复用已关闭的旧句柄。
  /// （源：sqflite_common-2.5.13 lib/src/factory_mixin.dart `closeDatabase`）
  ///
  /// **时序说明**：先清 `_db` 引用、再 `await close()`。这样关闭期间并发进来的 [open]
  /// 不会拿到「即将关闭」的旧句柄；而 sqflite 对同一路径的 open/close 有命名锁串行化，
  /// 并发的 open 会等待本次 close 完成后再建新句柄。若已关闭则直接返回（幂等）。
  Future<void> close() async {
    final existing = _db;
    if (existing == null) return;
    _db = null;
    if (existing.isOpen) {
      await existing.close();
    }
  }

  /// 事务封装：全成或全回滚（§8#13 导入事务性）。
  /// 导入时必须用事务包裹 §6.4 的批量写入 + id 冲突处理 + 导入后断言。
  ///
  /// ⚠️ **回调内必须使用 `...On(txn, ...)` 版本方法（读、写皆然）**：
  /// ```dart
  /// await db.transaction((txn) async {
  ///   await db.upsertCompanyOn(txn, c);      // ✅ 用传入的 txn
  ///   final agg = await db.aggregateOn(txn, c.id); // ✅ 读也要用 txn，否则读不到未提交数据
  /// });
  /// ```
  /// ```dart
  /// await db.transaction((txn) async {
  ///   await db.upsertCompany(c);             // ❌ 会死锁：见下
  /// });
  /// ```
  /// 原因：公开方法内部走 `_db`（与 `txn` 同一条底层连接）。在事务未结束时，
  /// `_db` 上的写操作会**重新申请一个事务**并排队等待当前事务让出连接，
  /// 而当前事务正等待该操作完成 → 双向等待，**永久死锁**（sqflite 不支持同连接重入事务）。
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    final db = _db ?? await open();
    return db.transaction<T>(action);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // 剩余工资聚合（关键：与 receivable_service.dart 口径逐条对齐）
  // ═══════════════════════════════════════════════════════════════════════

  /// 剩余工资汇总（分）。SQL 聚合，不拉全量到内存。
  Future<ReceivableAggregate> aggregate(String? companyId) async =>
      aggregateOn(_db ?? await open(), companyId);

  /// [aggregate] 的显式 executor 版本：**事务内必须用它**（见 [transaction]），
  /// 否则读不到本事务尚未提交的写入。
  ///
  /// 与 `services/receivable_service.dart` 的可证等价关系（逐条对照）：
  ///
  /// | receivable_service 纯函数                    | 本方法 SQL 条件                                                        |
  /// |---------------------------------------------|-----------------------------------------------------------------------|
  /// | `receivable(records)`                        | `SUM(amount_snapshot) FROM work_record`                                |
  /// | `for (final r in records) { if (r.isDeleted) continue; }`      | `WHERE deleted_at IS NULL`                          |
  /// | `if (!r.countsTowardReceivable) continue;`（`status != draft`）| `AND status IN ('confirmed','settled')`              |
  /// | `sum += r.amountSnapshot;`                   | 同上 SUM 的列 `amount_snapshot`                                        |
  /// | `records.where((r) => r.companyId == companyId)` | `AND company_id = ?`（companyId == null 时不加，返回全局）          |
  /// | `received(payments)`                         | `SUM(amount) FROM payment_record`                                      |
  /// | `if (p.isDeleted) continue;`                 | `WHERE deleted_at IS NULL`                                            |
  /// | `sum += p.amount;`                           | 同上 SUM 的列 `amount`                                                 |
  /// | `remaining = receivable - received`          | Dart 侧同式相减（SQL 整数加法精确，无浮点误差）                        |
  ///
  /// 状态用 `confirmed/settled` 白名单等价于「非 draft」，与
  /// `RecordStatus` 枚举 + 列默认值 `'confirmed'` 对齐（database_schema.dart:94）。
  /// 刻意**不**用 `status <> 'draft'` 黑名单：白名单对未知脏状态更保守（不计入应收），
  /// 与「只有明确确认的才算应收」的语义一致。
  Future<ReceivableAggregate> aggregateOn(
    DatabaseExecutor executor,
    String? companyId,
  ) async {
    final receivable = await _sumInt(
      executor,
      'SELECT COALESCE(SUM(amount_snapshot), 0) AS total FROM work_record '
      "WHERE deleted_at IS NULL AND status IN ('confirmed','settled')",
      companyId == null ? null : 'company_id = ?',
      companyId == null ? const [] : [companyId],
      table: 'work_record',
      column: 'amount_snapshot',
    );

    final received = await _sumInt(
      executor,
      'SELECT COALESCE(SUM(amount), 0) AS total FROM payment_record WHERE deleted_at IS NULL',
      companyId == null ? null : 'company_id = ?',
      companyId == null ? const [] : [companyId],
      table: 'payment_record',
      column: 'amount',
    );

    return ReceivableAggregate(
      companyId: companyId,
      receivable: receivable,
      received: received,
      remaining: receivable - received,
    );
  }

  /// 按公司分组汇总（公司列表页一次查完，避免 N+1）。
  /// 返回值仅含**有数据**的公司（无工作记录也无收款的公司在列表中剩余恒为 0，不必出现）。
  ///
  /// 注意：只含**草稿**记录（或记录全被软删）的公司不会出现在结果里——调用方需按
  /// 「未出现的公司 = 全 0」补齐，不要误判为「公司不存在」。
  Future<List<ReceivableAggregate>> aggregateByCompany() async =>
      aggregateByCompanyOn(_db ?? await open());

  /// [aggregateByCompany] 的显式 executor 版本：**事务内必须用它**（见 [transaction]）。
  Future<List<ReceivableAggregate>> aggregateByCompanyOn(
    DatabaseExecutor executor,
  ) async {
    // 类型前置守卫（M-01 修复）：**一次性全局 COUNT**（非逐组），语义 = 「任一表任一行类型坏 → 拒绝出数」。
    // 与 [aggregateOn] 同标准；两表都要（`work_record.amount_snapshot` / `payment_record.amount`）。
    await _assertAggregateColumnTypes(executor, 'work_record', 'amount_snapshot');
    await _assertAggregateColumnTypes(executor, 'payment_record', 'amount');

    final rows = await executor.rawQuery('''
      SELECT company_id,
             COALESCE(SUM(receivable), 0) AS receivable,
             COALESCE(SUM(received), 0)   AS received
      FROM (
        SELECT company_id,
               SUM(amount_snapshot) AS receivable,
               0                    AS received
        FROM work_record
        WHERE deleted_at IS NULL AND status IN ('confirmed','settled')
        GROUP BY company_id
        UNION ALL
        SELECT company_id,
               0        AS receivable,
               SUM(amount) AS received
        FROM payment_record
        WHERE deleted_at IS NULL
        GROUP BY company_id
      )
      GROUP BY company_id
    ''');

    return rows.map((r) {
      // SUM 结果经 [_asAggregateInt]（G-03 硬化）：非 num / REAL 非整值一律抛错，
      // 不做会「改动金额」的静默兜底；公司 id 是 NOT NULL 文本列，走 [_asString]。
      final receivable =
          _asAggregateInt(r['receivable'], 'work_record.amount_snapshot');
      final received = _asAggregateInt(r['received'], 'payment_record.amount');
      return ReceivableAggregate(
        companyId: _asString(r['company_id']),
        receivable: receivable,
        received: received,
        remaining: receivable - received,
      );
    }).toList(growable: false);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Ledger（单账本；无软删、无 updated_at，见 database_schema.dart:20-28）
  // ═══════════════════════════════════════════════════════════════════════

  /// 插入账本（已存在同 id 则覆盖）。仅事务外可用；事务内用 [upsertLedgerOn]。
  Future<void> upsertLedger(Ledger x) async => upsertLedgerOn(_db ?? await open(), x);

  /// [upsertLedger] 的显式 executor 版本（事务内必须用它）。
  Future<void> upsertLedgerOn(DatabaseExecutor executor, Ledger x) =>
      _write(executor, 'ledger', _ledgerToRow(x));

  /// 取账本；不存在返回 null。仅事务外可用；事务内用 [getLedgerOn]。
  Future<Ledger?> getLedger(String id) async => getLedgerOn(_db ?? await open(), id);

  /// [getLedger] 的显式 executor 版本（事务内必须用它）。
  Future<Ledger?> getLedgerOn(DatabaseExecutor executor, String id) async {
    final rows = await executor
        .query('ledger', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _ledgerFromRow(rows.first);
  }

  /// 列账本（通常仅一条）。按 created_at 升序。仅事务外可用；事务内用 [listLedgersOn]。
  Future<List<Ledger>> listLedgers() async => listLedgersOn(_db ?? await open());

  /// [listLedgers] 的显式 executor 版本（事务内必须用它）。
  Future<List<Ledger>> listLedgersOn(DatabaseExecutor executor) async {
    final rows = await executor.query('ledger', orderBy: 'created_at ASC');
    return rows.map(_ledgerFromRow).toList(growable: false);
  }

  /// 更新账本（按 id 定位）。仅事务外可用；事务内用 [updateLedgerOn]。
  Future<void> updateLedger(Ledger x) async => updateLedgerOn(_db ?? await open(), x);

  /// [updateLedger] 的显式 executor 版本（事务内必须用它）。
  /// 账本主键为 id，按 `ConflictAlgorithm.replace` 写入即为覆盖式更新。
  Future<void> updateLedgerOn(DatabaseExecutor executor, Ledger x) =>
      _write(executor, 'ledger', _ledgerToRow(x));

  /// 账本无 `deleted_at` 列，不支持软删（单账本设计，§2.1）。
  /// 物理删除仅用于测试清理，故不对外暴露。

  // ═══════════════════════════════════════════════════════════════════════
  // Company
  // ═══════════════════════════════════════════════════════════════════════

  /// 插入公司（同 id 覆盖，幂等重放安全）。仅事务外可用；事务内用 [upsertCompanyOn]。
  Future<void> upsertCompany(Company x) async => upsertCompanyOn(_db ?? await open(), x);

  /// [upsertCompany] 的显式 executor 版本（事务内必须用它）。
  Future<void> upsertCompanyOn(DatabaseExecutor executor, Company x) =>
      _write(executor, 'company', _companyToRow(x));

  /// 取公司（**不过滤软删**：历史记录需能解析到已删公司，§8#11 软引用仍可解析）。
  /// 仅事务外可用；事务内用 [getCompanyOn]。
  Future<Company?> getCompany(String id) async => getCompanyOn(_db ?? await open(), id);

  /// [getCompany] 的显式 executor 版本（事务内必须用它）。
  Future<Company?> getCompanyOn(DatabaseExecutor executor, String id) async {
    final rows = await executor
        .query('company', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _companyFromRow(rows.first);
  }

  /// 列公司。`ledgerId` 过滤账本；`includeDeleted=true` 时含软删（备份导出用）。
  /// **默认排除软删与停用项**（新建/快记选择器口径，§8#11 / AC-19，与 [listPricingRules] 对称）：
  /// `includeDisabled` 默认 **false** → 只返回 `enabled = 1` 且未软删的公司；
  /// 历史展示 / 备份需含停用或软删公司时显式传 `includeDisabled: true` / `includeDeleted: true`。
  /// （R2-06 修复：原实现只滤 `deleted_at`，停用公司仍返回，与 `listPricingRules` 不对称，易误用。）
  /// 仅事务外可用；事务内用 [listCompaniesOn]。
  Future<List<Company>> listCompanies({
    String? ledgerId,
    bool includeDeleted = false,
    bool includeDisabled = false,
  }) async =>
      listCompaniesOn(
        _db ?? await open(),
        ledgerId: ledgerId,
        includeDeleted: includeDeleted,
        includeDisabled: includeDisabled,
      );

  /// [listCompanies] 的显式 executor 版本（事务内必须用它）。
  Future<List<Company>> listCompaniesOn(
    DatabaseExecutor executor, {
    String? ledgerId,
    bool includeDeleted = false,
    bool includeDisabled = false,
  }) async {
    final (where, args) = _where([
      if (ledgerId != null) 'ledger_id = ?',
      if (!includeDeleted) 'deleted_at IS NULL',
      if (!includeDisabled) 'enabled = 1',
    ], [
      if (ledgerId != null) ledgerId,
    ]);
    final rows = await executor.query(
      'company',
      where: where,
      whereArgs: args,
      orderBy: 'created_at ASC',
    );
    return rows.map(_companyFromRow).toList(growable: false);
  }

  /// 更新公司（按 id 定位）。停用 = `enabled=false`，历史记录不受影响（§8#2）。
  /// 仅事务外可用；事务内用 [updateCompanyOn]。
  Future<void> updateCompany(Company x) async => updateCompanyOn(_db ?? await open(), x);

  /// [updateCompany] 的显式 executor 版本（事务内必须用它）。
  Future<void> updateCompanyOn(DatabaseExecutor executor, Company x) =>
      _write(executor, 'company', _companyToRow(x));

  /// 软删公司：置 `deleted_at` + 刷新 `updated_at`（§8#3 / AC-20）。
  /// 仅事务外可用；事务内用 [softDeleteCompanyOn]。
  Future<void> softDeleteCompany(String id, DateTime at) async =>
      softDeleteCompanyOn(_db ?? await open(), id, at);

  /// [softDeleteCompany] 的显式 executor 版本（事务内必须用它）。
  Future<void> softDeleteCompanyOn(DatabaseExecutor executor, String id, DateTime at) =>
      _softDelete(executor, 'company', id, at);

  // ═══════════════════════════════════════════════════════════════════════
  // PricingRule
  // ═══════════════════════════════════════════════════════════════════════

  /// 插入计价规则（同 id 覆盖）。
  /// 注意：本方法**只写 pricing_rule 表**，不触碰 work_record —— 改价不回改历史（底线 2）。
  /// 仅事务外可用；事务内用 [upsertPricingRuleOn]。
  Future<void> upsertPricingRule(PricingRule x) async =>
      upsertPricingRuleOn(_db ?? await open(), x);

  /// [upsertPricingRule] 的显式 executor 版本（事务内必须用它）。
  Future<void> upsertPricingRuleOn(DatabaseExecutor executor, PricingRule x) =>
      _write(executor, 'pricing_rule', _ruleToRow(x));

  /// 取计价规则（不过滤软删，供历史记录溯源展示）。
  /// 仅事务外可用；事务内用 [getPricingRuleOn]。
  Future<PricingRule?> getPricingRule(String id) async =>
      getPricingRuleOn(_db ?? await open(), id);

  /// [getPricingRule] 的显式 executor 版本（事务内必须用它）。
  Future<PricingRule?> getPricingRuleOn(DatabaseExecutor executor, String id) async {
    final rows = await executor
        .query('pricing_rule', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _ruleFromRow(rows.first);
  }

  /// 列计价规则。`companyId` 过滤公司。
  ///
  /// **默认排除软删与停用项**（新建选择器口径，§8#11 / AC-19）：
  /// `includeDisabled` 默认 **false** → 只返回 `enabled = 1` 且未软删的规则。
  /// 历史展示需含停用/软删时显式传 `includeDisabled: true` / `includeDeleted: true`。
  /// （M-01 修复：原默认值为 `true`，与本文档注释及 AC-19 矛盾。）
  /// 仅事务外可用；事务内用 [listPricingRulesOn]。
  Future<List<PricingRule>> listPricingRules({
    String? companyId,
    bool includeDeleted = false,
    bool includeDisabled = false,
  }) async =>
      listPricingRulesOn(
        _db ?? await open(),
        companyId: companyId,
        includeDeleted: includeDeleted,
        includeDisabled: includeDisabled,
      );

  /// [listPricingRules] 的显式 executor 版本（事务内必须用它）。
  Future<List<PricingRule>> listPricingRulesOn(
    DatabaseExecutor executor, {
    String? companyId,
    bool includeDeleted = false,
    bool includeDisabled = false,
  }) async {
    final (where, args) = _where([
      if (companyId != null) 'company_id = ?',
      if (!includeDeleted) 'deleted_at IS NULL',
      if (!includeDisabled) 'enabled = 1',
    ], [
      if (companyId != null) companyId,
    ]);
    final rows = await executor.query(
      'pricing_rule',
      where: where,
      whereArgs: args,
      orderBy: 'created_at ASC',
    );
    return rows.map(_ruleFromRow).toList(growable: false);
  }

  /// 更新计价规则。**注意：绝不可在此重算历史 work_record**（§3.3 实现红线）。
  /// 仅事务外可用；事务内用 [updatePricingRuleOn]。
  Future<void> updatePricingRule(PricingRule x) async =>
      updatePricingRuleOn(_db ?? await open(), x);

  /// [updatePricingRule] 的显式 executor 版本（事务内必须用它）。
  /// 只写 pricing_rule 表；**不触碰 work_record**（改价不回改历史，底线 2）。
  Future<void> updatePricingRuleOn(DatabaseExecutor executor, PricingRule x) =>
      _write(executor, 'pricing_rule', _ruleToRow(x));

  /// 软删计价规则。历史工作记录仍可按快照展示金额（弱引用允许悬空，§3.3）。
  /// 仅事务外可用；事务内用 [softDeletePricingRuleOn]。
  Future<void> softDeletePricingRule(String id, DateTime at) async =>
      softDeletePricingRuleOn(_db ?? await open(), id, at);

  /// [softDeletePricingRule] 的显式 executor 版本（事务内必须用它）。
  Future<void> softDeletePricingRuleOn(DatabaseExecutor executor, String id, DateTime at) =>
      _softDelete(executor, 'pricing_rule', id, at);

  // ═══════════════════════════════════════════════════════════════════════
  // WorkRecord
  // ═══════════════════════════════════════════════════════════════════════

  /// 插入工作记录（快照五件套落库固化，同 id 覆盖）。
  /// 仅事务外可用；事务内用 [upsertWorkRecordOn]。
  Future<void> upsertWorkRecord(WorkRecord x) async =>
      upsertWorkRecordOn(_db ?? await open(), x);

  /// [upsertWorkRecord] 的显式 executor 版本（事务内必须用它）。
  Future<void> upsertWorkRecordOn(DatabaseExecutor executor, WorkRecord x) =>
      _write(executor, 'work_record', _workRecordToRow(x));

  /// 取工作记录（不过滤软删）。仅事务外可用；事务内用 [getWorkRecordOn]。
  Future<WorkRecord?> getWorkRecord(String id) async =>
      getWorkRecordOn(_db ?? await open(), id);

  /// [getWorkRecord] 的显式 executor 版本（事务内必须用它）。
  Future<WorkRecord?> getWorkRecordOn(DatabaseExecutor executor, String id) async {
    final rows = await executor
        .query('work_record', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _workRecordFromRow(rows.first);
  }

  /// 列工作记录。
  /// - `companyId` 过滤公司；默认排除软删（导出备份传 `includeDeleted: true`）。
  /// - `startDate`/`endDate` 按**归属日**闭区间过滤（§7.1 月历跨公司聚合）。
  /// - `includeDraft` 默认 true（台账需显示草稿）；派生口径聚合在 [aggregate] 内排除草稿。
  /// 仅事务外可用；事务内用 [listWorkRecordsOn]。
  Future<List<WorkRecord>> listWorkRecords({
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
    bool includeDraft = true,
  }) async =>
      listWorkRecordsOn(
        _db ?? await open(),
        companyId: companyId,
        startDate: startDate,
        endDate: endDate,
        includeDeleted: includeDeleted,
        includeDraft: includeDraft,
      );

  /// [listWorkRecords] 的显式 executor 版本（事务内必须用它）。
  Future<List<WorkRecord>> listWorkRecordsOn(
    DatabaseExecutor executor, {
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
    bool includeDraft = true,
  }) async {
    final rows = await _workRecordRows(
      executor,
      companyId: companyId,
      startDate: startDate,
      endDate: endDate,
      includeDeleted: includeDeleted,
      includeDraft: includeDraft,
    );
    return rows.map(_workRecordFromRow).toList(growable: false);
  }

  /// **容错读**（G-02 脏行隔离，2026-09-30）：整表读工作记录，**逐行隔离**坏行
  /// ——坏行跳过并收集、**不上抛**（闭合 I-9）。
  ///
  /// 与 [listWorkRecords] 的**唯一差别**是坏行处理（过滤参数完全一致）：
  /// 本方法不因单行脏值致整表失败，返回 [LenientRead]（健康行 + 坏行清单）。
  /// ⚠️ **跳过坏行 = 该行金额未计入**；调用方**必须**检查 [LenientRead.skipped]
  /// 并处理（提示 / 阻断聚合 / 引导导出备份），**不得**当无事发生。
  /// 仅事务外可用；事务内用 [listWorkRecordsLenientOn]。
  Future<LenientRead<WorkRecord>> listWorkRecordsLenient({
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
    bool includeDraft = true,
  }) async =>
      listWorkRecordsLenientOn(
        _db ?? await open(),
        companyId: companyId,
        startDate: startDate,
        endDate: endDate,
        includeDeleted: includeDeleted,
        includeDraft: includeDraft,
      );

  /// [listWorkRecordsLenient] 的显式 executor 版本（事务内必须用它）。
  Future<LenientRead<WorkRecord>> listWorkRecordsLenientOn(
    DatabaseExecutor executor, {
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
    bool includeDraft = true,
  }) async {
    final rows = await _workRecordRows(
      executor,
      companyId: companyId,
      startDate: startDate,
      endDate: endDate,
      includeDeleted: includeDeleted,
      includeDraft: includeDraft,
    );
    return _parseLenient(rows, _workRecordFromRow);
  }

  // ── 工作记录更新：**已拆签名**（I-8 / G-11，2026-10-01 落地 · 批次 0-A）──────────────────
  //
  // 原 `updateWorkRecord(WorkRecord x)` 把整个对象（含四个金额快照）原样写回，
  // 调用方漏字段即等于把快照清零 → 已**删除**（lib/tool/test 零调用点）。
  // 现拆为两个**职责互斥**的方法，从类型/ SQL 两层堵死「误改快照」：
  //
  //   ┌ updateWorkRecordMeta        —— 只改非金额 Meta（归属日/备注/状态）；
  //   │                                SQL 语句不含任何快照列 + 运行期断言兜底（07 §4.2 D2）。
  //   └ replaceWorkRecordSnapshot   —— **显式**覆盖「快照块」（数量/起止/倍率/金额…）；
  //   调用点必须二次确认（07 §4.2 U5：仅「改单价」「手工覆盖金额」两处高危动作）。
  //
  // **契约（冻结，07 §4.2 D1 为准）**：
  //   `updateWorkRecordMeta({required String id, DateTime? workDate, String? note,
  //                          RecordStatus? status, required DateTime updatedAt})`
  //   `replaceWorkRecordSnapshot({required String id, required int rateSnapshot,
  //     required RateSnapshot rateDetailSnapshot, required int amountSnapshot,
  //     required AmountSource amountSource, int? autoReferenceAmount,
  //     double? qtySnapshot, String? qtyUnitSnapshot, DateTime? startTime,
  //     DateTime? endTime, bool? overnight, required DateTime updatedAt})`
  //
  // **参数 null 语义（07 §4.2 D1 **已冻结**）**：Meta 的可空参数传 `null` = **保留库内现值**；
  //   Snapshot 的可空列传 `null` = **清空写 NULL** → **调用方必须显式传全终态**（漏传 = 清空）。
  //   - Meta：可空参数传 `null` = **保留库内现值**（补丁语义；清空备注请传空串 `''`）；
  //   - Snapshot：**整块覆盖** —— 可空列（`autoReferenceAmount`/`qtyUnitSnapshot`/
  //     `startTime`/`endTime`）传 `null` = **写 NULL（清空）**；
  //     非空列 `qtySnapshot`/`overnight` 传 `null` = **保留库内现值**（无法写 NULL）。
  //
  // **改归属日 `workDate`（R-G05 **v3 终版** / AC-10，2026-10-01）**：
  //   `workDate` = **纯 Meta**。改归属日**只调本方法** `updateWorkRecordMeta(workDate: …)`，
  //   **只写 `attribution_date`**；**金额快照冻结不动**、**不重算**、**不需要事务双写**
  //   （**不**调 [replaceWorkRecordSnapshot]）。`D`（倍率命中的日期上下文）**不是运行期函数**，
  //   故**改归属日不是重算事件**；历史金额不受影响（守底线 2「快照不可变」）。
  //   **硬约束（07 §4.2）**：`replaceWorkRecordSnapshot` **不得**加 `workDate` 参数；**不引入**新 DB 方法。
  //   依据：`07 §4.2`（R-G05 v3）+ `03 §4.1`。

  /// 更新工作记录的 **Meta（非金额）字段**（按 id 定位）。仅事务外可用；事务内用
  /// [updateWorkRecordMetaOn]。
  ///
  /// 只触碰 `attribution_date`（归属日）/ `note`（备注）/ `status`（状态）/ `updated_at`；
  /// **SQL 更新语句里不含任何金额快照列**，故本方法在**语句层**就不可能改动快照。
  /// 另在**运行期**回读并断言四个金额快照（`amountSnapshot`/`rateSnapshot`/
  /// `rateDetailSnapshot`/`autoReferenceAmount`）未变（07 §4.2 D2 兜底），变了即抛。
  ///
  /// 🚫 要改金额 / 数量 / 起止 / 倍率 —— 走 [replaceWorkRecordSnapshot]（显式覆盖 + 二次确认）。
  /// 🚫 禁止「按当前 pricing_rule 现价重算金额」—— 那是「改价回改历史」（底线 2 / §8#4）。
  Future<void> updateWorkRecordMeta({
    required String id,
    DateTime? workDate,
    String? note,
    RecordStatus? status,
    required DateTime updatedAt,
  }) async =>
      updateWorkRecordMetaOn(
        _db ?? await open(),
        id: id,
        workDate: workDate,
        note: note,
        status: status,
        updatedAt: updatedAt,
      );

  /// [updateWorkRecordMeta] 的显式 executor 版本（事务内必须用它）。
  Future<void> updateWorkRecordMetaOn(
    DatabaseExecutor executor, {
    required String id,
    DateTime? workDate,
    String? note,
    RecordStatus? status,
    required DateTime updatedAt,
  }) async {
    // 读库内现值：既用于存在性校验，也用于步骤 ③ 的断言基线。
    final before = await getWorkRecordOn(executor, id);
    if (before == null) {
      throw StateError('updateWorkRecordMeta: work_record `$id` 不存在，无法按 id 更新');
    }
    // 只更新 Meta 列（null = 保留现值）；**不含**快照列。
    final values = <String, Object?>{
      if (workDate != null) 'attribution_date': _dateOnly(workDate),
      if (note != null) 'note': note,
      if (status != null) 'status': status.name,
      'updated_at': updatedAt.toIso8601String(),
    };
    await executor.update('work_record', values, where: 'id = ?', whereArgs: [id]);
    // 运行期断言兜底（07 §4.2 D2）：回读并断言四个金额快照与更新前一致，防任何越界写入。
    final after = await getWorkRecordOn(executor, id);
    _assertSnapshotUnchanged(before, after, 'updateWorkRecordMeta');
  }

  /// **显式覆盖**工作记录的快照块（按 id 定位）。仅事务外可用；事务内用
  /// [replaceWorkRecordSnapshotOn]。
  ///
  /// 覆盖列为：`quantity` / `quantity_unit_snapshot` / `start_time` / `end_time` /
  /// `is_overnight` / `unit_price_snapshot` / 倍率明细 7 列 / `amount_snapshot` /
  /// `amount_source` / `auto_reference` / `updated_at`。
  /// **不改**：`company_id` / `pricing_rule_id` / `attribution_date` / `mode_snapshot` /
  /// `currency` / `note` / `status` / `created_at` / `deleted_at`
  /// （Meta 变更请走 [updateWorkRecordMeta]；计价方式变更不在本基础版 UI 编辑范围内）。
  ///
  /// ⚠️ **调用契约**：本方法会**改写金额快照**，调用点**必须二次确认**
  /// （07 §4.2 U5：仅「改单价（动作 A）」「手工覆盖金额（动作 B）」两处）；传入的
  /// `amountSnapshot`/`rateSnapshot`/`rateDetailSnapshot` 必须是**已按本条快照重算/用户确认**
  /// 的值，**禁止**读当前 `pricing_rule` 现价重算（改价回改历史，底线 2 / §8#4）。
  /// 参数 null 语义见本节顶部契约。
  Future<void> replaceWorkRecordSnapshot({
    required String id,
    required int rateSnapshot,
    required RateSnapshot rateDetailSnapshot,
    required int amountSnapshot,
    required AmountSource amountSource,
    int? autoReferenceAmount,
    double? qtySnapshot,
    String? qtyUnitSnapshot,
    DateTime? startTime,
    DateTime? endTime,
    bool? overnight,
    required DateTime updatedAt,
  }) async =>
      replaceWorkRecordSnapshotOn(
        _db ?? await open(),
        id: id,
        rateSnapshot: rateSnapshot,
        rateDetailSnapshot: rateDetailSnapshot,
        amountSnapshot: amountSnapshot,
        amountSource: amountSource,
        autoReferenceAmount: autoReferenceAmount,
        qtySnapshot: qtySnapshot,
        qtyUnitSnapshot: qtyUnitSnapshot,
        startTime: startTime,
        endTime: endTime,
        overnight: overnight,
        updatedAt: updatedAt,
      );

  /// [replaceWorkRecordSnapshot] 的显式 executor 版本（事务内必须用它）。
  Future<void> replaceWorkRecordSnapshotOn(
    DatabaseExecutor executor, {
    required String id,
    required int rateSnapshot,
    required RateSnapshot rateDetailSnapshot,
    required int amountSnapshot,
    required AmountSource amountSource,
    int? autoReferenceAmount,
    double? qtySnapshot,
    String? qtyUnitSnapshot,
    DateTime? startTime,
    DateTime? endTime,
    bool? overnight,
    required DateTime updatedAt,
  }) async {
    // 数量 / 跨夜为非空列：可选参数传 null 时保留库内现值 → 先读现值（兼作存在性校验）。
    final current = await getWorkRecordOn(executor, id);
    if (current == null) {
      throw StateError('replaceWorkRecordSnapshot: work_record `$id` 不存在，无法按 id 更新');
    }
    final values = <String, Object?>{
      'quantity': qtySnapshot ?? current.qtySnapshot,
      'quantity_unit_snapshot': qtyUnitSnapshot,
      'start_time': startTime == null ? null : _hhmm(startTime),
      'end_time': endTime == null ? null : _hhmm(endTime),
      'is_overnight': (overnight ?? current.overnight) ? 1 : 0,
      'unit_price_snapshot': rateSnapshot,
      'rate_overtime_hit': rateDetailSnapshot.overtime ? 1 : 0,
      'rate_overtime_rate': rateDetailSnapshot.overtimeRate,
      'rate_weekend_hit': rateDetailSnapshot.weekend ? 1 : 0,
      'rate_weekend_rate': rateDetailSnapshot.weekendRate,
      'rate_holiday_hit': rateDetailSnapshot.holiday ? 1 : 0,
      'rate_holiday_rate': rateDetailSnapshot.holidayRate,
      'rate_applied': rateDetailSnapshot.appliedRate,
      'amount_snapshot': amountSnapshot,
      'amount_source': amountSource.name,
      'auto_reference': autoReferenceAmount,
      'updated_at': updatedAt.toIso8601String(),
    };
    await executor.update('work_record', values, where: 'id = ?', whereArgs: [id]);
  }

  /// 软删工作记录：置 `deleted_at` + 刷新 `updated_at`（§8#3 / AC-20）。
  /// 仅事务外可用；事务内用 [softDeleteWorkRecordOn]。
  Future<void> softDeleteWorkRecord(String id, DateTime at) async =>
      softDeleteWorkRecordOn(_db ?? await open(), id, at);

  /// [softDeleteWorkRecord] 的显式 executor 版本（事务内必须用它）。
  Future<void> softDeleteWorkRecordOn(DatabaseExecutor executor, String id, DateTime at) =>
      _softDelete(executor, 'work_record', id, at);

  // ═══════════════════════════════════════════════════════════════════════
  // PaymentRecord
  // ═══════════════════════════════════════════════════════════════════════

  /// 插入收款记录（同 id 覆盖）。金额 > 0 由 Validators 在保存前拦截（AC-25）。
  /// 仅事务外可用；事务内用 [upsertPaymentRecordOn]。
  Future<void> upsertPaymentRecord(PaymentRecord x) async =>
      upsertPaymentRecordOn(_db ?? await open(), x);

  /// [upsertPaymentRecord] 的显式 executor 版本（事务内必须用它）。
  Future<void> upsertPaymentRecordOn(DatabaseExecutor executor, PaymentRecord x) =>
      _write(executor, 'payment_record', _paymentToRow(x));

  /// 取收款记录（不过滤软删）。仅事务外可用；事务内用 [getPaymentRecordOn]。
  Future<PaymentRecord?> getPaymentRecord(String id) async =>
      getPaymentRecordOn(_db ?? await open(), id);

  /// [getPaymentRecord] 的显式 executor 版本（事务内必须用它）。
  Future<PaymentRecord?> getPaymentRecordOn(DatabaseExecutor executor, String id) async {
    final rows = await executor
        .query('payment_record', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _paymentFromRow(rows.first);
  }

  /// 列收款记录。`startDate`/`endDate` 按**收款日期**闭区间过滤。
  /// 仅事务外可用；事务内用 [listPaymentRecordsOn]。
  Future<List<PaymentRecord>> listPaymentRecords({
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
  }) async =>
      listPaymentRecordsOn(
        _db ?? await open(),
        companyId: companyId,
        startDate: startDate,
        endDate: endDate,
        includeDeleted: includeDeleted,
      );

  /// [listPaymentRecords] 的显式 executor 版本（事务内必须用它）。
  Future<List<PaymentRecord>> listPaymentRecordsOn(
    DatabaseExecutor executor, {
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
  }) async {
    final rows = await _paymentRecordRows(
      executor,
      companyId: companyId,
      startDate: startDate,
      endDate: endDate,
      includeDeleted: includeDeleted,
    );
    return rows.map(_paymentFromRow).toList(growable: false);
  }

  /// **容错读**（G-02 脏行隔离，2026-09-30）：整表读收款记录，**逐行隔离**坏行
  /// ——坏行跳过并收集、**不上抛**（闭合 I-9）。
  ///
  /// 语义与 [listWorkRecordsLenient] 一致（过滤参数与 [listPaymentRecords] 一致）；
  /// 坏行跳过 = 该行「已收」金额未计入，调用方**必须**处理 [LenientRead.skipped]。
  /// 仅事务外可用；事务内用 [listPaymentRecordsLenientOn]。
  Future<LenientRead<PaymentRecord>> listPaymentRecordsLenient({
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
  }) async =>
      listPaymentRecordsLenientOn(
        _db ?? await open(),
        companyId: companyId,
        startDate: startDate,
        endDate: endDate,
        includeDeleted: includeDeleted,
      );

  /// [listPaymentRecordsLenient] 的显式 executor 版本（事务内必须用它）。
  Future<LenientRead<PaymentRecord>> listPaymentRecordsLenientOn(
    DatabaseExecutor executor, {
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
  }) async {
    final rows = await _paymentRecordRows(
      executor,
      companyId: companyId,
      startDate: startDate,
      endDate: endDate,
      includeDeleted: includeDeleted,
    );
    return _parseLenient(rows, _paymentFromRow);
  }

  /// 更新收款记录（按 id 定位）。
  /// 金额字段（`amount`）的编辑口径由上层 Validators 把关（AC-25）；本层照写传入值。
  /// 仅事务外可用；事务内用 [updatePaymentRecordOn]。
  Future<void> updatePaymentRecord(PaymentRecord x) async =>
      updatePaymentRecordOn(_db ?? await open(), x);

  /// [updatePaymentRecord] 的显式 executor 版本（事务内必须用它）。
  Future<void> updatePaymentRecordOn(DatabaseExecutor executor, PaymentRecord x) =>
      _write(executor, 'payment_record', _paymentToRow(x));

  /// 软删收款记录：置 `deleted_at` + 刷新 `updated_at`（§8#3 / AC-20）。
  /// 仅事务外可用；事务内用 [softDeletePaymentRecordOn]。
  Future<void> softDeletePaymentRecord(String id, DateTime at) async =>
      softDeletePaymentRecordOn(_db ?? await open(), id, at);

  /// [softDeletePaymentRecord] 的显式 executor 版本（事务内必须用它）。
  Future<void> softDeletePaymentRecordOn(DatabaseExecutor executor, String id, DateTime at) =>
      _softDelete(executor, 'payment_record', id, at);

  // ═══════════════════════════════════════════════════════════════════════
  // HolidayMark（无 updated_at / deleted_at；唯一约束 (ledger_id, date)）
  // ═══════════════════════════════════════════════════════════════════════

  /// 插入/覆盖节假日标记。
  ///
  /// 唯一约束 `(ledger_id, date)`（§3.1）。⚠️ **`ConflictAlgorithm.replace` 的真实语义**：
  /// 它生成 `INSERT OR REPLACE`，而 SQLite 对**任意** UNIQUE 冲突（含 `(ledger_id, date)`）
  /// 一律「**先删冲突行、再插入新行**」，**不抛任何异常** —— 即写入**静默替换**：旧行被物理
  /// 删除、`id` 变为传入值、`(ledger_id, date)` 指向新 `id`。
  /// （R2-01 修正：原注释称「id 不同但 `(ledger_id,date)` 已存在会抛 `DatabaseException`」，
  /// 该断言为假；经 reviewer-db-2 探针 + 本脚本 §8 断言双重实测证伪。）
  ///
  /// **id 稳定性指引（调用方根据场景二选一）**：
  ///   - 只想改「类型 / 倍率」而**保留原 `id`**：先 [getHolidayMarkByDate] 取旧 id 复用，
  ///     再用该 id 构造 [HolidayMark] upsert（此时主键命中，覆盖等价于更新）；
  ///   - 或按 `(ledger_id, date)` 走**显式 UPDATE**（不经 `OR REPLACE`），彻底避免删行换 id。
  ///   ⚠️ **不可**依赖「捕获异常后转 UPDATE」——`OR REPLACE` 永不抛异常，该 catch 恒不触发。
  /// 仅事务外可用；事务内用 [upsertHolidayMarkOn]。
  Future<void> upsertHolidayMark(HolidayMark x) async =>
      upsertHolidayMarkOn(_db ?? await open(), x);

  /// [upsertHolidayMark] 的显式 executor 版本（事务内必须用它）。
  ///
  /// ⚠️ **R2-01 修正（2026-09-30）**：原注释断言「唯一约束 `(ledger_id, date)` 与主键 `id`
  /// 可能同时冲突，`ConflictAlgorithm.replace` 只保证按主键覆盖，`(ledger_id,date)` 冲突会抛
  /// `DatabaseException`」——**与实现不符**（实证见 [upsertHolidayMark] 与 tool/verify_db.dart §8）。
  /// 现状：`_write` 恒用 `INSERT OR REPLACE`，**任意** UNIQUE 冲突均静默「删旧行 + 插新行」、
  /// 不抛异常。语义与调用方契约以 [upsertHolidayMark] 为准。
  Future<void> upsertHolidayMarkOn(DatabaseExecutor executor, HolidayMark x) =>
      _write(executor, 'holiday_mark', _holidayToRow(x));

  /// 取节假日标记（该表无软删，物理存在即有效）。
  /// 仅事务外可用；事务内用 [getHolidayMarkOn]。
  Future<HolidayMark?> getHolidayMark(String id) async =>
      getHolidayMarkOn(_db ?? await open(), id);

  /// [getHolidayMark] 的显式 executor 版本（事务内必须用它）。
  Future<HolidayMark?> getHolidayMarkOn(DatabaseExecutor executor, String id) async {
    final rows = await executor
        .query('holiday_mark', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _holidayFromRow(rows.first);
  }

  /// 按 (ledger_id, date) 取唯一标记；未标记返回 null。
  /// 日历着色前查「当日是否节假日」走本方法（命中唯一索引，O(log n)）。
  /// 仅事务外可用；事务内用 [getHolidayMarkByDateOn]。
  Future<HolidayMark?> getHolidayMarkByDate(String ledgerId, DateTime date) async =>
      getHolidayMarkByDateOn(_db ?? await open(), ledgerId, date);

  /// [getHolidayMarkByDate] 的显式 executor 版本（事务内必须用它）。
  Future<HolidayMark?> getHolidayMarkByDateOn(
    DatabaseExecutor executor,
    String ledgerId,
    DateTime date,
  ) async {
    final rows = await executor.query(
      'holiday_mark',
      where: 'ledger_id = ? AND date = ?',
      whereArgs: [ledgerId, _dateOnly(date)],
      limit: 1,
    );
    return rows.isEmpty ? null : _holidayFromRow(rows.first);
  }

  /// 列节假日标记。`startDate`/`endDate` 按 `date` 闭区间过滤（日历渲染某月用）。
  /// 仅事务外可用；事务内用 [listHolidayMarksOn]。
  Future<List<HolidayMark>> listHolidayMarks({
    String? ledgerId,
    DateTime? startDate,
    DateTime? endDate,
  }) async =>
      listHolidayMarksOn(
        _db ?? await open(),
        ledgerId: ledgerId,
        startDate: startDate,
        endDate: endDate,
      );

  /// [listHolidayMarks] 的显式 executor 版本（事务内必须用它）。
  Future<List<HolidayMark>> listHolidayMarksOn(
    DatabaseExecutor executor, {
    String? ledgerId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final (dateWhere, dateArgs) = _dateRange('date', startDate, endDate);
    final (where, args) = _where([
      if (ledgerId != null) 'ledger_id = ?',
      ...dateWhere,
    ], [
      if (ledgerId != null) ledgerId,
      ...dateArgs,
    ]);
    final rows = await executor.query(
      'holiday_mark',
      where: where,
      whereArgs: args,
      orderBy: 'date ASC',
    );
    return rows.map(_holidayFromRow).toList(growable: false);
  }

  /// 更新节假日标记（按 id 定位）。仅事务外可用；事务内用 [updateHolidayMarkOn]。
  Future<void> updateHolidayMark(HolidayMark x) async =>
      updateHolidayMarkOn(_db ?? await open(), x);

  /// [updateHolidayMark] 的显式 executor 版本（事务内必须用它）。
  Future<void> updateHolidayMarkOn(DatabaseExecutor executor, HolidayMark x) =>
      _write(executor, 'holiday_mark', _holidayToRow(x));

  /// 取消标记 = **物理删除**：本表无 `deleted_at` 列（database_schema.dart:116-125），
  /// 且「取消某日标记」语义上就该让该日回到"无反查值"状态，无审计价值 → 不引入软删列。
  /// 与 §8#3「删除默认软删」的偏离已登记 00-开放问题台账。
  /// 仅事务外可用；事务内用 [deleteHolidayMarkOn]。
  Future<void> deleteHolidayMark(String id) async =>
      deleteHolidayMarkOn(_db ?? await open(), id);

  /// [deleteHolidayMark] 的显式 executor 版本（事务内必须用它）。
  Future<void> deleteHolidayMarkOn(DatabaseExecutor executor, String id) async {
    await executor.delete('holiday_mark', where: 'id = ?', whereArgs: [id]);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // 内部：通用写/删与 SQL 片段构造
  // ═══════════════════════════════════════════════════════════════════════

  /// upsert 写：`ConflictAlgorithm.replace` 按主键 id 覆盖（导入 overwrite 策略用，§6.4）。
  ///
  /// 入参类型为 [DatabaseExecutor]（`Database` 与 `Transaction` 均实现之），
  /// 使同一实现既能在事务外（[Database]）也能在事务内（[Transaction]）复用 —— C-01 修复核心。
  Future<void> _write(
    DatabaseExecutor executor,
    String table,
    Map<String, Object?> row,
  ) async {
    await executor.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 软删：`deleted_at = <at>` 且 `updated_at = <at>`（§8#3）。
  /// 用参数绑定，不拼字符串（防注入）。
  /// 入参类型为 [DatabaseExecutor]（理由同 [_write]）。
  Future<void> _softDelete(
    DatabaseExecutor executor,
    String table,
    String id,
    DateTime at,
  ) async {
    final stamp = at.toIso8601String();
    await executor.update(
      table,
      {'deleted_at': stamp, 'updated_at': stamp},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 拼 WHERE：空条件返回 `(null, [])`，让 sqflite 省略 WHERE 子句。
  (String?, List<Object?>) _where(List<String> clauses, List<Object?> args) {
    if (clauses.isEmpty) return (null, const []);
    return (clauses.join(' AND '), args);
  }

  /// 日期闭区间条件（列存 `yyyy-MM-dd` 文本，字典序 = 时间序，可直接比较）。
  (List<String>, List<Object?>) _dateRange(
    String column,
    DateTime? start,
    DateTime? end,
  ) {
    final clauses = <String>[];
    final args = <Object?>[];
    if (start != null) {
      clauses.add('$column >= ?');
      args.add(_dateOnly(start));
    }
    if (end != null) {
      clauses.add('$column <= ?');
      args.add(_dateOnly(end));
    }
    return (clauses, args);
  }

  /// **聚合前类型前置守卫**（M-01 修复，2026-10-01）。
  ///
  /// ⚠️ **为什么必须放在 SQL 侧**：SQLite `SUM()` 在**聚合阶段**就把非数值行「洗白」——
  /// TEXT / BLOB 参与 `SUM` 一律按 **`0.0`（REAL）** 计入。于是 Dart 侧 [_asAggregateInt]
  /// 永远只看到合法的 `0.0` 并放行 → **聚合静默少算**（`amount` 被改成 TEXT 后算 0 →
  /// 少算「已收」→ 剩余虚增，本项目**唯一不可容忍方向**），而**同值的行映射路径是抛错的**
  /// —— 两条口径路径行为不一致。即 [_asAggregateInt] 里「非 `num` → 抛」那个分支
  /// 在**纯 SQL 聚合路径上结构不可达**（实测：`typeof='text'` 时 raw `SUM` 返回 `0.0`/REAL）。
  /// 故必须在聚合**之前**用 `typeof()` 直接检查**列中每一行**的**存储类型**。
  ///
  /// 判据 = **白名单** `typeof(col) NOT IN ('integer','real')`（对未知脏类型更保守，
  /// 与 [aggregateOn] 用 `status IN (...)` 白名单、刻意不用 `status <> 'draft'` 黑名单同一思路）。
  /// 命中任一坏行 → 抛 [FormatException]（含表列名 + 坏行条数 + 具体 typeof），**整表拒绝出数**。
  ///
  /// 口径：命中即拒绝（**不做**「跳过坏行继续 SUM」）——聚合要的是一个**可信合计**，
  /// 少算一行与算错一行同样致命（AC-33「合计 == 明细之和」）。
  ///
  /// 注：`table` / `column` 均来自本文件内的**字面量调用点**（非用户输入），故直接内插；
  /// 语义为**全局**（不带公司过滤）：「任一行类型坏 → 拒绝出数」。
  /// **影响面（Minor-3）**：因守卫不带 `company_id` 过滤，**任意一家公司**的坏行都会让**所有**
  /// [aggregateOn] / [aggregateByCompanyOn] 调用抛错（含只查其它公司的调用）——这是刻意的
  /// fail-loud（宁可全局报警，也不局部静默少算，AC-33「合计 == 明细之和」）。
  Future<void> _assertAggregateColumnTypes(
    DatabaseExecutor executor,
    String table,
    String column,
  ) async {
    final rows = await executor.rawQuery(
      'SELECT typeof($column) AS t, COUNT(*) AS c FROM $table '
      "WHERE deleted_at IS NULL AND typeof($column) NOT IN ('integer','real') "
      'GROUP BY typeof($column)',
    );
    if (rows.isEmpty) return; // 无坏行
    var n = 0;
    final types = <String>[];
    for (final r in rows) {
      n += _asInt(r['c']);
      types.add(_asString(r['t']));
    }
    throw FormatException(
        '聚合列 `$table.$column` 存在 $n 条非数值行（typeof = ${types.join(',')}，'
        "不在 integer/real 白名单内），拒绝静默按 0 计入（库可能被外部改写）");
  }

  /// 取单个口径金额列的整数聚合；无行返回 0。
  ///
  /// 先经 [_assertAggregateColumnTypes] 做**类型前置守卫**（M-01 修复：`SUM()` 会把 TEXT/BLOB
  /// 洗成 `0.0`，纯 Dart 侧无法察觉，必须在 SQL 侧先拦）；再经 [_asAggregateInt] 解析求和结果
  /// （**G-03 硬化，2026-09-30**：REAL 非整值一律抛 [FormatException]）。
  /// 两道关合并覆盖：坏**类型**（TEXT/BLOB/NULL）→ 守卫抛；坏**数值**（REAL 非整）→ 解析抛。
  /// 均**不再**静默按 0 计或截断（静默偏离会「少算已收 → 剩余虚增」）。
  /// `table` / `column` 用于守卫与抛错消息定位（如 `work_record` / `amount_snapshot`）。
  Future<int> _sumInt(
    DatabaseExecutor executor,
    String sql, // 不含额外 WHERE 的基线语句（已含 WHERE deleted_at IS NULL 等基础条件）
    String? extraWhere,
    List<Object?> args, {
    required String table,
    required String column,
  }) async {
    await _assertAggregateColumnTypes(executor, table, column);
    final fullSql = extraWhere == null ? sql : '$sql AND $extraWhere';
    final rows = await executor.rawQuery(fullSql, args);
    if (rows.isEmpty) return 0;
    return _asAggregateInt(rows.first['total'], '$table.$column');
  }

  /// 工作记录**整表查询的原始行获取**（严格读 [listWorkRecordsOn] 与容错读
  /// [listWorkRecordsLenientOn] 共用，保证两条路径的过滤/排序/参数绑定**逐字一致**）。
  Future<List<Map<String, Object?>>> _workRecordRows(
    DatabaseExecutor executor, {
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
    bool includeDraft = true,
  }) {
    final (dateWhere, dateArgs) = _dateRange('attribution_date', startDate, endDate);
    final (where, args) = _where([
      if (companyId != null) 'company_id = ?',
      ...dateWhere,
      if (!includeDeleted) 'deleted_at IS NULL',
      if (!includeDraft) "status IN ('confirmed','settled')",
    ], [
      if (companyId != null) companyId,
      ...dateArgs,
    ]);
    return executor.query(
      'work_record',
      where: where,
      whereArgs: args,
      orderBy: 'attribution_date DESC, created_at DESC',
    );
  }

  /// 收款记录**整表查询的原始行获取**（严格读/容错读共用，理由同 [_workRecordRows]）。
  Future<List<Map<String, Object?>>> _paymentRecordRows(
    DatabaseExecutor executor, {
    String? companyId,
    DateTime? startDate,
    DateTime? endDate,
    bool includeDeleted = false,
  }) {
    final (dateWhere, dateArgs) = _dateRange('pay_date', startDate, endDate);
    final (where, args) = _where([
      if (companyId != null) 'company_id = ?',
      ...dateWhere,
      if (!includeDeleted) 'deleted_at IS NULL',
    ], [
      if (companyId != null) companyId,
      ...dateArgs,
    ]);
    return executor.query(
      'payment_record',
      where: where,
      whereArgs: args,
      orderBy: 'pay_date DESC, created_at DESC',
    );
  }

  /// 逐行隔离解析（G-02 脏行隔离，2026-09-30）：单行抛错 → 跳过并收集，其余照常返回。
  ///
  /// 坏行 id 只做**尽力提取**（`r['id']?.toString()`），提不出则为 null；
  /// 该提取本身也包在 try 里，避免「定位信息」的解析再抛错把隔离逻辑带崩。
  static LenientRead<T> _parseLenient<T>(
    List<Map<String, Object?>> rows,
    T Function(Map<String, Object?>) parse,
  ) {
    final ok = <T>[];
    final skipped = <SkippedRow>[];
    for (final r in rows) {
      try {
        ok.add(parse(r));
      } catch (e) {
        String? id;
        try {
          id = r['id']?.toString();
        } catch (_) {
          id = null;
        }
        skipped.add(SkippedRow(id: id, error: e));
      }
    }
    return LenientRead<T>(rows: ok, skipped: skipped);
  }

  /// 断言「四个金额快照字段」在更新前后未变（G-11 / 07 §4.2 D2 运行期兜底）。
  ///
  /// 比较 `amountSnapshot` / `rateSnapshot` / `rateDetailSnapshot` / `autoReferenceAmount`；
  /// 任一不一致即抛 [StateError]（说明发生了越界写入，属**严重**错误，必须暴露）。
  /// [after] 为 null（更新后按 id 回读不到）同样视为异常。
  static void _assertSnapshotUnchanged(
    WorkRecord before,
    WorkRecord? after,
    String op,
  ) {
    if (after == null) {
      throw StateError('$op: 更新后按 id 回读不到记录（记录被并发删除？）');
    }
    if (before.amountSnapshot != after.amountSnapshot ||
        before.rateSnapshot != after.rateSnapshot ||
        before.autoReferenceAmount != after.autoReferenceAmount ||
        !_rateSnapshotEquals(before.rateDetailSnapshot, after.rateDetailSnapshot)) {
      throw StateError(
          '$op: 检测到金额快照被改动（越界写入！）——'
          '更新前 amount=${before.amountSnapshot}/rate=${before.rateSnapshot}/'
          'autoRef=${before.autoReferenceAmount} ≠ '
          '更新后 amount=${after.amountSnapshot}/rate=${after.rateSnapshot}/'
          'autoRef=${after.autoReferenceAmount}');
    }
  }

  /// 倍率明细快照逐字段比较（[RateSnapshot] 未实现 `==`，故此处显式比对 7 个字段）。
  static bool _rateSnapshotEquals(RateSnapshot a, RateSnapshot b) =>
      a.overtime == b.overtime &&
      a.overtimeRate == b.overtimeRate &&
      a.weekend == b.weekend &&
      a.weekendRate == b.weekendRate &&
      a.holiday == b.holiday &&
      a.holidayRate == b.holidayRate &&
      a.appliedRate == b.appliedRate;

  // ═══════════════════════════════════════════════════════════════════════
  // 内部：类型 ↔ 列格式工具（与 export_service.dart 同规则，保证跨层一致）
  // ═══════════════════════════════════════════════════════════════════════

  /// 日期 → `yyyy-MM-dd`（列存形态；与 export_service._dateOnly 同规则）。
  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

  /// 时间 → `HH:mm`（列存形态）。
  static String _hhmm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String? _optDateOnly(DateTime? d) => d == null ? null : _dateOnly(d);

  /// 时间戳 → ISO-8601 文本（created_at/updated_at/deleted_at）。
  static String? _optIso(DateTime? d) => d?.toIso8601String();

  /// 兼容解析时间戳（含带时区 ISO 串与旧格式），失败返回 null。
  ///
  /// **兜底说明（M-03）**：解析失败返回 null 本身不注入金额；调用方对
  /// `created_at/updated_at` 用 `?? DateTime.now()` 兜底（审计时间戳，非口径字段，
  /// 不参与聚合）。但 `attribution_date` / `pay_date` 兜底为 `DateTime.now()` 会把
  /// 脏记录**挪到当前月**，造成月度归属漂移 —— 该风险已记录，见 [_dateOrNow]。
  static DateTime? _parseDate(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }

  /// 业务日期兜底：解析失败时退化为「当天」。
  ///
  /// **为何选择该兜底值（M-03）**：`attribution_date` / `pay_date` 是 `NOT NULL` 列，
  /// 正常情况下必可解析；解析失败只可能来自外部导入的脏文件。此时若抛错会整表读取失败，
  /// 影响面过大；退化为当天至少保证「记录仍可见、仍可被人工修正」，且
  /// **不会虚增剩余工资**（日期不参与金额计算，只影响月历/统计归属）。
  /// 该退化方向已获认可（只错归属、不错金额），故保留。
  static DateTime _dateOrNow(dynamic v) => _parseDate(v) ?? DateTime.now();

  /// `HH:mm` → DateTime（日期占位 1970-01-01，仅时间有意义；
  /// 与 import_service._parseHhmm 同规则）。解析失败返回 null（起止时间可空，非口径字段）。
  static DateTime? _parseHhmm(dynamic v) {
    if (v is! String || !v.contains(':')) return null;
    final parts = v.split(':');
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(1970, 1, 1, h, m);
  }

  /// SQLite INTEGER 布尔列 → bool。列由本层以 `0/1` 写入；
  /// 非 `1`/`true` 一律视为 false（不抛错：布尔字段不参与金额口径，宽容兜底无风险）。
  static bool _bool(dynamic v) => v == 1 || v == true;

  // ═══════════════════════════════════════════════════════════════════════
  // 内部：六表 模型 → 行 Map（键 = 表列名）
  // ═══════════════════════════════════════════════════════════════════════

  static Map<String, Object?> _ledgerToRow(Ledger x) => {
        'id': x.id,
        'name': x.name, // 注意：表列名是 name，备份 JSON 才叫 nickname
        'currency': x.currency,
        'mode': x.mode.name, // local | cloud
        'created_at': x.createdAt.toIso8601String(),
      };

  static Map<String, Object?> _companyToRow(Company x) => {
        'id': x.id,
        'ledger_id': x.ledgerId,
        'name': x.name,
        'short_name': x.shortName,
        'tag_color': x.color,
        'default_rule_id': x.defaultRuleId,
        'enabled': x.enabled ? 1 : 0,
        'contact': x.contact,
        'currency': x.currency,
        'note': x.note,
        'created_at': x.createdAt.toIso8601String(),
        'updated_at': x.updatedAt.toIso8601String(),
        'deleted_at': _optIso(x.deletedAt),
      };

  static Map<String, Object?> _ruleToRow(PricingRule x) => {
        'id': x.id,
        'company_id': x.companyId,
        'name': x.name,
        'method': x.method.name, // hourly | daily | piece（备份 JSON 才叫 pricing_mode）
        'base_rate': x.baseRate, // 分（备份 JSON 才叫 base_unit_price）
        'unit': x.unit,
        'standard_hours': x.standardHours,
        'half_day_ratio': x.halfDayRatio, // ×10
        'overtime_rate': x.overtimeRate, // ×10
        'weekend_rate': x.weekendRate, // ×10
        'holiday_rate': x.holidayRate, // ×10
        'effective_date': _optDateOnly(x.effectiveDate),
        'enabled': x.enabled ? 1 : 0,
        'created_at': x.createdAt.toIso8601String(),
        'updated_at': x.updatedAt.toIso8601String(),
        'deleted_at': _optIso(x.deletedAt),
      };

  static Map<String, Object?> _workRecordToRow(WorkRecord x) => {
        'id': x.id,
        'company_id': x.companyId,
        'pricing_rule_id': x.pricingRuleId, // 弱引用，允许悬空（§3.3）
        'attribution_date': _dateOnly(x.workDate),
        'mode_snapshot': x.methodSnapshot.name,
        'quantity': x.qtySnapshot,
        'quantity_unit_snapshot': x.qtyUnitSnapshot,
        'start_time': x.startTime == null ? null : _hhmm(x.startTime!),
        'end_time': x.endTime == null ? null : _hhmm(x.endTime!),
        'is_overnight': x.overnight ? 1 : 0,
        'unit_price_snapshot': x.rateSnapshot, // 分（备份 JSON 才叫 unit_price_snapshot）
        // ── 倍率明细快照：整数 ×10，与 RateSnapshot 字段一一对应 ──
        'rate_overtime_hit': x.rateDetailSnapshot.overtime ? 1 : 0,
        'rate_overtime_rate': x.rateDetailSnapshot.overtimeRate,
        'rate_weekend_hit': x.rateDetailSnapshot.weekend ? 1 : 0,
        'rate_weekend_rate': x.rateDetailSnapshot.weekendRate,
        'rate_holiday_hit': x.rateDetailSnapshot.holiday ? 1 : 0,
        'rate_holiday_rate': x.rateDetailSnapshot.holidayRate,
        'rate_applied': x.rateDetailSnapshot.appliedRate,
        // ── 金额（分）：落库即固化，更新时原样写入，绝不反算 ──
        'amount_snapshot': x.amountSnapshot,
        'amount_source': x.amountSource.name, // auto | manual
        'auto_reference': x.autoReferenceAmount,
        'currency': x.currencySnapshot,
        'note': x.note,
        'status': x.status.name, // draft | confirmed | settled
        'created_at': x.createdAt.toIso8601String(),
        'updated_at': x.updatedAt.toIso8601String(),
        'deleted_at': _optIso(x.deletedAt),
      };

  static Map<String, Object?> _paymentToRow(PaymentRecord x) => {
        'id': x.id,
        'company_id': x.companyId,
        'pay_date': _dateOnly(x.paymentDate),
        'amount': x.amount, // 分
        'method': x.method?.name, // cash | wechat | alipay | bank | other，可空
        'note': x.note,
        'created_at': x.createdAt.toIso8601String(),
        'updated_at': x.updatedAt.toIso8601String(),
        'deleted_at': _optIso(x.deletedAt),
      };

  static Map<String, Object?> _holidayToRow(HolidayMark x) => {
        'id': x.id,
        'ledger_id': x.ledgerId,
        'date': _dateOnly(x.date),
        'type': x.type.name, // statutory | working_swap | custom
        'rate': x.rate, // ×10
        'manual': x.manual ? 1 : 0,
        'created_at': x.createdAt.toIso8601String(),
      };

  // ═══════════════════════════════════════════════════════════════════════
  // 内部：六表 行 Map → 模型
  // ═══════════════════════════════════════════════════════════════════════

  static Ledger _ledgerFromRow(Map<String, Object?> r) => Ledger(
        id: _asId(r['id'], 'ledger.id'),
        name: _asString(r['name']),
        currency: _asString(r['currency'], fallback: 'CNY'),
        mode: _ledgerMode(r['mode']),
        createdAt: _dateOrNow(r['created_at']),
      );

  static Company _companyFromRow(Map<String, Object?> r) => Company(
        id: _asId(r['id'], 'company.id'),
        ledgerId: _asString(r['ledger_id']),
        name: _asString(r['name']),
        shortName: _asStringOrNull(r['short_name']),
        color: _asInt(r['tag_color']),
        defaultRuleId: _asStringOrNull(r['default_rule_id']),
        enabled: _bool(r['enabled']),
        contact: _asStringOrNull(r['contact']),
        currency: _asString(r['currency'], fallback: 'CNY'),
        note: _asStringOrNull(r['note']),
        createdAt: _dateOrNow(r['created_at']),
        updatedAt: _dateOrNow(r['updated_at']),
        deletedAt: _parseDate(r['deleted_at']),
      );

  static PricingRule _ruleFromRow(Map<String, Object?> r) => PricingRule(
        id: _asId(r['id'], 'pricing_rule.id'),
        companyId: _asString(r['company_id']),
        name: _asString(r['name']),
        method: _pricingMethod(r['method']),
        baseRate: _asInt(r['base_rate']),
        unit: _asStringOrNull(r['unit']),
        standardHours: _asDouble(r['standard_hours']),
        halfDayRatio: _asIntOr(r['half_day_ratio'], 5),
        overtimeRate: _asIntOr(r['overtime_rate'], 15),
        weekendRate: _asIntOr(r['weekend_rate'], 10),
        holidayRate: _asIntOr(r['holiday_rate'], 10),
        effectiveDate: _parseDate(r['effective_date']),
        enabled: _bool(r['enabled']),
        createdAt: _dateOrNow(r['created_at']),
        updatedAt: _dateOrNow(r['updated_at']),
        deletedAt: _parseDate(r['deleted_at']),
      );

  static WorkRecord _workRecordFromRow(Map<String, Object?> r) => WorkRecord(
        id: _asId(r['id'], 'work_record.id'),
        workDate: _dateOrNow(r['attribution_date']),
        companyId: _asString(r['company_id']),
        pricingRuleId: _asStringOrNull(r['pricing_rule_id']),
        methodSnapshot: _pricingMethod(r['mode_snapshot']),
        qtySnapshot: _asDouble(r['quantity']) ?? 0,
        qtyUnitSnapshot: _asStringOrNull(r['quantity_unit_snapshot']),
        startTime: _parseHhmm(r['start_time']),
        endTime: _parseHhmm(r['end_time']),
        overnight: _bool(r['is_overnight']),
        rateSnapshot: _asInt(r['unit_price_snapshot']),
        // 倍率明细：先取值再构造（避免构造器实参里带 ?. 的可空收窄问题）
        rateDetailSnapshot: _rateSnapshotFromRow(r),
        amountSnapshot: _asAmountColumn(r['amount_snapshot'], 'work_record.amount_snapshot'),
        amountSource: _amountSource(r['amount_source']),
        autoReferenceAmount:
            r['auto_reference'] == null ? null : _asInt(r['auto_reference']),
        currencySnapshot: _asStringOrNull(r['currency']),
        note: _asStringOrNull(r['note']),
        status: _recordStatus(r['status']),
        createdAt: _dateOrNow(r['created_at']),
        updatedAt: _dateOrNow(r['updated_at']),
        deletedAt: _parseDate(r['deleted_at']),
      );

  /// 从行 Map 还原倍率明细快照（7 个 int 列 → RateSnapshot）。
  static RateSnapshot _rateSnapshotFromRow(Map<String, Object?> r) => RateSnapshot(
        overtime: _bool(r['rate_overtime_hit']),
        overtimeRate: _asIntOr(r['rate_overtime_rate'], 10),
        weekend: _bool(r['rate_weekend_hit']),
        weekendRate: _asIntOr(r['rate_weekend_rate'], 10),
        holiday: _bool(r['rate_holiday_hit']),
        holidayRate: _asIntOr(r['rate_holiday_rate'], 10),
        appliedRate: _asIntOr(r['rate_applied'], 10),
      );

  static PaymentRecord _paymentFromRow(Map<String, Object?> r) => PaymentRecord(
        id: _asId(r['id'], 'payment_record.id'),
        paymentDate: _dateOrNow(r['pay_date']),
        companyId: _asString(r['company_id']),
        amount: _asAmountColumn(r['amount'], 'payment_record.amount'),
        method: _paymentMethod(r['method']),
        note: _asStringOrNull(r['note']),
        createdAt: _dateOrNow(r['created_at']),
        updatedAt: _dateOrNow(r['updated_at']),
        deletedAt: _parseDate(r['deleted_at']),
      );

  static HolidayMark _holidayFromRow(Map<String, Object?> r) => HolidayMark(
        id: _asId(r['id'], 'holiday_mark.id'),
        ledgerId: _asString(r['ledger_id']),
        date: _dateOrNow(r['date']),
        type: _holidayType(r['type']),
        rate: _asIntOr(r['rate'], 10),
        manual: _bool(r['manual']),
        createdAt: _dateOrNow(r['created_at']),
      );

  // ── 枚举解析（列存 .name 英文标识，保证与 Dart 枚举严格可逆、不受文案改动影响）──

  static LedgerMode _ledgerMode(dynamic v) =>
      LedgerMode.values.where((e) => e.name == v).firstOrNull ?? LedgerMode.local;

  static PricingMethod _pricingMethod(dynamic v) =>
      PricingMethod.values.where((e) => e.name == v).firstOrNull ??
      PricingMethod.hourly;

  /// 记录状态解析 —— **口径字段，兜底方向必须安全**（M-03 修复）。
  ///
  /// 无法识别的状态一律兜底为 [RecordStatus.draft]：
  /// [aggregate] / [aggregateByCompany] 只把 `confirmed`/`settled` 计入应收，
  /// 草稿**不计入**（AC-32）。因此脏状态兜底为 `draft` 只会「少算应收」（剩余偏小），
  /// **不会虚增剩余工资**。原实现兜底为 `confirmed`，会让脏数据被计入应收 → 虚增剩余，故纠正。
  static RecordStatus _recordStatus(dynamic v) =>
      RecordStatus.values.where((e) => e.name == v).firstOrNull ??
      RecordStatus.draft;

  static AmountSource _amountSource(dynamic v) =>
      AmountSource.values.where((e) => e.name == v).firstOrNull ?? AmountSource.auto;

  static PaymentMethod? _paymentMethod(dynamic v) =>
      v == null ? null : PaymentMethod.values.where((e) => e.name == v).firstOrNull;

  static HolidayType _holidayType(dynamic v) =>
      HolidayType.values.where((e) => e.name == v).firstOrNull ?? HolidayType.custom;

  // ── 数值/文本安全解析（类型异常的策略见各处 doc；口径字段禁用「虚增方向」兜底）──

  /// 宽松取整：SQLite 整数列返回 int；防御性兼容 num；无法识别时兜底 0。
  ///
  /// **用途已收窄（G-03 硬化，2026-09-30；m-04 更正举例）**：仅用于**不进入 `aggregate` 求和的
  /// 整数列**行映射。**真实调用点仅 4 处**：`company.tag_color`、`pricing_rule.base_rate`、
  /// `work_record.unit_price_snapshot`、`work_record.auto_reference`；另本文件内部用于
  /// [_assertAggregateColumnTypes] 读 `COUNT(*)`（`n`）。
  /// （注：`rate_*_rate` 列走 [_asIntOr]，**不**经本方法。）
  /// ——兜底 0 不会进入 `SUM`，**不影响剩余工资口径**（[aggregate] 只 SUM `amount_snapshot` / `amount`）。
  /// - 口径金额（`amount_snapshot` / `amount`）的**行映射**取值走 [_asAmountColumn]（非数值 / REAL 非整值抛错）；
  /// - 口径金额的**聚合求和**取值走 [_asAggregateInt]（+ 聚合前置守卫 [_assertAggregateColumnTypes]）。
  /// 故本方法**不再**用于任何口径路径（R2-02 所记「聚合路径静默兜底 0」的残留已由 G-03 + M-01 闭合）。
  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// **聚合求和专用**解析（G-03 硬化，2026-09-30）。
  ///
  /// 入参为 `SUM(金额列)` 的结果（`COALESCE(...,0)` 之后）。全表聚合**无「行」可逐行隔离**
  /// （行级隔离入口是另一条路径，见 [LenientRead] / [listWorkRecordsLenient]），
  /// 故本方法**拒绝一切会改动金额的静默兜底**，在读取点快速失败（宁可报错，不可算错）：
  /// - 非 `num`（TEXT / BLOB / NULL 等）→ 抛 [FormatException]（含列名与坏值）；
  /// - `num` 中的 REAL 非整 / `NaN` / `±Infinity` → 抛 [FormatException]
  ///   （`SUM` 一旦混入 REAL 非整值即返回 REAL；静默截断会「少算已收 → 剩余虚增」）；
  /// - 整值 REAL 但**超出 int64 范围**（`|v| >= 2^63`，如 `1e20`）→ 抛 [FormatException]
  ///   （**Minor-4**：`toInt()` 会静默钳位到 `9223372036854775807`）；
  /// - 仅「无损可转 int 且落在 int64 内」的 `num` 放行（返回 `toInt()`）。
  ///
  /// ⚠️ **分支可达性（M-01 修复后如实标注）**：`SUM()` 会把 TEXT/BLOB 洗成 `0.0`（REAL），
  /// 故在**唯一**的 SQL 聚合调用路径上，「非 `num`」分支**结构上不可达**——真正拦住
  /// TEXT/BLOB 的是**上游 SQL 侧类型前置守卫** [_assertAggregateColumnTypes]（M-01 修复，
  /// 见 [class-header] 纪律 7）。本方法的「非 `num`」分支保留为**防御性兜底**（若未来新增
  /// 非-SUM 的调用点则生效）；REAL 非整值分支则**确实可达且必需**（`SUM` 混入 REAL 非整值即返回 REAL）。
  ///
  /// 与 [_asAmountColumn]（行映射路径）策略一致：**两条口径路径都已硬化**，
  /// [aggregate] / [aggregateByCompany] 走本方法。
  static int _asAggregateInt(dynamic v, String column) {
    if (v is int) return v;
    if (v is num) {
      // 与 [_asAmountColumn] 同判据：显式纳入 isNaN/isInfinite（仅靠 truncateToDouble 无法拦 Infinity）。
      if (v is double && (v.isNaN || v.isInfinite || v != v.truncateToDouble())) {
        throw FormatException(
            '聚合列 `$column` 的 SUM 结果为非整/非法 REAL，拒绝静默截断（库可能被外部改写）：$v');
      }
      // int64 范围守卫（Minor-4，2026-10-01）：整值 double（如 `1e20`）能通过上面的「非整/NaN/Inf」
      // 检查，但 `toInt()` 对超出 int64 的 double 会**静默钳位**到 9223372036854775807（少算/失真）。
      // 判据 = `v.abs() >= 2^63`（double 无法精确表示 2^63−1，任何 ≥2^63 的 double 必然钳位）。
      if (v is double && v.abs() >= 9223372036854775808.0) {
        throw FormatException(
            '聚合列 `$column` 的 SUM 结果超出 int64 范围，拒绝静默钳位（库可能被外部改写）：$v');
      }
      return v.toInt();
    }
    throw FormatException(
        '聚合列 `$column` 的 SUM 结果为非数值类型，拒绝静默兜底（库可能被外部改写）：$v');
  }

  /// **金额口径列专用**解析（M-03 修复；R2-04 硬化）。
  ///
  /// `amount_snapshot` / `amount` 为 `INTEGER NOT NULL`（SQLite **INTEGER 亲和，非 STRICT**）。
  /// 正常路径只会返回 `int`（INTEGER 亲和列对**可无损转 int** 的 REAL 也会存成 int）；异常分支：
  /// - **非 `num` 类型**（文本 `'abc'` / BLOB / NULL）→ **抛 [FormatException]**，不做静默兜底。
  /// - **`num` 中的 REAL 非整 / 非法值**（`24000.7` / `NaN` / `±Infinity`）→ **抛 [FormatException]**
  ///   （R2-04 硬化）。理由：截断 `payment_record.amount` 会**少算「已收」→ 剩余虚增**（本项目唯一
  ///   不可容忍的方向）；放行 REAL 与本方法「拒绝静默兜底」的契约自相矛盾。
  /// - **整值 REAL 但超出 int64 范围**（`|v| >= 2^63`，如 `1e20`）→ **抛 [FormatException]**
  ///   （**Minor-4**：`toInt()` 会静默钳位到 `9223372036854775807`，同样「少算已收 → 剩余虚增」）。
  /// - **仅无损可转 int 且落在 int64 内**的 `num`（`int` / `24000.0`）→ 返回 `toInt()`。
  /// 统一「宁可报错，不可算错」，让脏值在**读取点**暴露；抛错消息含**列名 `$column` 与坏值 `$v`**
  /// 便于定位。注：本硬化会略扩「单行脏值 → 整表读崩溃」的面（`rows.map` 冒泡），已登记 **I-9**；
  /// **G-02（2026-09-30）已提供行级隔离入口**（[listWorkRecordsLenient] / [listPaymentRecordsLenient]，
  /// 坏行跳过并收集、不上抛），需要「跳过坏行、读健康行」的调用方改走该入口即可。
  static int _asAmountColumn(dynamic v, String column) {
    if (v is int) return v;
    if (v is num) {
      // REAL 非整/非法值拒绝静默截断：截断 payment_record.amount 会少算「已收」→ 剩余虚增。
      // （`isNaN`/`isInfinite` 显式纳入：`Infinity.truncateToDouble() == Infinity`，仅靠
      //   `!= truncateToDouble()` 无法拦 Infinity，会漏到 `toInt()` 抛 UnsupportedError。）
      if (v is double && (v.isNaN || v.isInfinite || v != v.truncateToDouble())) {
        throw FormatException(
            '金额列 `$column` 为非整/非法 REAL，拒绝静默截断（可能库损坏或被外部改写）：$v');
      }
      // int64 范围守卫（Minor-4，2026-10-01）：整值 double（如 `1e20`）通过上面的「非整/NaN/Inf」
      // 检查后，`toInt()` 会**静默钳位**到 9223372036854775807。金额列钳位会**少算「已收」→
      // 剩余虚增**（本项目唯一不可容忍方向），故显式拒绝。
      if (v is double && v.abs() >= 9223372036854775808.0) {
        throw FormatException(
            '金额列 `$column` 超出 int64 范围，拒绝静默钳位（可能库损坏或被外部改写）：$v');
      }
      return v.toInt();
    }
    throw FormatException('金额列 `$column` 非数值类型，拒绝静默兜底（可能库损坏或被外部改写）：$v');
  }

  /// 文本列守卫（M-04 修复）：同文件内数值列已有 `_asInt`/`_asDouble` 守卫，
  /// 文本列不应裸 `as String` cast（类型不符会抛 `TypeError`，且无统一策略）。
  ///
  /// 策略：`String` 原样返回；`null` 用 [fallback]；其它类型 `toString()` 兜底转换
  /// （导入的脏文件里常见数字 id / 数字备注，转成文本可读入并在上层次校验中暴露，
  /// 优于直接读取失败）。空串不在此处拦截——主键另有 [_asId] 严格把关。
  static String _asString(dynamic v, {String fallback = ''}) {
    if (v is String) return v;
    if (v == null) return fallback;
    return v.toString();
  }

  /// 可空文本列守卫（M-04 修复）：`null` 保持 `null`（语义是"字段未填"），
  /// 非 `String` 非 null 时 `toString()` 兜底（理由同 [_asString]）。
  static String? _asStringOrNull(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    return v.toString();
  }

  /// 主键列守卫（M-04 修复）：`id` 是 `TEXT PRIMARY KEY`。
  /// 空串会在写入时触发主键/唯一约束异常、在读取时把记录"粘"到同一 id 上，
  /// 是比类型不符更隐蔽的损坏。故**空串直接抛错**（失败点前移且可定位），
  /// 而不是静默返回空串。
  static String _asId(dynamic v, String column) {
    final s = _asString(v);
    if (s.isEmpty) {
      throw FormatException('主键列 `$column` 为空，拒绝静默兜底（记录无法定位）');
    }
    return s;
  }

  static int _asIntOr(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return fallback;
  }

  static double? _asDouble(dynamic v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return null;
  }
}
