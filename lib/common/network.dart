import 'dart:io';

import 'package:flutter/foundation.dart';

typedef NetworkInterfaceLister =
    Future<List<NetworkInterface>> Function({bool includeLoopback});

@visibleForTesting
NetworkInterfaceLister listNetworkInterfaces =
    ({bool includeLoopback = false}) =>
        NetworkInterface.list(includeLoopback: includeLoopback);

extension NetworkInterfaceExt on NetworkInterface {
  bool get isWifi {
    final nameLowCase = name.toLowerCase();
    if (nameLowCase.contains('wlan') ||
        nameLowCase.contains('wi-fi') ||
        nameLowCase == 'en0' ||
        nameLowCase == 'eth0') {
      return true;
    }

    return false;
  }

  bool get includesIPv4 {
    return addresses.any((addr) => addr.isIPv4);
  }
}

extension InternetAddressExt on InternetAddress {
  bool get isIPv4 {
    return type == InternetAddressType.IPv4;
  }
}

Future<String?> getLocalIpAddress() async {
  final interfaces = await listNetworkInterfaces(includeLoopback: false);
  final ranked =
      [
        for (final interface in interfaces)
          (
            interface: interface,
            wifi: interface.isWifi,
            ipv4: interface.includesIPv4,
          ),
      ]..sort((a, b) {
        if (a.wifi != b.wifi) return a.wifi ? -1 : 1;
        if (a.ipv4 != b.ipv4) return a.ipv4 ? -1 : 1;
        return 0;
      });
  for (final entry in ranked) {
    final interface = entry.interface;
    final addresses = interface.addresses;
    if (addresses.isEmpty) {
      continue;
    }
    for (final address in addresses) {
      if (address.isIPv4) {
        return address.address;
      }
    }
    return addresses.first.address;
  }
  return '';
}
