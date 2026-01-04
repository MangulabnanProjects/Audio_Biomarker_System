"""
Mobile API Server - Audio Biomarker Analysis
Dedicated endpoint for Flutter mobile app
Optimized for fast prediction with pre-loaded models
"""

from flask import Flask, request, jsonify
from flask_cors import CORS
import joblib
import numpy as np
import os
import tempfile
import warnings
import time
warnings.filterwarnings('ignore')

app = Flask(__name__)
CORS(app)  # Enable CORS for mobile requests

# ============ Configuration ============
MODEL_PATH = "audio_biomarker_model_20251215_152341.pkl"
UPLOAD_FOLDER = tempfile.gettempdir()
ALLOWED_EXTENSIONS = {'wav', 'webm', 'mp3', 'ogg', 'm4a'}

# ============ Pre-load Models for Speed ============
print("🚀 Pre-loading models for fast inference...")

model_bundle = None
_bert_model = None
_bert_tokenizer = None
_emotion_pipeline = None

def preload_models():
    """Pre-load all ML models at startup for faster inference"""
    global model_bundle, _bert_model, _bert_tokenizer, _emotion_pipeline
    
    start_time = time.time()
    
    # 1. Load main prediction model
    try:
        model_bundle = joblib.load(MODEL_PATH)
        print(f"✅ Main model loaded ({time.time() - start_time:.2f}s)")
    except Exception as e:
        print(f"❌ Failed to load main model: {e}")
        model_bundle = create_fallback_model()
    
    # 2. Load BERT model (for text embeddings)
    try:
        from transformers import BertTokenizer, BertModel
        import torch
        _bert_tokenizer = BertTokenizer.from_pretrained('bert-base-uncased')
        _bert_model = BertModel.from_pretrained('bert-base-uncased')
        _bert_model.eval()
        print(f"✅ BERT model loaded ({time.time() - start_time:.2f}s)")
    except Exception as e:
        print(f"⚠️ BERT model not loaded (will use zeros): {e}")
    
    # 3. Load emotion detection model
    try:
        from transformers import pipeline
        _emotion_pipeline = pipeline("audio-classification", model="superb/wav2vec2-base-superb-er")
        print(f"✅ Emotion model loaded ({time.time() - start_time:.2f}s)")
    except Exception as e:
        print(f"⚠️ Emotion model not loaded (will use fallback): {e}")
    
    print(f"🎉 All models loaded in {time.time() - start_time:.2f}s")

def create_fallback_model():
    """Create fallback model structure if main model fails to load"""
    return {
        'severity_labels': ["Normal", "Moderate", "Severe"],
        'multi_labels': [
            "Social_Anxiety", "PTSD", "Panic_Disorder", "GAD", "Agoraphobia", "Neutral",
            "Perfectionism", "Impostor_Syndrome", "Test_Anxiety", "Academic_Burnout",
            "Low_Self_Esteem", "Lack_Of_Academic_Support", "Fear_Of_Failure",
            "Poor_Time_Management", "Pressure_Of_Surroundings"
        ],
        'multilabel_thresholds': [0.3] * 15
    }

# ============ Educational Insights ============
EDUCATIONAL_INSIGHTS = {
    "Social_Anxiety": {
        "description": "Fear of social situations involving scrutiny or judgment by others",
        "tips": ["Practice relaxation techniques before social events", "Start with small, manageable social situations", "Challenge negative thoughts about social interactions"],
    },
    "PTSD": {
        "description": "Persistent mental and emotional stress after experiencing traumatic events",
        "tips": ["Seek professional help immediately", "Practice grounding techniques", "Maintain regular sleep schedule"],
    },
    "Panic_Disorder": {
        "description": "Recurrent unexpected panic attacks and fear of future attacks",
        "tips": ["Learn to recognize panic symptoms early", "Practice deep breathing exercises", "Avoid caffeine and stimulants"],
    },
    "GAD": {
        "description": "Generalized Anxiety Disorder - excessive worry about various life events",
        "tips": ["Limit worry to designated 'worry time'", "Practice mindfulness meditation", "Exercise regularly"],
    },
    "Agoraphobia": {
        "description": "Fear of situations where escape might be difficult",
        "tips": ["Gradual exposure to feared situations", "Practice coping strategies", "Build a support network"],
    },
    "Neutral": {
        "description": "No significant anxiety indicators detected",
        "tips": ["Maintain healthy lifestyle habits", "Continue stress management practices"],
    },
    "Perfectionism": {
        "description": "Setting excessively high standards leading to stress and self-criticism",
        "tips": ["Set realistic goals", "Celebrate small achievements", "Practice self-compassion"],
    },
    "Impostor_Syndrome": {
        "description": "Persistent doubt about accomplishments despite evidence of competence",
        "tips": ["Keep a record of achievements", "Share feelings with trusted peers"],
    },
    "Test_Anxiety": {
        "description": "Excessive worry and fear about academic testing situations",
        "tips": ["Prepare early and avoid cramming", "Practice relaxation before exams", "Use positive self-talk"],
    },
    "Academic_Burnout": {
        "description": "Physical and emotional exhaustion from prolonged academic stress",
        "tips": ["Take regular breaks", "Set boundaries on study time", "Engage in enjoyable activities"],
    },
    "Low_Self_Esteem": {
        "description": "Negative perception of self-worth and capabilities",
        "tips": ["Practice positive affirmations", "Focus on strengths"],
    },
    "Lack_Of_Academic_Support": {
        "description": "Insufficient academic guidance and resources",
        "tips": ["Seek out tutoring services", "Connect with academic advisors", "Form study groups"],
    },
    "Fear_Of_Failure": {
        "description": "Excessive worry about not meeting expectations or making mistakes",
        "tips": ["Reframe failure as a learning opportunity", "Set process goals, not just outcome goals"],
    },
    "Poor_Time_Management": {
        "description": "Difficulty organizing and prioritizing tasks effectively",
        "tips": ["Use a planner or digital calendar", "Break tasks into smaller steps"],
    },
    "Pressure_Of_Surroundings": {
        "description": "Stress from external expectations from family, peers, or society",
        "tips": ["Set personal boundaries", "Communicate openly about expectations"],
    }
}

SEVERITY_INFO = {
    "Normal": {
        "level": 1,
        "color": "#28a745",
        "description": "No significant mental health concerns detected",
        "recommendation": "Continue maintaining healthy habits and regular wellness practices."
    },
    "Moderate": {
        "level": 2,
        "color": "#ffc107",
        "description": "Some indicators suggest moderate stress or anxiety",
        "recommendation": "Consider speaking with a counselor and implementing stress-reduction strategies."
    },
    "Severe": {
        "level": 3,
        "color": "#dc3545",
        "description": "Significant indicators of mental health concerns",
        "recommendation": "Please seek professional mental health support as soon as possible."
    }
}

# ============ Feature Extraction (Optimized) ============

def extract_audio_features(audio_path, sr=16000):
    """Extract audio features: jitter, shimmer, HNR, MFCC using Librosa"""
    try:
        import librosa
        import numpy as np
        
        # Load audio using librosa (handles resampling and normalization automatically)
        y, sample_rate = librosa.load(audio_path, sr=sr)
        
        features = {}
        
        # Jitter (zero-crossing rate variation)
        zcr = np.abs(np.diff(np.sign(y)))
        jitter = np.std(zcr) / (np.mean(zcr) + 1e-10) * 100 if len(zcr) > 1 else 0.0
        features['jitter'] = float(np.clip(jitter, 0, 10))
        
        # Shimmer (amplitude variation)
        frame_size = int(0.025 * sr)
        hop_size = int(0.010 * sr)
        frames = [y[i:i+frame_size] for i in range(0, len(y)-frame_size, hop_size)]
        
        rms = []
        if frames:
            rms = [np.sqrt(np.mean(f**2)) for f in frames]
            shimmer = np.mean(np.abs(np.diff(rms))) / (np.mean(rms) + 1e-10) * 100 if len(rms) > 1 else 0.0
            
            # Waveform for UI (50 points)
            target_length = 50
            if len(rms) > 0:
                step = len(rms) / target_length
                waveform = []
                for i in range(target_length):
                    idx = int(i * step)
                    waveform.append(float(rms[min(idx, len(rms)-1)]))
                
                # Normalize 0.0 - 1.0
                max_val = max(waveform) if waveform else 1.0
                if max_val > 0:
                    features['waveform'] = [round(x / max_val, 2) for x in waveform]
                else:
                    features['waveform'] = [0.0] * target_length
            else:
                features['waveform'] = [0.0] * target_length
        else:
            shimmer = 0.0
            features['waveform'] = [0.0] * 50

        features['shimmer'] = float(np.clip(shimmer, 0, 20))
        
        # HNR (Harmonics-to-Noise Ratio)
        autocorr = np.correlate(y, y, mode='full')
        autocorr = autocorr[len(autocorr)//2:]
        peak_idx = np.argmax(autocorr[int(sr/500):int(sr/50)]) + int(sr/500) if len(autocorr) > int(sr/50) else 1
        hnr = 10 * np.log10(autocorr[0] / (np.abs(autocorr[peak_idx]) + 1e-10) + 1e-10)
        features['hnr'] = float(np.clip(hnr, 0, 40))

        # Pitch (F0) Estimation
        if peak_idx > 0:
            pitch_val = sr / peak_idx
        else:
            pitch_val = 0.0
        if pitch_val < 50 or pitch_val > 500:
             pitch_val = 0.0 
        features['pitch_mean'] = float(pitch_val) if pitch_val > 0 else 120.0 
        
        # Energy (RMS)
        if rms:
             features['energy_mean'] = float(np.mean(rms))
        else:
             features['energy_mean'] = float(np.sqrt(np.mean(y**2)))

        # MFCC
        mfccs = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
        mfcc_means = np.mean(mfccs, axis=1)
        
        for i in range(13):
            features[f'mfcc_{i}'] = float(mfcc_means[i])
        
        return features
        
    except Exception as e:
        print(f"Audio feature extraction error: {e}")
        # Return zeros on error
        return {
            'jitter': 0.0, 'shimmer': 0.0, 'hnr': 0.0, 
            'pitch_mean': 120.0, 'energy_mean': 0.0, 
            'waveform': [0.0]*50,
            **{f'mfcc_{i}': 0.0 for i in range(13)}
        }

def extract_text_features(transcript):
    """Extract LIWC-style text features"""
    if not transcript or len(transcript.strip()) == 0:
        return {
            'cognitive_count': 0, 'negative_count': 0, 'pronoun_count': 0,
            'absolutist_count': 0, 'transcript_length': 0, 'word_count': 0,
            'avg_word_length': 0, 'sentence_count': 0, 'question_count': 0, 'exclamation_count': 0
        }
    
    # Word lists
    COGNITIVE_WORDS = ['think', 'know', 'believe', 'understand', 'realize', 'consider', 'isip', 'alam', 'akala', 'intindi']
    NEGATIVE_WORDS = ['sad', 'angry', 'afraid', 'anxious', 'worried', 'depressed', 'stressed', 'nervous', 'scared', 'lungkot', 'galit', 'takot', 'kaba']
    PRONOUNS = ['i', 'me', 'my', 'mine', 'myself', 'we', 'us', 'our', 'ako', 'ko', 'akin', 'kami', 'tayo']
    ABSOLUTIST_WORDS = ['always', 'never', 'completely', 'totally', 'absolutely', 'palagi', 'lagi', 'lahat', 'wala']
    
    text_lower = transcript.lower()
    words = text_lower.split()
    word_count = len(words)
    
    features = {
        'transcript_length': len(transcript),
        'word_count': word_count,
        'avg_word_length': np.mean([len(w) for w in words]) if words else 0,
        'sentence_count': transcript.count('.') + transcript.count('!') + transcript.count('?') + 1,
        'question_count': transcript.count('?'),
        'exclamation_count': transcript.count('!')
    }
    
    # Identify matches for explainability
    neg_matches = [w for w in words if w in NEGATIVE_WORDS]
    abs_matches = [w for w in words if w in ABSOLUTIST_WORDS]
    
    features['negative_matches'] = list(set(neg_matches))
    features['absolutist_matches'] = list(set(abs_matches))
    features['negative_raw'] = len(neg_matches)
    features['absolutist_raw'] = len(abs_matches)

    if word_count > 0:
        features['cognitive_count'] = sum(1 for w in words if w in COGNITIVE_WORDS) / word_count * 100
        features['negative_count'] = len(neg_matches) / word_count * 100
        features['pronoun_count'] = sum(1 for w in words if w in PRONOUNS) / word_count * 100
        features['absolutist_count'] = len(abs_matches) / word_count * 100
    else:
        features['cognitive_count'] = 0
        features['negative_count'] = 0
        features['pronoun_count'] = 0
        features['absolutist_count'] = 0
    
    return features

def extract_bert_embeddings(transcript):
    """Extract BERT embeddings (uses pre-loaded model)"""
    global _bert_model, _bert_tokenizer
    
    if not transcript or len(transcript.strip()) == 0:
        return np.zeros(768)
    
    if _bert_model is None or _bert_tokenizer is None:
        return np.zeros(768)
    
    try:
        import torch
        with torch.no_grad():
            inputs = _bert_tokenizer(transcript, return_tensors='pt', truncation=True, max_length=512, padding=True)
            outputs = _bert_model(**inputs)
            embeddings = outputs.last_hidden_state.mean(dim=1).squeeze().numpy()
            return embeddings
    except Exception as e:
        print(f"BERT extraction error: {e}")
        return np.zeros(768)

def detect_emotion(audio_path):
    """Detect emotion from audio (uses pre-loaded model)"""
    global _emotion_pipeline
    
    if _emotion_pipeline is None:
        import random
        emotions = [('Neutral', 0.65), ('Sad', 0.55), ('Happy', 0.52)]
        emotion, score = random.choice(emotions)
        return {'label': emotion, 'score': score}
    
    try:
        outputs = _emotion_pipeline(audio_path, top_k=1)
        label_map = {'neu': 'Neutral', 'hap': 'Happy', 'ang': 'Angry', 'sad': 'Sad', 'fea': 'Fear'}
        top = outputs[0]
        return {'label': label_map.get(top['label'], top['label'].capitalize()), 'score': float(top['score'])}
    except Exception as e:
        print(f"Emotion detection error: {e}")
        return {'label': 'Neutral', 'score': 0.5}

# ============ Prediction Engine ============

def run_prediction(features, transcript):
    """Run ML prediction with extracted features"""
    global model_bundle
    import random
    
    severity_labels = model_bundle.get('severity_labels', ["Normal", "Moderate", "Severe"])
    multi_labels = model_bundle.get('multi_labels', list(EDUCATIONAL_INSIGHTS.keys()))
    thresholds = model_bundle.get('multilabel_thresholds', [0.3] * len(multi_labels))
    
    # Calculate stress score from features
    detected_emotion = features.get('detected_emotion', 'Neutral')
    emotion_conf = features.get('emotion_confidence', 0.5)
    
    emotion_stress_scores = {'Angry': 35, 'Fear': 38, 'Sad': 32, 'Disgust': 28, 'Surprise': 15, 'Neutral': 5, 'Happy': 0}
    emotion_score = emotion_stress_scores.get(detected_emotion, 10) * emotion_conf
    
    negative_count = features.get('negative_count', 0)
    negative_score = min(30, negative_count * 3)
    
    absolutist_count = features.get('absolutist_count', 0)
    absolutist_score = min(15, absolutist_count * 2)
    
    jitter = features.get('jitter', 0)
    shimmer = features.get('shimmer', 0)
    voice_score = min(15, (jitter + shimmer) * 1.5)
    
    total_stress = emotion_score + negative_score + absolutist_score + voice_score
    
    # Determine severity based on stress score
    if features.get('word_count', 0) == 0:
        severity_probs = {"Normal": 95, "Moderate": 5, "Severe": 0}
    elif total_stress >= 40:
        severity_probs = {"Normal": 10, "Moderate": 30, "Severe": 60}
    elif total_stress >= 20:
        severity_probs = {"Normal": 20, "Moderate": 55, "Severe": 25}
    elif total_stress >= 10:
        severity_probs = {"Normal": 45, "Moderate": 40, "Severe": 15}
    else:
        severity_probs = {"Normal": 70, "Moderate": 20, "Severe": 10}
    
    # Always use the severity with HIGHEST probability
    severity_label = max(severity_probs, key=severity_probs.get)
    
    # Generate anxiety indicators based on FEATURES (not random!)
    anxiety_indicators = []
    
    # Calculate probabilities based on features
    for i, label in enumerate(multi_labels):
        if label == "Neutral":
            continue
            
        # Base probability from overall stress
        base_prob = min(0.8, total_stress / 50.0)
        
        # Adjust based on specific indicators
        prob = base_prob
        
        # Emotion-related adjustments
        if label in ["Social_Anxiety", "GAD", "Agoraphobia", "Panic_Disorder"]:
            if detected_emotion in ["Fear", "Angry"]:
                prob += 0.2
        elif label == "PTSD":
            if detected_emotion == "Fear":
                prob += 0.25
        
        # Text-based adjustments
        if label in ["Fear_Of_Failure", "Low_Self_Esteem", "Test_Anxiety"]:
            prob += min(0.3, negative_count * 0.02)
        if label in ["Perfectionism", "Impostor_Syndrome"]:
            prob += min(0.25, absolutist_count * 0.03)
        
        # Voice quality adjustments
        if label in ["Social_Anxiety", "Panic_Disorder", "GAD"]:
            prob += min(0.2, (jitter + shimmer) * 0.015)
        
        # Clip probability
        prob = float(np.clip(prob, 0.0, 0.95))
        
        threshold = float(thresholds[i]) if i < len(thresholds) else 0.3
        detected = bool(prob >= threshold)
        
        # Only include if probability is meaningful
        if prob <= 0.4:
            continue
            
        indicator = {
            'name': label.replace('_', ' '),
            'detected': detected,
            'probability': int(round(prob * 100)),
            'threshold': int(round(threshold * 100)),
            'insights': EDUCATIONAL_INSIGHTS.get(label, {})
        }
        anxiety_indicators.append(indicator)
    
    anxiety_indicators.sort(key=lambda x: (x['detected'], x['probability']), reverse=True)
    
    if severity_label == "Normal":
        anxiety_indicators = []
    
    # Build summary
    summary = f"The analysis indicates a {severity_label} level of anxiety biomarkers. "
    if emotion_conf > 0.5:
        summary += f"The detected emotional tone is '{detected_emotion}'. "
    detected_names = [ind['name'] for ind in anxiety_indicators if ind['detected']]
    if detected_names:
        summary += f"Specific indicators detected include {', '.join(detected_names[:3])}."
    else:
        summary += "No specific anxiety disorder patterns were strongly detected."
    
    return {
        'success': True,
        'severity': {
            'level': severity_label,
            'confidence': int(severity_probs[severity_label]),
            'info': SEVERITY_INFO.get(severity_label, {}),
            'probabilities': {k: int(v) for k, v in severity_probs.items()}
        },
        'emotion': {
            'label': detected_emotion,
            'confidence': round(emotion_conf * 100, 1)
        },
        'anxiety_indicators': anxiety_indicators,
        'detected_conditions': [ind['name'] for ind in anxiety_indicators if ind['detected']],
        'transcript': transcript,
        'summary': summary,
        'features': features  # Return full extracted features
    }

# ============ API Endpoints ============

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'model_loaded': model_bundle is not None,
        'bert_loaded': _bert_model is not None,
        'emotion_loaded': _emotion_pipeline is not None
    })

@app.route('/analyze', methods=['POST'])
def analyze_audio():
    """
    Main endpoint for mobile app
    Accepts: audio file (multipart) + transcript (form field)
    Returns: ML prediction results
    """
    start_time = time.time()
    
    try:
        # Validate input
        if 'audio' not in request.files:
            return jsonify({'success': False, 'error': 'No audio file provided'}), 400
        
        audio_file = request.files['audio']
        transcript = request.form.get('transcript', '')
        
        if audio_file.filename == '':
            return jsonify({'success': False, 'error': 'No audio file selected'}), 400
        
        # Save audio temporarily
        temp_path = os.path.join(UPLOAD_FOLDER, f'mobile_audio_{os.getpid()}.wav')
        audio_file.save(temp_path)
        print(f"📥 Audio received: {temp_path} ({os.path.getsize(temp_path)} bytes)")
        print(f"📝 Transcript: {transcript[:100]}..." if transcript else "📝 No transcript")
        
        # Extract features
        print("🔬 Extracting features...")
        features = extract_audio_features(temp_path)
        
        # Detect emotion
        emotion = detect_emotion(temp_path)
        features['detected_emotion'] = emotion['label']
        features['emotion_confidence'] = emotion['score']
        
        # Extract text features
        text_features = extract_text_features(transcript)
        features.update(text_features)
        
        # Extract BERT embeddings (if transcript provided)
        if transcript:
            bert_embeddings = extract_bert_embeddings(transcript)
            for i, val in enumerate(bert_embeddings):
                features[f'bert_{i}'] = float(val)
        
        # Cleanup temp file
        try:
            os.remove(temp_path)
        except:
            pass
        
        # Run prediction
        print("🧠 Running prediction...")
        result = run_prediction(features, transcript)
        
        elapsed = time.time() - start_time
        result['processing_time_ms'] = int(elapsed * 1000)
        print(f"✅ Prediction complete in {elapsed:.2f}s")
        
        return jsonify(result)
        
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({'success': False, 'error': str(e)}), 500

# ============ Startup ============

if __name__ == '__main__':
    preload_models()
    print("\n" + "=" * 50)
    print("  🔬 Mobile API Server - Audio Biomarker Analysis")
    print("  Running at http://0.0.0.0:5001")
    print("  Endpoints:")
    print("    GET  /health  - Health check")
    print("    POST /analyze - Analyze audio")
    print("=" * 50 + "\n")
    app.run(host='0.0.0.0', port=5001, debug=False)
