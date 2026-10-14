/// 本地 id 生成（**不引入 uuid 依赖**）。格式 `<prefix>-<微秒时间戳>-<base36随机>`。
///
/// 设计取舍：基础版单机、单账本，无需全局唯一性保证，只需「本机不碰撞 + 时间有序
/// （便于调试与排序）」。微秒时间戳 + 6 位 base36 随机后缀，在同一微秒内还有
/// 36^6 ≈ 21.8 亿 种后缀，实际碰撞概率可忽略。
///
/// 前缀约定：账本 `led`、公司 `co`、规则 `rule`、工作 `wr`、收款 `pm`。
library;

import 'dart:math';

final Random _rng = Random();

/// 生成形如 `<prefix>-<微秒时间戳>-<base36随机>` 的本地唯一 id。
String newId(String prefix) {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return '$prefix-$ts-${_randomBase36(6)}';
}

const String _base36Chars = '0123456789abcdefghijklmnopqrstuvwxyz';

String _randomBase36(int len) {
  final buf = StringBuffer();
  for (var i = 0; i < len; i++) {
    buf.write(_base36Chars[_rng.nextInt(_base36Chars.length)]);
  }
  return buf.toString();
}
