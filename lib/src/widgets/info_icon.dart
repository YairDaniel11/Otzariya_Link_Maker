import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

/// אייקון מידע (ⓘ): ההסבר מוצג בריחוף או בלחיצה, כדי שהמסך יישאר נקי.
class InfoIcon extends StatelessWidget {
  const InfoIcon(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 12),
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.all(10),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(FluentIcons.info_24_regular, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
