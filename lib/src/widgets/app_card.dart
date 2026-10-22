import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../theme/app_surfaces.dart';
import '../theme/app_tokens.dart';
import 'info_icon.dart';

/// כרטיס סטנדרטי: משטח עם צל רך (בלי מסגרת), ריפוד ואופציונלית כותרת.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.padding,
    this.info,
    this.done = false,
    this.onTap,
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final EdgeInsetsGeometry? padding;

  /// הסבר שמוצג באייקון מידע ליד הכותרת.
  final String? info;

  /// שלב שהושלם: האייקון הופך לסימן וי בצבע הראשי.
  final bool done;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final content = Padding(
      padding: padding ?? const EdgeInsets.all(AppTokens.spaceMD),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(
              children: [
                AnimatedSwitcher(
                  duration: AppTokens.animNormal,
                  switchInCurve: Curves.easeOutBack,
                  transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                  child: done
                      ? Icon(
                          FluentIcons.checkmark_circle_24_filled,
                          key: const ValueKey('done'),
                          size: 22,
                          color: cs.primary,
                        )
                      : icon != null
                      ? Icon(icon, key: const ValueKey('icon'), size: 22, color: cs.onSurfaceVariant)
                      : const SizedBox.shrink(key: ValueKey('none')),
                ),
                if (done || icon != null) const SizedBox(width: AppTokens.spaceSM),
                Expanded(
                  child: Text(
                    title!,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: cs.primary),
                  ),
                ),
                if (info != null) InfoIcon(info!),
              ],
            ),
            const SizedBox(height: AppTokens.spaceMD),
          ],
          child,
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: AppTokens.borderRadiusAll, boxShadow: AppSurfaces.cardShadow(context)),
      child: Material(
        color: AppSurfaces.card(context),
        borderRadius: AppTokens.borderRadiusAll,
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}
