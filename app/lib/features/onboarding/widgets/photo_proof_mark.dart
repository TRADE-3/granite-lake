import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Animated "capture → verified" scene: a phone frames a photo, the
/// viewfinder closes in, the shutter flashes, a VERIFIED stamp pops and a
/// record line appears. After the intro it floats gently. [size] is the
/// width of the whole scene.
class PhotoProofMark extends StatefulWidget {
  const PhotoProofMark({super.key, this.size = 210});

  final double size;

  @override
  State<PhotoProofMark> createState() => _PhotoProofMarkState();
}

class _PhotoProofMarkState extends State<PhotoProofMark>
    with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward();
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _intro.dispose();
    _loop.dispose();
    super.dispose();
  }

  double _seg(double t, double from, double to, [Curve c = Curves.easeOut]) =>
      c.transform(((t - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final phoneW = size * 0.56;
    final phoneH = phoneW * 1.55;
    return AnimatedBuilder(
      animation: Listenable.merge([_intro, _loop]),
      builder: (context, _) {
        final t = _intro.value;
        final appear = _seg(t, 0.0, 0.25, Curves.easeOutBack);
        final close = _seg(t, 0.22, 0.5, Curves.easeInOutCubic);
        final flash = t < 0.5
            ? 0.0
            : 1 - _seg(t, 0.5, 0.64); // 1 → 0 after the shutter
        final stamp = _seg(t, 0.6, 0.82, Curves.elasticOut);
        final record = _seg(t, 0.8, 1.0);
        final float = Curves.easeInOut.transform(_loop.value) * 6 - 3;

        return SizedBox(
          width: size,
          height: phoneH + 56,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 0 + float,
                child: Opacity(
                  opacity: appear.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 0.85 + 0.15 * appear,
                    child: _Phone(
                      width: phoneW,
                      height: phoneH,
                      close: close,
                      flash: flash,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: phoneH - 22 + float,
                child: Transform.scale(
                  scale: stamp,
                  child: Opacity(
                    opacity: stamp.clamp(0.0, 1.0),
                    child: const _VerifiedPill(),
                  ),
                ),
              ),
              Positioned(
                top: phoneH + 28,
                child: Opacity(
                  opacity: record,
                  child: Transform.translate(
                    offset: Offset(0, 8 * (1 - record)),
                    child: Text(
                      'ID 7F3A · 12:41 · 6.93°N 79.85°E',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10.5,
                        letterSpacing: 1.1,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Phone extends StatelessWidget {
  const _Phone({
    required this.width,
    required this.height,
    required this.close,
    required this.flash,
  });

  final double width;
  final double height;
  final double close;
  final double flash;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: const Color(0xFF14083D),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(70),
            blurRadius: 34,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _LandscapePainter(flip: false)),
            CustomPaint(painter: _FocusPainter(close)),
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 34,
                height: 8,
                decoration: BoxDecoration(
                  color: const Color(0xFF14083D),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            if (flash > 0)
              ColoredBox(color: Colors.white.withValues(alpha: flash * 0.85)),
          ],
        ),
      ),
    );
  }
}

/// Viewfinder corners that start wide and close in on the subject.
class _FocusPainter extends CustomPainter {
  _FocusPainter(this.close);

  final double close;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.width * (0.04 + 0.16 * close);
    final rect = Rect.fromLTRB(
      inset,
      size.height * 0.2 + inset * 0.4,
      size.width - inset,
      size.height * 0.82 - inset * 0.4,
    );
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final len = size.width * 0.14;
    void corner(Offset o, double dx, double dy) {
      canvas.drawLine(o, o + Offset(dx * len, 0), paint);
      canvas.drawLine(o, o + Offset(0, dy * len), paint);
    }

    corner(rect.topLeft, 1, 1);
    corner(rect.topRight, -1, 1);
    corner(rect.bottomLeft, 1, -1);
    corner(rect.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _FocusPainter old) => old.close != close;
}

class _VerifiedPill extends StatelessWidget {
  const _VerifiedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 7, 16, 7),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(36),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: AppColors.statusActive,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              color: Colors.white,
              size: 16,
            ),
          ),
          const SizedBox(width: 9),
          Text(
            'VERIFIED',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// A simple brand-coloured sunset landscape standing in for a site photo.
class _LandscapePainter extends CustomPainter {
  _LandscapePainter({required this.flip});

  final bool flip;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3B128D), Color(0xFFB0457A), Color(0xFFF75835)],
          stops: [0.0, 0.55, 0.85],
        ).createShader(Offset.zero & size),
    );
    canvas.drawCircle(
      Offset(w * (flip ? 0.3 : 0.68), h * 0.5),
      w * 0.14,
      Paint()..color = const Color(0xFFFFD9A8),
    );
    Path hill(double base, double peakX, double peakY) => Path()
      ..moveTo(0, h)
      ..lineTo(0, h * base)
      ..quadraticBezierTo(w * peakX, h * peakY, w, h * (base + 0.05))
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(
      hill(0.7, flip ? 0.7 : 0.3, 0.5),
      Paint()..color = const Color(0xFF2A0C69),
    );
    canvas.drawPath(
      hill(0.82, flip ? 0.3 : 0.7, 0.68),
      Paint()..color = const Color(0xFF14083D),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// One icon + short line, used under the hero on the welcome screen.
class FeatureRow extends StatelessWidget {
  const FeatureRow({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(22),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 19, color: AppColors.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}
