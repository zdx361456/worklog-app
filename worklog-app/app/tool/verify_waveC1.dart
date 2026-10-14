/// Wave C1（统计与设置）自验证脚本 —— **DB 行为层 + 静态断言层**。
///
/// **证据层级三分（DECISIONS D-8）——先读本段，不要误读下面的输出**：
///
/// 【实测级 / 强证据】§1~§4（DB 行为层）：
///   全部走**真实 `AppDatabase`（内存库）**，对真实数据断言：
///   · §1 统计源口径：`listWorkRecords(includeDraft:false)` **排除草稿与软删**，且
///         `Σ amountSnapshot == aggregate(null).receivable`（逐条等价，`02 §C.1.4:210`）；
///   · §2 一致性：`aggregate(null).remaining == Σ aggregateByCompany().remaining`
///         （`07 §1.8` 规则 3 / AC-33）；
///   · §3 四维分组合计 == 总额；**按公司 == `aggregateByCompany().receivable`**（AC-P11-03）；
///         按计价方式 == `methodSnapshot` 归集（AC-P11-04 / AC-38）；**真·跨年**（2026-12-31 / 2027-01-01）；
///   · §4 节假日快照纪律：加/改/删节假日标记**不改动任何既有 work_record 快照**（AC-51）；
///         以及 G-13 id 漂移/不漂移实测。
///
/// 【实测级 / 强证据】§6（静态断言层，**读真实源码文件 + 结构切片**）：
///   直接 `File.readAsStringSync` 读 `lib/ui/*.dart` 与 `lib/db/database_schema.dart`、
///   `lib/app/routes.dart` 的**真实源码**（非复刻、非转述），断言：
///   S1 浮点禁令（4 页零命中，豁免 stats_page 布局比例行**按子串剔除**）；
///   S2 注释剥离（整行+行尾）；S3 四页外壳/构造签名保留；S4 六表 + **逐表列集合快照**；
///   S5 五入口接线（**锚定 tile 的 `onTap` + `_openXxx` 方法体**，非整文件 contains）；
///   S6 关键文案逐字；S7 默认倍率来源；S9 P11 结构 + `.map` 映射 + **剥注释后**口径；
///   S10 **MAJ-2「失败不丢输入」结构断言**（`pop` 在 `if (err == null)` 块体内、else 失败分支不含）；
///   S11 P11 页内**分组/时间键真身**（`_ymKey`/`_ymdKey`/`_formatDate`/`_computeRows`/`_groupedRows`）；
///   S12 AC 覆盖缺口补断言（AC-P11-02 红字+不查询 / AC-P12-05 币种只读 / AC-P12-06 页内三分支 / 降级黄条）。
///
/// 【源码结构级 / 中证据】§5 + §11（页内逻辑，**加固后取代原同构复刻**）：
///   页内 `_computeRows()` / `_rateText()` / `_parseRateX10()` 是 `lib/ui/*` 的**私有**成员，
///   脚本**拿不到、无法调用**。加固后**不再自写复刻**，改为经**括号/字符串/注释感知切片**
///   提取页内**真身源码片段**并断其**结构**（`~/ 10` 而非 `~/ 100`、拒 >1 位小数、
///   月/日分支分别用 `_ymKey`/`_ymdKey`、降序排序）。
///   ⚠️ 仍**非运行时实测**（私有函数未真正执行）→ 数值语义由结构约束间接保证。
///
/// 【不覆盖】页内交互/切维/红字/滚动/行点击跳 P07/二次确认弹窗/三态视觉/降级黄条渲染
///   —— 属 **[真机]** 档，由末次出包真机验收，本脚本**不替代**。
///
/// 运行（**必须两项齐全，缺一报 `CreateFile failed 231`**）：
/// ```
/// cd C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app
/// set WORKLOG_USE_SYSTEM_SQLITE=1
/// "D:\workspace\software\installed\tools\FlyEnv-Data\app\flutter\3.47.4\bin\cache\dart-sdk\bin\dart.exe" --disable-dart-dev tool\verify_waveC1.dart
/// ```
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/db/database.dart';
import '../lib/models/company.dart';
import '../lib/models/holiday_mark.dart';
import '../lib/models/ledger.dart';
import '../lib/models/payment_record.dart';
import '../lib/models/types.dart';
import '../lib/models/work_record.dart';

int _pass = 0;
int _fail = 0;

void _ok(String label) {
  _pass++;
  print('  [PASS] $label');
}

void _bad(String label, String detail) {
  _fail++;
  print('  [FAIL] $label');
  print('         -> $detail');
}

void _check(bool cond, String label, String detail) {
  if (cond) {
    _ok(label);
  } else {
    _bad(label, detail);
  }
}

// ── 与 tool/verify_db.dart 同源的 Windows 兜底（预加载系统 SQLite）──────────
void _maybePreloadSystemSqlite() {
  if (!Platform.isWindows) return;
  if (Platform.environment['WORKLOG_USE_SYSTEM_SQLITE'] != '1') return;
  for (final name in ['sqlite3.dll', 'winsqlite3.dll']) {
    try {
      DynamicLibrary.open(name);
      print('  · 已预加载系统 SQLite 动态库：$name');
      return;
    } catch (_) {
      // 继续尝试下一个
    }
  }
  print('  ! 未能预加载任何系统 SQLite 动态库');
}

// ── 时间键（与 lib/ui/stats_page.dart 的 `_ymKey`/`_ymdKey` **同构复刻**，读码级）──
String _ymKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

String _ymdKey(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

// ⚠️ **已移除**原「逐字复刻 `rateText` / `parseRateX10`」两份**同构副本**：
//    审计实测它们对"改坏页内真身"**天然恒真**（假覆盖）。§5 已改为**读页内真身源码**断言
//    （见 main() 的 `[5]` 与 `_exprBody` / `_methodBody`）——属**收紧转换**，非删除断言。

// ── 静态断言层工具（读真实源码）────────────────────────────────────────────
String _read(String relPath) {
  final f = File(relPath);
  if (!f.existsSync()) return '';
  return f.readAsStringSync();
}

/// 剥离注释：**整行注释与行尾注释都要剥**（`(^|\s)//.*$`，multiLine）。
/// ⚠️ 本项目已有一次「只剥整行注释 → 把 `code(); // 说明` 当用户可见文案」的**假阳性**教训，
///    故此处同时处理行尾注释（`verify_waveA2.dart` 第 5 节同款）。
final RegExp _commentRe = RegExp(r'(^|\s)//.*$', multiLine: true);

String _stripComments(String src) => src.replaceAll(_commentRe, '');

/// 浮点禁令：返回命中的模式名清单（已剥离注释）。
List<String> _floatViolations(String code) {
  final out = <String>[];
  final banned = <String, RegExp>{
    'fen/100': RegExp(r'fen\s*/\s*100'),
    'double.parse': RegExp(r'double\.parse'),
    '.round(': RegExp(r'\.round\s*\('),
    '.toDouble(': RegExp(r'\.toDouble\s*\('),
  };
  banned.forEach((name, re) {
    if (re.hasMatch(code)) out.add(name);
  });
  // 浮点 `/ 10`（排除整数除法 `~/ 10`）：逐匹配检查前一个字符非 `~`。
  final re10 = RegExp(r'/\s*10\b');
  for (final m in re10.allMatches(code)) {
    final before = m.start > 0 ? code[m.start - 1] : '';
    if (before != '~') {
      out.add('/10(float)');
      break;
    }
  }
  return out;
}

// ── 源码结构切片工具（**括号 / 字符串 / 注释感知**，供页内真身断言）──────────────
// ⚠️ 朴素括号配平会被 Dart 字符串插值 `'${...}'` 与行尾注释里的括号骗到（`stats_page._ymKey`
//    及 `_formatDate` 即含 `'${d.year...}'`）→ 以下工具**先跳过注释与字符串字面量**再配平，
//    确保切片落在真实代码结构上。

/// 跳过 [src] 中自 [i] 起的一个字符串字面量（含 `'`/`"`、转义、`${...}` 插值），
/// 返回字符串结束后的索引。
int _skipString(String src, int i) {
  final quote = src[i];
  var j = i + 1;
  while (j < src.length) {
    final c = src[j];
    if (c == '\\') {
      j += 2;
      continue;
    }
    if (c == r'$' && j + 1 < src.length && src[j + 1] == '{') {
      var depth = 1;
      j += 2; // 越过 '${'
      while (j < src.length && depth > 0) {
        final ch = src[j];
        if (ch == '"' || ch == "'") {
          j = _skipString(src, j);
          continue;
        }
        if (ch == '{') {
          depth++;
        } else if (ch == '}') {
          depth--;
        }
        j++;
      }
      continue;
    }
    if (c == quote) return j + 1;
    j++;
  }
  return src.length;
}

/// 从 [openIdx]（指向 `(` / `{` / `[`）起做**注释 / 字符串感知**的括号配平，
/// 返回含首尾括号的完整片段；未配平 → `null`。
String? _wireSlice(String src, int openIdx) {
  if (openIdx < 0 || openIdx >= src.length) return null;
  final open = src[openIdx];
  final close = open == '{' ? '}' : (open == '(' ? ')' : (open == '[' ? ']' : ''));
  if (close.isEmpty) return null;
  var depth = 0;
  var i = openIdx;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      i = _skipString(src, i);
      continue;
    }
    if (c == open) {
      depth++;
      i++;
      continue;
    }
    if (c == close) {
      depth--;
      i++;
      if (depth == 0) return src.substring(openIdx, i);
      continue;
    }
    i++;
  }
  return null;
}

/// 提取方法/函数名 [name] 的**块体**（含外层 `{ … }`）。先配平跳过参数列表
/// （支持具名参数 `{…}`），再跳过 `async`。表达式体（`=> …`）或未找到 → `null`。
String? _methodBody(String src, String name) {
  final re = RegExp(r'\b' + RegExp.escape(name) + r'\s*\(');
  for (final m in re.allMatches(src)) {
    final open = m.end - 1; // '('
    final params = _wireSlice(src, open);
    if (params == null) continue;
    var j = open + params.length;
    void skipWs() {
      while (j < src.length && ' \t\r\n'.contains(src[j])) {
        j++;
      }
    }

    skipWs();
    if (j + 5 <= src.length && src.substring(j, j + 5) == 'async') {
      j += 5;
      skipWs();
    }
    if (j < src.length && src[j] == '{') return _wireSlice(src, j);
  }
  return null;
}

/// 提取方法/函数名 [name] 的**表达式体**（`=> …` 到 `;`，不含 `;`）。块体 / 未找到 → `null`。
String? _exprBody(String src, String name) {
  final re = RegExp(r'\b' + RegExp.escape(name) + r'\s*\(');
  for (final m in re.allMatches(src)) {
    final open = m.end - 1;
    final params = _wireSlice(src, open);
    if (params == null) continue;
    var j = open + params.length;
    while (j < src.length && ' \t\r\n'.contains(src[j])) {
      j++;
    }
    if (j + 1 < src.length && src[j] == '=' && src[j + 1] == '>') {
      j += 2;
      var k = j;
      while (k < src.length) {
        final c = src[k];
        if (c == '"' || c == "'") {
          k = _skipString(src, k);
          continue;
        }
        if (c == ';') return src.substring(j, k);
        k++;
      }
      return src.substring(j);
    }
  }
  return null;
}

/// 按标题文本 `Text('<titleText>')` 定位其所属 `ListTile( … )` 片段（含 `title` 与 `onTap`）；
/// 定位不到 → `null`。**用于把"入口接线"断言锚定到具体 tile**，而非整文件 `contains`。
String? _tileBlockByTitle(String src, String titleText) {
  final ti = src.indexOf("Text('$titleText')");
  if (ti < 0) return null;
  final li = src.lastIndexOf('ListTile(', ti);
  if (li < 0) return null;
  return _wireSlice(src, src.indexOf('(', li));
}

int _countOccurrences(String src, String sub) {
  if (sub.isEmpty) return 0;
  var n = 0;
  var i = 0;
  while (true) {
    final k = src.indexOf(sub, i);
    if (k < 0) break;
    n++;
    i = k + sub.length;
  }
  return n;
}

/// 解析 `CREATE TABLE IF NOT EXISTS <table> (…)` 的**列名集合**（跳过约束行与 `--` 注释）。
Set<String> _tableColumns(String schemaSrc, String table) {
  final m = RegExp('CREATE TABLE IF NOT EXISTS\\s+' + RegExp.escape(table) + r'\s*\(')
      .firstMatch(schemaSrc);
  if (m == null) return <String>{};
  final block = _wireSlice(schemaSrc, schemaSrc.indexOf('(', m.start));
  if (block == null) return <String>{};
  final inner = block.substring(1, block.length - 1);
  final out = <String>{};
  for (var line in inner.split('\n')) {
    line = line.split('--').first.trim();
    if (line.isEmpty) continue;
    final tok = RegExp(r'^([A-Za-z_]\w*)').firstMatch(line)?.group(1);
    if (tok == null) continue;
    if (const {'UNIQUE', 'PRIMARY', 'FOREIGN', 'CHECK', 'CONSTRAINT'}
        .contains(tok.toUpperCase())) {
      continue;
    }
    out.add(tok);
  }
  return out;
}

/// S10 结构断言：MAJ-2「失败不丢输入」。
/// 断言：① 文件含必要符号；② [method] 体含 `if (err == null) {…}`；③ 该 **if 块体内**含
/// `Navigator.of(context).pop`；④ **else（失败）分支不含** pop；⑤ 全方法体内 pop **恰 1 处**
/// （防"pop 移出 if 但仍在法体内"）。原实现为跨 `{}` 的弱正则"同现即真"，此处改为括号配平结构断言。
void _checkS10({
  required String label,
  required String src,
  required String method,
  required List<String> extraNeedles,
}) {
  final body = _methodBody(src, method);
  final missNeedles = extraNeedles.where((n) => !src.contains(n)).toList();
  if (body == null || missNeedles.isNotEmpty) {
    _bad(label, '方法体未定位或缺符号：method=$method 缺失=$missNeedles');
    return;
  }
  const cond = 'if (err == null)';
  final ci = body.indexOf(cond);
  if (ci < 0) {
    _bad(label, '未找到 `$cond`');
    return;
  }
  final braceIdx = body.indexOf('{', ci + cond.length);
  if (braceIdx < 0) {
    _bad(label, '`$cond` 后未找到块体 `{`');
    return;
  }
  final ifBlock = _wireSlice(body, braceIdx);
  if (ifBlock == null) {
    _bad(label, '`$cond` 块体未配平');
    return;
  }
  final popInIf = ifBlock.contains('Navigator.of(context).pop');
  var k = braceIdx + ifBlock.length;
  while (k < body.length && ' \t\r\n'.contains(body[k])) {
    k++;
  }
  String? elseBlock;
  if (k + 4 <= body.length && body.substring(k, k + 4) == 'else') {
    final eb = body.indexOf('{', k);
    if (eb >= 0) elseBlock = _wireSlice(body, eb);
  }
  final popInElse =
      elseBlock != null && elseBlock.contains('Navigator.of(context).pop');
  final popTotal = _countOccurrences(body, 'Navigator.of(context).pop');
  if (popInIf && !popInElse && popTotal == 1) {
    _ok(label);
  } else {
    _bad(label,
        'pop在if块内=$popInIf pop在else失败分支=$popInElse 方法体pop总数=$popTotal（须 1）');
  }
}

// ── 播种标识 ─────────────────────────────────────────────────────────────
const _ledgerId = 'c1000000-0000-4000-8000-000000000001';
const _cidA = 'c1000000-0000-4000-8000-00000000000a';
const _cidB = 'c1000000-0000-4000-8000-00000000000b';
final _t0 = DateTime(2026, 10, 1, 9, 0);

WorkRecord _wr({
  required String id,
  required String companyId,
  required PricingMethod method,
  required int amount,
  required DateTime date,
  RecordStatus status = RecordStatus.confirmed,
}) =>
    WorkRecord(
      id: id,
      workDate: date,
      companyId: companyId,
      methodSnapshot: method,
      qtySnapshot: 1,
      rateSnapshot: amount,
      rateDetailSnapshot: const RateSnapshot(appliedRate: 10),
      amountSnapshot: amount,
      amountSource: AmountSource.auto,
      status: status,
      createdAt: date,
      updatedAt: date,
    );

Future<void> main() async {
  print('══════════════════════════════════════════════');
  print('Wave C1 · 统计与设置 · 自验证（DB 行为层 + 静态断言层）');
  print('══════════════════════════════════════════════');
  _maybePreloadSystemSqlite();
  sqfliteFfiInit();
  final db = AppDatabase.instance
    ..configureForTest(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  await db.open();

  // ── 播种 ────────────────────────────────────────────────────────────
  await db.upsertLedger(Ledger(id: _ledgerId, name: '我的账本', createdAt: _t0));
  await db.upsertCompany(Company(
      id: _cidA, ledgerId: _ledgerId, name: '甲建筑', color: 0xE53935, createdAt: _t0, updatedAt: _t0));
  await db.upsertCompany(Company(
      id: _cidB, ledgerId: _ledgerId, name: '乙劳务', color: 0x1565C0, createdAt: _t0, updatedAt: _t0));

  // 非草稿、非软删（计入应收）：
  await db.upsertWorkRecord(_wr(id: 'w1', companyId: _cidA, method: PricingMethod.hourly, amount: 100000, date: DateTime(2026, 10, 1)));
  await db.upsertWorkRecord(_wr(id: 'w2', companyId: _cidA, method: PricingMethod.daily, amount: 50000, date: DateTime(2026, 10, 5)));
  await db.upsertWorkRecord(_wr(id: 'w3', companyId: _cidB, method: PricingMethod.hourly, amount: 30000, date: DateTime(2026, 11, 2)));
  await db.upsertWorkRecord(_wr(id: 'w5', companyId: _cidB, method: PricingMethod.piece, amount: 40000, date: DateTime(2026, 12, 31)));
  // 真·跨年：2027-01-01（跨自然年边界）：
  await db.upsertWorkRecord(_wr(id: 'w8', companyId: _cidA, method: PricingMethod.hourly, amount: 8000, date: DateTime(2027, 1, 1)));
  // 草稿（不计入应收）：
  await db.upsertWorkRecord(_wr(id: 'w4', companyId: _cidA, method: PricingMethod.hourly, amount: 20000, date: DateTime(2026, 10, 3), status: RecordStatus.draft));
  // 先建后软删（不计入应收）：
  await db.upsertWorkRecord(_wr(id: 'w6', companyId: _cidA, method: PricingMethod.hourly, amount: 7000, date: DateTime(2026, 10, 10)));
  await db.softDeleteWorkRecord('w6', DateTime(2026, 10, 11));

  // 收款（用于 remaining 断言）：
  await db.upsertPaymentRecord(PaymentRecord(
      id: 'p1', paymentDate: DateTime(2026, 10, 6), companyId: _cidA, amount: 20000,
      method: PaymentMethod.wechat, createdAt: _t0, updatedAt: _t0));

  const expectedReceivable = 100000 + 50000 + 30000 + 40000 + 8000; // 228000
  const expectedA = 158000; // 100000 + 50000 + 8000（w4 草稿 / w6 软删 均不计）
  const expectedB = 70000;  // 30000 + 40000

  // ── §1 统计源口径（实测级）────────────────────────────────────────────
  print('\n[1] 统计源口径：排除草稿与软删 + 与 aggregate 逐条等价');
  final records = await db.listWorkRecords(includeDraft: false);
  final ids = records.map((r) => r.id).toSet();
  _check(!ids.contains('w4'), '草稿 w4 被排除（AC-32）', '仍含 w4：$ids');
  _check(!ids.contains('w6'), '软删 w6 被排除', '仍含 w6：$ids');
  _check(ids.length == 5, '统计源恰 5 条（w1/w2/w3/w5/w8）', '实际 ${ids.length} 条：$ids');
  final recordSum = records.fold<int>(0, (s, r) => s + r.amountSnapshot);
  _check(recordSum == expectedReceivable,
      'Σ listWorkRecords(includeDraft:false).amountSnapshot == 228000', '实际 $recordSum');

  final aggAll = await db.aggregate(null);
  _check(aggAll.receivable == expectedReceivable,
      'aggregate(null).receivable == 228000（与统计源逐条等价）', '实际 ${aggAll.receivable}');

  final recordsInclDraft = await db.listWorkRecords(includeDraft: true);
  _check(recordsInclDraft.length == 6,
      'includeDraft:true 时含草稿（6 条）→ 证明 includeDraft:false 确实排草稿', '实际 ${recordsInclDraft.length}');

  // ── §2 一致性（实测级，AC-33 / 07 §1.8 规则 3）───────────────────────
  print('\n[2] 一致性：aggregate(null).remaining == Σ aggregateByCompany().remaining');
  final byCompanyAgg = await db.aggregateByCompany();
  final sumRemaining = byCompanyAgg.fold<int>(0, (s, a) => s + a.remaining);
  _check(aggAll.remaining == sumRemaining,
      'aggregate(null).remaining(${aggAll.remaining}) == Σ aggregateByCompany().remaining($sumRemaining)',
      '不等 → 违 AC-33');
  final sumReceivable = byCompanyAgg.fold<int>(0, (s, a) => s + a.receivable);
  _check(sumReceivable == expectedReceivable,
      'Σ aggregateByCompany().receivable == 228000', '实际 $sumReceivable');

  // ── §3 四维分组（实测级数据 + 同构分组键）──────────────────────────────
  print('\n[3] 四维分组：合计 == 总额（AC-37）；按公司 == A2 应收（AC-P11-03）');

  final aById = {for (final a in byCompanyAgg) a.companyId: a};
  _check(aById[_cidA]?.receivable == expectedA,
      '按公司 · 甲建筑 应收 == 158000', '实际 ${aById[_cidA]?.receivable}');
  _check(aById[_cidB]?.receivable == expectedB,
      '按公司 · 乙劳务 应收 == 70000', '实际 ${aById[_cidB]?.receivable}');
  final companyDimTotal = aById.values.fold<int>(0, (s, a) => s + a.receivable);
  _check(companyDimTotal == expectedReceivable, '按公司维度合计 == 228000（== 总额）', '实际 $companyDimTotal');

  // 3.2 按月（含真·跨年 2026-12 / 2027-01）
  final byMonth = <String, int>{};
  for (final r in records) {
    final k = _ymKey(r.workDate);
    byMonth[k] = (byMonth[k] ?? 0) + r.amountSnapshot;
  }
  _check(byMonth['2026-10'] == 150000, '按月 · 2026-10 == 150000', '实际 ${byMonth['2026-10']}');
  _check(byMonth['2026-11'] == 30000, '按月 · 2026-11 == 30000', '实际 ${byMonth['2026-11']}');
  _check(byMonth['2026-12'] == 40000, '按月 · 2026-12 == 40000（跨年左界）', '实际 ${byMonth['2026-12']}');
  _check(byMonth['2027-01'] == 8000, '按月 · 2027-01 == 8000（**跨自然年** 2027-01-01）', '实际 ${byMonth['2027-01']}');
  _check(byMonth.values.fold<int>(0, (s, v) => s + v) == expectedReceivable,
      '按月维度合计 == 228000', '实际 ${byMonth.values.fold<int>(0, (s, v) => s + v)}');

  // 3.3 按时间段（同构分组键 _ymdKey，日粒度）
  final rangeStart = DateTime(2026, 10, 1);
  final rangeEnd = DateTime(2026, 10, 31);
  final inRange = records.where((r) {
    final d = DateTime(r.workDate.year, r.workDate.month, r.workDate.day);
    return !d.isBefore(rangeStart) && !d.isAfter(rangeEnd);
  }).toList();
  final byDay = <String, int>{};
  for (final r in inRange) {
    final k = _ymdKey(r.workDate);
    byDay[k] = (byDay[k] ?? 0) + r.amountSnapshot;
  }
  _check(byDay['2026-10-01'] == 100000, '按时间段 · 2026-10-01 == 100000', '实际 ${byDay['2026-10-01']}');
  _check(byDay['2026-10-05'] == 50000, '按时间段 · 2026-10-05 == 50000', '实际 ${byDay['2026-10-05']}');
  _check(byDay.values.fold<int>(0, (s, v) => s + v) == 150000,
      '按时间段 [2026-10-01,2026-10-31] 合计 == 150000', '实际 ${byDay.values.fold<int>(0, (s, v) => s + v)}');
  // **真·跨年区间** [2026-12-01, 2027-01-31]：20 26-12-31(40000) + 2027-01-01(8000)
  final crossYear = records.where((r) {
    final d = DateTime(r.workDate.year, r.workDate.month, r.workDate.day);
    return !d.isBefore(DateTime(2026, 12, 1)) && !d.isAfter(DateTime(2027, 1, 31));
  }).fold<int>(0, (s, r) => s + r.amountSnapshot);
  _check(crossYear == 48000,
      '时间段跨自然年 [2026-12-01,2027-01-31] 合计 == 48000（40000 + 8000）', '实际 $crossYear');

  // 3.4 按计价方式（methodSnapshot 归集，AC-38）
  final byMethod = <PricingMethod, int>{};
  for (final r in records) {
    byMethod[r.methodSnapshot] = (byMethod[r.methodSnapshot] ?? 0) + r.amountSnapshot;
  }
  _check(byMethod[PricingMethod.hourly] == 138000,
      '按计价方式 · 时价 == 138000（100000 + 30000 + 8000）', '实际 ${byMethod[PricingMethod.hourly]}');
  _check(byMethod[PricingMethod.daily] == 50000, '按计价方式 · 日价 == 50000', '实际 ${byMethod[PricingMethod.daily]}');
  _check(byMethod[PricingMethod.piece] == 40000, '按计价方式 · 计件 == 40000', '实际 ${byMethod[PricingMethod.piece]}');
  _check(byMethod.values.fold<int>(0, (s, v) => s + v) == expectedReceivable,
      '按计价方式维度合计 == 228000（AC-38：分段归集，合计仍等于总额）',
      '实际 ${byMethod.values.fold<int>(0, (s, v) => s + v)}');

  // ── §4 节假日标记：快照纪律 + G-13 id 行为（实测级）────────────────────
  print('\n[4] 节假日标记：只影响新建（快照纪律 AC-51）+ G-13 id 行为');

  final beforeSnapshot = (await db.getWorkRecord('w1'))!.amountSnapshot;
  await db.upsertHolidayMark(HolidayMark(
      id: 'hm1', ledgerId: _ledgerId, date: DateTime(2026, 10, 1),
      type: HolidayType.statutory, rate: 30, createdAt: _t0));
  final afterSnapshot = (await db.getWorkRecord('w1'))!.amountSnapshot;
  _check(beforeSnapshot == afterSnapshot && afterSnapshot == 100000,
      '加节假日标记后，既有记录 w1 快照不变（= 100000）→ 只影响以后新建',
      'before=$beforeSnapshot after=$afterSnapshot');

  final byDate = await db.getHolidayMarkByDate(_ledgerId, DateTime(2026, 10, 1));
  _check(byDate != null && byDate.rate == 30,
      'getHolidayMarkByDate 命中标记（rate=30）', '结果 $byDate');

  await db.upsertHolidayMark(HolidayMark(
      id: 'hm2', ledgerId: _ledgerId, date: DateTime(2026, 10, 1),
      type: HolidayType.custom, rate: 20, createdAt: _t0));
  final oldGone = await db.getHolidayMark('hm1');
  final newPresent = await db.getHolidayMark('hm2');
  _check(oldGone == null && newPresent != null && newPresent.rate == 20,
      'G-13 实测：upsert 同 (ledger,date) 新 id → 旧 id 消失、新 id 生效（id 漂移）',
      'old=$oldGone new=$newPresent');

  await db.updateHolidayMark(HolidayMark(
      id: 'hm2', ledgerId: _ledgerId, date: DateTime(2026, 10, 1),
      type: HolidayType.workingSwap, rate: 15, createdAt: _t0));
  final afterEdit = await db.getHolidayMark('hm2');
  _check(afterEdit != null && afterEdit.id == 'hm2' && afterEdit.rate == 15 &&
      afterEdit.type == HolidayType.workingSwap,
      '编辑走 updateHolidayMark → id 保持 hm2、内容更新（id 不漂移）',
      '结果 $afterEdit');

  await db.deleteHolidayMark('hm2');
  final afterDelete = await db.getHolidayMark('hm2');
  _check(afterDelete == null, 'deleteHolidayMark 为硬删（查无此标记）', '结果 $afterDelete');
  final listAfter = await db.listHolidayMarks(ledgerId: _ledgerId);
  _check(listAfter.isEmpty, '删除后 listHolidayMarks 为空', '实际 ${listAfter.length} 条');

  final finalSnapshot = (await db.getWorkRecord('w1'))!.amountSnapshot;
  _check(finalSnapshot == 100000, '节假日增/改/删全程 w1 快照恒定 100000', '实际 $finalSnapshot');

  await db.close();

  // ── §5 倍率显示 / 解析（**读页内真身源码**断言 —— 原为同构复刻，已按审计 MAJOR 4 加固）──
  // 原 9 条断言的是脚本**自写副本**（`rateText` / `parseRateX10`），对"改坏页内真身"**恒真**。
  // 现改为：提取 `holiday_mark_page.dart` 内 `_rateText` / `_parseRateX10` **真身片段**并断其结构。
  // 覆盖点逐条迁移（映射见加固报告）——属**收紧**，非删除。页内为私有函数 → 仍非运行时实测。
  print('\n[5] 倍率 显示/解析（读 holiday_mark_page.dart **真身源码**断言，非复刻）');
  final holPageRaw = _read('lib/ui/holiday_mark_page.dart');
  final holPageCode = _stripComments(holPageRaw);
  final rateTextBody = _exprBody(holPageCode, '_rateText');
  final parseBody = _methodBody(holPageCode, '_parseRateX10');

  _check(
      rateTextBody != null &&
          rateTextBody.contains('~/ 10') &&
          rateTextBody.contains('% 10'),
      'S5-1 `_rateText` 真身 == 整数 `~/ 10` + `% 10`（覆盖原 rateText(30)=="3.0"）',
      'body=${rateTextBody ?? '未定位'}');
  _check(rateTextBody != null && !rateTextBody.contains('~/ 100'),
      'S5-2 `_rateText` 真身**无** `~/ 100`（防十位错切；覆盖原 rateText(10)=="1.0"）',
      'body=${rateTextBody ?? '未定位'}');
  _check(rateTextBody != null && _floatViolations(rateTextBody).isEmpty,
      'S5-3 `_rateText` 真身**零浮点**（无 `/ 10`、无 double；覆盖原 rateText(15)=="1.5"）',
      '浮点命中=${rateTextBody == null ? 'n/a' : _floatViolations(rateTextBody)}');

  _check(parseBody != null && parseBody.contains("split('.')"),
      'S5-4 `_parseRateX10` 真身按 `.` 拆分（覆盖原 parseRateX10("3.0")==30）',
      'body=${parseBody ?? '未定位'}');
  _check(parseBody != null && parseBody.contains('yuan * 10 + tenth'),
      'S5-5 `_parseRateX10` 真身整数合成 `yuan * 10 + tenth`（覆盖原 parseRateX10("2.5")==25）',
      'body=${parseBody ?? '未定位'}');
  _check(parseBody != null && parseBody.contains('int.tryParse'),
      'S5-6 `_parseRateX10` 真身 `int.tryParse`（禁 double.parse；覆盖原 parseRateX10("1")==10）',
      'body=${parseBody ?? '未定位'}');
  _check(
      parseBody != null &&
          RegExp(r'length\s*>\s*1').hasMatch(parseBody) &&
          parseBody.contains('null'),
      'S5-7 `_parseRateX10` 真身**拒 >1 位小数**（覆盖原 parseRateX10("1.25")==null）',
      'body=${parseBody ?? '未定位'}');
  _check(parseBody != null && RegExp(r't\.isEmpty').hasMatch(parseBody),
      'S5-8 `_parseRateX10` 真身**空串拒**（覆盖原 parseRateX10("")==null）',
      'body=${parseBody ?? '未定位'}');
  _check(
      parseBody != null &&
          parseBody.contains('_isDigits') &&
          _methodBody(holPageCode, '_isDigits') != null,
      'S5-9 `_parseRateX10` 真身调 `_isDigits` 拒非数字（覆盖原 parseRateX10("a")==null）',
      'body=${parseBody ?? '未定位'}');

  // ── §6 静态断言层 S1~S10（读**真实源码**，非复刻）──────────────────────
  _staticLayer();

  print('\n──────────────────────────────────────────────');
  print('结果：$_pass 通过 / $_fail 失败');
  print('──────────────────────────────────────────────');
  print('【不覆盖】页内交互/切维/红字/滚动/行点击/二次确认/三态 → [真机] 档，本脚本不替代。');
  if (_fail > 0) exit(1);
}

/// 静态断言层：读**真实源码文件** + 正则断言（非复刻、非转述）。
void _staticLayer() {
  print('\n[6] 静态断言层 S1~S10（读真实源码：lib/ui/*.dart + schema + routes）');

  final statsRaw = _read('lib/ui/stats_page.dart');
  final settingsRaw = _read('lib/ui/settings_page.dart');
  final holidayRaw = _read('lib/ui/holiday_mark_page.dart');
  final aboutRaw = _read('lib/ui/about_page.dart');
  final routesRaw = _read('lib/app/routes.dart');
  final schemaRaw = _read('lib/db/database_schema.dart');
  final exportRaw = _read('lib/ui/export_backup_page.dart');

  final srcs = {
    'stats_page.dart': statsRaw,
    'settings_page.dart': settingsRaw,
    'holiday_mark_page.dart': holidayRaw,
    'about_page.dart': aboutRaw,
  };
  _check(srcs.values.every((s) => s.isNotEmpty), 'S0 四个页面文件均可读（真实源码）',
      '存在空/缺文件：${srcs.entries.where((e) => e.value.isEmpty).map((e) => e.key).toList()}');

  // S1：浮点禁令（剥离注释后）—— 零命中；豁免 stats_page 的布局比例行（MIN-2 / R47）
  var s1Violations = 0;
  var s1ExemptApplied = 0;
  final s1Detail = <String>[];
  srcs.forEach((name, raw) {
    final code = _stripComments(raw);
    for (var line in code.split('\n')) {
      // MIN-2 / R47 豁免：呈现层无量纲布局比例（非金额运算）。
      // **加固（审计 MINOR 6）**：原为 `continue` **整行跳过** → 同行其它浮点禁令一并逃逸；
      // 改为**只剔除豁免子串**后再跑禁令（同行其余部分仍受检）。
      if (name == 'stats_page.dart' && line.contains('amountFen / totalFen')) {
        s1ExemptApplied++;
        line = line.replaceAll('amountFen / totalFen', '');
      }
      final v = _floatViolations(line);
      if (v.isNotEmpty) {
        s1Violations++;
        s1Detail.add('$name: ${v.join(",")}');
      }
    }
  });
  _check(statsRaw.contains('amountFen / totalFen'),
      'S1 豁免项存在性：stats_page 确有布局比例行（MIN-2 豁免对象，R47 已登记）',
      '未找到 amountFen / totalFen');
  _check(s1ExemptApplied == 1,
      'S1 豁免**按子串剔除**生效（stats 恰 1 行命中豁免子串；防豁免静默失效）',
      '命中共 $s1ExemptApplied 行');
  _check(s1Violations == 0,
      'S1 四页剥离注释后**零**浮点禁令命中（fen/100、double.parse、.round、.toDouble、浮点 /10）',
      '命中：$s1Detail');

  // S2：注释剥离同时处理整行 + 行尾注释
  final codeHoliday = _stripComments(holidayRaw);
  final codeStats = _stripComments(statsRaw);
  final codeSettings = _stripComments(settingsRaw);
  _check(holidayRaw.contains('x / 10') && !codeHoliday.contains('x / 10'),
      'S2 整行/文档注释被剥离（`x / 10` 只在注释、不在代码）',
      'raw含=${holidayRaw.contains('x / 10')} code含=${codeHoliday.contains('x / 10')}');
  _check(settingsRaw.contains('右侧（角标位）') && !codeSettings.contains('右侧（角标位）'),
      'S2 **行尾注释**被剥离（settings 导出项行尾注释「右侧（角标位）」不在代码中）',
      'raw含=${settingsRaw.contains('右侧（角标位）')} code含=${codeSettings.contains('右侧（角标位）')}');
  _check(codeStats.contains('includeDraft: false'),
      'S2 剥离后**代码仍完整**（stats 保留 `includeDraft: false`）', '未找到 includeDraft: false');

  // S3：四页外壳/构造签名保留
  final shell = <String, List<String>>{
    'stats_page.dart': ['class StatsPage extends StatefulWidget', 'const StatsPage({super.key})'],
    'settings_page.dart': ['class SettingsPage extends StatefulWidget', 'const SettingsPage({super.key})'],
    'holiday_mark_page.dart': ['class HolidayMarkPage extends StatefulWidget', 'const HolidayMarkPage({super.key})'],
    'about_page.dart': ['class AboutPage extends StatelessWidget', 'const AboutPage({super.key})'],
  };
  shell.forEach((name, needles) {
    final s = srcs[name]!;
    final ok = needles.every((n) => s.contains(n)) && s.contains('Scaffold(') && s.contains('AppBar(');
    _check(ok, 'S3 $name 外壳保留（StatefulWidget/StatelessWidget + 构造签名 + Scaffold + AppBar）',
        '缺项：${needles.where((n) => !s.contains(n)).toList()}'
            '${s.contains('Scaffold(') ? '' : ' [缺 Scaffold]'}${s.contains('AppBar(') ? '' : ' [缺 AppBar]'}');
  });

  // S4：schema 未新增表/字段（六表不变，全派生不另存）
  const expectedTables = ['ledger', 'company', 'pricing_rule', 'work_record', 'payment_record', 'holiday_mark'];
  final tableNames = RegExp(r'CREATE TABLE IF NOT EXISTS\s+(\w+)')
      .allMatches(schemaRaw)
      .map((m) => m.group(1)!)
      .toSet();
  _check(tableNames.length == 6 && tableNames.containsAll(expectedTables),
      'S4-a schema 仍为**六表**、无新增表（全派生不落库，PRD 底线 1）',
      '实际表=${tableNames.toList()}');

  // **加固（审计 MINOR 7）**：原仅比"表名集合"，加列 / 删列 / 改列名**不红** → 补**逐表列集合快照**。
  // 期望列集 = 现盘 `lib/db/database_schema.dart` 快照，任一列增删改即红。
  const expectedColumns = <String, Set<String>>{
    'ledger': {'id', 'name', 'currency', 'mode', 'created_at'},
    'company': {
      'id', 'ledger_id', 'name', 'short_name', 'tag_color', 'default_rule_id',
      'enabled', 'contact', 'currency', 'note', 'created_at', 'updated_at',
      'deleted_at'
    },
    'pricing_rule': {
      'id', 'company_id', 'name', 'method', 'base_rate', 'unit',
      'standard_hours', 'half_day_ratio', 'overtime_rate', 'weekend_rate',
      'holiday_rate', 'effective_date', 'enabled', 'created_at', 'updated_at',
      'deleted_at'
    },
    'work_record': {
      'id', 'company_id', 'pricing_rule_id', 'attribution_date',
      'mode_snapshot', 'quantity', 'quantity_unit_snapshot', 'start_time',
      'end_time', 'is_overnight', 'unit_price_snapshot', 'rate_overtime_hit',
      'rate_overtime_rate', 'rate_weekend_hit', 'rate_weekend_rate',
      'rate_holiday_hit', 'rate_holiday_rate', 'rate_applied',
      'amount_snapshot', 'amount_source', 'auto_reference', 'currency',
      'note', 'status', 'created_at', 'updated_at', 'deleted_at'
    },
    'payment_record': {
      'id', 'company_id', 'pay_date', 'amount', 'method', 'note',
      'created_at', 'updated_at', 'deleted_at'
    },
    'holiday_mark': {
      'id', 'ledger_id', 'date', 'type', 'rate', 'manual', 'created_at'
    },
  };
  expectedColumns.forEach((table, cols) {
    final actual = _tableColumns(schemaRaw, table);
    final missing = cols.difference(actual).toList()..sort();
    final extra = actual.difference(cols).toList()..sort();
    _check(actual.isNotEmpty && missing.isEmpty && extra.isEmpty,
        'S4-b $table 列集合 == 冻结快照（${cols.length} 列，增/删/改列名即红）',
        '缺=${missing.isEmpty ? '无' : missing} 多=${extra.isEmpty ? '无' : extra}');
  });

  // S5：AC-P12-01 五入口接线且目标类存在
  // **加固（审计阻断 2）**：原为**整文件 `contains`**（被 import / doc 注释满足）→ 改为
  // ① 按 `title:` 文本定位该 `ListTile` 片段，断言其 `onTap` 指向**正确方法**；
  // ② 断言该 `_openXxx` **方法体**内构造/跳转的是**对应页类 / 路由**。
  final tileHoliday = _tileBlockByTitle(codeSettings, '节假日标记');
  _check(tileHoliday != null && tileHoliday.contains('onTap: _openHolidayMarks'),
      'S5-1a 设置页「节假日标记」tile 的 onTap == _openHolidayMarks（锚定 tile，非整文件）',
      'tile=${tileHoliday == null ? '未定位' : '未含 onTap: _openHolidayMarks'}');
  final bodyHoliday = _methodBody(codeSettings, '_openHolidayMarks');
  _check(
      bodyHoliday != null &&
          bodyHoliday.contains('HolidayMarkPage(') &&
          codeHoliday.contains('class HolidayMarkPage'),
      'S5-1b `_openHolidayMarks()` 方法体构造 HolidayMarkPage 且目标类存在',
      'body=${bodyHoliday ?? '未定位'}');

  final tileCompanies = _tileBlockByTitle(codeSettings, '公司列表');
  _check(tileCompanies != null && tileCompanies.contains('onTap: _openCompanies'),
      'S5-2a 设置页「公司列表」tile 的 onTap == _openCompanies', 'tile 未命中');
  final bodyCompanies = _methodBody(codeSettings, '_openCompanies');
  _check(bodyCompanies != null && bodyCompanies.contains('pushNamed(Routes.companies)'),
      'S5-2b `_openCompanies()` 方法体 pushNamed(Routes.companies)（M-2）',
      'body=${bodyCompanies ?? '未定位'}');
  _check(RegExp(r"static const String companies\s*=\s*'/companies'").hasMatch(routesRaw),
      "S5-2c routes.dart 常量 companies == '/companies'（原「恒真」次句已收紧）",
      '常量定义不符');

  final tileExport = _tileBlockByTitle(codeSettings, '导出备份');
  _check(tileExport != null && tileExport.contains('onTap: _openExport'),
      'S5-3a 设置页「导出备份」tile 的 onTap == _openExport', 'tile 未命中');
  final bodyExport = _methodBody(codeSettings, '_openExport');
  _check(
      bodyExport != null &&
          bodyExport.contains('ExportBackupPage(') &&
          exportRaw.contains('class ExportBackupPage'),
      'S5-3b `_openExport()` 方法体构造 ExportBackupPage 且目标类存在',
      'body=${bodyExport ?? '未定位'}');

  final tileAbout = _tileBlockByTitle(codeSettings, '关于 / 数据说明');
  _check(tileAbout != null && tileAbout.contains('onTap: _openAbout'),
      'S5-4a 设置页「关于 / 数据说明」tile 的 onTap == _openAbout', 'tile 未命中');
  final bodyAbout = _methodBody(codeSettings, '_openAbout');
  _check(
      bodyAbout != null &&
          bodyAbout.contains('AboutPage(') &&
          aboutRaw.contains('class AboutPage'),
      'S5-4b `_openAbout()` 方法体构造 AboutPage 且目标类存在',
      'body=${bodyAbout ?? '未定位'}');

  // S5-5：账本名保存 upsertLedger **实参完整**（`name` / `currency` / `mode` 不得丢）
  final ledgerCall = () {
    final idx = codeSettings.indexOf('upsertLedger(');
    if (idx < 0) return null;
    return _wireSlice(codeSettings, idx + 'upsertLedger'.length);
  }();
  _check(
      ledgerCall != null &&
          ledgerCall.contains('name:') &&
          ledgerCall.contains('currency:') &&
          ledgerCall.contains('mode:'),
      'S5-5 账本名保存 upsertLedger 实参含 name/currency/mode（丢字段即红，AC-P12-05）',
      'call=${ledgerCall ?? '未定位'}');

  // S6：关键文案逐字
  _check(codeSettings.contains("'从未备份'"), 'S6-1 settings 含「从未备份」逐字', '未找到');
  _check(!RegExp(r"subtitle\s*:\s*const Text\(\s*'从未备份'").hasMatch(settingsRaw),
      'S6-1b MIN-3：『从未备份』**不再**位于 subtitle（已移右侧角标位）', '仍出现在 subtitle');
  _check(holidayRaw.contains('删除后该日新建记录将不再套用节假日倍率'), 'S6-2 P12a 删除后果文案逐字', '未找到');
  _check(holidayRaw.contains('标记只影响以后新建的记录；已记的历史金额不变'), 'S6-3 P12a 效果说明逐字', '未找到');
  _check(holidayRaw.contains('标了节假日，当天记工自动按节假日倍率算'), 'S6-4 P12a 空态（E-05）逐字', '未找到');
  _check(statsRaw.contains('这段时间还没记工'), 'S6-5 P11 空态（AC-P11-07）逐字', '未找到');
  _check(aboutRaw.contains('账目只保存在这台手机上，不上传、不需要登录') &&
      aboutRaw.contains('手机丢失/换机/误删后无法找回') &&
      aboutRaw.contains('不包含借支'),
      'S6-6 P12b 关于页三条文案均在（AC-P12-04）', '三条文案缺项');

  // S7：G-C1-C 默认倍率来源 = 全账本首个启用规则（listPricingRules(includeDisabled:false)）
  _check(holidayRaw.contains('listPricingRules(includeDisabled: false)'),
      'S7-1 默认倍率来源 = listPricingRules(includeDisabled: false)', '未找到该调用');
  _check(holidayRaw.contains('rules.first.holidayRate') && holidayRaw.contains('Validators.minRate'),
      'S7-2 取首个启用规则 holidayRate，无则 Validators.minRate（=1.0）', '未找到取值口径');
  _check(!holidayRaw.contains('listPricingRules(includeDisabled: true)'),
      'S7-3 未误取停用规则', '出现 includeDisabled: true');

  // S9：P11 结构（四维度 + 惰性列表 + 口径）
  final dimOk = ['按公司', '按月', '按时间段', '按计价方式'].every((s) => codeStats.contains(s));
  _check(dimOk, 'S9-1a P11 四维度文案齐全', '缺维度');
  // **加固（审计 MINOR 7）**：原只查字符串存在 → 补**枚举 → label 映射**逐条断言（错配即红）。
  final dimMap = <String, String>{
    '_Dim.company': '按公司',
    '_Dim.month': '按月',
    '_Dim.range': '按时间段',
    '_Dim.method': '按计价方式',
  };
  final dimMapBad = dimMap.entries
      .where((e) => !RegExp(RegExp.escape(e.key) +
              r"\s*=>\s*'" +
              RegExp.escape(e.value) +
              "'")
          .hasMatch(codeStats))
      .map((e) => e.key)
      .toList();
  _check(dimMapBad.isEmpty,
      'S9-1b P11 `_Dim` 枚举 → label 映射逐条正确（错配即红）', '映射不符：$dimMapBad');
  _check(codeStats.contains('ListView.builder'),
      'S9-2 P11 用 ListView.builder（MIN-6 惰性）', '未找到 ListView.builder');
  // **加固（审计 MAJOR 3）**：原断 `statsRaw.contains('includeDraft: false')` 被 **doc 注释**满足
  // → 改用**剥注释后的代码**，并锚定到 `listWorkRecords(includeDraft: false)` 调用。
  _check(codeStats.contains('listWorkRecords(includeDraft: false)'),
      'S9-3 P11 统计源**代码**显式 listWorkRecords(includeDraft: false)（注释不算，AC-32）',
      '剥注释后未找到该调用（原注释即可满足 → 已加固）');

  // S10：MAJ-2「失败不丢输入」**结构断言**（可证伪）
  // **加固（审计阻断 1）**：原 `if \(err == null\)[\s\S]*?pop` 跨 `{}`「同现即真」，
  // 失败分支另加 pop 仍绿 → 改为**括号配平定位 if 块体**：断言 pop **在 if 块体内**、
  // else（失败）分支**不含** pop、且方法体内 pop **恰 1 处**（防"pop 移出 if"）。
  _checkS10(
    label: 'S10-1 MAJ-2：P12a `_submit()` pop 受成功分支守卫（失败保留输入/_DraftMark）',
    src: codeHoliday,
    method: '_submit',
    extraNeedles: const ['onSave', '_saveError'],
  );
  _checkS10(
    label: 'S10-2 MAJ-2：settings 账本名 `_save()` pop 受成功分支守卫（失败保留输入）',
    src: codeSettings,
    method: '_save',
    extraNeedles: const ['_LedgerNameDialog', 'onSave', '_saveError'],
  );

  // ── S11：P11 页内**分组 / 时间键真身**（**加固（审计 MAJOR 5）**）──────────────────
  // 原 §3 用脚本自写 `_ymKey`/`_ymdKey` 对 DB 记录复算 → 页内分组改坏**不红**；
  // 此处改读 `stats_page.dart` **真身源码**并断其结构（分组键粒度、分支取向、排序方向）。
  final ymKeyExpr = _exprBody(codeStats, '_ymKey');
  _check(
      ymKeyExpr != null &&
          ymKeyExpr.contains("padLeft(4, '0')") &&
          ymKeyExpr.contains("padLeft(2, '0')"),
      'S11-1 P11 `_ymKey` 真身 == yyyy-MM（year 补 4 位、month 补 2 位）',
      'expr=${ymKeyExpr ?? '未定位'}');
  final ymdKeyExpr = _exprBody(codeStats, '_ymdKey');
  _check(ymdKeyExpr != null && ymdKeyExpr.contains('_formatDate'),
      'S11-2 P11 `_ymdKey` 真身委托 `_formatDate`（日粒度 yyyy-MM-dd）',
      'expr=${ymdKeyExpr ?? '未定位'}');
  final fmtBody = _methodBody(codeStats, '_formatDate');
  _check(
      fmtBody != null &&
          fmtBody.contains("padLeft(4, '0')") &&
          fmtBody.contains("padLeft(2, '0')") &&
          fmtBody.contains(r"'$y-$m-$day'"),
      'S11-3 P11 `_formatDate` 真身 == yyyy-MM-dd（连字符连接）',
      'body=${fmtBody ?? '未定位'}');
  final computeBody = _methodBody(codeStats, '_computeRows');
  _check(
      computeBody != null &&
          computeBody.contains('_ymKey(r.workDate)') &&
          computeBody.contains('_ymdKey(r.workDate)') &&
          computeBody.contains('methodSnapshot'),
      'S11-4 P11 `_computeRows` 真身：月→_ymKey、时间段→_ymdKey、计价方式→methodSnapshot',
      'body=${computeBody ?? '未定位'}');
  final groupedBody = _methodBody(codeStats, '_groupedRows');
  _check(
      groupedBody != null &&
          RegExp(r'b\.label\.compareTo\(a\.label\)').hasMatch(groupedBody),
      'S11-5 P11 `_groupedRows` 真身按 label **降序**排序（新在前）',
      'body=${groupedBody ?? '未定位'}');

  // ── S12：AC 覆盖缺口补断言（审计 §6，原脚本零断言）─────────────────────────────
  // AC-P11-02：结束 < 开始 → 红字 + **不查询**
  _check(codeStats.contains('结束日期不能早于开始日期'),
      'S12-1 AC-P11-02 结束<开始 **红字文案**「结束日期不能早于开始日期」（代码区，非注释）',
      '未找到红字文案');
  _check(codeStats.contains('if (_rangeInvalid) return const [];'),
      'S12-2 AC-P11-02 区间非法时**不查询**（`_computeRows` 提前 return 空）',
      '未找到 `_rangeInvalid` 短路');
  _check(RegExp(r'bool get _rangeInvalid\s*=>').hasMatch(codeStats) &&
          codeStats.contains('isAfter'),
      'S12-3 AC-P11-02 `_rangeInvalid` 真身用 isAfter 判定（start 晚于 end）',
      '未找到 _rangeInvalid 谓词');

  // AC-P12-05：币种 CNY 只读（enabled: false）
  final currencyTile = _tileBlockByTitle(codeSettings, '币种');
  _check(currencyTile != null && currencyTile.contains('enabled: false'),
      'S12-4 AC-P12-05 币种 tile `enabled: false`（CNY 只读，不可改）',
      'tile=${currencyTile ?? '未定位'}');

  // AC-P12-06：P12a 页内「判重转编辑」三分支（原仅测 DB 层）
  final holSaveBody = _methodBody(codeHoliday, '_save');
  _check(
      holSaveBody != null &&
          _countOccurrences(holSaveBody, 'updateHolidayMark(') == 2 &&
          _countOccurrences(holSaveBody, 'upsertHolidayMark(') == 1,
      'S12-5 AC-P12-06 P12a `_save` 三分支：编辑/判重命中各走 updateHolidayMark（2 处）、新建走 upsertHolidayMark（1 处）',
      'update=${holSaveBody == null ? 'n/a' : _countOccurrences(holSaveBody, 'updateHolidayMark(')} upsert=${holSaveBody == null ? 'n/a' : _countOccurrences(holSaveBody, 'upsertHolidayMark(')}');
  _check(
      holSaveBody != null &&
          holSaveBody.contains('getHolidayMarkByDate(') &&
          holSaveBody.contains('id: existing.id'),
      'S12-6 AC-P12-06 P12a `_save` 新建前 `getHolidayMarkByDate` 判重、命中复用 `existing.id`（id 不漂移）',
      'body=${holSaveBody ?? '未定位'}');

  // 降级黄条（D-6 / E-11）
  _check(
      codeStats.contains('账目数字可能不完整，请勿据此对账') &&
          codeStats.contains('_DegradedBar'),
      'S12-7 降级黄条文案「账目数字可能不完整，请勿据此对账」+ _DegradedBar 渲染（D-6/E-11）',
      '未找到降级文案/组件');
  _check(
      codeStats.contains('_onExportGuide') &&
          _countOccurrences(codeStats, 'ExportBackupPage(') >= 1,
      'S12-8 降级黄条「导出备份」引导接线 ExportBackupPage（D-6/E-11）',
      '未找到导出引导接线');
}
