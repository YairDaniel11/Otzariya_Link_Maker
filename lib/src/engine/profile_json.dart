// פרופיל כללים <-> JSON, תואם לסכמת הפרופיל של התוכנה בפייתון (profile_for_ai / validate_profile).

import 'linker_core.dart';

const _ruleTypes = {'daf', 'heading', 'target_switch', 'anchor'};
const _roles = {'ref', 'chapter', 'sub'};

List<int> _levelsOf(Object? v) {
  if (v is List && v.isNotEmpty) {
    final a = num.tryParse('${v.first}')?.toInt();
    final b = num.tryParse('${v.last}')?.toInt();
    if (a != null && b != null) return [a, b];
  }
  return const [2, 6];
}

Rule _ruleFromJson(Map r) {
  final fm = r['formats'];
  return Rule(
    r['type'] as String,
    levels: _levelsOf(r['levels']),
    regex: r['regex'] is String ? r['regex'] as String : null,
    ref: r['ref'] is String ? r['ref'] as String : '{1}',
    role: r['role'] is String ? r['role'] as String : 'ref',
    formats: fm is List ? [for (final x in fm) '$x'] : null,
  );
}

/// בונה Profile מ-JSON. מומלץ להריץ קודם [validateProfileJson]; כלל מסוג לא מוכר זורק FormatException.
Profile profileFromJson(Map<dynamic, dynamic> j) {
  final rules = j['rules'];
  if (rules is! List) throw const FormatException('חסרים כללים');
  return Profile(
    target: j['target'] is String ? j['target'] as String : '',
    targetFromName: j['target_from_name'] == true,
    linkType: j['link_type'] is String && (j['link_type'] as String).isNotEmpty ? j['link_type'] as String : 'פירוש',
    validate: j['validate'] != false,
    resetOnUnmatched: j['reset_on_unmatched'] == true,
    rules: [
      for (final r in rules)
        if (r is Map && _ruleTypes.contains(r['type'])) _ruleFromJson(r) else throw const FormatException('סוג כלל לא מוכר'),
    ],
  );
}

/// JSON של פרופיל (המפתחות כמו בפייתון). [name] אופציונלי (שדה תיאור חופשי).
Map<String, dynamic> profileToJson(Profile p, {String? name}) => {
  'name': ?name,
  'target': p.target,
  'target_from_name': p.targetFromName,
  'link_type': p.linkType,
  'validate': p.validate,
  if (p.resetOnUnmatched) 'reset_on_unmatched': true,
  'rules': [
    for (final r in p.rules)
      {
        'type': r.type,
        if (r.type != 'anchor') 'levels': [r.lo, r.hi],
        if (r.regex != null) 'regex': r.regex,
        if (r.type == 'heading') ...{'ref': r.ref, 'role': r.role},
        if (r.type == 'daf') 'formats': r.formats ?? const ['std', 'ext'],
      },
  ],
};

/// בדיקת תקינות של פרופיל JSON (מהמשתמש או מ-AI). רשימת שגיאות בעברית; ריקה = תקין.
List<String> validateProfileJson(Object? profile) {
  if (profile is! Map) return ['הפרופיל אינו אובייקט'];
  final rules = profile['rules'];
  if (rules is! List || rules.isEmpty) return ['חסרים כללים'];
  final errs = <String>[];
  for (var k = 1; k <= rules.length; k++) {
    final r = rules[k - 1];
    if (r is! Map || !_ruleTypes.contains(r['type'])) {
      errs.add('כלל $k: סוג לא מוכר');
      continue;
    }
    final t = r['type'];
    if (t == 'heading' || t == 'target_switch') {
      try {
        RegExp(r['regex'] is String ? r['regex'] as String : '');
      } on FormatException catch (e) {
        errs.add('כלל $k: ביטוי רגולרי שגוי (${e.message})');
      }
      if (t == 'heading' && !_roles.contains(r['role'] ?? 'ref')) errs.add('כלל $k: role לא מוכר');
    }
  }
  return errs;
}
