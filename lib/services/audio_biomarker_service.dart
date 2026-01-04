import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/biomarker_result.dart';

/// Service to communicate with the Mobile API server for biomarker analysis
class AudioBiomarkerService {
  // Base URL for the mobile API server (can be changed in settings)
  // Default: Use your PC's IP for physical device
  static String _baseUrl = 'http://192.168.0.10:5001';
  
  static String get baseUrl => _baseUrl;

  /// Load server URL from local storage
  static Future<void> loadConfig() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/server_config.txt');
      if (await file.exists()) {
        final savedUrl = await file.readAsString();
        if (savedUrl.trim().isNotEmpty) {
          _baseUrl = savedUrl.trim();
          print('🔧 Loaded server configuration: $_baseUrl');
        }
      }
    } catch (e) {
      print('⚠️ Using default server configuration: $_baseUrl');
    }
  }

  /// Save server URL to local storage
  static Future<void> saveConfig(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/server_config.txt');
      await file.writeAsString(url.trim());
      _baseUrl = url.trim();
      print('💾 Saved server configuration: $_baseUrl');
    } catch (e) {
      print('❌ Error saving server configuration: $e');
    }
  }

  /// Check if the API server is running
  static Future<bool> isServerHealthy() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/health'),
      ).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('🏥 Server health: $data');
        return data['status'] == 'healthy';
      }
      return false;
    } catch (e) {
      print('❌ Server health check failed: $e');
      return false;
    }
  }

  /// Analyze audio file with the ML model
  /// 
  /// [audioPath] - Path to the audio file
  /// [transcript] - Transcribed text from the audio
  /// 
  /// Returns [BiomarkerResult] with severity, emotion, and anxiety indicators
  static Future<BiomarkerResult> analyzeAudio(String audioPath, String transcript) async {
    try {
      print('🔬 Starting biomarker analysis...');
      print('📁 Audio path: $audioPath');
      print('📝 Transcript length: ${transcript.length} chars');

      // Create multipart request
      final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/analyze'));
      
      // Add audio file
      final audioFile = File(audioPath);
      if (!await audioFile.exists()) {
        return BiomarkerResult.error('Audio file not found');
      }
      
      request.files.add(await http.MultipartFile.fromPath(
        'audio',
        audioPath,
        filename: audioPath.split('/').last,
      ));
      
      // Add transcript
      request.fields['transcript'] = transcript;
      
      // Send request
      print('📤 Sending to server...');
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60), // Allow time for ML processing
      );
      
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ Analysis complete!');
        print('📊 Severity: ${data['severity']?['level']}');
        print('🎭 Emotion: ${data['emotion']?['label']}');
        final features = data['features'] as Map<String, dynamic>?;
        print('🔢 Extracted Features: ${features?.length ?? 0}');
        
        return BiomarkerResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        print('❌ Server error: ${error['error']}');
        return BiomarkerResult.error(error['error'] ?? 'Server error: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ Analysis failed: $e');
      
      if (e.toString().contains('SocketException') || e.toString().contains('Connection refused')) {
        return BiomarkerResult.error('Cannot connect to analysis server. Make sure the server is running.');
      }
      
      return BiomarkerResult.error('Analysis failed: $e');
    }
  }
}
