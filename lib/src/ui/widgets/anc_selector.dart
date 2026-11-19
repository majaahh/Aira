import 'package:material_ui/material_ui.dart';

class AncSelector extends StatelessWidget {
  const AncSelector({
    super.key,
    required this.selectedMode,
    required this.onChanged,
    this.enabled = true,
    this.showAdaptive = true,
  });

  final String selectedMode;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool showAdaptive;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: [
          const ButtonSegment<String>(value: 'Normal', label: Text('Off')),
          const ButtonSegment<String>(value: 'ANC On', label: Text('ANC')),
          const ButtonSegment<String>(
            value: 'Transparency',
            label: Text('Aware'),
          ),
          if (showAdaptive)
            const ButtonSegment<String>(
              value: 'Adaptive',
              label: FittedBox(fit: BoxFit.scaleDown, child: Text('Adaptive')),
            ),
        ],
        selected: {selectedMode},
        onSelectionChanged: enabled
            ? (newSelection) => onChanged(newSelection.first)
            : null,
      ),
    );
  }
}
