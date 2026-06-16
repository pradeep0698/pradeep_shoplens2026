import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/models/user_profile.dart';
import '../../data/repositories/profile_repository.dart';
import '../providers/auth_provider.dart';
import '../providers/profile_provider.dart';
import '../widgets/profile_form.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool   _isSaving = false;
  String _saveError = '';

  Future<void> _save(UserProfile profile) async {
    final user = ref.read(authStateProvider).value;
    if (user == null) return;

    setState(() { _isSaving = true; _saveError = ''; });

    try {
      await ref.read(profileRepositoryProvider).save(user.uid, profile);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile saved'),
            backgroundColor: Color(0xFF166534),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _saveError = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);
    final user         = ref.watch(authStateProvider).value;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF94A3B8), size: 18),
          onPressed: () => context.pop(),
        ),
        title: const Text(
          'Profile',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.read(authNotifierProvider.notifier).signOut();
              if (context.mounted) context.go('/login');
            },
            child: const Text('Sign out', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
          ),
        ],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF34D399))),
        error: (e, _) => Center(
          child: Text('Error: $e', style: const TextStyle(color: Color(0xFFF87171))),
        ),
        data: (profile) => Column(
          children: [
            if (user != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: const Color(0xFF0F172A),
                child: Text(
                  user.email ?? '',
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                ),
              ),
            if (_saveError.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF450A0A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF991B1B)),
                ),
                child: Text(_saveError, style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13)),
              ),
            Expanded(
              child: ProfileForm(
                profile:  profile,
                onSave:   _save,
                isSaving: _isSaving,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
