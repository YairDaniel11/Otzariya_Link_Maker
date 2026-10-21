import 'package:flutter/material.dart';

/// טוקני מרווח ורדיוס — זהים ל"עדכוני אוצריא" (רדיוס 8 לכל הפינות).
class AppTokens {
  AppTokens._();
  static const double spaceXS = 4;
  static const double spaceSM = 8;
  static const double spaceMD = 16;
  static const double spaceLG = 24;
  static const double spaceXL = 32;
  static const double radius = 8;
  static const BorderRadius borderRadiusAll = BorderRadius.all(Radius.circular(radius));
  static const double fontSM = 12;
  static const double fontMD = 14;
  static const double fontLG = 16;
  static const double fontXL = 18;
  static const double contentMaxWidth = 860;
  static const Duration animFast = Duration(milliseconds: 150);
  static const Duration animNormal = Duration(milliseconds: 250);
}
