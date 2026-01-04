// Add these methods to _AudioRecorderScreenState class

/// Run biomarker analysis after transcription
Future<void> _runBiomarkerAnalysis(String audioPath, String transcription) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const Center(
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Analyzing biomarkers...'),
            ],
          ),
        ),
      ),
    ),
  );
  
  try {
    final result = await AudioBiomarkerService.analyzeAudio(audioPath, transcription);
    if (mounted) Navigator.of(context).pop();
    
    if (result.success) {
      _showBiomarkerResultsDialog(result);
      
      // Save to Firebase
      if (_currentAdminId != null) {
        await _saveBiomarkerToFirebase(result, audioPath);
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Analysis error: ${result.error ?? "Unknown error"}')),
        );
      }
    }
  } catch (e) {
    print('❌ Biomarker analysis error: $e');
    if (mounted) Navigator.of(context).pop();
  }
}

/// Save biomarker results to Firebase
Future<void> _saveBiomarkerToFirebase(BiomarkerResult result, String audioPath) async {
  try {
    await FirebaseService.saveBiomarkerResult(
      adminId: _currentAdminId!,
      folderName: _sessionDetails['folder'] ?? 'Uncategorized',
      audioPath: audioPath,
      severity: result.severity.level,
      severityConfidence: result.severity.confidence,
      emotion: result.emotion.label,
      emotionConfidence: result.emotion.confidence,
      anxietyIndicators: result.anxietyIndicators.map((i) => i.name).toList(),
      transcript: result.transcript,
      summary: result.summary,
      processingTime: result.processingTimeMs,
    );
  } catch (e) {
    print('Error saving biomarker to Firebase: $e');
  }
}

/// Show simplified biomarker results dialog (pill-style design)
void _showBiomarkerResultsDialog(BiomarkerResult result) {
  // Get severity display and color
  String getSeverityDisplay(String level) {
    switch (level) {
      case 'Normal': return 'Low';
      case 'Moderate': return 'Moderate';
      case 'Severe': return 'High';
      default: return level;
    }
  }
  
  Color getSeverityColor(String level) {
    switch (level) {
      case 'Normal': return const Color(0xFF4CAF50);
      case 'Moderate': return const Color(0xFFFF9800);
      case 'Severe': return const Color(0xFFF44336);
      default: return const Color(0xFF4CAF50);
    }
  }
  
  Color getSeverityBgColor(String level) {
    return getSeverityColor(level).withOpacity(0.15);
  }
  
  showDialog(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2196F3).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.analytics, color: Color(0xFF2196F3), size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Prediction Analytics',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _currentRecordingName ?? 'Recording',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 24),
            
            // Severity Level
            Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.grey[600], size: 18),
                const SizedBox(width: 8),
                Text('Severity Level', style: TextStyle(fontSize: 14, color: Colors.grey[700])),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: getSeverityBgColor(result.severity.level),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: getSeverityColor(result.severity.level).withOpacity(0.3)),
              ),
              child: Text(
                getSeverityDisplay(result.severity.level),
                style: TextStyle(
                  color: getSeverityColor(result.severity.level),
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Detected Emotion
            Row(
              children: [
                Icon(Icons.mood, color: Colors.grey[600], size: 18),
                const SizedBox(width: 8),
                Text('Detected Emotion', style: TextStyle(fontSize: 14, color: Colors.grey[700])),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF9C27B0).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF9C27B0).withOpacity(0.3)),
              ),
              child: Text(
                result.emotion.label,
                style: const TextStyle(
                  color: Color(0xFF9C27B0),
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Anxiety Indicators - CLICKABLE
            Row(
              children: [
                Icon(Icons.psychology_alt, color: Colors.grey[600], size: 18),
                const SizedBox(width: 8),
                Text('Anxiety Indicators', style: TextStyle(fontSize: 14, color: Colors.grey[700])),
              ],
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                if (result.anxietyIndicators.isNotEmpty) {
                  _showAnxietyDetailsDialog(result.anxietyIndicators);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF03A9F4).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF03A9F4).withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      result.anxietyIndicators.isEmpty ? 'None Detected' : 
                        '${result.anxietyIndicators.where((i) => i.detected).length} Detected',
                      style: const TextStyle(
                        color: Color(0xFF03A9F4),
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    if (result.anxietyIndicators.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.info_outline, color: Color(0xFF03A9F4), size: 16),
                    ],
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Educational Insights
            Row(
              children: [
                Icon(Icons.school, color: Colors.grey[600], size: 18),
                const SizedBox(width: 8),
                Text('Educational Insights', style: TextStyle(fontSize: 14, color: Colors.grey[700])),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF009688).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF009688).withOpacity(0.3)),
              ),
              child: Text(
                result.severity.level == 'Normal' ? 'No Significant Issues' : 'Review Recommended',
                style: const TextStyle(
                  color: Color(0xFF009688),
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Confidence Footer
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.verified_user, color: Colors.green[600], size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Analysis completed with ${result.severity.confidence}% confidence based on vocal biomarkers.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700], fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    if (_currentTranscription != null) {
                      _showTranscriptionDialog(_currentTranscription!);
                    }
                  },
                  child: const Text(
                    'Back to Transcript',
                    style: TextStyle(color: Color(0xFF4CAF50), fontWeight: FontWeight.w600),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Show detailed anxiety indicators with explanations
void _showAnxietyDetailsDialog(List<AnxietyIndicator> indicators) {
  showDialog(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        padding: const EdgeInsets.all(20),
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.psychology_alt, color: Color(0xFF03A9F4)),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Anxiety Indicators',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                 ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: indicators.length,
                itemBuilder: (context, index) {
                  final indicator = indicators[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    elevation: 2,
                    child: ExpansionTile(
                      leading: Icon(
                        indicator.detected ? Icons.warning : Icons.check_circle_outline,
                        color: indicator.detected ? Colors.orange : Colors.green,
                      ),
                      title: Text(
                        indicator.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text('${indicator.probability}% probability'),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (indicator.insights['description'] != null) ...[
                                const Text(
                                  'Description:',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  indicator.insights['description'],
                                  style: const TextStyle(fontSize: 13),
                                ),
                                const SizedBox(height: 12),
                              ],
                              if (indicator.insights['tips'] != null && indicator.insights['tips'] is List) ...[
                                const Text(
                                  'Tips:',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                const SizedBox(height: 4),
                                ...( indicator.insights['tips'] as List).map((tip) => Padding(
                                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('• ', style: TextStyle(fontSize: 16)),
                                      Expanded(child: Text(tip.toString(), style: const TextStyle(fontSize: 13))),
                                    ],
                                  ),
                                )).toList(),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
