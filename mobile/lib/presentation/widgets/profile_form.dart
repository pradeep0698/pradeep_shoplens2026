import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/user_profile.dart';
import '../../data/repositories/profile_repository.dart';
import '../providers/auth_provider.dart';
import '../providers/profile_provider.dart';
import 'voice_assistant_overlay.dart';

class ProfileForm extends ConsumerStatefulWidget {
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
  ConsumerState<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<ProfileForm> {
  late TextEditingController _username;
  late TextEditingController _dob;
  late TextEditingController _photoUrl;
  late TextEditingController _gender;
  late Set<String> _selectedCategories;
  late Map<String, CategoryTerms> _preferencesByCategory;
  final Map<String, TextEditingController> _includeInputs = {};
  final Map<String, TextEditingController> _excludeInputs = {};
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
    _selectedCategories = Set<String>.from(p.shoppingCategories);
    _preferencesByCategory = Map<String, CategoryTerms>.from(p.preferencesByCategory);
    _country = p.country.isEmpty ? null : p.country;
    _maxSearchesPerRun = clampMaxSearchesPerRun(p.maxSearchesPerRun);
  }

  @override
  void dispose() {
    for (final c in [_username, _dob, _photoUrl, _gender]) {
      c.dispose();
    }
    for (final c in [..._includeInputs.values, ..._excludeInputs.values]) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _inputFor(String category, {required bool isInclude}) {
    final store = isInclude ? _includeInputs : _excludeInputs;
    return store.putIfAbsent(category, () => TextEditingController());
  }

  // Category chips control shopping_categories; toggling one off is an
  // explicit user removal, so it also drops that category's preference
  // bucket rather than leaving orphaned data behind.
  void _toggleCategory(String category) {
    setState(() {
      if (_selectedCategories.contains(category)) {
        _selectedCategories.remove(category);
        _preferencesByCategory.remove(category);
        _includeInputs.remove(category)?.dispose();
        _excludeInputs.remove(category)?.dispose();
      } else {
        _selectedCategories.add(category);
      }
    });
  }

  void _removeCategoryBucket(String category) {
    setState(() {
      _selectedCategories.remove(category);
      _preferencesByCategory.remove(category);
      _includeInputs.remove(category)?.dispose();
      _excludeInputs.remove(category)?.dispose();
    });
  }

  // Duplicate handling is silent: if the normalized term already exists in
  // that same list, do nothing — no user-facing warning.
  void _addTerm(String category, {required bool isInclude, required String raw}) {
    final value = raw.trim();
    if (value.isEmpty) return;
    final lower = value.toLowerCase();
    setState(() {
      final current = _preferencesByCategory[category] ?? const CategoryTerms();
      final list = isInclude ? current.include : current.exclude;
      if (list.any((t) => t.toLowerCase() == lower)) return;
      final updated = [...list, value];
      _preferencesByCategory[category] = isInclude
          ? current.copyWith(include: updated)
          : current.copyWith(exclude: updated);
    });
    _inputFor(category, isInclude: isInclude).clear();
  }

  void _removeTerm(String category, {required bool isInclude, required String term}) {
    setState(() {
      final current = _preferencesByCategory[category];
      if (current == null) return;
      _preferencesByCategory[category] = isInclude
          ? current.copyWith(include: current.include.where((t) => t != term).toList())
          : current.copyWith(exclude: current.exclude.where((t) => t != term).toList());
    });
  }

  // General (not category-specific) terms — legacy pre-category-scoping data
  // or voice-assistant terms recorded without a category. Not tied to a
  // shopping-category chip, so it's only shown when it already has content;
  // otherwise it round-trips untouched through save.
  bool get _hasGeneralBucket {
    final general = _preferencesByCategory[generalPreferenceBucket];
    return general != null && (general.include.isNotEmpty || general.exclude.isNotEmpty);
  }

  // Opens the same voice-onboarding flow the forced first-run trigger uses
  // (see main_screen.dart's _maybeShowOnboarding) so users can (re-)run it
  // any time from Profile settings, not just once on first run.
  Future<void> _openVoiceSetup() async {
    await showVoiceAssistantOverlay(context, isOnboarding: true);
    if (!mounted) return;
    final user = ref.read(authStateProvider).value;
    if (user == null) return;
    // Re-read the freshest profile from the provider rather than trusting
    // widget.profile — it's prop-drilled from ProfileScreen and not
    // guaranteed to have rebuilt yet at this point in the async gap.
    final latest = ref.read(profileProvider).valueOrNull ?? widget.profile;
    if (latest.voiceOnboardingSeen) return;
    await ref.read(profileRepositoryProvider).save(
          user.uid,
          latest.copyWith(voiceOnboardingSeen: true),
        );
  }

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
    final dobPattern = RegExp(r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$');
    if (!dobPattern.hasMatch(_dob.text.trim())) {
      setState(() => _localError = 'Please enter date of birth in YYYY-MM-DD format.');
      return;
    }
    final photoUrl = _photoUrl.text.trim();
    if (photoUrl.isNotEmpty) {
      final uri = Uri.tryParse(photoUrl);
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
        setState(() => _localError = 'Please enter a valid photo URL.');
        return;
      }
    }

    // Final normalize pass: trim/drop-blank/dedupe (already applied
    // incrementally by _addTerm) plus a stable sort for display.
    final normalized = <String, CategoryTerms>{
      for (final entry in _preferencesByCategory.entries)
        entry.key: CategoryTerms(
          include: dedupeTermsCaseInsensitive(entry.value.include)..sort(),
          exclude: dedupeTermsCaseInsensitive(entry.value.exclude)..sort(),
        ),
    };

    await widget.onSave(UserProfile(
      username:              _username.text.trim(),
      dob:                   _dob.text.trim(),
      profilePhotoUrl:       photoUrl,
      gender:                _gender.text.trim(),
      country:               _country ?? '',
      shoppingCategories:    _selectedCategories.toList(),
      preferencesByCategory: normalized,
      maxSearchesPerRun:     _maxSearchesPerRun,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _voiceSetupCard(),
          _field('Username', _username, hint: 'Ava Chen'),
          _field('Date of birth (YYYY-MM-DD)', _dob, hint: '1990-01-01'),
          _field('Photo URL', _photoUrl, hint: 'https://example.com/avatar.jpg'),
          _dropdown('Gender', _gender, _genderOptions),
          _countryDropdown(),
          _categoryPicker(),
          ..._selectedCategories.map(
            (cat) => _categoryPreferencesCard(cat, removable: true),
          ),
          if (_hasGeneralBucket)
            _categoryPreferencesCard(
              generalPreferenceBucket,
              removable: false,
              title: 'General preferences',
              subtitle: "Terms not tied to a specific category — e.g. from voice setup",
            ),
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

  Widget _voiceSetupCard() => Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF34D399).withValues(alpha: 0.3)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openVoiceSetup,
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF34D399).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.smart_toy_outlined, color: Color(0xFF34D399), size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Set up with voice',
                      style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                    SizedBox(height: 4),
                    Text(
                      "Tell the assistant your shopping style and we'll fill this in for you.",
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF64748B), size: 20),
            ],
          ),
        ),
      );

  Widget _categoryPicker() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shopping categories',
              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              'Select the categories you shop for, then add include/exclude terms below',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _categoryOptions.map((cat) {
                final selected = _selectedCategories.contains(cat);
                return GestureDetector(
                  onTap: () => _toggleCategory(cat),
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

  Widget _categoryPreferencesCard(
    String category, {
    required bool removable,
    String? title,
    String? subtitle,
  }) {
    final terms = _preferencesByCategory[category] ?? const CategoryTerms();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title ?? category,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              if (removable)
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xFF64748B), size: 18),
                  onPressed: () => _removeCategoryBucket(category),
                  tooltip: 'Remove category',
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
          ],
          const SizedBox(height: 12),
          _termListEditor(
            category: category,
            label: 'Include',
            hint2: 'These matches float to the top',
            terms: terms.include,
            isInclude: true,
            chipColor: const Color(0xFF34D399),
          ),
          const SizedBox(height: 12),
          _termListEditor(
            category: category,
            label: 'Exclude',
            hint2: 'Hidden from analysis and matching',
            terms: terms.exclude,
            isInclude: false,
            chipColor: const Color(0xFFF87171),
          ),
        ],
      ),
    );
  }

  Widget _termListEditor({
    required String category,
    required String label,
    required String hint2,
    required List<String> terms,
    required bool isInclude,
    required Color chipColor,
  }) {
    final input = _inputFor(category, isInclude: isInclude);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(hint2, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
        const SizedBox(height: 8),
        if (terms.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: terms.map((term) {
              return Chip(
                label: Text(term, style: const TextStyle(color: Colors.white, fontSize: 12)),
                backgroundColor: chipColor.withValues(alpha: 0.15),
                side: BorderSide(color: chipColor.withValues(alpha: 0.4)),
                deleteIcon: const Icon(Icons.close, size: 14, color: Color(0xFF94A3B8)),
                onDeleted: () => _removeTerm(category, isInclude: isInclude, term: term),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: input,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Add a term...',
                  hintStyle: const TextStyle(color: Color(0xFF64748B)),
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF6EE7B7)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onSubmitted: (raw) => _addTerm(category, isInclude: isInclude, raw: raw),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.add_circle, color: Color(0xFF34D399)),
              onPressed: () => _addTerm(category, isInclude: isInclude, raw: input.text),
              tooltip: 'Add term',
            ),
          ],
        ),
      ],
    );
  }

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
}
