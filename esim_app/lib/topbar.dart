import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'currency.dart';
import 'i18n.dart';
import 'store.dart';
import 'theme.dart';

/// Pill button used in the top bar for language / currency.
class _Pill extends StatelessWidget {
  final String text;
  final bool highlight;
  final VoidCallback onTap;
  const _Pill(this.text, this.onTap, {this.highlight = false});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: highlight ? AppColors.primary.withValues(alpha: 0.1) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: highlight ? AppColors.primary : AppColors.border, width: 1.2),
          ),
          child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: highlight ? AppColors.primary : AppColors.text)),
        ),
      );
}

/// Top bar with brand + language/currency switchers. Use as the first child
/// of any screen body.
class TopBar extends StatelessWidget {
  final String title;
  final bool showBrand;
  const TopBar({super.key, this.title = '', this.showBrand = false});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
      child: Row(
        children: [
          Text(
            showBrand ? 'Onlylink' : title,
            style: TextStyle(
              fontSize: showBrand ? 21 : 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: showBrand ? AppColors.primary : AppColors.text,
            ),
          ),
          const Spacer(),
          _Pill(app.lang.short, () => _pickLang(context), highlight: true),
          const SizedBox(width: 8),
          _Pill(app.currency.label, () => _pickCurrency(context), highlight: true),
        ],
      ),
    );
  }

  void _pickLang(BuildContext context) {
    final app = context.read<AppState>();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _PickerSheet<AppLang>(
        title: app.t.language,
        current: app.lang,
        options: AppLang.values,
        labelOf: (v) => v.label,
        onPick: (v) {
          app.setLang(v);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _pickCurrency(BuildContext context) {
    final app = context.read<AppState>();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _PickerSheet<AppCurrency>(
        title: app.t.currency,
        current: app.currency,
        options: AppCurrency.values,
        labelOf: (v) => '${v.code}  ${v.symbol}',
        onPick: (v) {
          app.setCurrency(v);
          Navigator.pop(context);
        },
      ),
    );
  }
}

/// Generic bottom-sheet picker for language / currency.
class _PickerSheet<T> extends StatelessWidget {
  final String title;
  final T current;
  final List<T> options;
  final String Function(T) labelOf;
  final void Function(T) onPick;
  const _PickerSheet({required this.title, required this.current, required this.options, required this.labelOf, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 14 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Padding(padding: const EdgeInsets.only(left: 4), child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          const SizedBox(height: 8),
          // ListTile paints its splash on the nearest Material ancestor, so it
          // needs one between it and the white DecoratedBox above.
          ...options.map((o) => Material(
                type: MaterialType.transparency,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(labelOf(o), style: TextStyle(fontWeight: o == current ? FontWeight.w800 : FontWeight.w500, color: o == current ? AppColors.primary : AppColors.text)),
                  trailing: o == current ? const Icon(Icons.check_circle, color: AppColors.primary) : null,
                  onTap: () => onPick(o),
                ),
              )),
        ],
      ),
    );
  }
}

// (end of file)
