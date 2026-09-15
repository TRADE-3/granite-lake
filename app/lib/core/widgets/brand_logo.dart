import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../state/granite_lake_controller.dart';

/// The Trade3 wordmark. Picks the light- or dark-background SVG variant to
/// match the active theme, per Work/T3/design.md section 7.8 — the logo
/// must always render from its source SVG, never recreated as text.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 48});

  final double height;

  @override
  Widget build(BuildContext context) {
    final isDark = GraniteLakeController.current?.isDarkMode ?? false;
    return SvgPicture.asset(
      isDark
          ? 'assets/logos/trade3/trade3_logo_on_dark.svg'
          : 'assets/logos/trade3/trade3_logo_on_light.svg',
      height: height,
    );
  }
}
