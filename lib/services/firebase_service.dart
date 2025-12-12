import 'package:cloud_firestore/cloud_firestore.dart';

class FirebaseService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  /// Save client information to the 'client_info' collection
  /// Returns the document ID of the saved client info
  static Future<String?> saveClientInfo({
    required String folderName,
    required String fullName,
    required int age,
    required String gender,
    required String schoolYear,
    required String phoneNumber,
    required String address,
    required DateTime birthday,
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
      
      if (doc.exists) {
        return doc.data();
      }
      return null;
    } catch (e) {
      print('Error getting client info: $e');
      return null;
    }
  }
  
  /// Get all client information
  static Future<List<Map<String, dynamic>>> getAllClientInfo() async {
    try {
      final querySnapshot = await _firestore.collection('client_info')
          .orderBy('created_at', descending: true)
          .get();
      
      return querySnapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      print('Error getting all client info: $e');
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
  }) async {
    try {
      final docRef = await _firestore.collection('recordings').add({
        'folder_name': folderName,
        'file_name': fileName,
        'file_path': filePath,
        'duration': duration,
        'size': size,
        'date': date,
        'created_at': FieldValue.serverTimestamp(),
      });
      return docRef.id;
    } catch (e) {
      print('Error saving recording: $e');
      return null;
    }
  }

  /// Get recordings for a specific folder
  static Future<List<Map<String, dynamic>>> getRecordings(String folderName) async {
    try {
      final querySnapshot = await _firestore.collection('recordings')
          .where('folder_name', isEqualTo: folderName)
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
