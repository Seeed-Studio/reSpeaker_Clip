import 'package:flutter/widgets.dart';

/// Design tokens: corner radii
///
/// Most common in app: 8/10/12/14/16/18/20/24/26/999 (pill)
class AppRadii {
  AppRadii._();

  static const double r4 = 4;
  static const double r6 = 6;
  static const double r8 = 8;
  static const double r10 = 10;
  static const double r12 = 12;
  static const double r14 = 14;
  static const double r16 = 16;
  static const double r18 = 18;
  static const double r20 = 20;
  static const double r28 = 28;
  static const double r24 = 24;
  static const double r26 = 26;

  static const double pill = 999;

  static const BorderRadius br8 = BorderRadius.all(Radius.circular(r8));
  static const BorderRadius br12 = BorderRadius.all(Radius.circular(r12));
  static const BorderRadius br14 = BorderRadius.all(Radius.circular(r14));
  static const BorderRadius br16 = BorderRadius.all(Radius.circular(r16));
  static const BorderRadius br18 = BorderRadius.all(Radius.circular(r18));
  static const BorderRadius br20 = BorderRadius.all(Radius.circular(r20));
  static const BorderRadius br28 = BorderRadius.all(Radius.circular(r28));
  static const BorderRadius br24 = BorderRadius.all(Radius.circular(r24));
  static const BorderRadius br26 = BorderRadius.all(Radius.circular(r26));
  static const BorderRadius pillRadius = BorderRadius.all(Radius.circular(pill));
}

