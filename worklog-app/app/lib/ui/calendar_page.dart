/// P03 · 日历页（**Wave B 原位填充** —— 保留 Wave A2 的 `Scaffold` / `AppBar` 外壳
/// 与 `const CalendarPage({super.key})` 构造签名，仅在原地补齐月历数据与视图）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.3（`07:291-325`）；
/// `docs/04-迭代/2026-10-05/补齐规格07剩余页/02-需求与验收.md` §D.3（`AC-P03-01~09`）；
/// `docs/03-数据模型与信息架构.md` §7.1（`:525-534`，日历派生口径）。
/// 设计落点：同目录 `13-WaveB-实现设计.md` §1.1。
///
/// **口径纪律**（D-1/D-2/D-4）：
///  - 金额整数「分」、倍率整数「×10」，显示一律 [fenToYuan]，**禁浮点**；
///  - 日历**全派生不落库**，不新增汇总表；
///  - 色点/当日小计**同源** = 有效（非草稿、未软删）记录集 → `includeDraft: false`
///    （≡ `status IN ('confirmed','settled')`，`database.dart:1263`），与 `03 §7.1` 逐字一致；
///  - **容错读**：坏行逐行隔离（`listWorkRecordsLenient`），`skipped` 非空 → 顶部告警条（`02:442`）。
///
/// **证据层级**：本文件的数据接线与口径为【读码级】（源码 + 冻结文档）；
/// 网格渲染 / 手势 / 高亮等 UI 行为 =【真机】档，本机不可自动化。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/data_bus.dart';
import '../db/database.dart';
import '../models/company.dart';
import '../models/holiday_mark.dart';
import '../models/types.dart';
import '../models/work_record.dart';
import 'day_detail_page.dart';
import 'holiday_mark_page.dart';
import 'widgets/money.dart';

const Color _kRedAmount = Color(0xFFD32F2F);

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final AppDatabase _db = AppDatabase.instance;

  late int _year;
  late int _month;

  bool _loading = true;
  Object? _error;

  /// 当日聚合：`'yyyy-MM-dd' → _DayAgg`（全派生，不落库）。
  Map<String, _DayAgg> _byDay = const {};

  /// 节假日标记：`'yyyy-MM-dd' → HolidayMark`。
  Map<String, HolidayMark> _holidayByDate = const {};

  /// 坏行（容错读逐行隔离出的脏行；非空 → 顶部黄色告警条，`02:442`）。
  List<SkippedRow> _skipped = const [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
    dataBus.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataBus.removeListener(_load);
    super.dispose();
  }

  /// 拉当月有效记录 + 公司元数据（双 true，含停用/归档）+ 当月节假日。
  ///
  /// - `includeDraft: false` ≡ `status IN ('confirmed','settled')`（`database.dart:1263`）
  ///   → 草稿不计入色点与小计（`03 §7.1` / AC-32 / AC-P03-04）。
  /// - 公司元数据 `includeDisabled: true, includeDeleted: true`：停用/已归档公司的
  ///   历史记录其色点仍要显示（AC-19 / `03 §8` 约束 2；`13 §3 缺口 2` 已上报超集）。
  /// - `listHolidayMarks` 的 `endDate` 传当月最后一天以减少读取量（`07 A7`）。
  /// - **容错读**：用 `listWorkRecordsLenient`（`database.dart:663`）**逐行隔离**坏行，
  ///   `skipped` 非空 → 顶部黄色告警条（`02:442` P03 异常态：「脏行 → 容错读 + 告警条」）。
  Future<void> _load() async {
    final first = DateTime(_year, _month, 1);
    final last = DateTime(_year, _month + 1, 0); // 下月 0 日 = 本月最后一天
    try {
      final r = await Future.wait<Object>([
        _db.listWorkRecordsLenient(
          startDate: first,
          endDate: last,
          includeDraft: false, // 草稿不计入（AC-32 / AC-P03-04）
        ),
        _db.listCompanies(includeDisabled: true, includeDeleted: true),
        _db.listHolidayMarks(
          ledgerId: AppState.ledgerId,
          startDate: first,
          endDate: last,
        ),
      ]);
      final lenient = r[0] as LenientRead<WorkRecord>;
      final records = lenient.rows;
      final companies = r[1] as List<Company>;
      final holidays = r[2] as List<HolidayMark>;

      final colorById = {for (final c in companies) c.id: c.color};
      final byDay = <String, _DayAgg>{};
      for (final w in records) {
        final key = _fmtDate(w.workDate);
        final agg = byDay.putIfAbsent(key, () => _DayAgg());
        agg.records.add(w);
        agg.subtotal += w.amountSnapshot; // 全整数
        final color = colorById[w.companyId];
        // 色点：distinct 公司标记色，保持首见顺序（03 §7.1）。
        if (color != null && !agg.colors.contains(color)) {
          agg.colors.add(color);
        }
      }

      if (!mounted) return;
      setState(() {
        _byDay = byDay;
        _holidayByDate = {for (final h in holidays) _fmtDate(h.date): h};
        _skipped = lenient.skipped;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      // 兜底（非脏行）：容错读只隔离「脏行」；连接/查询级失败仍走错误态 + 重试。
      // 脏行已由 listWorkRecordsLenient 隔离 → 顶部告警条（见 _skipped）。
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  // ── 翻月（跨年由 DateTime 自然进位；重新查询，不用跨月缓存，AC-P03-05）──

  void _shiftMonth(int delta) {
    final d = DateTime(_year, _month + delta, 1);
    setState(() {
      _year = d.year;
      _month = d.month;
      _loading = true;
    });
    _load();
  }

  Future<void> _openDay(DateTime day) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DayDetailPage(date: day)),
    );
    if (!mounted) return;
    await _load(); // 返回后重载（07 §0.2-7）
  }

  /// 角标独立入口 → P12a 节假日标记页（`AC-P03-06` 方案 α，不改 `HolidayMarkPage` 签名）。
  Future<void> _openHolidayMark() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HolidayMarkPage()),
    );
    if (!mounted) return;
    await _load(); // 返回后重载（07 §0.2-7）
  }

  // ── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('日历')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: () async {
        setState(() => _loading = true);
        await _load();
      });
    }
    final first = DateTime(_year, _month, 1);
    final daysInMonth = DateTime(_year, _month + 1, 0).day;
    final leadingBlanks = first.weekday - 1; // 周一为周首：Mon=1 → 0 个空位
    final today = DateTime.now();
    final hasData = _byDay.isNotEmpty;

    // 格子总数向上取整到 7 的倍数。
    final totalCells = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;

    return Column(
      children: [
        // 坏行告警条（`02:442` / `07 §4.4 D2`）：有任何坏行被跳过即提示。
        if (_skipped.isNotEmpty) _SkippedBanner(count: _skipped.length),
        _buildMonthHeader(),
        const _WeekdayHeader(),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 0.72,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: totalCells,
            itemBuilder: (context, i) {
              final dayNum = i - leadingBlanks + 1;
              if (dayNum < 1 || dayNum > daysInMonth) {
                return const SizedBox.shrink();
              }
              final date = DateTime(_year, _month, dayNum);
              final key = _fmtDate(date);
              final isToday = date.year == today.year &&
                  date.month == today.month &&
                  date.day == today.day; // 只比年月日（§1.3）
              return _DayCell(
                day: dayNum,
                agg: _byDay[key],
                holiday: _holidayByDate[key],
                isToday: isToday,
                onTap: () => _openDay(date),
                onHolidayTap: _holidayByDate[key] == null ? null : () => _openHolidayMark(),
              );
            },
          ),
        ),
        if (!hasData)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('本月还没记工',
                style: TextStyle(fontSize: 14, color: Colors.black54)),
          )
        else
          const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildMonthHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: () => _shiftMonth(-1),
            icon: const Icon(Icons.chevron_left),
            tooltip: '上个月',
          ),
          Text(
            '$_year年$_month月',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          IconButton(
            onPressed: () => _shiftMonth(1),
            icon: const Icon(Icons.chevron_right),
            tooltip: '下个月',
          ),
        ],
      ),
    );
  }
}

/// 单日聚合（全派生，不落库）。
class _DayAgg {
  final List<WorkRecord> records = <WorkRecord>[];
  int subtotal = 0; // 分
  final List<int> colors = <int>[]; // distinct 公司标记色（不含 alpha）
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const List<String> _labels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (final l in _labels)
            Expanded(
              child: Center(
                child: Text(l, style: const TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 月历格子：日期 + 色点行 + 当日小计；节假日底色 / 今天描边。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.agg,
    required this.holiday,
    required this.isToday,
    required this.onTap,
    this.onHolidayTap,
  });

  final int day;
  final _DayAgg? agg;
  final HolidayMark? holiday;
  final bool isToday;
  final VoidCallback onTap;

  /// 角标独立入口（`AC-P03-06`）：仅当命中节假日时由调用处传入；为空 = 不响应。
  /// 与 [onTap]（进 P04 日详情，`AC-P03-08`）相互独立，互不覆盖。
  final VoidCallback? onHolidayTap;

  @override
  Widget build(BuildContext context) {
    final subtotal = agg?.subtotal ?? 0;
    final colors = agg?.colors ?? const <int>[];
    final marked = holiday != null;

    return InkWell(
      onTap: onTap, // 无记录也进空态日详情（AC-P03-08）
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: marked ? _holidayFill(holiday!.type) : null,
          borderRadius: BorderRadius.circular(6),
          border: isToday
              ? Border.all(color: Colors.blue, width: 2)
              : Border.all(color: Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('$day',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    )),
                const Spacer(),
                if (marked)
                  GestureDetector(
                    onTap: onHolidayTap,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.local_offer,
                          size: 10, color: Colors.red.shade300),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            _ColorDots(colors: colors),
            const Spacer(),
            if (subtotal != 0)
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  fenToYuan(subtotal),
                  style: const TextStyle(
                      fontSize: 10, color: _kRedAmount, fontWeight: FontWeight.w500),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 节假日底色（法定 / 调休 / 自定义）。
  Color _holidayFill(HolidayType t) => switch (t) {
        HolidayType.statutory => Colors.red.shade50,
        HolidayType.workingSwap => Colors.orange.shade50,
        HolidayType.custom => Colors.blue.shade50,
      };
}

/// 色点行：`distinct` 公司标记色；>4 个显示 `+N`（`07:303` / AC-P03-02）。
class _ColorDots extends StatelessWidget {
  const _ColorDots({required this.colors});

  final List<int> colors;

  @override
  Widget build(BuildContext context) {
    if (colors.isEmpty) return const SizedBox(height: 8);
    const maxDots = 4;
    final shown = colors.take(maxDots).toList();
    final extra = colors.length - shown.length;
    return SizedBox(
      height: 8,
      child: Row(
        children: [
          for (final c in shown)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  // 必须补 alpha：禁 Color(color)（会得 0x00xxxxxx 全透明）→ AC-P03-03
                  color: Color(0xFF000000 | c),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          if (extra > 0)
            Text('+$extra',
                style: const TextStyle(fontSize: 8, color: Colors.black54)),
        ],
      ),
    );
  }
}

/// 顶部坏行告警条（`02:442` P03 异常态 / `07 §4.4 D2`）；文案与 P04 `_SkippedBanner` 一致。
class _SkippedBanner extends StatelessWidget {
  const _SkippedBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 20, color: Colors.amber.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '有 $count 条数据异常，未显示也未计入剩余',
              style: TextStyle(fontSize: 13, color: Colors.amber.shade900),
            ),
          ),
        ],
      ),
    );
  }
}

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
            const Icon(Icons.error_outline, size: 48, color: _kRedAmount),
            const SizedBox(height: 12),
            const Text('数据加载失败',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('$error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.black54)),
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

/// `yyyy-MM-dd`（日期归一，避免带时分秒的 `DateTime` 直接 `==`，§1.3）。
String _fmtDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
