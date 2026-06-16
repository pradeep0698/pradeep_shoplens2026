// Must match frontend/src/app/page.tsx → `shoplens-user-${user.uid}`
// If this drifts, Flutter and web write to different Firestore documents and sync silently breaks.
String getSessionId(String uid) => 'shoplens-user-$uid';
