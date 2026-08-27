import 'package:flutter/material.dart';
import 'package:mobile/theme.dart';

class DecorativeCircles extends StatelessWidget {
  const DecorativeCircles({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const primaryColor = AppTheme.primaryBlue;

    return Stack(
      children: [
        // Top right circle (large soft gradient)
        Positioned(
          top: -140,
          right: -140,
          child: IgnorePointer(
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    primaryColor.withOpacity(isDark ? 0.12 : 0.08),
                    primaryColor.withOpacity(0),
                  ],
                  stops: const [0.3, 1.0],
                ),
              ),
            ),
          ),
        ),
        // Middle left circle (medium soft gradient)
        Positioned(
          top: 280,
          left: -150,
          child: IgnorePointer(
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    primaryColor.withOpacity(isDark ? 0.08 : 0.06),
                    primaryColor.withOpacity(0),
                  ],
                  stops: const [0.3, 1.0],
                ),
              ),
            ),
          ),
        ),
        // Bottom right circle (smaller soft gradient)
        Positioned(
          bottom: -100,
          right: -100,
          child: IgnorePointer(
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    primaryColor.withOpacity(isDark ? 0.10 : 0.07),
                    primaryColor.withOpacity(0),
                  ],
                  stops: const [0.3, 1.0],
                ),
              ),
            ),
          ),
        ),
        // Accent circle for extra depth
        Positioned(
          top: 180,
          right: 40,
          child: IgnorePointer(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    primaryColor.withOpacity(isDark ? 0.06 : 0.04),
                    primaryColor.withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
