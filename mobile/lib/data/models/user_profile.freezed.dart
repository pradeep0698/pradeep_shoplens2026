// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'user_profile.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$CategoryTerms {
  List<String> get include => throw _privateConstructorUsedError;
  List<String> get exclude => throw _privateConstructorUsedError;

  /// Create a copy of CategoryTerms
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $CategoryTermsCopyWith<CategoryTerms> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $CategoryTermsCopyWith<$Res> {
  factory $CategoryTermsCopyWith(
          CategoryTerms value, $Res Function(CategoryTerms) then) =
      _$CategoryTermsCopyWithImpl<$Res, CategoryTerms>;
  @useResult
  $Res call({List<String> include, List<String> exclude});
}

/// @nodoc
class _$CategoryTermsCopyWithImpl<$Res, $Val extends CategoryTerms>
    implements $CategoryTermsCopyWith<$Res> {
  _$CategoryTermsCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of CategoryTerms
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? include = null,
    Object? exclude = null,
  }) {
    return _then(_value.copyWith(
      include: null == include
          ? _value.include
          : include // ignore: cast_nullable_to_non_nullable
              as List<String>,
      exclude: null == exclude
          ? _value.exclude
          : exclude // ignore: cast_nullable_to_non_nullable
              as List<String>,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$CategoryTermsImplCopyWith<$Res>
    implements $CategoryTermsCopyWith<$Res> {
  factory _$$CategoryTermsImplCopyWith(
          _$CategoryTermsImpl value, $Res Function(_$CategoryTermsImpl) then) =
      __$$CategoryTermsImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<String> include, List<String> exclude});
}

/// @nodoc
class __$$CategoryTermsImplCopyWithImpl<$Res>
    extends _$CategoryTermsCopyWithImpl<$Res, _$CategoryTermsImpl>
    implements _$$CategoryTermsImplCopyWith<$Res> {
  __$$CategoryTermsImplCopyWithImpl(
      _$CategoryTermsImpl _value, $Res Function(_$CategoryTermsImpl) _then)
      : super(_value, _then);

  /// Create a copy of CategoryTerms
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? include = null,
    Object? exclude = null,
  }) {
    return _then(_$CategoryTermsImpl(
      include: null == include
          ? _value._include
          : include // ignore: cast_nullable_to_non_nullable
              as List<String>,
      exclude: null == exclude
          ? _value._exclude
          : exclude // ignore: cast_nullable_to_non_nullable
              as List<String>,
    ));
  }
}

/// @nodoc

class _$CategoryTermsImpl implements _CategoryTerms {
  const _$CategoryTermsImpl(
      {final List<String> include = const [],
      final List<String> exclude = const []})
      : _include = include,
        _exclude = exclude;

  final List<String> _include;
  @override
  @JsonKey()
  List<String> get include {
    if (_include is EqualUnmodifiableListView) return _include;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_include);
  }

  final List<String> _exclude;
  @override
  @JsonKey()
  List<String> get exclude {
    if (_exclude is EqualUnmodifiableListView) return _exclude;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_exclude);
  }

  @override
  String toString() {
    return 'CategoryTerms(include: $include, exclude: $exclude)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$CategoryTermsImpl &&
            const DeepCollectionEquality().equals(other._include, _include) &&
            const DeepCollectionEquality().equals(other._exclude, _exclude));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_include),
      const DeepCollectionEquality().hash(_exclude));

  /// Create a copy of CategoryTerms
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$CategoryTermsImplCopyWith<_$CategoryTermsImpl> get copyWith =>
      __$$CategoryTermsImplCopyWithImpl<_$CategoryTermsImpl>(this, _$identity);
}

abstract class _CategoryTerms implements CategoryTerms {
  const factory _CategoryTerms(
      {final List<String> include,
      final List<String> exclude}) = _$CategoryTermsImpl;

  @override
  List<String> get include;
  @override
  List<String> get exclude;

  /// Create a copy of CategoryTerms
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$CategoryTermsImplCopyWith<_$CategoryTermsImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$UserProfile {
  String get username => throw _privateConstructorUsedError;
  String get dob => throw _privateConstructorUsedError;
  String get profilePhotoUrl => throw _privateConstructorUsedError;
  String get gender => throw _privateConstructorUsedError;
  String get country => throw _privateConstructorUsedError;
  List<String> get shoppingCategories => throw _privateConstructorUsedError;
  Map<String, CategoryTerms> get preferencesByCategory =>
      throw _privateConstructorUsedError;
  int get maxSearchesPerRun => throw _privateConstructorUsedError;
  bool get voiceOnboardingSeen => throw _privateConstructorUsedError;
  String get voiceLanguage => throw _privateConstructorUsedError;

  /// Create a copy of UserProfile
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $UserProfileCopyWith<UserProfile> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $UserProfileCopyWith<$Res> {
  factory $UserProfileCopyWith(
          UserProfile value, $Res Function(UserProfile) then) =
      _$UserProfileCopyWithImpl<$Res, UserProfile>;
  @useResult
  $Res call(
      {String username,
      String dob,
      String profilePhotoUrl,
      String gender,
      String country,
      List<String> shoppingCategories,
      Map<String, CategoryTerms> preferencesByCategory,
      int maxSearchesPerRun,
      bool voiceOnboardingSeen,
      String voiceLanguage});
}

/// @nodoc
class _$UserProfileCopyWithImpl<$Res, $Val extends UserProfile>
    implements $UserProfileCopyWith<$Res> {
  _$UserProfileCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of UserProfile
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? username = null,
    Object? dob = null,
    Object? profilePhotoUrl = null,
    Object? gender = null,
    Object? country = null,
    Object? shoppingCategories = null,
    Object? preferencesByCategory = null,
    Object? maxSearchesPerRun = null,
    Object? voiceOnboardingSeen = null,
    Object? voiceLanguage = null,
  }) {
    return _then(_value.copyWith(
      username: null == username
          ? _value.username
          : username // ignore: cast_nullable_to_non_nullable
              as String,
      dob: null == dob
          ? _value.dob
          : dob // ignore: cast_nullable_to_non_nullable
              as String,
      profilePhotoUrl: null == profilePhotoUrl
          ? _value.profilePhotoUrl
          : profilePhotoUrl // ignore: cast_nullable_to_non_nullable
              as String,
      gender: null == gender
          ? _value.gender
          : gender // ignore: cast_nullable_to_non_nullable
              as String,
      country: null == country
          ? _value.country
          : country // ignore: cast_nullable_to_non_nullable
              as String,
      shoppingCategories: null == shoppingCategories
          ? _value.shoppingCategories
          : shoppingCategories // ignore: cast_nullable_to_non_nullable
              as List<String>,
      preferencesByCategory: null == preferencesByCategory
          ? _value.preferencesByCategory
          : preferencesByCategory // ignore: cast_nullable_to_non_nullable
              as Map<String, CategoryTerms>,
      maxSearchesPerRun: null == maxSearchesPerRun
          ? _value.maxSearchesPerRun
          : maxSearchesPerRun // ignore: cast_nullable_to_non_nullable
              as int,
      voiceOnboardingSeen: null == voiceOnboardingSeen
          ? _value.voiceOnboardingSeen
          : voiceOnboardingSeen // ignore: cast_nullable_to_non_nullable
              as bool,
      voiceLanguage: null == voiceLanguage
          ? _value.voiceLanguage
          : voiceLanguage // ignore: cast_nullable_to_non_nullable
              as String,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$UserProfileImplCopyWith<$Res>
    implements $UserProfileCopyWith<$Res> {
  factory _$$UserProfileImplCopyWith(
          _$UserProfileImpl value, $Res Function(_$UserProfileImpl) then) =
      __$$UserProfileImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String username,
      String dob,
      String profilePhotoUrl,
      String gender,
      String country,
      List<String> shoppingCategories,
      Map<String, CategoryTerms> preferencesByCategory,
      int maxSearchesPerRun,
      bool voiceOnboardingSeen,
      String voiceLanguage});
}

/// @nodoc
class __$$UserProfileImplCopyWithImpl<$Res>
    extends _$UserProfileCopyWithImpl<$Res, _$UserProfileImpl>
    implements _$$UserProfileImplCopyWith<$Res> {
  __$$UserProfileImplCopyWithImpl(
      _$UserProfileImpl _value, $Res Function(_$UserProfileImpl) _then)
      : super(_value, _then);

  /// Create a copy of UserProfile
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? username = null,
    Object? dob = null,
    Object? profilePhotoUrl = null,
    Object? gender = null,
    Object? country = null,
    Object? shoppingCategories = null,
    Object? preferencesByCategory = null,
    Object? maxSearchesPerRun = null,
    Object? voiceOnboardingSeen = null,
    Object? voiceLanguage = null,
  }) {
    return _then(_$UserProfileImpl(
      username: null == username
          ? _value.username
          : username // ignore: cast_nullable_to_non_nullable
              as String,
      dob: null == dob
          ? _value.dob
          : dob // ignore: cast_nullable_to_non_nullable
              as String,
      profilePhotoUrl: null == profilePhotoUrl
          ? _value.profilePhotoUrl
          : profilePhotoUrl // ignore: cast_nullable_to_non_nullable
              as String,
      gender: null == gender
          ? _value.gender
          : gender // ignore: cast_nullable_to_non_nullable
              as String,
      country: null == country
          ? _value.country
          : country // ignore: cast_nullable_to_non_nullable
              as String,
      shoppingCategories: null == shoppingCategories
          ? _value._shoppingCategories
          : shoppingCategories // ignore: cast_nullable_to_non_nullable
              as List<String>,
      preferencesByCategory: null == preferencesByCategory
          ? _value._preferencesByCategory
          : preferencesByCategory // ignore: cast_nullable_to_non_nullable
              as Map<String, CategoryTerms>,
      maxSearchesPerRun: null == maxSearchesPerRun
          ? _value.maxSearchesPerRun
          : maxSearchesPerRun // ignore: cast_nullable_to_non_nullable
              as int,
      voiceOnboardingSeen: null == voiceOnboardingSeen
          ? _value.voiceOnboardingSeen
          : voiceOnboardingSeen // ignore: cast_nullable_to_non_nullable
              as bool,
      voiceLanguage: null == voiceLanguage
          ? _value.voiceLanguage
          : voiceLanguage // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$UserProfileImpl extends _UserProfile {
  const _$UserProfileImpl(
      {this.username = '',
      this.dob = '',
      this.profilePhotoUrl = '',
      this.gender = '',
      this.country = '',
      final List<String> shoppingCategories = const [],
      final Map<String, CategoryTerms> preferencesByCategory = const {},
      this.maxSearchesPerRun = defaultMaxSearchesPerRun,
      this.voiceOnboardingSeen = false,
      this.voiceLanguage = 'English'})
      : _shoppingCategories = shoppingCategories,
        _preferencesByCategory = preferencesByCategory,
        super._();

  @override
  @JsonKey()
  final String username;
  @override
  @JsonKey()
  final String dob;
  @override
  @JsonKey()
  final String profilePhotoUrl;
  @override
  @JsonKey()
  final String gender;
  @override
  @JsonKey()
  final String country;
  final List<String> _shoppingCategories;
  @override
  @JsonKey()
  List<String> get shoppingCategories {
    if (_shoppingCategories is EqualUnmodifiableListView)
      return _shoppingCategories;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_shoppingCategories);
  }

  final Map<String, CategoryTerms> _preferencesByCategory;
  @override
  @JsonKey()
  Map<String, CategoryTerms> get preferencesByCategory {
    if (_preferencesByCategory is EqualUnmodifiableMapView)
      return _preferencesByCategory;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_preferencesByCategory);
  }

  @override
  @JsonKey()
  final int maxSearchesPerRun;
  @override
  @JsonKey()
  final bool voiceOnboardingSeen;
  @override
  @JsonKey()
  final String voiceLanguage;

  @override
  String toString() {
    return 'UserProfile(username: $username, dob: $dob, profilePhotoUrl: $profilePhotoUrl, gender: $gender, country: $country, shoppingCategories: $shoppingCategories, preferencesByCategory: $preferencesByCategory, maxSearchesPerRun: $maxSearchesPerRun, voiceOnboardingSeen: $voiceOnboardingSeen, voiceLanguage: $voiceLanguage)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$UserProfileImpl &&
            (identical(other.username, username) ||
                other.username == username) &&
            (identical(other.dob, dob) || other.dob == dob) &&
            (identical(other.profilePhotoUrl, profilePhotoUrl) ||
                other.profilePhotoUrl == profilePhotoUrl) &&
            (identical(other.gender, gender) || other.gender == gender) &&
            (identical(other.country, country) || other.country == country) &&
            const DeepCollectionEquality()
                .equals(other._shoppingCategories, _shoppingCategories) &&
            const DeepCollectionEquality()
                .equals(other._preferencesByCategory, _preferencesByCategory) &&
            (identical(other.maxSearchesPerRun, maxSearchesPerRun) ||
                other.maxSearchesPerRun == maxSearchesPerRun) &&
            (identical(other.voiceOnboardingSeen, voiceOnboardingSeen) ||
                other.voiceOnboardingSeen == voiceOnboardingSeen) &&
            (identical(other.voiceLanguage, voiceLanguage) ||
                other.voiceLanguage == voiceLanguage));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      username,
      dob,
      profilePhotoUrl,
      gender,
      country,
      const DeepCollectionEquality().hash(_shoppingCategories),
      const DeepCollectionEquality().hash(_preferencesByCategory),
      maxSearchesPerRun,
      voiceOnboardingSeen,
      voiceLanguage);

  /// Create a copy of UserProfile
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$UserProfileImplCopyWith<_$UserProfileImpl> get copyWith =>
      __$$UserProfileImplCopyWithImpl<_$UserProfileImpl>(this, _$identity);
}

abstract class _UserProfile extends UserProfile {
  const factory _UserProfile(
      {final String username,
      final String dob,
      final String profilePhotoUrl,
      final String gender,
      final String country,
      final List<String> shoppingCategories,
      final Map<String, CategoryTerms> preferencesByCategory,
      final int maxSearchesPerRun,
      final bool voiceOnboardingSeen,
      final String voiceLanguage}) = _$UserProfileImpl;
  const _UserProfile._() : super._();

  @override
  String get username;
  @override
  String get dob;
  @override
  String get profilePhotoUrl;
  @override
  String get gender;
  @override
  String get country;
  @override
  List<String> get shoppingCategories;
  @override
  Map<String, CategoryTerms> get preferencesByCategory;
  @override
  int get maxSearchesPerRun;
  @override
  bool get voiceOnboardingSeen;
  @override
  String get voiceLanguage;

  /// Create a copy of UserProfile
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$UserProfileImplCopyWith<_$UserProfileImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
