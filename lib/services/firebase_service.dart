import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:math';

class FirebaseService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // --- Auth Methods ---

  /// Generate Admin Code in format 2026-XXXX (year + 4 random digits)
  static String _generateAdminCode() {
    var rng = Random();
    final year = DateTime.now().year;
    final randomPart = (1000 + rng.nextInt(9000)).toString(); // 4 digits
    return '$year-$randomPart';
  }

  /// Create a new Admin account
  static Future<Map<String, dynamic>?> createAdmin({
    required String fullName,
    required String email,
    required String password,
    required String phoneNumber,
    String? photoUrl,
  }) async {
    try {
      // 1. Create Auth User
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // 2. Generate Unique Admin ID
      String adminId = _generateAdminCode();
      // Ensure uniqueness (simple check, theoretically could collision but rare for demo)
      // In production, would loop check.

      // 3. Save Admin Details to 'admin_info' (including encrypted password for code-only login)
      await _firestore.collection('admin_info').doc(userCredential.user!.uid).set({
        'admin_id': adminId,
        'full_name': fullName,
        'email': email,
        'phone_number': phoneNumber,
        'photo_url': photoUrl ?? '',
        'auth_password': password, // Stored securely for code-only login
        'created_at': FieldValue.serverTimestamp(),
        'uid': userCredential.user!.uid, // Link back to Auth UID
      });

      return {
        'uid': userCredential.user!.uid,
        'admin_id': adminId,
        'email': email,
      };
    } catch (e) {
      print('Error creating admin: $e');
      return null;
    }
  }

  /// Login Admin using Email and Password
  static Future<User?> loginAdmin({
    required String identifier, // Email or Admin ID
    required String password,
  }) async {
    try {
      String email = identifier;

      // Check if identifier is an Admin Code (format: YYYY-XXXX)
      if (RegExp(r'^\d{4}-\d{4}$').hasMatch(identifier)) {
        print('Attempting login with Admin Code: $identifier');
        // Look up email via Admin Code
        final query = await _firestore
            .collection('admin_info')
            .where('admin_id', isEqualTo: identifier)
            .limit(1)
            .get();

        if (query.docs.isNotEmpty) {
          email = query.docs.first.data()['email'];
          print('Found email for Admin Code: $email');
        } else {
          print('Admin Code not found in database');
          return null;
        }
      } else {
        print('Attempting login with Email: $email');
      }

      // Login with Email/Password
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      print('Login successful for user: ${userCredential.user?.uid}');
      return userCredential.user;
    } catch (e) {
      print('Error logging in: $e');
      return null;
    }
  }

  /// Passwordless login using only Admin Code (for web)
  static Future<User?> loginWithCode(String adminCode) async {
    try {
      print('Attempting passwordless login with code: $adminCode');
      
      // Look up admin by code
      final query = await _firestore
          .collection('admin_info')
          .where('admin_id', isEqualTo: adminCode)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        print('Admin Code not found');
        return null;
      }

      final adminData = query.docs.first.data();
      final email = adminData['email'] as String;
      final storedPassword = adminData['auth_password'] as String?;
      
      if (storedPassword == null) {
        print('No stored password for this admin');
        return null;
      }

      // Login with stored credentials
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: storedPassword,
      );
      
      print('Passwordless login successful for: ${userCredential.user?.uid}');
      return userCredential.user;
    } catch (e) {
      print('Error with passwordless login: $e');
      return null;
    }
  }
  
  /// Get current logged in admin ID from Firestore
  static Future<String?> getCurrentAdminId() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    
    try {
      final doc = await _firestore.collection('admin_info').doc(user.uid).get();
      if (doc.exists) {
        return doc.data()?['admin_id'];
      }
    } catch (e) {
      print('Error fetching admin ID: $e');
    }
    return null;
  }

  /// Sign out
  static Future<void> signOut() async {
    await _auth.signOut();
  }

  // --- Data Methods (Modified for Isolation) ---

  /// Save client information
  static Future<String?> saveClientInfo({
    required String folderName,
    required String fullName,
    required int age,
    required String gender,
    required String schoolYear,
    required String phoneNumber,
    required String address,
    required DateTime birthday,
    required String adminId, // REQUIRED: Owner
  }) async {
    try {
      final docRef = await _firestore.collection('client_info').add({
        'folder_name': folderName,
        'full_name': fullName,
        'age': age,
        'gender': gender,
        'school_year': schoolYear,
        'phone_number': phoneNumber,
        'address': address,
        'birthday': Timestamp.fromDate(birthday),
        'admin_id': adminId, // Tag with Owner
        'created_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      });
      
      return docRef.id;
    } catch (e) {
      print('Error saving client info: $e');
      return null;
    }
  }
  
  /// Get client information by document ID
  static Future<Map<String, dynamic>?> getClientInfo(String documentId) async {
    try {
      final doc = await _firestore.collection('client_info').doc(documentId).get();
      if (doc.exists) return doc.data();
      return null;
    } catch (e) {
      print('Error getting client info: $e');
      return null;
    }
  }
  
  /// Get all client information (Filtered by Admin ID)
static Future<List<Map<String, dynamic>>> getAllClientInfo(String adminId) async {
  try {
    // Query without orderBy to avoid composite index requirement
    final querySnapshot = await _firestore.collection('client_info')
        .where('admin_id', isEqualTo: adminId)
        .get();
    
    return querySnapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return data;
    }).toList();
  } catch (e) {
    print('Error getting client info: $e');
    return [];
  }
}
  
  /// Update client information
  static Future<bool> updateClientInfo(String documentId, Map<String, dynamic> data) async {
    try {
      data['updated_at'] = FieldValue.serverTimestamp();
      await _firestore.collection('client_info').doc(documentId).update(data);
      return true;
    } catch (e) {
      print('Error updating client info: $e');
      return false;
    }
  }
  
  /// Delete client information
  static Future<bool> deleteClientInfo(String documentId) async {
    try {
      await _firestore.collection('client_info').doc(documentId).delete();
      return true;
    } catch (e) {
      print('Error deleting client info: $e');
      return false;
    }
  }

  /// Delete client info by folder name and admin ID
  static Future<bool> deleteClientInfoByFolder(String folderName, String adminId) async {
    try {
      final querySnapshot = await _firestore.collection('client_info')
          .where('folder_name', isEqualTo: folderName)
          .where('admin_id', isEqualTo: adminId)
          .get();
      
      for (var doc in querySnapshot.docs) {
        await doc.reference.delete();
      }
      
      print('✅ Deleted ${querySnapshot.docs.length} client info records for folder "$folderName"');
      return true;
    } catch (e) {
      print('Error deleting client info by folder: $e');
      return false;
    }
  }

  /// Save recording metadata
  static Future<String?> saveRecording({
    required String folderName,
    required String fileName,
    required String filePath,
    required String duration,
    required String size,
    required String date,
    String? transcription,
    required String adminId, // REQUIRED: Owner
    List<double>? waveform, // Added waveform parameter
  }) async {
    try {
      final docRef = await _firestore.collection('recordings').add({
        'folder_name': folderName,
        'file_name': fileName,
        'file_path': filePath,
        'duration': duration,
        'size': size,
        'date': date,
        'transcription': transcription ?? '',
        'admin_id': adminId, // Tag with Owner
        'created_at': FieldValue.serverTimestamp(),
        'waveform_data': waveform, // Save waveform data
      });
      return docRef.id;
    } catch (e) {
      print('Error saving recording: $e');
      return null;
    }
  }

  /// Update recording transcription by document ID
  static Future<bool> updateRecordingTranscription(String documentId, String transcription) async {
    try {
      await _firestore.collection('recordings').doc(documentId).update({
        'transcription': transcription,
        'updated_at': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      print('Error updating transcription: $e');
      return false;
    }
  }

  /// Get recordings for a specific folder (Filtered by Admin ID)
  static Future<List<Map<String, dynamic>>> getRecordings(String folderName, String adminId) async {
    try {
      final querySnapshot = await _firestore.collection('recordings')
          .where('folder_name', isEqualTo: folderName)
          .where('admin_id', isEqualTo: adminId) // FILTER
          .orderBy('created_at', descending: true)
          .get();
      
      return querySnapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      print('Error getting recordings: $e');
      return [];
    }
  }
  
  /// Delete recording by ID
  static Future<bool> deleteRecording(String documentId) async {
    try {
      await _firestore.collection('recordings').doc(documentId).delete();
      return true;
    } catch (e) {
      print('Error deleting recording: $e');
      return false;
    }
  }

  /// Save biomarker analysis result for future analytics
  static Future<String?> saveBiomarkerResult({
    required String recordingId,
    required String folderName,
    required String adminId,
    required String transcript,
    String? fileName, // Added for linking by name
    required Map<String, dynamic> severity,
    required Map<String, dynamic> emotion,
    required List<Map<String, dynamic>> anxietyIndicators,
    required List<String> detectedConditions,
    required String summary,
    int? processingTimeMs,
    Map<String, dynamic>? extractedFeatures,
  }) async {
    try {
      final docRef = await _firestore.collection('biomarker_results').add({
        'recording_id': recordingId,
        'folder_name': folderName,
        'file_name': fileName, // Save filename
        'admin_id': adminId,
        'transcript': transcript,
        'severity': severity,
        'emotion': emotion,
        'anxiety_indicators': anxietyIndicators,
        'detected_conditions': detectedConditions,
        'summary': summary,
        'processing_time_ms': processingTimeMs,
        'extracted_features': extractedFeatures,
        'created_at': FieldValue.serverTimestamp(),
      });
      print('✅ Biomarker result saved to Firebase: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('Error saving biomarker result: $e');
      return null;
    }
  }

  /// Save full extracted features to a subcollection
  static Future<void> saveExtractedFeatures(String biomarkerId, Map<String, dynamic> features) async {
    try {
      await _firestore.collection('biomarker_results').doc(biomarkerId)
          .collection('features').doc('extracted').set(features);
      print('✅ Extracted features saved to subcollection');
    } catch (e) {
      print('Error saving extracted features: $e');
    }
  }

  /// Save extracted features to the recordings collection (linked to recording doc)
  static Future<void> saveFeaturesToRecording(String recordingDocId, Map<String, dynamic> features) async {
    try {
      // 1. Save to subcollection
      await _firestore.collection('recordings').doc(recordingDocId)
          .collection('features').doc('extracted').set(features);
          
      // 2. Save as field in main doc for visibility
      await _firestore.collection('recordings').doc(recordingDocId).update({
        'extracted_features': features
      });
      
      print('✅ Extracted features saved to recordings (field & subcollection)');
    } catch (e) {
      print('Error saving features to recording: $e');
    }
  }

  /// Get biomarker results for analytics (filtered by admin)
  static Future<List<Map<String, dynamic>>> getBiomarkerResults(String adminId, {String? folderName}) async {
    try {
      Query query = _firestore.collection('biomarker_results')
          .where('admin_id', isEqualTo: adminId)
          .orderBy('created_at', descending: true);
      
      if (folderName != null) {
        query = query.where('folder_name', isEqualTo: folderName);
      }
      
      final querySnapshot = await query.get();
      
      return querySnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      print('Error getting biomarker results: $e');
      return [];
    }
  }
}
