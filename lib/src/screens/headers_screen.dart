import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../headers/book_builder.dart';
import '../headers/header_utils.dart';
import '../headers/txt_headers.dart';
import '../services/jobs.dart' show runJob;
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/common_widgets.dart';
import '../widgets/credits_card.dart';
import '../widgets/headers_review_panel.dart';
import '../widgets/headers_rules_panel.dart';
import 'headers/headers_jobs.dart';

/// יצירת כותרות לספר חדש: קובץ Word, Markdown או TXT הופך לספר תקין של אוצריא.
class HeadersScreen extends StatefulWidget {
  const HeadersScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<HeadersScreen> createState() => _HeadersScreenState();
}

class _HeadersScreenState extends State<HeadersScreen> {
  final _title = TextEditingController();
  final _author = TextEditingController();
  final _baseSize = TextEditingController();
  final _noteSize = TextEditingController();

  String? _path;
  SourceKind _kind = SourceKind.unknown;
  LoadResult? _loaded;

  final _presets = headingPresets();
  final _customs = <CustomSpec>[];
  var _counts = <String, int>{};
  final _selected = <String>{};
  final _levels = <String, int>{};

  var _heads = <HeadDto>[];
  BuiltBook? _built;
  var _building = false;
  var _separateNotes = false;
  var _advanced = false;

  String? _outDir;
  List<String> _saved = const [];

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _author.text = c.settings.author;
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _baseSize.dispose();
    _noteSize.dispose();
    super.dispose();
  }

  bool get _hasStyleHeadings => (_loaded?.styleHeadings ?? 0) > 0;

  // ─── שלב 1: בחירת קובץ ───────────────────────────────────────────

  Future<void> _pickFile() async {
    final f = await FilePicker.pickFile(
      dialogTitle: 'בחירת קובץ',
      type: FileType.custom,
      allowedExtensions: const ['docx', 'txt', 'md', 'markdown', 'doc'],
    );
    if (f?.path != null) await _load(f!.path!);
  }

  int? _halfPts(TextEditingController t) {
    final v = double.tryParse(t.text.trim().replaceAll(',', '.'));
    return v == null || v <= 0 ? null : (v * 2).round();
  }

  Future<void> _load(String path, {bool keepSizes = false}) async {
    final kind = kindOfPath(path);
    final args = LoadArgs(
      path,
      kind,
      baseHalfPts: keepSizes ? _halfPts(_baseSize) : null,
      noteHalfPts: keepSizes ? _halfPts(_noteSize) : null,
    );
    final r = await c.run(
      'קורא את הקובץ',
      (onProgress, cancelled) => runJob(loadSourceJob, args, onProgress: onProgress, isCancelled: cancelled),
    );
    if (r == null || !mounted) return;
    setState(() {
      _path = path;
      _kind = kind;
      _loaded = r;
      _saved = const [];
      _built = null;
      _heads = [];
      _selected.clear();
      _levels.clear();
      _outDir ??= p.dirname(path);
      if (!keepSizes) {
        _title.text = r.detectedTitle ?? guessTitle(path);
        if (r.usedBase > 0) _baseSize.text = _pts(r.usedBase);
        if (r.usedNote > 0) _noteSize.text = _pts(r.usedNote);
      }
    });
    await _analyze(autoPick: true);
  }

  String _pts(int half) => half.isEven ? '${half ~/ 2}' : '${half / 2}';

  // ─── שלב 3: זיהוי כותרות ─────────────────────────────────────────

  Future<void> _analyze({bool autoPick = false}) async {
    final l = _loaded;
    if (l == null) return;
    if (autoPick) {
      final counts = await c.run(
        'בודק אילו כותרות יש בקובץ',
        (onProgress, cancelled) =>
            runJob(countRulesJob, CountArgs(l.lines, List.of(_customs)), onProgress: onProgress, isCancelled: cancelled),
      );
      if (counts == null || !mounted) return;
      setState(() {
        _counts = counts;
        _selected
          ..clear()
          ..addAll(_hasStyleHeadings ? const <String>{} : autoPickRules(counts, l.lines.length));
      });
    }
    await _detect();
  }

  Future<void> _detect() async {
    final l = _loaded;
    if (l == null) return;
    final args = DetectArgs(l.lines, _title.text.trim(), _selected.toList(), Map.of(_levels), List.of(_customs));
    final r = await c.run(
      'מחפש כותרות',
      (onProgress, cancelled) => runJob(detectJob, args, onProgress: onProgress, isCancelled: cancelled),
    );
    if (r == null || !mounted) return;
    setState(() => _heads = r);
    await _rebuild();
  }

  Future<void> _rebuild() async {
    final l = _loaded;
    if (l == null) return;
    setState(() => _building = true);
    final args = BuildArgs(
      lines: l.lines,
      notes: l.notes,
      title: _title.text.trim(),
      author: _author.text.trim(),
      heads: _heads,
      separateNotes: _separateNotes,
    );
    try {
      final b = await runJob(buildJob, args);
      if (mounted) setState(() => _built = b);
    } catch (e) {
      c.showMessage('הבנייה נכשלה: $e', error: true);
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  Future<void> _autoDetect() async {
    final l = _loaded;
    if (l == null) return;
    await _analyze(autoPick: true);
  }

  Future<void> _addCustom() async {
    final text = TextEditingController();
    var regex = false;
    final spec = await showDialog<CustomSpec>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('כלל משלי'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('שורה שמתחילה ב...')),
                    ButtonSegment(value: true, label: Text('ביטוי רגולרי (מתקדם)')),
                  ],
                  selected: {regex},
                  onSelectionChanged: (s) => setS(() => regex = s.first),
                ),
                const SizedBox(height: AppTokens.spaceMD),
                TextField(
                  controller: text,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: regex ? 'ביטוי רגולרי' : 'כל שורה קצרה שמתחילה במילים האלה תהפוך לכותרת',
                    hintText: regex ? r'^שיעור \d+' : 'שיעור',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
            FilledButton(
              onPressed: () {
                final t = text.text.trim();
                if (t.isEmpty) return;
                if (regex) {
                  try {
                    RegExp(t);
                  } catch (_) {
                    c.showMessage('הביטוי הרגולרי אינו תקין', error: true);
                    return;
                  }
                }
                Navigator.pop(ctx, CustomSpec(regex, t));
              },
              child: const Text('הוסף'),
            ),
          ],
        ),
      ),
    );
    text.dispose();
    if (spec == null || !mounted) return;
    setState(() {
      if (!_customs.any((x) => x.id == spec.id)) _customs.add(spec);
      _selected.add(spec.id);
    });
    await _analyze(autoPick: false);
    // ספירת ההתאמות של הכלל החדש
    final l = _loaded;
    if (l != null) {
      final counts = await runJob(countRulesJob, CountArgs(l.lines, List.of(_customs)));
      if (mounted) setState(() => _counts = counts);
    }
  }

  void _addHeadLine(int index) {
    final l = _loaded;
    if (l == null || _heads.any((h) => h.index == index)) return;
    final line = l.lines[index];
    setState(() {
      _heads = [
        ..._heads,
        HeadDto(
          index: index,
          text: line,
          plain: plainText(line).trim(),
          ruleId: 'manual',
          ruleLabel: 'נוספה ידנית',
          level: 2,
          existing: false,
          isWhole: true,
          manual: true,
        ),
      ]..sort((a, b) => a.index.compareTo(b.index));
    });
    _rebuild();
  }

  // ─── שמירה ────────────────────────────────────────────────────────

  Future<void> _pickOutDir() async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: 'היכן לשמור את הספר');
    if (d != null) setState(() => _outDir = d);
  }

  Future<void> _save({bool overwrite = false}) async {
    final b = _built;
    final dir = _outDir;
    if (b == null || dir == null) return;
    if (c.settings.author != _author.text.trim() && _author.text.trim().isNotEmpty) c.setAuthor(_author.text);
    try {
      final paths = await c.run(
        'שומר את הספר',
        (onProgress, cancelled) =>
            runJob(saveJob, SaveArgs(b, dir, overwrite), onProgress: onProgress, isCancelled: cancelled),
      );
      if (paths == null || !mounted) return;
      setState(() => _saved = paths);
      c.showMessage('הספר נשמר.');
    } catch (e) {
      if (!mounted) return;
      c.showMessage('$e', error: true);
    }
  }

  // ─── תצוגה ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final l = _loaded;
        final b = _built;
        return PageBody(
          children: [
            _fileCard(),
            if (l != null) _detailsCard(),
            if (l != null) _headingsCard(),
            if (l != null) _reviewCard(),
            if (l != null) _saveCard(b),
            const CreditsCard(),
          ],
        );
      },
    );
  }

  Widget _fileCard() {
    final l = _loaded;
    return AppCard(
      title: '1. בחרו את הקובץ',
      icon: FluentIcons.document_24_regular,
      done: l != null,
      info: 'אפשר לבחור קובץ Word (docx), קובץ Markdown (md) או קובץ טקסט (txt). '
          'התוכנה מוסיפה כותרות ומסדרת את הספר לפי הפורמט של אוצריא.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_path == null)
            const SizedBox(
              width: double.infinity,
              child: EmptyState(
                icon: FluentIcons.book_add_24_regular,
                title: 'עדיין לא נבחר קובץ',
                message: 'בחרו קובץ Word, Markdown או טקסט של הספר החדש.',
              ),
            )
          else ...[
            PathText(_path!),
            const SizedBox(height: AppTokens.spaceSM),
            Wrap(
              spacing: AppTokens.spaceSM,
              runSpacing: AppTokens.spaceXS,
              children: [
                Tag(kindLabel(_kind), kind: TagKind.good),
                if (l != null) Tag('${l.lines.length} שורות'),
                if (l != null && l.notes.isNotEmpty) Tag('${l.notes.length} הערות שוליים'),
              ],
            ),
          ],
          const SizedBox(height: AppTokens.spaceMD),
          FilledButton.icon(
            onPressed: c.busy ? null : _pickFile,
            icon: const Icon(FluentIcons.folder_open_24_regular),
            label: Text(_path == null ? 'בחר קובץ' : 'החלף קובץ'),
          ),
        ],
      ),
    );
  }

  Widget _detailsCard() {
    final l = _loaded!;
    final isWord = _kind == SourceKind.docx;
    return AppCard(
      title: '2. פרטי הספר',
      icon: FluentIcons.text_edit_style_24_regular,
      done: _title.text.trim().isNotEmpty,
      info: 'שורה 1 בספר היא שם הספר, ושורה 2 היא שם המחבר. אם המחבר לא ידוע אפשר להשאיר ריק.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'שם הספר'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _rebuild(),
            onEditingComplete: _rebuild,
          ),
          const SizedBox(height: AppTokens.spaceSM),
          TextField(
            controller: _author,
            decoration: const InputDecoration(labelText: 'שם המחבר (לא חובה)'),
            onSubmitted: (_) => _rebuild(),
            onEditingComplete: _rebuild,
          ),
          if (isWord) ...[
            const SizedBox(height: AppTokens.spaceSM),
            if (_hasStyleHeadings)
              Tag('נמצאו ${l.styleHeadings} כותרות בעיצוב של וורד', kind: TagKind.good)
            else
              const Tag('בקובץ לא נמצאו כותרות בעיצוב של וורד: נזהה לפי הטקסט', kind: TagKind.warn),
          ],
          if (_kind == SourceKind.md && _hasStyleHeadings) ...[
            const SizedBox(height: AppTokens.spaceSM),
            Tag('נמצאו ${l.styleHeadings} כותרות בקובץ', kind: TagKind.good),
          ],
          if (isWord) ...[
            const SizedBox(height: AppTokens.spaceSM),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('מתקדם: גודל הגופן'),
                subtitle: const Hint('לזיהוי טקסט גדול וקטן. בדרך כלל לא צריך לשנות.'),
                initiallyExpanded: _advanced,
                onExpansionChanged: (v) => _advanced = v,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _baseSize,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'גודל הטקסט הרגיל'),
                        ),
                      ),
                      const SizedBox(width: AppTokens.spaceSM),
                      Expanded(
                        child: TextField(
                          controller: _noteSize,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'גודל הערות השוליים'),
                        ),
                      ),
                      const SizedBox(width: AppTokens.spaceSM),
                      OutlinedButton(
                        onPressed: c.busy ? null : () => _load(_path!, keepSizes: true),
                        child: const Text('החל'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _headingsCard() {
    final title = _hasStyleHeadings ? '3. כותרות (אפשר גם להוסיף)' : '3. אילו שורות הן כותרות?';
    return AppCard(
      title: title,
      icon: FluentIcons.text_header_1_24_regular,
      done: _heads.isNotEmpty,
      info: 'סמנו את סוגי הכותרות שיש בספר. מימין לכל כלל מספר השורות שמתאימות לו. '
          'אפשר לשנות את הרמה של כל סוג, ולהוסיף כלל משלכם.',
      child: HeadersRulesPanel(
        presets: _presets,
        customs: _customs,
        counts: _counts,
        selected: _selected,
        levels: _levels,
        busy: c.busy,
        onToggle: (id, on) {
          setState(() => on ? _selected.add(id) : _selected.remove(id));
          _detect();
        },
        onLevel: (id, level) {
          setState(() => level == null ? _levels.remove(id) : _levels[id] = level);
          _detect();
        },
        onAuto: _autoDetect,
        onAddCustom: _addCustom,
        onRemoveCustom: (s) {
          setState(() {
            _customs.removeWhere((x) => x.id == s.id);
            _selected.remove(s.id);
            _levels.remove(s.id);
          });
          _detect();
        },
      ),
    );
  }

  Widget _reviewCard() {
    final l = _loaded!;
    final b = _built;
    final errors = b?.issues.where((i) => i.severity == IssueSeverity.error).length ?? 0;
    return AppCard(
      title: '4. בדיקה ותצוגה מקדימה',
      icon: FluentIcons.eye_24_regular,
      done: b != null && errors == 0 && _heads.isNotEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HeadersReviewPanel(
            lines: l.lines,
            heads: _heads,
            built: b,
            building: _building,
            onChanged: _rebuild,
            onAddLine: _addHeadLine,
          ),
          if (l.notes.isNotEmpty) ...[
            const SizedBox(height: AppTokens.spaceSM),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('מתקדם: הערות שוליים'),
                children: [
                  RadioGroup<bool>(
                    groupValue: _separateNotes,
                    onChanged: (v) {
                      setState(() => _separateNotes = v ?? false);
                      _rebuild();
                    },
                    child: const Column(
                      children: [
                        RadioListTile<bool>(
                          value: false,
                          title: Text('בתוך הספר (מומלץ)'),
                          subtitle: Text('ההערות מוצגות ליד המילה, בלי קבצים נוספים.'),
                        ),
                        RadioListTile<bool>(
                          value: true,
                          title: Text('בקובץ נפרד'),
                          subtitle: Text('נוצרים גם קובץ "הערות על..." וקובץ קישורים.'),
                        ),
                      ],
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

  Widget _saveCard(BuiltBook? b) {
    final blocked = b == null || b.hasErrors || _title.text.trim().isEmpty;
    return AppCard(
      title: '5. שמירה',
      icon: FluentIcons.save_24_regular,
      done: _saved.isNotEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Hint('היכן לשמור את הספר:'),
          const SizedBox(height: AppTokens.spaceXS),
          if (_outDir != null) PathText(_outDir!),
          if (b != null) ...[
            const SizedBox(height: AppTokens.spaceXS),
            Hint('שם הקובץ: ${b.fileName}'),
          ],
          const SizedBox(height: AppTokens.spaceMD),
          Wrap(
            spacing: AppTokens.spaceSM,
            runSpacing: AppTokens.spaceSM,
            children: [
              OutlinedButton.icon(
                onPressed: c.busy ? null : _pickOutDir,
                icon: const Icon(FluentIcons.folder_open_24_regular),
                label: const Text('שנה תיקייה'),
              ),
              FilledButton.icon(
                onPressed: c.busy || blocked ? null : _confirmAndSave,
                icon: const Icon(FluentIcons.save_24_regular),
                label: const Text('שמור את הספר'),
              ),
            ],
          ),
          if (b != null && b.hasErrors) ...[
            const SizedBox(height: AppTokens.spaceSM),
            const Hint('יש שגיאות בבדיקה למעלה. תקנו אותן כדי לשמור.', error: true),
          ],
          if (_saved.isNotEmpty) ...[
            const SizedBox(height: AppTokens.spaceMD),
            const Tag('נשמר', kind: TagKind.good),
            const SizedBox(height: AppTokens.spaceXS),
            for (final s in _saved) PathText(s),
            const SizedBox(height: AppTokens.spaceSM),
            OutlinedButton.icon(
              onPressed: () => AppController.reveal(_saved.first),
              icon: const Icon(FluentIcons.folder_open_24_regular),
              label: const Text('פתח תיקייה'),
            ),
            const SizedBox(height: AppTokens.spaceSM),
            const Hint(
              'להוספה לאוצריא: בהגדרות ← ספרייה ← הוספת תיקייה (ספרים אישיים), ובחרו את התיקייה שבה נשמר הספר.',
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmAndSave() async {
    final b = _built!;
    final exists = File(p.join(_outDir!, b.fileName)).existsSync();
    if (!exists) return _save();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('הקובץ כבר קיים'),
        content: Text('בתיקייה כבר יש קובץ בשם "${b.fileName}". להחליף אותו?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('החלף')),
        ],
      ),
    );
    if (ok == true) await _save(overwrite: true);
  }
}
