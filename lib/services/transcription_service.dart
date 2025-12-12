import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Service to handle real-time speech transcription
/// Supports both English and Tagalog (Taglish)
class TranscriptionService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isAvailable = false;
  bool _isListening = false;
  final _transcriptionController = StreamController<String>.broadcast();
  
  /// Stream of transcribed text
  Stream<String> get transcriptionStream => _transcriptionController.stream;
  
  /// Check if speech recognition is available on the device
  Future<bool> initialize() async {
    try {
      _isAvailable = await _speech.initialize(
        onError: (error) {
          print('Speech recognition error: $error');
          _transcriptionController.add('[Error: ${error.errorMsg}]');
        },
        onStatus: (status) {
          print('Speech recognition status: $status');
          if (status == 'notListening') {
            _isListening = false;
          }
        },
      );
      return _isAvailable;
    } catch (e) {
      print('Failed to initialize speech recognition: $e');
      return false;
    }
  }
  
  /// Start listening and transcribing
  /// Uses English (en_US) for maximum compatibility
  Future<void> startListening() async {
    if (!_isAvailable) {
      print('❌ Speech recognition not available');
      _transcriptionController.add('[Speech recognition not available on device]');
      return;
    }
    
    if (_isListening) {
      print('⚠️ Already listening');
      return;
    }
    
    try {
      print('🎤 Starting transcription with English...');
      
      // Force English locale for maximum compatibility
      await _speech.listen(
        onResult: (result) {
          print('📝 Transcription: ${result.recognizedWords}');
          if (result.recognizedWords.isNotEmpty) {
            _transcriptionController.add(result.recognizedWords);
          }
        },
        localeId: 'en_US', // Force English
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        onDevice: false, // Use online recognition (no language pack needed)
        listenFor: const Duration(minutes: 30),
        pauseFor: const Duration(seconds: 3),
        cancelOnError: false,
      );
      
      _isListening = true;
      print('✅ Transcription started in English (online mode)');
    } catch (e) {
      print('❌ Failed to start listening: $e');
      _transcriptionController.add('[Error: $e]');
    }
  }
  
  /// Stop listening
  Future<void> stopListening() async {
    if (_isListening) {
      await _speech.stop();
      _isListening = false;
    }
  }
  
  /// Cancel listening
  Future<void> cancelListening() async {
    if (_isListening) {
      await _speech.cancel();
      _isListening = false;
    }
  }
  
  /// Get list of available locales on the device
  Future<List<stt.LocaleName>> getAvailableLocales() async {
    if (!_isAvailable) {
      await initialize();
    }
    return await _speech.locales();
  }
  
  /// Check if currently listening
  bool get isListening => _isListening;
  
  /// Check if service is available
  bool get isAvailable => _isAvailable;
  
  /// Dispose resources
  void dispose() {
    _speech.stop();
    _transcriptionController.close();
  }
}
