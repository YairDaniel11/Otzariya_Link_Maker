import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../engine/auto_links.dart';
import '../theme/app_surfaces.dart';
import '../theme/app_tokens.dart';
import 'app_card.dart';

/// מציג את ההודעה האחרונה של הקונטרולר, עם כפתור סגירה.
class MessageBanner extends StatefulWidget {
  const MessageBanner({super.key, required this.controller});

  final AppController controller;

  @override
  State<MessageBanner> createState() => _MessageBannerState();
}

class _MessageBannerState extends State<MessageBanner> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final msg = controller.lastMessage;
    final err = controller.lastMessageIsError;
    final cs = Theme.of(context).colorScheme;
    final bg = err ? cs.errorContainer : cs.secondaryContainer;
    final fg = err ? cs.onErrorContainer : cs.onSecondaryContainer;
    return AnimatedSize(
      duration: AppTokens.animNormal,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppTokens.animNormal,
        transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
        child: msg == null
            ? const SizedBox(width: double.infinity, key: ValueKey('empty'))
            : Container(
                key: ValueKey('$err$msg'),
                padding: const EdgeInsetsDirectional.only(start: AppTokens.spaceMD, end: AppTokens.spaceXS),
                decoration: BoxDecoration(color: bg, borderRadius: AppTokens.borderRadiusAll),
                child: Row(
                  children: [
                    Icon(
                      err ? FluentIcons.error_circle_24_regular : FluentIcons.checkmark_circle_24_regular,
                      color: fg,
                      size: 20,
                    ),
                    const SizedBox(width: AppTokens.spaceSM),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSM),
                        child: SelectableText(msg, style: TextStyle(color: fg)),
                      ),
                    ),
                    IconButton(
                      tooltip: 'סגור',
                      icon: Icon(FluentIcons.dismiss_24_regular, color: fg, size: 20),
                      onPressed: controller.clearMessage,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// כרטיס התקדמות של פעולה ארוכה, עם כפתור "עצור".
class ActivityCard extends StatelessWidget {
  const ActivityCard({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final a = controller.activity;
    if (a == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(a.title, style: theme.textTheme.titleMedium)),
              if (a.progress != null) ...[
                Text('${(a.progress! * 100).round()}%', style: theme.textTheme.titleSmall),
                const SizedBox(width: AppTokens.spaceSM),
              ],
              OutlinedButton.icon(
                onPressed: a.cancelled ? null : controller.cancelActivity,
                icon: const Icon(FluentIcons.stop_24_regular, size: 18),
                label: Text(a.cancelled ? 'עוצר...' : 'עצור'),
              ),
            ],
          ),
          if (a.detail.isNotEmpty) ...[
            const SizedBox(height: AppTokens.spaceXS),
            Text(
              a.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: AppTokens.spaceSM),
          ClipRRect(
            borderRadius: AppTokens.borderRadiusAll,
            child: LinearProgressIndicator(value: a.progress),
          ),
        ],
      ),
    );
  }
}

/// תגית קטנה בצבע לפי מצב: אייקון וטקסט על רקע מעומעם.
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.kind = TagKind.neutral});

  final String label;
  final TagKind kind;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (color, icon) = switch (kind) {
      TagKind.good => (cs.primary, FluentIcons.checkmark_circle_24_regular),
      TagKind.warn => (cs.tertiary, FluentIcons.info_24_regular),
      TagKind.error => (cs.error, FluentIcons.error_circle_24_regular),
      TagKind.neutral => (cs.onSurfaceVariant, null),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: AppSurfaces.tint(color), borderRadius: AppTokens.borderRadiusAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 5)],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: AppTokens.fontSM, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

enum TagKind { good, warn, error, neutral }

/// תגית סטטוס קישורים של ספר.
class LinkStatusTag extends StatelessWidget {
  const LinkStatusTag(this.status, {super.key});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
    LinkStatus.linked => const Tag('קושר', kind: TagKind.good),
    LinkStatus.notLinked => const Tag('לא קושר', kind: TagKind.warn),
    LinkStatus.manual => const Tag('קישורים משלך'),
    LinkStatus.disabled => const Tag('בוטל'),
  };
}

/// שורת מספר + תווית בכרטיס סיכום.
class StatTile extends StatelessWidget {
  const StatTile(this.value, this.label, {super.key});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 110),
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMD, vertical: AppTokens.spaceSM),
      decoration: BoxDecoration(color: AppSurfaces.inset(context), borderRadius: AppTokens.borderRadiusAll),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.primary),
          ),
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// עמוד ברוחב מוגבל וממורכז. עם [itemCount] ו-[itemBuilder] נבנית גם רשימה ארוכה בעצלות.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.controller, this.itemCount = 0, this.itemBuilder});

  final List<Widget> children;
  final ScrollController? controller;
  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (itemBuilder == null) {
      return ListView(
        controller: controller,
        padding: const EdgeInsets.all(AppTokens.spaceMD),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppTokens.spaceMD),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.all(AppTokens.spaceMD),
      itemCount: children.length + itemCount,
      itemBuilder: (context, i) {
        final isChild = i < children.length;
        final gap = i == 0 ? 0.0 : (isChild || i == children.length ? AppTokens.spaceMD : AppTokens.spaceXS);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
            child: Padding(
              padding: EdgeInsets.only(top: gap),
              child: SizedBox(
                width: double.infinity,
                child: isChild ? children[i] : itemBuilder!(context, i - children.length),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// מצב ריק: אייקון גדול, הסבר ופעולה אופציונלית.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceMD),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(AppTokens.spaceMD),
            decoration: BoxDecoration(color: AppSurfaces.tint(cs.primary), shape: BoxShape.circle),
            child: Icon(icon, size: 32, color: cs.primary),
          ),
          const SizedBox(height: AppTokens.spaceMD),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          if (message != null) ...[
            const SizedBox(height: AppTokens.spaceXS),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: AppTokens.spaceMD), action!],
        ],
      ),
    );
  }
}

/// כפתור העתקה ללוח, עם הודעת אישור.
class CopyButton extends StatelessWidget {
  const CopyButton(this.text, {super.key, required this.onCopied});

  final String text;
  final VoidCallback onCopied;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'העתק',
    visualDensity: VisualDensity.compact,
    icon: const Icon(FluentIcons.copy_24_regular, size: 18),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: text));
      onCopied();
    },
  );
}

/// טקסט משני (אפור).
class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// נתיב קובץ: תמיד משמאל לימין (אחרת "C:\ספרים" מתהפך בממשק עברי), מיושר לימין.
class PathText extends StatelessWidget {
  const PathText(this.path, {super.key, this.maxLines});

  final String path;
  final int? maxLines;

  /// סימן כיוון שמאל-לימין אחרי כל מפריד: כל חלק בנתיב עומד בפני עצמו, וסדר החלקים נשמר.
  static final _lrm = String.fromCharCode(0x200E);
  static final _sep = String.fromCharCode(0x5C); // לוכסן הפוך

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: SelectableText(
      path.replaceAll(_sep, '$_sep$_lrm').replaceAll('/', '/$_lrm'),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
      maxLines: maxLines,
    ),
  );
}
