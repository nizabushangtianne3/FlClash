import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/system.dart';
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop && !safeModeBuild ? Proxy() : null;

String proxyEnvCommand(int port, {required bool isWindows}) {
  final url = 'http://127.0.0.1:$port';
  // PowerShell's `set` alias takes a variable name, and an unquoted
  // `$env:name=http://…` makes its parser run the URL as a command, so the
  // assignment needs both the alias gone and the value quoted.
  return isWindows ? "\$env:all_proxy='$url'" : 'export all_proxy=$url';
}
