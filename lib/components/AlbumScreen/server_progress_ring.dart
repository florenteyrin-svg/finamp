import 'package:flutter/material.dart';

/// Apple Music style progress: a ring with the percentage written inside.
class ServerProgressRing extends StatelessWidget {
  const ServerProgressRing({super.key, required this.percent, this.tooltip, this.failed = false});

  final int percent;
  final String? tooltip;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = failed ? theme.colorScheme.error : theme.colorScheme.primary;
    final ring = SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: percent / 100),
                  duration: const Duration(milliseconds: 600),
                  builder: (context, value, _) => CircularProgressIndicator(
                    value: value,
                    strokeWidth: 2.5,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.2),
                  ),
                ),
              ),
              Text(
                "$percent",
                style: theme.textTheme.labelSmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w700, color: color),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      label: tooltip,
      value: "$percent %",
      child: tooltip == null ? ring : Tooltip(message: tooltip!, child: ring),
    );
  }
}
