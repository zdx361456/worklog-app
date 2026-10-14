/// 数据变更广播：任何写操作后调用 [DataBus.dataChanged]，展示类页面据此重载。
///
/// 用纯 Flutter 内置 `ChangeNotifier`（不引 provider / riverpod 等状态管理库）。
/// 展示页用 `ListenableBuilder(listenable: dataBus, ...)` 或 `addListener` 监听。
library;

import 'package:flutter/foundation.dart';

class DataBus extends ChangeNotifier {
  /// 广播一次「数据已变更」。写入端（表单/公司管理）在落库成功后调用即可。
  void dataChanged() => notifyListeners();
}

/// 全局单例：全 App 共用一条数据变更总线。
final DataBus dataBus = DataBus();
