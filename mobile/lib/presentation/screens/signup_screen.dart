import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants/firestore_constants.dart';
import '../../data/models/user_profile.dart';
import '../providers/auth_provider.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _username        = TextEditingController();
  final _email           = TextEditingController();
  final _password        = TextEditingController();
  final _confirmPassword = TextEditingController();
  String _localError = '';

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _localError = '');

    if (_username.text.trim().isEmpty || _email.text.trim().isEmpty ||
        _password.text.isEmpty || _confirmPassword.text.isEmpty) {
      setState(() => _localError = 'Fill in all fields.');
      return;
    }
    if (_password.text.length < 6) {
      setState(() => _localError = 'Password must be at least 6 characters.');
      return;
    }
    if (_password.text != _confirmPassword.text) {
      setState(() => _localError = 'Passwords do not match.');
      return;
    }

    await ref.read(authNotifierProvider.notifier).signUp(
      _email.text.trim(),
      _password.text,
    );

    if (!mounted) return;

    final authState = ref.read(authNotifierProvider);
    if (authState.hasError) {
      setState(() => _localError = 'Sign-up failed. Check your details.');
      return;
    }

    // Write initial username to Firestore UserProfiles after signup
    final user = ref.read(authStateProvider).value;
    if (user != null) {
      await FirebaseFirestore.instance
          .collection(FirestoreConstants.userProfiles)
          .doc(user.uid)
          .set(
            UserProfile.toFirestore(UserProfile(username: _username.text.trim())),
            SetOptions(merge: true),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authNotifierProvider).isLoading;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/shoplens-logo-nobckg.png', height: 120),
                const SizedBox(height: 12),
                const Text(
                  'Create your account',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                ),
                const SizedBox(height: 28),
                _inputField('Username', _username, hint: 'Ava Chen'),
                const SizedBox(height: 14),
                _inputField('Email', _email, hint: 'user@shoplens.com'),
                const SizedBox(height: 14),
                _inputField('Password', _password, obscure: true, hint: 'At least 6 characters'),
                const SizedBox(height: 14),
                _inputField('Confirm password', _confirmPassword, obscure: true, hint: 'Re-enter password'),
                if (_localError.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF450A0A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF991B1B)),
                    ),
                    child: Text(_localError, style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13)),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF34D399),
                      disabledBackgroundColor: const Color(0xFF334155),
                      foregroundColor: const Color(0xFF0F172A),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                    child: Text(
                      isLoading ? 'Creating account...' : 'Create account',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Flexible(
                      child: Text(
                        'Already have an account? ',
                        style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => context.go('/login'),
                      child: const Text(
                        'Sign in',
                        style: TextStyle(
                          color: Color(0xFF6EE7B7),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputField(String label, TextEditingController ctrl, {bool obscure = false, String hint = ''}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          TextField(
            controller:  ctrl,
            obscureText: obscure,
            style:       const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: Color(0xFF64748B)),
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF6EE7B7)),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ],
      );
}
