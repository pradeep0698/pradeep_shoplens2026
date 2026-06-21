import 'package:flutter/material.dart';
import '../../data/models/user_profile.dart';

class ProfileForm extends StatefulWidget {
  const ProfileForm({
    super.key,
    required this.profile,
    required this.onSave,
    this.isSaving = false,
  });

  final UserProfile    profile;
  final Future<void> Function(UserProfile) onSave;
  final bool           isSaving;

  @override
  State<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<ProfileForm> {
  late TextEditingController _username;
  late TextEditingController _dob;
  late TextEditingController _photoUrl;
  late TextEditingController _gender;
  late TextEditingController _ignoreTerms;
  late TextEditingController _preferenceTerms;
  late Set<String> _selectedCategories;
  String? _country;
  late int _maxSearchesPerRun;

  String? _localError;

  static const _genderOptions = ['Woman', 'Man', 'Non-binary', 'Prefer not to say'];

  static const _countries = {
    'United States': 'us', 'United Kingdom': 'gb', 'Canada': 'ca',
    'Australia': 'au', 'Germany': 'de', 'France': 'fr', 'India': 'in',
    'Japan': 'jp', 'Brazil': 'br', 'Mexico': 'mx', 'Spain': 'es',
    'Italy': 'it', 'Netherlands': 'nl', 'Sweden': 'se', 'Singapore': 'sg',
    'South Korea': 'kr', 'UAE': 'ae', 'South Africa': 'za',
    'New Zealand': 'nz', 'Ireland': 'ie',
  };
  static const _categoryOptions = [
    'Furniture',
    'Clothing',
    'Kitchen & Cookware',
    'Accessories',
    'Electronics',
    'Home Decor',
    'Sports & Outdoors',
    'Books & Stationery',
  ];

  @override
  void initState() {
    super.initState();
    _initControllers(widget.profile);
  }

  @override
  void didUpdateWidget(ProfileForm old) {
    super.didUpdateWidget(old);
    if (old.profile != widget.profile) _initControllers(widget.profile);
  }

  void _initControllers(UserProfile p) {
    _username        = TextEditingController(text: p.username);
    _dob             = TextEditingController(text: p.dob);
    _photoUrl        = TextEditingController(text: p.profilePhotoUrl);
    _gender          = TextEditingController(text: p.gender);
    _ignoreTerms     = TextEditingController(text: p.ignoreTerms.join(', '));
    _preferenceTerms = TextEditingController(text: p.preferenceTerms.join(', '));
    _selectedCategories = Set<String>.from(p.shoppingCategories);
    _country = p.country.isEmpty ? null : p.country;
    _maxSearchesPerRun = clampMaxSearchesPerRun(p.maxSearchesPerRun);
  }

  @override
  void dispose() {
    for (final c in [_username, _dob, _photoUrl, _gender, _ignoreTerms, _preferenceTerms]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _splitTerms(String raw) =>
      raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  Future<void> _submit() async {
    setState(() => _localError = null);
    if (_username.text.trim().isEmpty) {
      setState(() => _localError = 'Username is required.');
      return;
    }
    if (_dob.text.trim().isEmpty) {
      setState(() => _localError = 'Date of birth is required.');
      return;
    }

    await widget.onSave(UserProfile(
      username:           _username.text.trim(),
      dob:                _dob.text.trim(),
      profilePhotoUrl:    _photoUrl.text.trim(),
      gender:             _gender.text.trim(),
      country:            _country ?? '',
      shoppingCategories: _selectedCategories.toList(),
      ignoreTerms:        _splitTerms(_ignoreTerms.text),
      preferenceTerms:    _splitTerms(_preferenceTerms.text),
      maxSearchesPerRun:  _maxSearchesPerRun,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field('Username', _username, hint: 'Ava Chen'),
          _field('Date of birth (YYYY-MM-DD)', _dob, hint: '1990-01-01'),
          _field('Photo URL', _photoUrl, hint: 'https://example.com/avatar.jpg'),
          _dropdown('Gender', _gender, _genderOptions),
          _countryDropdown(),
          _categorySection(),
          _textArea('Ignore terms', _ignoreTerms, hint: 'item1, item2', hint2: 'Hidden from analysis and matching'),
          _textArea('Preference terms', _preferenceTerms, hint: 'item1, item2', hint2: 'These matches float to the top'),
          _maxSearchesSection(),
          if (_localError != null)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF450A0A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF991B1B)),
              ),
              child: Text(_localError!, style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13)),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: widget.isSaving ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF34D399),
                disabledBackgroundColor: const Color(0xFF334155),
                foregroundColor: const Color(0xFF0F172A),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              child: Text(
                widget.isSaving ? 'Saving...' : 'Save profile',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _categorySection() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shopping preferences',
              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              'Select the categories you shop for',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _categoryOptions.map((cat) {
                final selected = _selectedCategories.contains(cat);
                return GestureDetector(
                  onTap: () => setState(() {
                    if (selected) {
                      _selectedCategories.remove(cat);
                    } else {
                      _selectedCategories.add(cat);
                    }
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF34D399).withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected ? const Color(0xFF34D399) : Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Text(
                      cat,
                      style: TextStyle(
                        color: selected ? const Color(0xFF34D399) : const Color(0xFFCBD5E1),
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );

  Widget _maxSearchesSection() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Search results per scan',
              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              'How many product searches to run per scan (1-5). Lower is faster, higher finds more.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(maxSearchesPerRunCeiling, (i) => i + 1).map((n) {
                final selected = n == _maxSearchesPerRun;
                return GestureDetector(
                  onTap: () => setState(() => _maxSearchesPerRun = n),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF34D399).withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? const Color(0xFF34D399) : Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Text(
                      '$n',
                      style: TextStyle(
                        color: selected ? const Color(0xFF34D399) : const Color(0xFFCBD5E1),
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );

  Widget _field(String label, TextEditingController ctrl, {String hint = ''}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
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
        ),
      );

  Widget _dropdown(String label, TextEditingController ctrl, List<String> options) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: options.contains(ctrl.text) ? ctrl.text : null,
              hint: Text(ctrl.text.isNotEmpty ? ctrl.text : 'Select...', style: const TextStyle(color: Color(0xFF64748B))),
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
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
              items: options
                  .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  ctrl.text = v;
                  setState(() {});
                }
              },
            ),
          ],
        ),
      );

  Widget _countryDropdown() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Country', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              key: ValueKey(_country),
              initialValue: _country,
              hint: const Text('Select...', style: TextStyle(color: Color(0xFF64748B))),
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF6EE7B7))),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              items: _countries.entries
                  .map((e) => DropdownMenuItem(value: e.value, child: Text(e.key)))
                  .toList(),
              onChanged: (v) => setState(() => _country = v),
            ),
          ],
        ),
      );

  Widget _textArea(String label, TextEditingController ctrl, {String hint = '', String hint2 = ''}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            TextField(
              controller: ctrl,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 14),
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
            if (hint2.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(hint2, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
            ],
          ],
        ),
      );
}
