/// 应用级全局状态（基础版：仅当前账本 id）。
///
/// 基础版为**单账本**（`LedgerMode.local`），账本 id 在首启初始化后赋值一次，
/// 之后全局只读使用（见 `main.dart` 的 bootstrap）。
library;

class AppState {
  AppState._(); // 纯静态容器，禁止实例化。

  /// 首启初始化后赋值的当前账本 id（`null` = 尚未初始化完成）。
  static String? ledgerId;

  /// 默认账本名（首启自动创建账本时使用）。
  static const String defaultLedgerName = '我的账本';
}
