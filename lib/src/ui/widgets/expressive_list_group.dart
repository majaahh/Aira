import 'package:material_ui/material_ui.dart';

class ExpressiveListGroup extends StatelessWidget {
  const ExpressiveListGroup({super.key, required this.children, this.color});

  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTileTheme(
      data: ListTileTheme.of(context).copyWith(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minVerticalPadding: 15,
        titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          for (final (index, child) in children.indexed)
            Material(
              color: color ?? theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(index == 0 ? 24 : 4),
                bottom: Radius.circular(index == children.length - 1 ? 24 : 4),
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
        ],
      ),
    );
  }
}
