import 'dart:async';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';

import 'application.dart';
import 'bootstrap.dart';
import 'common/common.dart';
import 'common/window.dart';

void main(List<String> args) {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final views = WidgetsBinding.instance.platformDispatcher.views;
      final view = views.isEmpty ? null : views.first;
      final pixelRatio = view?.devicePixelRatio;
      final physicalSize = view?.physicalSize;
      final viewSize =
          pixelRatio == null ||
              pixelRatio == 0 ||
              physicalSize == null ||
              physicalSize.isEmpty
          ? Size.zero
          : Size(
              physicalSize.width / pixelRatio,
              physicalSize.height / pixelRatio,
            );
      if (Platform.isLinux) {
        linkManager.seedInitialLink(args);
      }
      FlutterError.onError = (details) {
        Future.microtask(() {
          commonPrint.log(
            'exception: ${details.exception} stack: ${details.stack}',
            logLevel: LogLevel.warning,
          );
        });
      };
      try {
        await RustLib.init();
        final version = await system.init();
        final container = await bootstrap.init(version, viewSize: viewSize);
        HttpOverrides.global = FlClashHttpOverrides(container);
        request.attach(container.read);
        runApp(
          UncontrolledProviderScope(
            container: container,
            child: const Application(),
          ),
        );
      } catch (e, s) {
        runApp(
          MaterialApp(
            // The failure screen reads the app's own strings, so it needs the
            // delegates the running app installs; the locale is the system's,
            // because the saved setting may be what failed to load.
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: AppLocalizations.delegate.supportedLocales,
            home: InitErrorScreen(error: e, stack: s),
          ),
        );
        unawaited(window?.showInitFailure());
      }
    },
    (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}
