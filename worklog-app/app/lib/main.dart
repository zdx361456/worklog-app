/// App 入口（本轮重写：替换 Flutter 默认计数器 Demo）。
///
/// 职责：① 注册 sqflite 插件 factory（**必须**，见下）② 首启初始化账本（G-12）
/// ③ 装配 Material 主题与 4 tab 主壳 ④ 命名路由（含编辑态 `?id=` 透传）。
///
/// **为何必须 `databaseFactory = databaseFactorySqflitePlugin;`**：
/// `lib/db/database.dart` 刻意**不** import `package:sqflite`（为使其能在纯 Dart VM 下
/// 被 verify_db 运行）。故 sqflite 插件注册链必须在入口补上，否则 Android 上
/// `AppDatabase.open()` 拿不到 factory 实现（sqflite_common 会抛带指引的 StateError）。
library;

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'app/app_state.dart';
import 'app/routes.dart';
import 'db/database.dart';
import 'models/ledger.dart';
import 'models/types.dart';
import 'services/id_gen.dart';
import 'ui/calendar_page.dart';
import 'ui/company_page.dart';
import 'ui/overview_page.dart';
import 'ui/payment_form_page.dart';
import 'ui/settings_page.dart';
import 'ui/stats_page.dart';
import 'ui/work_form_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  databaseFactory = databaseFactorySqflitePlugin;
  runApp(const WorklogApp());
}

class WorklogApp extends StatelessWidget {
  const WorklogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '工时记账',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
      ),
      home: const BootstrapGate(),
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case Routes.workForm:
            return MaterialPageRoute<void>(
              builder: (_) => WorkFormPage(id: _extractId(settings)),
            );
          case Routes.paymentForm:
            return MaterialPageRoute<void>(
              builder: (_) => PaymentFormPage(id: _extractId(settings)),
            );
          // Wave A2：`case Routes.records`（原 → `const RecordsPage()`）已随死路由
          // **同批删除**（`11 §1 Q-D1` 硬约束 (a) + `09 §13.1 N-D7`「常量与 case 不得只删其一」
          // + `12 §7`）。`Routes.records` 全工程零 `pushNamed` 调用；`RecordsPage` 现为
          // 下钻页，由 P01 三处以 `MaterialsPageRoute` + 显式 `title` 进入。
          case Routes.companies:
            return MaterialPageRoute<void>(builder: (_) => const CompanyPage());
        }
        return null;
      },
    );
  }
}

/// 从路由参数中提取编辑对象 id。
///
/// 兼容两种传参：`arguments`（String 或 `{'id': ...}` 均支持）与查询串
/// `'/work/new?id=<id>'`（Wave 2 两种写法均可用）。
String? _extractId(RouteSettings settings) {
  final args = settings.arguments;
  if (args is String && args.isNotEmpty) return args;
  if (args is Map && args['id'] is String) {
    final id = args['id'] as String;
    return id.isEmpty ? null : id;
  }
  final name = settings.name ?? '';
  final q = name.indexOf('?');
  if (q >= 0) {
    final query = Uri.splitQueryString(name.substring(q + 1));
    final id = query['id'];
    if (id != null && id.isNotEmpty) return id;
  }
  return null;
}

/// 首启初始化闸门（G-12）：打开数据库 → 无账本则建默认账本 → 记录 `AppState.ledgerId`。
///
/// **失败必须有兜底页**（显示错误 + 重试），绝不白屏。
class BootstrapGate extends StatefulWidget {
  const BootstrapGate({super.key});

  @override
  State<BootstrapGate> createState() => _BootstrapGateState();
}

class _BootstrapGateState extends State<BootstrapGate> {
  bool _ready = false;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final db = AppDatabase.instance;
      await db.open();
      var ledgers = await db.listLedgers();
      if (ledgers.isEmpty) {
        await db.upsertLedger(
          Ledger(
            id: newId('led'),
            name: AppState.defaultLedgerName,
            currency: 'CNY',
            mode: LedgerMode.local,
            createdAt: DateTime.now(),
          ),
        );
        ledgers = await db.listLedgers();
      }
      AppState.ledgerId = ledgers.first.id;
      if (!mounted) return;
      setState(() {
        _ready = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Color(0xFFD32F2F)),
                const SizedBox(height: 12),
                const Text('初始化失败',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('$_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _init,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return const MainShell();
  }
}

/// 4 tab 主壳：**看板 / 日历 / 统计 / 设置**（Ware A2 落点，契约 `07:141` / `07:210`）。
///
/// 用 [IndexedStack] 保留各 tab 状态。
///
/// **Wave A2 说明**：底栏由 3 Tab（总览 / 明细 / 公司）改为 4 Tab。原「明细」
/// （`RecordsPage`）与「公司」（`CompanyPage`）**不再是 Tab**，改为**下钻页**：
///   - `RecordsPage` → 由 P01「查看全部」以 `Navigator.push` 进入（P01 有 3 处入口）；
///   - `CompanyPage`  → 由 P01「全部公司」以 `pushNamed(Routes.companies)` 进入，
///     命名路由**保留为活路由**（`M-2` 裁定，Wave A2 不清理）。
/// → **两页均未失去可达性**（`02 §C.2` Q22 结论）。
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  /// 4 个 Tab 同建（`IndexedStack` 首帧 build 全部）。
  ///
  /// `AC-A2-05`：P03/P11/P12 在 A2 阶段为**占位骨架**，其 `_load()` 为**空实现**，
  /// 故启动期 DB 读数**不增加**（仍只有 P01 一路）。
  static const List<Widget> _pages = <Widget>[
    OverviewPage(),
    CalendarPage(),
    StatsPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined), label: '看板'),
          BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month_outlined), label: '日历'),
          BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_outlined), label: '统计'),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }
}
