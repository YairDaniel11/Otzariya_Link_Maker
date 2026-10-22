import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/common_widgets.dart';
import '../widgets/credits_card.dart';

/// גרסת התוכנה (מוזרקת בבנייה ב-GitHub Actions).
const appVersion = String.fromEnvironment('APP_VERSION');

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _author = TextEditingController(text: widget.controller.settings.author);
  late final _key = TextEditingController(text: _currentKey());
  late final _model = TextEditingController(text: _currentModel());

  AppController get c => widget.controller;

  String _currentKey() => c.settings.aiKeys[c.settings.aiProvider] ?? '';
  String _currentModel() => c.settings.aiModels[c.settings.aiProvider] ?? '';

  @override
  void dispose() {
    _author.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _pickDb() async {
    final f = await FilePicker.pickFile(
      dialogTitle: 'בחירת seforim.db של אוצריא',
      type: FileType.custom,
      allowedExtensions: const ['db'],
    );
    if (f?.path != null) c.setOfficialDb(f!.path!);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.settings;
        return PageBody(
          children: [
            AppCard(
              title: 'ערכת נושא',
              icon: FluentIcons.paint_brush_24_regular,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(FluentIcons.desktop_24_regular, size: 18),
                      label: Text('מערכת'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(FluentIcons.weather_sunny_24_regular, size: 18),
                      label: Text('בהיר'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(FluentIcons.weather_moon_24_regular, size: 18),
                      label: Text('כהה'),
                    ),
                  ],
                  selected: {c.themeMode},
                  onSelectionChanged: (v) => c.setThemeMode(v.first),
                ),
              ),
            ),
            AppCard(
              title: 'הספרייה של אוצריא',
              icon: FluentIcons.library_24_regular,
              info: 'הקובץ seforim.db של אוצריא. משמש לוודא שהקישורים מצביעים למקום שקיים. התוכנה רק קוראת אותו.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.officialDb.isEmpty)
                    const Tag('לא נבחר קובץ', kind: TagKind.warn)
                  else ...[
                    PathText(s.officialDb),
                    const SizedBox(height: AppTokens.spaceXS),
                    c.officialError == null
                        ? const Tag('תקין', kind: TagKind.good)
                        : Tag(c.officialError!, kind: TagKind.error),
                  ],
                  const SizedBox(height: AppTokens.spaceMD),
                  Wrap(
                    spacing: AppTokens.spaceSM,
                    runSpacing: AppTokens.spaceSM,
                    children: [
                      FilledButton.icon(
                        onPressed: () => c.detectOfficial()
                            ? c.showMessage('נמצא הקובץ של אוצריא.')
                            : c.showMessage('לא נמצא. בחרו את הקובץ ידנית.', error: true),
                        icon: const Icon(FluentIcons.search_24_regular),
                        label: const Text('מצא אוטומטית'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _pickDb,
                        icon: const Icon(FluentIcons.folder_open_24_regular),
                        label: const Text('בחר קובץ'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            AppCard(
              title: 'שם המחבר ברירת מחדל',
              icon: FluentIcons.person_24_regular,
              child: TextField(
                controller: _author,
                decoration: const InputDecoration(labelText: 'יופיע בשורה 2 של ספרים חדשים (לא חובה)'),
                onChanged: c.setAuthor,
              ),
            ),
            AppCard(
              title: 'בינה מלאכותית (לא חובה)',
              icon: FluentIcons.bot_24_regular,
              info: 'עוזרת לזהות מבנה כותרות של ספר. נשלח רק תקציר כותרות. המפתח נשמר בקובץ מקומי במחשב.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'gemini', label: Text('Gemini')),
                      ButtonSegment(value: 'claude', label: Text('Claude')),
                      ButtonSegment(value: 'openai', label: Text('OpenAI')),
                    ],
                    selected: {s.aiProvider},
                    onSelectionChanged: (v) {
                      s.aiProvider = v.first;
                      _key.text = _currentKey();
                      _model.text = _currentModel();
                      c.changed();
                    },
                  ),
                  const SizedBox(height: AppTokens.spaceSM),
                  TextField(
                    controller: _key,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'מפתח API'),
                    onChanged: (v) {
                      s.aiKeys[s.aiProvider] = v.trim();
                      c.save();
                    },
                  ),
                  const SizedBox(height: AppTokens.spaceSM),
                  TextField(
                    controller: _model,
                    decoration: const InputDecoration(labelText: 'מודל (ריק = בחירה אוטומטית)'),
                    onChanged: (v) {
                      s.aiModels[s.aiProvider] = v.trim();
                      c.save();
                    },
                  ),
                  if (s.aiProvider == 'gemini') ...[
                    const SizedBox(height: AppTokens.spaceSM),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'free', label: Text('מסלול חינמי')),
                        ButtonSegment(value: 'paid', label: Text('בתשלום')),
                      ],
                      selected: {s.aiTier},
                      onSelectionChanged: (v) {
                        s.aiTier = v.first;
                        c.changed();
                      },
                    ),
                  ],
                ],
              ),
            ),
            const CreditsCard(),
            Hint('גרסה ${appVersion.isEmpty ? 'פיתוח' : appVersion}'),
          ],
        );
      },
    );
  }
}
