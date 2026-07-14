import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/product.dart';
import '../providers/scan_review_provider.dart';
import 'product_card.dart';

/// Collapsible per-object result section shared by the live-scan review
/// screen (select-then-search — [showSelectionAffordance] true, tap toggles
/// selection) and the gallery scan results screen (items are already
/// selected and searching by the time this renders — [showSelectionAffordance]
/// false, tap instead lets the user manually collapse/re-expand a
/// finished/errored section to review results at their own pace).
class DetectedItemSection extends ConsumerStatefulWidget {
  const DetectedItemSection({
    super.key,
    required this.index,
    required this.item,
    required this.selected,
    required this.shoppingCategories,
    this.showSelectionAffordance = true,
  });

  final int index;
  final DetectedItem item;
  final bool selected;
  final List<String> shoppingCategories;
  final bool showSelectionAffordance;

  @override
  ConsumerState<DetectedItemSection> createState() => _DetectedItemSectionState();
}

class _DetectedItemSectionState extends ConsumerState<DetectedItemSection> {
  bool _userCollapsed = false;

  // Only done/error states have a body worth collapsing — while searching,
  // the body is empty anyway (the header's spinner is the only feedback).
  bool get _hasBody => widget.item.status == ItemSearchStatus.done ||
                        widget.item.status == ItemSearchStatus.error;
  bool get _expanded => widget.item.status != ItemSearchStatus.idle && !_userCollapsed;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.showSelectionAffordance && widget.selected;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlighted ? const Color(0xFF34D399) : Colors.white.withValues(alpha: 0.08),
          width: highlighted ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.showSelectionAffordance
                ? () => ref.read(scanReviewProvider.notifier).toggleSelect(widget.index)
                : (_hasBody ? () => setState(() => _userCollapsed = !_userCollapsed) : null),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: widget.item.cropBytes != null
                        ? Image.memory(widget.item.cropBytes!, width: 56, height: 56, fit: BoxFit.cover)
                        : Container(width: 56, height: 56, color: const Color(0xFF334155)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.item.name,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!widget.showSelectionAffordance && _hasBody)
                    Icon(
                      _userCollapsed ? Icons.expand_more : Icons.expand_less,
                      color: const Color(0xFF64748B),
                      size: 20,
                    )
                  else
                    _TrailingIndicator(
                      status: widget.item.status,
                      selected: widget.selected,
                      showSelectionAffordance: widget.showSelectionAffordance,
                    ),
                ],
              ),
            ),
          ),
          if (_expanded) _SectionBody(item: widget.item, shoppingCategories: widget.shoppingCategories),
        ],
      ),
    );
  }
}

class _TrailingIndicator extends StatelessWidget {
  const _TrailingIndicator({
    required this.status,
    required this.selected,
    required this.showSelectionAffordance,
  });
  final ItemSearchStatus status;
  final bool selected;
  final bool showSelectionAffordance;

  @override
  Widget build(BuildContext context) {
    if (status == ItemSearchStatus.searching) {
      return const SizedBox(
        height: 20, width: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF34D399)),
      );
    }
    if (!showSelectionAffordance) {
      return switch (status) {
        ItemSearchStatus.done => const Icon(Icons.check_circle, size: 20, color: Color(0xFF34D399)),
        ItemSearchStatus.error => const Icon(Icons.error_outline, size: 20, color: Color(0xFFF87171)),
        _ => const SizedBox.shrink(),
      };
    }
    return Container(
      width: 24, height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? const Color(0xFF34D399) : Colors.transparent,
        border: Border.all(color: selected ? const Color(0xFF34D399) : Colors.white38, width: 2),
      ),
      child: selected ? const Icon(Icons.check, size: 16, color: Color(0xFF0F172A)) : null,
    );
  }
}

class _SectionBody extends StatelessWidget {
  const _SectionBody({required this.item, required this.shoppingCategories});
  final DetectedItem item;
  final List<String> shoppingCategories;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: switch (item.status) {
        ItemSearchStatus.error => Text(
            item.errorMessage ?? 'Search failed',
            style: const TextStyle(color: Color(0xFFF87171), fontSize: 12),
          ),
        ItemSearchStatus.done when item.products.isEmpty => const Text(
            'No matches found',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
          ),
        ItemSearchStatus.done => Column(
            children: [
              for (final Product p in item.products)
                ProductCard(product: p, shoppingCategories: shoppingCategories),
            ],
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}
