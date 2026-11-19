import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:material_ui/material_ui.dart';

const _popupDuration = Duration(milliseconds: 240);

Future<T?> showExpressiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showDialog<T>(
    context: context,
    animationStyle: reduceMotion
        ? AnimationStyle.noAnimation
        : AnimationStyle(
            duration: _popupDuration,
            curve: _PopupSpringCurve.effects,
            reverseCurve: Curves.easeInCubic,
          ),
    builder: (context) {
      final dialog = Builder(builder: builder);
      if (reduceMotion) return dialog;
      return ScaleTransition(
        scale: _popupScale(ModalRoute.of(context)!.animation!),
        child: RepaintBoundary(child: dialog),
      );
    },
  );
}

Future<void> showEarbudLocatorNotice(
  BuildContext context,
  String message, {
  String title = 'Find my earbuds',
}) =>
    showExpressiveDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );

Future<T?> showExpressiveMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required double preferredHeight,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final button = context.findRenderObject()! as RenderBox;
  final anchor =
      button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;

  return navigator.push(
    _AnchoredMenuRoute<T>(
      anchor: anchor,
      preferredHeight: preferredHeight,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    ),
  );
}

class _AnchoredMenuRoute<T> extends PopupRoute<T> {
  _AnchoredMenuRoute({
    required this.anchor,
    required this.preferredHeight,
    required this.builder,
    required this.themes,
    required this.barrierLabel,
    required this.reduceMotion,
  });

  final Rect anchor;
  final double preferredHeight;
  final WidgetBuilder builder;
  final CapturedThemes themes;
  final bool reduceMotion;

  @override
  final String barrierLabel;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : _popupDuration;

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 140);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Offset.zero & constraints.biggest;
        final usable = media.viewPadding
            .copyWith(
              bottom: math.max(
                media.viewPadding.bottom,
                media.viewInsets.bottom,
              ),
            )
            .deflateRect(viewport);
        final screens = DisplayFeatureSubScreen.subScreensInBounds(
          usable,
          DisplayFeatureSubScreen.avoidBounds(media),
        );
        final screen = screens.reduce(
          (a, b) =>
              (a.center - anchor.center).distanceSquared <=
                  (b.center - anchor.center).distanceSquared
              ? a
              : b,
        );
        final bounds = screen.deflate(8);
        if (bounds.isEmpty) return const SizedBox.shrink();

        final below = (anchor.bottom + 4).clamp(bounds.top, bounds.bottom);
        final above = (anchor.top - 4).clamp(bounds.top, bounds.bottom);
        final belowHeight = bounds.bottom - below;
        final aboveHeight = above - bounds.top;
        final opensBelow =
            belowHeight >= preferredHeight || belowHeight >= aboveHeight;
        final width = math.min(anchor.width, bounds.width);
        final left = anchor.left.clamp(bounds.left, bounds.right - width);

        Widget menu = Semantics(
          role: SemanticsRole.menu,
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: MaterialLocalizations.of(context).popupMenuLabel,
          child: themes.wrap(_MenuSurface(builder: builder)),
        );
        if (!reduceMotion) {
          menu = FadeTransition(
            opacity: animation.drive(
              CurveTween(curve: _PopupSpringCurve.effects),
            ),
            child: ScaleTransition(
              alignment: opensBelow
                  ? Alignment.topCenter
                  : Alignment.bottomCenter,
              scale: _popupScale(animation),
              child: RepaintBoundary(child: menu),
            ),
          );
        }

        return Stack(
          children: [
            Positioned(
              left: left,
              top: opensBelow ? below : null,
              bottom: opensBelow ? null : viewport.bottom - above,
              width: width,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(
                    preferredHeight,
                    opensBelow ? belowHeight : aboveHeight,
                  ),
                ),
                child: menu,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MenuSurface extends StatefulWidget {
  const _MenuSurface({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_MenuSurface> createState() => _MenuSurfaceState();
}

class _MenuSurfaceState extends State<_MenuSurface> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      elevation: 3,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.all(6),
            child: Builder(builder: widget.builder),
          ),
        ),
      ),
    );
  }
}

Animation<double> _popupScale(Animation<double> animation) => animation.drive(
  Tween(
    begin: 0.92,
    end: 1.0,
  ).chain(CurveTween(curve: _PopupSpringCurve.spatial)),
);

class _PopupSpringCurve extends Curve {
  const _PopupSpringCurve(this._simulation, {this.bounded = false});

  static final effects = _PopupSpringCurve(
    SpringSimulation(Springs.expressiveFastEffects, 0, 1, 0),
    bounded: true,
  );
  static final spatial = _PopupSpringCurve(
    SpringSimulation(Springs.expressiveFastSpatial, 0, 1, 0),
  );

  final SpringSimulation _simulation;
  final bool bounded;

  @override
  double transformInternal(double t) {
    final value = _simulation.x(t * _popupDuration.inMilliseconds / 1000);
    return bounded ? value.clamp(0.0, 1.0) : value;
  }
}

class ExpressiveActionMenu<T> extends StatelessWidget {
  const ExpressiveActionMenu({
    super.key,
    required this.actions,
    required this.selectedValue,
    this.destructiveValue,
  });

  final Map<T, String> actions;
  final T? selectedValue;
  final T? destructiveValue;

  @override
  Widget build(BuildContext context) {
    final options = actions.entries.toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 2,
      children: [
        for (final (index, action) in options.indexed)
          _ActionMenuRow<T>(
            value: action.key,
            label: action.value,
            selected: action.key == selectedValue,
            destructive: action.key == destructiveValue,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(index == 0 ? 24 : 4),
              bottom: Radius.circular(index == options.length - 1 ? 24 : 4),
            ),
          ),
      ],
    );
  }
}

class _ActionMenuRow<T> extends StatelessWidget {
  const _ActionMenuRow({
    required this.value,
    required this.label,
    required this.selected,
    required this.destructive,
    required this.borderRadius,
  });

  static const minimumHeight = 48.0;

  final T value;
  final String label;
  final bool selected;
  final bool destructive;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final surface = selected
        ? colors.secondaryContainer
        : colors.surfaceContainerHigh;
    final ink = destructive
        ? colors.error
        : selected
        ? colors.onSecondaryContainer
        : colors.onSurface;

    return Semantics(
      selected: selected,
      child: TextButton(
        style: ButtonStyle(
          alignment: AlignmentDirectional.centerStart,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: borderRadius),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, minimumHeight)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered)
                ? Color.alphaBlend(ink.withValues(alpha: 0.14), surface)
                : surface,
          ),
          foregroundColor: WidgetStatePropertyAll(ink),
          overlayColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) &&
                    !states.contains(WidgetState.pressed) &&
                    !states.contains(WidgetState.focused)
                ? Colors.transparent
                : null,
          ),
        ),
        onPressed: () => Navigator.pop(context, value),
        child: selected
            ? Row(
                spacing: 8,
                children: [
                  Expanded(child: Text(label)),
                  const Icon(Icons.check_rounded, size: 18),
                ],
              )
            : Text(label),
      ),
    );
  }
}

class ExpressiveOptionPicker<T extends Object> extends StatelessWidget {
  const ExpressiveOptionPicker({
    super.key,
    required this.label,
    required this.value,
    required this.actions,
    required this.onSelected,
    this.valueLabel,
  });

  final String label;
  final T? value;
  final String? valueLabel;
  final Map<T, String> actions;
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) {
    final enabled = onSelected != null && actions.isNotEmpty;
    final subtitle = valueLabel ?? actions[value] ?? value?.toString() ?? 'Choose an option';
    return ListTile(
      title: Text(label),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: const Icon(Icons.keyboard_arrow_down_rounded),
      enabled: enabled,
      onTap: enabled
          ? () async {
              final selected = await showExpressiveMenu<T>(
                context: context,
                preferredHeight: (actions.length * 50.0 + 12).clamp(0.0, 312.0),
                builder: (_) => ExpressiveActionMenu(
                  actions: actions,
                  selectedValue: value,
                ),
              );
              if (context.mounted && selected != null && selected != value) {
                onSelected!(selected);
              }
            }
          : null,
    );
  }
}
