import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:math';

class FirebaseService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // --- Auth Methods ---

  /// Generate a random 6-digit Admin ID
  static String _generateRandomAdminId() {
    var rng = Random();
    return (100000 + rng.nextInt(900000)).toString();
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
      String adminId = _generateRandomAdminId();
      // Ensure uniqueness (simple check, theoretically could collision but rare for demo)
      // In production, would loop check.

      // 3. Save Admin Details to 'admin_info'
      await _firestore.collection('admin_info').doc(userCredential.user!.uid).set({
        'admin_id': adminId,
        'full_name': fullName,
        'email': email,
        'phone_number': phoneNumber,
        'photo_url': photoUrl ?? '',
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

  /// Login Admin using Email or Admin ID
  static Future<User?> loginAdmin({
    required String identifier, // Email or Admin ID
    required String password,
  }) async {
    try {
      String email = identifier;

      // Check if identifier is an Admin ID (assumed numeric)
      if (RegExp(r'^\d+$').hasMatch(identifier)) {
        print('Attempting login with Admin ID: $identifier');
        // Look up email via Admin ID
        final query = await _firestore
            .collection('admin_info')
            .where('admin_id', isEqualTo: identifier)
            .limit(1)
            .get();

        if (query.docs.isNotEmpty) {
          email = query.docs.first.data()['email'];
          print('Found email for Admin ID: $email');
        } else {
          print('Admin ID not found in database');
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
      final querySnapshot = await _firestore.collection('client_info')
          .where('admin_id', isEqualTo: adminId) // FILTER
          .orderBy('created_at', descending: true)
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
}
