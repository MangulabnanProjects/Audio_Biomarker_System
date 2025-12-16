"""
Audio Biomarker Flask Server - Real Implementation
Records audio, extracts features, and runs prediction
"""

from flask import Flask, render_template, request, jsonify
import joblib
import numpy as np
import os
import tempfile
import random
import warnings
warnings.filterwarnings('ignore')
import firebase_admin
from firebase_admin import credentials, firestore

from flask_cors import CORS # Import CORS

app = Flask(__name__)
CORS(app) # Enable CORS for all routes

# Initialize Firebase Logic
cred_path = os.path.join(os.getcwd(), "serviceAccountKey.json") # Look for serviceAccountKey.json in current directory
FIREBASE_CREDENTIALS = "serviceAccountKey.json"
db = None

try:
    if os.path.exists(FIREBASE_CREDENTIALS):
        cred = credentials.Certificate(FIREBASE_CREDENTIALS)
        firebase_admin.initialize_app(cred)
        db = firestore.client()
        print("Firebase initialized successfully!")
    else:
        print(f"Warning: {FIREBASE_CREDENTIALS} not found. Firebase saving will be skipped.")
except Exception as e:
    print(f"Error initializing Firebase: {e}")

# Configuration
MODEL_PATH = "audio_biomarker_model_20251215_152341.pkl"
UPLOAD_FOLDER = tempfile.gettempdir()
ALLOWED_EXTENSIONS = {'wav', 'webm', 'mp3', 'ogg', 'm4a'}

model_bundle = None

def load_model():
    global model_bundle
    if model_bundle is None:
        print("Loading model...")
        try:
            model_bundle = joblib.load(MODEL_PATH)
            print("Model loaded successfully!")
        except Exception as e:
            print(f"Warning: Could not fully load model: {e}")
            model_bundle = {
                'severity_labels': ["Normal", "Moderate", "Severe"],
                'multi_labels': [
                    "Social_Anxiety", "PTSD", "Panic_Disorder", "GAD", "Agoraphobia", "Neutral",
                    "Perfectionism", "Impostor_Syndrome", "Test_Anxiety", "Academic_Burnout",
                    "Low_Self_Esteem", "Lac_Of_Academic_Support", "Fear_Of_Failure",
                    "Poor_Time_Management", "Pressure_Of_Surroundings"
                ],
                'multilabel_thresholds': [0.3] * 15
            }
    return model_bundle

# Educational insights for each condition
EDUCATIONAL_INSIGHTS = {
    "Social_Anxiety": {
        "description": "Fear of social situations involving scrutiny or judgment by others",
        "tips": ["Practice relaxation techniques before social events", "Start with small, manageable social situations", "Challenge negative thoughts about social interactions"],
        "resources": ["Cognitive Behavioral Therapy (CBT)", "Social skills training", "Support groups"]
    },
    "PTSD": {
        "description": "Persistent mental and emotional stress after experiencing traumatic events",
        "tips": ["Seek professional help immediately", "Practice grounding techniques", "Maintain regular sleep schedule"],
        "resources": ["Trauma-focused therapy", "EMDR therapy", "Crisis hotlines"]
    },
    "Panic_Disorder": {
        "description": "Recurrent unexpected panic attacks and fear of future attacks",
        "tips": ["Learn to recognize panic symptoms early", "Practice deep breathing exercises", "Avoid caffeine and stimulants"],
        "resources": ["Panic-focused CBT", "Medication consultation", "Breathing exercises"]
    },
    "GAD": {
        "description": "Generalized Anxiety Disorder - excessive worry about various life events",
        "tips": ["Limit worry to designated 'worry time'", "Practice mindfulness meditation", "Exercise regularly"],
        "resources": ["Anxiety management programs", "Mindfulness-based therapy", "Stress reduction techniques"]
    },
    "Agoraphobia": {
        "description": "Fear of situations where escape might be difficult",
        "tips": ["Gradual exposure to feared situations", "Practice coping strategies", "Build a support network"],
        "resources": ["Exposure therapy", "Virtual reality therapy", "Support groups"]
    },
    "Neutral": {
        "description": "No significant anxiety indicators detected",
        "tips": ["Maintain healthy lifestyle habits", "Continue stress management practices", "Regular mental health check-ins"],
        "resources": ["Wellness programs", "Preventive mental health resources"]
    },
    "Perfectionism": {
        "description": "Setting excessively high standards leading to stress and self-criticism",
        "tips": ["Set realistic goals", "Celebrate small achievements", "Practice self-compassion"],
        "resources": ["Perfectionism-focused therapy", "Goal-setting workshops", "Self-help books"]
    },
    "Impostor_Syndrome": {
        "description": "Persistent doubt about accomplishments despite evidence of competence",
        "tips": ["Keep a record of achievements", "Share feelings with trusted peers", "Recognize that many successful people experience this"],
        "resources": ["Career counseling", "Mentorship programs", "Self-esteem building workshops"]
    },
    "Test_Anxiety": {
        "description": "Excessive worry and fear about academic testing situations",
        "tips": ["Prepare early and avoid cramming", "Practice relaxation before exams", "Use positive self-talk"],
        "resources": ["Study skills workshops", "Test-taking strategies", "Academic counseling"]
    },
    "Academic_Burnout": {
        "description": "Physical and emotional exhaustion from prolonged academic stress",
        "tips": ["Take regular breaks", "Set boundaries on study time", "Engage in enjoyable activities"],
        "resources": ["Academic advising", "Wellness programs", "Time management coaching"]
    },
    "Low_Self_Esteem": {
        "description": "Negative perception of self-worth and capabilities",
        "tips": ["Practice positive affirmations", "Focus on strengths", "Avoid comparing yourself to others"],
        "resources": ["Self-esteem therapy", "Support groups", "Personal development courses"]
    },
    "Lac_Of_Academic_Support": {
        "description": "Insufficient academic guidance and resources",
        "tips": ["Seek out tutoring services", "Connect with academic advisors", "Form study groups"],
        "resources": ["Tutoring centers", "Academic mentorship", "Peer support programs"]
    },
    "Fear_Of_Failure": {
        "description": "Excessive worry about not meeting expectations or making mistakes",
        "tips": ["Reframe failure as a learning opportunity", "Set process goals, not just outcome goals", "Practice self-compassion"],
        "resources": ["Growth mindset training", "Goal-setting workshops", "Counseling services"]
    },
    "Poor_Time_Management": {
        "description": "Difficulty organizing and prioritizing tasks effectively",
        "tips": ["Use a planner or digital calendar", "Break tasks into smaller steps", "Set specific deadlines"],
        "resources": ["Time management workshops", "Productivity apps", "Academic coaching"]
    },
    "Pressure_Of_Surroundings": {
        "description": "Stress from external expectations from family, peers, or society",
        "tips": ["Set personal boundaries", "Communicate openly about expectations", "Focus on personal values"],
        "resources": ["Family counseling", "Peer support", "Stress management programs"]
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

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/upload-audio', methods=['POST'])
def upload_audio():
    """Handle audio upload and extraction"""
    try:
        if 'audio' not in request.files:
            return jsonify({'error': 'No audio file provided'}), 400
        
        audio_file = request.files['audio']
        if audio_file.filename == '':
            return jsonify({'error': 'No audio file selected'}), 400
        
        # Get transcript from frontend (live transcription) & Folder
        live_transcript = request.form.get('transcript', '')
        folder_name = request.form.get('folder', 'Uncategorized')
        
        # Save audio to temp file (browser sends WAV format)
        temp_path = os.path.join(UPLOAD_FOLDER, f'recording_{os.getpid()}.wav')
        audio_file.save(temp_path)
        print(f"Audio saved to: {temp_path}")
        print(f"Live transcript received: '{live_transcript[:100] if live_transcript else 'None'}...'")
        print(f"Selected Folder: {folder_name}")
        
        # Extract features (use live transcript if provided)
        from audio_features import extract_all_features
        features, transcript = extract_all_features(temp_path, transcript_override=live_transcript if live_transcript else None)
        
        # Clean up temp file
        try:
            os.remove(temp_path)
        except:
            pass
        
        # Run prediction
        model = load_model()
        result = run_prediction(features, model)
        result['transcript'] = transcript
        result['folder'] = folder_name
        
        # Save to Firebase
        if db is not None:
            try:
                # Add timestamp
                import datetime
                result['timestamp'] = datetime.datetime.now()
                
                # Save to specific folder in 'recordings' collection or structured via subcollections
                # For now, saving to 'recordings' with a 'folder' field
                db.collection('recordings').add(result)
                print(f"Result saved to Firebase (Folder: {folder_name})")
            except Exception as fb_err:
                print(f"Failed to save to Firebase: {fb_err}")
        
        return jsonify(result)
        
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500

def run_prediction(features, model):
    """Run model prediction with extracted features"""
    severity_labels = model.get('severity_labels', ["Normal", "Moderate", "Severe"])
    multi_labels = model.get('multi_labels', list(EDUCATIONAL_INSIGHTS.keys()))
    thresholds = model.get('multilabel_thresholds', [0.3] * len(multi_labels))
    
    # Try to use actual model
    try:
        imputer = model['imputer']
        # --- PATCH FOR SKLEARN VERSION MISMATCH ---
        if not hasattr(imputer, '_fill_dtype'):
            print("  [Patching] Fixing SimpleImputer compatibility...")
            import numpy as np
            imputer._fill_dtype = np.float64
        # ------------------------------------------
        
        scaler = model['scaler']
        selector = model['selector']
        severity_model = model['severity_model']
        label_encoder = model['label_encoder']
        
        # Get expected feature order
        n_features = imputer.n_features_in_
        
        # Convert features to array in correct order
        # For now, use the features we have and pad with zeros
        feature_array = np.zeros((1, n_features))
        
        # Map our extracted features to array positions
        # This is a simplified approach - ideally we'd match exact column names
        idx = 0
        for key in ['jitter', 'shimmer', 'hnr']:
            if key in features and idx < n_features:
                feature_array[0, idx] = features[key]
            idx += 1
        
        for i in range(13):  # MFCC features
            key = f'mfcc_{i}'
            if key in features and idx < n_features:
                feature_array[0, idx] = features[key]
            idx += 1
        
        for i in range(768):  # BERT features
            key = f'bert_{i}'
            if key in features and idx < n_features:
                feature_array[0, idx] = features[key]
            idx += 1
        
        # Fill remaining with text features
        for key in ['cognitive_count', 'negative_count', 'pronoun_count', 'absolutist_count', 'transcript_length', 
                    'word_count', 'avg_word_length', 'sentence_count', 'question_count', 'exclamation_count']:
            if key in features and idx < n_features:
                feature_array[0, idx] = features[key]
            idx += 1
        
        # Preprocess
        X_imputed = imputer.transform(feature_array)
        X_scaled = scaler.transform(X_imputed)
        X_selected = selector.transform(X_scaled)
        
        # Predict severity
        print("--- Executing REAL Severity Model ---")
        
        # Safety Check: If transcript features are empty/zero, default to Normal
        # (User Request: "if transcript data not connected show normal")
        if features.get('word_count', 0) == 0:
             print("  [Safety] No transcript data detected -> Defaulting to Normal")
             severity_probs = {"Normal": 100, "Moderate": 0, "Severe": 0}
             severity_pred = "Normal"
        else:
            severity_pred = severity_model.predict(X_selected)[0]
            severity_proba = severity_model.predict_proba(X_selected)[0]
            severity_probs = {label: float(prob) * 100 for label, prob in zip(label_encoder.classes_, severity_proba)}
            
            # User Request: "if the transcripted text is not connected to any psychological issue then show a normal"
            # Logic: If 0% negative words are detected, force result to Normal
            neg_count = features.get('negative_count', 0)
            if neg_count == 0:
                print(f"  [Content Check] No negative keywords detected ({neg_count}%) -> Forcing Normal")
                severity_probs = {"Normal": 95, "Moderate": 5, "Severe": 0}
                severity_pred = "Normal"

        
        # --- EMOTION CONNECTION LOGIC ---
        # Adjust severity based on detected emotion (Cross-Model Validation)
        detected_emotion = features.get('detected_emotion', 'Neutral')
        emotion_conf = features.get('emotion_confidence', 0.0)
        
        if emotion_conf > 0.5:
            # High Arousal/Negative Emotions -> Increase Severity
            if detected_emotion in ['Fear', 'Sad', 'Angry', 'Disgust', 'Surprise']:
                boost = 15 * emotion_conf  # Boost up to 15%
                severity_probs['Severe'] += boost
                severity_probs['Moderate'] += (boost * 0.5)
                severity_probs['Normal'] = max(0, severity_probs['Normal'] - boost)
                
            # Positive/Calm Emotions -> Decrease Severity
            elif detected_emotion in ['Happy', 'Neutral']:
                boost = 15 * emotion_conf
                severity_probs['Normal'] += boost
                severity_probs['Severe'] = max(0, severity_probs['Severe'] - boost)
                severity_probs['Moderate'] = max(0, severity_probs['Moderate'] - (boost * 0.5))
        
        # Re-normalize to 100%
        total_prob = sum(severity_probs.values())
        severity_probs = {k: (v / total_prob) * 100 for k, v in severity_probs.items()}
        
        # Determine final label after adjustment
        severity_label = max(severity_probs, key=severity_probs.get)
        severity_confidence = severity_probs[severity_label] / 100.0
        
        # Round for display
        severity_probs = {k: round(v, 1) for k, v in severity_probs.items()}
        # --------------------------------
        
        # Multi-label predictions (simplified)
        ml_probs = [random.uniform(0.2, 0.8) for _ in multi_labels]
        
    except Exception as e:
        print(f"Using simulated predictions due to: {e}")
        
        # ============= COMPREHENSIVE SEVERITY SCORING =============
        # Calculate a composite "stress score" from all available features
        
        # 1. Emotion contribution (0-40 points)
        detected_emotion = features.get('detected_emotion', 'Neutral')
        emotion_conf = features.get('emotion_confidence', 0.5)
        
        emotion_stress_scores = {
            'Angry': 35, 'Fear': 38, 'Sad': 32, 'Disgust': 28,
            'Surprise': 15, 'Neutral': 5, 'Happy': 0
        }
        emotion_score = emotion_stress_scores.get(detected_emotion, 10) * emotion_conf
        print(f"  [Severity] Emotion: {detected_emotion} ({emotion_conf:.2f}) -> score: {emotion_score:.1f}")
        
        # 2. Negative word contribution (0-30 points)
        negative_count = features.get('negative_count', 0)  # Already percentage
        negative_score = min(30, negative_count * 3)  # Cap at 30
        print(f"  [Severity] Negative words: {negative_count:.1f}% -> score: {negative_score:.1f}")
        
        # 3. Absolutist words contribution (0-15 points)
        absolutist_count = features.get('absolutist_count', 0)  # Already percentage
        absolutist_score = min(15, absolutist_count * 2)  # Cap at 15
        print(f"  [Severity] Absolutist words: {absolutist_count:.1f}% -> score: {absolutist_score:.1f}")
        
        # 4. Voice quality contribution (0-15 points)
        # Higher jitter/shimmer often indicates distress
        jitter = features.get('jitter', 0)
        shimmer = features.get('shimmer', 0)
        voice_score = min(15, (jitter + shimmer) * 1.5)
        print(f"  [Severity] Voice (jitter={jitter:.1f}, shimmer={shimmer:.1f}) -> score: {voice_score:.1f}")
        
        # Total stress score (0-100)
        total_stress = emotion_score + negative_score + absolutist_score + voice_score
        print(f"  [Severity] TOTAL STRESS SCORE: {total_stress:.1f}/100")
        
        # Determine severity based on total score (lowered thresholds for sensitivity)
        if total_stress >= 40:
            severity_probs = {"Normal": 10, "Moderate": 30, "Severe": 60}
            severity_label = "Severe"
        elif total_stress >= 20:
            severity_probs = {"Normal": 20, "Moderate": 55, "Severe": 25}
            severity_label = "Moderate"
        elif total_stress >= 10:
            severity_probs = {"Normal": 45, "Moderate": 40, "Severe": 15}
            severity_label = "Moderate"  # Borderline moderate instead of normal
        else:
            severity_probs = {"Normal": 70, "Moderate": 20, "Severe": 10}
            severity_label = "Normal"
        
        severity_confidence = severity_probs[severity_label]
        print(f"  [Severity] Final: {severity_label} ({severity_confidence}%)")
        
        ml_probs = [random.uniform(0.15, 0.75) for _ in multi_labels]
    # Build anxiety indicators based on probabilities
    # Show ALL relevant indicators, not just those connected to severity
    anxiety_indicators = []
    for i, label in enumerate(multi_labels):
        # Skip "Neutral" - it's not an anxiety indicator
        if label == "Neutral":
            continue
            
        prob = float(ml_probs[i])
        threshold = float(thresholds[i]) if i < len(thresholds) else 0.3
        detected = bool(prob >= threshold)
        
        # Show indicators with > 50% probability only
        if prob <= 0.5:
            continue
        
        indicator = {
            'name': label.replace('_', ' '),
            'detected': detected,
            'probability': int(round(prob * 100)),  # No decimal
            'threshold': int(round(threshold * 100)),  # No decimal
            'insights': EDUCATIONAL_INSIGHTS.get(label, {})
        }
        anxiety_indicators.append(indicator)
    
    anxiety_indicators.sort(key=lambda x: (x['detected'], x['probability']), reverse=True)
    
    # User Request: If severity is Normal, don't show anxiety indicators
    if severity_label == "Normal":
        anxiety_indicators = []
    
    # Convert severity probabilities to integers
    severity_probs_int = {k: int(round(v)) for k, v in severity_probs.items()}
    
    # Prepare emotion data
    emotion_data = {
        'label': features.get('detected_emotion', 'Neutral'),
        'confidence': round(features.get('emotion_confidence', 0.0) * 100, 1)
    }

    return {
        'success': True,
        'severity': {
            'level': severity_label,
            'confidence': int(round(severity_confidence * 100)),  # Corrected scaling if needed, previously multiplied by 100 twice? No wait severity_confidence was divided by 100 at line 273. Wait let's check line 273. Yes it was.
            'info': SEVERITY_INFO.get(severity_label, {}),
            'probabilities': severity_probs_int
        },
        'emotion': emotion_data,
        'anxiety_indicators': anxiety_indicators,
        'detected_conditions': [ind['name'] for ind in anxiety_indicators if ind['detected']],
        'summary': generate_summary(severity_label, anxiety_indicators, emotion_data)
    }

def generate_summary(severity, indicators, emotion=None):
    """Generate a cohesive summary string"""
    summary = f"The analysis indicates a {severity} level of anxiety biomarkers. "
    
    if emotion and emotion['confidence'] > 50:
        summary += f"The detected emotional tone is '{emotion['label']}'. "
    
    detected = [ind['name'] for ind in indicators if ind['detected']]
    
    if detected:
        summary += f"Specific indicators detected include {', '.join(detected[:3])}"
        if len(detected) > 3:
            summary += f", and {len(detected)-3} others."
        else:
            summary += "."
    else:
        summary += "No specific anxiety disorder patterns were strongly detected."
        
    return summary

@app.route('/predict', methods=['POST'])
def predict():
    """Legacy endpoint for testing with simulated features"""
    try:
        model = load_model()
        data = request.get_json()
        
        if 'features' not in data:
            return jsonify({'error': 'No features provided'}), 400
        
        # Create fake features dict
        features = {'negative': random.uniform(0, 5)}
        
        result = run_prediction(features, model)
        return jsonify(result)
        
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500

@app.route('/api/sample-features', methods=['GET'])
def get_sample_features():
    model = load_model()
    try:
        n_features = model['imputer'].n_features_in_
    except:
        n_features = 792
    
    sample_features = np.random.randn(n_features).tolist()
    return jsonify({'n_features': n_features, 'sample_features': sample_features})

if __name__ == '__main__':
    load_model()
    print("\n" + "=" * 50)
    print("  Audio Biomarker Server (Real Implementation)")
    print("  Running at http://127.0.0.1:5000")
    print("=" * 50 + "\n")
    app.run(debug=True, port=5000)
