import 'package:flutter/material.dart';

/// משטחי המסך: רקע לוח רך, כרטיסים עם צל עדין, וקו הפרדה — בהשראת "עדכוני אוצריא".
class AppSurfaces {
  AppSurfaces._();

  static bool _dark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  static Color panelBackground(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _dark(context)
        ? Colors.black
        : Color.alphaBlend(cs.surfaceContainerHighest.withValues(alpha: 0.475), cs.surface);
  }

  static Color card(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _dark(context) ? cs.surfaceContainer : cs.surface;
  }

  static List<BoxShadow> cardShadow(BuildContext context) => _dark(context)
      ? const []
      : [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2))];

  static Color divider(BuildContext context) => Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6);

  static Color inset(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);

  static Color tint(Color base) => base.withValues(alpha: 0.12);
}
