import 'package:flutter/material.dart';

/// 自有几何图形：终端提示符与前进箭头，不依赖外部品牌图片。
class GoMark extends StatelessWidget {
  const GoMark({this.size = 40, super.key});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Codex Go',
    image: true,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6473F4), Color(0xFF3647BC)],
        ),
        borderRadius: BorderRadius.circular(size * .28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4556D8).withValues(alpha: .15),
            blurRadius: size * .5,
            offset: Offset(0, size * .12),
          ),
        ],
      ),
      child: CustomPaint(painter: _GoMarkPainter()),
    ),
  );
}

class _GoMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * .075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(s * .30, s * .32)
        ..lineTo(s * .48, s * .5)
        ..lineTo(s * .30, s * .68),
      paint,
    );
    canvas.drawLine(Offset(s * .54, s * .68), Offset(s * .73, s * .68), paint);
    canvas.drawCircle(
      Offset(s * .75, s * .26),
      s * .055,
      Paint()..color = const Color(0xFF9AF1CA),
    );
  }

  @override
  bool shouldRepaint(covariant _GoMarkPainter oldDelegate) => false;
}

class GoEmptyState extends StatelessWidget {
  const GoEmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    super.key,
  });
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(icon, size: 36, color: colors.primary),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant, height: 1.6),
              ),
              if (action != null) ...[const SizedBox(height: 24), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class GoSectionHeading extends StatelessWidget {
  const GoSectionHeading(this.title, {this.subtitle, this.trailing, super.key});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 20, 18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    ),
  );
}
