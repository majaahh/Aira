import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class ShutdownTimerCard extends StatefulWidget {
  const ShutdownTimerCard({
    super.key,
    required this.seconds,
    required this.status,
    required this.enabled,
    required this.saving,
    this.allowRestart = false,
    required this.onChanged,
  });

  final int? seconds;
  final String? status;
  final bool enabled;
  final bool saving;
  final bool allowRestart;
  final ValueChanged<int> onChanged;

  @override
  State<ShutdownTimerCard> createState() => _ShutdownTimerCardState();
}

class _ShutdownTimerCardState extends State<ShutdownTimerCard>
    with AutomaticKeepAliveClientMixin<ShutdownTimerCard> {
  static const _maxMinutes = 0xFFFFFFFF ~/ 60;

  late final _minutes = TextEditingController(
    text: _initialMinutes(widget.seconds),
  );

  static String _initialMinutes(int? seconds) => switch (seconds) {
    null || 0 => '30',
    _ => (seconds ~/ 60).clamp(1, _maxMinutes).toString(),
  };

  @override
  void didUpdateWidget(ShutdownTimerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final disconnected = oldWidget.enabled && !widget.enabled;
    final durationChanged = oldWidget.seconds != widget.seconds;
    if (disconnected ||
        (durationChanged &&
            (oldWidget.saving ||
                _minutes.text == _initialMinutes(oldWidget.seconds)))) {
      _minutes.text = _initialMinutes(widget.seconds);
    }
  }

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  bool get _canEdit => widget.enabled && !widget.saving;

  void _step(int delta) {
    final minutes = int.tryParse(_minutes.text) ?? 0;
    final text = (minutes + delta).clamp(1, _maxMinutes).toString();
    _minutes.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  bool _isValid(int? minutes) =>
      minutes != null && minutes >= 1 && minutes <= _maxMinutes;

  void _save() {
    final minutes = int.tryParse(_minutes.text);
    if (_canEdit && _isValid(minutes)) _apply(minutes! * 60);
  }

  void _apply(int seconds) {
    FocusScope.of(context).unfocus();
    widget.onChanged(seconds);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actionStyle = FilledButton.styleFrom(
      backgroundColor: colors.primary,
      foregroundColor: colors.onPrimary,
      minimumSize: const Size(0, 52),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      shape: const StadiumBorder(),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.status case final status?) ...[
              Row(
                children: [
                  Icon(
                    Icons.timer_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(status, style: theme.textTheme.bodyMedium),
                  ),
                  if (widget.saving)
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            ExcludeSemantics(
              child: Text(
                'Minutes',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder(
              valueListenable: _minutes,
              builder: (context, value, _) {
                final minutes = int.tryParse(value.text);
                final valid = _isValid(minutes);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton.filledTonal(
                          tooltip: 'Subtract one minute',
                          iconSize: 28,
                          style: IconButton.styleFrom(
                            fixedSize: const Size.square(60),
                            shape: const StadiumBorder(),
                          ),
                          onPressed: _canEdit && minutes != null && minutes > 1
                              ? () => _step(-1)
                              : null,
                          icon: const Icon(Icons.remove),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Semantics(
                            label: 'Minutes',
                            child: TextField(
                              controller: _minutes,
                              enabled: _canEdit,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineSmall,
                              keyboardType: TextInputType.number,
                              textInputAction: TextInputAction.done,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(8),
                              ],
                              decoration: InputDecoration(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 16,
                                ),
                                filled: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onSubmitted: (_) => _save(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filled(
                          tooltip: 'Add one minute',
                          iconSize: 28,
                          style: IconButton.styleFrom(
                            fixedSize: const Size(68, 60),
                            shape: const StadiumBorder(),
                          ),
                          onPressed:
                              _canEdit &&
                                  (minutes == null || minutes < _maxMinutes)
                              ? () => _step(1)
                              : null,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    if (_canEdit && !valid)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Enter 1–$_maxMinutes minutes',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonal(
                            style: actionStyle,
                            onPressed: _canEdit && widget.seconds != 0
                                ? () => _apply(0)
                                : null,
                            child: const Text(
                              'Turn off',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.tonal(
                            style: actionStyle,
                            onPressed:
                                _canEdit &&
                                    valid &&
                                    (widget.allowRestart ||
                                        minutes! * 60 != widget.seconds)
                                ? _save
                                : null,
                            child: const Text(
                              'Set timer',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
