import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/profile_provider.dart';
import '../providers/scan_review_provider.dart';
import '../widgets/detected_item_section.dart';

/// Gallery Scan All, phase 4: shows only the objects the user selected, each
/// as its own collapsible section. Sections render immediately (skeleton +
/// spinner) and fill in independently as their parallel /identify call
/// resolves — a slow object never blocks a faster one from showing results.
class GalleryScanResultsScreen extends ConsumerWidget {
  const GalleryScanResultsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scanReviewProvider);
    final shoppingCategories = ref.watch(profileProvider).valueOrNull?.shoppingCategories ?? const [];
    final selected = state.selected.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: Text('Search Results (${selected.length})'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => context.pop(),
        ),
      ),
      body: selected.isEmpty
          ? const Center(
              child: Text('No items selected', style: TextStyle(color: Color(0xFF64748B))),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: selected.length,
              itemBuilder: (_, i) {
                final index = selected[i];
                final item = state.items[index];
                return Padding(
                  key: ValueKey(item.box),
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DetectedItemSection(
                    index: index,
                    displayNumber: i + 1,
                    item: item,
                    selected: true,
                    shoppingCategories: shoppingCategories,
                    showSelectionAffordance: false,
                  ),
                );
              },
            ),
    );
  }
}
