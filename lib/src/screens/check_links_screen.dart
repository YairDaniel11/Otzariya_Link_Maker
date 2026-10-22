import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../engine/errors.dart';
import '../engine/repair.dart';
import '../engine/seforim_db.dart';
import '../services/jobs.dart';
import '../services/settings_store.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/common_widgets.dart';
import 'check_links/report_list.dart';
import 'check_links/status_info.dart';

const _linksFolderName = 'קבצי קישורים וסדר הדורות';

class _PlanArgs {
  const _PlanArgs(this.booksDir, this.linksDir, this.dbPath);
  final String booksDir;
  final String linksDir;
  final String dbPath;
}

RepairPlan _planJob(_PlanArgs a, JobContext ctx) {
  final db = SeforimDb(a.dbPath);
  try {
    return planRepair(
      booksDir: a.booksDir,
      linksDir: a.linksDir,
      db: db,
      progress: (m) => ctx.progress('בודק את הקישורים', m, null),
      checkCancel: ctx.checkCancel,
    );
  } finally {
    db.close();
  }
}

class _ApplyArgs {
  const _ApplyArgs(this.plan, this.newDir, this.backupDir);
  final RepairPlan plan;
  final String newDir;
  final String backupDir;
}

RepairResult _applyJob(_ApplyArgs a, JobContext ctx) => applyRepair(
  a.plan,
  newDir: a.newDir,
  backupDir: a.backupDir,
  progress: (m) => ctx.progress('מתקן את הקישורים', m, null),
  checkCancel: ctx.checkCancel,
);

/// "בדיקת קישורים": משווה קישורים קיימים לספרים העדכניים ומתקן מספרי שורות שזזו.
class CheckLinksScreen extends StatefulWidget {
  const CheckLinksScreen({super.key, required this.controller, this.onOpenSettings});

  final AppController controller;

  /// מעבר למסך ההגדרות (לבחירת seforim.db), אם הוזן.
  final VoidCallback? onOpenSettings;

  @override
  State<CheckLinksScreen> createState() => _CheckLinksScreenState();
}

class _CheckLinksScreenState extends State<CheckLinksScreen> {
  String _booksDir = '';
  String _linksDir = '';
  RepairPlan? _plan;
  RepairResult? _result;
  bool _busy = false;
  bool _cancelled = false;
  String _title = '';
  String _detail = '';
  String? _error;
  RepairStatus? _filter; // null + !_showAll = "דורש טיפול"
  bool _showAll = false;
  String _query = '';

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _booksDir = _c.settings.lastBooksDir;
    _linksDir = _c.settings.lastLinksDir;
  }

  bool get _dbReady {
    final path = _c.settings.officialDb;
    return path.isNotEmpty && File(path).existsSync();
  }

  bool get _foldersReady =>
      _booksDir.isNotEmpty &&
      _linksDir.isNotEmpty &&
      Directory(_booksDir).existsSync() &&
      Directory(_linksDir).existsSync();

  void _save() {
    _c.settings.lastBooksDir = _booksDir;
    _c.settings.lastLinksDir = _linksDir;
    SettingsStore.save(_c.settings).catchError((_) {});
  }

  void _reset() {
    _plan = null;
    _result = null;
    _error = null;
    _filter = null;
    _showAll = false;
    _query = '';
  }

  Future<void> _pickBooks() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקיית הספרים של אוצריא');
    if (dir == null || !mounted) return;
    setState(() {
      _booksDir = dir;
      _reset();
      final guess = p.join(dir, _linksFolderName, 'קישורים');
      if (Directory(guess).existsSync()) _linksDir = guess;
    });
    _save();
  }

  Future<void> _pickLinks() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקיית קבצי הקישורים');
    if (dir == null || !mounted) return;
    setState(() {
      _linksDir = dir;
      _reset();
    });
    _save();
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _title = 'בודק את הקישורים';
      _detail = '';
      _reset();
    });
    _save();
    try {
      final plan = await runJob(
        _planJob,
        _PlanArgs(_booksDir, _linksDir, _c.settings.officialDb),
        onProgress: (t, d, f) {
          if (mounted) setState(() => _detail = d);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _showAll = !plan.report.any((r) => needsAttention(r.status));
      });
    } on Cancelled {
      if (mounted) _c.showMessage('הבדיקה נעצרה.');
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'הבדיקה נכשלה: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _newDir() {
    if (p.basename(_linksDir) == 'קישורים') return p.join(_linksDir, '13');
    final sub = p.join(_linksDir, 'קישורים');
    return Directory(sub).existsSync() ? p.join(sub, '13') : p.join(_linksDir, 'חדשים');
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null || _busy) return;
    final counts = summarizeReport(plan.report);
    final backupDir = p.join(SettingsStore.configDir(), 'backups');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('לתקן את הקישורים?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'יתוקנו ${counts[RepairStatus.updated] ?? 0} קבוצות קישורים, '
              'ויתווספו קישורים ל-${counts[RepairStatus.added] ?? 0} ספרים חדשים.',
            ),
            const SizedBox(height: AppTokens.spaceSM),
            const Text('לפני התיקון נשמר גיבוי (קובץ zip) של כל קבצי הקישורים, כך שתמיד אפשר לחזור אחורה.'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('גבה ותקן')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _title = 'מתקן את הקישורים';
      _detail = '';
      _error = null;
    });
    try {
      final res = await runJob(
        _applyJob,
        _ApplyArgs(plan, _newDir(), backupDir),
        onProgress: (t, d, f) {
          if (mounted) setState(() => _detail = d);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _plan = null;
      });
      _c.showMessage('הקישורים תוקנו. הגיבוי נשמר לפני השינוי.');
    } on Cancelled {
      if (mounted) _c.showMessage('התיקון נעצר.');
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'התיקון נכשל: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<RepairEntry> _visible(RepairPlan plan) {
    final q = _query.trim();
    return [
      for (final r in plan.report)
        if ((_showAll || (_filter == null ? needsAttention(r.status) : r.status == _filter)) &&
            (q.isEmpty || r.stem.contains(q) || r.category.contains(q)))
          r,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final visible = plan == null ? const <RepairEntry>[] : _visible(plan);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => PageBody(
        itemCount: visible.length,
        itemBuilder: (context, i) => ReportRow(visible[i]),
        children: [
          _intro(context),
          _foldersCard(context),
          if (!_dbReady) _needDbCard(context),
          if (_busy) _progressCard(context),
          if (_error != null) Hint(_error!, error: true),
          if (_result != null) _doneCard(context, _result!),
          if (plan != null) ..._summary(context, plan),
        ],
      ),
    );
  }

  Widget _intro(BuildContext context) => AppCard(
    title: 'בדיקת קישורים',
    icon: FluentIcons.checkmark_circle_24_regular,
    info:
        'מתי צריך את זה: אחרי שהוספתם או מחקתם שורה בראש ספר. אז מספרי השורות בקישורים שכבר יצרתם '
        'כבר לא מדויקים, והקישורים מצביעים על מקום שגוי. הבדיקה משווה כל קישור לספר כמו שהוא היום, '
        'והתיקון מזיז את מספרי השורות למקום הנכון.',
    child: Text(
      'אחרי שהוספתם או מחקתם שורה בראש ספר, הקישורים הקיימים עלולים להצביע על מקום לא נכון. '
      'כאן בודקים אם זה קרה, ומתקנים בלחיצה אחת. לפני כל תיקון נשמר גיבוי.',
      style: Theme.of(context).textTheme.bodyMedium,
    ),
  );

  Widget _foldersCard(BuildContext context) {
    final canCheck = !_busy && _foldersReady && _dbReady;
    return AppCard(
      title: 'מה לבדוק',
      icon: FluentIcons.folder_24_regular,
      done: _plan != null || _result != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _folderRow(context, '1. תיקיית הספרים', _booksDir, _busy ? null : _pickBooks),
          const SizedBox(height: AppTokens.spaceMD),
          _folderRow(context, '2. תיקיית קבצי הקישורים', _linksDir, _busy ? null : _pickLinks),
          if (_booksDir.isNotEmpty && _linksDir.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Hint('לא נמצאה תיקיית קישורים אוטומטית. בדרך כלל היא בתוך "קבצי קישורים וסדר הדורות" שבתיקיית הספרים.'),
            ),
          const SizedBox(height: AppTokens.spaceMD),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: canCheck ? _check : null,
              icon: const Icon(FluentIcons.search_24_regular, size: 18),
              label: const Text('בדוק'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderRow(BuildContext context, String label, String value, VoidCallback? onPick) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: value.isEmpty ? const Hint('עוד לא נבחרה תיקייה') : PathText(value, maxLines: 2)),
            const SizedBox(width: AppTokens.spaceSM),
            OutlinedButton(onPressed: onPick, child: const Text('בחירת תיקייה')),
          ],
        ),
      ],
    );
  }

  Widget _needDbCard(BuildContext context) => AppCard(
    icon: FluentIcons.warning_24_regular,
    title: 'חסר מסד הספרייה של אוצריא',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('הבדיקה צריכה את הקובץ seforim.db של אוצריא כדי לדעת מה המבנה הנכון של כל ספר. אפשר לבחור אותו בהגדרות.'),
        if (widget.onOpenSettings != null) ...[
          const SizedBox(height: AppTokens.spaceSM),
          OutlinedButton.icon(
            onPressed: widget.onOpenSettings,
            icon: const Icon(FluentIcons.settings_24_regular, size: 18),
            label: const Text('פתח הגדרות'),
          ),
        ],
      ],
    ),
  );

  Widget _progressCard(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_title, style: theme.textTheme.titleMedium)),
              OutlinedButton.icon(
                onPressed: _cancelled ? null : () => setState(() => _cancelled = true),
                icon: const Icon(FluentIcons.stop_24_regular, size: 18),
                label: Text(_cancelled ? 'עוצר...' : 'עצור'),
              ),
            ],
          ),
          if (_detail.isNotEmpty) Hint(_detail),
          const SizedBox(height: AppTokens.spaceSM),
          ClipRRect(borderRadius: AppTokens.borderRadiusAll, child: const LinearProgressIndicator()),
          const SizedBox(height: 4),
          const Hint('עשוי לקחת דקה או שתיים, בהתאם למספר הספרים.'),
        ],
      ),
    );
  }

  Widget _doneCard(BuildContext context, RepairResult r) {
    final backup = r.backupPath;
    return AppCard(
      title: 'התיקון הסתיים',
      icon: FluentIcons.checkmark_circle_24_regular,
      done: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('עודכנו ${r.changedFiles} קבצי קישורים.'),
          if (r.additionsPath != null) ...[
            const SizedBox(height: 4),
            const Text('קישורים לספרים חדשים נכתבו אל:'),
            PathText(r.additionsPath!),
          ],
          if (backup != null) ...[
            const SizedBox(height: AppTokens.spaceSM),
            const Text('גיבוי של הקבצים המקוריים נשמר ב:'),
            PathText(backup),
          ],
          const SizedBox(height: AppTokens.spaceSM),
          Wrap(
            spacing: AppTokens.spaceSM,
            children: [
              if (backup != null)
                OutlinedButton.icon(
                  onPressed: () => AppController.reveal(backup),
                  icon: const Icon(FluentIcons.folder_open_24_regular, size: 18),
                  label: const Text('פתח תיקיית גיבוי'),
                ),
              OutlinedButton.icon(
                onPressed: () => AppController.reveal(_linksDir),
                icon: const Icon(FluentIcons.folder_open_24_regular, size: 18),
                label: const Text('פתח תיקיית קישורים'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _summary(BuildContext context, RepairPlan plan) {
    final counts = summarizeReport(plan.report);
    int n(RepairStatus s) => counts[s] ?? 0;
    final attention = n(RepairStatus.updated) + n(RepairStatus.added);
    final theme = Theme.of(context);
    final legend = [for (final s in RepairStatus.values) '${s.label}: ${statusExplanation(s)}'].join('\n');
    return [
      AppCard(
        title: 'תוצאות הבדיקה',
        icon: FluentIcons.clipboard_task_list_ltr_24_regular,
        info: 'מה המשמעות של כל סטטוס:\n$legend',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: AppTokens.spaceSM,
              runSpacing: AppTokens.spaceSM,
              children: [
                StatTile('${n(RepairStatus.ok)}', 'תקין'),
                StatTile('${n(RepairStatus.updated)}', 'עודכן'),
                StatTile('${n(RepairStatus.unchecked)}', 'לא נבדק'),
                StatTile('${n(RepairStatus.added)}', 'חדש'),
                if (n(RepairStatus.manual) > 0) StatTile('${n(RepairStatus.manual)}', 'ידני'),
              ],
            ),
            const SizedBox(height: AppTokens.spaceMD),
            if (attention == 0)
              Text('הכול תקין, אין מה לתקן.', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary))
            else ...[
              Text(
                'נמצאו ${n(RepairStatus.updated)} קבוצות קישורים שזזו, ו-${n(RepairStatus.added)} ספרים בלי קישורים.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppTokens.spaceSM),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  onPressed: _busy || !plan.hasChanges ? null : _apply,
                  icon: const Icon(FluentIcons.wrench_24_regular, size: 18),
                  label: const Text('תקן את הקישורים'),
                ),
              ),
              const SizedBox(height: 4),
              const Hint('לפני התיקון נשמר גיבוי zip של כל קבצי הקישורים.'),
            ],
          ],
        ),
      ),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(FluentIcons.search_24_regular),
                hintText: 'חיפוש לפי שם ספר',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: AppTokens.spaceSM),
            Wrap(
              spacing: AppTokens.spaceSM,
              runSpacing: AppTokens.spaceXS,
              children: [
                ChoiceChip(
                  label: Text('דורש טיפול ($attention)'),
                  selected: !_showAll && _filter == null,
                  onSelected: (_) => setState(() {
                    _showAll = false;
                    _filter = null;
                  }),
                ),
                ChoiceChip(
                  label: Text('הכול (${plan.report.length})'),
                  selected: _showAll,
                  onSelected: (_) => setState(() => _showAll = true),
                ),
                for (final s in RepairStatus.values)
                  if (n(s) > 0)
                    ChoiceChip(
                      label: Text('${s.label} (${n(s)})'),
                      selected: !_showAll && _filter == s,
                      onSelected: (_) => setState(() {
                        _showAll = false;
                        _filter = s;
                      }),
                    ),
              ],
            ),
          ],
        ),
      ),
      if (_visible(plan).isEmpty)
        const EmptyState(
          icon: FluentIcons.checkmark_circle_24_regular,
          title: 'אין שורות להצגה',
          message: 'אפשר לבחור "הכול" כדי לראות את כל הקבוצות.',
        ),
    ];
  }
}
