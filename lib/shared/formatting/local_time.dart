import 'package:intl/intl.dart';

/// 列表和消息共用本地时区的分钟级显示，当天省略日期，跨年保留年份。
String formatLocalTime(DateTime timestamp, String locale) {
  final local = timestamp.toLocal();
  final now = DateTime.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return DateFormat.Hm(locale).format(local);
  }
  return (local.year == now.year
          ? DateFormat.Md(locale)
          : DateFormat.yMd(locale))
      .add_Hm()
      .format(local);
}

/// 长按时间可查看包含年份的完整日期，显示和提示采用同一时区。
String formatFullLocalTime(DateTime timestamp, String locale) =>
    DateFormat.yMd(locale).add_Hm().format(timestamp.toLocal());
