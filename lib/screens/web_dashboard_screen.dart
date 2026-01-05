import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:html' as html;
import 'dart:math';
import 'dart:async';
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../services/firebase_service.dart';
import '../services/audio_recorder_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:record/record.dart';
import '../widgets/waveform_visualizer.dart';

class WebDashboardScreen extends StatefulWidget {
  const WebDashboardScreen({super.key});

  @override
  State<WebDashboardScreen> createState() => _WebDashboardScreenState();
}

class _WebDashboardScreenState extends State<WebDashboardScreen> {
  int _selectedIndex = 0;
  
  // Data from Firebase
  Map<String, List<Map<String, dynamic>>> _allFolders = {};
  List<Map<String, dynamic>> _clients = [];
  bool _isLoading = true;
  String? _currentAdminId; // Store current Admin ID
  String _adminFullName = 'Admin'; // Store current admin's full name

  // Selected recording for analysis view
  Map<String, dynamic>? _selectedAnalysisRecording;
  
  // Selected recording for waveform visualization on overview
  Map<String, dynamic>? _selectedWaveformRecording;
  
  // Biomarker results from Firebase for analytics
  List<Map<String, dynamic>> _biomarkerResults = [];

  // Recording state variables
  bool _isRecording = false;
  bool _isPaused = false;
  bool _isPlaying = false;
  int _recordingDuration = 0; // in seconds
  Timer? _recordingTimer;
  
  // Audio Recorder Service
  final AudioRecorderService _audioService = AudioRecorderService();

  StreamSubscription<double>? _amplitudeSub;
  List<double> _amplitudeLevels = []; // For visualization
  double _currentAmplitude = 0.0; // For WaveformVisualizer
  
  // Selected folder/client for recording
  String? _selectedFolderName;
  bool _hasShownClientDialog = false; // Prevents repeated dialog on rebuild

  // Web Speech Recognition
  html.SpeechRecognition? _speechRecognition;
  String _currentTranscript = "";
  bool _isSpeechAvailable = false;
  
  // Real-time Audio Visualization
  List<double> _audioWaveform = List.filled(50, 0.0);

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _initializeApp();
  }

  void _initSpeech() {
    if (html.SpeechRecognition.supported) {
      _speechRecognition = html.SpeechRecognition();
      _speechRecognition!.continuous = true;
      _speechRecognition!.interimResults = true;
      _speechRecognition!.lang = 'en-US'; // Default to English (US)
      
      _speechRecognition!.onResult.listen((event) {
        if (event.results == null) return;
        
        String finalTranscript = "";
        String interimTranscript = "";
        
        // Critical Fix: Iterate from 0 to capture full session transcript
        // Previous logic (event.resultIndex) dropped early sentences
        for (var i = 0; i < event.results!.length; ++i) {
          if (event.results![i].isFinal!) {
            finalTranscript += event.results![i].item(0)!.transcript!;
          } else {
            interimTranscript += event.results![i].item(0)!.transcript!;
          }
        }
        
        if (mounted) {
          setState(() {
            _currentTranscript = finalTranscript + interimTranscript;
          });
        }
      });
      
      _speechRecognition!.onError.listen((event) {
        print("Speech Recognition Error: ${event.error}");
      });
      
      setState(() {
        _isSpeechAvailable = true;
      });
    } else {
      print("Web Speech API not supported in this browser.");
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _amplitudeSub?.cancel();
    _audioService.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    // 1. Fetch Admin ID and Info first
    _currentAdminId = await FirebaseService.getCurrentAdminId();
    final adminInfo = await FirebaseService.getCurrentAdminInfo();
    if (adminInfo != null) {
      _adminFullName = adminInfo['full_name'] ?? 'Admin';
    }
    if (mounted) {
      if (_currentAdminId == null) {
        // Should likely logout if cant find admin ID, but let's handle gracefully
        print("Error: No Admin ID found for current user on Web");
      }
      setState(() {});
      
      // 2. Setup Listeners (only after we have ID)
      if (_currentAdminId != null) {
        _setupRealtimeListener();
        _setupClientListener();
        _setupBiomarkerListener();
      } else {
        setState(() => _isLoading = false);
      }
    }
  }

  void _setupRealtimeListener() {
    // Real-time listener for auto-refresh when new recordings are added
    if (_currentAdminId == null) {
      print('⚠️ No admin ID - skipping recordings listener');
      return;
    }
    
    print('🔄 Setting up recordings listener for admin: $_currentAdminId');
    
    // Query WITHOUT orderBy to avoid composite index requirement
    FirebaseFirestore.instance
        .collection('recordings')
        .where('admin_id', isEqualTo: _currentAdminId) // Filter by Admin ID
        .snapshots()
        .listen((snapshot) {
      print('📦 Received ${snapshot.docs.length} recordings from Firebase');
      
      Map<String, List<Map<String, dynamic>>> loadedFolders = {};

      for (var doc in snapshot.docs) {
        final data = doc.data();
        String folderName = data['folder_name'] ?? 'Uncategorized';
        
        if (!loadedFolders.containsKey(folderName)) {
          loadedFolders[folderName] = [];
        }
        
        loadedFolders[folderName]!.add({
          'id': doc.id,
          'name': data['file_name'] ?? '',
          'duration': data['duration'] ?? '00:00:00',
          'date': data['date'] ?? '',
          'size': data['size'] ?? '0 B',
          'path': data['file_path'] ?? '',
          'transcription': data['transcription'] ?? '',
          'folder_name': folderName, // Critical for client lookup
          'waveform_data': data['waveform_data'], // Added waveform data
        });
      }
      
      // Sort each folder's recordings by date (locally, to avoid index requirement)
      loadedFolders.forEach((folder, recordings) {
        recordings.sort((a, b) {
           final aDate = a['date'];
           final bDate = b['date'];
           // Handle mixed types (Timestamp vs String) safely by converting to String
           return (bDate?.toString() ?? '').compareTo(aDate?.toString() ?? '');
        });
      });

      if (mounted) {
        setState(() {
          _allFolders = loadedFolders;
          _isLoading = false;
        });
        print('✅ Loaded ${_getTotalRecordings()} recordings in ${loadedFolders.length} folders');
      }
    }, onError: (e) {
      print('❌ Error loading recordings from Firebase: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    });
  }

  void _setupClientListener() {
    // Real-time listener for client info
    if (_currentAdminId == null) return;

    FirebaseFirestore.instance
        .collection('client_info')
        .where('admin_id', isEqualTo: _currentAdminId) // Filter by Admin ID
        .snapshots()
        .listen((snapshot) {
      print('📋 Client info snapshot received: ${snapshot.docs.length} clients');
      
      final clients = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
      
      // Sort by created_at locally (in case Firestore index not set)
      // Sort by created_at locally (in case Firestore index not set)
      clients.sort((a, b) {
        final aRaw = a['created_at'];
        final bRaw = b['created_at'];
        if (aRaw == null && bRaw == null) return 0;
        if (aRaw == null) return 1;
        if (bRaw == null) return -1;
        
        if (aRaw is Timestamp && bRaw is Timestamp) {
          return bRaw.compareTo(aRaw);
        }
        // Fallback for String or mismatch
        return bRaw.toString().compareTo(aRaw.toString());
      });

      if (mounted) {
        setState(() {
          _clients = clients;
        });
      }
    }, onError: (e) {
      print('❌ Error loading clients from Firebase: $e');
    });
  }

  void _setupBiomarkerListener() {
    // Real-time listener for biomarker analysis results
    if (_currentAdminId == null) return;
    
    print('🔬 Setting up biomarker results listener for admin: $_currentAdminId');
    
    FirebaseFirestore.instance
        .collection('biomarker_results')
        .where('admin_id', isEqualTo: _currentAdminId)
        .snapshots()
        .listen((snapshot) {
      print('📊 Received ${snapshot.docs.length} biomarker results from Firebase');
      
      final results = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        // Debug: Log each biomarker result's identifiers
        print('  🔬 Biomarker: recording_id=${data['recording_id']}, file_name=${data['file_name']}, folder=${data['folder_name']}');
        return data;
      }).toList();
      
      if (mounted) {
        setState(() {
          _biomarkerResults = results;
        });
        print('📊 Total biomarker results loaded: ${results.length}');
      }
    }, onError: (e) {
      print('❌ Error loading biomarker results from Firebase: $e');
    });
  }

  // Helper methods for statistics
  int _getTotalRecordings() {
    int total = 0;
    _allFolders.forEach((_, recordings) {
      total += recordings.length;
    });
    return total;
  }

  String _getTotalDuration() {
    int totalSeconds = 0;
    _allFolders.forEach((_, recordings) {
      for (var recording in recordings) {
        final durationStr = recording['duration'] ?? '00:00:00';
        final parts = durationStr.split(':');
        if (parts.length == 3) {
          totalSeconds += (int.tryParse(parts[0]) ?? 0) * 3600;
          totalSeconds += (int.tryParse(parts[1]) ?? 0) * 60;
          totalSeconds += int.tryParse(parts[2]) ?? 0;
        } else if (parts.length == 2) {
          totalSeconds += (int.tryParse(parts[0]) ?? 0) * 60;
          totalSeconds += int.tryParse(parts[1]) ?? 0;
        }
      }
    });
    
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    
    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  String _getTotalStorageUsed() {
    double totalBytes = 0;
    _allFolders.forEach((_, recordings) {
      for (var recording in recordings) {
        final sizeStr = recording['size'] ?? '0 B';
        final parts = sizeStr.split(' ');
        if (parts.length == 2) {
          final value = double.tryParse(parts[0]) ?? 0;
          final unit = parts[1].toUpperCase();
          if (unit == 'B') {
            totalBytes += value;
          } else if (unit == 'KB') {
            totalBytes += value * 1024;
          } else if (unit == 'MB') {
            totalBytes += value * 1024 * 1024;
          } else if (unit == 'GB') {
            totalBytes += value * 1024 * 1024 * 1024;
          }
        }
      }
    });
    
    if (totalBytes < 1024) return '${totalBytes.toInt()} B';
    if (totalBytes < 1024 * 1024) return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    if (totalBytes < 1024 * 1024 * 1024) return '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _getPageTitle() {
    switch (_selectedIndex) {
      case 0: return 'Dashboard Overview';
      case 1: return 'Analytics';
      case 2: return 'Recordings';
      case 3: return 'Settings';
      default: return 'Dashboard';
    }
  }

  bool _isDragging = false;
  
  Widget _buildAudioDropZone(List<String> folders) {
    return StatefulBuilder(
      builder: (context, setDropState) {
        return MouseRegion(
          onEnter: (_) => setDropState(() => _isDragging = false),
          child: DragTarget<Object>(
            onWillAcceptWithDetails: (data) {
              setDropState(() => _isDragging = true);
              return true;
            },
            onLeave: (data) {
              setDropState(() => _isDragging = false);
            },
            onAcceptWithDetails: (data) {
              setDropState(() => _isDragging = false);
              // Handle file drop would go here
            },
            builder: (context, candidateData, rejectedData) {
              return GestureDetector(
                onTap: () => _pickAndUploadAudio(folders),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.all(30),
                  decoration: BoxDecoration(
                    color: _isDragging ? const Color(0xFFE8F5E9) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isDragging ? const Color(0xFF2E7D32) : Colors.grey[300]!,
                      width: 2,
                      style: BorderStyle.solid,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined,
                        size: 48,
                        color: _isDragging ? const Color(0xFF2E7D32) : Colors.grey[400],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isDragging ? 'Drop audio file here!' : 'Click or drag audio file to upload',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: _isDragging ? const Color(0xFF2E7D32) : Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Supports WAV, MP3, M4A files',
                        style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _pickAndUploadAudio(List<String> folders) {
    final html.FileUploadInputElement uploadInput = html.FileUploadInputElement();
    uploadInput.accept = 'audio/*,.wav,.mp3,.m4a';
    uploadInput.click();
    
    uploadInput.onChange.listen((e) {
      final files = uploadInput.files;
      if (files != null && files.isNotEmpty) {
        final file = files.first;
        _showFolderSelectionDialog(file, folders);
      }
    });
  }

  void _showFolderSelectionDialog(html.File? file, List<String> folders) {
    // If file is null, we are just selecting a folder for recording
    String? selectedFolder;
    
    // Form controllers for new client
    final nameController = TextEditingController();
    final ageController = TextEditingController();
    final phoneController = TextEditingController();
    final addressController = TextEditingController();
    final folderNameController = TextEditingController();
    
    String selectedGender = 'Male';
    String selectedSchoolYear = 'Grade 11';
    DateTime selectedBirthday = DateTime.now().subtract(const Duration(days: 365 * 16)); // Default 16 yo
    
    showDialog(
      context: context,
      barrierDismissible: false, // Force selection
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return DefaultTabController(
            length: 2,
            child: AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(file != null ? Icons.upload_file : Icons.mic, color: const Color(0xFF2E7D32)),
                  ),
                  const SizedBox(width: 12),
                  const Text('Select Client', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SizedBox(
                width: 500,
                height: 500,
                child: Column(
                  children: [
                    const TabBar(
                      labelColor: Color(0xFF2E7D32),
                      unselectedLabelColor: Colors.grey,
                      indicatorColor: Color(0xFF2E7D32),
                      tabs: [
                        Tab(text: 'Existing Client'),
                        Tab(text: 'Create New'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // Tab 1: Existing Clients
                          Column(
                            children: [
                              TextField(
                                decoration: InputDecoration(
                                  hintText: 'Search clients...',
                                  prefixIcon: const Icon(Icons.search),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                                ),
                                onChanged: (val) {
                                  // Implement filtering locally if needed
                                },
                              ),
                              const SizedBox(height: 12),
                              Expanded(
                                child: folders.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.folder_off, size: 40, color: Colors.grey[300]),
                                            const SizedBox(height: 8),
                                            const Text('No clients found', style: TextStyle(color: Colors.grey)),
                                          ],
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: folders.length,
                                        itemBuilder: (context, index) {
                                          final folder = folders[index];
                                          final isSelected = selectedFolder == folder;
                                          return ListTile(
                                            leading: CircleAvatar(
                                              backgroundColor: isSelected ? const Color(0xFF2E7D32) : Colors.grey[200],
                                              child: Icon(Icons.person, color: isSelected ? Colors.white : Colors.grey[500]),
                                            ),
                                            title: Text(folder, style: const TextStyle(fontWeight: FontWeight.w500)),
                                            selected: isSelected,
                                            selectedTileColor: const Color(0xFFF1F8F4),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                            onTap: () => setDialogState(() => selectedFolder = folder),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                          
                          // Tab 2: Create New Client
                          SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Client Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                const SizedBox(height: 12),
                                // Folder Name (Unique ID)
                                TextField(
                                  controller: folderNameController,
                                  decoration: const InputDecoration(
                                    labelText: 'Folder Name (Unique ID)',
                                    border: OutlineInputBorder(),
                                    helperText: 'e.g. John Doe',
                                  ),
                                ),
                                const SizedBox(height: 12),
                                // Full Name
                                TextField(
                                  controller: nameController,
                                  decoration: const InputDecoration(
                                    labelText: 'Full Name',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.badge_outlined),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: ageController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'Age',
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        value: selectedGender,
                                        decoration: const InputDecoration(
                                          labelText: 'Gender',
                                          border: OutlineInputBorder(),
                                        ),
                                        items: ['Male', 'Female', 'Prefer not to say']
                                            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                                            .toList(),
                                        onChanged: (val) => setDialogState(() => selectedGender = val!),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                // Birthday Picker
                                InkWell(
                                  onTap: () async {
                                    final date = await showDatePicker(
                                      context: context,
                                      initialDate: selectedBirthday,
                                      firstDate: DateTime(1900),
                                      lastDate: DateTime.now(),
                                    );
                                    if (date != null) {
                                      setDialogState(() => selectedBirthday = date);
                                    }
                                  },
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Birthday',
                                      border: OutlineInputBorder(),
                                      prefixIcon: Icon(Icons.cake_outlined),
                                    ),
                                    child: Text(
                                      "${selectedBirthday.year}-${selectedBirthday.month.toString().padLeft(2, '0')}-${selectedBirthday.day.toString().padLeft(2, '0')}",
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                // School Year Dropdown
                                DropdownButtonFormField<String>(
                                  value: selectedSchoolYear,
                                  decoration: const InputDecoration(
                                    labelText: 'School Year',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.school_outlined),
                                  ),
                                  items: [
                                    'Grade 7', 'Grade 8', 'Grade 9', 'Grade 10', 'Grade 11', 'Grade 12',
                                    '1st Year College', '2nd Year College', '3rd Year College', '4th Year College', '5th Year College'
                                  ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                                  onChanged: (val) => setDialogState(() => selectedSchoolYear = val!),
                                ),
                                const SizedBox(height: 12),
                                // Contact Info
                                TextField(
                                  controller: phoneController,
                                  decoration: const InputDecoration(
                                    labelText: 'Phone Number',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.phone_outlined),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: addressController,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                    labelText: 'Address',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.location_on_outlined),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: () async {
                                      if (folderNameController.text.isEmpty) return;
                                      
                                      // Save client info to Firebase
                                      try {
                                        await FirebaseFirestore.instance.collection('client_info').add({
                                          'folder_name': folderNameController.text,
                                          'full_name': nameController.text,
                                          'age': int.tryParse(ageController.text) ?? 0,
                                          'gender': selectedGender,
                                          'birthday': Timestamp.fromDate(selectedBirthday),
                                          'school_year': selectedSchoolYear,
                                          'phone_number': phoneController.text,
                                          'address': addressController.text,
                                          'created_at': FieldValue.serverTimestamp(),
                                          'admin_id': _currentAdminId,
                                        });
                                        
                                        // Auto-select the new folder
                                        setDialogState(() => selectedFolder = folderNameController.text);
                                        // Close dialog and proceed (handled by parent setState if needed)
                                        Navigator.of(context).pop();
                                        
                                        if (file != null) {
                                          _uploadAudioToFirebase(file, selectedFolder!);
                                        } else {
                                          // Just setting folder for recording
                                          setState(() => _selectedWaveformRecording = {'folder': selectedFolder!});
                                        }
                                        
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Client created successfully!')),
                                        );
                                      } catch (e) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Error creating client: $e')),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.person_add),
                                    label: const Text('Create Client Profile'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2E7D32),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                if (file != null) // Only show upload button if uploading file
                  ElevatedButton(
                    onPressed: selectedFolder == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            _uploadAudioToFirebase(file, selectedFolder!);
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Use Selected Folder'),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Show client selection dialog specifically for the Record page
  /// This sets _selectedFolderName and uses _clients from Firebase
  void _showRecordingClientDialog() {
    String? selectedFolder = _selectedFolderName;
    String searchQuery = '';
    
    // Form controllers for new client
    final nameController = TextEditingController();
    final ageController = TextEditingController();
    final phoneController = TextEditingController();
    final addressController = TextEditingController();
    final folderNameController = TextEditingController();
    
    String selectedGender = 'Male';
    String selectedSchoolYear = '1st Year College';
    DateTime selectedBirthday = DateTime.now().subtract(const Duration(days: 365 * 16)); // Default 16 yo
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Filter clients based on search
          final filteredClients = _clients.where((client) {
            final folderName = (client['folder_name'] ?? '').toString().toLowerCase();
            final fullName = (client['full_name'] ?? '').toString().toLowerCase();
            return folderName.contains(searchQuery.toLowerCase()) ||
                   fullName.contains(searchQuery.toLowerCase());
          }).toList();
          
          return DefaultTabController(
            length: 2,
            child: AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.mic, color: Color(0xFF2E7D32)),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Select Client for Recording', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Text('Choose who this recording is for', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 500,
                height: 520,
                child: Column(
                  children: [
                    const TabBar(
                      labelColor: Color(0xFF2E7D32),
                      unselectedLabelColor: Colors.grey,
                      indicatorColor: Color(0xFF2E7D32),
                      tabs: [
                        Tab(text: 'Existing Client'),
                        Tab(text: 'Create New'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // Tab 1: Existing Clients
                          Column(
                            children: [
                              TextField(
                                decoration: InputDecoration(
                                  hintText: 'Search clients...',
                                  prefixIcon: const Icon(Icons.search),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                                ),
                                onChanged: (val) {
                                  setDialogState(() => searchQuery = val);
                                },
                              ),
                              const SizedBox(height: 12),
                              Expanded(
                                child: filteredClients.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.person_search, size: 48, color: Colors.grey[300]),
                                            const SizedBox(height: 12),
                                            Text(
                                              _clients.isEmpty 
                                                  ? 'No clients yet' 
                                                  : 'No clients match your search',
                                              style: TextStyle(color: Colors.grey[600]),
                                            ),
                                            if (_clients.isEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(top: 8),
                                                child: Text(
                                                  'Create a new client to get started',
                                                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                                                ),
                                              ),
                                          ],
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: filteredClients.length,
                                        itemBuilder: (context, index) {
                                          final client = filteredClients[index];
                                          final folderName = client['folder_name']?.toString() ?? '';
                                          final fullName = client['full_name']?.toString() ?? '';
                                          final isSelected = selectedFolder == folderName;
                                          
                                          return Card(
                                            margin: const EdgeInsets.only(bottom: 8),
                                            elevation: isSelected ? 2 : 0,
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(12),
                                              side: BorderSide(
                                                color: isSelected ? const Color(0xFF2E7D32) : Colors.grey[200]!,
                                                width: isSelected ? 2 : 1,
                                              ),
                                            ),
                                            color: isSelected ? const Color(0xFFF1F8F4) : Colors.white,
                                            child: ListTile(
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                              leading: CircleAvatar(
                                                backgroundColor: isSelected ? const Color(0xFF2E7D32) : Colors.grey[200],
                                                child: Icon(Icons.person, color: isSelected ? Colors.white : Colors.grey[500]),
                                              ),
                                              title: Text(folderName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                              subtitle: fullName.isNotEmpty ? Text(fullName) : null,
                                              trailing: isSelected 
                                                  ? const Icon(Icons.check_circle, color: Color(0xFF2E7D32))
                                                  : null,
                                              onTap: () => setDialogState(() => selectedFolder = folderName),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                          
                          // Tab 2: Create New Client
                          SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Client Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: folderNameController,
                                  decoration: const InputDecoration(
                                    labelText: 'Folder Name (Unique ID) *',
                                    border: OutlineInputBorder(),
                                    helperText: 'e.g. John Doe',
                                    prefixIcon: Icon(Icons.folder_outlined),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: nameController,
                                  decoration: const InputDecoration(
                                    labelText: 'Full Name',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.badge_outlined),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: ageController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'Age',
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        value: selectedGender,
                                        decoration: const InputDecoration(
                                          labelText: 'Gender',
                                          border: OutlineInputBorder(),
                                        ),
                                        items: ['Male', 'Female', 'Prefer not to say']
                                            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                                            .toList(),
                                        onChanged: (val) => setDialogState(() => selectedGender = val!),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                InkWell(
                                  onTap: () async {
                                    final date = await showDatePicker(
                                      context: context,
                                      initialDate: selectedBirthday,
                                      firstDate: DateTime(1900),
                                      lastDate: DateTime.now(),
                                    );
                                    if (date != null) {
                                      setDialogState(() => selectedBirthday = date);
                                    }
                                  },
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Birthday',
                                      border: OutlineInputBorder(),
                                      prefixIcon: Icon(Icons.cake_outlined),
                                    ),
                                    child: Text(
                                      "${selectedBirthday.year}-${selectedBirthday.month.toString().padLeft(2, '0')}-${selectedBirthday.day.toString().padLeft(2, '0')}",
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  value: selectedSchoolYear,
                                  decoration: const InputDecoration(
                                    labelText: 'School Year',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.school_outlined),
                                  ),
                                  items: [
                                    'Senior High School',
                                    '1st Year College', '2nd Year College', '3rd Year College', 
                                    '4th Year College', '5th Year College'
                                  ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                                  onChanged: (val) => setDialogState(() => selectedSchoolYear = val!),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: phoneController,
                                  decoration: const InputDecoration(
                                    labelText: 'Phone Number',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.phone_outlined),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: addressController,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                    labelText: 'Address',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.location_on_outlined),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: () async {
                                      if (folderNameController.text.trim().isEmpty) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Please enter a folder name')),
                                        );
                                        return;
                                      }
                                      
                                      try {
                                        await FirebaseFirestore.instance.collection('client_info').add({
                                          'folder_name': folderNameController.text.trim(),
                                          'full_name': nameController.text.trim(),
                                          'age': int.tryParse(ageController.text) ?? 0,
                                          'gender': selectedGender,
                                          'birthday': Timestamp.fromDate(selectedBirthday),
                                          'school_year': selectedSchoolYear,
                                          'phone_number': phoneController.text.trim(),
                                          'address': addressController.text.trim(),
                                          'created_at': FieldValue.serverTimestamp(),
                                          'admin_id': _currentAdminId,
                                        });
                                        
                                        // Set the new folder as selected
                                        setState(() {
                                          _selectedFolderName = folderNameController.text.trim();
                                        });
                                        
                                        Navigator.of(context).pop();
                                        
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Row(
                                              children: [
                                                const Icon(Icons.check_circle, color: Colors.white),
                                                const SizedBox(width: 12),
                                                Text('Client "${folderNameController.text}" created!'),
                                              ],
                                            ),
                                            backgroundColor: const Color(0xFF2E7D32),
                                          ),
                                        );
                                      } catch (e) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Error creating client: $e')),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.person_add),
                                    label: const Text('Create & Select Client'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2E7D32),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: selectedFolder == null
                      ? null
                      : () {
                          setState(() {
                            _selectedFolderName = selectedFolder;
                          });
                          Navigator.of(context).pop();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Use Selected Client'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _uploadAudioToFirebase(html.File file, String folderName) async {
    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Analyzing ${file.name}... (transcription, features, ML prediction)')),
          ],
        ),
        backgroundColor: const Color(0xFF2E7D32),
        duration: const Duration(seconds: 120), // Longer duration for full analysis
      ),
    );
    
    try {
      // 1. Read file as bytes
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      await reader.onLoadEnd.first;
      
      final audioBytes = reader.result as Uint8List;

      // 2. Send to mobile_api.py Backend (port 5001) for full processing
      // The /analyze endpoint handles: transcription, translation, feature extraction, ML prediction
      var request = http.MultipartRequest('POST', Uri.parse('http://127.0.0.1:5001/analyze'));
      request.files.add(http.MultipartFile.fromBytes(
        'audio', 
        audioBytes,
        filename: file.name
      ));
      request.fields['folder_name'] = folderName;
      request.fields['admin_id'] = _currentAdminId ?? '';
      request.fields['transcript'] = ''; // Let backend handle transcription via Whisper

      print('📤 Sending to mobile_api.py (port 5001) for full analysis...');
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);
      
      print('📥 Response status: ${response.statusCode}');
      
      Map<String, dynamic> analysisResult = {};
      if (response.statusCode == 200) {
        analysisResult = jsonDecode(response.body);
        print('✅ Analysis success: severity=${analysisResult['severity_level']}, indicators=${(analysisResult['indicators'] as List?)?.length ?? 0}');
      } else {
        print('❌ Backend error: ${response.body}');
        throw Exception("AI Analysis Failed: ${response.body}");
      }
      
      // 3. Extract all data from the response
      final now = DateTime.now();
      
      // Transcription data
      final transcript = analysisResult['transcript'] ?? '';
      final transcriptEn = analysisResult['transcript_en'] ?? '';
      final transcriptTl = analysisResult['transcript_tl'] ?? '';
      
      // Severity data
      final severityLevel = analysisResult['severity_level'] ?? 'Normal';
      final severityConfidence = analysisResult['severity_confidence'] ?? 0;
      final severityProbabilities = analysisResult['severity_probabilities'] ?? {};
      
      // Emotion data
      final emotion = analysisResult['emotion'] ?? 'Neutral';
      final emotionConfidence = analysisResult['emotion_confidence'] ?? 0;
      
      // Indicators (anxiety + educational)
      final indicators = analysisResult['indicators'] ?? [];
      
      // Extracted features for visualization and storage
      final extractedFeatures = analysisResult['extracted_features'] ?? {};
      final waveform = extractedFeatures['waveform'] ?? [];
      
      // Overall confidence
      final overallConfidence = analysisResult['overall_confidence'] ?? 0;
      
      // 4. Save complete recording metadata + Analysis to Firestore
      await FirebaseFirestore.instance.collection('recordings').add({
        // Basic info
        'folder_name': folderName,
        'name': file.name,
        'size': '${(file.size / 1024).toStringAsFixed(1)} KB',
        'date': '${_getMonthName(now.month)} ${now.day}, ${now.year}',
        'duration': analysisResult['processing_time_ms'] != null 
            ? '${(analysisResult['processing_time_ms'] / 1000).toStringAsFixed(1)}s processing'
            : '00:00:00',
        
        // Transcription (original + translations)
        'transcription': transcript,
        'transcript_en': transcriptEn,
        'transcript_tl': transcriptTl,
        
        // Severity Analysis
        'severity_level': severityLevel,
        'severity_confidence': severityConfidence,
        'severity_probabilities': severityProbabilities,
        
        // Emotion Analysis
        'emotion_label': emotion,
        'emotion_confidence': emotionConfidence,
        
        // ML Indicators (complete list with probabilities and reasons)
        'indicators': indicators,
        'anxiety_indicators': indicators, // For backward compatibility
        
        // Word Analysis (for highlighting in UI)
        'negative_matches': extractedFeatures['negative_matches'] ?? [],
        'positive_matches': extractedFeatures['positive_matches'] ?? [],
        'cognitive_matches': extractedFeatures['cognitive_matches'] ?? [],
        'absolutist_matches': extractedFeatures['absolutist_matches'] ?? [],
        'distress_words': extractedFeatures['distress_words'] ?? [],
        'analyzed_words': extractedFeatures['analyzed_words'] ?? [],
        
        // Audio Features
        'waveform': waveform,
        'jitter': extractedFeatures['jitter'] ?? 0,
        'shimmer': extractedFeatures['shimmer'] ?? 0,
        'hnr': extractedFeatures['hnr'] ?? 0,
        'pitch_mean': extractedFeatures['pitch_mean'] ?? 0,
        'energy_mean': extractedFeatures['energy_mean'] ?? 0,
        
        // Confidence and summary
        'overall_confidence': overallConfidence,
        'summary': analysisResult['summary'] ?? '',
        
        // Metadata
        'uploaded_at': FieldValue.serverTimestamp(),
        'source': 'web_dashboard_analyzed',
        'admin_id': _currentAdminId,
        'processing_time_ms': analysisResult['processing_time_ms'] ?? 0,
      });
      
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Analysis Complete! Saved to $folderName'),
                    Text(
                      'Severity: $severityLevel (${severityConfidence}%) • ${(indicators as List).length} indicators detected',
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF2E7D32),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      print('❌ Upload Error: $e');
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Analysis Failed', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('$e', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              const Text('Make sure mobile_api.py is running on port 5001', style: TextStyle(fontSize: 11, color: Colors.white70)),
            ],
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }


  String _getMonthName(int month) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month - 1];
  }

  // Gender count helper
  Map<String, int> _getGenderCounts() {
    Map<String, int> counts = {'Male': 0, 'Female': 0, 'Other': 0};
    for (var client in _clients) {
      final gender = (client['gender'] ?? 'Other').toString();
      if (gender.toLowerCase() == 'male') {
        counts['Male'] = (counts['Male'] ?? 0) + 1;
      } else if (gender.toLowerCase() == 'female') {
        counts['Female'] = (counts['Female'] ?? 0) + 1;
      } else {
        counts['Other'] = (counts['Other'] ?? 0) + 1;
      }
    }
    return counts;
  }

  // School year count helper
  Map<String, int> _getSchoolYearCounts() {
    Map<String, int> counts = {};
    for (var client in _clients) {
      final schoolYear = (client['school_year'] ?? 'Unknown').toString();
      counts[schoolYear] = (counts[schoolYear] ?? 0) + 1;
    }
    return counts;
  }

  Widget _buildGenderChart() {
    final counts = _getGenderCounts();
    final total = counts.values.fold(0, (a, b) => a + b);
    
    if (total == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 8),
            Text('No client data', style: TextStyle(color: Colors.grey[500])),
          ],
        ),
      );
    }
    
    // Get client names by gender
    Map<String, List<String>> clientsByGender = {'Male': [], 'Female': [], 'Other': []};
    for (var client in _clients) {
      final gender = (client['gender'] ?? 'Other').toString().toLowerCase();
      final name = client['full_name'] ?? client['folder_name'] ?? 'Unknown';
      if (gender == 'male') {
        clientsByGender['Male']!.add(name);
      } else if (gender == 'female') {
        clientsByGender['Female']!.add(name);
      } else {
        clientsByGender['Other']!.add(name);
      }
    }
    
    final colors = {
      'Male': const Color(0xFF2196F3),
      'Female': const Color(0xFFE91E63),
      'Other': const Color(0xFF9E9E9E),
    };
    
    return Column(
      children: [
        // Semi-circle chart
        Expanded(
          child: CustomPaint(
            painter: SemiCircleChartPainter(
              data: counts.entries.where((e) => e.value > 0).map((e) => ChartSegment(e.key, e.value.toDouble())).toList(),
              colors: const [Color(0xFF2196F3), Color(0xFFE91E63), Color(0xFF9E9E9E)],
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 8),
        // Interactive legend with tooltips
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: counts.entries.where((e) => e.value > 0).map((entry) {
            final clients = clientsByGender[entry.key] ?? [];
            final displayNames = clients.take(5).join('\n');
            final moreCount = clients.length > 5 ? '\n+${clients.length - 5} more' : '';
            
            return Tooltip(
              message: clients.isEmpty 
                  ? '${entry.key}: No clients' 
                  : '$displayNames$moreCount',
              preferBelow: true,
              decoration: BoxDecoration(
                color: colors[entry.key]?.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              textStyle: const TextStyle(color: Colors.white, fontSize: 12),
              waitDuration: const Duration(milliseconds: 200),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: colors[entry.key]?.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors[entry.key]!.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colors[entry.key],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${entry.key} (${entry.value})',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: colors[entry.key]),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSchoolYearChart() {
    final counts = _getSchoolYearCounts();
    
    if (counts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.school, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 8),
            Text('No school year data', style: TextStyle(color: Colors.grey[500])),
          ],
        ),
      );
    }
    
    // Define colors for school years
    final schoolYearColors = [
      const Color(0xFF1976D2), // Blue
      const Color(0xFF388E3C), // Green
      const Color(0xFFE64A19), // Orange
      const Color(0xFF7B1FA2), // Purple
      const Color(0xFF00796B), // Teal
      const Color(0xFFC2185B), // Pink
      const Color(0xFF455A64), // Blue Grey
      const Color(0xFFF57C00), // Amber
    ];
    
    // Get client names by school year
    Map<String, List<String>> clientsBySchoolYear = {};
    for (var client in _clients) {
      final schoolYear = (client['school_year'] ?? 'Unknown').toString();
      final name = client['full_name'] ?? client['folder_name'] ?? 'Unknown';
      if (!clientsBySchoolYear.containsKey(schoolYear)) {
        clientsBySchoolYear[schoolYear] = [];
      }
      clientsBySchoolYear[schoolYear]!.add(name);
    }
    
    final sortedEntries = counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    
    return Column(
      children: [
        // Semi-circle chart
        Expanded(
          child: CustomPaint(
            painter: SemiCircleChartPainter(
              data: sortedEntries.map((e) => ChartSegment(e.key, e.value.toDouble())).toList(),
              colors: schoolYearColors,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 8),
        // Interactive legend with tooltips
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: sortedEntries.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            final color = schoolYearColors[index % schoolYearColors.length];
            final clients = clientsBySchoolYear[item.key] ?? [];
            final displayNames = clients.take(5).join('\n');
            final moreCount = clients.length > 5 ? '\n+${clients.length - 5} more' : '';
            
            return Tooltip(
              message: clients.isEmpty 
                  ? '${item.key}: No clients' 
                  : '$displayNames$moreCount',
              preferBelow: true,
              decoration: BoxDecoration(
                color: color.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              textStyle: const TextStyle(color: Colors.white, fontSize: 12),
              waitDuration: const Duration(milliseconds: 200),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: color.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${item.key} (${item.value})',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: color),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildLegendItem(String label, int count, Color color) {
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: Colors.grey[700])),
        const Spacer(),
        Text('$count', style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildRecordingActivityChart() {
    // Get recordings per day for last 7 days
    final now = DateTime.now();
    final dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    
    Map<String, int> dailyCounts = {};
    for (int i = 6; i >= 0; i--) {
      final day = now.subtract(Duration(days: i));
      final dayName = dayNames[day.weekday - 1];
      dailyCounts[dayName] = 0;
    }
    
    // Count recordings per day
    _allFolders.forEach((folder, recordings) {
      for (var recording in recordings) {
        DateTime? date;
        final rawDate = recording['date'];
        
        // Parse date safely
        try {
          if (rawDate is Timestamp) {
            date = rawDate.toDate();
          } else if (rawDate is String) {
            // Try ISO format first
            date = DateTime.tryParse(rawDate);
            // If failed, try parse "Dec 13, 2024" format manually if needed, 
            // but usually we save ISO or standard.
            // For the specific format "Month DD, YYYY lines":
            if (date == null && rawDate.contains(',')) {
               // Quick hack/effort for "Dec 13, 2024" style if standard parsing fails
               // Better to rely on the 'created_at' ISO field if available
            }
          }
          
          // Fallback to 'created_at' if 'date' failed
          if (date == null && recording['created_at'] != null) {
             if (recording['created_at'] is String) {
               date = DateTime.tryParse(recording['created_at']);
             } else if (recording['created_at'] is Timestamp) {
               date = (recording['created_at'] as Timestamp).toDate();
             }
          }

          if (date != null) {
            final dayName = dayNames[date.weekday - 1]; // 1=Mon .. 7=Sun
            // Only count if it's within the last 7 days displayed
            if (dailyCounts.containsKey(dayName)) {
               // Check if it's actually the correct recent date, not just "a Monday"
               // For simplicity in this chart, we align by weekday name for the last week
               dailyCounts[dayName] = (dailyCounts[dayName] ?? 0) + 1;
            }
          }
        } catch (e) {
          print('Error parsing date for activity chart: $e');
        }
      }
    });
    
    // Check if we have any data
    final hasData = dailyCounts.values.any((v) => v > 0);
    
    return Column(
      children: [
        Expanded(
          child: hasData 
            ? CustomPaint(
                painter: LineGraphPainter(
                  data: dailyCounts.values.toList(),
                  labels: dailyCounts.keys.toList(),
                ),
                child: const SizedBox.expand(),
              )
            : Center(
                child: Text(
                  'No recording activity in the last 7 days',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: dailyCounts.keys.map((day) => 
            Text(day, style: TextStyle(
              fontSize: 11, 
              color: hasData ? Colors.grey[600] : Colors.grey[300]
            ))
          ).toList(),
        ),
      ],
    );

  }

  Widget _buildAnalysisSummary() {
    // Find biomarker result for selected recording using the helper function
    final selectedResult = _findMatchingBiomarkerResult();
    
    if (_selectedWaveformRecording != null) {
      print('🔍 Searching biomarker for: ${_selectedWaveformRecording!['name']}');
      print('🔍 Found result: ${selectedResult != null ? 'Yes' : 'No'}');
    }
    
    // If no selection, use the most recent result
    // REMOVED: Only show data when user explicitly selects a recording
    // if (selectedResult == null && _biomarkerResults.isNotEmpty) {
    //   selectedResult = _biomarkerResults.first;
    // }
    
    // Build biomarker items from real data
    List<Map<String, String>> biomarkers = [];
    bool hasRealData = selectedResult != null && selectedResult.isNotEmpty;
    
    if (hasRealData) {
      // Extract severity data
      final severity = selectedResult!['severity'] as Map<String, dynamic>? ?? {};
      final severityLevel = severity['level']?.toString() ?? 'Unknown';
      final severityConf = severity['confidence']?.toString() ?? '--';
      
      // Extract emotion data
      final emotion = selectedResult['emotion'] as Map<String, dynamic>? ?? {};
      final emotionLabel = emotion['label']?.toString() ?? 'Unknown';
      final emotionConf = emotion['confidence']?.toString() ?? '--';
      
      // Extract detected conditions
      final conditions = (selectedResult['detected_conditions'] as List<dynamic>?)
          ?.map((c) => c.toString())
          .toList() ?? [];
      
      // Extract audio features if available
      final features = selectedResult['extracted_features'] as Map<String, dynamic>? ?? {};
      
      // Calculate MFCC mean (average of mfcc_0 to mfcc_12)
      double mfccMean = 0;
      int mfccCount = 0;
      for (int i = 0; i < 13; i++) {
        final mfccVal = features['mfcc_$i'];
        if (mfccVal != null) {
          mfccMean += (mfccVal as num).toDouble();
          mfccCount++;
        }
      }
      if (mfccCount > 0) mfccMean /= mfccCount;
      
      // Calculate BERT mean (average of bert_0 to bert_767)
      double bertMean = 0;
      int bertCount = 0;
      for (int i = 0; i < 768; i++) {
        final bertVal = features['bert_$i'];
        if (bertVal != null) {
          bertMean += (bertVal as num).toDouble();
          bertCount++;
        }
      }
      if (bertCount > 0) bertMean /= bertCount;
      
      biomarkers = [
        if (features['hnr'] != null) {'label': 'HNR (dB)', 'value': (features['hnr'] as num).toStringAsFixed(2), 'status': 'normal'},
        if (features['jitter'] != null) {'label': 'Jitter (%)', 'value': (features['jitter'] as num).toStringAsFixed(4), 'status': 'normal'},
        if (features['shimmer'] != null) {'label': 'Shimmer (%)', 'value': (features['shimmer'] as num).toStringAsFixed(4), 'status': 'normal'},
        if (mfccCount > 0) {'label': 'MFCC Mean', 'value': mfccMean.toStringAsFixed(4), 'status': 'normal'},
        if (bertCount > 0) {'label': 'BERT Mean', 'value': bertMean.toStringAsFixed(4), 'status': 'normal'},
      ];
    } else {
      // No data available - show placeholder
      biomarkers = [
        {'label': 'Status', 'value': 'No Analysis', 'status': 'normal'},
        {'label': 'Info', 'value': 'Record audio to see results', 'status': 'normal'},
      ];
    }
    
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: biomarkers.map((marker) {
                final statusColor = marker['status'] == 'good' 
                    ? Colors.greenAccent
                    : marker['status'] == 'warning'
                        ? Colors.orangeAccent
                        : marker['status'] == 'severe'
                            ? Colors.redAccent
                            : Colors.white;
                
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        marker['label']!,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                marker['value']!,
                                style: TextStyle(
                                  color: statusColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (!hasRealData) Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.touch_app, color: Colors.white70, size: 14),
              SizedBox(width: 6),
              Text(
                'Select a recording above',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  String _getSeverityStatus(String severity) {
    switch (severity.toLowerCase()) {
      case 'normal': return 'good';
      case 'moderate': return 'warning';
      case 'severe': return 'severe';
      default: return 'normal';
    }
  }
  
  /// Helper to find matching biomarker result for a given recording
  /// If no recording is passed, uses _selectedWaveformRecording
  Map<String, dynamic>? _findMatchingBiomarkerResult([Map<String, dynamic>? recording]) {
    final rec = recording ?? _selectedWaveformRecording;
    if (rec == null) return null;
    
    final fileName = rec['name'] ?? '';
    final folderName = rec['folder_name'] ?? rec['folder'] ?? '';
    final recordingDocId = rec['id'] ?? '';
    
    // Create filename variations for matching
    final fileNameNoExt = fileName.replaceAll(RegExp(r'\.(wav|m4a|mp3|mp4)$', caseSensitive: false), '');
    
    // Try multiple matching strategies
    for (var result in _biomarkerResults) {
      final rRecordingId = result['recording_id']?.toString() ?? '';
      final rFileName = result['file_name']?.toString() ?? '';
      final rFolderName = result['folder_name']?.toString() ?? '';
      final rAudioName = result['audio_name']?.toString() ?? '';
      
      // Match by recording_id (which is often the filename without extension)
      bool matchById = rRecordingId == recordingDocId || 
                       rRecordingId == fileName || 
                       rRecordingId == fileNameNoExt;
      
      // Match by file_name field
      bool matchByFileName = rFileName == fileName || 
                             rFileName == fileNameNoExt ||
                             rAudioName == fileName ||
                             rAudioName == fileNameNoExt;
      
      // Match by folder + filename
      bool matchByFolderAndFile = rFolderName == folderName && matchByFileName;
      
      if (matchById || matchByFileName || matchByFolderAndFile) {
        return result;
      }
    }
    return null;
  }

  /// Build a carousel of recent recordings
  Widget _buildRecentRecordingsCarousel() {
    // Collect all recordings from all folders
    List<Map<String, dynamic>> allRecordings = [];
    _allFolders.forEach((folder, recordings) {
      for (var rec in recordings) {
        allRecordings.add({...rec, 'folder': folder});
      }
    });
    
    // Sort by date (most recent first) - simplified sort with mixed type handling
    allRecordings.sort((a, b) {
       final aDate = a['date'];
       final bDate = b['date'];
       return (bDate?.toString() ?? '').compareTo(aDate?.toString() ?? '');
    });
    
    // Take only first 10
    final recentRecordings = allRecordings.take(10).toList();
    
    if (recentRecordings.isEmpty) {
      return Container(
        height: 100,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.mic_none, size: 32, color: Colors.grey[400]),
              const SizedBox(height: 8),
              Text('No recordings yet', style: TextStyle(color: Colors.grey[500])),
            ],
          ),
        ),
      );
    }
    
    return SizedBox(
      height: 110,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: recentRecordings.length,
        itemBuilder: (context, index) {
          final rec = recentRecordings[index];
          final isSelected = _selectedWaveformRecording?['name'] == rec['name'];
          
          return GestureDetector(
            onTap: () {
              setState(() {
                // Toggle selection - click again to deselect
                if (_selectedWaveformRecording?['name'] == rec['name']) {
                  _selectedWaveformRecording = null;
                } else {
                  _selectedWaveformRecording = rec;
                }
              });
            },
            child: Container(
              width: 180,
              margin: EdgeInsets.only(right: index < recentRecordings.length - 1 ? 12 : 0),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF2E7D32).withOpacity(0.1) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected ? const Color(0xFF2E7D32) : Colors.grey[200]!,
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isSelected 
                              ? const Color(0xFF2E7D32).withOpacity(0.2)
                              : Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.mic, 
                          size: 16, 
                          color: isSelected ? const Color(0xFF2E7D32) : Colors.grey[600],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          rec['name'] ?? 'Recording',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: isSelected ? const Color(0xFF2E7D32) : Colors.grey[800],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    rec['folder'] ?? '',
                    style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.access_time, size: 12, color: Colors.grey[400]),
                      const SizedBox(width: 4),
                      Text(
                        rec['duration'] ?? '00:00',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                      const Spacer(),
                      Text(
                        rec['date']?.split(',').first ?? '',
                        style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Build waveform visualization for selected recording
  Widget _buildWaveformVisualization() {
    final selectedName = _selectedWaveformRecording?['name'] ?? 'Select a recording';
    final selectedDuration = _selectedWaveformRecording?['duration'] ?? '--:--';
    final selectedFolder = _selectedWaveformRecording?['folder'] ?? '';
    final hasSelection = _selectedWaveformRecording != null;
    
    // Use real waveform data if available, otherwise fallback
    final List<dynamic> rawWaveform = _selectedWaveformRecording?['waveform_data'] as List<dynamic>? ?? [];
    
    // Process waveform for display
    List<double> waveformPoints = [];
    if (rawWaveform.isNotEmpty) {
      // Skip leading zeros - find first non-zero value
      int startIndex = 0;
      for (int i = 0; i < rawWaveform.length; i++) {
        if ((rawWaveform[i] as num).toDouble() > 0.1) {
          startIndex = i;
          break;
        }
      }
      // Use only the active portion
      List<dynamic> activeWave = rawWaveform.sublist(startIndex);
      
      // Normalize: if values are 0-100, scale to 0-1
      waveformPoints = activeWave.map((e) {
        double rawVal = (e as num).toDouble();
        return rawVal > 1.0 ? (rawVal / 100.0).clamp(0.0, 1.0) : rawVal.clamp(0.0, 1.0);
      }).toList();
    } else {
      // Fallback simulation only if no data
      waveformPoints = List.generate(50, (i) {
        if (!hasSelection) return 0.2;
        final seed = (selectedName.hashCode + i * 17) % 100;
        return 0.2 + (seed / 100) * 0.8;
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with file info
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: hasSelection 
                    ? const Color(0xFF2E7D32).withOpacity(0.1)
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.graphic_eq, 
                color: hasSelection ? const Color(0xFF2E7D32) : Colors.grey[400],
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selectedName,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: hasSelection ? const Color(0xFF263238) : Colors.grey[500],
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hasSelection)
                    Text(
                      '$selectedFolder • $selectedDuration',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        
        // Waveform visualization
        Expanded(
          child: hasSelection
              ? Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FBF8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: waveformPoints.take(80).map((height) {
                      double barHeight = height * 70;
                      if (barHeight < 4) barHeight = 4; // Minimum height
                      return Container(
                        width: 3,
                        height: barHeight, 
                        decoration: BoxDecoration(
                          color: Color(0xFF2E7D32).withOpacity((0.5 + (height * 0.5)).clamp(0.0, 1.0)),
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      );
                    }).toList(),
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.touch_app, size: 40, color: Colors.grey[300]),
                      const SizedBox(height: 12),
                      Text(
                        'Select a recording above to view waveform',
                        style: TextStyle(color: Colors.grey[400], fontSize: 13),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSeverityChart() {
    // Use real data from biomarker results
    Map<String, int> severityData = {'Normal': 0, 'Moderate': 0, 'Severe': 0};
    
    if (_selectedWaveformRecording != null) {
      // Show severity distribution for the selected recording based on EMOTION data
      final result = _findMatchingBiomarkerResult();
      print('DEBUG: Selected recording: ${_selectedWaveformRecording?['name']}');
      print('DEBUG: Matching result found: ${result != null}');
      
      if (result != null && result.isNotEmpty) {
        // PRIORITY: Use emotion.label + emotion.confidence to calculate distribution
        // PRIORITY: Use valid severity data directly from backend
        final severityDataRaw = result['severity'] as Map<String, dynamic>? ?? {};
        final rawProbs = severityDataRaw['probabilities'] as Map<String, dynamic>?;
        
        if (rawProbs != null && rawProbs.isNotEmpty) {
           // Use the exact probabilities from the backend
           severityData['Normal'] = (rawProbs['Normal'] as num?)?.toInt() ?? 0;
           severityData['Moderate'] = (rawProbs['Moderate'] as num?)?.toInt() ?? 0;
           severityData['Severe'] = (rawProbs['Severe'] as num?)?.toInt() ?? 0;
           print('DEBUG: Used backend probabilities: $severityData');
        } else {
           // Legacy Fallback: Synthesize distribution if backend probs missing
           String effectiveSeverity = severityDataRaw['level']?.toString() ?? 'Unknown';
           int confidence = (severityDataRaw['confidence'] as num?)?.toInt() ?? 0;
           
           // Fallback: If severity is missing/unknown, infer from emotion (Legacy behavior)
           if (effectiveSeverity == 'Unknown' || effectiveSeverity == 'null') {
             // ... [Rest of legacy logic identical to before] ...
             final emotionData = result['emotion'] as Map<String, dynamic>? ?? {};
             final emotionLabel = emotionData['label']?.toString() ?? 'Neutral';
             final emotionConf = (emotionData['confidence'] as num?)?.toInt() ?? 50;
             confidence = emotionConf;
             
             if (emotionLabel == 'Neutral' || emotionLabel == 'Happy' || emotionLabel == 'Calm') {
                effectiveSeverity = 'Normal';
             } else if (emotionLabel == 'Sad' || emotionLabel == 'Fear' || emotionLabel == 'Fearful') {
                effectiveSeverity = 'Moderate';
             } else if (emotionLabel == 'Angry' || emotionLabel == 'Disgust') {
                effectiveSeverity = 'Severe';
             } else {
                effectiveSeverity = 'Normal';
             }
           }
           
           // Normalize string case
           if (effectiveSeverity.toLowerCase() == 'normal') effectiveSeverity = 'Normal';
           else if (effectiveSeverity.toLowerCase() == 'moderate') effectiveSeverity = 'Moderate';
           else if (effectiveSeverity.toLowerCase() == 'severe') effectiveSeverity = 'Severe';
           
           // Set the main severity with its confidence
           severityData[effectiveSeverity] = confidence;
           
           // Distribute the remainder to other categories
           final remainder = 100 - confidence;
           if (effectiveSeverity == 'Normal') {
             severityData['Moderate'] = remainder ~/ 2;
             severityData['Severe'] = remainder - (remainder ~/ 2);
           } else if (effectiveSeverity == 'Moderate') {
             severityData['Normal'] = remainder ~/ 2;
             severityData['Severe'] = remainder - (remainder ~/ 2);
           } else {
             severityData['Normal'] = remainder ~/ 2;
             severityData['Moderate'] = remainder - (remainder ~/ 2);
           }
        }
      } else {
        severityData['Normal'] = 100; // Default if no data
      }
    } else if (_biomarkerResults.isNotEmpty) {
      // NO SELECTION: Count the WINNER severity from each recording
      // Then show the distribution as percentage of recordings
      Map<String, int> winnerCounts = {'Normal': 0, 'Moderate': 0, 'Severe': 0};
      
      for (var result in _biomarkerResults) {
        String winnerLevel = 'Normal';
        
        // PRIORITY: Use severity level directly
        final severityDataRaw = result['severity'] as Map<String, dynamic>? ?? {};
        String rawLevel = severityDataRaw['level']?.toString() ?? 'Unknown';
        
        if (rawLevel != 'Unknown' && rawLevel != 'null') {
           winnerLevel = rawLevel;
        } else {
           // Fallback to emotion
           final emotionData = result['emotion'] as Map<String, dynamic>? ?? {};
           final emotionLabel = emotionData['label']?.toString() ?? 'Neutral';
           
           if (emotionLabel == 'Neutral' || emotionLabel == 'Happy' || emotionLabel == 'Calm') {
             winnerLevel = 'Normal';
           } else if (emotionLabel == 'Sad' || emotionLabel == 'Fear' || emotionLabel == 'Fearful') {
             winnerLevel = 'Moderate';
           } else if (emotionLabel == 'Angry' || emotionLabel == 'Disgust') {
             winnerLevel = 'Severe';
           }
        }
        
        // Normalize
        if (winnerLevel.toLowerCase() == 'normal') winnerLevel = 'Normal';
        else if (winnerLevel.toLowerCase() == 'moderate') winnerLevel = 'Moderate';
        else if (winnerLevel.toLowerCase() == 'severe') winnerLevel = 'Severe';
        else winnerLevel = 'Normal'; // Fallback
        
        winnerCounts[winnerLevel] = (winnerCounts[winnerLevel] ?? 0) + 1;
      }
      
      // Convert counts to percentages
      final total = _biomarkerResults.length;
      severityData['Normal'] = ((winnerCounts['Normal'] ?? 0) / total * 100).round();
      severityData['Moderate'] = ((winnerCounts['Moderate'] ?? 0) / total * 100).round();
      severityData['Severe'] = ((winnerCounts['Severe'] ?? 0) / total * 100).round();
      
      print('DEBUG: Winner counts based on severity: $winnerCounts');
    } else {
      // No data - show placeholder
      severityData = {'Normal': 1, 'Moderate': 0, 'Severe': 0};
    }
    
    print('DEBUG: Final severityData: $severityData');
    
    final total = severityData.values.fold(0, (a, b) => a + b);
    if (total == 0) {
      // No Data State
      return Column(
        children: [
          Container(
            height: 24,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text(
                'No Data',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Legend (Placeholder)
           Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
               Icon(Icons.info_outline, size: 12, color: Colors.grey[400]),
               const SizedBox(width: 4),
               Text('No severity analysis available', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
            ],
          ),
        ],
      );
    }
    
    final colors = {
      'Normal': const Color(0xFF4CAF50),
      'Moderate': const Color(0xFFFF9800),
      'Severe': const Color(0xFFF44336),
    };
    
    return Column(
      children: [
        // Horizontal stacked bar
        Container(
          height: 24,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: severityData.entries.where((e) => e.value > 0).map((entry) {
              final percent = entry.value / (total > 0 ? total : 1);
              return Expanded(
                flex: (percent * 100).round().clamp(1, 100),
                child: Container(color: colors[entry.key]),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 16),
        // Legend
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: severityData.entries.map((entry) {
            final percent = ((entry.value / (total > 0 ? total : 1)) * 100).round();
            return Column(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: colors[entry.key],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 4),
                Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
                Text('$percent%', style: TextStyle(color: Colors.grey[600], fontSize: 11)),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildAnxietyChart() {
    // Use real data from biomarker results - anxiety_indicators
    Map<String, int> anxietyCounts = {
      'Social Anxiety': 0, 'GAD': 0, 'PTSD': 0, 
      'Panic Disorder': 0, 'Agoraphobia': 0, 'Normal': 0,
    };
    
    if (_selectedWaveformRecording != null) {
      // Show data for the selected recording only
      final result = _findMatchingBiomarkerResult();
      if (result != null && result.isNotEmpty) {
        final indicators = result['anxiety_indicators'] as List<dynamic>? ?? [];
        bool hasDetected = false;
        for (var indicator in indicators) {
          final name = indicator['name']?.toString() ?? '';
          final detected = indicator['detected'] == true;
          if (detected && anxietyCounts.containsKey(name)) {
            anxietyCounts[name] = 100;
            hasDetected = true;
          }
        }
        if (!hasDetected) {
          anxietyCounts['Normal'] = 100;
        }
      } else {
        anxietyCounts['Normal'] = 100;
      }
    } else if (_biomarkerResults.isNotEmpty) {
      // Aggregate from all results
      for (var result in _biomarkerResults) {
        final indicators = result['anxiety_indicators'] as List<dynamic>? ?? [];
        bool hasDetected = false;
        for (var indicator in indicators) {
          final name = indicator['name']?.toString() ?? '';
          final detected = indicator['detected'] == true;
          if (detected && anxietyCounts.containsKey(name)) {
            anxietyCounts[name] = (anxietyCounts[name] ?? 0) + 1;
            hasDetected = true;
          }
        }
        if (!hasDetected) {
          anxietyCounts['Normal'] = (anxietyCounts['Normal'] ?? 0) + 1;
        }
      }
    } else {
      anxietyCounts['Normal'] = 1;
    }
    
    // Convert to ChartSegment list
    final anxietyData = anxietyCounts.entries
        .where((e) => e.value > 0)
        .map((e) => ChartSegment(e.key, e.value.toDouble()))
        .toList();
    
    if (anxietyData.isEmpty) {
        // No Data layout
        return Column(
          children: [
            Expanded(
              child: CustomPaint(
                painter: SemiCircleChartPainter(
                  data: [ChartSegment('No Data', 1)], 
                  colors: [Colors.grey[200]!]
                ),
                child: const SizedBox.expand(),
              ),
            ),
             Text('No Data', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
          ],
        );
    }
    
    final colorMap = {
      'Social Anxiety': const Color(0xFFE91E63),
      'GAD': const Color(0xFF9C27B0),
      'PTSD': const Color(0xFF673AB7),
      'Panic Disorder': const Color(0xFF3F51B5),
      'Agoraphobia': const Color(0xFF2196F3),
      'Normal': const Color(0xFF4CAF50),
    };
    
    final colors = anxietyData.map((e) => colorMap[e.label] ?? const Color(0xFF4CAF50)).toList();
    
    return CustomPaint(
      painter: SemiCircleChartPainter(data: anxietyData, colors: colors),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildEducationalIssuesChart() {
    // Educational issues (NOT anxiety disorders like GAD, Social Anxiety, PTSD)
    const educationalIssues = {
      'Impostor Syndrome', 'Academic Burnout', 'Perfectionism', 
      'Fear Of Failure', 'Fear of Failure', 'Test Anxiety',
      'Low Self-Esteem', 'Low Self Esteem', // Handle both formats
      'Lack of Support', 'Lack Of Academic Support', 
      'Pressure', 'Pressure Of Surroundings',
      'Poor Time Management',
    };
    
    // Use real data from biomarker results - anxiety_indicators
    Map<String, int> issuesData = {};
    
    if (_selectedWaveformRecording != null) {
      // Show data for the selected recording only - use probability values
      final result = _findMatchingBiomarkerResult();
      if (result != null && result.isNotEmpty) {
        final indicators = result['anxiety_indicators'] as List<dynamic>? ?? [];
        for (var indicator in indicators) {
          final name = indicator['name']?.toString() ?? '';
          final probability = (indicator['probability'] as num?)?.toInt() ?? 0;
          final detected = indicator['detected'] == true;
          
          // Only include educational issues (not GAD, Social Anxiety, PTSD, etc.)
          if (detected && educationalIssues.contains(name)) {
            issuesData[name] = probability;
          }
        }
      }
    } else if (_biomarkerResults.isNotEmpty) {
      // Aggregate - show highest probability for each issue across all recordings
      for (var result in _biomarkerResults) {
        final indicators = result['anxiety_indicators'] as List<dynamic>? ?? [];
        for (var indicator in indicators) {
          final name = indicator['name']?.toString() ?? '';
          final probability = (indicator['probability'] as num?)?.toInt() ?? 0;
          final detected = indicator['detected'] == true;
          
          // Only include educational issues
          if (detected && educationalIssues.contains(name)) {
            // Keep the highest probability seen
            if ((issuesData[name] ?? 0) < probability) {
              issuesData[name] = probability;
            }
          }
        }
      }
    }
    
    // If no issues detected, show "No Data" placeholder instead of generic "No Issues"
    if (issuesData.isEmpty) {
       return Center(
         child: Column(
           mainAxisAlignment: MainAxisAlignment.center,
           children: [
             Icon(Icons.analytics_outlined, size: 32, color: Colors.grey[300]),
             const SizedBox(height: 8),
             Text(
               'No educational issues data available',
               style: TextStyle(color: Colors.grey[400], fontSize: 12),
             ),
           ],
         ),
       );
    }
    
    // Sort by value descending
    final sortedEntries = issuesData.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    final maxValue = sortedEntries.isNotEmpty 
        ? sortedEntries.first.value 
        : 1;
    
    return ListView.separated(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      itemCount: sortedEntries.length, // Show all issues
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final entry = sortedEntries[index];
        // Use probability as percentage (out of 100)
        final percent = entry.value / 100.0;
        final isNoIssues = entry.key == 'No Issues Detected';
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: 12, 
                      fontWeight: FontWeight.w500,
                      color: isNoIssues ? Colors.green : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  isNoIssues ? '✓' : '${entry.value}%',
                  style: TextStyle(
                    fontSize: 12, 
                    color: isNoIssues ? Colors.green : Colors.grey[600], 
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Stack(
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: percent.clamp(0.05, 1.0),
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isNoIssues 
                            ? [const Color(0xFF4CAF50), const Color(0xFF81C784)] // Green for no issues
                            : entry.value >= 90
                                ? [const Color(0xFFD32F2F), const Color(0xFFF44336)] // Dark red for 90%+
                                : entry.value >= 70
                                    ? [const Color(0xFFF44336), const Color(0xFFFF7043)] // Red/orange for 70-89%
                                    : entry.value >= 50
                                        ? [const Color(0xFFFF9800), const Color(0xFFFFB74D)] // Orange for 50-69%
                                        : [const Color(0xFF4CAF50), const Color(0xFF81C784)], // Green for <50%
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmotionChart() {
    // Use real data from biomarker results
    Map<String, int> emotionCounts = {
      'Calm': 0, 'Happy': 0, 'Sad': 0, 'Angry': 0, 
      'Fearful': 0, 'Surprise': 0, 'Disgust': 0, 'Neutral': 0,
    };
    
    if (_selectedWaveformRecording != null) {
      // Show data for the selected recording only
      final result = _findMatchingBiomarkerResult();
      if (result != null && result.isNotEmpty) {
        final emotion = result['emotion'] as Map<String, dynamic>? ?? {};
        final label = emotion['label']?.toString() ?? 'Neutral';
        // Capitalize first letter
        final normalizedLabel = label.isNotEmpty ? label[0].toUpperCase() + label.substring(1).toLowerCase() : 'Neutral';
        if (emotionCounts.containsKey(normalizedLabel)) {
          emotionCounts[normalizedLabel] = 100;
        } else {
          emotionCounts['Neutral'] = 100;
        }
      } else {
        emotionCounts['Neutral'] = 100;
      }
    } else if (_biomarkerResults.isNotEmpty) {
      // Aggregate from all results
      for (var result in _biomarkerResults) {
        final emotion = result['emotion'] as Map<String, dynamic>? ?? {};
        final label = emotion['label']?.toString() ?? 'Neutral';
        final normalizedLabel = label.isNotEmpty ? label[0].toUpperCase() + label.substring(1).toLowerCase() : 'Neutral';
        if (emotionCounts.containsKey(normalizedLabel)) {
          emotionCounts[normalizedLabel] = (emotionCounts[normalizedLabel] ?? 0) + 1;
        } else {
          emotionCounts['Neutral'] = (emotionCounts['Neutral'] ?? 0) + 1;
        }
      }
    } else {
      emotionCounts['Neutral'] = 1;
    }
    
    // Convert to ChartSegment list
    final emotionData = emotionCounts.entries
        .where((e) => e.value > 0)
        .map((e) => ChartSegment(e.key, e.value.toDouble()))
        .toList();
    
    if (emotionData.isEmpty) {
      emotionData.add(ChartSegment('Neutral', 1));
    }
    
    final colorMap = {
      'Calm': const Color(0xFF4CAF50),
      'Happy': const Color(0xFFFFEB3B),
      'Sad': const Color(0xFF2196F3),
      'Angry': const Color(0xFFF44336),
      'Fearful': const Color(0xFF9C27B0),
      'Surprise': const Color(0xFFFF9800),
      'Disgust': const Color(0xFF795548),
      'Neutral': const Color(0xFF9E9E9E),
    };
    
    final colors = emotionData.map((e) => colorMap[e.label] ?? const Color(0xFF9E9E9E)).toList();
    
    return CustomPaint(
      painter: SemiCircleChartPainter(data: emotionData, colors: colors),
      child: const SizedBox.expand(),
    );
  }

  // Generate PDF Document
  // Generate PDF Document
  Future<Uint8List> _generatePdf(Map<String, dynamic> client, Map<String, String> recording) async {
    try {
      final pdf = pw.Document();
      
      // Robust date formatting
      String formatBirthday(dynamic birthday) {
        if (birthday == null) return 'N/A';
        try {
          if (birthday is Timestamp) {
            DateTime date = birthday.toDate();
            const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
            return '${months[date.month - 1]} ${date.day}, ${date.year}';
          }
           // Handle if it's already a string or other type
          return birthday.toString();
        } catch (e) {
          return 'Invalid Date';
        }
      }

      final now = DateTime.now();
      final dateStr = '${_getMonthName(now.month)} ${now.day}, ${now.year}';

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) {
            return [
              // Header
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Audio Biomarker System', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: PdfColors.green800)),
                  pw.Text('Confidential Report', style: pw.TextStyle(fontSize: 12, color: PdfColors.grey)),
                ],
              ),
              pw.Divider(thickness: 2, color: PdfColors.green800),
              pw.SizedBox(height: 20),
              
              // Client Info Section
              pw.Container(
                padding: const pw.EdgeInsets.all(15),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Client Information', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey800)),
                    pw.SizedBox(height: 10),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        _buildPdfInfoRow('Full Name', client['full_name']?.toString() ?? 'Unknown'),
                        _buildPdfInfoRow('Age', client['age']?.toString() ?? 'N/A'),
                        _buildPdfInfoRow('Gender', client['gender']?.toString() ?? 'N/A'),
                      ],
                    ),
                    pw.SizedBox(height: 10),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        _buildPdfInfoRow('Birthday', formatBirthday(client['birthday'])),
                        _buildPdfInfoRow('School Year', client['school_year']?.toString() ?? 'N/A'),
                        _buildPdfInfoRow('Date', dateStr),
                      ],
                    ),
                    pw.SizedBox(height: 10),
                    _buildPdfInfoRow('Address', client['address']?.toString() ?? 'N/A'),
                  ],
                ),
              ),
              pw.SizedBox(height: 30),
              
              // Assessment Results Header
              pw.Text('Assessment Results', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              
              // Severity Section
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                color: PdfColors.grey100,
                child: pw.Row(
                  children: [
                     pw.Expanded(child: pw.Text('Severity Level', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                     pw.Text('Moderate (Demo)', style: pw.TextStyle(color: PdfColors.orange700, fontWeight: pw.FontWeight.bold)),
                  ]
                )
              ),
              pw.SizedBox(height: 20),

              // Prediction Details (Using standard Text for consistency)
              pw.Text('Detailed Analysis', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              _buildPdfBullet('Primary Issue: Social Anxiety (78% confidence)'),
              _buildPdfBullet('Secondary Issue: General Anxiety (45% confidence)'),
              _buildPdfBullet('Educational Impact: High likelihood of participation withdrawal'),
              
              pw.SizedBox(height: 40),
              
              // Footer
              pw.Divider(color: PdfColors.grey),
              pw.Center(child: pw.Text('Generated by Audio Biomarker System • $dateStr', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600))),
            ];
          },
        ),
      );
      return pdf.save();
    } catch (e, stack) {
      print('❌ Error generating PDF: $e');
      print(stack);
      
      // Return a basic error PDF so the preview doesn't just crash
      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          build: (context) => pw.Center(
            child: pw.Text('Error generating report: $e', style: const pw.TextStyle(color: PdfColors.red)),
          ),
        ),
      );
      return pdf.save();
    }
  }
  
  // Helper for PDF Info Row
  pw.Widget _buildPdfInfoRow(String label, String value) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label, style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        pw.Text(value, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      ]
    );
  }

  // Helper for PDF Bullet Point
  pw.Widget _buildPdfBullet(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 5),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('• ', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Expanded(
            child: pw.Text(text, style: const pw.TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // Show PDF Preview Dialog
  void _showPdfPreview(Map<String, dynamic> client, Map<String, String> recording) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 800,
            height: 800,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Report Preview', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Expanded(
                  child: PdfPreview(
                    build: (format) => _generatePdf(client, recording),
                    canChangeOrientation: false,
                    canChangePageFormat: false,
                    pdfFileName: 'Report_${client['full_name'] ?? 'Client'}.pdf',
                    onError: (context, error) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red, size: 48),
                            const SizedBox(height: 16),
                            Text('Error displaying PDF: $error', style: const TextStyle(color: Colors.red)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPageContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    
    // Show Analysis Detail Page if a recording is selected
    if (_selectedAnalysisRecording != null) {
      return _buildPredictionAnalysisPage();
    }
    
    // Nav order: 0=Overview, 1=Analytics, 2=Recordings, 3=Settings
    switch (_selectedIndex) {
      case 0: return _buildOverviewPage();
      case 1: return _buildAnalyticsPage();
      case 2: return _buildRecordingsPage();
      case 3: return _buildOverviewPage(); // Settings - show overview for now
      default: return _buildOverviewPage();
    }
  }

  Widget _buildOverviewPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stats Grid
          Row(
            children: [
              Expanded(child: _buildStatCard('Total Recordings', _getTotalRecordings().toString(), '${_clients.length} clients', Icons.mic)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('Total Duration', _getTotalDuration(), 'all recordings', Icons.timer)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('Storage Used', _getTotalStorageUsed(), 'cloud data', Icons.cloud_queue)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('Clients', _clients.length.toString(), 'registered', Icons.people_outlined)),
            ],
          ),
          const SizedBox(height: 40),
          
          // Charts Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Gender Distribution Chart
              Expanded(
                child: Container(
                  height: 300,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Gender Distribution',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                      ),
                      const SizedBox(height: 20),
                      Expanded(child: _buildGenderChart()),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              // School Year Distribution Chart
              Expanded(
                child: Container(
                  height: 300,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'School Year Distribution',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                      ),
                      const SizedBox(height: 20),
                      Expanded(child: _buildSchoolYearChart()),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          
          // Recent Recordings Carousel Section
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Recent Recordings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                  ),
                  Text(
                    '${_allFolders.values.fold<int>(0, (sum, list) => sum + list.length)} total',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildRecentRecordingsCarousel(),
            ],
          ),
          const SizedBox(height: 30),
          
          // Waveform Visualization & Analysis Summary Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Waveform Visualization
              Expanded(
                flex: 2,
                child: Container(
                  height: 300,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Audio Waveform',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                          ),
                          if (_selectedWaveformRecording != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2E7D32).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _selectedWaveformRecording!['folder'] ?? '',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF2E7D32)),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Expanded(child: _buildWaveformVisualization()),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              // Analysis Result Summary
              Expanded(
                child: Container(
                  height: 300,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF2E7D32), Color(0xFF1B5E20)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2E7D32).withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Analysis Summary',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      Text('Biomarker Results', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 16),
                      Expanded(child: _buildAnalysisSummary()),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          // Row 1: Anxiety Types & Emotion Distribution (Semi-circles - need more height)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Anxiety Types Chart
              Expanded(
                child: Container(
                  height: 280,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Anxiety Types Distribution',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(child: _buildAnxietyChart()),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              // Emotion Distribution Chart
              Expanded(
                child: Container(
                  height: 280,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Emotion Distribution',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(child: _buildEmotionChart()),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 30),
          
          // Row 2: Severity & Educational Issues
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Severity Distribution
              Expanded(
                child: Container(
                  height: 180,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Severity Distribution',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                          ),
                          Text(_selectedWaveformRecording != null 
                            ? '(Selected)' 
                            : (_biomarkerResults.isEmpty ? '(No Data)' : '(${_biomarkerResults.length} results avg)'), 
                            style: TextStyle(color: _selectedWaveformRecording != null ? Colors.green : Colors.grey[400], fontSize: 11)),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Expanded(child: _buildSeverityChart()),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              // Educational Issues Chart
              Expanded(
                child: Container(
                  height: 180,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Educational Issues',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Expanded(child: _buildEducationalIssuesChart()),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          
          // Recent recordings section
          Container(
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Recent Recordings',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => _selectedIndex = 2),
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: const Text('View All'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (_getTotalRecordings() == 0)
                  Container(
                    padding: const EdgeInsets.all(40),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.mic_off, size: 48, color: Colors.grey[300]),
                          const SizedBox(height: 12),
                          Text('No recordings yet', style: TextStyle(color: Colors.grey[500])),
                          Text('Start recording from the mobile app!', style: TextStyle(fontSize: 12, color: Colors.grey[400])),
                        ],
                      ),
                    ),
                  )
                else
                  ..._allFolders.entries.take(3).expand((entry) => entry.value.take(2).map((recording) => _buildRecordingListItem(recording, entry.key))).toList(),
              ],
            ),
          ),
          
          const SizedBox(height: 40),
          
          // Clients/Folders section
          Container(
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Clients / Folders',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                    ),
                    Text('${_clients.length} clients', style: TextStyle(color: Colors.grey[500])),
                  ],
                ),
                const SizedBox(height: 20),
                if (_clients.isEmpty && _allFolders.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(40),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.people_outline, size: 48, color: Colors.grey[300]),
                          const SizedBox(height: 12),
                          Text('No clients yet', style: TextStyle(color: Colors.grey[500])),
                        ],
                      ),
                    ),
                  )
                else
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      // Show clients with info
                      ..._clients.take(6).map((client) => _buildClientCard(client)),
                      // Show folders without client info
                      ..._allFolders.keys
                          .where((folder) => !_clients.any((c) => c['folder_name'] == folder))
                          .take(6)
                          .map((folder) => _buildFolderOnlyCard(folder)),
                    ],
                  ),
              ],
            ),
          ),
          
          const SizedBox(height: 40),
          
          // Recording Activity Chart (moved to bottom)
          Container(
            height: 300,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Recording Activity',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                    ),
                    Text('Last 7 days', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(child: _buildRecordingActivityChart()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClientCard(Map<String, dynamic> client) {
    final folderName = client['folder_name'] ?? 'Unknown';
    final recordingCount = _allFolders[folderName]?.length ?? 0;
    
    return InkWell(
      onTap: () => _showClientInfoDialog(client),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F8F4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2E7D32).withOpacity(0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFF2E7D32),
                  radius: 18,
                  child: Text(
                    (client['full_name'] ?? 'U')[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        client['full_name'] ?? folderName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '$recordingCount recordings',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Text('Click for details', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderOnlyCard(String folderName) {
    final recordingCount = _allFolders[folderName]?.length ?? 0;
    
    return Container(
      width: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.grey[400],
                radius: 18,
                child: const Icon(Icons.folder, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folderName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '$recordingCount recordings',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('No client info', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ],
      ),
    );
  }

  void _showClientInfoDialog(Map<String, dynamic> client) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFF2E7D32),
              child: Text(
                (client['full_name'] ?? 'U')[0].toUpperCase(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                client['full_name'] ?? 'Unknown Client',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Container(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoRow(Icons.folder, 'Folder', client['folder_name'] ?? 'N/A'),
              _buildInfoRow(Icons.cake, 'Age', '${client['age'] ?? 'N/A'} years old'),
              _buildInfoRow(Icons.person, 'Gender', client['gender'] ?? 'N/A'),
              _buildInfoRow(Icons.school, 'School Year', client['school_year'] ?? 'N/A'),
              _buildInfoRow(Icons.phone, 'Phone', client['phone_number'] ?? 'N/A'),
              _buildInfoRow(Icons.location_on, 'Address', client['address'] ?? 'N/A'),
              const Divider(),
              _buildInfoRow(Icons.audiotrack, 'Recordings', '${_allFolders[client['folder_name']]?.length ?? 0} files'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF2E7D32)),
          const SizedBox(width: 12),
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(color: Colors.grey[600])),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsPage() {
    // Combine folders with clients for display
    Map<String, List<Map<String, dynamic>>> allData = Map.from(_allFolders);
    for (var client in _clients) {
      final folderName = client['folder_name'] ?? client['full_name'] ?? 'Unknown';
      if (!allData.containsKey(folderName)) {
        allData[folderName] = [];
      }
    }
    
    // Count folders with transcriptions
    int foldersWithTranscriptions = 0;
    int totalTranscriptions = 0;
    allData.forEach((folder, recordings) {
      bool hasTranscription = false;
      for (var rec in recordings) {
        if (rec['transcription']?.isNotEmpty == true) {
          totalTranscriptions++;
          hasTranscription = true;
        }
      }
      if (hasTranscription) foldersWithTranscriptions++;
    });
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Analytics Dashboard',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                  ),
                  const SizedBox(height: 8),
                  Text('Folders, audio files, and transcription analysis', style: TextStyle(color: Colors.grey[600])),
                ],
              ),
            ],
          ),
          const SizedBox(height: 30),
          
          // Drop Zone for Audio Upload
          _buildAudioDropZone(allData.keys.toList()),
          const SizedBox(height: 30),
          
          // Stats row
          Row(
            children: [
              Expanded(child: _buildStatCard('Total Folders', allData.length.toString(), 'with data', Icons.folder)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('With Audio', allData.values.where((r) => r.isNotEmpty).length.toString(), 'folders', Icons.audiotrack)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('Transcriptions', totalTranscriptions.toString(), 'completed', Icons.text_snippet)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('Clients', _clients.length.toString(), 'registered', Icons.people)),
            ],
          ),
          const SizedBox(height: 40),
          
          // Folder list with audio and transcriptions
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Folder Analysis',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF263238)),
                    ),
                    Text('${allData.length} folders', style: TextStyle(color: Colors.grey[500])),
                  ],
                ),
                const SizedBox(height: 20),
                
                if (allData.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        children: [
                          Icon(Icons.folder_open, size: 60, color: Colors.grey[300]),
                          const SizedBox(height: 16),
                          Text('No folders yet', style: TextStyle(color: Colors.grey[500])),
                        ],
                      ),
                    ),
                  )
                else
                  ...allData.entries.map((entry) => _buildAnalyticsFolderCard(entry.key, entry.value)).toList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsFolderCard(String folderName, List<Map<String, dynamic>> recordings) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.folder, color: Color(0xFF2E7D32)),
        ),
        title: Text(
          folderName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Text(
          '${recordings.length} recording${recordings.length == 1 ? '' : 's'}',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
        children: recordings.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('No recordings yet', style: TextStyle(color: Colors.grey[400])),
                )
              ]
            : recordings.map((recording) => _buildAnalyticsRecordingItem(recording)).toList(),
      ),
    );
  }

  Widget _buildAnalyticsRecordingItem(Map<String, dynamic> recording) {
    final hasTranscript = recording['transcription']?.isNotEmpty == true;
    
    return InkWell(
      onTap: () => _showTranscriptionDialog(recording),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.grey[200]!)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F8F4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.music_note, color: Colors.grey[600], size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recording['name'] ?? 'Unknown',
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    recording['date'] ?? '',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                ],
              ),
            ),
            // Duration
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  recording['duration'] ?? '00:00:00',
                  style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w500, fontSize: 13),
                ),
                Text(
                  recording['size'] ?? '',
                  style: TextStyle(color: Colors.grey[400], fontSize: 11),
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Transcription icon
            Tooltip(
              message: hasTranscript 
                  ? 'Click to view transcription'
                  : 'No transcription available',
              child: Icon(
                Icons.description_outlined,
                color: hasTranscript ? const Color(0xFF2E7D32) : Colors.grey[300],
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordPage() {
    // Show client selection dialog on first load if no client selected
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_selectedFolderName == null && !_isRecording && !_hasShownClientDialog) {
        _hasShownClientDialog = true;
        _showRecordingClientDialog();
      }
    });
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Client Selection Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _selectedFolderName != null 
                        ? const Color(0xFF2E7D32).withOpacity(0.3)
                        : Colors.orange.withOpacity(0.5),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _selectedFolderName != null 
                            ? const Color(0xFFE8F5E9) 
                            : Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _selectedFolderName != null ? Icons.person : Icons.person_outline,
                        color: _selectedFolderName != null 
                            ? const Color(0xFF2E7D32) 
                            : Colors.orange,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedFolderName != null 
                                ? 'Recording for: $_selectedFolderName'
                                : 'No Client Selected',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: _selectedFolderName != null 
                                  ? const Color(0xFF263238) 
                                  : Colors.orange[800],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _selectedFolderName != null 
                                ? 'Recordings will be saved to this client\'s folder'
                                : 'Please select a client before recording',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _showRecordingClientDialog(),
                      icon: Icon(
                        _selectedFolderName != null ? Icons.swap_horiz : Icons.person_add,
                        size: 18,
                      ),
                      label: Text(_selectedFolderName != null ? 'Change Client' : 'Select Client'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _selectedFolderName != null 
                            ? Colors.grey[100] 
                            : const Color(0xFF2E7D32),
                        foregroundColor: _selectedFolderName != null 
                            ? Colors.grey[700] 
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Two Column Layout: Left = Recording Controls, Right = Questions
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // LEFT SIDE - Recording Controls
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [
                        // Waveform Visualization Box
                        Container(
                          height: 140,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                const Color(0xFFE8F5E9),
                                Colors.white,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: const Color(0xFF2E7D32).withOpacity(0.1),
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 20,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: _isRecording || _recordingDuration > 0
                              ? SizedBox(
                                  height: 80,
                                  width: double.infinity,
                                  child: WaveformVisualizer(
                                    level: _currentAmplitude,
                                    isRecording: _isRecording && !_isPaused,
                                  ),
                                )
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.graphic_eq, size: 48, color: Colors.grey[300]),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Waveform Visualization',
                                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                                    ),
                                  ],
                                ),
                        ),
                        const SizedBox(height: 12),
                        
                        // Duration Timer
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _isRecording && !_isPaused 
                                  ? Icons.fiber_manual_record 
                                  : Icons.access_time,
                              color: _isRecording && !_isPaused 
                                  ? Colors.red 
                                  : const Color(0xFF2E7D32),
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _formatDuration(_recordingDuration),
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2E7D32),
                                fontFeatures: [FontFeature.tabularFigures()],
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        
                        // Microphone Recording Controls
                        if (_isRecording || _recordingDuration > 0)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Pause/Resume Button
                              InkWell(
                                onTap: _isPaused ? _resumeRecording : _pauseRecording,
                                borderRadius: BorderRadius.circular(50),
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withOpacity(0.1),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.orange, width: 2),
                                  ),
                                  child: Icon(
                                    _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                    color: Colors.orange,
                                    size: 32,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 32),
                              // STOP Button (Main)
                              InkWell(
                                onTap: _stopRecording,
                                borderRadius: BorderRadius.circular(50),
                                child: Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withOpacity(0.1),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.red, width: 4),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.red.withOpacity(0.3),
                                        blurRadius: 15,
                                        spreadRadius: 2,
                                      )
                                    ],
                                  ),
                                  child: const Icon(Icons.stop_rounded, color: Colors.red, size: 48),
                                ),
                              ),
                            ],
                          )
                        else
                          // START Button
                          InkWell(
                            onTap: _selectedFolderName == null 
                              ? () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Please select a client first before recording'),
                                      backgroundColor: Colors.orange,
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                  _showRecordingClientDialog();
                                }
                              : _startRecording,
                            borderRadius: BorderRadius.circular(50),
                            child: Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: _selectedFolderName == null
                                    ? Colors.grey.withOpacity(0.1)
                                    : const Color(0xFF2E7D32).withOpacity(0.1),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _selectedFolderName == null
                                      ? Colors.grey
                                      : const Color(0xFF2E7D32),
                                  width: 3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: (_selectedFolderName == null
                                            ? Colors.grey
                                            : const Color(0xFF2E7D32))
                                        .withOpacity(0.3),
                                    blurRadius: 15,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.mic_rounded,
                                size: 48,
                                color: _selectedFolderName == null
                                    ? Colors.grey
                                    : const Color(0xFF2E7D32),
                              ),
                            ),
                          ),
                        // Disabled hint text
                        if (_selectedFolderName == null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Select a client to enable recording',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500], fontStyle: FontStyle.italic),
                          ),
                        ],
                        const SizedBox(height: 16),
                        
                        // Real-time Transcription Box
                        Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(minHeight: 180, maxHeight: 300),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFF2E7D32).withOpacity(0.2),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 15,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.transcribe,
                                    color: Color(0xFF2E7D32),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'Real-time Transcription',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF263238),
                                    ),
                                  ),
                                  const Spacer(),
                                  if (_isRecording && !_isPaused)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.red.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 5,
                                            height: 5,
                                            decoration: const BoxDecoration(
                                              color: Colors.red,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                          const Text(
                                            'Live',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.red,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              const Divider(height: 1),
                              const SizedBox(height: 10),
                              Flexible(
                                child: SingleChildScrollView(
                                  child: Text(
                                    _currentTranscript.isNotEmpty
                                        ? _currentTranscript
                                        : _isRecording 
                                            ? 'Listening for speech...'
                                            : 'Start recording to see live transcription',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: _currentTranscript.isNotEmpty
                                          ? Colors.black87
                                          : Colors.grey[400],
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(width: 24),
                  
                  // RIGHT SIDE - Suggested Questions
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.grey[300]!,
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.lightbulb_outline,
                                color: Color(0xFF2E7D32),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Suggested Questions',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF263238),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          _buildQuestionItem('Tell me about your day'),
                          _buildQuestionItem('How are you feeling today?'),
                          _buildQuestionItem('What\'s on your mind?'),
                          _buildQuestionItem('Describe your recent mood'),
                          _buildQuestionItem('Share something that happened today'),
                          _buildQuestionItem('How has your week been?'),
                          _buildQuestionItem('Tell me about any challenges you\'re facing'),
                          _buildQuestionItem('What are you grateful for?'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Helper function to build control buttons
  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 28),
      label: Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        elevation: 3,
      ),
    );
  }

  // Format duration to HH:MM:SS
  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  // Recording control functions (placeholder implementations)
  Future<void> _startRecording() async {
    // Ensure a client is selected before recording
    if (_selectedFolderName == null) {
      _showRecordingClientDialog();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a client before recording'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    try {
      final session = await _audioService.startRecording();
      if (session != null) {
        // Clear previous amplitude data
        _amplitudeLevels.clear();
        
        print('🎙️ Started recording via Unified Service');
      
        // Start Web Speech Recognition
        if (_isSpeechAvailable && _speechRecognition != null) {
          _currentTranscript = ""; // Clear previous
          _speechRecognition!.start();
          print('🗣️ Speech Recognition Started');
        }

        // Start timer
        _recordingDuration = 0;
        setState(() {
          _isRecording = true;
          _isPaused = false;
        });
        
        // Start timer
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted) { timer.cancel(); return; }
          if (_isRecording && !_isPaused) {
            setState(() {
              _recordingDuration++;
            });
          }
        });
        
        // Listen to amplitude for visualization (Service provides normalized 0-100 values)
        _amplitudeSub = _audioService.amplitudeStream.listen((level) {
           if (!mounted) return;
           
           setState(() {
             _currentAmplitude = level;
           });
        });
        
        print('🎙️ Started recording for client: $_selectedFolderName');
      } else {
         ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      print('❌ Error starting recording: $e');
       ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error starting recording: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _pauseRecording() async {
    await _audioService.pauseRecording();
    setState(() {
      _isPaused = true;
    });
  }

  Future<void> _resumeRecording() async {
    await _audioService.resumeRecording();
    setState(() {
      _isPaused = false;
    });
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _amplitudeSub?.cancel();
    
    setState(() {
      _isRecording = false;
      _isPaused = false;
    });
    
    // Stop Speech Recognition
    if (_isSpeechAvailable && _speechRecognition != null) {
      _speechRecognition!.stop();
      print('🗣️ Speech Recognition Stopped. Final: $_currentTranscript');
    }

    try {
      final path = await _audioService.stopRecording();
      if (path == null) {
        throw Exception('Recording stop failed: No path returned');
      }
      
      print('🎙️ Recording stopped. processing...');
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Processing recording...'),
          duration: Duration(seconds: 2), 
          backgroundColor: Colors.blue,
        ),
      );

      final filename = 'web_rec_${DateTime.now().millisecondsSinceEpoch}.wav';
      
      // 1. Get Audio Bytes
      final response = await http.get(Uri.parse(path));
      if (response.statusCode != 200) throw Exception('Failed to get blob data');
      final audioBytes = response.bodyBytes;
      
      // 2. SAVE LOCALLY (Trigger Browser Download)
      // This mimics "Saving to device storage"
      final blob = html.Blob([audioBytes]);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..setAttribute("download", filename)
        ..click();
      html.Url.revokeObjectUrl(url);
      print('💾 Download triggered: $filename');
      
      // 3. Save "Recordings" Metadata to Firestore
      // We use the filename as ID or just auto-id
      final docRef = await FirebaseFirestore.instance.collection('recordings').add({
        'admin_id': _currentAdminId,
        'folder_name': _selectedFolderName,
        'file_name': filename,
        'audio_name': filename,
        'date': Timestamp.now(),
        'created_at': DateTime.now().toIso8601String(),
        'duration': _formatDuration(_recordingDuration),
        'duration_seconds': _recordingDuration,
        'status': 'processed', 
        'has_analysis': false, // Will become true after analysis
        'source': 'web_dashboard',
        'transcription': _currentTranscript, // Save initial transcription
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Analyzing audio biomarkers...'),
          duration: Duration(seconds: 10),
          backgroundColor: Colors.orange,
        ),
      );
      
      // 4. PROCESS & ANALYZE (Send to Python API)
      await _processAnalysis(audioBytes, filename, docRef.id);
      
    } catch (e) {
      print('❌ Error saving/processing: $e');
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // Send audio to Python API for analysis
  Future<void> _processAnalysis(Uint8List audioBytes, String filename, String recordingId) async {
    try {
      // Create Multipart Request to local Python server
      // Note: Python API must be running on localhost:5001
      var request = http.MultipartRequest('POST', Uri.parse('http://127.0.0.1:5001/analyze'));
      
      // Add Audio File
      request.files.add(http.MultipartFile.fromBytes(
        'audio', 
        audioBytes, 
        filename: filename
      ));
      
      // Add transcript (from Web Speech API)
      request.fields['transcript'] = _currentTranscript;
      print('📝 Sending transcript: $_currentTranscript'); 

      print('🚀 Sending to API...');
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (!mounted) return;

      if (response.statusCode == 200) {
         print('✅ API Analysis Complete');
         final result = jsonDecode(response.body);
         
         // 1. Prepare Data Matching Mobile Schema
         final Map<String, dynamic> severity = {
           'level': result['severity']['level'],
           'confidence': result['severity']['confidence'],
           'probabilities': result['severity']['probabilities'],
         };
         
         final Map<String, dynamic> emotion = {
           'label': result['emotion']['label'],
           'confidence': result['emotion']['confidence'],
         };
         
         // Fix Anxiety Indicators List validation
         final List<dynamic> anxietyRaw = result['anxiety_indicators'] ?? [];
         final List<Map<String, dynamic>> anxietyIndicators = anxietyRaw.map((i) => {
           'name': i['name'],
           'detected': i['detected'],
           'probability': i['probability'],
           'threshold': i['threshold'] ?? 0.0,
           'supporting_evidence': i['supporting_evidence'], // Pass through supporting evidence
         }).toList().cast<Map<String, dynamic>>();

         // 2. Save to 'biomarker_results' collection
         final docRef = await FirebaseFirestore.instance.collection('biomarker_results').add({
           'admin_id': _currentAdminId,
           'folder_name': _selectedFolderName,
           'recording_id': recordingId,
           'file_name': filename,
           'audio_name': filename,
           'date': Timestamp.now(),
           'transcript': result['transcript'] ?? _currentTranscript,
           'transcription': result['transcript'] ?? _currentTranscript, // Redundancy for safety
           
           // Structured Analysis Data
           'severity': severity,
           'emotion': emotion,
           'anxietyIndicators': anxietyIndicators, // CamelCase matching mobile model
           'detectedConditions': result['detected_conditions'] ?? [],
           'summary': result['summary'] ?? '',
           'processingTimeMs': result['processing_time_ms'] ?? 0,
           'extractedFeatures': result['features'], // Also keep in main doc for quick access if needed
         });
         
         print('✅ Saved biomarker result ID: ${docRef.id}');

         // 3. Save Features to Subcollection (Critical for detailed charts)
         if (result['features'] != null) {
           await docRef.collection('extracted_features').doc('all_features').set(
             Map<String, dynamic>.from(result['features'])
           );
           print('✅ Saved extracted_features subcollection');
         }
         
         // 4. Update 'recordings' document to link success
         await FirebaseFirestore.instance.collection('recordings').doc(recordingId).update({
           'has_analysis': true,
           'severity': result['severity']['level'],
           'severity_score': result['severity']['confidence'], // Helpful for sorting
           'emotion_label': result['emotion']['label'],
           'transcription': result['transcript'] ?? _currentTranscript,
           'biomarker_result_id': docRef.id, // Direct link
         });
         
         // 5. Update UI
         final now = DateTime.now();
         const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
         final formattedDate = '${months[now.month - 1]} ${now.day}, ${now.year} • ${now.hour > 12 ? now.hour - 12 : now.hour}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';

         ScaffoldMessenger.of(context).hideCurrentSnackBar();
         ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Analysis Complete! Report Generated.'),
            backgroundColor: Colors.purple,
            duration: Duration(seconds: 2),
          ),
        );
        
        // Auto-open Analysis View
        setState(() {
          _selectedAnalysisRecording = {
            'id': recordingId,
            'name': filename,
            'folder_name': _selectedFolderName ?? '',
            'date': formattedDate,
            'duration': _formatDuration(_recordingDuration),
            'admin_id': _currentAdminId ?? '',
            'transcription': result['transcript'] ?? _currentTranscript,
          };
        });
        
      } else {
        throw Exception('API Error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('❌ Analysis Failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Analysis Failed: Is Python server running?'),
          backgroundColor: Colors.red,
          action: SnackBarAction(label: 'Retry', onPressed: () {}),
        ),
      );
    }
  }

  void _playRecording() {
    setState(() {
      _isPlaying = true;
    });
    // TODO: Implement playback using audioplayers if needed
    // Auto-stop after duration
    Timer(Duration(seconds: _recordingDuration), () {
      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
      }
    });
  }

  void _pausePlayback() {
    setState(() {
      _isPlaying = false;
    });
    // TODO: Pause playback
  }

  // Build question list item (simple text with bullet)
  Widget _buildQuestionItem(String question) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFF2E7D32),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              question,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[700],
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _deleteRecording() {
    setState(() {
      _recordingDuration = 0;
      _isPlaying = false;
    });
    // TODO: Delete recorded file
  }

  Widget _buildRecordingsPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stats summary
          Row(
            children: [
              Expanded(child: _buildStatCard('Total Recordings', _getTotalRecordings().toString(), '', Icons.audiotrack)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('Clients', _clients.length.toString(), 'registered', Icons.people)),
              const SizedBox(width: 20),
              Expanded(child: _buildStatCard('Storage', _getTotalStorageUsed(), '', Icons.storage)),
            ],
          ),
          const SizedBox(height: 40),
          
          // Combine folders from recordings AND clients with 0 recordings
          ...(() {
            // Start with all folders from recordings
            Map<String, List<Map<String, dynamic>>> allFoldersWithClients = Map.from(_allFolders);
            
            // Add any clients that don't have recordings yet
            for (var client in _clients) {
              final folderName = client['folder_name'] ?? client['full_name'] ?? 'Unknown';
              if (!allFoldersWithClients.containsKey(folderName)) {
                allFoldersWithClients[folderName] = []; // Empty recordings
              }
            }
            
            if (allFoldersWithClients.isEmpty) {
              return [
                Container(
                  padding: const EdgeInsets.all(60),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.folder_open, size: 80, color: Colors.grey[300]),
                        const SizedBox(height: 20),
                        Text('No recordings yet', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
                        const SizedBox(height: 8),
                        Text('Start recording from the mobile app', style: TextStyle(color: Colors.grey[400])),
                      ],
                    ),
                  ),
                )
              ];
            }
            
            return allFoldersWithClients.entries.map((entry) => _buildFolderCard(entry.key, entry.value)).toList();
          })(),
        ],
      ),
    );
  }

  Widget _buildFolderCard(String folderName, List<Map<String, dynamic>> recordings) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.folder, color: Color(0xFF2E7D32)),
        ),
        title: Text(
          folderName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Text(
          '${recordings.length} recording${recordings.length == 1 ? '' : 's'}',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
        children: recordings.map((recording) => _buildRecordingListItem(recording, folderName)).toList(),
      ),
    );
  }

  Widget _buildRecordingListItem(Map<String, dynamic> recording, String folderName) {
    return InkWell(
      onTap: () => _showTranscriptionDialog(recording),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.grey[200]!)),
        ),
        child: Row(
          children: [
            // Audio Play Button (visual indicator)
            Tooltip(
              message: 'Audio stored on mobile device',
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2E7D32), Color(0xFF4CAF50)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF2E7D32).withOpacity(0.3),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 22),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recording['name'] ?? 'Unknown',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recording['date'] ?? '',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    recording['duration'] ?? '00:00',
                    style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2E7D32), fontSize: 13),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  recording['size'] ?? '',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Transcription indicator
            Tooltip(
              message: (recording['transcription'] ?? '').isNotEmpty 
                  ? 'Has transcription' 
                  : 'No transcription',
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (recording['transcription'] ?? '').isNotEmpty 
                      ? const Color(0xFFE8F5E9) 
                      : Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  (recording['transcription'] ?? '').isNotEmpty ? Icons.description : Icons.description_outlined,
                  color: (recording['transcription'] ?? '').isNotEmpty ? const Color(0xFF2E7D32) : Colors.grey[400],
                  size: 18,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTranscriptionDialog(Map<String, dynamic> recording) {
    final transcription = recording['transcription'] ?? '';
    final hasTranscription = transcription.isNotEmpty;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.audiotrack, color: Color(0xFF2E7D32)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    recording['name'] ?? 'Recording',
                    style: const TextStyle(fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  recording['duration'] ?? '',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(width: 16),
                Text(
                  recording['size'] ?? '',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(width: 16),
                Text(
                  recording['date'] ?? '',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ],
        ),
        content: Container(
          width: 500,
          constraints: const BoxConstraints(maxHeight: 400),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Transcription',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 12),
                if (hasTranscription)
                  SelectableText(
                    transcription,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.info_outline, color: Colors.grey[400]),
                        const SizedBox(width: 8),
                        Text(
                          'No transcription available for this recording',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (hasTranscription)
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _showPredictionAnalytics(recording);
              },
              icon: const Icon(Icons.analytics_outlined, size: 18),
              label: const Text('View Prediction Analytics'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showPredictionAnalytics(Map<String, dynamic> recording) {
    setState(() {
      _selectedAnalysisRecording = recording;
    });
  }

  Widget _buildAnalyticsSection(String title, dynamic data, IconData icon, Color color, {bool isPill = false, bool isList = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (isList)
          Wrap(
            spacing: 8,
            children: (data as List<String>).map((item) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withOpacity(0.3)),
              ),
              child: Text(
                item,
                style: TextStyle(color: color.withOpacity(0.9), fontWeight: FontWeight.w500),
              ),
            )).toList(),
          )
        else if (isPill)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Text(
              data.toString(),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          )
        else
          Text(data.toString(), style: const TextStyle(fontSize: 16)),
      ],
    );
  }

  // ========== EXPORT REPORT DIALOG ==========
  void _showExportReportDialog(BuildContext context, Map<String, dynamic> recording, Map<String, dynamic>? matchingResult) {
    // Get client info
    final folderName = recording['folder_name'] ?? recording['folder'] ?? '';
    final client = _clients.firstWhere(
      (c) => c['folder_name']?.toString() == folderName.toString(),
      orElse: () => {'full_name': folderName, 'folder_name': folderName},
    );
    
    // Extract analysis data
    String severity = 'Unknown';
    Color severityColor = Colors.grey;
    String emotion = 'Unknown';
    double emotionConfidence = 0;
    List<Map<String, dynamic>> allIndicators = [];
    String transcript = recording['transcription'] ?? '';
    
    if (matchingResult != null) {
      final severityRaw = matchingResult['severity'];
      if (severityRaw is Map) {
        severity = severityRaw['level']?.toString() ?? 'Normal';
      } else if (severityRaw is String) {
        severity = severityRaw;
      } else {
        severity = matchingResult['severity_level']?.toString() ?? 'Normal';
      }
      
      if (severity.toLowerCase() == 'severe') severityColor = Colors.red;
      else if (severity.toLowerCase() == 'moderate') severityColor = Colors.orange;
      else severityColor = Colors.green;
      
      final emotionRaw = matchingResult['emotion'];
      if (emotionRaw is Map) {
        emotion = emotionRaw['label']?.toString() ?? 'Neutral';
        emotionConfidence = (emotionRaw['confidence'] as num?)?.toDouble() ?? 0;
      } else if (emotionRaw is String) {
        emotion = emotionRaw;
        emotionConfidence = (matchingResult['emotion_confidence'] as num?)?.toDouble() ?? 0;
      }
      
      final indicators = matchingResult['anxiety_indicators'] as List<dynamic>? ?? [];
      for (var indicator in indicators) {
        if (indicator is Map<String, dynamic>) {
          allIndicators.add(indicator);
        }
      }
      
      transcript = matchingResult['transcript']?.toString() ?? recording['transcription'] ?? '';
    }
    
    // Separate anxiety vs educational
    const educationalNames = {
      'Impostor Syndrome', 'Academic Burnout', 'Perfectionism',
      'Fear Of Failure', 'Fear of Failure', 'Test Anxiety',
      'Low Self-Esteem', 'Low Self Esteem',
      'Lack of Support', 'Lack Of Academic Support',
      'Pressure', 'Pressure Of Surroundings',
      'Poor Time Management'
    };
    
    List<Map<String, dynamic>> anxietyIndicators = [];
    List<Map<String, dynamic>> educationalIndicators = [];
    
    for (var indicator in allIndicators) {
      final name = indicator['name']?.toString() ?? '';
      final detected = indicator['detected'] == true;
      if (detected && name.isNotEmpty) {
        if (educationalNames.contains(name)) {
          educationalIndicators.add(indicator);
        } else {
          anxietyIndicators.add(indicator);
        }
      }
    }
    
    // Get negative/absolutist words
    final negativeWords = matchingResult?['negative_matches'] as List? ?? [];
    final absolutistWords = matchingResult?['absolutist_matches'] as List? ?? [];
    
    // Get audio features
    final jitter = (matchingResult?['jitter'] as num?)?.toDouble() ?? 0;
    final shimmer = (matchingResult?['shimmer'] as num?)?.toDouble() ?? 0;
    final hnr = (matchingResult?['hnr'] as num?)?.toDouble() ?? 0;
    
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 800,
          height: MediaQuery.of(context).size.height * 0.9,
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFF2E7D32),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.description, color: Colors.white, size: 28),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Audio Biomarker Analysis Report',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.print, color: Colors.white),
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Print functionality coming soon!')),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              
              // Report Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // CLIENT INFORMATION
                      Row(
                        children: [
                          const Icon(Icons.person, size: 18, color: Colors.blue),
                          const SizedBox(width: 8),
                          const Text('Client Information', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 32, runSpacing: 8,
                        children: [
                          _buildReportField('Full Name', client['full_name']?.toString() ?? 'N/A'),
                          _buildReportField('Age', client['age']?.toString() ?? 'N/A'),
                          _buildReportField('Birthday', _formatBirthday(client['birthday'])),
                          _buildReportField('School Year', client['school_year']?.toString() ?? 'N/A'),
                          _buildReportField('Gender', client['gender']?.toString() ?? 'N/A'),
                          _buildReportField('Phone', client['phone_number']?.toString() ?? 'N/A'),
                        ],
                      ),
                      
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      
                      // PREDICTION ANALYTICS
                      Row(
                        children: [
                          const Icon(Icons.analytics, size: 18, color: Colors.purple),
                          const SizedBox(width: 8),
                          const Text('Prediction Analytics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.purple)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: severityColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: severityColor.withOpacity(0.3)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Severity Level', style: TextStyle(fontSize: 12, color: severityColor)),
                                  Text(severity, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: severityColor)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.purple.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.purple.withOpacity(0.3)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Detected Emotion', style: TextStyle(fontSize: 12, color: Colors.purple)),
                                  Text(emotion, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.purple)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 16),
                      
                      // Anxiety & Educational
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Anxiety Indicators', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6, runSpacing: 6,
                                    children: anxietyIndicators.isEmpty
                                      ? [const Chip(label: Text('None Detected', style: TextStyle(fontSize: 11)))]
                                      : anxietyIndicators.map((i) => Chip(
                                          label: Text('${i['name']} (${i['probability']}%)', style: const TextStyle(fontSize: 11)),
                                          backgroundColor: Colors.white,
                                        )).toList(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.teal.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Educational Insights', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6, runSpacing: 6,
                                    children: educationalIndicators.isEmpty
                                      ? [const Chip(label: Text('No Issues', style: TextStyle(fontSize: 11)))]
                                      : educationalIndicators.map((i) => Chip(
                                          label: Text('${i['name']} (${i['probability']}%)', style: const TextStyle(fontSize: 11)),
                                          backgroundColor: Colors.white,
                                        )).toList(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      
                      // AI SUMMARY
                      Row(
                        children: [
                          const Icon(Icons.auto_awesome, size: 18, color: Colors.deepPurple),
                          const SizedBox(width: 8),
                          const Text('AI Analysis Summary', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.deepPurple)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.deepPurple.withOpacity(0.2)),
                        ),
                        child: Text(
                          matchingResult?['summary']?.toString() ?? 
                          recording['summary']?.toString() ?? 
                          'No summary available for this recording.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.black87,
                            height: 1.5,
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      
                      // CONFIDENCE ANALYSIS
                      if (allIndicators.where((i) => i['detected'] == true).isNotEmpty) ...[
                        Row(
                          children: [
                            const Icon(Icons.bar_chart, size: 18, color: Colors.blue),
                            const SizedBox(width: 8),
                            const Text('Confidence Analysis', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ...allIndicators.where((i) => i['detected'] == true).take(5).map((indicator) {
                          final prob = (indicator['probability'] as num?)?.toInt() ?? 0;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              children: [
                                SizedBox(width: 150, child: Text(indicator['name'] ?? '', style: const TextStyle(fontSize: 13))),
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: prob / 100,
                                      backgroundColor: Colors.grey[200],
                                      valueColor: AlwaysStoppedAnimation(prob > 70 ? Colors.red : prob > 50 ? Colors.orange : Colors.green),
                                      minHeight: 12,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text('$prob%', style: TextStyle(fontWeight: FontWeight.bold, color: prob > 70 ? Colors.red : prob > 50 ? Colors.orange : Colors.green)),
                              ],
                            ),
                          );
                        }).toList(),
                        const SizedBox(height: 24),
                        const Divider(),
                        const SizedBox(height: 16),
                      ],
                      
                      // CLINICAL BIOMARKERS
                      Row(
                        children: [
                          const Icon(Icons.science, size: 18, color: Colors.indigo),
                          const SizedBox(width: 8),
                          const Text('Clinical Biomarkers', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.indigo)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12, runSpacing: 12,
                        children: [
                          _buildBiomarkerTag('Tremor', jitter > 0.03 ? 'Detected' : 'Normal', jitter > 0.03 ? Colors.orange : Colors.green),
                          _buildBiomarkerTag('Breathing', shimmer > 0.15 ? 'Irregular' : 'Steady', shimmer > 0.15 ? Colors.orange : Colors.green),
                          _buildBiomarkerTag('Tension', hnr < 10 && hnr > 0 ? 'Tense' : 'Relaxed', hnr < 10 && hnr > 0 ? Colors.orange : Colors.green),
                          _buildBiomarkerTag('Distress', '${negativeWords.length}', negativeWords.isNotEmpty ? Colors.red : Colors.green),
                        ],
                      ),
                      
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      
                      // TRANSCRIPTION
                      Row(
                        children: [
                          const Icon(Icons.record_voice_over, size: 18, color: Colors.blueGrey),
                          const SizedBox(width: 8),
                          const Text('Analyzed Transcription', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.grey[50],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: SelectableText(
                          transcript.isNotEmpty ? transcript : 'No transcription available',
                          style: TextStyle(
                            fontSize: 13,
                            fontStyle: transcript.isEmpty ? FontStyle.italic : FontStyle.normal,
                            color: transcript.isEmpty ? Colors.grey : Colors.black87,
                            height: 1.5,
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 24),
                      Center(
                        child: Text(
                          'Generated on ${DateTime.now().toString().substring(0, 19)} • Audio Biomarker Analysis System',
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildReportField(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      ],
    );
  }
  
  Widget _buildBiomarkerTag(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: const TextStyle(fontSize: 12)),
          Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildPredictionAnalysisPage() {
    final recording = _selectedAnalysisRecording!;
    
    // Find matching biomarker result
    final recordingName = recording['name'] ?? '';
    final folderName = recording['folder_name'] ?? recording['folder'] ?? '';
    final matchingResult = _findMatchingBiomarkerResult(recording);
    
    // Extract real data
    String severity = 'Unknown';
    Color severityColor = Colors.grey;
    String emotion = 'Unknown';
    List<String> anxietyTypes = [];
    List<String> educationalIssues = [];
    
    if (matchingResult != null) {
      final severityRaw = matchingResult['severity'];
      if (severityRaw is Map) {
         severity = severityRaw['level']?.toString() ?? 'Normal';
      } else if (severityRaw is String) {
         severity = severityRaw;
      } else {
         severity = 'Normal';
      }
      
      if (severity.toLowerCase() == 'severe') severityColor = Colors.red;
      else if (severity.toLowerCase() == 'moderate') severityColor = Colors.orange;
      else severityColor = Colors.green;
      
      final emotionRaw = matchingResult['emotion'];
      if (emotionRaw is Map) {
         emotion = emotionRaw['label']?.toString() ?? 'Neutral';
      } else if (emotionRaw is String) {
         emotion = emotionRaw;
      } else {
         emotion = 'Neutral';
      }
      
      final indicators = matchingResult['anxiety_indicators'] as List<dynamic>? ?? [];
      const educationalNames = {
        'Impostor Syndrome', 'Academic Burnout', 'Perfectionism', 
        'Fear Of Failure', 'Fear of Failure', 'Test Anxiety',
        'Low Self-Esteem', 'Low Self Esteem',
        'Lack of Support', 'Lack Of Academic Support',
        'Pressure', 'Pressure Of Surroundings',
        'Poor Time Management'
      };
      
      for (var indicator in indicators) {
        final name = indicator['name']?.toString() ?? '';
        final detected = indicator['detected'] == true;
        final probability = (indicator['probability'] as num?)?.toInt() ?? 0;
        
        if (detected && name.isNotEmpty) {
          if (educationalNames.contains(name)) educationalIssues.add('$name ($probability%)');
          else anxietyTypes.add('$name ($probability%)');
        }
      }
    }
    
    if (anxietyTypes.isEmpty) anxietyTypes.add('None Detected');
    if (educationalIssues.isEmpty) educationalIssues.add('No Significant Issues');

    return Container(
      color: const Color(0xFFF5F7FA),
      child: Column(
        children: [
          // Header (Compact)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedAnalysisRecording = null),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recording['name'] ?? 'Recording Analysis',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(recording['date'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                          const SizedBox(width: 12),
                          Icon(Icons.timer, size: 12, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text(recording['duration'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                        ],
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () { 
                     _showExportReportDialog(context, recording, matchingResult);
                  },
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export Report', style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
          
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Client Information - FULL WIDTH
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                       boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 5)],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Client Information', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),
                        Builder(builder: (context) {
                          final folderName = recording['folder_name'];
                          final client = _clients.firstWhere(
                            (c) => c['folder_name'].toString() == folderName.toString(),
                            orElse: () => {'full_name': folderName ?? 'Unknown', 'folder_name': folderName},
                          );
                          
                          return Wrap(
                            spacing: 32, runSpacing: 12,
                            children: [
                               _buildInfoItem('Full Name', client['full_name']?.toString() ?? 'N/A'),
                               _buildInfoItem('Age', client['age']?.toString() ?? 'N/A'),
                               _buildInfoItem('Birthday', _formatBirthday(client['birthday'])),
                               _buildInfoItem('School Year', client['school_year']?.toString() ?? 'N/A'),
                               _buildInfoItem('Gender', client['gender']?.toString() ?? 'N/A'),
                               _buildInfoItem('Phone', client['phone_number']?.toString() ?? 'N/A'),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Prediction Analytics - FULL WIDTH
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                       boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 5)],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Prediction Analytics', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(child: _buildCompactAnalyticsItem('Severity Level', severity, severityColor)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildCompactAnalyticsItem('Detected Emotion', emotion, Colors.purple)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withOpacity(0.04),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.blue.withOpacity(0.1)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Anxiety Indicators', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 6, runSpacing: 6,
                                      children: anxietyTypes.map((t) => Chip(
                                        label: Text(t, style: const TextStyle(fontSize: 10, color: Colors.blueGrey)),
                                        backgroundColor: Colors.white,
                                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: Colors.blueGrey.withOpacity(0.1))),
                                      )).toList(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.teal.withOpacity(0.04),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.teal.withOpacity(0.1)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Educational Insights', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal)),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 6, runSpacing: 6,
                                      children: educationalIssues.map((t) => Chip(
                                        label: Text(t, style: const TextStyle(fontSize: 10, color: Colors.teal)),
                                        backgroundColor: Colors.white,
                                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: Colors.teal.withOpacity(0.1))),
                                      )).toList(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // AI Summary Box - fetched from Firebase biomarker_results
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.deepPurple.withOpacity(0.2)),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 5)],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.auto_awesome, size: 18, color: Colors.deepPurple),
                            const SizedBox(width: 8),
                            const Text('AI Analysis Summary', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.deepPurple)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          matchingResult?['summary']?.toString() ?? 
                          recording['summary']?.toString() ?? 
                          'No summary available for this recording.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.black87,
                            height: 1.5,
                            fontStyle: (matchingResult?['summary'] == null && recording['summary'] == null) 
                              ? FontStyle.italic 
                              : FontStyle.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Waveform/Audio Analysis - FULL WIDTH (above anxiety conditions)
                  Container(
                    height: 120,
                    padding: const EdgeInsets.all(16),
                     decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                       boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 5)],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Audio Analysis', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFFAFAFA),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey[200]!),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Visualizer
                                Builder(builder: (context) {
                                   List<dynamic> wave = (recording['waveform_data'] as List<dynamic>?) 
                                      ?? (matchingResult?['extracted_features'] as Map<String, dynamic>?)?['waveform'] 
                                      ?? [];
                                   
                                   if (wave.isEmpty) {
                                      return Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: List.generate(80, (i) => Container(
                                          margin: const EdgeInsets.symmetric(horizontal: 1),
                                          width: 3,
                                          height: 10.0 + (i % 5) * 6,
                                          color: const Color(0xFF2E7D32).withOpacity(0.5),
                                        )),
                                      );
                                   }
                                   
                                   int startIndex = 0;
                                   for (int i = 0; i < wave.length; i++) {
                                     if ((wave[i] as num).toDouble() > 0.1) {
                                       startIndex = i;
                                       break;
                                     }
                                   }
                                   List<dynamic> activeWave = wave.sublist(startIndex);
                                   
                                   return Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: activeWave.map((val) {
                                         double rawVal = (val as num).toDouble();
                                         double norm = rawVal > 1.0 ? (rawVal / 100.0).clamp(0.0, 1.0) : rawVal.clamp(0.0, 1.0);
                                         double h = norm * 40.0;
                                         if (h < 3) h = 3;
                                         return Container(
                                            margin: const EdgeInsets.symmetric(horizontal: 0.5),
                                            width: 3,
                                            height: h,
                                            decoration: BoxDecoration(
                                              color: Color(0xFF2E7D32).withOpacity((0.5 + (norm * 0.5)).clamp(0.0, 1.0)),
                                              borderRadius: BorderRadius.circular(1)
                                            ),
                                         );
                                      }).toList(),
                                   );
                                }),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Row: Specific Anxiety Conditions (left) + Transcription (right)
                  Builder(builder: (context) {
                     List<dynamic> allInds = matchingResult?['anxiety_indicators'] as List<dynamic>? ?? [];
                     final clinicalNames = ['Social Anxiety', 'GAD', 'Agoraphobia', 'Panic Disorder', 'PTSD'];
                     var clinical = allInds.where((i) => clinicalNames.contains(i['name'])).toList();
                     
                     return Row(
                       crossAxisAlignment: CrossAxisAlignment.start,
                       children: [
                         // Specific Anxiety Conditions (left)
                         Expanded(
                           flex: 2,
                           child: _buildConditionAnalytics(
                               "Specific Anxiety Conditions", 
                               "Deep dive into specific anxiety types and their multimodal triggers.", 
                               clinical, 
                               matchingResult?['extracted_features'] as Map<String, dynamic>?,
                               isEducational: false,
                               transcript: recording['transcription'] as String?
                           ),
                         ),
                         const SizedBox(width: 16),
                         // Transcription (right)
                         Expanded(
                           flex: 1,
                           child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                 boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 5)],
                              ),
                              child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Transcription', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 12),
                                Container(
                                  constraints: const BoxConstraints(minHeight: 150),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFAFAFA),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: SingleChildScrollView(
                                    child: _buildHighlightedTranscript(
                                      recording['transcription']?.isNotEmpty == true ? recording['transcription']! : 'No transcription available.',
                                      matchingResult?['extracted_features'] as Map<String, dynamic>?
                                    ),
                                  ),
                                ),
                              ],
                            ),
                           ),
                         ),
                       ],
                     );
                  }),
                  
                  const SizedBox(height: 16),
                  
                  // Educational Insights (separate section)
                  Builder(builder: (context) {
                     List<dynamic> allInds = matchingResult?['anxiety_indicators'] as List<dynamic>? ?? [];
                     final clinicalNames = ['Social Anxiety', 'GAD', 'Agoraphobia', 'Panic Disorder', 'PTSD'];
                     var educational = allInds.where((i) => !clinicalNames.contains(i['name'])).toList();
                     
                     return _buildConditionAnalytics(
                         "Educational Insights", 
                         "AI analysis of academic performance and cognitive stressors.", 
                         educational, 
                         matchingResult?['extracted_features'] as Map<String, dynamic>?,
                         isEducational: true,
                         transcript: recording['transcription'] as String?
                     );
                  }),
                  const SizedBox(height: 24),
                  // Explanation & Decision Logic (Neural Emotion Analysis)
                  Builder(builder: (context) {
                    // Handle emotion as either map {label, confidence} or flat string
                    final emotionRaw = matchingResult?['emotion'];
                    String emotionLabel;
                    int emotionConf;
                    if (emotionRaw is Map) {
                      emotionLabel = emotionRaw['label']?.toString() ?? 'Neutral';
                      emotionConf = (emotionRaw['confidence'] as num?)?.toInt() ?? 0;
                    } else {
                      emotionLabel = emotionRaw?.toString() ?? 'Neutral';
                      emotionConf = (matchingResult?['emotion_confidence'] as num?)?.toInt() ?? 0;
                    }
                    // Fallback to extracted_features.detected_emotion if available
                    final features = matchingResult?['extracted_features'] as Map<String, dynamic>?;
                    if (emotionLabel == 'Neutral' || emotionLabel.isEmpty) {
                      emotionLabel = features?['detected_emotion']?.toString() ?? emotionLabel;
                    }
                    if (emotionConf == 0) {
                      emotionConf = ((features?['emotion_confidence'] as num?)?.toDouble() ?? 0.0 * 100).toInt();
                    }
                    return _buildEmotionAnalytics(emotionLabel, emotionConf, features);
                  }),
                  const SizedBox(height: 24),
                  _buildPredictionExplainability(
                    severity, 
                    (matchingResult?['severity_confidence'] as num?)?.toInt() ?? 0,
                     matchingResult?['extracted_features'] as Map<String, dynamic>?,
                     matchingResult?['severity_probabilities'] as Map<String, dynamic>?
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatBirthday(dynamic birthday) {
      if (birthday == null) return 'N/A';
      if (birthday is Timestamp) {
        DateTime date = birthday.toDate();
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return '${months[date.month - 1]} ${date.day}, ${date.year}';
      }
      return birthday.toString();
  }

  Widget _buildCompactAnalyticsItem(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildPredictionExplainability(String severity, int confidence, Map<String, dynamic>? features, [Map<String, dynamic>? probabilities]) {
    // Extract & Format Features
    final jitter = (features?['jitter'] as num?)?.toDouble() ?? 0.0;
    final shimmer = (features?['shimmer'] as num?)?.toDouble() ?? 0.0;
    final hnr = (features?['hnr'] as num?)?.toDouble() ?? 0.0;
    
    // Exact metadata numbers (Formatted)
    // Note: jitter and shimmer from Firebase are already percentage values (e.g., 10 = 10%, not 0.10)
    String jitterVal = '${jitter.toStringAsFixed(3)}%'; 
    String shimmerVal = '${shimmer.toStringAsFixed(3)}%'; 
    String hnrVal = '${hnr.toStringAsFixed(2)} dB'; 
    
    // Probabilities handling
    // First, try to get emotion_confidence from features as a fallback for confidence
    int effectiveConfidence = confidence;
    if (effectiveConfidence == 0 && features != null) {
      // emotion_confidence in Firebase is stored as 0.0-1.0, convert to percentage
      final emotionConf = (features['emotion_confidence'] as num?)?.toDouble() ?? 0.0;
      effectiveConfidence = (emotionConf * 100).toInt();
      // If still 0, use a default confidence of 50
      if (effectiveConfidence == 0) effectiveConfidence = 50;
    }
    
    // Map 'Neutral' emotion to 'Normal' severity if severity is not explicitly set
    String effectiveSeverity = severity;
    if (severity.isEmpty || severity == 'Unknown') {
      final detectedEmotion = features?['detected_emotion']?.toString() ?? '';
      if (detectedEmotion == 'Neutral' || detectedEmotion == 'Happy' || detectedEmotion == 'Calm') {
        effectiveSeverity = 'Normal';
      } else if (detectedEmotion == 'Sad' || detectedEmotion == 'Fear') {
        effectiveSeverity = 'Moderate';
      } else if (detectedEmotion == 'Angry' || detectedEmotion == 'Disgust') {
        effectiveSeverity = 'Severe';
      } else {
        effectiveSeverity = 'Normal'; // Default to Normal
      }
    }
    
    int normalProb = (probabilities?['Normal'] as num?)?.toInt() ?? (effectiveSeverity == 'Normal' ? effectiveConfidence : 0);
    int moderateProb = (probabilities?['Moderate'] as num?)?.toInt() ?? (effectiveSeverity == 'Moderate' ? effectiveConfidence : 0);
    int severeProb = (probabilities?['Severe'] as num?)?.toInt() ?? (effectiveSeverity == 'Severe' ? effectiveConfidence : 0);
    
    // Fill gaps if strictly limited info (e.g. old records)
    if (probabilities == null) {
       int remainder = 100 - effectiveConfidence;
       if (effectiveSeverity == 'Normal') { moderateProb = remainder ~/ 2; severeProb = remainder - moderateProb; }
       else if (effectiveSeverity == 'Moderate') { normalProb = remainder ~/ 2; severeProb = remainder - normalProb; }
       else { normalProb = remainder ~/ 2; moderateProb = remainder - normalProb; }
    }
    
    // Explanation Text
    // Detailed Explanation Logic
    String explanation = "";
    
    if (effectiveSeverity == 'Normal') {
       explanation = "The analysis suggests a **Normal** state ($effectiveConfidence% confidence). ";
       if (jitter < 1.2 && shimmer < 5.0) {
         explanation += "Acoustic biomarkers are well within the healthy baseline. Low Jitter ($jitterVal) and Shimmer ($shimmerVal) indicate consistent and stable vocal fold vibration, typical of a relaxed physiological state.";
       } else {
         explanation += "While overall stable, slight variations in acoustic intensity were noted ($shimmerVal Shimmer), though they remain below the threshold for clinical concern.";
       }
    } else if (effectiveSeverity == 'Moderate') {
       explanation = "The analysis detects **Moderate** signs of anxiety ($effectiveConfidence% confidence). ";
       explanation += "The model identified irregularities in vocal frequency and amplitude. ";
       
       if (jitter > 1.5) {
          explanation += "Elevated Jitter ($jitterVal) points to micro-fluctuations in pitch often caused by muscle tension. ";
       } else if (shimmer > 5.0) {
          explanation += "High Shimmer ($shimmerVal) suggests inconsistent loudness control, a common indicator of underlying stress. ";
       } else {
          explanation += "Combined acoustic features deviate from the stable baseline, consistent with elevated stress levels. ";
       }
    } else if (effectiveSeverity == 'Severe') {
       explanation = "The analysis indicates a **Severe** anxiety classification ($effectiveConfidence% confidence). ";
       explanation += "Significant acoustic perturbations were detected. ";
       
       if (hnr < 20) {
         explanation += "A low Harmonics-to-Noise Ratio ($hnrVal) suggests breathiness or 'noise' in the speech signal, a strong biomarker for high-anxiety states. ";
       }
       explanation += "High vocal instability (Jitter $jitterVal) combined with these features strongly correlates with acute physiological distress.";
    } else {
       explanation = "The model predicts a $effectiveSeverity level ($effectiveConfidence%). Acoustic markers include Jitter ($jitterVal), Shimmer ($shimmerVal), and HNR ($hnrVal).";
    }

    return Container(
       width: double.infinity,
       padding: const EdgeInsets.all(24),
       decoration: BoxDecoration(
         color: Colors.white,
         borderRadius: BorderRadius.circular(16),
         boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0,4))],
       ),
       child: Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
            const Text('Prediction Logic & Explainability', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(explanation, style: TextStyle(color: Colors.grey[700], fontSize: 13, height: 1.5)),
            const SizedBox(height: 24),
            
            // Severity Probabilities Bar (Segmented)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 20,
                child: Row(
                  children: [
                    if (normalProb > 0) Expanded(flex: normalProb, child: Container(color: const Color(0xFF4CAF50))),
                    if (moderateProb > 0) Expanded(flex: moderateProb, child: Container(color: const Color(0xFFFF9800))),
                    if (severeProb > 0) Expanded(flex: severeProb, child: Container(color: const Color(0xFFF44336))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Labels below bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                 _buildProbLabel('Normal', normalProb, const Color(0xFF4CAF50)),
                 _buildProbLabel('Moderate', moderateProb, const Color(0xFFFF9800)),
                 _buildProbLabel('Severe', severeProb, const Color(0xFFF44336)),
              ],
            ),
            
            const SizedBox(height: 32),
            
            // Features Grid
            const Text('Key Acoustic Biomarkers', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: [
                 // Normalize for display: jitter typically 0-5%, shimmer 0-10%, HNR 0-30dB
                 _buildBiomarkerMetric('Vocal Stability (Jitter)', jitterVal, (jitter / 5.0).clamp(0.0, 1.0), Colors.blue),
                 _buildBiomarkerMetric('Amplitude Perturbation (Shimmer)', shimmerVal, (shimmer / 15.0).clamp(0.0, 1.0), Colors.teal),
                 _buildBiomarkerMetric('Harmonic-to-Noise (HNR)', hnrVal, (hnr / 30.0).clamp(0.0, 1.0), Colors.purple),
              ],
            ),
         ],
       ),
    );
  }

  Widget _buildProbLabel(String label, int percent, Color color) {
    return Column(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
        Text('$percent%', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
  
  Widget _buildBiomarkerMetric(String label, String value, double percent, Color color) {
     return Container(
       width: 220,
       padding: const EdgeInsets.all(12),
       decoration: BoxDecoration(
         color: color.withOpacity(0.05),
         borderRadius: BorderRadius.circular(8),
         border: Border.all(color: color.withOpacity(0.2)),
       ),
       child: Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
           Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[700])),
           const SizedBox(height: 4),
           Row(
             mainAxisAlignment: MainAxisAlignment.spaceBetween,
             children: [
               Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
               // Simple bar
               Container(
                 width: 60, height: 4,
                 decoration: BoxDecoration(
                   color: color.withOpacity(0.2),
                   borderRadius: BorderRadius.circular(2),
                 ),
                 alignment: Alignment.centerLeft,
                 child: Container(
                   width: 60 * (percent > 1.0 ? 1.0 : percent),
                   height: 4,
                   decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                 ),
               )
             ],
           )
         ],
       ),
     );
  }

  Widget _buildEmotionAnalytics(String emotion, int confidence, Map<String, dynamic>? features) {
     // Debug: Print what we're receiving
     print('🎯 _buildEmotionAnalytics features keys: ${features?.keys.toList()}');
     print('🎯 pitch_mean: ${features?['pitch_mean']}, energy_mean: ${features?['energy_mean']}');
     
     final pitch = (features?['pitch_mean'] as num?)?.toDouble() ?? 120.0;
     final energy = (features?['energy_mean'] as num?)?.toDouble() ?? 0.05;
     
     // Linguistic
     final negativeCount = (features?['negative_count'] as num?)?.toInt() ?? 0;
     final wordCount = (features?['word_count'] as num?)?.toInt() ?? 1; // avoid div/0
     final absolutistCount = (features?['absolutist_count'] as num?)?.toInt() ?? 0;
     
     // Normalize Pitch (Clamped 80-300)
     double pitchNorm = ((pitch - 80) / (300 - 80)).clamp(0.0, 1.0);
     // Normalize Energy (Clamped 0-0.2)
     double energyNorm = (energy / 0.15).clamp(0.0, 1.0);
     
     return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
         color: Colors.white,
         borderRadius: BorderRadius.circular(16),
         boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0,4))],
       ),
       child: Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
           Row(
             children: [
               Icon(Icons.psychology, color: Colors.purple.shade400),
               const SizedBox(width: 10),
               const Text('Neural Emotion Analysis', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
             ],
           ),
           const SizedBox(height: 8),
           const Text('Breakdown of how detecting acoustic and linguistic patterns determines emotional state.', style: TextStyle(color: Colors.grey, fontSize: 13)),
           const SizedBox(height: 24),
           
           Row(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
                // Acoustic Column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Acoustic Profile (Voice)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      const SizedBox(height: 16),
                      _buildSliderMetric('Pitch (Tone)', pitchNorm, '${pitch.toStringAsFixed(0)} Hz', Colors.blue),
                      const SizedBox(height: 12),
                      _buildSliderMetric('Energy (Intensity)', energyNorm, '${energy.toStringAsFixed(3)} (${floatToLevel(energyNorm)})', Colors.orange),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                // Linguistic Column
                Expanded(
                  child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       const Text('Linguistic Profile (Content)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                       const SizedBox(height: 16),
                       Wrap(
                         spacing: 8, runSpacing: 8,
                         children: [
                           _buildBadge('Negative Words', '$negativeCount', Colors.red),
                           _buildBadge('Absolutist Terms', '$absolutistCount', Colors.purple),
                           _buildBadge('Word Count', '$wordCount', Colors.grey),
                         ],
                       )
                     ],
                  ),
                ),
             ],
           ),
           const SizedBox(height: 24),
           Container(
             padding: const EdgeInsets.all(12),
             decoration: BoxDecoration(color: Colors.purple.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
             child: Row(
               children: [
                 const Icon(Icons.auto_awesome, color: Colors.purple, size: 20),
                 const SizedBox(width: 12),
                 Expanded(
                   child: Text(
                     generateFusionSummary(emotion, confidence, pitchNorm, energyNorm, negativeCount),
                     style: const TextStyle(fontSize: 13, color: Colors.purple, fontStyle: FontStyle.italic),
                   ),
                 ),
               ],
             ),
           )
         ],
       ),
     );
  }

  Widget _buildSliderMetric(String label, double value, String textValue, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text(textValue, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(value: value, color: color, backgroundColor: color.withOpacity(0.1), minHeight: 6),
        ),
      ],
    );
  }

  Widget _buildBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 11)),
        ],
      ),
    );
  }

  String floatToLevel(double val) {
    if (val < 0.3) return 'Low';
    if (val < 0.7) return 'Medium';
    return 'High';
  }

  String generateFusionSummary(String emotion, int confidence, double pitch, double energy, int negCount) {
    String reason = "Predicted **$emotion** (confidence: $confidence%) based on ";
    List<String> factors = [];
    if (emotion == 'Sad' || emotion == 'Neutral') {
       if (pitch < 0.4) factors.add("low vocal pitch");
       if (energy < 0.4) factors.add("subdued energy");
    } else if (emotion == 'Happy' || emotion == 'Angry') {
       if (pitch > 0.6) factors.add("heightened pitch");
       if (energy > 0.6) factors.add("high intensity");
    }
    
    if (negCount > 1) factors.add("use of negative sentiment words");
    
    if (factors.isEmpty) {
       return reason + "a combination of acoustic markers and linguistic context.";
    }
    return reason + factors.join(' and ') + ".";
  }

  Widget _buildConditionAnalytics(String title, String subtitle, List<dynamic> indicators, Map<String, dynamic>? features, {required bool isEducational, String? transcript}) {
      final detected = indicators.where((i) => i['detected'] == true).toList();
      
      // Build explanation based on features
      String explanation = _buildExplainableAI(features, detected, isEducational, transcript);
      
      return Container(
         width: double.infinity,
         margin: const EdgeInsets.only(top: 24),
         padding: const EdgeInsets.all(24),
         decoration: BoxDecoration(
           color: Colors.white, 
           borderRadius: BorderRadius.circular(16),
           boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0,4))],
         ),
         child: Column(
           crossAxisAlignment: CrossAxisAlignment.start,
           children: [
             Row(
               children: [
                 Icon(isEducational ? Icons.school : Icons.analytics_outlined, color: isEducational ? Colors.teal : Colors.indigo),
                 const SizedBox(width: 10),
                 Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
               ],
             ),
             const SizedBox(height: 8),
             Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 13)),
             const SizedBox(height: 24),
             
             if (detected.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       const Icon(Icons.check_circle, color: Colors.green),
                       const SizedBox(width: 12),
                       Expanded(child: Text(
                          isEducational 
                              ? "No significant educational or cognitive stressors detected. The student appears balanced."
                              : "No specific anxiety indicators were flagged. The analysis suggests a balanced state based on acoustic and linguistic patterns.", 
                          style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600)
                       )),
                    ],
                  ),
                )
             else 
               ...detected.take(3).map((indicator) {
                   return _buildIndicatorCard(indicator, features);
               }).toList(),
             
             // Confidence Analysis Graph
             if (detected.isNotEmpty) _buildConfidenceGraph(detected, isEducational),

             // Explainable AI Section
             const SizedBox(height: 20),
             Container(
               padding: const EdgeInsets.all(16),
               decoration: BoxDecoration(
                 color: Colors.blue.withOpacity(0.05),
                 borderRadius: BorderRadius.circular(12),
                 border: Border.all(color: Colors.blue.withOpacity(0.2)),
               ),
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   Row(
                     children: [
                       Icon(Icons.psychology, color: Colors.blue[700], size: 20),
                       const SizedBox(width: 8),
                       Text('AI Prediction Explanation', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue[700], fontSize: 14)),
                     ],
                   ),
                   const SizedBox(height: 12),
                   Text(
                     explanation,
                     style: TextStyle(fontSize: 12, color: Colors.grey[700], height: 1.5),
                   ),
                   const SizedBox(height: 12),
                   // Contributing factors
                   if (features != null) _buildContributingFactors(features, detected.isNotEmpty, isEducational: isEducational),
                   // Show transcript summary if available
                   if (transcript != null && transcript.isNotEmpty) ...[
                     const SizedBox(height: 12),
                     const Divider(),
                     const SizedBox(height: 8),
                     Text('📝 Analyzed Transcription:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Colors.grey[700])),
                     const SizedBox(height: 6),
                     Container(
                       padding: const EdgeInsets.all(10),
                       decoration: BoxDecoration(
                         color: Colors.grey[100],
                         borderRadius: BorderRadius.circular(8),
                       ),
                       child: Text(
                         transcript.length > 200 ? '${transcript.substring(0, 200)}...' : transcript,
                         style: TextStyle(fontSize: 11, color: Colors.grey[600], fontStyle: FontStyle.italic, height: 1.4),
                       ),
                     ),
                   ],
                 ],
               ),
             ),
           ],
         ),
      );
  }

  Widget _buildConfidenceGraph(List<dynamic> detected, bool isEducational) {
     return Column(
       children: [
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 5)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                 Row(
                   children: [
                     Icon(Icons.bar_chart, size: 18, color: isEducational ? Colors.teal : Colors.indigo),
                     const SizedBox(width: 8),
                     Text('Confidence Analysis', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey[800])),
                   ],
                 ),
                 const SizedBox(height: 16),
                 ...detected.take(5).map((item) {
                    final double probability = (item['probability'] as num).toDouble();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(item['name'], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                              Text('${probability.toInt()}%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: probability > 70 ? Colors.red : (probability > 40 ? Colors.orange : Colors.green))),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: probability / 100,
                              backgroundColor: Colors.grey[100],
                              valueColor: AlwaysStoppedAnimation<Color>(
                                 probability > 70 ? Colors.red : (probability > 40 ? Colors.orange : Colors.green)
                              ),
                              minHeight: 8,
                            ),
                          ),
                        ],
                      ),
                    );
                 }).toList(),
              ],
            ),
          ),
       ],
     );
  }
  
  String _buildExplainableAI(Map<String, dynamic>? features, List<dynamic> detected, bool isEducational, String? transcript) {
    if (features == null) {
      return isEducational 
        ? "Unable to analyze: No educational metrics available for this recording."
        : "Unable to analyze: No anxiety biomarkers available for this recording.";
    }
    
    // Extract key features
    final jitter = (features['jitter'] as num?)?.toDouble() ?? 0;
    final shimmer = (features['shimmer'] as num?)?.toDouble() ?? 0;
    final hnr = (features['hnr'] as num?)?.toDouble() ?? 0;
    final negativeCount = (features['negative_count'] as num?)?.toInt() ?? 0;
    final absolutistCount = (features['absolutist_count'] as num?)?.toInt() ?? 0;
    final pitchMean = (features['pitch_mean'] as num?)?.toDouble() ?? 0;
    final energyMean = (features['energy_mean'] as num?)?.toDouble() ?? 0;
    final detectedEmotion = features['detected_emotion']?.toString() ?? 'Neutral';
    final emotionConf = (features['emotion_confidence'] as num?)?.toDouble() ?? 0.5;
    
    // Get detected trigger words
    List<String> negativeMatches = (features['negative_matches'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    List<String> absolutistMatches = (features['absolutist_matches'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    
    StringBuffer explanation = StringBuffer();
    
    if (isEducational) {
      // ===== EDUCATIONAL INSIGHTS - Focus on Learning & Cognitive Factors =====
      // Educational trigger words (Taglish)
      const educationalStressWords = [
        'exam', 'test', 'quiz', 'assignment', 'project', 'deadline', 'submit', 'grade', 'fail', 'failed',
        'pagod', 'antok', 'hirap', 'mahirap', 'stressed', 'pressure', 'aral', 'homework', 'thesis',
        'late', 'absent', 'absent', 'bagsak', 'kulang'
      ];
      const positiveEducationalWords = [
        'learn', 'learned', 'understand', 'gets', 'easy', 'madali', 'tapos', 'done', 'finish', 'passed',
        'natutunan', 'nakuha', 'naintindihan', 'alam', 'ready', 'prepared'
      ];
      
      List<String> foundStressWords = [];
      List<String> foundPositiveWords = [];
      
      if (transcript != null && transcript.isNotEmpty) {
        final words = transcript.toLowerCase().split(RegExp(r'[\s,\.!?]+'));
        for (var word in words) {
          final cleanWord = word.replaceAll(RegExp(r'[^\w]'), '');
          if (educationalStressWords.contains(cleanWord) && !foundStressWords.contains(cleanWord)) {
            foundStressWords.add(cleanWord);
          }
          if (positiveEducationalWords.contains(cleanWord) && !foundPositiveWords.contains(cleanWord)) {
            foundPositiveWords.add(cleanWord);
          }
        }
      }
      
      if (detected.isEmpty) {
        explanation.writeln("📚 EDUCATIONAL ASSESSMENT: No cognitive stressors detected");
        explanation.writeln("");
        explanation.writeln("The student shows balanced academic indicators:");
        explanation.writeln("");
        
        // Focus on cognitive clarity
        if (hnr > 10) {
          explanation.writeln("• Speech Clarity: Clear articulation (HNR: ${hnr.toStringAsFixed(1)}dB) indicates focused thinking.");
        }
        
        // Energy levels for attention
        if (energyMean > 0.3) {
          explanation.writeln("• Attention Level: Voice energy suggests engaged and attentive state.");
        } else {
          explanation.writeln("• Calm Focus: Steady voice pattern indicates relaxed concentration.");
        }
        
        // Absolutist thinking for cognitive flexibility
        if (absolutistCount == 0) {
          explanation.writeln("• Cognitive Flexibility: No rigid thinking patterns ('always'/'never') detected.");
        }
        
        // Positive learning words
        if (foundPositiveWords.isNotEmpty) {
          explanation.writeln("• Positive Learning Indicators: Words like '${foundPositiveWords.take(3).join("', '")}' suggest academic confidence.");
        }
        
        // No stress words
        if (foundStressWords.isEmpty) {
          explanation.writeln("• Academic Stress: No stress-related academic words detected in speech.");
        }
        
      } else {
        explanation.writeln("📚 EDUCATIONAL ASSESSMENT: Cognitive stressors identified");
        explanation.writeln("");
        
        for (var indicator in detected.take(2)) {
          explanation.writeln("⚠️ ${indicator['name']} (${indicator['probability']}% probability)");
        }
        explanation.writeln("");
        
        // Educational stress words
        if (foundStressWords.isNotEmpty) {
          explanation.writeln("• Academic Stress Words: '${foundStressWords.take(4).join("', '")}'");
        }
        
        // Cognitive load indicators
        if (jitter > 5) {
          explanation.writeln("• Cognitive Load: Voice irregularity (${jitter.toStringAsFixed(2)}%) may indicate mental fatigue.");
        }
        
        // Attention/focus issues
        if (hnr < 10) {
          explanation.writeln("• Attention Drift: Low speech clarity suggests possible attention difficulties.");
        }
        
        // Rigid thinking
        if (absolutistCount > 0) {
          explanation.writeln("• Fixed Mindset: $absolutistCount absolute statements may indicate academic frustration.");
        }
      }
      
    } else {
      // ===== ANXIETY CONDITIONS - Focus on Clinical Biomarkers =====
      // Clinical anxiety words (Taglish)
      const anxietyTriggerWords = [
        'worried', 'scared', 'afraid', 'nervous', 'anxious', 'panic', 'fear', 'terrified',
        'kinakabahan', 'kabado', 'natatakot', 'takot', 'nag-aalala', 'balisa', 'nerbiyoso',
        'nanginginig', 'palpitate', 'hilo', 'nahihilo', 'breathless'
      ];
      const calmWords = [
        'calm', 'relaxed', 'peaceful', 'okay', 'fine', 'safe',
        'kalmado', 'relax', 'payapa', 'tahimik', 'okay', 'ayos'
      ];
      
      List<String> foundAnxietyWords = [];
      List<String> foundCalmWords = [];
      
      if (transcript != null && transcript.isNotEmpty) {
        final words = transcript.toLowerCase().split(RegExp(r'[\s,\.!?]+'));
        for (var word in words) {
          final cleanWord = word.replaceAll(RegExp(r'[^\w]'), '');
          if (anxietyTriggerWords.contains(cleanWord) && !foundAnxietyWords.contains(cleanWord)) {
            foundAnxietyWords.add(cleanWord);
          }
          if (calmWords.contains(cleanWord) && !foundCalmWords.contains(cleanWord)) {
            foundCalmWords.add(cleanWord);
          }
        }
      }
      
      if (detected.isEmpty) {
        explanation.writeln("🧠 CLINICAL ASSESSMENT: No anxiety biomarkers detected");
        explanation.writeln("");
        explanation.writeln("Voice analysis indicates balanced psychological state:");
        explanation.writeln("");
        
        // Voice tremor analysis (clinical)
        if (jitter < 5) {
          explanation.writeln("• Voice Tremor: Jitter ${jitter.toStringAsFixed(2)}% within normal range - no tremor detected.");
        }
        
        // Respiratory patterns
        if (shimmer < 15) {
          explanation.writeln("• Respiratory Pattern: Shimmer ${shimmer.toStringAsFixed(2)}% indicates steady breathing rhythm.");
        }
        
        // Vocal cord tension
        if (hnr > 10) {
          explanation.writeln("• Vocal Cord Tension: HNR ${hnr.toStringAsFixed(1)}dB shows relaxed vocal production.");
        }
        
        // Negative affect markers
        if (negativeCount == 0) {
          explanation.writeln("• Negative Affect: No distress language patterns detected.");
        }
        
        // Calm words
        if (foundCalmWords.isNotEmpty) {
          explanation.writeln("• Positive Indicators: Calm words detected - '${foundCalmWords.take(3).join("', '")}'");
        }
        
        // Emotion baseline
        if (detectedEmotion == 'Neutral' || detectedEmotion == 'Happy' || detectedEmotion == 'Calm') {
          explanation.writeln("• Baseline Emotion: '$detectedEmotion' (${(emotionConf * 100).toInt()}% confidence) - stable affect.");
        }
        
      } else {
        explanation.writeln("🧠 CLINICAL ASSESSMENT: Anxiety biomarkers identified");
        explanation.writeln("");
        
        for (var indicator in detected.take(2)) {
          explanation.writeln("⚠️ ${indicator['name']} (${indicator['probability']}% probability)");
        }
        explanation.writeln("");
        
        // Anxiety trigger words
        if (foundAnxietyWords.isNotEmpty) {
          explanation.writeln("• Anxiety Lexicon: '${foundAnxietyWords.take(4).join("', '")}'");
        }
        
        // Voice tremor (clinical indicator)
        if (jitter > 5) {
          explanation.writeln("• Voice Tremor: Elevated jitter (${jitter.toStringAsFixed(2)}%) suggests vocal instability.");
        }
        
        // Hyperventilation signs
        if (shimmer > 15) {
          explanation.writeln("• Respiratory Dysregulation: High shimmer indicates irregular breathing pattern.");
        }
        
        // Muscle tension
        if (hnr < 10) {
          explanation.writeln("• Laryngeal Tension: Low HNR suggests tense vocal production.");
        }
        
        // Negative affect
        if (negativeMatches.isNotEmpty) {
          explanation.writeln("• Distress Language: '${negativeMatches.take(3).join("', '")}'");
        }
        
        // Anxious emotion
        if (detectedEmotion == 'Sad' || detectedEmotion == 'Fear' || detectedEmotion == 'Angry') {
          explanation.writeln("• Affect Dysregulation: '$detectedEmotion' emotion with ${(emotionConf * 100).toInt()}% confidence.");
        }
      }
    }
    
    return explanation.toString().trim();
  }
  
  Widget _buildContributingFactors(Map<String, dynamic> features, bool hasAnxiety, {bool isEducational = false}) {
    final jitter = (features['jitter'] as num?)?.toDouble() ?? 0;
    final shimmer = (features['shimmer'] as num?)?.toDouble() ?? 0;
    final hnr = (features['hnr'] as num?)?.toDouble() ?? 0;
    final negativeCount = (features['negative_count'] as num?)?.toInt() ?? 0;
    final absolutistCount = (features['absolutist_count'] as num?)?.toInt() ?? 0;
    final energyMean = (features['energy_mean'] as num?)?.toDouble() ?? 0.5;
    
    if (isEducational) {
      // Educational-specific factors
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('📊 Learning Metrics:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Colors.grey[700])),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _buildFactorChip('Focus', hnr > 10 ? 'Clear' : 'Unclear', hnr > 10 ? Colors.green : Colors.orange),
              _buildFactorChip('Energy', energyMean > 0.4 ? 'Active' : 'Low', energyMean > 0.4 ? Colors.green : Colors.orange),
              _buildFactorChip('Flexibility', absolutistCount == 0 ? 'Good' : 'Rigid', absolutistCount == 0 ? Colors.green : Colors.red),
              _buildFactorChip('Stress Words', negativeCount == 0 ? 'None' : '$negativeCount', negativeCount == 0 ? Colors.green : Colors.red),
            ],
          ),
        ],
      );
    } else {
      // Clinical anxiety factors
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('🏥 Clinical Biomarkers:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Colors.grey[700])),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _buildFactorChip('Tremor', jitter < 5 ? 'Normal' : 'Elevated', jitter < 5 ? Colors.green : Colors.orange),
              _buildFactorChip('Breathing', shimmer < 15 ? 'Steady' : 'Irregular', shimmer < 15 ? Colors.green : Colors.orange),
              _buildFactorChip('Tension', hnr > 10 ? 'Relaxed' : 'Tense', hnr > 10 ? Colors.green : Colors.orange),
              _buildFactorChip('Distress', negativeCount == 0 ? 'None' : '$negativeCount', negativeCount == 0 ? Colors.green : Colors.red),
            ],
          ),
        ],
      );
    }
  }
  
  Widget _buildFactorChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          Text(value, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildHighlightedTranscript(String text, Map<String, dynamic>? features) {
    if (text == 'No transcription available.') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(color: Colors.grey)),
        ],
      );
    }
    
    // Color mapping per label - unique color for each anxiety/educational indicator
    const Map<String, Color> labelColors = {
      'Social_Anxiety': Color(0xFF9C27B0),     // Purple
      'GAD': Color(0xFF3F51B5),                 // Indigo
      'Panic_Disorder': Color(0xFFF44336),     // Red
      'Test_Anxiety': Color(0xFF2196F3),       // Blue
      'PTSD': Color(0xFF795548),               // Brown
      'Agoraphobia': Color(0xFF009688),        // Teal
      'Academic_Burnout': Color(0xFFFF5722),   // Deep Orange
      'Perfectionism': Color(0xFF673AB7),      // Deep Purple
      'Impostor_Syndrome': Color(0xFF607D8B),  // Blue Grey
      'Low_Self_Esteem': Color(0xFFE91E63),    // Pink
      'Fear_Of_Failure': Color(0xFFFF9800),    // Orange
      'Poor_Time_Management': Color(0xFF00BCD4), // Cyan
      'Lack_Of_Academic_Support': Color(0xFF8BC34A), // Light Green
      'Pressure_Of_Surroundings': Color(0xFFCDDC39), // Lime
    };
    
    // Extract trigger highlights from API response (per label)
    Map<String, List<String>> triggerHighlights = {};
    if (features?['trigger_highlights'] != null) {
      final triggers = features!['trigger_highlights'] as Map<String, dynamic>;
      triggers.forEach((label, keywords) {
        if (keywords is List) {
          triggerHighlights[label] = keywords.map((k) => k.toString().toLowerCase()).toList();
        }
      });
    }
    
    // Extract basic word lists from features
    List<String> negatives = (features?['negative_matches'] as List<dynamic>?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
    List<String> absolutists = (features?['absolutist_matches'] as List<dynamic>?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
    
    // Track which labels have highlights for legend
    Set<String> detectedLabels = {};
    int triggerCount = 0;
    
    List<TextSpan> spans = [];
    final words = text.split(' ');
    
    for (String word in words) {
       String cleanWord = word.toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
       Color? bgColor;
       Color textColor = Colors.black87;
       FontWeight? weight;
       String? matchedLabel;
       
       // Check each label's trigger keywords
       for (var entry in triggerHighlights.entries) {
         String label = entry.key;
         List<String> keywords = entry.value;
         
         // Check if word matches any keyword (single word or part of phrase)
         for (String kw in keywords) {
           if (kw.split(' ').length == 1) {
             // Single word keyword
             if (cleanWord == kw) {
               matchedLabel = label;
               break;
             }
           } else {
             // Multi-word phrase - check if word is part of phrase and phrase is in text
             if (kw.contains(cleanWord) && text.toLowerCase().contains(kw)) {
               matchedLabel = label;
               break;
             }
           }
         }
         if (matchedLabel != null) break;
       }
       
       // Apply color based on matched label
       if (matchedLabel != null) {
         Color labelColor = labelColors[matchedLabel] ?? Colors.purple;
         bgColor = labelColor.withOpacity(0.2);
         textColor = labelColor;
         weight = FontWeight.bold;
         detectedLabels.add(matchedLabel);
         triggerCount++;
       } else if (negatives.contains(cleanWord)) {
         bgColor = Colors.red.withOpacity(0.2);
         textColor = Colors.red[800]!;
         weight = FontWeight.bold;
       } else if (absolutists.contains(cleanWord)) {
         bgColor = Colors.orange.withOpacity(0.2);
         textColor = Colors.orange[800]!;
         weight = FontWeight.bold;
       }
       
       spans.add(TextSpan(
          text: '$word ',
          style: TextStyle(
            color: textColor, 
            fontWeight: weight ?? FontWeight.normal, 
            fontSize: 13, 
            height: 1.5,
            backgroundColor: bgColor,
          )
       ));
    }
    
    // Determine summary message
    String summaryText;
    Color summaryColor;
    IconData summaryIcon;
    
    int negativeCount = negatives.length;
    int absolutistCount = absolutists.length;
    
    if (triggerCount > 0 || negativeCount > 0) {
      summaryText = 'Indicators detected: $negativeCount negative, $absolutistCount absolutist, $triggerCount trigger words';
      summaryColor = Colors.red;
      summaryIcon = Icons.warning_amber_rounded;
    } else {
      summaryText = 'Neutral language - no strong indicators detected';
      summaryColor = Colors.green;
      summaryIcon = Icons.check_circle_outline;
    }
    
    // Build dynamic legend for detected labels
    List<Widget> legendItems = [
      _buildLegendDot('Negative', Colors.red),
      _buildLegendDot('Absolutist', Colors.orange),
    ];
    
    // Add legend items for each detected label
    for (String label in detectedLabels) {
      String displayName = label.replaceAll('_', ' ');
      Color labelColor = labelColors[label] ?? Colors.purple;
      legendItems.add(_buildLegendDot(displayName, labelColor));
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(text: TextSpan(children: spans)),
        const SizedBox(height: 12),
        const Divider(),
        const SizedBox(height: 8),
        // Summary message
        Row(
          children: [
            Icon(summaryIcon, size: 16, color: summaryColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(summaryText, style: TextStyle(fontSize: 11, color: summaryColor, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Dynamic Legend
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: legendItems,
        ),
      ],
    );
  }
  
  Widget _buildLegendDot(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withOpacity(0.3),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: color, width: 1),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
      ],
    );
  }

  Widget _buildIndicatorCard(Map<String, dynamic> indicator, Map<String, dynamic>? features) {
      String name = indicator['name'];
      int probability = indicator['probability'];
      
      // Feature extraction (local for rule checking)
      String emotion = features?['detected_emotion'] ?? 'Neutral';
      double jitter = (features?['jitter'] as num?)?.toDouble() ?? 0.0;
      double shimmer = (features?['shimmer'] as num?)?.toDouble() ?? 0.0;
      
      // Fallback Logic for Legacy/Missing Data
      int? negRaw = (features?['negative_raw'] as num?)?.toInt();
      int negPct = (features?['negative_count'] as num?)?.toInt() ?? 0;
      bool hasNegRaw = negRaw != null;
      int negVal = hasNegRaw ? negRaw! : negPct;
      
      int? absRaw = (features?['absolutist_raw'] as num?)?.toInt();
      int absPct = (features?['absolutist_count'] as num?)?.toInt() ?? 0;
      bool hasAbsRaw = absRaw != null;
      int absVal = hasAbsRaw ? absRaw! : absPct;
      
      // Extract matched words
      List<String> negWords = (features?['negative_matches'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
      List<String> absWords = (features?['absolutist_matches'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
      
      // Determine contributors based on Rules (Mirroring Python logic)
      List<Widget> contributors = [];
      
      // NEW: Use Backend Evidence if available (Prioritize specific reasons)
      final List<dynamic>? evidence = indicator['supporting_evidence'];
      
      if (evidence != null && evidence.isNotEmpty) {
        for (var item in evidence) {
           IconData iconData = Icons.info_outline;
           Color iconColor = Colors.blue;
           
           // Map string icons to IconData
           switch (item['icon']) {
             case 'text_fields': iconData = Icons.text_fields; iconColor = Colors.orange; break;
             case 'graphic_eq': iconData = Icons.graphic_eq; iconColor = Colors.red; break;
             case 'air': iconData = Icons.air; iconColor = Colors.purple; break;
             case 'sentiment_dissatisfied': iconData = Icons.sentiment_dissatisfied; iconColor = Colors.redAccent; break;
             case 'psychology': iconData = Icons.psychology; iconColor = Colors.indigo; break;
           }
           
           contributors.add(_buildContributorRow(
             iconData, 
             item['title'] ?? 'Factor', 
             item['text'] ?? 'Contributing factor detected', 
             iconColor
           ));
        }
      } else {
          // Fallback to LEGACY Hardcoded Rules if API didn't provide specific evidence
          // Rule 1: Emotion
          bool emotionMatch = false;
          if (['Social Anxiety', 'GAD', 'Agoraphobia', 'Panic Disorder'].contains(name) && ['Fear', 'Angry'].contains(emotion)) emotionMatch = true;
          if (name == 'PTSD' && emotion == 'Fear') emotionMatch = true;
          
          if (emotionMatch) {
             contributors.add(_buildContributorRow(Icons.mood_bad, "Emotion Match", "Detected '$emotion' aligns with $name profile.", Colors.purple));
          }
          
          // Rule 2: Voice
          bool voiceMatch = false;
          if (['Social Anxiety', 'Panic Disorder', 'GAD'].contains(name) && (jitter + shimmer) > 0.02) voiceMatch = true;
          
          if (voiceMatch) {
             contributors.add(_buildContributorRow(Icons.graphic_eq, "Acoustic Stress", "High vocal instability (fluctuation in pitch/volume).", Colors.blue));
          }
          
          // Rule 3: Text (Negative)
          if (['Fear Of Failure', 'Low Self Esteem', 'Test Anxiety'].contains(name) && negVal > 0) {
             String reason = "Used negative language";
             if (hasNegRaw) {
                 String list = negWords.isNotEmpty ? ": [${negWords.take(4).join(', ')}${negWords.length > 4 ? ', ...' : ''}]" : "";
                 reason = "Used $negVal negative keywords$list";
             } else {
                 reason = "High negative sentiment detected in text.";
             }
             contributors.add(_buildContributorRow(Icons.text_fields, "Negative Sentiment", reason, Colors.red));
          }
          
          // Rule 4: Text (Absolutist)
          if (['Perfectionism', 'Impostor Syndrome'].contains(name) && absVal > 0) {
              String reason = "Used absolutist language";
              if (hasAbsRaw) {
                 String list = absWords.isNotEmpty ? ": [${absWords.take(4).join(', ')}${absWords.length > 4 ? ', ...' : ''}]" : "";
                 reason = "Used $absVal absolutist terms$list";
              } else {
                 reason = "Absolutist language patterns detected.";
              }
              contributors.add(_buildContributorRow(Icons.rule, "Absolutist Language", reason, Colors.orange));
          }
          
          // Rule 5: TRIGGER KEYWORDS for ALL labels - show which keywords triggered this prediction
          String labelKey = name.replaceAll(' ', '_');
          if (features?['trigger_highlights'] != null) {
            final triggers = features!['trigger_highlights'] as Map<String, dynamic>?;
            if (triggers != null && triggers.containsKey(labelKey)) {
              List<String> keywords = (triggers[labelKey] as List<dynamic>).map((k) => k.toString()).toList();
              if (keywords.isNotEmpty) {
                String kwList = keywords.take(5).join(', ');
                contributors.add(_buildContributorRow(
                  Icons.key, 
                  "Trigger Keywords", 
                  "Found: [$kwList]", 
                  Colors.green
                ));
              }
            }
          }
          
          // Fallback
          if (contributors.isEmpty) {
              contributors.add(_buildContributorRow(Icons.category, "Biomarker Match", "AI detected patterns consistent with $name.", Colors.grey));
          }
      }
      
      // Extract trigger keywords for THIS specific indicator
      String labelKey = name.replaceAll(' ', '_'); // Convert "Social Anxiety" to "Social_Anxiety"
      List<String> triggerKeywords = [];
      if (features?['trigger_highlights'] != null) {
        final triggers = features!['trigger_highlights'] as Map<String, dynamic>;
        if (triggers.containsKey(labelKey)) {
          triggerKeywords = (triggers[labelKey] as List<dynamic>).map((k) => k.toString()).toList();
        }
      }
  
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                 Container(
                   padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                   decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                   child: Text('$probability% Match', style: const TextStyle(fontSize: 12, color: Colors.indigo, fontWeight: FontWeight.bold)),
                 )
               ],
             ),
             
             // Show trigger keywords if any
             if (triggerKeywords.isNotEmpty) ...[
               const SizedBox(height: 12),
               Row(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   Icon(Icons.key, size: 14, color: Colors.green[700]),
                   const SizedBox(width: 6),
                   Text("Trigger Keywords: ", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.green[700])),
                 ],
               ),
               const SizedBox(height: 6),
               Wrap(
                 spacing: 6,
                 runSpacing: 4,
                 children: triggerKeywords.take(5).map((kw) => Container(
                   padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                   decoration: BoxDecoration(
                     color: Colors.green.withOpacity(0.15),
                     borderRadius: BorderRadius.circular(12),
                     border: Border.all(color: Colors.green.withOpacity(0.5)),
                   ),
                   child: Text(
                     kw,
                     style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green[800]),
                   ),
                 )).toList(),
               ),
             ],
             
             const SizedBox(height: 12),
             const Text("Primary Contributing Factors:", style: TextStyle(fontSize: 12, color: Colors.grey)),
             const SizedBox(height: 8),
             ...contributors,
          ],
        ),
      );
  }

  Widget _buildContributorRow(IconData icon, String title, String subtitle, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
           Icon(icon, size: 16, color: color),
           const SizedBox(width: 8),
           Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: color)),
           const SizedBox(width: 8),
           Expanded(child: Text(subtitle, style: const TextStyle(fontSize: 13, color: Colors.black87), overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _buildInfoItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ],
    );
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA), // Light grey-blue background
      body: Row(
        children: [
          // Sidebar
          Container(
            width: 280,
            color: Colors.white,
            child: Column(
              children: [
                const SizedBox(height: 40),
                // Logo
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.graphic_eq, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'AudioPulse',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2E7D32),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 60),
                
                // Nav Items (Record and Settings removed)
              _buildNavItem(0, 'Overview', Icons.dashboard_outlined),
              _buildNavItem(1, 'Analytics', Icons.bar_chart_outlined),
              _buildNavItem(2, 'Recordings', Icons.folder_open_outlined),
                
                const Spacer(),
                
                // User Profile dummy
                Container(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Color(0xFFE8F5E9),
                        child: Icon(Icons.person, color: Color(0xFF2E7D32)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _adminFullName,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'ID: $_currentAdminId',
                            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),  
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Main Content
          Expanded(
            child: Column(
              children: [
                // Header
                Container(
                  height: 80,
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  color: Colors.white,
                  child: Row(
                    children: [
                      Text(
                        _getPageTitle(),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF263238),
                        ),
                      ),
                      const Spacer(),
                      IconButton(onPressed: () {}, icon: const Icon(Icons.notifications_outlined)),
                    const SizedBox(width: 16),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await FirebaseService.signOut();
                        // Navigation handled by stream
                      },
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Log Out'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: BorderSide(color: Colors.red.withOpacity(0.5)),
                      ),
                    ),

                    ],
                  ),
                ),
                
                // Scrollable Content
                Expanded(
                  child: _buildPageContent(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, String title, IconData icon) {
    final isSelected = _selectedIndex == index;
    return InkWell(
      onTap: () => setState(() => _selectedIndex = index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE8F5E9) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? const Color(0xFF2E7D32) : Colors.grey[600], size: 22),
            const SizedBox(width: 15),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? const Color(0xFF2E7D32) : Colors.grey[700],
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, String trend, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title above icon
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F8F4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFF2E7D32)),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: trend.startsWith('+') ? const Color(0xFFE8F5E9) : Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    trend,
                    style: TextStyle(
                      color: trend.startsWith('+') ? const Color(0xFF2E7D32) : Colors.orange[800],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            value,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Color(0xFF263238),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }
}

class DummyChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2E7D32)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
      
    final path = Path();
    path.moveTo(0, size.height * 0.8);
    
    // Draw a nice curve
    path.cubicTo(
      size.width * 0.2, size.height * 0.9,
      size.width * 0.3, size.height * 0.4,
      size.width * 0.5, size.height * 0.6,
    );
    path.cubicTo(
      size.width * 0.7, size.height * 0.8,
      size.width * 0.8, size.height * 0.2,
      size.width, size.height * 0.5,
    );
    
    canvas.drawPath(path, paint);
    
    // Fill below
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF2E7D32).withOpacity(0.2),
          const Color(0xFF2E7D32).withOpacity(0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      
    final fillPath = Path.from(path);
    fillPath.lineTo(size.width, size.height);
    fillPath.lineTo(0, size.height);
    fillPath.close();
    
    canvas.drawPath(fillPath, fillPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ChartSegment {
  final String label;
  final double value;
  
  ChartSegment(this.label, this.value);
}

class SemiCircleChartPainter extends CustomPainter {
  final List<ChartSegment> data;
  final List<Color> colors;
  
  SemiCircleChartPainter({required this.data, required this.colors});
  
  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    
    final total = data.fold<double>(0, (sum, segment) => sum + segment.value);
    if (total == 0) return;
    
    final centerX = size.width / 2;
    final centerY = size.height * 0.85; // Move center down for semi-circle
    final radius = (size.width < size.height * 1.5 ? size.width : size.height * 1.5) / 2 - 60;
    final innerRadius = radius * 0.4; // Inner cutout for donut effect
    
    double startAngle = 3.14159; // Start from left (180 degrees = PI)
    
    for (int i = 0; i < data.length; i++) {
      final segment = data[i];
      final sweepAngle = (segment.value / total) * 3.14159; // Half circle = PI
      
      final paint = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.fill;
      
      // Draw arc segment
      final path = Path();
      path.moveTo(
        centerX + innerRadius * cos(startAngle),
        centerY + innerRadius * sin(startAngle),
      );
      path.arcTo(
        Rect.fromCircle(center: Offset(centerX, centerY), radius: radius),
        startAngle,
        sweepAngle,
        false,
      );
      path.lineTo(
        centerX + innerRadius * cos(startAngle + sweepAngle),
        centerY + innerRadius * sin(startAngle + sweepAngle),
      );
      path.arcTo(
        Rect.fromCircle(center: Offset(centerX, centerY), radius: innerRadius),
        startAngle + sweepAngle,
        -sweepAngle,
        false,
      );
      path.close();
      
      canvas.drawPath(path, paint);
      
      // Draw label with leader line
      final midAngle = startAngle + sweepAngle / 2;
      final labelRadius = radius + 20;
      final labelX = centerX + labelRadius * cos(midAngle);
      final labelY = centerY + labelRadius * sin(midAngle);
      
      // Draw leader line
      final linePaint = Paint()
        ..color = Colors.grey[400]!
        ..strokeWidth = 1;
      
      final lineEndX = centerX + (radius - 5) * cos(midAngle);
      final lineEndY = centerY + (radius - 5) * sin(midAngle);
      canvas.drawLine(Offset(lineEndX, lineEndY), Offset(labelX, labelY), linePaint);
      
      // Draw horizontal line from label point
      final horizontalEndX = midAngle < 3.14159 * 1.5 ? labelX - 25 : labelX + 25;
      canvas.drawLine(Offset(labelX, labelY), Offset(horizontalEndX, labelY), linePaint);
      
      // Draw label text
      final textSpan = TextSpan(
        text: segment.label,
        style: TextStyle(
          color: Colors.grey[700],
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
        textAlign: midAngle < 3.14159 * 1.5 ? TextAlign.right : TextAlign.left,
      );
      textPainter.layout();
      
      final textX = midAngle < 3.14159 * 1.5 
        ? horizontalEndX - textPainter.width - 4
        : horizontalEndX + 4;
      final textY = labelY - textPainter.height / 2;
      
      textPainter.paint(canvas, Offset(textX, textY));
      
      startAngle += sweepAngle;
    }
  }
  
  double cos(double radians) => _cos(radians);
  double sin(double radians) => _sin(radians);
  
  static double _cos(double x) {
    // Taylor series approximation for cos
    x = x % (2 * 3.14159);
    double result = 1.0;
    double term = 1.0;
    for (int n = 1; n <= 10; n++) {
      term *= -x * x / ((2 * n - 1) * (2 * n));
      result += term;
    }
    return result;
  }
  
  static double _sin(double x) {
    // Taylor series approximation for sin
    x = x % (2 * 3.14159);
    double result = x;
    double term = x;
    for (int n = 1; n <= 10; n++) {
      term *= -x * x / ((2 * n) * (2 * n + 1));
      result += term;
    }
    return result;
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class LineGraphPainter extends CustomPainter {
  final List<int> data;
  final List<String> labels;
  
  LineGraphPainter({required this.data, required this.labels});
  
  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    
    final maxValue = data.fold(1, (a, b) => a > b ? a : b);
    final minValue = 0;
    final padding = 30.0;
    final graphWidth = size.width - padding * 2;
    final graphHeight = size.height - padding;
    
    // Draw grid lines
    final gridPaint = Paint()
      ..color = Colors.grey[200]!
      ..strokeWidth = 1;
    
    for (int i = 0; i <= 4; i++) {
      final y = padding / 2 + (graphHeight / 4) * i;
      canvas.drawLine(Offset(padding, y), Offset(size.width - padding, y), gridPaint);
    }
    
    // Calculate points
    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = padding + (graphWidth / (data.length - 1)) * i;
      final normalizedValue = (data[i] - minValue) / (maxValue - minValue);
      final y = padding / 2 + graphHeight * (1 - normalizedValue);
      points.add(Offset(x, y));
    }
    
    // Draw filled area under the line
    if (points.length >= 2) {
      final fillPath = Path();
      fillPath.moveTo(points.first.dx, size.height - padding / 2);
      
      // Create smooth curve through points
      for (int i = 0; i < points.length; i++) {
        if (i == 0) {
          fillPath.lineTo(points[i].dx, points[i].dy);
        } else {
          final prev = points[i - 1];
          final curr = points[i];
          final controlX1 = prev.dx + (curr.dx - prev.dx) / 3;
          final controlX2 = prev.dx + (curr.dx - prev.dx) * 2 / 3;
          fillPath.cubicTo(controlX1, prev.dy, controlX2, curr.dy, curr.dx, curr.dy);
        }
      }
      
      fillPath.lineTo(points.last.dx, size.height - padding / 2);
      fillPath.close();
      
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF4CAF50).withOpacity(0.4),
            const Color(0xFF4CAF50).withOpacity(0.05),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      
      canvas.drawPath(fillPath, fillPaint);
    }
    
    // Draw the line
    if (points.length >= 2) {
      final linePath = Path();
      linePath.moveTo(points.first.dx, points.first.dy);
      
      for (int i = 1; i < points.length; i++) {
        final prev = points[i - 1];
        final curr = points[i];
        final controlX1 = prev.dx + (curr.dx - prev.dx) / 3;
        final controlX2 = prev.dx + (curr.dx - prev.dx) * 2 / 3;
        linePath.cubicTo(controlX1, prev.dy, controlX2, curr.dy, curr.dx, curr.dy);
      }
      
      final linePaint = Paint()
        ..color = const Color(0xFF2E7D32)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      
      canvas.drawPath(linePath, linePaint);
    }
    
    // Draw points and value labels
    for (int i = 0; i < points.length; i++) {
      // Draw point
      final pointPaint = Paint()
        ..color = const Color(0xFF2E7D32)
        ..style = PaintingStyle.fill;
      
      canvas.drawCircle(points[i], 6, Paint()..color = Colors.white);
      canvas.drawCircle(points[i], 4, pointPaint);
      
      // Draw value label
      final textSpan = TextSpan(
        text: '${data[i]}',
        style: TextStyle(
          color: Colors.grey[700],
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas, 
        Offset(points[i].dx - textPainter.width / 2, points[i].dy - 20),
      );
    }
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Simple consistent random generator
class _ConsistentRandom {
  int _seed;
  _ConsistentRandom(this._seed);
  
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }
  
  bool nextBool() => nextInt(2) == 0;
}
