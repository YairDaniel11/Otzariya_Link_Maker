import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../theme/app_tokens.dart';
import 'app_card.dart';

/// קרדיט על הקוד של עריכת הספרים (יצירת הכותרות).
const creditsText = 'קרדיט על הקוד של עריכת הספרים (יצירת הכותרות): @יום חדש מתחיל, @pcinfogmach ו-@menajemmendel';

class CreditsCard extends StatelessWidget {
  const CreditsCard({super.key, this.compact = false});

  /// גרסה קטנה: שורה אחת בלי כותרת.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      creditsText,
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
    if (compact) {
      return Row(
        children: [
          Icon(FluentIcons.heart_24_regular, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: AppTokens.spaceSM),
          Expanded(child: text),
        ],
      );
    }
    return AppCard(title: 'קרדיט', icon: FluentIcons.heart_24_regular, child: text);
  }
}
