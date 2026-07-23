import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_locale_store.dart';

final appLocaleProvider = NotifierProvider<AppLocaleController, Locale>(AppLocaleController.new);

class AppLocaleController extends Notifier<Locale> {
  @override
  Locale build() => AppLocaleStore.cached;

  Future<void> setLocale(Locale locale) async {
    if (state == locale) return;
    state = locale;
    await AppLocaleStore.save(locale);
  }
}

