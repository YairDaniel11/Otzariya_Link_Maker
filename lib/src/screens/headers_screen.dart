import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../widgets/common_widgets.dart';

/// מקום שמור: המסך נכתב בנפרד.
class HeadersScreen extends StatelessWidget {
  const HeadersScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) =>
      const Center(child: EmptyState(icon: FluentIcons.wrench_24_regular, title: 'בבנייה'));
}
