import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../theme/app_surfaces.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/common_widgets.dart';
import '../widgets/credits_card.dart';

/// דף הבית: שלוש כרטיסיות גדולות, אחת לכל כלי.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller, required this.onGo});

  final AppController controller;

  /// מעבר למסך לפי אינדקס בסרגל הצד.
  final void Function(int index) onGo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final noDb = !controller.hasOfficial;
        return PageBody(
          children: [
            Text(
              'מה רוצים לעשות?',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            _ToolCard(
              icon: FluentIcons.book_add_24_regular,
              title: 'יצירת כותרות לספר חדש',
              text: 'יש לכם קובץ Word, Markdown או טקסט? התוכנה מוסיפה כותרות ומכינה ספר מוכן להוספה לאוצריא.',
              action: 'בחרו קובץ',
              onTap: () => onGo(1),
            ),
            _ToolCard(
              icon: FluentIcons.link_24_regular,
              title: 'יצירת קישורים לפירוש',
              text: 'מקשרים פירוש לספר שהוא מפרש (למשל גמרא או שולחן ערוך), לפי הכותרות שבו.',
              action: 'צרו קישורים',
              onTap: () => onGo(2),
            ),
            _ToolCard(
              icon: FluentIcons.checkmark_starburst_24_regular,
              title: 'בדיקה ותיקון קישורים קיימים',
              text: 'אחרי שהוספתם או מחקתם שורות בספרים, התוכנה בודקת את הקישורים ומתקנת אותם.',
              action: 'בדקו קישורים',
              onTap: () => onGo(3),
            ),
            if (noDb)
              AppCard(
                icon: FluentIcons.info_24_regular,
                title: 'לא נמצאה הספרייה של אוצריא',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'יצירת קישורים ובדיקתם צריכות את הספרייה של אוצריא (הקובץ seforim.db). בלי זה אפשר ליצור כותרות.',
                    ),
                    const SizedBox(height: AppTokens.spaceSM),
                    OutlinedButton.icon(
                      onPressed: () => onGo(5),
                      icon: const Icon(FluentIcons.settings_24_regular),
                      label: const Text('בחירת הקובץ בהגדרות'),
                    ),
                  ],
                ),
              ),
            const CreditsCard(compact: true),
          ],
        );
      },
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.title,
    required this.text,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String title, text, action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppTokens.spaceLG),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(AppTokens.spaceMD),
            decoration: BoxDecoration(color: AppSurfaces.tint(cs.primary), shape: BoxShape.circle),
            child: Icon(icon, size: 36, color: cs.primary),
          ),
          const SizedBox(width: AppTokens.spaceMD),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: AppTokens.spaceXS),
                Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.spaceMD),
          FilledButton(onPressed: onTap, child: Text(action)),
        ],
      ),
    );
  }
}
