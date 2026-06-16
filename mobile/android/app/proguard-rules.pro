# firebase-iid is excluded from the build (absorbed into firebase-messaging),
# but google_mlkit_linkfirebase still holds a reference to FirebaseInstanceId.
# Tell R8 to ignore the missing class rather than failing the release build.
-dontwarn com.google.firebase.iid.FirebaseInstanceId

# video_player uses ExoPlayer 3 (AndroidX media3) — keep native bridge classes
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**
