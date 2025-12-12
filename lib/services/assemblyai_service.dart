import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// AssemblyAI transcription service for post-recording transcription
/// Free tier: 5 hours/month, no billing needed
class AssemblyAIService {
  // AssemblyAI API key
  static const String apiKey = '1f4030f4b48c4aeab11a8f207df1c96b';
  static const String uploadUrl = 'https://api.assemblyai.com/v2/upload';
  static const String transcriptUrl = 'https://api.assemblyai.com/v2/transcript';
  
  /// Upload audio file and get transcription
  Future<String> transcribeFile(String filePath) async {
    try {
      print('🎤 Starting transcription with AssemblyAI...');
      
      // Step 1: Upload audio file
      final uploadedUrl = await _uploadFile(filePath);
      if (uploadedUrl == null) {
        return '[Failed to upload audio]';
      }
      
      // Step 2: Request transcription
      final transcriptId = await _requestTranscription(uploadedUrl);
      if (transcriptId == null) {
        return '[Failed to start transcription]';
      }
      
      // Step 3: Poll for completion
      final transcription = await _pollForCompletion(transcriptId);
      return transcription;
      
    } catch (e) {
      print('❌ Transcription error: $e');
      return '[Error: $e]';
    }
  }
  
  /// Upload audio file to AssemblyAI
  Future<String?> _uploadFile(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      
      final response = await http.post(
        Uri.parse(uploadUrl),
        headers: {
          'authorization': apiKey,
          'Transfer-Encoding': 'chunked',
        },
        body: bytes,
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ File uploaded: ${data['upload_url']}');
        return data['upload_url'];
      } else {
        print('❌ Upload failed: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ Upload error: $e');
      return null;
    }
  }
  
  /// Request transcription
  Future<String?> _requestTranscription(String audioUrl) async {
    try {
      final response = await http.post(
        Uri.parse(transcriptUrl),
        headers: {
          'authorization': apiKey,
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'audio_url': audioUrl,
          'language_code': 'en', // English/Taglish
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ Transcription started: ${data['id']}');
        return data['id'];
      } else {
        print('❌ Transcription request failed: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ Request error: $e');
      return null;
    }
  }
  
  /// Poll for transcription completion
  Future<String> _pollForCompletion(String transcriptId) async {
    const maxAttempts = 60; // 5 minutes max
    int attempts = 0;
    
    while (attempts < maxAttempts) {
      try {
        final response = await http.get(
          Uri.parse('$transcriptUrl/$transcriptId'),
          headers: {'authorization': apiKey},
        );
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final status = data['status'];
          
          if (status == 'completed') {
            print('✅ Transcription complete!');
            return data['text'] ?? '[No transcription]';
          } else if (status == 'error') {
            print('❌ Transcription error: ${data['error']}');
            return '[Transcription failed]';
          }
          
          // Still processing
          print('⏳ Status: $status');
          await Future.delayed(const Duration(seconds: 5));
          attempts++;
        }
      } catch (e) {
        print('❌ Polling error: $e');
        return '[Error checking status]';
      }
    }
    
    return '[Transcription timeout]';
  }
}
