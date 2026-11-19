import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'expressive_popup.dart';

enum _TimerUnit {
  seconds(1, 'Seconds', 'second'),
  minutes(60, 'Minutes', 'minute'),
  hours(3600, 'Hours', 'hour');

  const _TimerUnit(this.secondsPerUnit, this.label, this.singular);
  final int secondsPerUnit;
  final String label;
  final String singular;

  int get maximum => 0xFFFFFFFF ~/ secondsPerUnit;
}

class ShutdownTimerCard extends StatefulWidget {
  const ShutdownTimerCard({
    super.key,
    required this.seconds,
    required this.status,
    required this.enabled,
    required this.saving,
    required this.initialInput,
    required this.onChanged,
    this.deadline,
    this.allowRestart = false,
  });

  final int? seconds;
  final String? status;
  final bool enabled;
  final bool saving;
  final DateTime? deadline;
  final ({int amount, int unitSeconds}) initialInput;
  final bool allowRestart;
  final void Function(int seconds, int unitSeconds) onChanged;

  @override
  State<ShutdownTimerCard> createState() => _ShutdownTimerCardState();
}

class _ShutdownTimerCardState extends State<ShutdownTimerCard>
    with AutomaticKeepAliveClientMixin<ShutdownTimerCard> {
  late _TimerUnit _unit = _TimerUnit.values.firstWhere(
    (unit) => unit.secondsPerUnit == widget.initialInput.unitSeconds,
    orElse: () => _TimerUnit.minutes,
  );
  late final _amount = TextEditingController(
    text: widget.initialInput.amount.toString(),
  );
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  bool get _canEdit => widget.enabled && !widget.saving;

  void _setAmount(int amount) {
    final text = amount.clamp(1, _unit.maximum).toString();
    _amount.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _setUnit(_TimerUnit unit) {
    if (!_canEdit || _unit == unit) return;
    setState(() => _unit = unit);
  }

  void _apply(int seconds) {
    _focus.unfocus();
    widget.onChanged(seconds, _unit.secondsPerUnit);
  }

  void _save() {
    final amount = int.tryParse(_amount.text);
    if (_canEdit && amount != null && amount >= 1 && amount <= _unit.maximum) {
      _apply(amount * _unit.secondsPerUnit);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final buttonEdge = BorderSide(color: colors.outlineVariant);
    final actionStyle = FilledButton.styleFrom(
      backgroundColor: colors.secondaryContainer,
      foregroundColor: colors.onSecondaryContainer,
      disabledBackgroundColor: colors.secondaryContainer.withValues(
        alpha: 0.48,
      ),
      disabledForegroundColor: colors.onSecondaryContainer.withValues(
        alpha: 0.48,
      ),
      side: buttonEdge,
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
            ] else if (widget.deadline case final deadline?) ...[
              _TimerCountdown(deadline: deadline),
              const SizedBox(height: 12),
            ],
            Center(
              child: Builder(
                builder: (context) => FilledButton.tonal(
                  onPressed: !_canEdit
                      ? null
                      : () async {
                          _focus.unfocus();
                          final unit = await showExpressiveMenu<_TimerUnit>(
                            context: context,
                            preferredHeight: 162,
                            builder: (_) => ExpressiveActionMenu(
                              actions: {
                                for (final unit in _TimerUnit.values)
                                  unit: unit.label,
                              },
                              selectedValue: _unit,
                            ),
                          );
                          if (mounted && unit != null) _setUnit(unit);
                        },
                  style: FilledButton.styleFrom(
                    textStyle: theme.textTheme.titleMedium,
                    backgroundColor: colors.secondaryContainer,
                    foregroundColor: colors.onSecondaryContainer,
                    side: buttonEdge,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      Text(_unit.label),
                      const Icon(Icons.keyboard_arrow_down_rounded),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder(
              valueListenable: _amount,
              child: TextField(
                controller: _amount,
                focusNode: _focus,
                enabled: _canEdit,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                scrollPadding: const EdgeInsets.only(bottom: 36),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
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
                onTapOutside: (_) => _focus.unfocus(),
                onSubmitted: (_) => _save(),
              ),
              builder: (context, value, field) {
                final amount = int.tryParse(value.text);
                final valid =
                    amount != null && amount >= 1 && amount <= _unit.maximum;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      spacing: 10,
                      children: [
                        IconButton.filledTonal(
                          tooltip: 'Subtract one ${_unit.singular}',
                          iconSize: 28,
                          style: IconButton.styleFrom(
                            backgroundColor: colors.surfaceContainerLow,
                            foregroundColor: colors.onSurface,
                            side: buttonEdge,
                            fixedSize: const Size.square(60),
                            shape: const StadiumBorder(),
                          ),
                          onPressed: _canEdit && amount != null && amount > 1
                              ? () => _setAmount(amount - 1)
                              : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Expanded(
                          child: Semantics(label: _unit.label, child: field),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Add one ${_unit.singular}',
                          iconSize: 28,
                          style: IconButton.styleFrom(
                            backgroundColor: colors.surfaceContainerLow,
                            foregroundColor: colors.onSurface,
                            side: buttonEdge,
                            fixedSize: const Size.square(60),
                            shape: const StadiumBorder(),
                          ),
                          onPressed:
                              _canEdit &&
                                  (amount == null || amount < _unit.maximum)
                              ? () => _setAmount((amount ?? 0) + 1)
                              : null,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    if (_canEdit && !valid)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Enter 1–${_unit.maximum} ${_unit.label.toLowerCase()}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      spacing: 8,
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
                        Expanded(
                          child: FilledButton.tonal(
                            style: actionStyle,
                            onPressed:
                                _canEdit &&
                                    valid &&
                                    (widget.allowRestart ||
                                        amount * _unit.secondsPerUnit !=
                                            widget.seconds)
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

class _TimerCountdown extends StatefulWidget {
  const _TimerCountdown({required this.deadline});

  final DateTime deadline;

  @override
  State<_TimerCountdown> createState() => _TimerCountdownState();
}

class _TimerCountdownState extends State<_TimerCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _scheduleTick();
  }

  @override
  void didUpdateWidget(_TimerCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deadline != widget.deadline) _scheduleTick();
  }

  void _scheduleTick() {
    _tick?.cancel();
    final remaining = widget.deadline.difference(DateTime.now()).inMilliseconds;
    if (remaining > 0) {
      _tick = Timer(Duration(milliseconds: (remaining - 1) % 1000 + 1), () {
        setState(() {});
        _scheduleTick();
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final deadline = widget.deadline;
    final seconds = (deadline.difference(now).inMilliseconds / 1000)
        .ceil()
        .clamp(0, 0xFFFFFFFF);
    final locale = MaterialLocalizations.of(context);
    final clock = locale.formatTimeOfDay(
      TimeOfDay.fromDateTime(deadline),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final end = DateUtils.isSameDay(now, deadline)
        ? clock
        : '${locale.formatCompactDate(deadline)} $clock';
    String pair(int value) => locale.formatDecimal(value).padLeft(2, '0');
    final remaining =
        '${pair(seconds ~/ 3600)}:'
        '${pair(seconds ~/ 60 % 60)}:${pair(seconds % 60)}';
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(remaining, style: Theme.of(context).textTheme.titleMedium),
        const ExcludeSemantics(child: Icon(Icons.circle, size: 5)),
        Text(end),
      ],
    );
  }
}
