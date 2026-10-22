import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../engine/common.dart';
import '../engine/linker_core.dart';
import '../engine/seforim_db.dart';
import '../services/jobs.dart';
import '../theme/app_surfaces.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/common_widgets.dart';
import 'ai_scan_dialog.dart';

/// יצירת קישורים לפירוש: בוחרים קובץ, על איזה ספר הוא מפרש, בודקים ושומרים links.csv.
class CreateLinksScreen extends StatefulWidget {
  const CreateLinksScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<CreateLinksScreen> createState() => _CreateLinksScreenState();
}

class _CreateLinksScreenState extends State<CreateLinksScreen> {
  var _files = <BookInfo>[];

  /// תוכנית הקישור לכל קובץ (לפי נתיב).
  final _plans = <String, LinkPlan>{};
  final _detect = <String, DetectResult>{};
  List<String> _titles = const [];
  PreviewResult? _preview;
  String? _savedPath;
  final _targetCtl = TextEditingController();
  String? _preset;

  AppController get c => widget.controller;

  @override
  void dispose() {
    _targetCtl.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final r = await FilePicker.pickFiles(
      dialogTitle: 'בחירת קובץ הספר',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    final paths = [for (final f in r) if (f.path != null) f.path!];
    if (paths.isEmpty) return;
    final infos = <BookInfo>[];
    for (final path in paths) {
      final i = await runJob(bookInfoJob, path);
      infos.add(i);
    }
    if (!mounted) return;
    setState(() {
      _files = infos;
      _plans.clear();
      _detect.clear();
      _preview = null;
      _savedPath = null;
      _preset = null;
      _targetCtl.clear();
    });
    if (c.hasOfficial) {
      _titles = await c.loadTitles();
      if (mounted) setState(() {});
      await _autoDetect();
    }
  }

  Future<void> _autoDetect() async {
    if (_files.isEmpty) return;
    if (!c.hasOfficial) {
      c.showMessage('צריך קודם לבחור את הספרייה של אוצריא בהגדרות.', error: true);
      return;
    }
    final args = DetectArgs(c.settings.officialDb, [for (final f in _files) f.path]);
    final r = await c.run(
      'מזהה את הספר שהקובץ מפרש',
      (onProgress, cancelled) => runJob(detectJob, args, onProgress: onProgress, isCancelled: cancelled),
    );
    if (r == null || !mounted) return;
    setState(() {
      _plans.clear();
      _detect.clear();
      for (final d in r) {
        _detect[d.path] = d;
        if (d.plan != null && d.status == DetectStatus.found) _plans[d.path] = d.plan!;
      }
      final first = r.isEmpty ? null : r.first;
      if (first != null && first.target.isNotEmpty) _targetCtl.text = first.target;
    });
    if (_plans.isNotEmpty) await _makePreview();
  }

  /// בחירת ספר יעד ידנית לכל הקבצים.
  Future<void> _chooseTarget(String target) async {
    if (!c.hasOfficial) return;
    setState(() {
      for (final f in _files) {
        _plans[f.path] = LinkPlan(target: target, label: 'לפי מבנה ספר היעד');
      }
      _preset = null;
    });
    await _makePreview();
  }

  Future<void> _choosePreset(String? name) async {
    if (name == null || _plans.isEmpty && _targetCtl.text.trim().isEmpty) return;
    final target = _targetCtl.text.trim();
    final prof = presets[name]!;
    setState(() {
      _preset = name;
      for (final f in _files) {
        _plans[f.path] = LinkPlan(profile: target.isEmpty ? prof : prof.withTarget(target, reset: false), label: name);
      }
    });
    await _makePreview();
  }

  Future<void> _aiScan() async {
    if (_files.isEmpty || !c.hasOfficial) return;
    final f = _files.first;
    final db = SeforimDb(c.settings.officialDb);
    try {
      final profile = await showAiScanDialog(
        context,
        controller: c,
        lines: readBookLines(f.path),
        stem: f.stem,
        db: db,
        targetHint: _targetCtl.text.trim(),
      );
      if (profile == null || !mounted) return;
      setState(() {
        for (final x in _files) {
          _plans[x.path] = LinkPlan(profile: profile, label: 'כללים מהבינה המלאכותית');
        }
      });
      await _makePreview();
    } finally {
      db.close();
    }
  }

  Future<void> _makePreview() async {
    if (_plans.isEmpty) return;
    final args = PreviewArgs(c.settings.officialDb, [for (final f in _files) if (_plans[f.path] != null) (f.path, _plans[f.path]!)]);
    final r = await c.run(
      'מחשב קישורים',
      (onProgress, cancelled) => runJob(previewJob, args, onProgress: onProgress, isCancelled: cancelled),
    );
    if (r == null || !mounted) return;
    setState(() {
      _preview = r;
      _savedPath = null;
    });
  }

  Future<void> _save() async {
    final pv = _preview;
    if (pv == null || pv.links == 0) return;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'היכן לשמור את links.csv');
    if (dir == null || !mounted) return;
    final path = p.join(dir, 'links.csv');
    if (File(path).existsSync()) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('הקובץ כבר קיים'),
          content: const Text('בתיקייה כבר יש links.csv. הקישורים של הספרים האלה יוחלפו, והשאר יישארו. להמשיך?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('המשך')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      final stems = {for (final f in pv.files) f.stem};
      final existing = File(path).existsSync() ? readCsv(path).skip(1).where((r) => r.length < 2 || !stems.contains(r[1])).toList() : <List<String>>[];
      final rows = <List<String>>[
        linkHeader,
        ...existing,
        for (final f in pv.files) ...linksRows(f.stem, f.rows, linkType: f.linkType),
      ];
      writeCsv(path, rows);
      setState(() => _savedPath = path);
      c.showMessage('נשמר: ${pv.links} קישורים.');
    } catch (e) {
      c.showMessage('השמירה נכשלה: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => PageBody(
        children: [
          _filesCard(),
          if (_files.isNotEmpty) _targetCard(),
          if (_files.isNotEmpty && _preview != null) _previewCard(),
          if (_preview != null && _preview!.links > 0) _saveCard(),
        ],
      ),
    );
  }

  Widget _filesCard() {
    return AppCard(
      title: '1. בחרו את קובץ הפירוש',
      icon: FluentIcons.document_24_regular,
      done: _files.isNotEmpty,
      info: 'קובץ טקסט (txt) של הספר בפורמט אוצריא, עם כותרות. אפשר לבחור כמה קבצים שחולקים אותם כללים.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_files.isEmpty)
            const SizedBox(
              width: double.infinity,
              child: EmptyState(
                icon: FluentIcons.document_add_24_regular,
                title: 'עדיין לא נבחר קובץ',
                message: 'בחרו את קובץ הפירוש שרוצים לקשר לספר שהוא מפרש.',
              ),
            ),
          for (final f in _files) ...[
            Text(f.stem, style: const TextStyle(fontWeight: FontWeight.bold)),
            Wrap(spacing: AppTokens.spaceSM, children: [
              Tag('${f.lines} שורות'),
              Tag('${f.headings} כותרות', kind: f.headings > 0 ? TagKind.good : TagKind.warn),
              if (f.isLfs) const Tag('קובץ ריק (git-lfs)', kind: TagKind.error),
            ]),
            const SizedBox(height: AppTokens.spaceSM),
          ],
          FilledButton.icon(
            onPressed: c.busy ? null : _pickFiles,
            icon: const Icon(FluentIcons.folder_open_24_regular),
            label: Text(_files.isEmpty ? 'בחר קובץ' : 'החלף קבצים'),
          ),
        ],
      ),
    );
  }

  Widget _targetCard() {
    final theme = Theme.of(context);
    final first = _files.isEmpty ? null : _detect[_files.first.path];
    return AppCard(
      title: '2. על איזה ספר הוא מפרש?',
      icon: FluentIcons.book_24_regular,
      done: _plans.isNotEmpty,
      info: 'לדוגמה: חידושים על מסכת ברכות מפרש את מסכת ברכות. אפשר להקליד את שם הספר, או ללחוץ זיהוי אוטומטי.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!c.hasOfficial)
            const Hint('צריך קודם לבחור את הספרייה של אוצריא (seforim.db) בהגדרות.', error: true)
          else ...[
            FilledButton.icon(
              onPressed: c.busy ? null : _autoDetect,
              icon: const Icon(FluentIcons.wand_24_regular),
              label: const Text('זיהוי אוטומטי לפי שם הקובץ'),
            ),
            if (first != null) ...[
              const SizedBox(height: AppTokens.spaceSM),
              switch (first.status) {
                DetectStatus.found => Tag(
                    'זוהה: ${first.target}${first.coverage == null ? '' : ' (${(first.coverage! * 100).round()}% מהשורות)'}',
                    kind: TagKind.good,
                  ),
                DetectStatus.lowCoverage => Tag(
                    'זוהה ${first.target}, אבל הכותרות לא תואמות מספיק (${((first.coverage ?? 0) * 100).round()}%)',
                    kind: TagKind.warn,
                  ),
                DetectStatus.notFound => Tag(first.reason, kind: TagKind.warn),
              },
            ],
            const SizedBox(height: AppTokens.spaceMD),
            Text('או בחרו ידנית:', style: theme.textTheme.labelLarge),
            const SizedBox(height: AppTokens.spaceXS),
            Autocomplete<String>(
              optionsBuilder: (v) {
                final q = v.text.trim();
                if (q.length < 2) return const Iterable<String>.empty();
                return _titles.where((t) => t.contains(q)).take(30);
              },
              fieldViewBuilder: (ctx, ctl, focus, submit) {
                if (ctl.text != _targetCtl.text && _targetCtl.text.isNotEmpty && !focus.hasFocus) ctl.text = _targetCtl.text;
                return TextField(
                  controller: ctl,
                  focusNode: focus,
                  decoration: const InputDecoration(
                    labelText: 'שם ספר היעד',
                    hintText: 'הקלידו כמה אותיות מהשם',
                    prefixIcon: Icon(FluentIcons.search_24_regular),
                  ),
                  onChanged: (v) => _targetCtl.text = v,
                );
              },
              onSelected: (t) {
                _targetCtl.text = t;
                _chooseTarget(t);
              },
            ),
            const SizedBox(height: AppTokens.spaceSM),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('מתקדם: כללי כותרות'),
                subtitle: const Hint('בחירת מבנה מוכן או סריקה בעזרת בינה מלאכותית'),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _preset,
                    decoration: const InputDecoration(labelText: 'מבנה כותרות מוכן'),
                    items: [for (final n in presets.keys) DropdownMenuItem(value: n, child: Text(n))],
                    onChanged: c.busy ? null : _choosePreset,
                  ),
                  const SizedBox(height: AppTokens.spaceSM),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: c.busy ? null : _aiScan,
                      icon: const Icon(FluentIcons.bot_24_regular),
                      label: const Text('סרוק מבנה בעזרת בינה מלאכותית'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _previewCard() {
    final pv = _preview!;
    final theme = Theme.of(context);
    return AppCard(
      title: '3. בדיקה ותצוגה מקדימה',
      icon: FluentIcons.eye_24_regular,
      done: pv.links > 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: AppTokens.spaceSM, runSpacing: AppTokens.spaceSM, children: [
            StatTile('${pv.links}', 'קישורים'),
            StatTile('${(pv.coverage * 100).round()}%', 'מהשורות קושרו'),
            StatTile('${pv.body}', 'שורות תוכן'),
          ]),
          for (final f in pv.files) ...[
            for (final n in f.notes) Padding(padding: const EdgeInsets.only(top: AppTokens.spaceXS), child: Hint(n, error: true)),
          ],
          if (pv.links == 0) ...[
            const SizedBox(height: AppTokens.spaceSM),
            const Hint('לא נוצרו קישורים. נסו ספר יעד אחר או מבנה כותרות אחר.', error: true),
          ] else if (pv.coverage < 0.5) ...[
            const SizedBox(height: AppTokens.spaceSM),
            const Hint('פחות ממחצית השורות קושרו. כדאי לבדוק שבחרתם את ספר היעד הנכון.'),
          ],
          if (pv.samples.isNotEmpty) ...[
            const SizedBox(height: AppTokens.spaceMD),
            Text('דוגמאות:', style: theme.textTheme.labelLarge),
            const SizedBox(height: AppTokens.spaceXS),
            Container(
              decoration: BoxDecoration(color: AppSurfaces.inset(context), borderRadius: AppTokens.borderRadiusAll),
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: pv.samples.length,
                separatorBuilder: (_, _) => Divider(color: AppSurfaces.divider(context)),
                itemBuilder: (_, i) {
                  final s = pv.samples[i];
                  return ListTile(
                    dense: true,
                    title: Text(s.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('שורה ${s.line}  ←  ${s.target}, ${s.location}'),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _saveCard() {
    return AppCard(
      title: '4. שמירה',
      icon: FluentIcons.save_24_regular,
      done: _savedPath != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.icon(
            onPressed: c.busy ? null : _save,
            icon: const Icon(FluentIcons.save_24_regular),
            label: const Text('שמור קובץ קישורים (links.csv)'),
          ),
          if (_savedPath != null) ...[
            const SizedBox(height: AppTokens.spaceMD),
            const Tag('נשמר', kind: TagKind.good),
            PathText(_savedPath!),
            const SizedBox(height: AppTokens.spaceSM),
            OutlinedButton.icon(
              onPressed: () => AppController.reveal(_savedPath!),
              icon: const Icon(FluentIcons.folder_open_24_regular),
              label: const Text('פתח תיקייה'),
            ),
          ],
          const SizedBox(height: AppTokens.spaceSM),
          const Hint('איך מייבאים באוצריא: הגדרות ← ספרים אישיים ← ייבוא קישורים.'),
        ],
      ),
    );
  }
}
