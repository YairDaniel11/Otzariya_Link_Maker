import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../ai/ai_providers.dart';
import '../ai/structure_ai.dart';
import '../controllers/app_controller.dart';
import '../engine/linker_core.dart';
import '../engine/seforim_db.dart';
import '../theme/app_tokens.dart';
import '../widgets/common_widgets.dart';

/// כמה שורות לדוגמה נשלחות אם המשתמש הסכים.
const aiSampleLineCount = 40;

/// תיאור כלל בעברית פשוטה.
String describeRule(Rule r) {
  final lv = r.lo == r.hi ? 'ברמה ${r.lo}' : 'ברמות ${r.lo} עד ${r.hi}';
  switch (r.type) {
    case 'daf':
      return 'כותרות של דפים (כמו "דף ב." או "דף ב:") $lv';
    case 'heading':
      final what = switch (r.role) {
        'chapter' => 'כותרות של פרקים/סימנים',
        'sub' => 'כותרות משנה (כמו הלכה או סעיף)',
        _ => 'כותרות שמציינות מיקום בספר היעד',
      };
      return '$what $lv${r.regex != null ? ' (לפי תבנית טקסט)' : ''}';
    case 'target_switch':
      return 'כותרת שמחליפה את ספר היעד באמצע הספר $lv';
    case 'anchor':
      return 'כותרת קבועה שמסמנת נקודת התחלה';
    default:
      return r.type;
  }
}

/// חלון "סריקת מבנה בעזרת בינה מלאכותית". מחזיר את הפרופיל שהמשתמש אישר, או null.
Future<Profile?> showAiScanDialog(
  BuildContext context, {
  required AppController controller,
  required List<String> lines,
  required String stem,
  SeforimDb? db,
  String targetHint = '',
  AiClient? client,
}) => showDialog<Profile>(
  context: context,
  barrierDismissible: false,
  builder: (_) => AiScanDialog(
    controller: controller,
    lines: lines,
    stem: stem,
    db: db,
    targetHint: targetHint,
    client: client,
  ),
);

class AiScanDialog extends StatefulWidget {
  const AiScanDialog({
    super.key,
    required this.controller,
    required this.lines,
    required this.stem,
    this.db,
    this.targetHint = '',
    this.client,
  });

  final AppController controller;
  final List<String> lines;
  final String stem;
  final SeforimDb? db;
  final String targetHint;
  final AiClient? client;

  @override
  State<AiScanDialog> createState() => _AiScanDialogState();
}

class _AiScanDialogState extends State<AiScanDialog> {
  final _feedback = TextEditingController();
  bool _sendSamples = false;
  bool _running = false;
  String? _error;
  StructureProposal? _proposal;

  AiProvider get _provider => AiProvider.byId(widget.controller.settings.aiProvider) ?? AiProvider.gemini;
  String get _key => (widget.controller.settings.aiKeys[_provider.id] ?? '').trim();
  String get _model => (widget.controller.settings.aiModels[_provider.id] ?? '').trim();
  bool get _configured => _key.isNotEmpty && _model.isNotEmpty;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  Future<void> _run({bool retry = false}) async {
    setState(() {
      _running = true;
      _error = null;
    });
    final prev = _proposal;
    final parts = <String>[
      if (retry && prev != null && prev.feedback.isNotEmpty) prev.feedback,
      if (retry && _feedback.text.trim().isNotEmpty) 'User feedback: ${_feedback.text.trim()}',
    ];
    try {
      final s = widget.controller.settings;
      final res = await proposeProfile(
        client: widget.client ?? AiClient(),
        provider: _provider,
        key: _key,
        model: _model,
        tier: s.aiTier,
        stem: widget.stem,
        lines: widget.lines,
        db: widget.db,
        targetHint: widget.targetHint,
        sampleLines: _sendSamples ? aiSampleLineCount : 0,
        feedback: parts.join('\n'),
      );
      if (!mounted) return;
      setState(() => _proposal = res);
    } on AiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'הסריקה נכשלה: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prop = _proposal;
    return AlertDialog(
      title: const Text('סריקת מבנה בעזרת בינה מלאכותית'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_configured)
                const Hint('כדי להשתמש בזה צריך להגדיר מפתח ומודל של בינה מלאכותית במסך ההגדרות.', error: true)
              else if (prop == null || _running) ..._intro(context)
              else ..._result(context, prop),
              if (_running) ...[
                const SizedBox(height: AppTokens.spaceMD),
                const LinearProgressIndicator(),
                const SizedBox(height: 4),
                const Hint('הבינה המלאכותית עובדת. זה לוקח כמה שניות.'),
              ],
              if (_error != null) ...[const SizedBox(height: AppTokens.spaceSM), Hint(_error!, error: true)],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
        if (_configured && (prop == null || !prop.ok) && !_running)
          FilledButton(onPressed: () => _run(retry: prop != null), child: Text(prop == null ? 'סרוק' : 'נסה שוב')),
        if (prop != null && prop.ok && !_running) ...[
          OutlinedButton(onPressed: () => _run(retry: true), child: const Text('נסה שוב עם הערה')),
          FilledButton(onPressed: () => Navigator.pop(context, prop.profile), child: const Text('השתמש בכללים האלה')),
        ],
      ],
    );
  }

  List<Widget> _intro(BuildContext context) => [
    Text('התוכנה תבקש מבינה מלאכותית להציע כללי כותרות לספר "${widget.stem}" לפי מבנה הכותרות שבו.'),
    const SizedBox(height: AppTokens.spaceSM),
    const Hint('נשלח רק סיכום של הכותרות (איזה סוגי כותרות יש וכמה). טקסט הספר עצמו לא נשלח.'),
    const SizedBox(height: AppTokens.spaceSM),
    CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: _sendSamples,
      onChanged: _running ? null : (v) => setState(() => _sendSamples = v ?? false),
      title: Text('לשלוח גם $aiSampleLineCount שורות לדוגמה מהספר'),
      subtitle: const Text('מדויק יותר בספרים מסובכים. השורות יישלחו לספק הבינה המלאכותית שבחרתם.'),
    ),
  ];

  List<Widget> _result(BuildContext context, StructureProposal prop) {
    final theme = Theme.of(context);
    if (prop.profile == null) {
      final why = prop.reason.isNotEmpty ? prop.reason : prop.errors.join('\n');
      return [
        const Text('הבינה המלאכותית לא הצליחה להציע כללים מתאימים.'),
        if (why.isNotEmpty) Hint(why),
        const SizedBox(height: AppTokens.spaceSM),
        _feedbackField(),
      ];
    }
    final pct = (prop.coverage * 100).round();
    final run = prop.run;
    return [
      Text('הכללים שהוצעו', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      for (final r in prop.profile!.rules)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 3), child: Icon(FluentIcons.checkmark_24_regular, size: 16)),
              const SizedBox(width: 6),
              Expanded(child: Text(describeRule(r))),
            ],
          ),
        ),
      if (prop.profile!.target.isNotEmpty) Hint('ספר היעד: ${prop.profile!.target}'),
      const SizedBox(height: AppTokens.spaceMD),
      Row(
        children: [
          Tag('כיסוי $pct%', kind: pct >= 80 ? TagKind.good : TagKind.warn),
          const SizedBox(width: AppTokens.spaceSM),
          Expanded(child: Text('${prop.linked} מתוך ${prop.bodyLines} שורות יקבלו קישור', style: theme.textTheme.bodySmall)),
        ],
      ),
      if (run != null && run.unmatched.isNotEmpty) ...[
        const SizedBox(height: 4),
        Hint('כותרות שלא התאימו לאף כלל: ${run.unmatched.keys.take(5).join(', ')}'),
      ],
      const SizedBox(height: AppTokens.spaceMD),
      _feedbackField(),
    ];
  }

  Widget _feedbackField() => TextField(
    controller: _feedback,
    minLines: 1,
    maxLines: 3,
    decoration: const InputDecoration(
      labelText: 'לא מדויק? כתבו מה לתקן (לא חובה)',
      hintText: 'למשל: הכותרות ברמה 3 הן הלכות, לא פרקים',
    ),
  );
}
