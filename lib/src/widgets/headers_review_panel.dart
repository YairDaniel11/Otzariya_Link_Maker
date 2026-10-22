import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../headers/book_builder.dart';
import '../headers/header_utils.dart';
import '../screens/headers/headers_jobs.dart';
import '../theme/app_surfaces.dart';
import '../theme/app_tokens.dart';
import 'common_widgets.dart';
import 'headers_rules_panel.dart' show levelName;

/// "בדיקה ותצוגה מקדימה": עץ כותרות מימין, טקסט סביב הכותרת הנבחרת משמאל, ובדיקות ונתונים מתחת.
class HeadersReviewPanel extends StatefulWidget {
  const HeadersReviewPanel({
    super.key,
    required this.lines,
    required this.heads,
    required this.built,
    required this.building,
    required this.onChanged,
    required this.onAddLine,
    this.bookTitle = '',
  });

  /// שם הספר (כותרת H1), מוצג בראש תוכן העניינים.
  final String bookTitle;

  /// שורות המקור (לתצוגה מקדימה).
  final List<String> lines;
  final List<HeadDto> heads;
  final BuiltBook? built;
  final bool building;

  /// שינוי בכותרת קיימת (סימון / רמה): המסך בונה מחדש.
  final VoidCallback onChanged;

  /// הוספת כותרת משורה (אינדקס מ-0).
  final void Function(int index) onAddLine;

  @override
  State<HeadersReviewPanel> createState() => _HeadersReviewPanelState();
}

class _HeadersReviewPanelState extends State<HeadersReviewPanel> {
  int? _focus; // שורה במרכז התצוגה (אינדקס)
  int? _picked; // שורה שנבחרה להוספה
  final _lineCtl = TextEditingController();
  final _previewScroll = ScrollController();
  static const _radius = 14;

  @override
  void dispose() {
    _lineCtl.dispose();
    _previewScroll.dispose();
    super.dispose();
  }

  void _focusOn(int i) => setState(() {
        _focus = i.clamp(0, widget.lines.length - 1);
        _picked = null;
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heads = widget.heads;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stats(context),
        const SizedBox(height: AppTokens.spaceMD),
        LayoutBuilder(
          builder: (context, c) {
            final toc = _toc(context);
            final prev = _preview(context);
            if (c.maxWidth >= 640) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: toc),
                  const SizedBox(width: AppTokens.spaceMD),
                  Expanded(child: prev),
                ],
              );
            }
            return Column(children: [toc, const SizedBox(height: AppTokens.spaceMD), prev]);
          },
        ),
        const SizedBox(height: AppTokens.spaceMD),
        _issues(context),
        if (heads.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.spaceSM),
            child: Hint('לא נמצאו כותרות. אפשר לבחור למעלה סוגי כותרות, או להוסיף כותרת ידנית מהטקסט.', error: false),
          ),
        Text('', style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _box(BuildContext context, {required String title, required Widget child, double height = 340}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: AppTokens.spaceXS),
        Container(
          height: height,
          decoration: BoxDecoration(
            color: AppSurfaces.inset(context),
            borderRadius: AppTokens.borderRadiusAll,
            border: Border.all(color: AppSurfaces.divider(context)),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ],
    );
  }

  Widget _stats(BuildContext context) {
    final b = widget.built;
    final per = b?.headingsPerLevel ?? const <int, int>{};
    final total = per.values.fold<int>(0, (s, v) => s + v);
    return Wrap(
      spacing: AppTokens.spaceSM,
      runSpacing: AppTokens.spaceSM,
      children: [
        StatTile('$total', 'כותרות בספר'),
        for (final e in (per.entries.toList()..sort((a, c) => a.key.compareTo(c.key))))
          if (e.key >= 2) StatTile('${e.value}', levelName(e.key)),
        StatTile('${widget.lines.length}', 'שורות'),
        StatTile('${b?.footnoteCount ?? 0}', 'הערות שוליים'),
        if (widget.building)
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
      ],
    );
  }

  Widget _toc(BuildContext context) {
    final theme = Theme.of(context);
    final heads = widget.heads;
    return _box(
      context,
      title: 'תוכן העניינים של הספר',
      child: heads.isEmpty && widget.bookTitle.trim().isEmpty
          ? const Center(child: Hint('אין כותרות'))
          : ListView.builder(
              itemCount: heads.length + 1,
              itemExtent: 40,
              itemBuilder: (context, k) {
                if (k == 0) return _titleRow(theme);
                final h = heads[k - 1];
                final selected = _focus == h.index;
                return Tooltip(
                  message: 'כותרת H${h.level}',
                  waitDuration: const Duration(milliseconds: 250),
                  child: InkWell(
                  key: ValueKey('head-${h.index}'),
                  onTap: () => _focusOn(h.index),
                  child: Container(
                    color: selected ? AppSurfaces.tint(theme.colorScheme.primary) : null,
                    padding: EdgeInsetsDirectional.only(start: 2 + (h.level - 2) * 16.0),
                    child: Row(
                      children: [
                        Checkbox(
                          visualDensity: VisualDensity.compact,
                          value: h.included,
                          onChanged: (v) {
                            setState(() => h.included = v ?? false);
                            widget.onChanged();
                          },
                        ),
                        Expanded(
                          child: Text(
                            h.plain.isEmpty ? '(ריק)' : h.plain,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: h.level <= 2 ? FontWeight.bold : FontWeight.normal,
                              color: h.included ? null : theme.disabledColor,
                              decoration: h.included ? null : TextDecoration.lineThrough,
                            ),
                          ),
                        ),
                        Text('${h.index + 1}', style: theme.textTheme.bodySmall),
                        IconButton(
                          tooltip: 'הפחת רמה (כותרת ראשית יותר)',
                          visualDensity: VisualDensity.compact,
                          iconSize: 16,
                          icon: const Icon(FluentIcons.subtract_24_regular),
                          onPressed: h.level <= 2
                              ? null
                              : () {
                                  setState(() => h.level--);
                                  widget.onChanged();
                                },
                        ),
                        IconButton(
                          tooltip: 'הוסף רמה (כותרת משנית יותר)',
                          visualDensity: VisualDensity.compact,
                          iconSize: 16,
                          icon: const Icon(FluentIcons.add_24_regular),
                          onPressed: h.level >= 6
                              ? null
                              : () {
                                  setState(() => h.level++);
                                  widget.onChanged();
                                },
                        ),
                      ],
                    ),
                  ),
                  ),
                );
              },
            ),
    );
  }

  /// שורת שם הספר בראש תוכן העניינים: תמיד H1, לא ניתנת להסרה.
  Widget _titleRow(ThemeData theme) {
    final t = widget.bookTitle.trim();
    return Tooltip(
      message: 'כותרת H1 (שם הספר)',
      waitDuration: const Duration(milliseconds: 250),
      child: Container(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 12),
        alignment: AlignmentDirectional.centerStart,
        child: Row(
          children: [
            Icon(FluentIcons.book_24_regular, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t.isEmpty ? '(שם הספר)' : t,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(BuildContext context) {
    final theme = Theme.of(context);
    final lines = widget.lines;
    final focus = _focus;
    final byIndex = {for (final h in widget.heads) h.index: h};
    Widget body;
    if (focus == null || lines.isEmpty) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(AppTokens.spaceMD),
          child: Text('לחצו על כותרת בצד כדי לראות את הטקסט סביבה, או בחרו מספר שורה למטה.', textAlign: TextAlign.center),
        ),
      );
    } else {
      final from = (focus - _radius).clamp(0, lines.length - 1);
      final to = (focus + _radius).clamp(0, lines.length - 1);
      body = ListView.builder(
        controller: _previewScroll,
        itemCount: to - from + 1,
        itemBuilder: (context, k) {
          final i = from + k;
          final h = byIndex[i];
          final isHead = h != null && h.included;
          var text = plainText(lines[i]).trim();
          if (text.length > 160) text = '${text.substring(0, 160)}...';
          return InkWell(
            key: ValueKey('line-$i'),
            onTap: () => setState(() {
              _picked = i;
              _lineCtl.text = '${i + 1}';
            }),
            child: Container(
              color: _picked == i
                  ? AppSurfaces.tint(theme.colorScheme.tertiary)
                  : (i == focus ? AppSurfaces.tint(theme.colorScheme.primary) : null),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 40,
                    child: Text('${i + 1}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: Text(
                      text.isEmpty ? ' ' : text,
                      style: TextStyle(
                        fontWeight: isHead ? FontWeight.bold : FontWeight.normal,
                        color: isHead ? theme.colorScheme.primary : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }
    final pickedHead = _picked != null && byIndex[_picked!] != null && byIndex[_picked!]!.included;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _box(context, title: 'הטקסט סביב הכותרת', child: body, height: 296),
        const SizedBox(height: AppTokens.spaceSM),
        Row(
          children: [
            SizedBox(
              width: 100,
              child: TextField(
                controller: _lineCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'שורה מספר', isDense: true),
                onSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 1 && n <= lines.length) {
                    _focusOn(n - 1);
                    setState(() => _picked = n - 1);
                  }
                },
              ),
            ),
            const SizedBox(width: AppTokens.spaceSM),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _picked == null || pickedHead
                    ? null
                    : () {
                        widget.onAddLine(_picked!);
                        setState(() => _picked = null);
                      },
                icon: const Icon(FluentIcons.text_header_1_24_regular, size: 18),
                label: const Text('הפוך שורה זו לכותרת'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _issues(BuildContext context) {
    final theme = Theme.of(context);
    final b = widget.built;
    if (b == null) return const SizedBox.shrink();
    final issues = b.issues.where((i) => i.severity != IssueSeverity.info).toList()
      ..sort((a, c) => a.severity.index.compareTo(c.severity.index));
    final errors = issues.where((i) => i.severity == IssueSeverity.error).length;
    if (issues.isEmpty) {
      return const Row(children: [Tag('הבדיקה עברה בהצלחה, לא נמצאו בעיות', kind: TagKind.good)]);
    }
    const amber = Color(0xFFB26A00);
    final amberFg = theme.brightness == Brightness.dark ? const Color(0xFFFFB74D) : amber;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          errors > 0
              ? 'נמצאו $errors בעיות שכדאי לתקן ו-${issues.length - errors} הערות'
              : 'נמצאו ${issues.length} הערות (לא חוסמות את השמירה)',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppTokens.spaceXS),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: Container(
            decoration: BoxDecoration(
              color: AppSurfaces.inset(context),
              borderRadius: AppTokens.borderRadiusAll,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: issues.length > 100 ? 100 : issues.length,
              itemBuilder: (context, k) {
                final i = issues[k];
                final isErr = i.severity == IssueSeverity.error;
                final color = isErr ? theme.colorScheme.error : amberFg;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    isErr ? FluentIcons.error_circle_24_regular : FluentIcons.warning_24_regular,
                    color: color,
                    size: 20,
                  ),
                  title: Text(i.message, style: TextStyle(color: color)),
                  subtitle: i.line > 0 ? Text('בקובץ שיישמר, שורה ${i.line}') : null,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
