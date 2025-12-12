import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

/// Whisper-based transcription service for offline Taglish support
/// Processes audio AFTER recording completes (not real-time)
class WhisperTranscriptionService {
  WhisperFlutterNew? _whisper;
  bool _isInitialized = false;
  String? _modelPath;
  
  /// Initialize Whisper with base model
  Future<bool> initialize() async {
    try {
      print('🎤 Initializing Whisper transcription service...');
      
      _whisper = WhisperFlutterNew();
      
      // Get model path
      final modelDir = await getApplicationDocumentsDirectory();
      _modelPath = '${modelDir.path}/whisper_base.bin';
      
      // Check if model exists, if not, download it
      final modelFile = File(_modelPath!);
      if (!await modelFile.exists()) {
        print('📥 Downloading Whisper base model (~140MB)...');
        print('⚠️ This may take a few minutes on first use');
        
        // Download model from official source
        // Note: In production, you should host this yourself or use asset bundling
        await _downloadModel(_modelPath!);
      }
      
      _isInitialized = true;
      print('✅ Whisper initialized successfully');
      return true;
    } catch (e) {
      print('❌ Failed to initialize Whisper: $e');
      return false;
    }
  }
  
  /// Transcribe an audio file
  Future<String> transcribeFile(String audioFilePath) async {
    if (!_isInitialized || _whisper == null) {
      print('❌ Whisper not initialized');
      return '[Transcription service not initialized]';
    }
    
    try {
      print('🎵 Transcribing audio file: $audioFilePath');
      
      // Whisper transcription request
      final request = WhisperRequest(
        audio: audioFilePath,
        model: _modelPath!,
        language: null, // Auto-detect (supports Taglish)
        isTranslate: false, // Don't translate, just transcribe
        isNotimestamps: true, // We don't need timestamps
        threads: 4, // Use 4 threads for faster processing
      );
      
      // Process transcription
      final response = await _whisper!.request(request);
      
      if (response != null && response.isNotEmpty) {
        print('✅ Transcription complete: ${response.length} characters');
        return response;
      } else {
        print('⚠️ No transcription result');
        return '[No speech detected]';
      }
    } catch (e) {
      print('❌ Transcription error: $e');
      return '[Transcription failed: $e]';
    }
  }
  
  /// Download Whisper base model
  Future<void> _downloadModel(String destinationPath) async {
    // Model URL - using ggml-base model
    // Note: You should host this file yourself or include it as an asset
    const modelUrl = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';
    
    try {
      final httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(modelUrl));
      final response = await request.close();
      
      final file = File(destinationPath);
      final sink = file.openWrite();
      
      await response.pipe(sink);
      await sink.close();
      
      print('✅ Model downloaded successfully');
    } catch (e) {
      print('❌ Model download failed: $e');
      throw Exception('Failed to download Whisper model: $e');
    }
  }
  
  /// Check if initialized
  bool get isInitialized => _isInitialized;
  
  /// Dispose resources
  void dispose() {
    _whisper = null;
    _isInitialized = false;
  }
}
