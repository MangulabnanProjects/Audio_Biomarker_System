import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final StreamController<double> _amplitudeController = StreamController<double>.broadcast();
  Timer? _amplitudeTimer;
  String? _currentRecordingPath;
  
  // Stream for real-time amplitude updates (in dB)
  Stream<double> get amplitudeStream => _amplitudeController.stream;

  // Audio Player Streams
  Stream<PlayerState> get playerStateStream => _audioPlayer.onPlayerStateChanged;
  Stream<Duration> get positionStream => _audioPlayer.onPositionChanged;
  Stream<Duration> get durationStream => _audioPlayer.onDurationChanged;
  Stream<void> get playerCompleteStream => _audioPlayer.onPlayerComplete;
  
  // Check if currently recording
  Future<bool> isRecording() async {
    return await _recorder.isRecording();
  }

  // ... (Permission methods remain same) ...

  // Play audio
  Future<void> play(String path) async {
    try {
      await _audioPlayer.play(DeviceFileSource(path));
    } catch (e) {
      print('Error playing audio: $e');
    }
  }

  // Pause audio
  Future<void> pausePlayback() async {
    await _audioPlayer.pause();
  }

  // Resume audio
  Future<void> resumePlayback() async {
    await _audioPlayer.resume();
  }

  // Seek audio
  Future<void> seek(Duration duration) async {
    await _audioPlayer.seek(duration);
  }

  // Stop audio
  Future<void> stopPlayback() async {
    await _audioPlayer.stop();
  }
  
  // Request microphone permission
  Future<bool> requestPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }
  
  // Check if permission is granted
  Future<bool> hasPermission() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }
  
  // Start recording audio
  Future<String?> startRecording() async {
    try {
      // Check permission
      if (!await hasPermission()) {
        final granted = await requestPermission();
        if (!granted) {
          return null;
        }
      }
      
      // Create file path for recording
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentRecordingPath = '${directory.path}/recording_$timestamp.wav';
      
      // Start recording with amplitude monitoring
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          bitRate: 128000, // Not used for WAV but good to keep or remove
          sampleRate: 44100,
        ),
        path: _currentRecordingPath!,
      );
      
      // Start monitoring amplitude
      _startAmplitudeMonitoring();
      
      return _currentRecordingPath;
    } catch (e) {
      print('Error starting recording: $e');
      return null;
    }
  }
  
  // Stop recording
  Future<String?> stopRecording() async {
    try {
      _stopAmplitudeMonitoring();
      final path = await _recorder.stop();
      _currentRecordingPath = null;
      return path;
    } catch (e) {
      print('Error stopping recording: $e');
      return null;
    }
  }

  // Pause recording
  Future<void> pauseRecording() async {
    try {
      await _recorder.pause();
      // Don't stop timer, but logic in timer should handle pause... 
      // Actually, let's just stop monitoring or send 0s. 
      // If we stop monitoring, visualizer freezes. 
      // Better to modify monitoring loop to check isPaused? 
      // Or simply let it run? getAmplitude() might return 0 if paused.
    } catch (e) {
      print('Error pausing recording: $e');
    }
  }

  // Resume recording
  Future<void> resumeRecording() async {
    try {
      await _recorder.resume();
    } catch (e) {
      print('Error resuming recording: $e');
    }
  }
  
  // Start monitoring amplitude in real-time
  void _startAmplitudeMonitoring() {
    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) async {
      final amplitude = await _recorder.getAmplitude();
      
      // Convert amplitude to dB scale
      // The current value from getAmplitude() is already in dBFS (decibels relative to full scale)
      // Range is typically -160 dB (silence) to 0 dB (max)
      double dbValue = amplitude.current;
      
      // Normalize to a more useful range (0 to 100 for UI purposes)
      // Map -60 dB to 0, and 0 dB to 100
      double normalizedDb = ((dbValue + 60) / 60 * 100).clamp(0, 100);
      
      _amplitudeController.add(normalizedDb);
    });
  }
  
  // Stop monitoring amplitude
  void _stopAmplitudeMonitoring() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    _amplitudeController.add(0);
  }
  
  // Dispose resources
  void dispose() {
    _stopAmplitudeMonitoring();
    _amplitudeController.close();
    _recorder.dispose();
    _audioPlayer.dispose();
  }
}
