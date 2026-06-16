import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/utils/video_fingerprint.dart';
import '../../data/sources/firebase/firestore_source.dart';
import '../providers/admin_provider.dart';
import 'admin_annotator_screen.dart';

/// Admin portal: lists all VideoAnnotations documents and lets the admin
/// pick a local video file to start (or continue) annotating.
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videoDocs = ref.watch(allVideoAnnotationsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Admin Portal',
            style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.video_call_outlined,
                color: Color(0xFF34D399)),
            tooltip: 'Add video',
            onPressed: () => _pickAndAnnotate(context, ref),
          ),
        ],
      ),
      body: videoDocs.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF34D399))),
        error: (e, _) => Center(
          child: Text('Error: $e',
              style: const TextStyle(color: Color(0xFFF87171)))),
        data: (docs) => docs.isEmpty
            ? _emptyState(context, ref)
            : _docList(context, ref, docs),
      ),
    );
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_outlined,
                size: 52,
                color: Colors.white.withValues(alpha: 0.12)),
            const SizedBox(height: 14),
            const Text(
              'No annotated videos yet.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _pickAndAnnotate(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Pick a video to annotate'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF34D399),
                foregroundColor: const Color(0xFF0F172A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _docList(
      BuildContext context, WidgetRef ref, List<AdminVideoDoc> docs) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: docs.length,
      itemBuilder: (_, i) {
        final doc = docs[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc.fileName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${doc.annotationCount} annotation'
                      '${doc.annotationCount != 1 ? 's' : ''}',
                      style: const TextStyle(
                          color: Color(0xFF64748B), fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _deleteVideo(context, ref, doc),
                icon: const Icon(Icons.close,
                    color: Color(0xFF64748B), size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        );
      },
    );
  }

  // Pick any video → confirm/rename it → create/merge a VideoAnnotations doc → open annotator
  Future<void> _pickAndAnnotate(
      BuildContext context, WidgetRef ref) async {
    final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (file == null || !context.mounted) return;

    final fileName = await _promptForFileName(context, file.name);
    if (fileName == null || !context.mounted) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !context.mounted) return;
    final uid = user.uid;
    final source      = ref.read(firestoreSourceProvider);
    final fingerprint = await videoFingerprint(file.path);
    await source.initVideoAnnotationsDoc(fileName, uid, fingerprint: fingerprint);

    final existingAnnotations = await source.getVideoAnnotations(fileName);

    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AdminAnnotatorScreen(
        fileName:           fileName,
        videoPath:          file.path,
        initialAnnotations: existingAnnotations,
      ),
    ));
  }

  // Lets the admin confirm or override the OS-assigned file name before it
  // becomes the VideoAnnotations doc ID — useful since iOS's Photos picker
  // hands back a fresh UUID-based name for the same video on every pick.
  Future<String?> _promptForFileName(BuildContext context, String suggested) {
    final controller = TextEditingController(text: suggested);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Name this video', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF0F172A),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              Navigator.of(dialogContext).pop(name.isEmpty ? suggested : name);
            },
            child: const Text(
              'Continue',
              style: TextStyle(color: Color(0xFF34D399), fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteVideo(
      BuildContext context, WidgetRef ref, AdminVideoDoc doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Delete video?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'This will permanently remove "${doc.fileName}" and all its annotations.',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF64748B))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: Color(0xFFF87171),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref
        .read(firestoreSourceProvider)
        .deleteVideoAnnotationsDoc(doc.fileName);
  }
}
