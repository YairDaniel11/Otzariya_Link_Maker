import 'package:flutter/material.dart';

import '../../engine/repair.dart';
import '../../widgets/common_widgets.dart';

/// הסבר קצר וברור לכל סטטוס, לאנשים שאינם טכניים.
String statusExplanation(RepairStatus s) => switch (s) {
  RepairStatus.ok => 'הקישורים מתאימים לספר כמו שהוא היום. אין מה לתקן.',
  RepairStatus.updated => 'הספר השתנה, ומספרי השורות בקישורים כבר לא מדויקים. התיקון יעדכן אותם.',
  RepairStatus.unchecked => 'אי אפשר לבדוק את הקבוצה הזו (הספר חסר, או שאין לו כללים מוכרים). היא לא תשתנה.',
  RepairStatus.manual => 'קישורים שהוגדרו כידניים. התוכנה לא נוגעת בהם.',
  RepairStatus.added => 'ספר שיש לו כללים מוכרים אבל עדיין אין לו קישורים. התיקון ייצור לו קישורים.',
};

TagKind statusKind(RepairStatus s) => switch (s) {
  RepairStatus.ok => TagKind.good,
  RepairStatus.added => TagKind.good,
  RepairStatus.updated => TagKind.warn,
  RepairStatus.unchecked => TagKind.neutral,
  RepairStatus.manual => TagKind.neutral,
};

/// "הוזז בשורה אחת" וכדומה. null כשאין הזזה רלוונטית.
String? shiftText(int? shift) {
  if (shift == null) return null;
  if (shift == 0) return 'ללא הזזה';
  final n = shift.abs();
  final how = n == 1 ? 'בשורה אחת' : 'ב-$n שורות';
  return shift > 0 ? 'הוזז $how למטה' : 'הוזז $how למעלה';
}

/// האם הסטטוס דורש טיפול (משנה משהו בעת התיקון).
bool needsAttention(RepairStatus s) => s == RepairStatus.updated || s == RepairStatus.added;

/// כרטיס הסבר על כל הסטטוסים (מוצג בלחיצה על אייקון המידע).
Widget statusLegend(BuildContext context) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (final s in RepairStatus.values)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 84, child: Align(alignment: AlignmentDirectional.centerStart, child: Tag(s.label, kind: statusKind(s)))),
            const SizedBox(width: 8),
            Expanded(child: Text(statusExplanation(s), style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      ),
  ],
);
