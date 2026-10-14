/// 金额格式化 / 解析（元 ↔ 分）。
///
/// **纪律（契约 §2 / 03 §4.6）**：元↔分 转换**必须走字符串解析**（小数点后补/截 2 位），
/// **禁止** `double × 100` 后再 `round()`——浮点误差会在大额或特定小数上产生 ±1 分的偏移。
library;

/// `123456` → `'¥1,234.56'`（带 `¥` 符号与千分位）。
/// 负值前置 `-`（例：`-123456` → `'-¥1,234.56'`）。所有界面金额展示一律用它。
String fenToYuan(int fen) {
  final negative = fen < 0;
  final absFen = fen.abs();
  final yuan = absFen ~/ 100;
  final cents = absFen % 100;
  final body = '¥${_groupThousands(yuan.toString())}.${_twoDigits(cents)}';
  return negative ? '-$body' : body;
}

/// `123456` → `'1234.56'`（**无**符号、**无**千分位，供输入框编辑/回填用）。
String fenToYuanPlain(int fen) {
  final negative = fen < 0;
  final absFen = fen.abs();
  final yuan = absFen ~/ 100;
  final cents = absFen % 100;
  final body = '$yuan.${_twoDigits(cents)}';
  return negative ? '-$body' : body;
}

/// 解析用户输入的元金额 → 分。接受 `'1234.56'` / `'12'` / `'12.5'` / `'¥1,234.56'` / `' 12.5 '`。
/// 非法（空串 / 非数字 / 小数位 > 2）→ 返回 `null`（由调用方给校验提示，**不静默兜底**）。
int? yuanToFen(String text) {
  var t = text.trim();
  if (t.isEmpty) return null;

  var negative = false;
  if (t.startsWith('-')) {
    negative = true;
    t = t.substring(1).trim();
  } else if (t.startsWith('+')) {
    t = t.substring(1).trim();
  }
  if (t.startsWith('¥') || t.startsWith('￥')) t = t.substring(1).trim();
  t = t.replaceAll(',', ''); // 容忍千分位输入
  if (t.isEmpty) return null;

  final dotParts = t.split('.');
  if (dotParts.length > 2) return null; // 多于一个小数点 → 非法

  final intPart = dotParts[0].isEmpty ? '0' : dotParts[0];
  final fracPart = dotParts.length == 2 ? dotParts[1] : '';
  if (!_isDigits(intPart)) return null;
  if (fracPart.isNotEmpty && !_isDigits(fracPart)) return null;
  if (fracPart.length > 2) return null; // 超过 2 位小数：非法（不静默截断）

  final yuanValue = int.tryParse(intPart);
  if (yuanValue == null) return null;
  final cents = fracPart.isEmpty ? 0 : int.parse(fracPart.padRight(2, '0'));
  final total = yuanValue * 100 + cents;
  return negative ? -total : total;
}

bool _isDigits(String s) {
  if (s.isEmpty) return false;
  for (final c in s.codeUnits) {
    if (c < 0x30 || c > 0x39) return false; // '0'..'9'
  }
  return true;
}

String _twoDigits(int n) => n < 10 ? '0$n' : '$n';

String _groupThousands(String digits) {
  if (digits.length <= 3) return digits;
  final firstGroup = digits.length % 3;
  final buf = StringBuffer();
  if (firstGroup > 0) buf.write(digits.substring(0, firstGroup));
  for (var i = firstGroup; i < digits.length; i += 3) {
    if (buf.isNotEmpty) buf.write(',');
    buf.write(digits.substring(i, i + 3));
  }
  return buf.toString();
}
