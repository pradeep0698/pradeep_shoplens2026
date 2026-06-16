import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/user_profile.dart';
import '../../models/product.dart';
import '../../../core/constants/firestore_constants.dart';

// Firestore can return nested arrays as LinkedMap in some SDK versions.
// Using `is List` avoids a runtime TypeError from an unsafe `as List` cast.
List<dynamic> _asList(dynamic value) => value is List ? value : const [];

class FirestoreSource {
  final _db = FirebaseFirestore.instance;

  // Watches existing UserProfiles/{uid} document
  Stream<UserProfile> watchProfile(String uid) =>
      _db
          .collection(FirestoreConstants.userProfiles)
          .doc(uid)
          .snapshots()
          .map((snap) => snap.exists
              ? UserProfile.fromFirestore(snap.data()!)
              : const UserProfile());

  Future<void> saveProfile(String uid, UserProfile profile) =>
      _db
          .collection(FirestoreConstants.userProfiles)
          .doc(uid)
          .set(UserProfile.toFirestore(profile), SetOptions(merge: true));

  // Clears the shopping list directly in Firestore (bypasses State Manager API)
  Future<void> clearShoppingList(String sessionId) =>
      _db
          .collection(FirestoreConstants.shoppingSessions)
          .doc(sessionId)
          .set({
            'products':     [],
            'last_updated': FieldValue.serverTimestamp(),
          });

  // Watches existing LiveShoppingSessions/{sessionId} document
  // sessionId must be "shoplens-user-{uid}" — must match State Manager exactly
  Stream<List<Product>> watchShoppingList(String sessionId) =>
      _db
          .collection(FirestoreConstants.shoppingSessions)
          .doc(sessionId)
          .snapshots()
          .map((snap) {
            if (!snap.exists) return <Product>[];
            return _asList(snap.data()!['products'])
                .map((e) => Product.fromFirestore(e as Map<String, dynamic>))
                .toList();
          });

  // Loads cached product list for a video file from VideoAnalysisCache/{fileName}
  Future<List<Product>?> loadVideoCache(String fileName) async {
    final doc = await _db
        .collection(FirestoreConstants.videoAnalysisCache)
        .doc(fileName)
        .get();
    if (!doc.exists) return null;
    final list = _asList(doc.data()?['products']);
    if (list.isEmpty) return null;
    return list
        .map((e) => Product.fromFirestore(e as Map<String, dynamic>))
        .toList();
  }

  // Saves product list permanently under VideoAnalysisCache/{fileName}
  Future<void> saveVideoCache(String fileName, List<Product> products) =>
      _db
          .collection(FirestoreConstants.videoAnalysisCache)
          .doc(fileName)
          .set({
            'fileName':   fileName,
            'products':   products.map(Product.toFirestore).toList(),
            'analyzedAt': FieldValue.serverTimestamp(),
          });

  List<VideoAnnotation> _parseAnnotations(Map<String, dynamic>? data) {
    return _asList(data?['annotations']).map((e) {
      final map      = e as Map<String, dynamic>;
      final products = _asList(map['products'])
          .map((p) => Product.fromFirestore(p as Map<String, dynamic>))
          .toList();
      return VideoAnnotation(
        timestamp: (map['timestamp'] as num?)?.toDouble() ?? 0.0,
        products:  products,
      );
    }).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  // Loads admin-annotated timestamp->products list from VideoAnnotations/{fileName}
  // Returns empty list if no annotation doc exists.
  Future<List<VideoAnnotation>> getVideoAnnotations(String fileName) async {
    final doc = await _db
        .collection(FirestoreConstants.videoAnnotations)
        .doc(fileName)
        .get();
    if (!doc.exists) return [];
    return _parseAnnotations(doc.data());
  }

  // Looks up an annotation doc by content fingerprint instead of filename —
  // needed because image_picker assigns a fresh filename to the same physical
  // video on every pick on iOS, so the filename-keyed lookup above always
  // misses there. The fingerprint stays stable across picks (see videoFingerprint).
  Future<List<VideoAnnotation>> getVideoAnnotationsByFingerprint(
      String fingerprint) async {
    final snap = await _db
        .collection(FirestoreConstants.videoAnnotations)
        .where('fingerprint', isEqualTo: fingerprint)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return [];
    return _parseAnnotations(snap.docs.first.data());
  }

  // Admin: checks if a user has role == 'admin' in their UserProfile
  Future<bool> isUserAdmin(String uid) async {
    final doc = await _db
        .collection(FirestoreConstants.userProfiles)
        .doc(uid)
        .get();
    if (!doc.exists) return false;
    return (doc.data()?['role'] as String? ?? 'user') == 'admin';
  }

  // Admin: streams all VideoAnnotations documents for the admin list screen
  Stream<List<AdminVideoDoc>> watchAllVideoAnnotations() =>
      _db.collection(FirestoreConstants.videoAnnotations).snapshots().map(
        (snap) => snap.docs.map((doc) {
          final data = doc.data();
          return AdminVideoDoc(
            fileName:        doc.id,
            fingerprint:     data['fingerprint'] as String? ?? '',
            status:          data['status'] as String? ?? 'pending',
            annotationCount: _asList(data['annotations']).length,
          );
        }).toList()
          ..sort((a, b) => a.fileName.compareTo(b.fileName)),
      );

  // Admin: creates or merges an initial VideoAnnotations doc (safe to call repeatedly).
  // Does NOT touch the annotations field so existing annotations are never overwritten.
  Future<void> initVideoAnnotationsDoc(
    String fileName,
    String uid, {
    required String fingerprint,
  }) =>
      _db.collection(FirestoreConstants.videoAnnotations).doc(fileName).set({
        'fileName':    fileName,
        'fingerprint': fingerprint,
        'status':      'pending',
        'uploadedAt':  FieldValue.serverTimestamp(),
        'uploadedBy':  uid,
      }, SetOptions(merge: true));

  // Admin: appends new annotations using arrayUnion so existing ones are preserved
  Future<void> appendVideoAnnotations(
      String fileName, List<VideoAnnotation> newAnnotations) async {
    final maps = newAnnotations
        .map((a) => {
              'timestamp': a.timestamp,
              'products':  a.products.map(Product.toFirestore).toList(),
            })
        .toList();
    await _db.collection(FirestoreConstants.videoAnnotations).doc(fileName).set(
      {
        'annotations': FieldValue.arrayUnion(maps),
        'status':      'ready',
      },
      SetOptions(merge: true),
    );
  }

  // Admin: deletes an entire VideoAnnotations document
  Future<void> deleteVideoAnnotationsDoc(String fileName) =>
      _db.collection(FirestoreConstants.videoAnnotations).doc(fileName).delete();

  // Admin: replaces the entire annotations array — use this when saving the
  // complete current state (avoids arrayUnion deduplication issues with nested maps).
  Future<void> saveVideoAnnotations(
      String fileName, List<VideoAnnotation> annotations) async {
    final maps = annotations
        .map((a) => {
              'timestamp': a.timestamp,
              'products':  a.products.map(Product.toFirestore).toList(),
            })
        .toList();
    await _db
        .collection(FirestoreConstants.videoAnnotations)
        .doc(fileName)
        .set({'annotations': maps, 'status': 'ready'}, SetOptions(merge: true));
  }
}

class VideoAnnotation {
  const VideoAnnotation({required this.timestamp, required this.products});
  final double        timestamp;
  final List<Product> products;
}

class AdminVideoDoc {
  const AdminVideoDoc({
    required this.fileName,
    required this.fingerprint,
    required this.status,
    required this.annotationCount,
  });
  final String fileName;
  final String fingerprint;
  final String status;
  final int    annotationCount;
}

final firestoreSourceProvider = Provider((_) => FirestoreSource());
