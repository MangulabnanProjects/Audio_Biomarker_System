import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/audio_recorder_service.dart';
import '../services/firebase_service.dart';
import '../services/database_service.dart'; // Import DatabaseService
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/waveform_visualizer.dart';
import '../widgets/record_button.dart';
import '../widgets/marquee_text.dart';

class AudioRecorderScreen extends StatefulWidget {
  const AudioRecorderScreen({super.key});

  @override
  State<AudioRecorderScreen> createState() => _AudioRecorderScreenState();
}

class _AudioRecorderScreenState extends State<AudioRecorderScreen> {
  final AudioRecorderService _audioService = AudioRecorderService();
  bool _isRecording = false;
  bool _isPaused = false;
  double _currentLevel = 0.0;
  Duration _recordingDuration = Duration.zero;
  Timer? _timer;
  StreamSubscription? _amplitudeSubscription;
  String _statusMessage = 'Ready to record';
  int _selectedNavIndex = 0; // Start on Home tab by default
  // Session Details State
  bool _hasShownSessionDetails = false;
  final Map<String, String> _sessionDetails = {};
  
  // Controllers for Session Form
  final TextEditingController _folderController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();
  final TextEditingController _genderController = TextEditingController();
  final TextEditingController _yearController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _birthdayController = TextEditingController();
  
  // Gender, School Year, and Birthday Selection
  String? _selectedGender;
  String? _selectedSchoolYear;
  DateTime? _selectedBirthday;
  
  // Search Controller for Storage Page
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  
  // Delete Mode for Storage Page
  bool _isDeleteMode = false;
  
  // Audio Player State
  String? _selectedAudioName;
  bool _isPlaying = false;
  bool _isPausedPlayer = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  // Stream Subscriptions
  StreamSubscription? _positionSubscription;
  StreamSubscription? _playerCompleteSubscription;

  // Storage Folders State
  // Map<String, List<Map<String, String>>> where inner list contains file info
  // Keys: name, duration, date, size
  Map<String, List<Map<String, String>>> _allFolders = {
    'Meetings': [],
    'Interviews': [],
    'Personal Notes': [],
  };
  
  // Folder Metadata for partial user info storage
  Map<String, Map<String, dynamic>> _folderMetadata = {};

  @override
  void initState() {
    super.initState();
    _checkPermission();
    _setupAmplitudeListener();
    _allFolders = {};
    _allFolders = {};
    _allFolders = {};
    // Load persisted data (Local DB + Firebase)
    _loadData();
    
    // Listen to audio player position
    _positionSubscription = _audioService.positionStream.listen((position) {
      if (mounted && _isPlaying) {
        setState(() {
          _currentPosition = position;
        });
      }
    });

    // Listen to audio player completion
    _playerCompleteSubscription = _audioService.playerCompleteStream.listen((event) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _isPausedPlayer = false;
          _currentPosition = Duration.zero;
          _selectedAudioName = null;
        });
      }
    });
  }
  
  Future<void> _loadData() async {
    try {
      // 1. Load from Local Database (SQLite) - Primary Source
      final localRecordings = await DatabaseService.instance.getAllRecordings();
      
      Map<String, List<Map<String, String>>> loadedFolders = {};
      Set<String> folderNames = {};

      for (var rec in localRecordings) {
        String folderName = rec['folder_name'] as String;
        folderNames.add(folderName);
        
        if (!loadedFolders.containsKey(folderName)) {
          loadedFolders[folderName] = [];
        }
        
        // Check if file exists physically
        bool fileExists = await File(rec['file_path']).exists();
        if (fileExists) {
           loadedFolders[folderName]!.add({
            'id': rec['id'].toString(), // SQLite ID is int
            'name': rec['file_name'],
            'duration': rec['duration'],
            'date': rec['date'],
            'size': rec['size'],
            'path': rec['file_path'],
          });
        }
      }
      
      // Load Metadata from Firebase (for user info) - Secondary
      final clientInfos = await FirebaseService.getAllClientInfo();

      // 1b. Load Folders from Local Database (Metadata)
      final localFolders = await DatabaseService.instance.getAllFolders();
      for (var folder in localFolders) {
        String name = folder['name'] as String;
        folderNames.add(name);
        
        if (!loadedFolders.containsKey(name)) {
          loadedFolders[name] = [];
        }

        // Restore metadata from local DB if available (assuming we store it JSON encoded or columns)
        // For this iteration, we didn't add specific columns for age/gender etc to 'folders' table yet in the CREATE statement.
        // Wait, looking at DatabaseService, the 'folders' table only has 'name' and 'created_at'.
        // So we can't fully restore metadata just from that table unless we expanded it.
        // HOWEVER, user just asked "where did the folder go?", so ensuring the NAME exists is step 1.
        // We can rely on Firebase or valid recordings to populate metadata for now, OR rely on the fact that
        // we will be inserting it into the 'folders' table if we update the schema.
        // For now, let's just make sure the folder exists in the list.
      }
      Map<String, Map<String, dynamic>> loadedMetadata = {};
      
      for (var info in clientInfos) {
        final folderName = info['folder_name'] as String?;
        if (folderName != null && folderName.isNotEmpty) {
           // If folder exists in Firebase but not in local DB yet, add it to names
           // But don't create empty list in loadedFolders unless we want empty folders
           if (!folderNames.contains(folderName)) {
             folderNames.add(folderName); 
             // Optional: loadedFolders[folderName] = []; 
           }

          if (!loadedMetadata.containsKey(folderName)) {
            loadedMetadata[folderName] = {
              'name': info['full_name'],
              'age': info['age'].toString(),
              'year': info['school_year'],
              'gender': info['gender'],
              'phone': info['phone_number'],
              'address': info['address'],
              'birthday': (info['birthday'] as Timestamp).toDate(),
            };
          }
        }
      }

      // 3. Add "Personal Notes" default
      if (!loadedFolders.containsKey('Personal Notes')) {
        loadedFolders['Personal Notes'] = [];
      }

      // 4. Update UI
      if (mounted) {
        setState(() {
          _allFolders = loadedFolders;
          _folderMetadata = loadedMetadata;
        });
      }
    } catch (e) {
      print('Error loading data: $e');
    }
  }

  Future<void> _checkPermission() async {
    final hasPermission = await _audioService.hasPermission();
    if (!hasPermission) {
      setState(() {
        _statusMessage = 'Microphone permission required';
      });
    }
  }

  void _setupAmplitudeListener() {
    _amplitudeSubscription = _audioService.amplitudeStream.listen((level) {
      setState(() {
        _currentLevel = level;
      });
    });
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _togglePause() async {
    if (!_isRecording) return;
    
    if (_isPaused) {
      // Resume
      await _audioService.resumeRecording();
      setState(() {
        _isPaused = false;
        _statusMessage = 'Recording...';
      });
    } else {
      // Pause
      await _audioService.pauseRecording();
      setState(() {
        _isPaused = true;
        _statusMessage = 'Recording Paused';
      });
    }
  }

  Future<void> _startTimer() async {
    _timer?.cancel();
    _recordingDuration = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isPaused && _isRecording) {
        setState(() {
          _recordingDuration += const Duration(seconds: 1);
        });
      }
    });
  }

  Future<void> _startRecording() async {
    final path = await _audioService.startRecording();
    
    if (path != null) {
      setState(() {
        _isRecording = true;
        _isPaused = false;
        _recordingDuration = Duration.zero;
        _statusMessage = 'Recording...';
      });

      // Start duration timer
      _startTimer();
    } else {
      setState(() {
        _statusMessage = 'Failed to start recording. Please grant microphone permission.';
      });
      
      // Request permission
      await _audioService.requestPermission();
    }
  }

  Future<void> _stopRecording() async {
    final path = await _audioService.stopRecording();
    final duration = _recordingDuration; // Capture duration before reset
    
    _timer?.cancel();
    _timer = null;

    if (path != null) {
      // Process the recording
      final file = File(path);
      final fileName = path.split('/').last; // Get filename from path
      final fileSize = await file.length();
      final sizeStr = _formatFileSize(fileSize);
      final dateStr = DateFormat('MMM dd, h:mm a').format(DateTime.now());
      final durationStr = _formatDuration(duration); // Using existing helper
      
      // Determine folder
      String folderName = _sessionDetails['folder'] ?? 'Personal Notes';
      
      // Save to Firebase (Optional mostly for metadata now)
      final firebaseId = await FirebaseService.saveRecording(
        folderName: folderName,
        fileName: fileName,
        filePath: path,
        duration: durationStr,
        size: sizeStr,
        date: dateStr,
      );
      
      // Save to Local Database (CRITICAL for persistence)
      final dbId = await DatabaseService.instance.insertRecording({
        'file_name': fileName,
        'file_path': path,
        'folder_name': folderName,
        'duration': durationStr,
        'size': sizeStr,
        'date': dateStr,
        'created_at': DateTime.now().toIso8601String(),
      });
      
      // Update UI
      setState(() {
        _isRecording = false;
        _isPaused = false;
        _currentLevel = 0.0;
        _statusMessage = 'Recording saved to $folderName';
        
        // Add to folder list
        if (!_allFolders.containsKey(folderName)) {
          _allFolders[folderName] = [];
        }
        
        _allFolders[folderName]!.insert(0, {
          'id': dbId.toString(), // Use DB ID
          'name': fileName,
          'duration': durationStr,
          'date': dateStr,
          'size': sizeStr,
          'path': path,
        });
      });
    } else {
      setState(() {
        _isRecording = false;
        _isPaused = false;
        _currentLevel = 0.0;
        _statusMessage = 'Failed to save recording';
      });
    }

    // Reset status message after a delay
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_isRecording) {
        setState(() {
          _statusMessage = 'Ready to record';
          _recordingDuration = Duration.zero;
        });
      }
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }




  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _amplitudeSubscription?.cancel();
    _audioService.dispose();
    _folderController.dispose();
    _nameController.dispose();
    _ageController.dispose();
    _genderController.dispose();
    _yearController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _birthdayController.dispose();
    _searchController.dispose();
    _positionSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    super.dispose();
  }

  // Audio Player Control Methods
  void _playAudio(String audioName, String duration, String path) {
    _audioService.play(path);
    setState(() {
      _selectedAudioName = audioName;
      _isPlaying = true;
      _isPausedPlayer = false;
      _currentPosition = Duration.zero;
      // Parse duration (format: "45:20" or "2:30")
      final parts = duration.split(':');
      if (parts.length == 2) {
        _totalDuration = Duration(
          minutes: int.tryParse(parts[0]) ?? 0,
          seconds: int.tryParse(parts[1]) ?? 0,
        );
      } else if (parts.length == 3) {
        _totalDuration = Duration(
          hours: int.tryParse(parts[0]) ?? 0,
          minutes: int.tryParse(parts[1]) ?? 0,
          seconds: int.tryParse(parts[2]) ?? 0,
        );
      }
    });
  }

  void _pauseAudio() {
    _audioService.pausePlayback();
    setState(() {
      _isPausedPlayer = true;
    });
  }

  void _resumeAudio() {
    _audioService.resumePlayback();
    setState(() {
      _isPausedPlayer = false;
    });
  }

  void _stopAudio() {
    _audioService.stopPlayback();
    setState(() {
      _selectedAudioName = null;
      _isPlaying = false;
      _isPausedPlayer = false;
      _currentPosition = Duration.zero;
      _totalDuration = Duration.zero;
    });
  }

  void _seekAudio(double value) {
    final position = Duration(milliseconds: value.toInt());
    _audioService.seek(position);
    setState(() {
      _currentPosition = position;
    });
  }

  Future<void> _showDeleteFolderDialog(String folderName) async {
    return showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text(
            'Delete Folder',
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Are you sure you want to delete the folder "$folderName" and all its contents?',
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                
                setState(() {
                  _allFolders.remove(folderName);
                  _folderMetadata.remove(folderName);
                  _isDeleteMode = false; // Exit delete mode after deletion
                });
                
                // Delete from Local DB
                await DatabaseService.instance.deleteFolder(folderName);
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Folder "$folderName" deleted'),
                    backgroundColor: Colors.red[700],
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red[700],
              ),
              child: const Text('Delete', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDeleteFileDialog(String fileName, String folderName, String id) async {
    return showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text(
            'Delete Audio File',
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Are you sure you want to delete "$fileName"?',
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                
                // 1. Delete from Local Database
                int? dbId = int.tryParse(id);
                if (dbId != null) {
                  await DatabaseService.instance.deleteRecording(dbId);
                }

                // 2. Delete Physical File
                try {
                  if (_allFolders.containsKey(folderName)) {
                    final fileData = _allFolders[folderName]?.firstWhere(
                      (element) => element['name'] == fileName,
                      orElse: () => {},
                    );
                    
                    if (fileData != null && fileData.isNotEmpty && fileData.containsKey('path')) {
                      final file = File(fileData['path']!);
                      if (await file.exists()) {
                        await file.delete();
                      }
                    }
                  }
                } catch (e) {
                  print('Error deleting file: $e');
                }

                // 3. Update UI
                if (mounted) {
                  setState(() {
                    if (_allFolders.containsKey(folderName)) {
                      _allFolders[folderName]?.removeWhere((file) => file['name'] == fileName);
                    }
                  });
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('File "$fileName" deleted'),
                      backgroundColor: Colors.red[700],
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red[700],
              ),
              child: const Text('Delete', style: TextStyle(color: Colors.white)),
            ),

          ],
        );
      },
    );
  }

  Future<void> _showSessionDetailsDialog() async {
    return showDialog(
      context: context,
      barrierDismissible: false, // Force user to interact
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text(
                'New Recording Session',
                style: TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Collapsing Existing Folder List - FIRST
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFF81C784)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ExpansionTile(
                          leading: const Icon(Icons.folder_open, color: Color(0xFF81C784)),
                          title: const Text(
                            'Select Existing Folder',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF424242),
                            ),
                          ),
                          iconColor: const Color(0xFF2E7D32),
                          collapsedIconColor: const Color(0xFF81C784),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                          children: _allFolders.keys.map((name) {
                            return _buildFolderItem(name, setDialogState); // Pass setState to close dialog if needed
                          }).toList(),
                        ),
                      ),
                    ),
                    
                    // Create New Folder Field - SECOND
                    _buildTextField(_folderController, 'Or Create New Folder', Icons.create_new_folder),
                    
                    // Other user info fields
                    _buildTextField(_nameController, 'Full Name', Icons.person),
                    
                    Row(
                      children: [
                        // Age field with 3 digit max
                        Expanded(
                          child: TextField(
                            controller: _ageController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(3),
                            ],
                            decoration: InputDecoration(
                              labelText: 'Age',
                              prefixIcon: const Icon(Icons.cake, color: Color(0xFF81C784)),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 2),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // School Year Dropdown
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _selectedSchoolYear,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: 'School Year',
                              prefixIcon: const Icon(Icons.school, color: Color(0xFF81C784), size: 20),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 2),
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                            ),
                            items: [
                              '1st Year College',
                              '2nd Year College',
                              '3rd Year College',
                              '4th Year College',
                              'Senior High School',
                              '1st Year High School',
                              '2nd Year High School',
                              '3rd Year High School',
                              '4th Year High School',
                            ].map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(
                                  value,
                                  style: const TextStyle(fontSize: 9),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
                            onChanged: (String? newValue) {
                              setDialogState(() {
                                _selectedSchoolYear = newValue;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Gender Dropdown
                    DropdownButtonFormField<String>(
                      value: _selectedGender,
                      decoration: InputDecoration(
                        labelText: 'Gender',
                        prefixIcon: const Icon(Icons.wc, color: Color(0xFF81C784)),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 2),
                        ),
                      ),
                      items: ['Male', 'Female'].map((String value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setDialogState(() {
                          _selectedGender = newValue;
                        });
                      },
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Birthday Date Picker
                    InkWell(
                      onTap: () async {
                        final DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedBirthday ?? DateTime(2000),
                          firstDate: DateTime(1900),
                          lastDate: DateTime.now(),
                          builder: (context, child) {
                            return Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: const ColorScheme.light(
                                  primary: Color(0xFF2E7D32),
                                  onPrimary: Colors.white,
                                  onSurface: Colors.black,
                                ),
                              ),
                              child: child!,
                            );
                          },
                        );
                        if (picked != null) {
                          setDialogState(() {
                            _selectedBirthday = picked;
                            _birthdayController.text = DateFormat('MMM dd, yyyy').format(picked);
                          });
                        }
                      },
                      child: AbsorbPointer(
                        child: TextField(
                          controller: _birthdayController,
                          decoration: InputDecoration(
                            labelText: 'Birthday',
                            prefixIcon: const Icon(Icons.calendar_today, color: Color(0xFF81C784)),
                            suffixIcon: const Icon(Icons.arrow_drop_down),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 2),
                            ),
                          ),
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Phone Number with 11 digit validation
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(11),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Phone Number (11 digits)',
                        prefixIcon: const Icon(Icons.phone, color: Color(0xFF81C784)),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 2),
                        ),
                        helperText: 'Must be exactly 11 digits',
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    _buildTextField(_addressController, 'Address', Icons.location_on),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    // Cancel: Go to Home instead of Record
                    Navigator.of(context).pop();
                    setState(() {
                      _selectedNavIndex = 0; // Go to Home
                    });
                  },
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    // Validate required fields
                    if (_folderController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please enter or select a folder name'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    
                    if (_nameController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please enter your full name'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    
                    if (_ageController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please enter your age'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    
                    if (_selectedGender == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please select your gender'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    
                    if (_selectedSchoolYear == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please select your school year/level'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    
                    if (_selectedBirthday == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please select your birthday'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    
                    if (_addressController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please enter your address'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    
                    // Validate phone number is exactly 11 digits
                    if (_phoneController.text.length != 11) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Phone number must be exactly 11 digits'),
                          backgroundColor: Colors.red,
                          duration: Duration(seconds: 3),
                        ),
                      );
                      return;
                    }
                    
                    // Save to Firebase
                    final docId = await FirebaseService.saveClientInfo(
                      folderName: _folderController.text,
                      fullName: _nameController.text,
                      age: int.parse(_ageController.text),
                      gender: _selectedGender!,
                      schoolYear: _selectedSchoolYear!,
                      phoneNumber: _phoneController.text,
                      address: _addressController.text,
                      birthday: _selectedBirthday!,
                    );
                    
                    if (docId != null) {
                      setState(() {
                        _sessionDetails['documentId'] = docId;
                        _sessionDetails['folder'] = _folderController.text;
                        _sessionDetails['name'] = _nameController.text;
                        _sessionDetails['age'] = _ageController.text;
                        _sessionDetails['year'] = _selectedSchoolYear!;
                        _sessionDetails['gender'] = _selectedGender!;
                        _sessionDetails['phone'] = _phoneController.text;
                        _sessionDetails['address'] = _addressController.text;
                        
                        _hasShownSessionDetails = true;
                        _selectedNavIndex = 2; // Actually go to Record tab
                        
                        // Create the folder if it doesn't exist (UI Update)
                        final folderName = _folderController.text;
                        if (folderName.isNotEmpty) {
                          if (!_allFolders.containsKey(folderName)) {
                            _allFolders[folderName] = []; // Initialize empty folder
                          }
                          
                          // Save folder metadata for future bypass
                          _folderMetadata[folderName] = {
                            'name': _nameController.text,
                            'age': _ageController.text,
                            'year': _selectedSchoolYear,
                            'gender': _selectedGender,
                            'phone': _phoneController.text,
                            'address': _addressController.text,
                            'birthday': _selectedBirthday,
                          };
                        }

                        // Clear all form fields for next session
                        _folderController.clear();
                        _nameController.clear();
                        _ageController.clear();
                        _phoneController.clear();
                        _addressController.clear();
                        _birthdayController.clear();
                        _selectedGender = null;
                        _selectedSchoolYear = null;
                        _selectedBirthday = null;
                      });
                      
                      // SAVE EXISTING FOLDER TO LOCAL DB (Async, outside setState)
                      final folderName = _sessionDetails['folder']; 
                      
                      if (folderName != null && folderName.isNotEmpty) {
                         await DatabaseService.instance.insertFolder({
                            'name': folderName,
                            'created_at': DateTime.now().toIso8601String(),
                          });
                      }
                      
                      Navigator.of(context).pop();
                      
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Session details saved successfully!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Failed to save session details. Please try again.'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Start Session'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildFolderItem(String name, StateSetter setDialogState) {
    return ListTile(
      leading: const Icon(Icons.folder, size: 20, color: Colors.grey),
      title: Text(name, style: const TextStyle(fontSize: 14)),
      onTap: () {
        // Check if we have metadata for this folder (Bypass Logic)
        if (_folderMetadata.containsKey(name)) {
          final data = _folderMetadata[name]!;
          
          setState(() {
            _sessionDetails['folder'] = name;
            _sessionDetails['name'] = data['name'];
            _sessionDetails['age'] = data['age'];
            _sessionDetails['year'] = data['year'];
            _sessionDetails['gender'] = data['gender'];
            _sessionDetails['phone'] = data['phone'];
            _sessionDetails['address'] = data['address'];
            
            // Note: date format might need adjustment if storing object vs string
            // For now assuming we just restart session with these details
            
            _hasShownSessionDetails = true;
            _selectedNavIndex = 2; // Go to Record
          });
          
          Navigator.of(context).pop();
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Session started for folder "$name"'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          // Legacy behavior for folders without metadata (just fill text field)
          _folderController.text = name;
        }
      },
    );
  }

  Widget _buildTextField(TextEditingController controller, String label, IconData icon, {bool isNumber = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: TextField(
        controller: controller,
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: const Color(0xFF81C784)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF81C784)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF81C784)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Soft green background - lighter and easier on the eyes
      backgroundColor: const Color(0xFFF1F8F4), // Very light soft green
      body: SafeArea(
        child: Stack(
          children: [
            // Main content area
            Column(
              children: [
                Expanded(
                  child: _selectedNavIndex == 0 
                    ? _buildHomePage()
                    : _selectedNavIndex == 1
                      ? _buildStoragePage()
                      : _selectedNavIndex == 2
                        ? SingleChildScrollView(
                            physics: const ClampingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 100.0), // Extra bottom padding for navbar
                            child: Column(
                              children: [
                                const SizedBox(height: 20),
                                
                                // App Title
                                const Text(
                                  'Audio Recorder',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2E7D32), // Dark green
                              ),
                            ),
                            const SizedBox(height: 10),
                            
                            // Waveform Visualizer
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.black87, // Black border
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.green.withOpacity(0.1),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: WaveformVisualizer(
                                level: _currentLevel,
                                isRecording: _isRecording,
                              ),
                            ),
                            
                            const SizedBox(height: 30),
                            
                            // Recording Duration Timer (Above Recording Button)
                            Text(
                              _formatDuration(_recordingDuration),
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF424242),
                                fontFamily: 'monospace',
                                letterSpacing: 1,
                              ),
                            ),
                            
                            const SizedBox(height: 16),
                            
                            // Record Controls
                            if (!_isRecording)
                              // Simple Start Button
                              RecordButton(
                                isRecording: false,
                                onPressed: _toggleRecording,
                              )
                            else
                              // Controls when recording: Pause/Resume + Stop
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // Pause/Resume Button
                                  Container(
                                    height: 60,
                                    width: 60,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.orange,
                                        width: 2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.orange.withOpacity(0.2),
                                          blurRadius: 8,
                                          spreadRadius: 1,
                                        ),
                                      ],
                                    ),
                                    child: IconButton(
                                      icon: Icon(
                                        _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                        size: 32,
                                        color: Colors.orange,
                                      ),
                                      onPressed: _togglePause,
                                    ),
                                  ),
                                  
                                  const SizedBox(width: 30),
                                  
                                  // Stop Button (using RecordButton style but strict stop)
                                  RecordButton(
                                    isRecording: true,
                                    onPressed: _toggleRecording, // This stops it
                                  ),
                                ],
                              ),
                            
                            const SizedBox(height: 20),
                            
                            // Real-time Transcription Box (Dummy for now)
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(
                                minHeight: 120, // Minimum height for the transcription box
                              ),
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: const Color(0xFF81C784), // Light green
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.green.withOpacity(0.1),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: const [
                                      Icon(
                                        Icons.transcribe,
                                        color: Color(0xFF2E7D32),
                                        size: 20,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Real-time Transcription',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF2E7D32),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 15),
                                  Text(
                                    _isRecording 
                                      ? 'Transcription will appear here...'
                                      : 'Start recording to see transcription',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey[600],
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                            const SizedBox(height: 20),
                          ],
                        ),
                      )
                    : _selectedNavIndex == 3
                      ? _buildInfoPage()
                      : _buildAboutPage(),
                ),
              ],
            ),
            
            // Bottom Navigation Bar
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.green.withOpacity(0.2),
                          blurRadius: 10,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            // 0. Home
                            _buildNavItem(
                              icon: Icons.home_outlined,
                              label: 'Home',
                              index: 0,
                            ),
                            
                            // 1. Storage
                            _buildNavItem(
                              icon: Icons.folder_open_outlined,
                              label: 'Storage',
                              index: 1,
                            ),
                            
                            // 2. Record (Center)
                            _buildNavItem(
                              icon: Icons.mic_none_outlined,
                              label: 'Record',
                              index: 2,
                            ),
                            
                            // 3. Info
                            _buildNavItem(
                              icon: Icons.info_outline,
                              label: 'Info',
                              index: 3,
                            ),
                            
                            // 4. About
                            _buildNavItem(
                              icon: Icons.person_outline,
                              label: 'About',
                              index: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            // Audio Player - anchored above navbar (Storage page only)
            if (_selectedNavIndex == 1 && _selectedAudioName != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 80, // Position above the navbar (navbar height ~80px)
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: _buildAudioPlayer(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
  }) {
    final isSelected = _selectedNavIndex == index;
    return InkWell(
      onTap: () {
        // Always show session details dialog when navigating to Record page
        if (index == 2) {
          _showSessionDetailsDialog();
        } else {
          setState(() {
            // Stop audio if switching away from Storage page
            if (_selectedNavIndex == 1 && index != 1 && _selectedAudioName != null) {
              _stopAudio();
            }
            _selectedNavIndex = index;
          });
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 28,
              color: isSelected 
                ? const Color(0xFF2E7D32) // Dark green when selected
                : Colors.grey[400],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isSelected 
                  ? const Color(0xFF2E7D32)
                  : Colors.grey[400],
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Home Page
  Widget _buildHomePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20.0, 20.0, 20.0, 100.0), // Extra bottom padding for navbar
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          
          // Welcome Header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF2E7D32), Color(0xFF66BB6A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withOpacity(0.3),
                  blurRadius: 15,
                  spreadRadius: 2,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.waving_hand, color: Colors.white, size: 28),
                    SizedBox(width: 10),
                    Text(
                      'Welcome Back!',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Ready to record your next session?',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.9),
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Summary Stats Cards
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  'Total Recordings',
                  '24',
                  Icons.audiotrack,
                  const Color(0xFF4CAF50),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  'Total Duration',
                  '3h 45m',
                  Icons.access_time,
                  const Color(0xFF2196F3),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  'Folders',
                  '8',
                  Icons.folder,
                  const Color(0xFFFF9800),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  'Storage Used',
                  '156 MB',
                  Icons.storage,
                  const Color(0xFF9C27B0),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 28),
          
          // Feature Carousel
          const Text(
            'Quick Guide',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2E7D32),
            ),
          ),
          const SizedBox(height: 12),
          
          SizedBox(
            height: 180,
            child: PageView(
              children: [
                _buildCarouselCard(
                  'Record High Quality Audio',
                  'Tap the Record tab to start capturing crystal-clear audio for your projects.',
                  Icons.mic,
                  const Color(0xFF4CAF50),
                ),
                _buildCarouselCard(
                  'Organize with Folders',
                  'Keep your recordings organized by creating folders for different projects.',
                  Icons.folder_special,
                  const Color(0xFF2196F3),
                ),
                _buildCarouselCard(
                  'Playback & Share',
                  'Listen to your recordings anytime and share them easily with others.',
                  Icons.play_circle,
                  const Color(0xFFFF9800),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 28),
          
          // Tabbed Content
          DefaultTabController(
            length: 3,
            child: Column(
              children: [
                TabBar(
                  labelColor: const Color(0xFF2E7D32),
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: const Color(0xFF2E7D32),
                  tabs: const [
                    Tab(text: 'Recent'),
                    Tab(text: 'Tips'),
                    Tab(text: 'Actions'),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 250,
                  child: TabBarView(
                    children: [
                      _buildRecentTab(),
                      _buildTipsTab(),
                      _buildActionsTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 28),
          
          // Anxiety Education Section
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.blue.shade50, Colors.purple.shade50],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.blue.shade200, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.psychology, color: Colors.blue.shade700, size: 28),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Understanding Anxiety',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Anxiety affects how people think, feel, and behave. Understanding its various forms can help in recognition and support.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[700],
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                
                // Interactive Info Buttons Grid
                GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.1,
                  children: [
                    _buildAnxietyButton(
                      'Types of Anxiety',
                      Icons.category,
                      Colors.blue,
                      () => _showAnxietyTypesDialog(),
                    ),
                    _buildAnxietyButton(
                      'Severity Levels',
                      Icons.trending_up,
                      Colors.orange,
                      () => _showSeverityDialog(),
                    ),
                    _buildAnxietyButton(
                      'Educational Issues',
                      Icons.school,
                      Colors.purple,
                    () => _showEducationalIssuesDialog(),
                    ),
                    _buildAnxietyButton(
                      'Associated Emotions',
                      Icons.mood,
                      Colors.pink,
                      () => _showEmotionsDialog(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnxietyButton(String title, IconData icon,Color color, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.3), width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.1),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 32),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAnxietyTypesDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Types of Anxiety Disorders',
          style: TextStyle(color: Color(0xFF1565C0), fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '📊 Most Common Types:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey[800]),
              ),
              const SizedBox(height: 8),
              
              _buildAnxietyDetail('1. GAD (Generalized Anxiety Disorder)', '~6.8% of adults', 'Persistent, excessive worry about various aspects of life.'),
              _buildAnxietyDetail('2. Social Anxiety', '~7.1% of adults', 'Intense fear of social situations and being judged by others.'),
              _buildAnxietyDetail('3. Panic Disorder', '~2-3% of adults', 'Recurrent, unexpected panic attacks with physical symptoms.'),
              _buildAnxietyDetail('4. PTSD', '~3.6% of adults', 'Triggered by traumatic events, causing flashbacks and hypervigilance.'),
              _buildAnxietyDetail('5. Agoraphobia', '~1.7% of adults', 'Fear of places where escape might be difficult.'),
              _buildAnxietyDetail('6. Neutral/Normal', 'Most common', 'Typical stress responses to life challenges.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSeverityDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Anxiety Severity Levels',
          style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '📈 Understanding Impact Levels:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey[800]),
              ),
              const SizedBox(height: 8),
              
              _buildSeverityDetail('Normal/Mild', '~60-70%', Colors.green, 
                'Manageable daily stress. Occasional worry that doesn\'t interfere with daily activities. Most people function well.'),
              _buildSeverityDetail('Moderate', '~20-25%', Colors.orange,
                'Noticeable impact on daily life. Difficulty concentrating, sleep disturbances, and some avoidance behaviors. May need support.'),
              _buildSeverityDetail('Severe', '~10-15%', Colors.red,
                'Significant impairment. Major impact on work, relationships, and daily functioning. Professional help strongly recommended.'),
              
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '💡 Note: Severity can fluctuate over time and with different stressors. Early intervention at moderate levels can prevent escalation.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showEducationalIssuesDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Educational Anxiety Issues',
          style: TextStyle(color: Colors.purple, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '🎓 Top Educational Stressors (By Prevalence):',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey[800]),
              ),
              const SizedBox(height: 8),
              
              _buildAnxietyDetail('1. Test Anxiety', '~25-40% of students', 'Excessive worry before and during exams, affecting performance despite preparation.'),
              _buildAnxietyDetail('2. Fear of Failure', '~30-35% of students', 'Intense worry about not meeting expectations, leading to perfectionism or avoidance.'),
              _buildAnxietyDetail('3. Pressure of Surroundings', '~28-32% of students', 'Stress from family expectations, peer comparison, and competitive environments.'),
              _buildAnxietyDetail('4. Academic Burnout', '~40-50% at some point', 'Mental and physical exhaustion from prolonged academic stress.'),
              _buildAnxietyDetail('5. Low Self-Esteem', '~20-25% of students', 'Negative self-perception affecting academic confidence and participation.'),
              _buildAnxietyDetail('6. Lack of Support', '~15-20% of students', 'Insufficient guidance from teachers, parents, or peers in academic journey.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showEmotionsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Emotions in Anxiety',
          style: TextStyle(color: Colors.pink, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '😊 Common Emotional Responses:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey[800]),
              ),
              const SizedBox(height: 8),
              
              _buildEmotionDetail('Fearful', '😨', 'Most common in anxiety', 'Experiencing worry, dread, or apprehension about future events.'),
              _buildEmotionDetail('Sad', '😢', 'Often co-occurs', 'Low mood, unhappiness, or feelings of hopelessness.'),
              _buildEmotionDetail('Angry', '😠', 'Frustration response', 'Irritability, frustration, or rage often masking underlying fear.'),
              _buildEmotionDetail('Calm', '😌', 'Recovery state', 'Peaceful, relaxed state - the goal of anxiety management.'),
              _buildEmotionDetail('Happy', '😊', 'Positive state', 'Joyful feelings, contentment, and well-being.'),
              _buildEmotionDetail('Surprise', '😲', 'Situational', 'Unexpected emotional responses to sudden changes.'),
              _buildEmotionDetail('Disgust', '🤢', 'Less common', 'Strong aversion, often related to specific phobias.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildAnxietyDetail(String title, String prevalence, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  prevalence,
                  style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildSeverityDetail(String level, String prevalence, Color color, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    level,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: color),
                  ),
                ),
                Text(
                  prevalence,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmotionDetail(String emotion, String emoji, String frequency, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      emotion,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '($frequency)',
                      style: TextStyle(fontSize: 10, color: Colors.grey[600], fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF424242),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarouselCard(String title, String description, IconData icon, Color color) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, color.withOpacity(0.7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.3),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 48),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withOpacity(0.9),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildRecentTab() {
    return ListView(
      children: [
        _buildRecentItem('Meeting_Notes.m4a', 'Today, 2:30 PM', '45:20'),
        _buildRecentItem('Interview_Session.m4a', 'Yesterday, 10:15 AM', '32:10'),
        _buildRecentItem('Podcast_Ep5.m4a', 'Dec 10, 3:45 PM', '1:12:30'),
      ],
    );
  }

  Widget _buildRecentItem(String name, String date, String duration) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF2E7D32).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.audiotrack, color: Color(0xFF2E7D32), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  date,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          Text(
            duration,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2E7D32),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTipsTab() {
    return ListView(
      children: [
        _buildTipItem(
          'Use headphones for monitoring',
          'Wear headphones while recording to avoid feedback and monitor audio quality.',
          Icons.headset,
        ),
        _buildTipItem(
          'Find a quiet environment',
          'Record in a quiet room to minimize background noise and improve clarity.',
          Icons.volume_off,
        ),
        _buildTipItem(
          'Keep your device stable',
          'Place your phone on a stable surface to reduce handling noise.',
          Icons.phone_android,
        ),
      ],
    );
  }

  Widget _buildTipItem(String title, String description, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF81C784).withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: const Color(0xFF4CAF50), size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Color(0xFF2E7D32),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsTab() {
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.3,
      children: [
        _buildActionCard('New Recording', Icons.fiber_manual_record, const Color(0xFFE53935)),
        _buildActionCard('Browse Files', Icons.folder_open, const Color(0xFF1E88E5)),
        _buildActionCard('Settings', Icons.settings, const Color(0xFF43A047)),
        _buildActionCard('Help', Icons.help_outline, const Color(0xFFFB8C00)),
      ],
    );
  }

  Widget _buildActionCard(String title, IconData icon, Color color) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.2),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {},
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 32),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[800],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureItem(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF2E7D32), size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF424242),
            ),
          ),
        ),
      ],
    );
  }

  // Storage Page (Dummy with Folders)
  Widget _buildStoragePage() {
    // Filter folders based on search query
    final filteredFolders = _allFolders.entries.where((entry) {
      return entry.key.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 100.0), // Extra bottom padding for navbar clearance
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          
          // Storage header with delete button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Storage',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2E7D32),
                ),
              ),
              IconButton(
                icon: Icon(
                  _isDeleteMode ? Icons.close : Icons.delete_outline,
                  color: _isDeleteMode ? Colors.red[700] : const Color(0xFF2E7D32),
                ),
                onPressed: () {
                  setState(() {
                    _isDeleteMode = !_isDeleteMode;
                  });
                },
                tooltip: _isDeleteMode ? 'Cancel Delete' : 'Delete Folders',
              ),
            ],
          ),
          const SizedBox(height: 20),
          
          // Search Bar
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withOpacity(0.1),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: 'Search folders...',
                hintStyle: TextStyle(color: Colors.grey[400]),
                prefixIcon: const Icon(
                  Icons.search,
                  color: Color(0xFF2E7D32),
                ),
                suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.grey),
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Display filtered folders or "no results" message
          if (filteredFolders.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(40.0),
                child: Column(
                  children: [
                    Icon(
                      Icons.folder_off_outlined,
                      size: 64,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No folders found',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Try a different search term',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[400],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ...filteredFolders.asMap().entries.map((entry) {
              final index = entry.key;
              final folderEntry = entry.value;
              final folderName = folderEntry.key;
              final fileList = folderEntry.value;
              
              // Convert data maps to widgets
              final widgetList = fileList.map((fileData) {
                return _buildStorageItem(
                  fileData['name']!,
                  fileData['duration']!,
                  fileData['date']!,
                  fileData['size']!,
                  folderName, // Pass folder name for deletion
                  fileData['path'] ?? '', // Pass file path
                  fileData['id'] ?? '', // Pass id
                );
              }).toList();

              return Column(
                children: [
                  if (index > 0) const SizedBox(height: 16),
                  _buildStorageFolder(folderName, widgetList),
                ],
              );
            }).toList(),
        ],
      ),
    );
  }

  Widget _buildStorageFolder(String folderName, List<Widget> items) {
    return Container(
      decoration: BoxDecoration(
        color: _isDeleteMode ? const Color(0xFFFFCDD2) : Colors.white, // Light soft red in delete mode
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.05),
            blurRadius: 5,
            spreadRadius: 1,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: _isDeleteMode 
            ? Colors.red.withOpacity(0.3) 
            : const Color(0xFF81C784).withOpacity(0.3),
        ),
      ),
      child: ExpansionTile(
        leading: Icon(
          Icons.folder, 
          color: _isDeleteMode ? Colors.red[700] : const Color(0xFF2E7D32), 
          size: 30,
        ),
        title: Text(
          folderName,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: _isDeleteMode ? Colors.red[900] : const Color(0xFF424242),
          ),
        ),
        subtitle: Text(
          '${items.length} files',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        onExpansionChanged: (expanded) {
          if (_isDeleteMode && !expanded) {
            // Show delete confirmation when in delete mode
            _showDeleteFolderDialog(folderName);
          }
        },
        iconColor: _isDeleteMode ? Colors.red[700] : const Color(0xFF2E7D32),
        collapsedIconColor: _isDeleteMode ? Colors.red[700] : const Color(0xFF2E7D32),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        collapsedShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        childrenPadding: const EdgeInsets.all(8),
        children: items,
      ),
    );
  }

  Widget _buildStorageItem(String name, String duration, String date, String fileSize, String folderName, String path, String id) {
    return InkWell(
      onTap: () {
        // Play audio when clicking the item (unless in delete mode)
        if (!_isDeleteMode) {
          _playAudio(name, duration, path);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F8F4), // Light green background for items
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.audiotrack, color: Color(0xFF2E7D32), size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarqueeText(
                    text: name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Color(0xFF2E7D32),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    date,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Duration and File Size stacked vertically on the right
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  duration,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF424242),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  fileSize,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Show delete icon in delete mode, otherwise show play icon
            if (_isDeleteMode)
              IconButton(
                icon: Icon(Icons.delete, color: Colors.red[700]),
                onPressed: () => _showDeleteFileDialog(name, folderName, id),
              )
            else
              // Only show play icon if NOT playing this specific audio
              if (_selectedAudioName != name)
                Icon(Icons.play_circle_fill, color: const Color(0xFF2E7D32).withOpacity(0.8), size: 28)
              else
                 // Show pause/stop controls or visualizer indicator if playing
                Icon(Icons.graphic_eq, color: const Color(0xFF2E7D32), size: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioPlayer() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2E7D32), width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.15),
            blurRadius: 12,
            spreadRadius: 2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Audio name and Results button
          Row(
            children: [
              const Icon(Icons.audiotrack, color: Color(0xFF2E7D32), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: MarqueeText(
                  text: _selectedAudioName ?? '',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2E7D32),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Results feature coming soon!'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.assessment, size: 16),
                label: const Text('Results'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF2E7D32),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          
          // Progress bar
          Column(
            children: [
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: const Color(0xFF2E7D32),
                  inactiveTrackColor: Colors.grey[300],
                  thumbColor: const Color(0xFF2E7D32),
                  overlayColor: const Color(0xFF2E7D32).withOpacity(0.2),
                ),
                child: Slider(
                  value: _currentPosition.inMilliseconds.toDouble().clamp(0.0, _totalDuration.inMilliseconds.toDouble()),
                  min: 0,
                  max: _totalDuration.inMilliseconds.toDouble() > 0 ? _totalDuration.inMilliseconds.toDouble() : 1.0, 
                  onChanged: _seekAudio,
                ),
              ),
              
              // Time displays
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_currentPosition),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      _formatDuration(_totalDuration),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          
          // Playback controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Play/Pause button
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF2E7D32).withOpacity(0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: IconButton(
                  icon: Icon(
                    _isPausedPlayer ? Icons.play_arrow : Icons.pause,
                    color: Colors.white,
                    size: 28,
                  ),
                  onPressed: _isPausedPlayer ? _resumeAudio : _pauseAudio,
                ),
              ),
              
              const SizedBox(width: 20),
              
              // Stop button
              Container(
                decoration: BoxDecoration(
                  color: Colors.red[600],
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.stop,
                    color: Colors.white,
                    size: 28,
                  ),
                  onPressed: _stopAudio,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Info Page (Dummy)
  Widget _buildInfoPage() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 100.0), // Extra bottom padding for navbar
        child: Column(
          children: [
            const SizedBox(height: 40),
            Icon(
              Icons.info_outline,
              size: 80,
              color: const Color(0xFF2E7D32),
            ),
            const SizedBox(height: 20),
            const Text(
              'Information',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2E7D32),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'This application allows you to record high-quality audio with real-time visualization.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Color(0xFF424242),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),
            _buildInfoCard(Icons.mic, 'High Quality Recording', 'Crystal clear audio capture.'),
            const SizedBox(height: 16),
            _buildInfoCard(Icons.graphic_eq, 'Visual Feedback', 'Real-time dB level monitoring.'),
            const SizedBox(height: 16),
            _buildInfoCard(Icons.security, 'Secure Storage', 'Your recordings are saved locally.'),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(IconData icon, String title, String description) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.05),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, size: 32, color: const Color(0xFF2E7D32)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2E7D32),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // About/Settings Page
  Widget _buildAboutPage() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 100.0), // Extra bottom padding for navbar
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            const Text(
              'About',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2E7D32),
              ),
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.info, color: Color(0xFF2E7D32)),
              title: const Text('Version'),
              subtitle: const Text('1.0.0'),
            ),
            ListTile(
              leading: const Icon(Icons.email, color: Color(0xFF2E7D32)),
              title: const Text('Contact'),
              subtitle: const Text('support@audiorecorder.com'),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip, color: Color(0xFF2E7D32)),
              title: const Text('Privacy Policy'),
            ),
            ListTile(
              leading: const Icon(Icons.article, color: Color(0xFF2E7D32)),
              title: const Text('Terms of Service'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingItem(IconData icon, String title, String subtitle) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.05),
            blurRadius: 5,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFF2E7D32)),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Color(0xFF2E7D32),
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
        trailing: Icon(
          Icons.arrow_forward_ios,
          size: 16,
          color: Colors.grey[400],
        ),
        onTap: () {
          // TODO: Implement setting action
        },
      ),
    );
  }
}
