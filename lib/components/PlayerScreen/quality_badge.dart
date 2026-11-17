import 'dart:math';

import 'package:flutter/material.dart';

/// What the current track sounds like, shown as a logo on the player screen.
enum ListeningQuality {
  /// Lossless, above CD resolution (more than 16 bits or more than 48 kHz)
  hiRes,

  /// Lossless at CD resolution (16 bits, 44.1 / 48 kHz)
  cd,

  /// Lossy (MP3, AAC, Opus...)
  lossy;

  static const _losslessCodecs = {"flac", "alac", "wav", "aiff", "ape", "wavpack", "wv", "tta", "dsd", "truehd", "mlp"};

  /// Classifies what is actually played: [codec] after any transcoding, its [bitDepth] and [sampleRate].
  static ListeningQuality? of({required String? codec, int? bitDepth, int? sampleRate}) {
    final name = codec?.toLowerCase().trim();
    if (name == null || name.isEmpty || name == "unknown" || name == "inconnu") return null;
    final lossless = _losslessCodecs.contains(name) || name.startsWith("pcm") || name.startsWith("dsd");
    if (!lossless) return ListeningQuality.lossy;
    if ((bitDepth ?? 16) > 16 || (sampleRate ?? 44100) > 48000) return ListeningQuality.hiRes;
    return ListeningQuality.cd;
  }
}

/// The logo for [quality]: Hi-Res Audio, Compact Disc or an "mp3"-style mark (with the codec's name for other
/// lossy formats). Drawn in code so it stays sharp at any size.
class QualityBadge extends StatelessWidget {
  const QualityBadge({super.key, required this.quality, required this.codec, this.height = 30});

  final ListeningQuality quality;
  final String codec;
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.white;
    final label = switch (quality) {
      ListeningQuality.hiRes => "Hi-Res Audio",
      ListeningQuality.cd => "Compact Disc",
      ListeningQuality.lossy => codec.toUpperCase(),
    };
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: switch (quality) {
          ListeningQuality.hiRes => _HiResLogo(size: height),
          ListeningQuality.cd => _CompactDiscLogo(height: height, color: color),
          ListeningQuality.lossy => _LossyLogo(height: height, color: color, text: codec.toLowerCase()),
        },
      ),
    );
  }
}

/// Gold square, "Hi·Res" on top, "AUDIO" in gold on a dark band with a curved top.
class _HiResLogo extends StatelessWidget {
  const _HiResLogo({required this.size});

  final double size;

  static const _brown = Color(0xFF2B1E15);
  static const _gold = Color(0xFFE8AE1C);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.04),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFE27A), Color(0xFFF2BF2C), Color(0xFFD99A12)],
        ),
        border: Border.all(color: const Color(0xFFB07A0E), width: max(0.6, size * 0.025)),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _HiResBandPainter(_brown))),
          Positioned(
            left: size * 0.06,
            right: size * 0.06,
            top: size * 0.07,
            height: size * 0.42,
            child: const FittedBox(
              child: Text(
                "Hi·Res",
                style: TextStyle(color: _brown, fontWeight: FontWeight.w700, height: 1, letterSpacing: -0.5),
              ),
            ),
          ),
          Positioned(
            left: size * 0.1,
            right: size * 0.1,
            bottom: size * 0.07,
            height: size * 0.3,
            child: const FittedBox(
              child: Text(
                "AUDIO",
                style: TextStyle(color: _gold, fontWeight: FontWeight.w700, height: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HiResBandPainter extends CustomPainter {
  _HiResBandPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final inset = w * 0.035;
    final top = h * 0.52;
    final path = Path()
      ..moveTo(inset, top)
      ..quadraticBezierTo(w / 2, top + h * 0.2, w - inset, top)
      ..lineTo(w - inset, h - inset)
      ..lineTo(inset, h - inset)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_HiResBandPainter oldDelegate) => oldDelegate.color != color;
}

/// "COMPACT" above a big outlined "disc", like the Compact Disc Digital Audio mark.
class _CompactDiscLogo extends StatelessWidget {
  const _CompactDiscLogo({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: height * 1.55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            height: height * 0.3,
            child: FittedBox(
              child: Text(
                "COMPACT",
                style: TextStyle(color: color, fontWeight: FontWeight.w900, height: 1, letterSpacing: 0.5),
              ),
            ),
          ),
          SizedBox(
            height: height * 0.7,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.fill,
              child: Text(
                "disc",
                // drawn large then scaled down, so the outline keeps its proportions
                style: TextStyle(
                  fontSize: 100,
                  fontWeight: FontWeight.w700,
                  height: 0.95,
                  letterSpacing: 6,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 7
                    ..strokeJoin = StrokeJoin.round
                    ..color = color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Heavy italic codec name ("mp3", "aac"...) with the swoosh around it, like the mp3 mark.
class _LossyLogo extends StatelessWidget {
  const _LossyLogo({required this.height, required this.color, required this.text});

  final double height;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: height * (0.9 + 0.42 * text.length),
      child: CustomPaint(
        painter: _SwooshPainter(color),
        child: Padding(
          padding: EdgeInsets.only(left: height * 0.32, top: height * 0.2, bottom: height * 0.12),
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                height: 1,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwooshPainter extends CustomPainter {
  _SwooshPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final rect = Rect.fromLTWH(h * 0.04, h * 0.06, h * 1.15, h * 0.9);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = h * 0.07;
    // Open circle around the "m", from the bottom right round to the top
    canvas.drawArc(rect, pi * 0.42, pi * 1.5, false, paint);
  }

  @override
  bool shouldRepaint(_SwooshPainter oldDelegate) => oldDelegate.color != color;
}
