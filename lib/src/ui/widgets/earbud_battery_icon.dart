import 'package:material_ui/material_ui.dart';

enum EarbudBatteryPart { left, chargingCase, right }

class EarbudBatteryIcon extends StatelessWidget {
  const EarbudBatteryIcon(this.part, {super.key});

  final EarbudBatteryPart part;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    return CustomPaint(
      size: Size.square(iconTheme.size ?? 24),
      painter: _EarbudBatteryIconPainter(
        part,
        iconTheme.color ?? Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

class _EarbudBatteryIconPainter extends CustomPainter {
  const _EarbudBatteryIconPainter(this.part, this.color);

  final EarbudBatteryPart part;
  final Color color;

  static final _earbud = Path()
    ..moveTo(6, 8.5)
    ..cubicTo(6, 5.2, 8.4, 3, 11.8, 3)
    ..cubicTo(15.3, 3, 18, 4.8, 18, 7.6)
    ..cubicTo(18, 10.3, 15.6, 11.9, 12.6, 11.9)
    ..quadraticBezierTo(11.5, 11.9, 11.5, 13.1)
    ..lineTo(11.5, 18.8)
    ..cubicTo(11.5, 20.2, 10.7, 21, 9.4, 21)
    ..cubicTo(8.1, 21, 7.3, 20.2, 7.3, 18.8)
    ..lineTo(7.3, 12.3)
    ..cubicTo(7.3, 10.9, 6, 10.4, 6, 8.5)
    ..close();

  static final _caseOutline = RRect.fromLTRBR(
    2.5,
    5,
    21.5,
    19,
    const Radius.circular(4.5),
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()..color = color;

    if (part == EarbudBatteryPart.chargingCase) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7;
      canvas.drawRRect(_caseOutline, paint);
      canvas.drawLine(const Offset(2.5, 10), const Offset(21.5, 10), paint);
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(const Offset(12, 14.5), 1.15, paint);
    } else {
      if (part == EarbudBatteryPart.right) {
        canvas.translate(24, 0);
        canvas.scale(-1, 1);
      }
      canvas.drawPath(_earbud, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EarbudBatteryIconPainter oldDelegate) =>
      oldDelegate.part != part || oldDelegate.color != color;
}
