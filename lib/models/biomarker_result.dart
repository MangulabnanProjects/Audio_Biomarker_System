/// Data model for biomarker analysis results from the ML model
class BiomarkerResult {
  final bool success;
  final Severity severity;
  final Emotion emotion;
  final List<AnxietyIndicator> anxietyIndicators;
  final List<String> detectedConditions;
  final String transcript;
  final String summary;
  final int? processingTimeMs;
  final String? error;
  final Map<String, dynamic>? features;

  BiomarkerResult({
    required this.success,
    required this.severity,
    required this.emotion,
    required this.anxietyIndicators,
    required this.detectedConditions,
    required this.transcript,
    required this.summary,
    this.processingTimeMs,
    this.error,
    this.features,
  });

  factory BiomarkerResult.fromJson(Map<String, dynamic> json) {
    return BiomarkerResult(
      success: json['success'] ?? false,
      severity: Severity.fromJson(json['severity'] ?? {}),
      emotion: Emotion.fromJson(json['emotion'] ?? {}),
      anxietyIndicators: (json['anxiety_indicators'] as List<dynamic>?)
          ?.map((e) => AnxietyIndicator.fromJson(e))
          .toList() ?? [],
      detectedConditions: List<String>.from(json['detected_conditions'] ?? []),
      transcript: json['transcript'] ?? '',
      summary: json['summary'] ?? '',
      processingTimeMs: json['processing_time_ms'],
      error: json['error'],
      features: json['features'] as Map<String, dynamic>?,
    );
  }

  factory BiomarkerResult.error(String message) {
    return BiomarkerResult(
      success: false,
      severity: Severity.normal(),
      emotion: Emotion.neutral(),
      anxietyIndicators: [],
      detectedConditions: [],
      transcript: '',
      summary: '',
      error: message,
    );
  }
}

class Severity {
  final String level;
  final int confidence;
  final SeverityInfo info;
  final Map<String, int> probabilities;

  Severity({
    required this.level,
    required this.confidence,
    required this.info,
    required this.probabilities,
  });

  factory Severity.fromJson(Map<String, dynamic> json) {
    return Severity(
      level: json['level'] ?? 'Normal',
      confidence: json['confidence'] ?? 0,
      info: SeverityInfo.fromJson(json['info'] ?? {}),
      probabilities: Map<String, int>.from(json['probabilities'] ?? {}),
    );
  }

  factory Severity.normal() {
    return Severity(
      level: 'Normal',
      confidence: 0,
      info: SeverityInfo.fromJson({}),
      probabilities: {},
    );
  }

  bool get isNormal => level == 'Normal';
  bool get isModerate => level == 'Moderate';
  bool get isSevere => level == 'Severe';
}

class SeverityInfo {
  final int level;
  final String color;
  final String description;
  final String recommendation;

  SeverityInfo({
    required this.level,
    required this.color,
    required this.description,
    required this.recommendation,
  });

  factory SeverityInfo.fromJson(Map<String, dynamic> json) {
    return SeverityInfo(
      level: json['level'] ?? 1,
      color: json['color'] ?? '#28a745',
      description: json['description'] ?? '',
      recommendation: json['recommendation'] ?? '',
    );
  }
}

class Emotion {
  final String label;
  final double confidence;

  Emotion({
    required this.label,
    required this.confidence,
  });

  factory Emotion.fromJson(Map<String, dynamic> json) {
    return Emotion(
      label: json['label'] ?? 'Neutral',
      confidence: (json['confidence'] ?? 0).toDouble(),
    );
  }

  factory Emotion.neutral() {
    return Emotion(label: 'Neutral', confidence: 0);
  }

  String get emoji {
    switch (label.toLowerCase()) {
      case 'happy':
        return '😊';
      case 'sad':
        return '😢';
      case 'angry':
        return '😠';
      case 'fear':
        return '😨';
      case 'disgust':
        return '🤢';
      case 'surprise':
        return '😲';
      default:
        return '😐';
    }
  }
}

class AnxietyIndicator {
  final String name;
  final bool detected;
  final int probability;
  final int threshold;
  final IndicatorInsights insights;

  AnxietyIndicator({
    required this.name,
    required this.detected,
    required this.probability,
    required this.threshold,
    required this.insights,
  });

  factory AnxietyIndicator.fromJson(Map<String, dynamic> json) {
    return AnxietyIndicator(
      name: json['name'] ?? '',
      detected: json['detected'] ?? false,
      probability: json['probability'] ?? 0,
      threshold: json['threshold'] ?? 30,
      insights: IndicatorInsights.fromJson(json['insights'] ?? {}),
    );
  }
}

class IndicatorInsights {
  final String description;
  final List<String> tips;

  IndicatorInsights({
    required this.description,
    required this.tips,
  });

  factory IndicatorInsights.fromJson(Map<String, dynamic> json) {
    return IndicatorInsights(
      description: json['description'] ?? '',
      tips: List<String>.from(json['tips'] ?? []),
    );
  }
}
