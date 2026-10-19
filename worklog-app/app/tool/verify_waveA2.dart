// Wave A2（导航骨架）静态自检。
//
// 覆盖范围（两批）：
//   · 首批 —— `AC-A2-03`（零一次性代码）/ `AC-A2-05`（占位页 _load() 空实现）两条 **[静态]** 档，
//     外加「用户可见文案统一为『看板』」口径自检；
//   · 第二批（**独立审查 MAJ-01 回填**）—— **死路由清理**：`Routes.records` /
//     `Routes.overview` 常量与 `main.dart` case 同批移除、`Routes.companies` 保留、
//     `RecordsPage.title` 改必填。依据 `11-主理人裁定（WaveA设计）.md` §1 Q-D1 施工硬约束 (a)、
//     `09-WaveA-实现设计.md` §13.1 N-D7、`12-WaveA-批2归档与教训.md` §7。
//
// 证据层级标注（本项目纪律，见 `docs/00-项目总览/DECISIONS.md` D-8）：
//   【实测级】 本脚本 = 读真实源码文件 + 正则断言，**结论可直接采信**（不涉 UI 渲染）。
//   【不覆盖】 `AC-A2-01` / `AC-A2-02` / `AC-A2-04` 为 **[真机]** 档（Tab 可点入、
//             占位页非空白、切换不崩）→ 本脚本**不能**替代，须末次出包真机验收。
//
// 断言强度加固（依据 `docs/08-验证脚本断言强度审计/03-verify_waveA 与 waveA2.md` §3.2）：
//   · [4] 可达性：由「全文出现/计数 ≥1」改为**实参级锚定方法体 + 剥注释 + 精确计数**——
//     `_openAllRecords` 内 RecordsPage( 恰 1、`_openCompanyDetail` 内 CompanyDetailPage 接线（堵 F4）、
//     `pushNamed(Routes.companies)` 剥注释后恰 2 且 `_openAllCompanies` 内恰 1（堵 F5；注释行不再计入）。
//   · [5] 文案：AppBar 标题**锚定 `appBar:` 表达式内 `title:`**（堵 F6 单点逃逸）；
//     「总览」字面量扫描范围由 `lib/ui` 扩至**整个 `lib`** 且**单/双引号均查**（堵 F7）。
//
// 跑法：`export WORKLOG_USE_SYSTEM_SQLITE=1; dart --disable-dart-dev tool/verify_waveA2.dart`
//      （本脚本用 dart:io，不触 DB；WORKLOG_USE_SYSTEM_SQLITE 仅为与其他套件保持一致的跑法）
//
// 契约来源：
//   · `docs/04-迭代/2026-10-05/补齐规格07剩余页/02-需求与验收.md` §D.15（`AC-A2-01~05`）
//   · `docs/04-迭代/2026-10-05/补齐规格07剩余页/02-需求与验收.md` §A.3（Wave A2 行）
//   · `docs/07-UI实现规格.md` `:141` / `:210`（底部 4 Tab = 看板 / 日历 / 统计 / 设置）

import 'dart:io';

int _pass = 0;
int _fail = 0;

void _ok(String label) {
  _pass++;
  stdout.writeln('  ✓ $label');
}

void _bad(String label, String detail) {
  _fail++;
  stdout.writeln('  ✗ $label');
  stdout.writeln('      → $detail');
}

void _check(bool cond, String label, String detail) {
  if (cond) {
    _ok(label);
  } else {
    _bad(label, detail);
  }
}

String _read(String relPath) {
  final f = File(relPath);
  if (!f.existsSync()) return '';
  return f.readAsStringSync();
}

/// 取 `label: '<x>'` 形式的字符串字面量**按出现顺序**的列表。
List<String> _stringLiteralsAfter(String src, String key) {
  final out = <String>[];
  final re = RegExp(RegExp.escape(key) + r"\s*:\s*'([^']*)'");
  for (final m in re.allMatches(src)) {
    out.add(m.group(1)!);
  }
  return out;
}

// ── 静态锚定工具（[4]/[5] 加固用；手法同唯一 0 假覆盖脚本 `verify_waveD2.dart:98-227`）──
/// 剥离**整行注释 + 行尾注释**（`(^|\s)//.*$`）。注释行不得救活断言（堵 F5）。
final RegExp _commentRe = RegExp(r'(^|\s)//.*$', multiLine: true);
String _stripComments(String src) => src.replaceAll(_commentRe, '');

/// `needle` 在 `code` 中的**总出现次数**（不重叠）。
int _count(String code, String needle) {
  if (needle.isEmpty) return 0;
  var c = 0;
  var i = code.indexOf(needle);
  while (i >= 0) {
    c++;
    i = code.indexOf(needle, i + needle.length);
  }
  return c;
}

/// 取 `marker` 所在方法/函数体的完整块（花括号配对）。
String _blockAfter(String code, String marker) {
  final i = code.indexOf(marker);
  if (i < 0) return '';
  final open = code.indexOf('{', i);
  if (open < 0) return '';
  var depth = 0;
  for (var j = open; j < code.length; j++) {
    final c = code[j];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return code.substring(i, j + 1);
    }
  }
  return code.substring(i);
}

/// 取 `marker` 之后**第一个** `(` 到配对 `)` 的完整表达式（含 `marker`）。
/// 用于无花括号体的块提取（如 `appBar: AppBar(title: …)`）。
String _parenAfter(String code, String marker) {
  final i = code.indexOf(marker);
  if (i < 0) return '';
  final open = code.indexOf('(', i);
  if (open < 0) return '';
  var depth = 0;
  for (var j = open; j < code.length; j++) {
    final c = code[j];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return code.substring(i, j + 1);
    }
  }
  return code.substring(i);
}

void main() {
  stdout.writeln('══════════════════════════════════════════════');
  stdout.writeln('Wave A2 · 导航骨架 · 静态自检');
  stdout.writeln('══════════════════════════════════════════════');

  final mainSrc = _read('lib/main.dart');
  _check(mainSrc.isNotEmpty, 'lib/main.dart 可读', '文件不存在或为空');

  // ── 1. `_pages` 四项与顺序（§A.3 Wave A2 行逐字要求）─────────────────
  stdout.writeln('\n[1] _pages 四项与顺序（AC-A2-01 / AC-A2-03）');
  final pagesBlock = RegExp(
    r'_pages\s*=\s*<Widget>\s*\[(.*?)\]',
    dotAll: true,
  ).firstMatch(mainSrc);
  _check(pagesBlock != null, '_pages 可定位', '正则未命中 `_pages = <Widget>[`');
  if (pagesBlock != null) {
    final body = pagesBlock.group(1)!;
    final order = RegExp(r'(\w+Page)\(\)')
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toList();
    _check(
      order.length == 4,
      '_pages 恰 4 项',
      '实际 ${order.length} 项：$order',
    );
    const expected = ['OverviewPage', 'CalendarPage', 'StatsPage', 'SettingsPage'];
    _check(
      order.length == expected.length &&
          List.generate(order.length, (i) => order[i] == expected[i])
              .every((e) => e),
      '_pages 顺序 = $expected',
      '实际：$order',
    );
    _check(
      !body.contains('RecordsPage') && !body.contains('CompanyPage'),
      '旧 Tab 页（RecordsPage / CompanyPage）已移出 _pages',
      '_pages 内仍有 RecordsPage 或 CompanyPage（应改为下钻页）',
    );
  }

  // ── 2. 底部 4 个 Tab 与文案（07:141 / 07:210）──────────────────────
  stdout.writeln('\n[2] 底部 4 Tab 文案（07:141 / 07:210）');
  final itemsCount = RegExp(r'BottomNavigationBarItem\(').allMatches(mainSrc).length;
  _check(itemsCount == 4, 'BottomNavigationBarItem 恰 4 个', '实际 $itemsCount 个');
  final labels = _stringLiteralsAfter(mainSrc, 'label');
  const wantLabels = ['看板', '日历', '统计', '设置'];
  _check(
    labels.length == 4 &&
        List.generate(4, (i) => labels[i] == wantLabels[i]).every((e) => e),
    'Tab 文案 = $wantLabels',
    '实际：$labels',
  );
  _check(
    !mainSrc.contains("label: '总览'") &&
        !mainSrc.contains("label: '明细'") &&
        !mainSrc.contains("label: '公司'"),
    '旧 Tab 文案（总览 / 明细 / 公司）已不存在',
    'main.dart 仍含旧 Tab 文案',
  );

  // ── 3. 三个占位页（AC-A2-02 / AC-A2-03 / AC-A2-05）────────────────────
  // ⚠️ **占位态断言是【过渡态】断言，随 Wave B/C1 原位填充而按其设计退役**。
  //    依据 `AC-A2-03`：「占位页 = P03/P11/P12 的文件骨架；Wave B/C1 **原位填充**，
  //    无需删除/重写」→ 填充**必然**使「_load() 为空」「含『建设中』」两条失效。
  //    故本脚本按 **条件式** 断言：**仍是占位页**时必须满足占位态约束；
  //    **已填充**时该两条自动退役（不再作为"基线不得变红"的长期门禁），
  //    但**结构不变量**（StatefulWidget + const 构造 + Scaffold/AppBar 外壳）**始终**校验。
  stdout.writeln('\n[3] P03 / P11 / P12 页面（占位态条件式 · 结构不变量恒校验）');
  const placeholders = {
    'lib/ui/calendar_page.dart': ('CalendarPage', 'Wave B'),
    'lib/ui/stats_page.dart': ('StatsPage', 'Wave C1'),
    'lib/ui/settings_page.dart': ('SettingsPage', 'Wave C1'),
  };
  final emptyLoad = RegExp(r'Future<void>\s+_load\(\)\s+async\s*\{\s*return;\s*\}');
  final emptyLoad2 = RegExp(r'Future<void>\s+_load\(\)\s+async\s*\{\s*\}');

  // ── 已填充页的「**数据接线**」判据（v2，替代「`_load()` 非空」判据）────────────
  //   独立审查（2026-10-19）实测：v1 判据只认 `{}` / `{ return; }` 两种语法形态，
  //   把 `_load()` 换成下面四种「假加载」形态**全部仍判为通过**：
  //     ① `{ setState(() {}); }`　② `{ /* 什么都不做 */ }`
  //     ③ `{ _loading = false; return; }`　④ `{ _records = []; }`（空列表假数据）
  //   最坏情形实测：把 `settings_page._load()` 的**整段取数搬空**，10 个脚本全绿
  //   —— 因为 `tool/` 下没有任何脚本断言过 settings 页调用 `getLedger`。
  //   这就是「断言跟着代码形状走、不跟着价值链走」的老病（与上一轮 34 处假覆盖同族）。
  //   故改为**按页面锚定它唯一的数据来源调用 + 状态落位 + 渲染出口**（写死 needle），
  //   上述四种形态会同时因「缺取数调用」而变红。
  const loadWiring = <String, List<String>>{
    // [数据来源调用, …（可多条）, 状态落位, 渲染出口]
    'lib/ui/calendar_page.dart': [
      '_db.listWorkRecordsLenient(',
      'lenient.skipped', // 坏行计数必须取自容错读（AC-P03 / 坏行提示的来源）
      '_byDay = ',
      'setState(',
    ],
    'lib/ui/stats_page.dart': [
      '_db.listWorkRecords(',
      '_db.aggregateByCompany(',
      '_records = ',
      'setState(',
    ],
    'lib/ui/settings_page.dart': [
      '_db.getLedger(',
      '_ledger = ',
      'setState(',
    ],
  };
  // 每页「主取数调用」——必须在 `_load()` 内**恰 1 处**（防死分支诱饵：先放一条永不执行的调用）。
  const loadPrimary = <String, String>{
    'lib/ui/calendar_page.dart': '_db.listWorkRecordsLenient(',
    'lib/ui/stats_page.dart': '_db.aggregateByCompany(',
    'lib/ui/settings_page.dart': '_db.getLedger(',
  };

  placeholders.forEach((path, meta) {
    final name = meta.$1;
    final wave = meta.$2;
    final src = _read(path);
    if (src.isEmpty) {
      _bad('$path 存在', '文件不存在或为空');
      return;
    }
    // 语义判定一律走**剥注释**后的代码：注释里出现「建设中」/「Scaffold(」不该翻转结论
    // （否则是「假红」—— 断言方向对但判据脏）。
    final srcCode = _stripComments(src);
    // ── 结构不变量：填充后仍必须成立（`MainShell._pages` 是 `static const`）──
    _check(
      srcCode.contains('class $name extends StatefulWidget'),
      '$path：$name 为 StatefulWidget（可原位填充）',
      '未找到 `class $name extends StatefulWidget`',
    );
    _check(
      srcCode.contains('const $name({super.key})'),
      '$path：构造签名 const $name({super.key})（_pages 依赖，填充后不得改）',
      '构造签名不匹配',
    );
    _check(
      srcCode.contains('Scaffold(') && srcCode.contains('AppBar('),
      '$path：保留 Scaffold / AppBar 外壳（原位填充不得重建）',
      '缺少 Scaffold 或 AppBar',
    );
    // ── 填充态 / 占位态：**显式判定当前态**，不再「条件式静默跳过」──
    //    ★ 加固（空断言转守卫）：原实现为
    //        `if (src.contains('建设中')) { 占位约束 } else { _ok(…退役…) }`
    //      ⇒ 任何人把页面**退回占位态**，脚本仍全绿（退回后走占位分支，而占位分支本就通过）。
    //      即「占位态已退役」这件事**不可证伪** —— 属审计判定的「空断言」。
    //      改为：先断言「已填充」本身（退回即红），再按当前态施加对应约束。
    final filled = !srcCode.contains('建设中');
    _check(
      filled,
      '$path：已由 $wave 原位填充（占位态已退役；**退回占位态则本断言变红**）',
      '仍含「建设中」→ 该页退回占位态，违反 AC-A2-03「原位填充、不得删除重建」',
    );
    if (filled) {
      // 半填充守卫 v2 = **数据接线判据**（见上方 `loadWiring` 说明）。
      final loadBody = _blockAfter(srcCode, 'Future<void> _load() async');
      _check(
        loadBody.isNotEmpty,
        '$path：`_load()` 方法体可切片（数据接线判据的前置）',
        '未找到 `Future<void> _load() async` 或花括号不配对',
      );
      final need = loadWiring[path] ?? const <String>[];
      final missing = need.where((n) => !loadBody.contains(n)).toList();
      _check(
        loadBody.isNotEmpty && missing.isEmpty,
        '$path：已填充页 `_load()` **数据接线完整**（${need.length} 个必备锚点全含）',
        '缺失：$missing —— 页面在、数据未接（假加载 / 半填充）',
      );
      final primary = loadPrimary[path] ?? '';
      final pn = _count(loadBody, primary);
      _check(
        pn == 1,
        '$path：`_load()` 内主取数调用 `$primary` 恰 1 处（防死分支诱饵）',
        '实际 $pn 处',
      );
    } else {
      _check(
        emptyLoad.hasMatch(srcCode) || emptyLoad2.hasMatch(srcCode),
        '$path：仍是占位页 → _load() 必须为空实现（AC-A2-05 启动期零 DB 读）',
        '_load() 非空实现 —— 占位页不得在启动期读库',
      );
      _check(
        srcCode.contains(wave),
        '$path：仍是占位页 → 标注预期交付波次「$wave」（AC-A2-02）',
        '未找到「$wave」字样',
      );
    }
  });

  // ── 4. 下钻可达性未被破坏（AC-A2-04 / 02 §C.2 Q22）────────────────
  stdout.writeln('\n[4] 原 Tab 页降级为下钻页后仍可达（AC-A2-04 / Q22）');
  final routeSrc = _read('lib/app/routes.dart');
  _check(
    routeSrc.contains("static const String companies = '/companies';"),
    'Routes.companies 保留为活路由且值不改为 /companies（M-2 裁定，A2 不得清理）',
    'routes.dart 中 companies 路由被删或被改',
  );
  _check(
    mainSrc.contains('case Routes.companies:') &&
        mainSrc.contains('const CompanyPage()'),
    'main.dart 仍注册 Routes.companies → CompanyPage',
    'Routes.companies 未注册到 CompanyPage',
  );
  final overviewSrc = _read('lib/ui/overview_page.dart');
  // ★ 加固（审计 F4/F5）：实参级锚定 + 剥注释 + 精确计数，取代原「任意位置出现/计数 ≥1」。
  final overviewCode = _stripComments(overviewSrc);
  // ① P01 明细下钻入口：锚定「查看全部记录」→ _openAllRecords 方法体内 RecordsPage(
  final allRecordsBody =
      _blockAfter(overviewCode, 'Future<void> _openAllRecords()');
  final recordsPushCount = _count(allRecordsBody, 'RecordsPage(');
  _check(
    recordsPushCount == 1,
    'P01「查看全部记录」→ _openAllRecords 方法体内 RecordsPage( 恰 1（剥注释·锚定方法体）',
    '实际 $recordsPushCount 处（期望 1）→ 明细页失去可达性',
  );
  // ② ★审计 F4 逃逸点：点公司卡片 → P07 公司详情（原 [4] 只数 RecordsPage(，未查该接线）
  final openCompanyBody =
      _blockAfter(overviewCode, 'Future<void> _openCompanyDetail(Company c)');
  final companyDetailCount =
      _count(openCompanyBody, 'CompanyDetailPage(companyId: c.id)');
  _check(
    companyDetailCount == 1 && !openCompanyBody.contains('CompanyDebtListPage()'),
    'P01 点公司卡片 → _openCompanyDetail 方法体内 CompanyDetailPage(companyId: c.id) 恰 1（堵 F4）',
    '实际：CompanyDetailPage=$companyDetailCount 含CompanyDebtListPage=${openCompanyBody.contains('CompanyDebtListPage()')}',
  );
  // ③ ★审计 F5 逃逸点：M-2 一律 pushNamed；剥注释后精确计数（注释行不得计入）
  final companiesPushCount =
      _count(overviewCode, 'pushNamed(Routes.companies)');
  final allCompaniesBody =
      _blockAfter(overviewCode, 'Future<void> _openAllCompanies()');
  final allCompaniesPush =
      _count(allCompaniesBody, 'pushNamed(Routes.companies)');
  _check(
    companiesPushCount == 2 && allCompaniesPush == 1,
    'P01 剥注释后 pushNamed(Routes.companies) 恰 2 处，且「全部公司」_openAllCompanies 内恰 1（M-2，堵 F5）',
    '全文=$companiesPushCount（期望 2）_openAllCompanies 内=$allCompaniesPush（期望 1）',
  );

  // ── 5. 用户可见文案口径统一为「看板」（07 通篇无「总览」）──────────
  stdout.writeln('\n[5] 用户可见文案：总览 → 看板（07 通篇无「总览」）');
  // ★ 加固（审计 F6）：锚定 appBar: 表达式内的 title:，取代「全文 contains Text('看板')」单点逃逸。
  final appBarExpr = _parenAfter(overviewCode, 'appBar:');
  _check(
    appBarExpr.contains("title: const Text('看板')") &&
        !appBarExpr.contains("Text('首页')"),
    'P01 AppBar 标题 = 看板（锚定 appBar: 表达式内 title:，堵 F6 单点逃逸）',
    'appBar 表达式=$appBarExpr',
  );
  final offenders = <String>[];
  // 单/双引号字符串字面量均查（堵 F7：`Text("总览")` 双引号诱饵）
  final literalTotal = RegExp("['\"][^'\"\n]*总览[^'\"\n]*['\"]");
  // 剥离注释：**整行注释与行尾注释都要剥**（`(^|\s)//.*$`）。
  // ⚠️ 只剥整行注释会漏掉 `code(); // 说明` 这类行尾注释 → 制造**假阳性**
  //    （本项目真实教训：检查器粗糙时不得据此改本来无害的代码）。
  // ★ 加固（审计 F7）：扫描范围 = **整个 lib**（非仅 lib/ui），堵「lib/ui 之外的可见字面量」缺口。
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final codeOnly = e.readAsStringSync().replaceAll(_commentRe, '');
    if (literalTotal.hasMatch(codeOnly)) {
      offenders.add(e.path);
    }
  }
  _check(
    offenders.isEmpty,
    'lib/（含 main.dart，非仅 lib/ui）下无遗留的用户可见「总览」字面量（单/双引号均查）',
    '仍命中：$offenders',
  );

  // ── 6. 死路由清理（MAJ-01：随 4 Tab 同批，依据 11 §1 Q-D1 / 09 §13.1 N-D7 / 12 §7）
  stdout.writeln('\n[6] 死路由清理：Routes.records / Routes.overview（MAJ-01）');
  _check(
    !routeSrc.contains('static const String records'),
    'routes.dart 已删 Routes.records 常量',
    'Routes.records 常量仍在',
  );
  _check(
    !routeSrc.contains('static const String overview'),
    'routes.dart 已删 Routes.overview 常量',
    'Routes.overview 常量仍在',
  );
  _check(
    routeSrc.contains('static const String companies'),
    'routes.dart 保留 Routes.companies（活路由，Q-D1 v2 / M2）',
    'Routes.companies 被误删',
  );
  _check(
    !mainSrc.contains('case Routes.records:'),
    'main.dart 已删 case Routes.records（N-D7：常量与 case 不得只删其一）',
    'case Routes.records 仍在',
  );
  _check(
    !mainSrc.contains('case Routes.overview:'),
    'main.dart 无 case Routes.overview（E-7：该路由从未注册）',
    '出现 case Routes.overview',
  );
  _check(
    mainSrc.contains('case Routes.companies:'),
    'main.dart 保留 case Routes.companies',
    'case Routes.companies 被误删',
  );
  _check(
    !mainSrc.contains("import 'ui/records_page.dart';"),
    'main.dart 无未使用的 records_page import',
    'records_page 已不被 main.dart 引用，该 import 应删除',
  );
  // 全工程「代码」中零 Routes.records / Routes.overview 引用（注释不计）
  final deadRef = RegExp(r'Routes\.(records|overview)\b');
  final deadOffenders = <String>[];
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    if (deadRef.hasMatch(e.readAsStringSync().replaceAll(_commentRe, ''))) {
      deadOffenders.add(e.path);
    }
  }
  _check(
    deadOffenders.isEmpty,
    'lib/ 代码中零 Routes.records / Routes.overview 引用',
    '仍命中：$deadOffenders',
  );
  // records_page 的 title 改必填（原默认「明细」随 Tab 变更消失 —— 09:234 已预言）
  final recSrc = _read('lib/ui/records_page.dart');
  _check(
    recSrc.contains('required this.title') &&
        !recSrc.contains("this.title = '明细'"),
    'records_page.dart：title 已改必填，旧默认「明细」已消失（09:234 预言）',
    "title 仍带默认值 '明细' 或未改必填",
  );

  stdout.writeln('\n──────────────────────────────────────────────');
  stdout.writeln('结果：$_pass 通过 / $_fail 失败');
  stdout.writeln('──────────────────────────────────────────────');
  if (_fail > 0) {
    stdout.writeln('【未覆盖】AC-A2-01 / AC-A2-02 / AC-A2-04 属 [真机] 档，本脚本不替代。');
    exit(1);
  }
  stdout.writeln('本脚本覆盖 [静态] 档：AC-A2-03 / AC-A2-05、文案口径（总览→看板）、'
      '死路由清理（MAJ-01）与 RecordsPage.title 必填化；'
      '[4] 可达性已升级为实参级锚定（下钻接线 / pushNamed 精确计数）。');
  stdout.writeln('【未覆盖】AC-A2-01 / AC-A2-02 / AC-A2-04 属 [真机] 档，须末次出包人工验收。');
}
