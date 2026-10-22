import 'package:flutter/material.dart';

import '../../engine/repair.dart';
import '../../theme/app_surfaces.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common_widgets.dart';
import 'status_info.dart';

/// שורה אחת בדוח: ספר, סטטוס, ספירות לפני/אחרי, הזזה והסבר.
class ReportRow extends StatelessWidget {
  const ReportRow(this.entry, {super.key});

  final RepairEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final shift = shiftText(entry.shift);
    final counts = entry.status == RepairStatus.added
        ? 'יווצרו ${entry.newCount} קישורים'
        : entry.oldCount == entry.newCount
        ? '${entry.oldCount} קישורים'
        : '${entry.oldCount} ← ${entry.newCount} קישורים';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMD, vertical: AppTokens.spaceSM),
      decoration: BoxDecoration(
        color: AppSurfaces.card(context),
        borderRadius: AppTokens.borderRadiusAll,
        border: Border.all(color: AppSurfaces.divider(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.category.isEmpty ? entry.stem : '${entry.stem}  (${entry.category})',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(statusExplanation(entry.status), style: muted),
                if (entry.note.isNotEmpty) Text(entry.note, style: muted),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.spaceMD),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Tag(entry.status.label, kind: statusKind(entry.status)),
              const SizedBox(height: 4),
              Text(counts, style: theme.textTheme.bodySmall),
              if (shift != null && entry.status != RepairStatus.added) Text(shift, style: muted),
            ],
          ),
        ],
      ),
    );
  }
}
