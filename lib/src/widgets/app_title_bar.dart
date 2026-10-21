import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_surfaces.dart';
import '../theme/app_tokens.dart';

const double kAppTitleBarHeight = 40;

/// שורת הכותרת של החלון במקום המסגרת של המערכת: שם התוכנה בצד ההתחלה, שם המסך באמצע,
/// וכפתורי החלון בצד הסיום. כל השאר גורר את החלון.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key, required this.screenTitle});

  final String screenTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppSurfaces.panelBackground(context),
      child: Container(
        height: kAppTitleBarHeight,
        decoration: BoxDecoration(
          color: AppSurfaces.panelBackground(context),
          border: Border(bottom: BorderSide(color: AppSurfaces.divider(context))),
        ),
        child: Row(
          children: [
            DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMD),
                child: Row(
                  children: [
                    Icon(FluentIcons.building_bank_24_filled, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: AppTokens.spaceSM),
                    Text(
                      'ספרייה אישית לאוצריא',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: DragToMoveArea(
                child: Center(
                  child: Text(
                    screenTitle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: AppTokens.fontLG,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 138,
              height: kAppTitleBarHeight,
              child: WindowCaption(brightness: theme.brightness, backgroundColor: Colors.transparent),
            ),
          ],
        ),
      ),
    );
  }
}
