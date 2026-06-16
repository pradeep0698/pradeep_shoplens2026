import '../../data/models/user_profile.dart';

class ValidateProfileUseCase {
  String? validate(UserProfile profile) {
    if (profile.username.trim().isEmpty) return 'Username is required.';
    if (profile.dob.trim().isEmpty) return 'Date of birth is required.';
    return null;
  }
}
