import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:html' as html;
import 'dart:async';
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../services/firebase_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class WebDashboardScreen extends StatefulWidget {
  const WebDashboardScreen({super.key});

  @override
  State<WebDashboardScreen> createState() => _WebDashboardScreenState();
}

class _WebDashboardScreenState extends State<WebDashboardScreen> {
  int _selectedIndex = 0;
  
  // Data from Firebase
  Map<String, List<Map<String, String>>> _allFolders = {};
  List<Map<String, dynamic>> _clients = [];
  bool _isLoading = true;
  String? _currentAdminId; // Store current Admin ID

  // Selected recording for analysis view
  Map<String, String>? _selectedAnalysisRecording;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // 1. Fetch Admin ID first
    _currentAdminId = await FirebaseService.getCurrentAdminId();
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
      } else {
        setState(() => _isLoading = false);
      }
    }
  }

  void _setupRealtimeListener() {
    // Real-time listener for auto-refresh when new recordings are added
    if (_currentAdminId == null) return;
    
    FirebaseFirestore.instance
        .collection('recordings')
        .where('admin_id', isEqualTo: _currentAdminId) // Filter by Admin ID
        .orderBy('created_at', descending: true)
        .snapshots()
        .listen((snapshot) {
      Map<String, List<Map<String, String>>> loadedFolders = {};

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
        });
      }

      if (mounted) {
        setState(() {
          _allFolders = loadedFolders;
          _isLoading = false;
        });
      }
    }, onError: (e) {
      print('Error loading data from Firebase: $e');
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
      clients.sort((a, b) {
        final aTime = a['created_at'];
        final bTime = b['created_at'];
        if (aTime == null || bTime == null) return 0;
        return (bTime as Timestamp).compareTo(aTime as Timestamp);
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

  void _showFolderSelectionDialog(html.File file, List<String> folders) {
    String? selectedFolder;
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.audio_file, color: Color(0xFF2E7D32)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Upload Audio', style: TextStyle(fontSize: 18)),
                      Text(
                        file.name,
                        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Select folder to save recording:', style: TextStyle(color: Colors.grey[700])),
                  const SizedBox(height: 16),
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: folders.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.folder_off, size: 40, color: Colors.grey[300]),
                                const SizedBox(height: 8),
                                Text('No folders available', style: TextStyle(color: Colors.grey[500])),
                                const SizedBox(height: 8),
                                Text('Create a client on the mobile app first', 
                                  style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: folders.length,
                            itemBuilder: (context, index) {
                              final folder = folders[index];
                              final isSelected = selectedFolder == folder;
                              return ListTile(
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: isSelected ? const Color(0xFFE8F5E9) : Colors.grey[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.folder,
                                    color: isSelected ? const Color(0xFF2E7D32) : Colors.grey[400],
                                  ),
                                ),
                                title: Text(folder),
                                selected: isSelected,
                                selectedTileColor: const Color(0xFFF1F8F4),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                onTap: () => setDialogState(() => selectedFolder = folder),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
              ),
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
                  disabledBackgroundColor: Colors.grey[300],
                ),
                child: const Text('Upload'),
              ),
            ],
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
            Text('Analyzing ${file.name} with AI Model...'),
          ],
        ),
        backgroundColor: const Color(0xFF2E7D32),
        duration: const Duration(seconds: 60), // Longer duration for analysis
      ),
    );
    
    try {
      // 1. Read file as bytes
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      await reader.onLoadEnd.first;
      
      final audioBytes = reader.result as Uint8List;

      // 2. Send to Python Backend (app.py)
      // Note: Ensure app.py is running on port 5000
      var request = http.MultipartRequest('POST', Uri.parse('http://127.0.0.1:5000/upload-audio'));
      request.files.add(http.MultipartFile.fromBytes(
        'audio', 
        audioBytes,
        filename: file.name
      ));
      request.fields['folder'] = folderName;
      request.fields['transcript'] = ''; // Let backend handle transcription

      print('Sending to Python Backend...');
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);
      
      print('Response status: ${response.statusCode}');
      
      Map<String, dynamic> analysisResult = {};
      if (response.statusCode == 200) {
        analysisResult = jsonDecode(response.body);
        print('Analysis success: $analysisResult');
      } else {
        print('Backend error: ${response.body}');
        throw Exception("AI Analysis Failed: ${response.body}");
      }
      
      // 3. Save recording metadata + Analysis to Firestore
      final now = DateTime.now();
      final severity = analysisResult['severity'] ?? {'level': 'Unknown', 'score': 0};
      final emotion = analysisResult['emotion'] ?? {'label': 'Unknown', 'confidence': 0};
      
      await FirebaseFirestore.instance.collection('recordings').add({
        'folder_name': folderName,
        'name': file.name,
        'size': '${(file.size / 1024).toStringAsFixed(1)} KB',
        'date': '${_getMonthName(now.month)} ${now.day}, ${now.year}',
        'duration': analysisResult['duration'] ?? '00:00:00', 
        'transcription': analysisResult['transcript'] ?? '',
        
        // Analysis Data
        'severity_level': severity['level'],
        'severity_score': severity['score'],
        'emotion_label': emotion['label'],
        'emotion_confidence': emotion['confidence'],
        'anxiety_indicators': analysisResult['anxiety_indicators'] ?? [],
        'summary': analysisResult['summary'] ?? '',
        
        'uploaded_at': FieldValue.serverTimestamp(),
        'source': 'web_upload_analyzed',
        'admin_id': _currentAdminId,
      });
      
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Text('Analysis Complete! Saved to $folderName'),
            ],
          ),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
    } catch (e) {
      print('Upload Error: $e');
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e. Is Python Server running?'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
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
        final dateStr = recording['date'] ?? '';
        // Extract day from "Dec 13, 2024" format
        try {
          final parts = dateStr.split(', ');
          if (parts.length >= 2) {
            final dayPart = parts[0].split(' ');
            if (dayPart.length >= 2) {
              final dayNum = int.tryParse(dayPart[1]) ?? 0;
              // Match to our day list (simplified - just count for demo)
              for (var key in dailyCounts.keys) {
                dailyCounts[key] = (dailyCounts[key] ?? 0) + (dayNum % 7 == dailyCounts.keys.toList().indexOf(key) ? 1 : 0);
              }
            }
          }
        } catch (e) {
          // Skip invalid dates
        }
      }
    });
    
    // If no real data, use sample data
    if (dailyCounts.values.every((v) => v == 0)) {
      dailyCounts = {'Mon': 3, 'Tue': 5, 'Wed': 2, 'Thu': 8, 'Fri': 4, 'Sat': 1, 'Sun': 6};
    }
    
    return Column(
      children: [
        Expanded(
          child: CustomPaint(
            painter: LineGraphPainter(
              data: dailyCounts.values.toList(),
              labels: dailyCounts.keys.toList(),
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: dailyCounts.keys.map((day) => 
            Text(day, style: TextStyle(fontSize: 11, color: Colors.grey[600]))
          ).toList(),
        ),
      ],
    );
  }

  Widget _buildAnalysisSummary() {
    // Dummy biomarker data for demo - will be replaced with real data
    final biomarkers = [
      {'label': 'HNR (dB)', 'value': '23.5', 'status': 'normal'},
      {'label': 'Jitter (%)', 'value': '0.45', 'status': 'normal'},
      {'label': 'Shimmer (%)', 'value': '2.1', 'status': 'warning'},
      {'label': 'F0 Mean (Hz)', 'value': '142', 'status': 'normal'},
      {'label': 'Prediction', 'value': 'Healthy', 'status': 'good'},
    ];
    
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: biomarkers.length,
            separatorBuilder: (_, __) => Divider(color: Colors.white24, height: 1),
            itemBuilder: (context, index) {
              final marker = biomarkers[index];
              final statusColor = marker['status'] == 'good' 
                  ? Colors.greenAccent
                  : marker['status'] == 'warning'
                      ? Colors.orangeAccent
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
                    Row(
                      children: [
                        Text(
                          marker['value']!,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
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
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.info_outline, color: Colors.white70, size: 14),
              SizedBox(width: 6),
              Text(
                'Demo data - Connect for real results',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSeverityChart() {
    // Demo severity distribution data
    final severityData = {
      'Normal': 45,
      'Moderate': 35,
      'Severe': 20,
    };
    final total = severityData.values.fold(0, (a, b) => a + b);
    
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
            children: severityData.entries.map((entry) {
              final percent = entry.value / total;
              return Expanded(
                flex: (percent * 100).round(),
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
            final percent = ((entry.value / total) * 100).round();
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
    // Demo anxiety type distribution
    final anxietyData = [
      ChartSegment('Social Anxiety', 25),
      ChartSegment('GAD', 20),
      ChartSegment('PTSD', 15),
      ChartSegment('Panic Disorder', 12),
      ChartSegment('Agoraphobia', 8),
      ChartSegment('Neutral', 20),
    ];
    
    final colors = [
      const Color(0xFFE91E63),  // Pink
      const Color(0xFF9C27B0),  // Purple
      const Color(0xFF673AB7),  // Deep Purple
      const Color(0xFF3F51B5),  // Indigo
      const Color(0xFF2196F3),  // Blue
      const Color(0xFF4CAF50),  // Green (Neutral)
    ];
    
    return CustomPaint(
      painter: SemiCircleChartPainter(data: anxietyData, colors: colors),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildEducationalIssuesChart() {
    // Demo educational issues data
    final issuesData = {
      'Test Anxiety': 28,
      'Academic Burnout': 22,
      'Fear of Failure': 18,
      'Poor Time Mgmt': 15,
      'Low Self-Esteem': 12,
      'Impostor Syndrome': 10,
      'Perfectionism': 8,
      'Lack of Support': 6,
      'Pressure': 5,
    };
    
    final maxValue = issuesData.values.fold(0, (a, b) => a > b ? a : b);
    
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: issuesData.entries.take(5).length, // Show top 5
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final entry = issuesData.entries.elementAt(index);
        final percent = entry.value / maxValue;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    entry.key,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${entry.value}%',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.bold),
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
                        colors: [const Color(0xFF2E7D32), const Color(0xFF4CAF50)],
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
    // Demo emotion distribution data
    final emotionData = [
      ChartSegment('Calm', 20),
      ChartSegment('Happy', 18),
      ChartSegment('Sad', 15),
      ChartSegment('Angry', 12),
      ChartSegment('Fearful', 12),
      ChartSegment('Surprise', 13),
      ChartSegment('Disgust', 10),
    ];
    
    final colors = [
      const Color(0xFF4CAF50),  // Calm - Green
      const Color(0xFFFFEB3B),  // Happy - Yellow
      const Color(0xFF2196F3),  // Sad - Blue
      const Color(0xFFF44336),  // Angry - Red
      const Color(0xFF9C27B0),  // Fearful - Purple
      const Color(0xFFFF9800),  // Surprise - Orange
      const Color(0xFF795548),  // Disgust - Brown
    ];
    
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
    
    switch (_selectedIndex) {
      case 0: return _buildOverviewPage();
      case 1: return _buildAnalyticsPage();
      case 2: return _buildRecordingsPage();
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
          
          // Recording Activity & Analysis Summary Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Recording Activity Chart
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
                      Text('Biomarker Results (Demo)', style: TextStyle(color: Colors.white70, fontSize: 12)),
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
                          Text('(Demo)', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
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
                          Text('(Demo)', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
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
                          Text('(Demo)', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
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
                          Text('Top 5 (Demo)', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
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
    Map<String, List<Map<String, String>>> allData = Map.from(_allFolders);
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

  Widget _buildAnalyticsFolderCard(String folderName, List<Map<String, String>> recordings) {
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

  Widget _buildAnalyticsRecordingItem(Map<String, String> recording) {
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
            Map<String, List<Map<String, String>>> allFoldersWithClients = Map.from(_allFolders);
            
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

  Widget _buildFolderCard(String folderName, List<Map<String, String>> recordings) {
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

  Widget _buildRecordingListItem(Map<String, String> recording, String folderName) {
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
              child: const Icon(Icons.audiotrack, color: Color(0xFF2E7D32), size: 20),
            ),
            const SizedBox(width: 16),
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
                Text(
                  recording['duration'] ?? '00:00',
                  style: const TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF2E7D32)),
                ),
                const SizedBox(height: 4),
                Text(
                  recording['size'] ?? '',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ],
            ),
            const SizedBox(width: 16),
            Icon(
              (recording['transcription'] ?? '').isNotEmpty ? Icons.description : Icons.description_outlined,
              color: (recording['transcription'] ?? '').isNotEmpty ? const Color(0xFF2E7D32) : Colors.grey[400],
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  void _showTranscriptionDialog(Map<String, String> recording) {
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

  void _showPredictionAnalytics(Map<String, String> recording) {
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

  Widget _buildPredictionAnalysisPage() {
    final recording = _selectedAnalysisRecording!;
    
    // Generate consistent dummy data
    final int seed = recording['name'].hashCode;
    final random = _ConsistentRandom(seed);
    
    // 1. Determine Severity
    final severityRoll = random.nextInt(100);
    String severity;
    Color severityColor;
    if (severityRoll < 30) {
      severity = 'High';
      severityColor = Colors.red;
    } else if (severityRoll < 70) {
      severity = 'Moderate';
      severityColor = Colors.orange;
    } else {
      severity = 'Low';
      severityColor = Colors.green;
    }
    
    // 2. Determine Emotion
    String emotion;
    if (severity == 'High') {
      emotion = ['Fearful', 'Angry', 'Sad'][random.nextInt(3)];
    } else if (severity == 'Moderate') {
      emotion = ['Anxious', 'Surprised', 'Disgust'][random.nextInt(3)];
    } else {
      emotion = ['Calm', 'Happy', 'Neutral'][random.nextInt(3)];
    }
    
    // 3. Determine Anxiety Types
    List<String> anxietyTypes = [];
    if (severity != 'Low') {
      if (random.nextBool()) anxietyTypes.add('Generalized Anxiety');
      if (random.nextBool()) anxietyTypes.add('Social Anxiety');
      if (random.nextBool()) anxietyTypes.add('Panic Disorder');
      if (anxietyTypes.isEmpty) anxietyTypes.add('Unspecified Anxiety');
    } else {
      anxietyTypes.add('None Detected');
    }
    
    // 4. Determine Educational Issues
    List<String> educationalIssues = [];
    if (severity == 'High' || severity == 'Moderate') {
      if (random.nextBool()) educationalIssues.add('Attention Deficit');
      if (random.nextBool()) educationalIssues.add('Auditory Processing');
      if (random.nextBool()) educationalIssues.add('Exam Anxiety');
      if (educationalIssues.isEmpty) educationalIssues.add('General Focus Issues');
    } else {
      educationalIssues.add('No Significant Issues');
    }

    // Find client info (approximated by folder name or assuming single client context for now)
    // Ideally we would link recording to client ID properly
    final clientName = recording['folder_name'] ?? 'Unknown Client';
    
    return Container(
      color: const Color(0xFFF5F7FA),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            color: Colors.white,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedAnalysisRecording = null),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recording['name'] ?? 'Recording Analysis',
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.calendar_today, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text(
                            recording['date'] ?? '',
                            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                          ),
                          const SizedBox(width: 16),
                          Icon(Icons.timer, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text(
                            recording['duration'] ?? '',
                            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    // Call client lookup logic again or reuse if available in scope
                     final folderName = recording['folder_name'];
                     
                     // We need to find the client again as it's not directly in scope unless we grab it from the listener data
                     // Assuming _clients is available
                     final client = _clients.firstWhere(
                      (c) => c['folder_name'] == folderName,
                      orElse: () => {'full_name': 'Unknown Client', 'folder_name': folderName},
                    );
                    
                    _showPdfPreview(client, recording);
                  },
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Export Report'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Client Info Section
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Client Information',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                            // Look up client details using folder_name
                            Builder(
                              builder: (context) {
                                final folderName = recording['folder_name'];
                                print('🔍 DEBUG: Looking for client with folder_name: "$folderName"');
                                print('🔍 DEBUG: Available clients: ${_clients.map((c) => c['folder_name']).toList()}');
                                
                                final client = _clients.firstWhere(
                                  (c) {
                                     final match = c['folder_name'].toString() == folderName.toString();
                                     if (match) print('✅ Match found for $folderName');
                                     return match;
                                  },
                                  orElse: () {
                                    print('❌ No match found for $folderName');
                                    return {'full_name': folderName ?? 'Unknown Client'};
                                  },
                                );

                                // Helper to format date
                                String formatBirthday(dynamic birthday) {
                                  if (birthday == null) return 'N/A';
                                  if (birthday is Timestamp) {
                                    DateTime date = birthday.toDate();
                                    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                                    return '${months[date.month - 1]} ${date.day}, ${date.year}';
                                  }
                                  return birthday.toString();
                                }

                                return Wrap(
                                  spacing: 40,
                                  runSpacing: 20,
                                  children: [
                                    _buildInfoItem('Full Name', client['full_name']?.toString() ?? 'N/A'),
                                    _buildInfoItem('Age', client['age']?.toString() ?? 'N/A'),
                                    _buildInfoItem('Birthday', formatBirthday(client['birthday'])),
                                    _buildInfoItem('School Year', client['school_year']?.toString() ?? 'N/A'),
                                    _buildInfoItem('Address', client['address']?.toString() ?? 'N/A'),
                                    _buildInfoItem('Phone', client['phone_number']?.toString() ?? 'N/A'),
                                  ],
                                );
                              }
                            ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Audio Visualizer Section
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Audio Analysis',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          height: 120,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAFAFA),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey[200]!),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Dummy Waveform Visualizer
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: List.generate(40, (index) {
                                  final height = 20 + random.nextInt(60).toDouble();
                                  return Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 2),
                                    width: 4,
                                    height: height,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2E7D32).withOpacity(0.6),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  );
                                }),
                              ),
                              // Play Button Overlay
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.play_arrow, color: Color(0xFF2E7D32), size: 30),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Transcription Section
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Transcription',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAFAFA),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey[200]!),
                          ),
                          child: Text(
                            recording['transcription']?.isNotEmpty == true 
                                ? recording['transcription']! 
                                : 'No transcription available.',
                            style: const TextStyle(height: 1.6, fontSize: 16, color: Color(0xFF455A64)),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Analytics Grid
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Prediction Analytics',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _buildAnalyticsSection(
                                'Severity Level',
                                severity,
                                Icons.warning_amber_rounded,
                                severityColor,
                                isPill: true,
                              ),
                            ),
                            Expanded(
                              child: _buildAnalyticsSection(
                                'Detected Emotion',
                                emotion,
                                Icons.sentiment_satisfied_alt,
                                Colors.purple,
                                isPill: true,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _buildAnalyticsSection(
                                'Anxiety Indicators',
                                anxietyTypes,
                                Icons.waves,
                                Colors.blue,
                                isList: true,
                              ),
                            ),
                            Expanded(
                              child: _buildAnalyticsSection(
                                'Educational Insights',
                                educationalIssues,
                                Icons.school_outlined,
                                Colors.teal,
                                isList: true,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue.withOpacity(0.2)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.verified_user_outlined, color: Colors.blue),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Analysis completed with 94% confidence based on vocal biomarkers.',
                                  style: TextStyle(fontSize: 14, color: Colors.blue[800], fontStyle: FontStyle.italic),
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
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 13)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
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
                
                // Nav Items
                _buildNavItem(0, 'Overview', Icons.dashboard_outlined),
                _buildNavItem(1, 'Analytics', Icons.bar_chart_outlined),
                _buildNavItem(2, 'Recordings', Icons.folder_open_outlined),
                _buildNavItem(3, 'Settings', Icons.settings_outlined),
                
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
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Admin User',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          Text(
                            'Pro Plan',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
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
