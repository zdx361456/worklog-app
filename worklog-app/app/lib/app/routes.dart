/// 路由名常量。
///
/// **冻结说明（Wave 2 契约 §2）**：本文件在 Wave 2 冻结为「不得增删」。
///
/// **Wave A2 的例外（有据可查，非自行扩范围）**：死路由 `overview`（`'/'`）与
/// `records`（`'/records'`）已**随 4 Tab 导航骨架同批删除**。依据三处上游：
///   - `11-主理人裁定（WaveA设计）.md` §1 **Q-D1 施工硬约束 (a)**：「**必须**：把
///     `Routes.records` + `Routes.overview` 写入 Wave A2 交付清单（**与 4 Tab 落地同批**），防止遗忘」；
///   - `09-WaveA-实现设计.md` §13.1 **N-D7**：「**A2 清理时必须一并处理**（常量 +
///     `main.dart` case 同批，**不得只删其一**）」；
///   - `12-WaveA-批2归档与教训.md` §7：「死路由清理与 4 Tab 导航骨架…**同批**」。
///
/// 两条常量在全工程**零 `pushNamed` 调用**（`E-7` 已证实 `Routes.overview` 从未注册，
/// 故只删常量、无需删 case）；`main.dart` 对应的 `case Routes.records` 已同批移除。
///
/// **[companies] 是活路由，不得删**：P01「全部公司」等 3 处经
/// `pushNamed(Routes.companies)` 进入（`Q-D1` v2 追加 / `11 §5.1 M2`）。
///
/// - [workForm] / [paymentForm] 既用于**新建**也用于**编辑**：
///   编辑时通过 `?id=<id>` 查询串或 `arguments` 传入被编辑记录 id，
///   由 `main.dart` 的 `onGenerateRoute` 透传给页面构造函数。
library;

class Routes {
  Routes._(); // 纯常量容器，禁止实例化。

  static const String workForm = '/work/new';
  static const String paymentForm = '/payment/new';
  static const String companies = '/companies';
}
