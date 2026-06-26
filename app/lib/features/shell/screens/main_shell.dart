import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../history/screens/history_screen.dart';
import '../../profile/screens/profile_screen.dart';
import '../../projects/screens/projects_screen.dart';
import 'capture_tab_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, this.initialTab = 1});

  /// Which tab to open: 0=History 1=Capture 2=Projects 3=Profile.
  final int initialTab;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialTab;
  }

  static const _tabs = [
    _NavItem(label: 'History', icon: Icons.history_rounded),
    _NavItem(label: 'Capture', icon: Icons.radio_button_checked_rounded),
    _NavItem(label: 'Projects', icon: Icons.folder_open_outlined),
    _NavItem(label: 'Profile', icon: Icons.person_outline_rounded),
  ];

  static const _bodies = [
    HistoryScreen(),
    CaptureTabScreen(),
    ProjectsScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _selectedIndex, children: _bodies),
      ),
      bottomNavigationBar: _GraniteBottomNavBar(
        items: _tabs,
        selectedIndex: _selectedIndex,
        hasActiveSession: controller.hasActiveSession,
        onTap: (index) async {
          setState(() => _selectedIndex = index);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom bottom navigation bar matching the Granite Lake dark theme.
// ─────────────────────────────────────────────────────────────────────────────

class _NavItem {
  const _NavItem({required this.label, required this.icon});
  final String label;
  final IconData icon;
}

class _GraniteBottomNavBar extends StatelessWidget {
  const _GraniteBottomNavBar({
    required this.items,
    required this.selectedIndex,
    required this.hasActiveSession,
    required this.onTap,
  });

  final List<_NavItem> items;
  final int selectedIndex;
  final bool hasActiveSession;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: List.generate(items.length, (i) {
              return Expanded(
                child: _NavBarItem(
                  item: items[i],
                  isSelected: selectedIndex == i,
                  showSessionDot: i == 1 && hasActiveSession,
                  onTap: () => onTap(i),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
    required this.item,
    required this.isSelected,
    required this.showSessionDot,
    required this.onTap,
  });

  final _NavItem item;
  final bool isSelected;
  final bool showSessionDot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppColors.statusActive : AppColors.textMuted;

    return InkWell(
      onTap: onTap,
      splashColor: AppColors.statusActive.withAlpha(30),
      highlightColor: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Active indicator dot above icon.
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 4,
              height: 4,
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? AppColors.statusActive : Colors.transparent,
              ),
            ),
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topRight,
              children: [
                Icon(item.icon, size: 22, color: color),
                if (showSessionDot && !isSelected)
                  Positioned(
                    top: -2,
                    right: -4,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.statusActive,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              style: AppTextStyles.labelSmall.copyWith(
                color: color,
                fontSize: 11,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
