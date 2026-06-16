// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'pipeline_provider.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$PipelineState {
  PipelineStatus get status => throw _privateConstructorUsedError;
  String? get errorMessage => throw _privateConstructorUsedError;
  AnalyzerErrorCode? get errorCode => throw _privateConstructorUsedError;
  bool get isRetryable => throw _privateConstructorUsedError;
  List<String> get warnings => throw _privateConstructorUsedError;
  Uint8List? get imageBytes => throw _privateConstructorUsedError;

  /// Create a copy of PipelineState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $PipelineStateCopyWith<PipelineState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $PipelineStateCopyWith<$Res> {
  factory $PipelineStateCopyWith(
          PipelineState value, $Res Function(PipelineState) then) =
      _$PipelineStateCopyWithImpl<$Res, PipelineState>;
  @useResult
  $Res call(
      {PipelineStatus status,
      String? errorMessage,
      AnalyzerErrorCode? errorCode,
      bool isRetryable,
      List<String> warnings,
      Uint8List? imageBytes});
}

/// @nodoc
class _$PipelineStateCopyWithImpl<$Res, $Val extends PipelineState>
    implements $PipelineStateCopyWith<$Res> {
  _$PipelineStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of PipelineState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? errorMessage = freezed,
    Object? errorCode = freezed,
    Object? isRetryable = null,
    Object? warnings = null,
    Object? imageBytes = freezed,
  }) {
    return _then(_value.copyWith(
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as PipelineStatus,
      errorMessage: freezed == errorMessage
          ? _value.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      errorCode: freezed == errorCode
          ? _value.errorCode
          : errorCode // ignore: cast_nullable_to_non_nullable
              as AnalyzerErrorCode?,
      isRetryable: null == isRetryable
          ? _value.isRetryable
          : isRetryable // ignore: cast_nullable_to_non_nullable
              as bool,
      warnings: null == warnings
          ? _value.warnings
          : warnings // ignore: cast_nullable_to_non_nullable
              as List<String>,
      imageBytes: freezed == imageBytes
          ? _value.imageBytes
          : imageBytes // ignore: cast_nullable_to_non_nullable
              as Uint8List?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$PipelineStateImplCopyWith<$Res>
    implements $PipelineStateCopyWith<$Res> {
  factory _$$PipelineStateImplCopyWith(
          _$PipelineStateImpl value, $Res Function(_$PipelineStateImpl) then) =
      __$$PipelineStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {PipelineStatus status,
      String? errorMessage,
      AnalyzerErrorCode? errorCode,
      bool isRetryable,
      List<String> warnings,
      Uint8List? imageBytes});
}

/// @nodoc
class __$$PipelineStateImplCopyWithImpl<$Res>
    extends _$PipelineStateCopyWithImpl<$Res, _$PipelineStateImpl>
    implements _$$PipelineStateImplCopyWith<$Res> {
  __$$PipelineStateImplCopyWithImpl(
      _$PipelineStateImpl _value, $Res Function(_$PipelineStateImpl) _then)
      : super(_value, _then);

  /// Create a copy of PipelineState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? errorMessage = freezed,
    Object? errorCode = freezed,
    Object? isRetryable = null,
    Object? warnings = null,
    Object? imageBytes = freezed,
  }) {
    return _then(_$PipelineStateImpl(
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as PipelineStatus,
      errorMessage: freezed == errorMessage
          ? _value.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      errorCode: freezed == errorCode
          ? _value.errorCode
          : errorCode // ignore: cast_nullable_to_non_nullable
              as AnalyzerErrorCode?,
      isRetryable: null == isRetryable
          ? _value.isRetryable
          : isRetryable // ignore: cast_nullable_to_non_nullable
              as bool,
      warnings: null == warnings
          ? _value._warnings
          : warnings // ignore: cast_nullable_to_non_nullable
              as List<String>,
      imageBytes: freezed == imageBytes
          ? _value.imageBytes
          : imageBytes // ignore: cast_nullable_to_non_nullable
              as Uint8List?,
    ));
  }
}

/// @nodoc

class _$PipelineStateImpl implements _PipelineState {
  const _$PipelineStateImpl(
      {this.status = PipelineStatus.idle,
      this.errorMessage,
      this.errorCode,
      this.isRetryable = false,
      final List<String> warnings = const [],
      this.imageBytes})
      : _warnings = warnings;

  @override
  @JsonKey()
  final PipelineStatus status;
  @override
  final String? errorMessage;
  @override
  final AnalyzerErrorCode? errorCode;
  @override
  @JsonKey()
  final bool isRetryable;
  final List<String> _warnings;
  @override
  @JsonKey()
  List<String> get warnings {
    if (_warnings is EqualUnmodifiableListView) return _warnings;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_warnings);
  }

  @override
  final Uint8List? imageBytes;

  @override
  String toString() {
    return 'PipelineState(status: $status, errorMessage: $errorMessage, errorCode: $errorCode, isRetryable: $isRetryable, warnings: $warnings, imageBytes: $imageBytes)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$PipelineStateImpl &&
            (identical(other.status, status) || other.status == status) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage) &&
            (identical(other.errorCode, errorCode) ||
                other.errorCode == errorCode) &&
            (identical(other.isRetryable, isRetryable) ||
                other.isRetryable == isRetryable) &&
            const DeepCollectionEquality().equals(other._warnings, _warnings) &&
            const DeepCollectionEquality()
                .equals(other.imageBytes, imageBytes));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      status,
      errorMessage,
      errorCode,
      isRetryable,
      const DeepCollectionEquality().hash(_warnings),
      const DeepCollectionEquality().hash(imageBytes));

  /// Create a copy of PipelineState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$PipelineStateImplCopyWith<_$PipelineStateImpl> get copyWith =>
      __$$PipelineStateImplCopyWithImpl<_$PipelineStateImpl>(this, _$identity);
}

abstract class _PipelineState implements PipelineState {
  const factory _PipelineState(
      {final PipelineStatus status,
      final String? errorMessage,
      final AnalyzerErrorCode? errorCode,
      final bool isRetryable,
      final List<String> warnings,
      final Uint8List? imageBytes}) = _$PipelineStateImpl;

  @override
  PipelineStatus get status;
  @override
  String? get errorMessage;
  @override
  AnalyzerErrorCode? get errorCode;
  @override
  bool get isRetryable;
  @override
  List<String> get warnings;
  @override
  Uint8List? get imageBytes;

  /// Create a copy of PipelineState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$PipelineStateImplCopyWith<_$PipelineStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
