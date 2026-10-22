import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../headers/txt_headers.dart';
import '../screens/headers/headers_jobs.dart';
import '../theme/app_surfaces.dart';
import '../theme/app_tokens.dart';
import 'common_widgets.dart';

/// "רמה 1" = h2 (h1 שמור לשם הספר).
String levelName(int htmlLevel) => 'רמה ${htmlLevel - 1}';

/// רשימת "אילו שורות הן כותרות?": תיבת סימון לכל כלל, דוגמה, מספר התאמות ובחירת רמה.
class HeadersRulesPanel extends StatelessWidget {
  const HeadersRulesPanel({
    super.key,
    required this.presets,
    required this.customs,
    required this.counts,
    required this.selected,
    required this.levels,
    required this.busy,
    required this.onToggle,
    required this.onLevel,
    required this.onAuto,
    required this.onAddCustom,
    required this.onRemoveCustom,
  });

  final List<HeadingRule> presets;
  final List<CustomSpec> customs;
  final Map<String, int> counts;
  final Set<String> selected;
  final Map<String, int> levels;
  final bool busy;
  final void Function(String id, bool on) onToggle;
  final void Function(String id, int? level) onLevel;
  final VoidCallback onAuto;
  final VoidCallback onAddCustom;
  final void Function(CustomSpec spec) onRemoveCustom;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppTokens.spaceSM,
          runSpacing: AppTokens.spaceSM,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : onAuto,
              icon: const Icon(FluentIcons.sparkle_24_regular, size: 18),
              label: const Text('זיהוי אוטומטי'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : onAddCustom,
              icon: const Icon(FluentIcons.add_24_regular, size: 18),
              label: const Text('הוסף כלל משלי'),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.spaceSM),
        const Hint('סמנו את סוגי השורות שהם כותרות בספר שלכם. המספר ליד כל שורה הוא כמה שורות בקובץ מתאימות לה.'),
        const SizedBox(height: AppTokens.spaceSM),
        for (final r in presets)
          _RuleRow(
            key: ValueKey('rule-${r.id}'),
            id: r.id,
            label: r.label,
            example: r.example,
            count: counts[r.id],
            selected: selected.contains(r.id),
            level: levels[r.id],
            onToggle: onToggle,
            onLevel: onLevel,
          ),
        for (final c in customs)
          _RuleRow(
            key: ValueKey('rule-${c.id}'),
            id: c.id,
            label: c.regex ? 'ביטוי משלי: ${c.text}' : 'שורה שמתחילה ב"${c.text}"',
            example: null,
            count: counts[c.id],
            selected: selected.contains(c.id),
            level: levels[c.id],
            onToggle: onToggle,
            onLevel: onLevel,
            onRemove: () => onRemoveCustom(c),
          ),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.id,
    required this.label,
    required this.example,
    required this.count,
    required this.selected,
    required this.level,
    required this.onToggle,
    required this.onLevel,
    this.onRemove,
  });

  final String id, label;
  final String? example;
  final int? count, level;
  final bool selected;
  final void Function(String id, bool on) onToggle;
  final void Function(String id, int? level) onLevel;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final none = count == 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? AppSurfaces.tint(theme.colorScheme.primary) : null,
          borderRadius: AppTokens.borderRadiusAll,
        ),
        child: Row(
          children: [
            Checkbox(value: selected, onChanged: (v) => onToggle(id, v ?? false)),
            Expanded(
              child: InkWell(
                onTap: () => onToggle(id, !selected),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: TextStyle(color: none && !selected ? theme.disabledColor : null)),
                      if (example != null)
                        Text(
                          'לדוגמה: $example',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (count != null) ...[
              Tag(count == 0 ? 'אין' : '$count', kind: count == 0 ? TagKind.neutral : TagKind.good),
              const SizedBox(width: AppTokens.spaceSM),
            ],
            SizedBox(
              width: 128,
              child: DropdownButton<int?>(
                isExpanded: true,
                isDense: true,
                value: level,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('רמה אוטומטית')),
                  for (var l = 2; l <= 6; l++) DropdownMenuItem<int?>(value: l, child: Text(levelName(l))),
                ],
                onChanged: (v) => onLevel(id, v),
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: 'הסר כלל',
                icon: const Icon(FluentIcons.dismiss_24_regular, size: 18),
                onPressed: onRemove,
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// חלון "הוסף כלל משלי". מחזיר את הכלל, או null בביטול.
Future<CustomSpec?> showAddCustomRuleDialog(BuildContext context) {
  final ctl = TextEditingController();
  var regex = false;
  String? error;
  return showDialog<CustomSpec>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('הוסף כלל משלי'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('כל שורה שמתחילה בטקסט שתכתבו תהפוך לכותרת.'),
              const SizedBox(height: AppTokens.spaceSM),
              TextField(
                controller: ctl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: regex ? 'ביטוי רגולרי' : 'השורה מתחילה ב...',
                  hintText: regex ? r'^פרק \d+' : 'לדוגמה: שיעור',
                  errorText: error,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: regex,
                onChanged: (v) => setS(() => regex = v ?? false),
                title: const Text('מתקדם: זה ביטוי רגולרי'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
          FilledButton(
            onPressed: () {
              final t = ctl.text.trim();
              if (t.isEmpty) {
                setS(() => error = 'כתבו טקסט לחיפוש');
                return;
              }
              final spec = CustomSpec(regex, t);
              try {
                spec.build();
              } catch (e) {
                setS(() => error = e.toString());
                return;
              }
              Navigator.pop(ctx, spec);
            },
            child: const Text('הוסף'),
          ),
        ],
      ),
    ),
  );
}
