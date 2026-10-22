import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/common_widgets.dart';
import '../widgets/credits_card.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return PageBody(
      children: [
        _section(FluentIcons.book_add_24_regular, 'יצירת כותרות לספר חדש', const [
          'בוחרים קובץ Word (docx), Markdown (md) או טקסט (txt).',
          'נותנים שם לספר, ואם רוצים גם שם מחבר.',
          'מסמנים אילו שורות הן כותרות (פרק, סימן, דף ועוד). בקובץ Word שיש בו כותרות מעוצבות, הן מזוהות לבד.',
          'בודקים את תצוגת הכותרות והבדיקות, ולוחצים "שמור את הספר".',
          'מוסיפים לאוצריא: הגדרות ← ספרייה ← הוספת תיקייה (ספרים אישיים).',
        ]),
        _section(FluentIcons.link_24_regular, 'יצירת קישורים לפירוש', const [
          'בוחרים את קובץ הפירוש (txt בפורמט אוצריא).',
          'בוחרים על איזה ספר הוא מפרש, או לוחצים "זיהוי אוטומטי לפי שם הקובץ".',
          'בודקים בתצוגה המקדימה שהקישורים נראים נכון, ושומרים קובץ links.csv.',
          'באוצריא: הגדרות ← ספרים אישיים ← ייבוא קישורים.',
        ]),
        _section(FluentIcons.checkmark_starburst_24_regular, 'בדיקה ותיקון קישורים קיימים', const [
          'בוחרים את תיקיית הספרים ואת תיקיית קבצי הקישורים.',
          'לוחצים "בדוק", ורואים אילו קבוצות קישורים זזו.',
          'לוחצים "תקן". לפני התיקון נשמר גיבוי zip.',
        ]),
        AppCard(
          title: 'שאלות נפוצות',
          icon: FluentIcons.question_circle_24_regular,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('למה צריך את הספרייה של אוצריא?', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('כדי לוודא שכל קישור מצביע למקום שקיים באמת (הקובץ seforim.db). כותרות נוצרות גם בלעדיה.'),
              SizedBox(height: AppTokens.spaceSM),
              Text('מה זה בינה מלאכותית בהגדרות?', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('אופציונלי. עוזר להציע כללי כותרות לספר שהתוכנה לא מזהה. הספרים עצמם לא נשלחים, רק תקציר כותרות.'),
              SizedBox(height: AppTokens.spaceSM),
              Text('קובץ doc ישן לא נפתח', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('פתחו אותו ב-Word ושמרו בשם כ-docx.'),
            ],
          ),
        ),
        const CreditsCard(),
      ],
    );
  }

  Widget _section(IconData icon, String title, List<String> steps) {
    return AppCard(
      title: title,
      icon: icon,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.spaceXS),
              child: Text('${i + 1}. ${steps[i]}'),
            ),
        ],
      ),
    );
  }
}
