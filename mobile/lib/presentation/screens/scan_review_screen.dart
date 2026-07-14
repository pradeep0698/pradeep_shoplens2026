import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/product.dart';
import '../providers/profile_provider.dart';
import '../providers/scan_review_provider.dart';
import '../widgets/product_card.dart';

/// Arguments passed via GoRouter's `extra` when pushing '/scan-review'.
class ScanReviewArgs {
  final Uint8List imageBytes;
  final String mime;
  final Map<String, dynamic>? mlkitContext;

  const ScanReviewArgs({required this.imageBytes, required this.mime, this.mlkitContext});
}

/// Scan All's review step: shows every object Gemini detected in the frame
/// as a collapsible section (thumbnail + name), lets the user tap to
/// select/deselect which ones to search, then fires one /identify call per
/// selected object in parallel — the same call the single-tap live-camera
/// flow uses — and fills in each section's results independently as they
/// resolve.
class ScanReviewScreen extends ConsumerStatefulWidget {
  const ScanReviewScreen({super.key, required this.args});
  final ScanReviewArgs args;

  @override
  ConsumerState<ScanReviewScreen> createState() => _ScanReviewScreenState();
}

class _ScanReviewScreenState extends ConsumerState<ScanReviewScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(scanReviewProvider.notifier).detect(
          widget.args.imageBytes,
          widget.args.mime,
          mlkitContext: widget.args.mlkitContext,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scanReviewProvider);
    final shoppingCategories = ref.watch(profileProvider).valueOrNull?.shoppingCategories ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select items to search'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => context.pop(),
        ),
      ),
      body: switch (state.phase) {
        ScanReviewPhase.detecting => const _LoadingBody(),
        ScanReviewPhase.error => _ErrorBody(message: state.errorMessage ?? 'Detection failed'),
        ScanReviewPhase.ready => _ReadyBody(state: state, shoppingCategories: shoppingCategories),
      },
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF34D399)),
            SizedBox(height: 16),
            Text('Detecting objects…', style: TextStyle(color: Color(0xFF64748B))),
          ],
        ),
      );
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFF87171), size: 48),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Color(0xFFF87171), fontSize: 14), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go back', style: TextStyle(color: Color(0xFF34D399))),
              ),
            ],
          ),
        ),
      );
}

class _ReadyBody extends ConsumerWidget {
  const _ReadyBody({required this.state, required this.shoppingCategories});
  final ScanReviewState state;
  final List<String> shoppingCategories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.items.isEmpty) {
      return const Center(
        child: Text('No objects detected', style: TextStyle(color: Color(0xFF64748B))),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            itemCount: state.items.length,
            itemBuilder: (_, index) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _DetectedItemSection(
                index: index,
                item: state.items[index],
                selected: state.selected.contains(index),
                shoppingCategories: shoppingCategories,
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: state.selected.isEmpty || state.isSearching
                    ? null
                    : () => ref.read(scanReviewProvider.notifier).searchSelected(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF34D399),
                  foregroundColor: const Color(0xFF0F172A),
                  disabledBackgroundColor: const Color(0xFF334155),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                ),
                child: state.isSearching
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0F172A)),
                      )
                    : Text(
                        state.selected.isEmpty
                            ? 'Select items to search'
                            : 'Search ${state.selected.length} item${state.selected.length == 1 ? '' : 's'}',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DetectedItemSection extends ConsumerWidget {
  const _DetectedItemSection({
    required this.index,
    required this.item,
    required this.selected,
    required this.shoppingCategories,
  });

  final int index;
  final DetectedItem item;
  final bool selected;
  final List<String> shoppingCategories;

  bool get _expanded => item.status != ItemSearchStatus.idle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? const Color(0xFF34D399) : Colors.white.withValues(alpha: 0.08),
          width: selected ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => ref.read(scanReviewProvider.notifier).toggleSelect(index),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: item.cropBytes != null
                        ? Image.memory(item.cropBytes!, width: 56, height: 56, fit: BoxFit.cover)
                        : Container(width: 56, height: 56, color: const Color(0xFF334155)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.name,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _TrailingIndicator(status: item.status, selected: selected),
                ],
              ),
            ),
          ),
          if (_expanded) _SectionBody(item: item, shoppingCategories: shoppingCategories),
        ],
      ),
    );
  }
}

class _TrailingIndicator extends StatelessWidget {
  const _TrailingIndicator({required this.status, required this.selected});
  final ItemSearchStatus status;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    if (status == ItemSearchStatus.searching) {
      return const SizedBox(
        height: 20, width: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF34D399)),
      );
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
