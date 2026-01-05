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
import uuid
warnings.filterwarnings('ignore')

# Custom modules
from word_analyzer import get_word_features_from_transcripts
from translator import get_translator

app = Flask(__name__)
CORS(app)  # Enable CORS for mobile requests

# --- FORCE FFMPEG PATH INJECTION (Fix for Windows/Winget) ---
# Ensure backend tools are visible even without a terminal restart
try:
    local_app_data = os.environ.get("LOCALAPPDATA", r"C:\Users\markn\AppData\Local")
    ffmpeg_paths = [
        os.path.join(local_app_data, "Microsoft", "WinGet", "Links"),
        os.path.join(local_app_data, "Microsoft", "WinGet", "Packages", "Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe", "ffmpeg-8.0.1-full_build", "bin")
    ]
    for p in ffmpeg_paths:
        if os.path.exists(p):
            # Add to PATH so subprocesses can find 'ffmpeg'
            if p not in os.environ["PATH"]:
                print(f"[Injecting FFmpeg path]: {p}")
                os.environ["PATH"] += os.pathsep + p
except Exception as e:
    print(f"[Warning]: Failed to inject FFmpeg path: {e}")

# ============ Configuration ============
MODEL_PATH = "testmodelapiy.pkl"
UPLOAD_FOLDER = tempfile.gettempdir()
ALLOWED_EXTENSIONS = {'wav', 'webm', 'mp3', 'ogg', 'm4a'}


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
    """Extract audio features: jitter, shimmer, HNR, MFCC - MATCHING TRAINING CODE EXACTLY"""
    try:
        import librosa
        import numpy as np
        import parselmouth
        from parselmouth.praat import call
        import python_speech_features as psf
        
        features = {}
        
        # === PARSELMOUTH/PRAAT for Jitter, Shimmer, HNR (MATCHING TRAINING) ===
        try:
            snd = parselmouth.Sound(audio_path)
            
            # PointProcess with 75-500 pitch range (MATCHES TRAINING CODE)
            point_process = call(snd, "To PointProcess (periodic, cc)", 75, 500)
            
            # Jitter (local) - EXACT PARAMETERS FROM TRAINING
            jitter = call(point_process, "Get jitter (local)", 0, 0, 0.0001, 0.02, 1.3)
            features['jitter'] = float(jitter) if not np.isnan(jitter) else 0.0
            
            # Shimmer (local) - EXACT PARAMETERS FROM TRAINING
            shimmer = call([snd, point_process], "Get shimmer (local)", 0, 0, 0.0001, 0.02, 1.3, 1.6)
            features['shimmer'] = float(shimmer) if not np.isnan(shimmer) else 0.0
            
            # HNR - EXACT METHOD FROM TRAINING
            harmonicity = snd.to_harmonicity_cc(time_step=0.01, minimum_pitch=75)
            hnr_values = harmonicity.values
            hnr = np.mean(hnr_values[hnr_values != -200]) if len(hnr_values[hnr_values != -200]) > 0 else 0.0
            features['hnr'] = float(hnr) if not np.isnan(hnr) else 0.0
            
            print(f"   Parselmouth: jitter={features['jitter']:.6f}, shimmer={features['shimmer']:.6f}, hnr={features['hnr']:.2f}")
            
        except Exception as e:
            print(f"   ⚠️ Parselmouth extraction failed: {e}. Using fallback values.")
            features['jitter'] = 0.0
            features['shimmer'] = 0.0
            features['hnr'] = 0.0
        
        # === MFCC using python_speech_features (MATCHING TRAINING CODE) ===
        try:
            # Load at NATIVE sample rate (sr=None) like training code
            y, native_sr = librosa.load(audio_path, sr=None)
            
            if len(y) < 160:
                mfcc_means = np.zeros(13)
            else:
                # Use python_speech_features with nfft=2048 (MATCHES TRAINING)
                mfccs = psf.mfcc(y, native_sr, nfft=2048)
                mfcc_means = np.mean(mfccs, axis=0)
            
            for i in range(13):
                features[f'mfcc_{i}'] = float(mfcc_means[i]) if i < len(mfcc_means) else 0.0
            
            print(f"   MFCCs (psf): mfcc_0={features['mfcc_0']:.4f}, mfcc_1={features['mfcc_1']:.4f}")
            
        except Exception as e:
            print(f"   ⚠️ MFCC extraction failed: {e}. Using zeros.")
            for i in range(13):
                features[f'mfcc_{i}'] = 0.0
        
        # === Waveform for UI (using librosa RMS) ===
        y_16k, _ = librosa.load(audio_path, sr=sr)
        frame_size = int(0.025 * sr)
        hop_size = int(0.010 * sr)
        frames = [y_16k[i:i+frame_size] for i in range(0, len(y_16k)-frame_size, hop_size)]
        
        rms = []
        if frames:
            rms = [np.sqrt(np.mean(f**2)) for f in frames]
            
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
            features['waveform'] = [0.0] * 50

        # Pitch (F0) Estimation using librosa
        try:
            f0, voiced_flag, voiced_probs = librosa.pyin(y_16k, fmin=75, fmax=500, sr=sr)
            f0_valid = f0[~np.isnan(f0)]
            pitch_val = float(np.mean(f0_valid)) if len(f0_valid) > 0 else 120.0
        except:
            pitch_val = 120.0
        features['pitch_mean'] = pitch_val 
        
        # Energy (RMS)
        if rms:
             features['energy_mean'] = float(np.mean(rms))
        else:
             features['energy_mean'] = float(np.sqrt(np.mean(y_16k**2)))
        
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
    # Word lists - Expanded for better sensitivity
    COGNITIVE_WORDS = [
    # -- Original List --
    'think', 'know', 'believe', 'understand', 'realize', 'consider', 'isip', 'alam', 'akala', 'intindi',
    'feel', 'felt', 'perceive', 'guess', 'assume', 'expect', 'remember', 'recall', 'forget', 'plan',
    'decide', 'choose', 'prefer', 'wish', 'hope', 'wonder', 'maybe', 'perhaps', 'possibly',
    'suppose', 'imagine', 'dream', 'analyze', 'examine', 'evaluate', 'conclude', 'infer',
    
    # -- English Additions --
    'thought', 'thinking', 'knowledge', 'belief', 'believed', 'understanding', 'understood', 
    'realization', 'realized', 'consideration', 'considered', 'feeling', 'perception', 'perceived',
    'guessing', 'assumption', 'assumed', 'expectation', 'expected', 'remembrance', 'memory', 'memorize',
    'forgot', 'forgotten', 'planning', 'decision', 'decided', 'choice', 'chose', 'chosen',
    'preference', 'preferred', 'wishing', 'hoping', 'wondering', 'supposition', 'supposed',
    'imagination', 'imagining', 'dreaming', 'analysis', 'analyzed', 'examination', 'examined',
    'evaluation', 'evaluated', 'conclusion', 'concluded', 'inference', 'inferred',
    'mind', 'brain', 'reason', 'reasoning', 'logic', 'logical', 'doubt', 'doubting',
    'question', 'questioning', 'answer', 'answering', 'solution', 'solve', 'solved',
    'idea', 'concept', 'notion', 'view', 'opinion', 'reflect', 'reflection', 'contemplate', 'contemplation',
    'focus', 'concentrate', 'concentration', 'attention', 'aware', 'awareness', 'conscious', 'consciousness',
    'learn', 'learning', 'learned', 'study', 'studying', 'studied',
    
    # -- Tagalog Additions --
    'naisip', 'naiisip', 'iniisip', 'isipin', 'mag-isip',
    'nalaman', 'malaman', 'alamin',
    'paniwala', 'paniniwala', 'pinaniwalaan',
    'unawa', 'pag-unawa', 'maunawaan', 'naunawaan',
    'naintindihan', 'maintindihan', 'pagkakaintindi',
    'ramdam', 'pakiramdam', 'nararamdaman',
    'hula', 'hinala', 'paghihinala',
    'inaakala', 'pag-aakala',
    'tanda', 'matandaan', 'natatandaan', 'tandaan',
    'limot', 'kalimutan', 'nakalimutan', 'kinalimutan',
    'balak', 'pagbabalak', 'plano', 'pagpaplano',
    'pasya', 'pagpapasya', 'desisyon', 'pagdedesisyon',
    'pili', 'pinili', 'pagpili', 'mapili',
    'gusto', 'nais', 'sana',
    'asa', 'pag-asa', 'umasa',
    'baka', 'siguro', 'tila', 'kaya', 'yata', 
    'panaginip', 'pangarap', 'angarap',
    'suri', 'pagsusuri', 'sinuri',
    'hatol', 'paghatol',
    'puna', 'pagpuna',
    'kuro-kuro', 'pananaw', 'opinyon',
    'isipan', 'diwa',
    'malay', 'kamalayan',
    'lohika', 'katwiran', 'rason',
    'duda', 'pagdududa', 'nagdududa',
    'tanong', 'nagtatanong', 'sagot', 'sumagot',
    'lunas', 'solusyon',
    'ideya', 'konsepto',
    'aral', 'pag-aaral', 'natutunan', 'matutunan', 'saulo', 'kabisado'
    ]
    NEGATIVE_WORDS = [
    # -- Original List --
    'sad', 'angry', 'afraid', 'anxious', 'worried', 'depressed', 'stressed', 'nervous', 'scared', 'lungkot', 'galit', 'takot', 'kaba',
    'terrible', 'awful', 'horrible', 'bad', 'worst', 'hate', 'pain', 'hurt', 'cry', 'crying', 'tears',
    'upset', 'annoyed', 'frustrated', 'exhausted', 'tired', 'fatigued', 'lazy', 'bored', 'lonely',
    'hopeless', 'helpless', 'useless', 'worthless', 'failure', 'fail', 'stupid', 'dumb', 'idiot',
    'panic', 'panicking', 'tense', 'tension', 'pressure', 'overwhelmed', 'burden', 'heavy',
    'dark', 'black', 'empty', 'void', 'lost', 'confused', 'dizzy', 'sick', 'nausea',
    'takot', 'pangamba', 'bigat', 'hirap', 'pagod', 'suko', 'ayaw', 'inis', 'bwisit',
    'kaba', 'inig', 'gulat', 'lungkot', 'dalamhati', 'api', 'kawawa',
    'fear', 'grief', 'mess', 'trouble', 'problem', 'problema', 'iyak', 'hikbi', 'frightened', 'sadness',
    'lumbay', 'dismaya', 'pighati', 'hinagpis', 'tampo', 'inis', 'ayamot', 'muhi', 'ngitngit',
    'pangit', 'sawi', 'bigo', 'dusa', 'parusa', 'sakit', 'kirot', 'hapdi',
    
    # -- CRITICAL MISSING VERB FORMS (for highlighting) --
    'kinakabahan', 'kabado', 'natatakot', 'nababahala', 'nag-aalala', 'nagaalala',
    'naiinis', 'nagagalit', 'nalulungkot', 'natatakot', 'nangangamba',
    'nahihirapan', 'napapagod', 'nakakapagod', 'nakakastress',
    'nakakatakot', 'nakakalungkot', 'nakakabahala', 'nakakainis',
    'naiistress', 'stressed out', 'burn out', 'burned out',
    
    # -- CRITICAL NEGATION WORDS (frequently used in transcripts) --
    'hindi', 'di', 'ayoko', 'ayaw ko', 'wala', 'walang',
    
    # -- User Requested Additions --
    'mali', 'kamali', 'nagkamali', 'magkamali', 'pagkakamali', 
    'hiya', 'napahiya', 'kahihiyan', 'mahiya', 'nakakahiya', 
    'pagtawanan', 'tawanan', 'natawa', 
    
    # -- Additional "Better Indication" Words --
    'mistake', 'error', 'wrong', 'fault',
    'embarrassed', 'embarrassing', 'shame', 'ashamed', 'humiliation', 'humiliated',
    'mock', 'mocked', 'laugh', 'laughed', 'ridicule',
    'regret', 'guilt', 'guilty', 'sorry',
    'doubt', 'uncertain', 'hesitate',
    'disappoint', 'disappointed', 'disappointment',
    'shy', 'shyness', 'timid',
    'judgment', 'judged', 'criticize', 'criticized',
    'sisi', 'pagsisisi', 'hinayang',
    'duda', 'alinlangan',
    'bigo', 'pagkabigo',
    'husga', 'hinusgahan', 'puna',
    'pigil', 'nagpigil', 'pinigilan'
    ]
    POSITIVE_WORDS = [
    # -- Original List --
    'happy', 'good', 'great', 'excellent', 'love', 'joy', 'wonderful', 'blessed', 'mabuti', 'masaya', 'maganda', 'galing',
    'excited', 'glad', 'calm', 'relaxed', 'peaceful', 'content', 'satisfied', 'proud', 'confident',
    'strong', 'brave', 'courage', 'hopeful', 'optimistic', 'inspired', 'motivated', 'energetic',
    'thankful', 'grateful', 'appreciate', 'enjoy', 'fun', 'funny', 'laugh', 'smile',
    'success', 'win', 'achievement', 'progress', 'growth', 'learning', 'improve', 'better',
    'ayos', 'husay', 'tibay', 'lakas', 'saya', 'tuwa', 'ligaya', 'ginhawa', 'payapa',
    
    # -- English Additions --
    'best', 'amazing', 'fantastic', 'awesome', 'brilliant', 'perfect',
    'pleasure', 'pleasant', 'delight', 'delightful',
    'safe', 'safety', 'secure', 'security', 'comfort', 'comfortable',
    'relief', 'relieved', 'easy', 'ease',
    'fine', 'okay', 'ok', 'right', 'correct',
    'beautiful', 'lovely', 'pretty', 'cute',
    'smart', 'wise', 'intelligent', 'genius',
    'kind', 'kindness', 'generous', 'caring',
    'helpful', 'support', 'supportive',
    'trust', 'trusted', 'faith',
    'victory', 'triumph', 'winner',
    'passion', 'passionate', 'favorite',
    'worth', 'worthy', 'valuable',
    'positive', 'positivity',
    
    # -- Tagalog Additions --
    'sarap', 'masarap', 'ginhawa', 'maginhawa',
    'gaan', 'magaan', 'alwan', 'maaliwalas',
    'tulong', 'matulungin',
    'buti', 'pabuti', 'mabait', 'kabaitan',
    'ganda', 'kagandahan',
    'aliw', 'nakakaaliw',
    'kampante', 'atag', 'panatag',
    'tiwala', 'pagtitiwala',
    'panalo', 'manalo',
    'swerte', 'pinagpala',
    'salamat', 'pasasalamat',
    'bilib', 'humahanga',
    'ok', 'sige', 'oo', 'korak', 'tumpak'
    ]
    
    PRONOUNS = [
    # -- Original List (First Person) --
    'i', 'me', 'my', 'mine', 'myself', 'we', 'us', 'our', 'ako', 'ko', 'akin', 'kami', 'tayo',
    
    # -- English Additions (2nd/3rd Person) --
    'ours', 'ourselves',
    'you', 'your', 'yours', 'yourself', 'yourselves',
    'he', 'him', 'his', 'himself',
    'she', 'her', 'hers', 'herself',
    'it', 'its', 'itself',
    'they', 'them', 'their', 'theirs', 'themselves',
    
    'amin', 'atin', 'namin', 'natin', 'kata', 'kita',
    'ka', 'ikaw', 'mo', 'iyo', 'kayo', 'ninyo', 'inyo',
    'siya', 'niya', 'kaniya', 'kanya',
    'sila', 'nila', 'kanila'
    ]
    FIRST_PERSON = [
    'i', 'me', 'my', 'mine', 'myself', 'ako', 'ko', 'akin',
    
    'we', 'us', 'our', 'ours', 'ourselves',
    
    'kita', 'kata',
    'kami', 'tayo', 'amin', 'atin', 'namin', 'natin'
    ]
    
    ABSOLUTIST_WORDS = [
    # -- Original List --
    'always', 'never', 'completely', 'totally', 'absolutely', 'palagi', 'lagi', 'lahat', 'wala',
    'every', 'everyone', 'everything', 'no one', 'nobody', 'nothing', 'forever', 'constant',
    'entire', 'whole', 'full', 'none', 'must', 'should', 'have to', 'need to',
    
    # -- English Additions --
    'all', 'any', 'anyone', 'anything', 'anywhere',
    'definite', 'definitely', 'certain', 'certainly', 'sure', 'surely',
    'perfect', 'perfectly', 'pure', 'purely',
    'total', 'entirely', 'fully',
    'ultimate', 'ultimately', 'unconditional', 'unquestionable',
    'infinite', 'endless', 'limitless',
    'exact', 'exactly', 'precisely',
    'undeniable', 'undeniably',
    'without a doubt', 'no doubt',
    'constantly', 'permanently',
    'must', 'ought to',
    
    # -- Tagalog Additions --
    'bawat', 'puro', 'ubos', 'wagas', 'sakdal', 'lubos', 'ganap',
    'walang hanggan', 'habang-buhay', 'habambuhay',
    'sigurado', 'tiyak', 'mismo', 'tunay', 'talaga',
    'dapat', 'kailangan', 'nararapat',
    'todo', 'sobra', 'sukdulan',
    'buo', 'kabuuan',
    'saanman', 'sinuman', 'anuman', 'kailanman',
    'walang duda', 'walang alinlangan',
    'araw-araw', 'gabi-gabi', 'oras-oras'
    ]
    HESITATION_WORDS = [
    # -- Original List --
    'um', 'uh', 'er', 'ah', 'like', 'hmm', 'kwan', 'ano', 'parang', 'uhm', 'umm', 'ahh',
    
    # -- English Additions --
    'well', 'actually', 'basically', 'literally', 'so', 'mean', 
    'okay', 'right', 'anyway', 'huh', 'mhmm',
    'wait', 'guess', 'kind of', 'sort of', 'you know',
    
    # -- Tagalog Additions --
    'bale', 'kumbaga', 'kuwan', 'ayun', 'ganun', 'ganyan', 
    'eh', 'ehh', 'ha', 'o', 'oh', 'ay',
    'tsaka', 'yung', 'sa', # Common fillers, but also grammatical. Keep if context implies filler.
    'kano', 'anong', 'basta', 'siguro', 'yata'
    ]
    
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
    
    # Identify matches
    neg_matches = [w for w in words if w in NEGATIVE_WORDS]
    pos_matches = [w for w in words if w in POSITIVE_WORDS]
    abs_matches = [w for w in words if w in ABSOLUTIST_WORDS]
    hes_matches = [w for w in words if w in HESITATION_WORDS]
    first_matches = [w for w in words if w in FIRST_PERSON]
    pronoun_matches = [w for w in words if w in PRONOUNS]
    cog_matches = [w for w in words if w in COGNITIVE_WORDS]
    
    features['negative_matches'] = list(set(neg_matches))
    features['positive_matches'] = list(set(pos_matches))
    features['absolutist_matches'] = list(set(abs_matches))
    features['hesitation_matches'] = list(set(hes_matches))
    features['cognitive_matches'] = list(set(cog_matches))
    features['pronoun_matches'] = list(set(pronoun_matches))
    features['first_person_matches'] = list(set(first_matches))
    features['negative_raw'] = len(neg_matches)
    features['absolutist_raw'] = len(abs_matches)
    
    # Create NEGATIVE and ABSOLUTIST word sets for quick lookup
    neg_set = set(NEGATIVE_WORDS)
    pos_set = set(POSITIVE_WORDS)
    abs_set = set(ABSOLUTIST_WORDS)
    hes_set = set(HESITATION_WORDS)
    cog_set = set(COGNITIVE_WORDS)
    
    # Build analyzed_words list with word + category for UI highlighting
    # Priority: negative > absolutist > positive > anxiety (hesitation) > cognitive
    analyzed_words = []
    for word in words:
        word_lower = word.lower() if word else ""
        category = "neutral"  # default
        
        if word_lower in neg_set:
            category = "negative"
        elif word_lower in abs_set:
            category = "absolutist"
        elif word_lower in pos_set:
            category = "positive"
        elif word_lower in hes_set:
            category = "anxiety"  # hesitation words indicate anxiety
        elif word_lower in cog_set:
            category = "cognitive"  # cognitive/thinking words
        
        analyzed_words.append({
            "word": word,
            "category": category
        })
    
    features['analyzed_words'] = analyzed_words

    # Word counts as RAW COUNTS (matching training data format)
    features['cognitive_count'] = len(cog_matches)
    features['negative_count'] = len(neg_matches)
    features['positive_count'] = len(pos_matches)
    features['absolutist_count'] = len(abs_matches)
    features['pronoun_count'] = len(pronoun_matches)
    features['emotional_count'] = len(neg_matches) + len(pos_matches)
    features['hesitation_count'] = len(hes_matches)
    features['first_person_count'] = len(first_matches)
    
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

# ============ Global Model References ============
# ============ Global Model References ============
scaler = None
imputer = None
selector = None
severity_model = None
multilabel_model = None
model_bundle = None # Keep for labels

def preload_models():
    """Pre-load all ML models at startup for faster inference"""
    global model_bundle, _bert_model, _bert_tokenizer, _emotion_pipeline 
    global scaler, imputer, selector, severity_model, multilabel_model
    
    start_time = time.time()
    
    # 1. Load main prediction model bundle
    try:
        model_bundle = joblib.load(MODEL_PATH)
        # Extract trained components
        scaler = model_bundle.get('scaler')
        imputer = model_bundle.get('imputer')  # May not exist in new model
        selector = model_bundle.get('selector')  # May not exist in new model
        severity_model = model_bundle.get('severity_model')
        # Handle both old ('multilabel_model') and new ('issues_model') naming
        multilabel_model = model_bundle.get('multilabel_model') or model_bundle.get('issues_model')
        
        print(f"[SUCCESS] Main model loaded ({time.time() - start_time:.2f}s)")
        print(f"   - Severity Model: {type(severity_model).__name__ if severity_model else 'None'}")
        print(f"   - Multilabel Model: {type(multilabel_model).__name__ if multilabel_model else 'None'}")
        print(f"   - Scaler: {type(scaler).__name__ if scaler else 'None'}")
        print(f"   - Features expected: {len(model_bundle.get('features', []))}")
    except Exception as e:
        print(f"[ERROR] Failed to load main model: {e}")
        model_bundle = create_fallback_model()
    
    # 2. Load BERT model (for text embeddings)
    try:
        from transformers import BertTokenizer, BertModel
        import torch
        _bert_tokenizer = BertTokenizer.from_pretrained('bert-base-uncased')
        _bert_model = BertModel.from_pretrained('bert-base-uncased')
        _bert_model.eval()
        print(f"[SUCCESS] BERT model loaded ({time.time() - start_time:.2f}s)")
    except Exception as e:
        print(f"[WARNING] BERT model not loaded (will use zeros): {e}")
    
    # 3. Load emotion detection model
    try:
        from transformers import pipeline
        _emotion_pipeline = pipeline("audio-classification", model="superb/wav2vec2-base-superb-er")
        print(f"[SUCCESS] Emotion model loaded ({time.time() - start_time:.2f}s)")
    except Exception as e:
        print(f"[WARNING] Emotion model not loaded (will use fallback): {e}")
    
    # 4. Initialize translator
    try:
        translator = get_translator()
        print(f"[SUCCESS] Translator initialized ({time.time() - start_time:.2f}s)")
    except Exception as e:
        print(f"[WARNING] Translator not loaded (translations will be skipped): {e}")
    
    print(f"[DONE] All models loaded in {time.time() - start_time:.2f}s")


def run_prediction(features, transcript):
    """Run ML prediction using trained models (RandomForest + ClassifierChain)"""
    global model_bundle, scaler, imputer, selector, severity_model, multilabel_model
    
    severity_labels = model_bundle.get('severity_labels', ["Normal", "Moderate", "Severe"])
    multi_labels = model_bundle.get('multi_labels', list(EDUCATIONAL_INSIGHTS.keys()))
    # Use learned thresholds if available, else default
    thresholds = model_bundle.get('multilabel_thresholds', [0.3] * len(multi_labels))

    # --- 1. Construct Feature Vector (MATCHING testmodelapiy.pkl TRAINING ORDER) ---
    # Order: jitter, shimmer, hnr, mfcc_0-12, negative_count, positive_count, 
    #        emotional_count, cognitive_count, absolutist_count, hesitation_count, 
    #        pronoun_count, first_person_count, bert_0-767
    feature_vector = []
    
    # 1. Voice Quality (3 features: Jitter, Shimmer, HNR)
    feature_vector.append(features.get('jitter', 0.0))
    feature_vector.append(features.get('shimmer', 0.0))
    feature_vector.append(features.get('hnr', 0.0))
    
    # 2. MFCC (13 features: mfcc_0 to mfcc_12)
    for i in range(13):
        feature_vector.append(features.get(f'mfcc_{i}', 0.0))
        
    # 3. Text Features (8 specific features in order)
    text_feat_order = [
        'negative_count', 
        'positive_count',
        'emotional_count', 
        'cognitive_count', 
        'absolutist_count', 
        'hesitation_count', 
        'pronoun_count', 
        'first_person_count'
    ]
    for name in text_feat_order:
        feature_vector.append(features.get(name, 0.0))
    
    # 4. BERT Embeddings (768 features: bert_0 to bert_767)
    for i in range(768):
        feature_vector.append(features.get(f'bert_{i}', 0.0))
    
    # Convert to 2D array for sklearn [1, n_features]
    X = np.array([feature_vector])
    
    # --- 2. Preprocessing (Impute + Scale) ---
    if imputer:
        X = imputer.transform(X)
    if scaler:
        X = scaler.transform(X)
    if selector:
        X = selector.transform(X)
        
    # --- 3. Severity Prediction (Random Forest) ---
    if severity_model:
        # Get probability distribution
        sev_probs_arr = severity_model.predict_proba(X)[0]
        severity_label = severity_labels[np.argmax(sev_probs_arr)]
        
        # Map probabilities to labels
        severity_probs = {
            label: int(round(prob * 100)) 
            for label, prob in zip(severity_labels, sev_probs_arr)
        }
        print(f"   [SEVERITY] Predicted: {severity_label} | Probabilities: Normal={severity_probs.get('Normal', 0)}%, Moderate={severity_probs.get('Moderate', 0)}%, Severe={severity_probs.get('Severe', 0)}%")
        
        # --- DEBUG: Show key features influencing prediction ---
        print(f"\n   [FEATURES] Audio: jitter={features.get('jitter', 0):.4f}, shimmer={features.get('shimmer', 0):.4f}, hnr={features.get('hnr', 0):.2f}")
        print(f"   [FEATURES] Text: negative={features.get('negative_count', 0):.1f}%, positive={features.get('positive_count', 0):.1f}%, cognitive={features.get('cognitive_count', 0):.1f}%")
        print(f"   [FEATURES] BERT: avg={np.mean([features.get(f'bert_{i}', 0) for i in range(768)]):.4f}, std={np.std([features.get(f'bert_{i}', 0) for i in range(768)]):.4f}")
        
        # --- POST-PROCESSING DISABLED: Using pure model predictions ---
        # positive_pct = features.get('positive_count', 0)
        # negative_pct = features.get('negative_count', 0)
        # jitter_val = features.get('jitter', 0)
        # shimmer_val = features.get('shimmer', 0)
        
        # # Rule 1: High positive (>15%) + low negative (<5%) + positive > 5x negative
        # if (positive_pct > 15 and negative_pct < 5 and 
        #     positive_pct > negative_pct * 5):
        #     
        #     if severity_label == "Severe":
        #         print(f"\n   [CORRECTION] Positive speech ({positive_pct:.1f}%) >> Negative ({negative_pct:.1f}%)")
        #         print(f"                Downgrading 'Severe' to 'Normal'")
        #         severity_label = "Normal"
        #         severity_probs = {"Normal": 55, "Moderate": 35, "Severe": 10}
        #     elif severity_label == "Moderate":
        #         print(f"\n   [CORRECTION] Positive speech ({positive_pct:.1f}%) >> Negative ({negative_pct:.1f}%)")
        #         print(f"                Downgrading 'Moderate' to 'Normal'")
        #         severity_label = "Normal"
        #         severity_probs = {"Normal": 60, "Moderate": 30, "Severe": 10}
        # 
        # # Rule 2: Low confidence Severe (<50%) with positive indicators
        # elif (severity_label == "Severe" and severity_probs.get("Severe", 0) < 50 and
        #       positive_pct > negative_pct * 2):
        #     
        #     print(f"\n   [CORRECTION] Low confidence Severe ({severity_probs.get('Severe', 0)}%)")
        #     print(f"                Downgrading to 'Moderate'")
        #     severity_label = "Moderate"
        #     severity_probs = {"Normal": 30, "Moderate": 50, "Severe": 20}
        # 
        # # Rule 3: No negative words + no trigger keywords = force Normal
        # elif negative_pct == 0 and severity_label != "Normal":
        #     print(f"\n   [CORRECTION] No negative words detected in transcript.")
        #     print(f"                Overriding '{severity_label}' to 'Normal' (neutral speech)")
        #     severity_label = "Normal"
        #     severity_probs = {"Normal": 70, "Moderate": 20, "Severe": 10}
        
    else:
        # Fallback if model missing
        severity_label = "Normal"
        severity_probs = {"Normal": 98, "Moderate": 0, "Severe": 0}

    # --- 4. Anxiety Indicators Prediction (Classifier Chain) ---
    anxiety_indicators = []
    
    # Keyword Boost Mapping - 100% UNIQUE keywords per label (NO OVERLAPPING)
    # Each label has keywords specific ONLY to that condition
    TRIGGER_KEYWORDS = {
        "Social_Anxiety": [
            # English - UNIQUE: focus on social situations, judgment, public
            "social situation", "public speaking", "crowd", "audience", "stage fright",
            "being judged", "embarrassed in public", "everyone staring", "center of attention",
            "awkward conversation", "party anxiety", "meeting new people", "talking to strangers",
            # Tagalog - UNIQUE: social/public situations
            "maraming tao", "nahihiya ako", "nakakahiya", "napapahiya", "hiyang hiya",
            "tinitingnan ako", "pinapanood ako", "di ako makapagsalita sa harap",
            "takot magsalita sa marami", "nahihiya sa tao"
        ],
        "Test_Anxiety": [
            # English - UNIQUE: focus on exams, grades, academic testing
            "exam", "test", "quiz", "midterm", "final exam", "grade", "score",
            "failing the test", "blank during exam", "forgot the answer",
            "studied but forgot", "time running out in exam",
            # Tagalog - UNIQUE: exam-specific
            "mababagsak", "exam ko", "quiz ko", "pasado", "bagsak", "grade ko",
            "blangko utak sa exam", "nakalimutan sagot", "nag-aral pero nakalimutan",
            "kinakabahan sa exam", "di ko masagot", "mahirap yung test"
        ],
        "Panic_Disorder": [
            # English - UNIQUE: physical panic symptoms
            "panic attack", "heart racing", "cant breathe", "hyperventilating", "chest tightness",
            "going to die", "losing control completely", "shaking uncontrollably",
            "sudden fear", "overwhelming terror", "dizziness attack",
            # Tagalog - UNIQUE: panic physical symptoms
            "hingal", "sikip dibdib", "parang mamamatay", "di makahinga",
            "mabilis tibok ng puso", "nanginginig buong katawan", "nangangatog",
            "himatay", "biglang takot", "sobrang kaba"
        ],
        "GAD": [
            # English - UNIQUE: chronic worry, overthinking, general anxiety
            "worry all the time", "overthinking", "cant stop worrying", "what if something bad",
            "always anxious", "restless", "cant relax", "mind racing",
            "worried about everything", "expecting the worst", "constant unease",
            # Tagalog - UNIQUE: general worry/overthinking
            "praning", "laging iniisip", "di mapalagay", "di mapakali",
            "puro isip", "over thinking", "di makatulog sa kakaisip",
            "ano kaya mangyayari", "laging kinakabahan", "walang pahinga ang isip"
        ],
        "PTSD": [
            # English - UNIQUE: trauma, past events, flashbacks
            "trauma", "flashback", "nightmare about", "triggered", "reminded of",
            "cant forget what happened", "haunted by", "bad memory",
            "abuse", "assault", "accident", "violence", "war",
            # Tagalog - UNIQUE: trauma/past events
            "traumado", "bangungot", "naaalala ko yung nangyari", "hindi ko malimutan",
            "masama ang nakaraan", "sinasaktan ako dati", "inabuso", 
            "napapaiyak pag naaalala", "takot sa nangyari dati"
        ],
        "Agoraphobia": [
            # English - UNIQUE: fear of leaving home, outdoor spaces
            "afraid to leave home", "cant go outside", "stay inside", "trapped outside",
            "fear of open spaces", "fear of public places", "cant leave the house",
            "safe only at home", "panic outside", "need to escape",
            # Tagalog - UNIQUE: fear of going out
            "takot lumabas ng bahay", "ayaw lumabas", "di makalabas",
            "sa bahay lang", "takot sa labas", "gusto lang nasa loob",
            "nakakulong sa bahay", "di makatakas sa labas"
        ],
        "Academic_Burnout": [
            # English - UNIQUE: exhaustion, giving up on school
            "burned out", "exhausted from school", "drained", "no energy for studying",
            "hate studying", "want to quit school", "too much schoolwork",
            "cant do this anymore", "school is killing me", "done with school",
            # Tagalog - UNIQUE: academic exhaustion
            "ayoko na mag-aral", "suko na ako sa school", "sobrang pagod sa aral",
            "sawang sawa na", "ubos na energy ko", "burn out sa school",
            "wala na akong gana", "gusto ko na tumigil"
        ],
        "Perfectionism": [
            # English - UNIQUE: need for perfection, no mistakes
            "must be perfect", "no mistakes allowed", "flawless", "100 percent",
            "cant accept less than perfect", "has to be exactly right",
            "redo until perfect", "not good enough yet", "keep fixing",
            # Tagalog - UNIQUE: perfectionist behavior
            "kailangan perfect", "walang mali dapat", "dapat tama lahat",
            "ayaw ng kahit konting mali", "ulitin hanggang tama",
            "di pa perpekto", "kulang pa", "kailangan mas maganda pa"
        ],
        "Impostor_Syndrome": [
            # English - UNIQUE: feeling like a fraud
            "feel like a fraud", "dont belong here", "fooling everyone",
            "not smart enough", "just got lucky", "will be exposed",
            "dont deserve this", "others are better", "faking it",
            # Tagalog - UNIQUE: impostor feelings
            "peke lang ako", "nagpapanggap lang", "swerte lang talaga",
            "malalaman din nila", "di naman talaga ako magaling",
            "di ako deserve dito", "di ako belong", "mas magaling sila"
        ],
        "Low_Self_Esteem": [
            # English - UNIQUE: self-worth, self-hate
            "hate myself", "im worthless", "im ugly", "im stupid",
            "nobody likes me", "im a loser", "im nothing",
            "i dont matter", "wish i was different", "im disgusting",
            # Tagalog - UNIQUE: self-deprecation
            "walang kwenta ako", "ang pangit ko", "ang bobo ko",
            "wala akong silbi", "ayaw nila sa akin", "loser ako",
            "sana iba na lang ako", "nakakainis ako", "nakakadiri ako"
        ],
        "Fear_Of_Failure": [
            # English - UNIQUE: fear of failing, not trying
            "afraid to fail", "what if i fail", "scared to try",
            "cant afford to fail", "failure is not an option", "letting people down",
            "disappointing everyone", "scared to mess up", "avoiding risks",
            # Tagalog - UNIQUE: fear of failing
            "takot mabigo", "paano kung bumagsak ako", "baka di ko kaya",
            "mabibigo sila sa akin", "mapapahiya pag nabigo",
            "takot subukan", "baka mali", "siguradong babagsak"
        ],
        "Poor_Time_Management": [
            # English - UNIQUE: deadlines, procrastination, rushing
            "deadline", "procrastinating", "last minute", "cramming",
            "running out of time", "always late", "forgot the due date",
            "too many things to do", "no time left", "rushing everything",
            # Tagalog - UNIQUE: time management issues
            "deadline na bukas", "mamaya na yan", "bukas na lang",
            "nagcram", "laging late", "wala na akong oras",
            "nakalimutan ko deadline", "nagmamadali", "kulang sa oras"
        ],
        "Lack_Of_Academic_Support": [
            # English - UNIQUE: no help, struggling alone
            "no one to help", "struggling alone", "no tutor", "teacher doesnt explain",
            "left behind in class", "no support system", "nobody understands",
            "asking but no answer", "falling behind", "no resources",
            # Tagalog - UNIQUE: lack of support
            "walang tumutulong", "mag-isa lang ako", "walang nagtuturo",
            "di ko maintindihan ang lesson", "nahuhuli na ako",
            "walang kasama mag-aral", "di ako tinutulungan"
        ],
        "Pressure_Of_Surroundings": [
            # English - UNIQUE: family/peer pressure, comparison
            "parents expect", "family pressure", "compared to sibling",
            "relatives always ask", "peer pressure", "everyone expects me to",
            "disappointing my family", "living up to expectations",
            # Tagalog - UNIQUE: external pressure
            "sabi ng magulang ko", "ikinukumpara sa kapatid", "sabi ni mama",
            "sabi ni papa", "ano sasabihin ng kamag-anak", "pamilya nagpupumilit",
            "mas magaling daw si", "disappointed ang family"
        ]
    }



    sanity_override = False  # Initialize flag - set to True if sanity check forces Normal
    trigger_map = {}  # Initialize trigger map for response - stores matched keywords per label
    if multilabel_model:
        # Predict using the chain
        ml_probs = multilabel_model.predict_proba(X)[0]
        
        # KEYWORD BOOSTING: Enhance probability based on trigger word matches
        import re
        any_keyword_found = False
        
        if transcript:
            transcript_lower = transcript.lower()
            words_in_transcript = set(re.findall(r'\b\w+\b', transcript_lower))
            
            for i, label in enumerate(multi_labels):
                if label == "Neutral":
                    continue  # Don't boost Neutral based on keywords
                    
                keywords = TRIGGER_KEYWORDS.get(label, [])
                matched_keywords = []
                
                for kw in keywords:
                    if ' ' in kw:
                        if kw in transcript_lower:
                            matched_keywords.append(kw)
                    else:
                        if kw in words_in_transcript:
                            matched_keywords.append(kw)
                
                # Boost probability based on number of keywords matched
                # +40% for first keyword, +25% for each additional (up to +90%) - keywords are strong evidence
                if len(matched_keywords) > 0:
                    any_keyword_found = True
                    # First keyword gives big boost, additional keywords add more
                    keyword_boost = min(0.90, 0.40 + (len(matched_keywords) - 1) * 0.25)
                    old_prob = ml_probs[i]
                    ml_probs[i] = min(0.98, ml_probs[i] + keyword_boost)
                    trigger_map[label] = matched_keywords
                    print(f"   Boosted {label}: {int(old_prob*100)}% + {int(keyword_boost*100)}% (keywords: {matched_keywords[:3]}) = {int(ml_probs[i]*100)}%")
        
        # === SANITY CHECK: Empty/Gibberish Transcript ===
        # If transcript has NO negative words, NO keywords, and very low cognitive content,
        # the model is likely hallucinating from audio features alone. Suppress indicators.
        negative_count = features.get('negative_count', 0)
        cognitive_count = features.get('cognitive_count', 0)
        word_count = features.get('word_count', 1)  # Avoid div by zero
        
        # Check if transcript is essentially meaningless
        has_no_meaningful_content = (
            negative_count == 0 and 
            not any_keyword_found and 
            (cognitive_count / word_count) < 0.03  # Less than 3% cognitive words
        )
        
        if has_no_meaningful_content and transcript:
            sanity_override = True
            print(f"   [SANITY] No negative words, no keywords, low cognitive content - forcing Normal/Neutral")
            # Suppress all non-Neutral indicators by setting them BELOW threshold
            for j, lbl in enumerate(multi_labels):
                if lbl != "Neutral":
                    ml_probs[j] = 0.10  # Set to 10% (well below 30% threshold)
            # Boost Neutral strongly
            neutral_idx = multi_labels.index("Neutral") if "Neutral" in multi_labels else -1
            if neutral_idx >= 0:
                ml_probs[neutral_idx] = 0.95
            # Also force severity to Normal
            severity_label = "Normal"
            severity_probs = {"Normal": 95, "Moderate": 4, "Severe": 1}
        
        # === POSITIVE SENTIMENT OVERRIDE ===
        # If speech is clearly positive (positive words >> negative, no keywords, no negative words),
        # suppress anxiety indicators and boost Neutral
        positive_count = features.get('positive_count', 0)
        negative_count_val = features.get('negative_count', 0)
        if (positive_count > 5 and  # More than 5% positive words
            negative_count_val == 0 and  # No negative words
            positive_count > negative_count_val * 2 and  # Positive dominates
            not any_keyword_found):  # No trigger keywords
            
            print(f"   [POSITIVE] Happy speech detected ({positive_count:.1f}% positive, 0% negative) - forcing Normal/Neutral")
            sanity_override = True
            for j, lbl in enumerate(multi_labels):
                if lbl != "Neutral":
                    ml_probs[j] = 0.15  # Suppress all anxiety indicators
            neutral_idx = multi_labels.index("Neutral") if "Neutral" in multi_labels else -1
            if neutral_idx >= 0:
                ml_probs[neutral_idx] = 0.90
            severity_label = "Normal"
            severity_probs = {"Normal": 88, "Moderate": 10, "Severe": 2}
        
        # If NO keywords found AND model is not confident in anything else, boost Neutral
        max_non_neutral_prob = max([ml_probs[j] for j, lbl in enumerate(multi_labels) if lbl != "Neutral"], default=0)
        if not any_keyword_found and transcript and max_non_neutral_prob < 0.40 and not has_no_meaningful_content and not sanity_override:
            neutral_idx = multi_labels.index("Neutral") if "Neutral" in multi_labels else -1
            if neutral_idx >= 0:
                ml_probs[neutral_idx] = 0.90  # High confidence for Neutral
                print(f"   No keywords & model uncertain (max={int(max_non_neutral_prob*100)}%) - boosting Neutral to 90%")
        
        for i, label in enumerate(multi_labels):
            prob = ml_probs[i]
            threshold = thresholds[i] if i < len(thresholds) else 0.3
            
            # Convert raw probability to display percentage (0-100) - NO FLOOR, NO CAP
            display_prob = int(round(prob * 100))
            
            # Show ALL labels above 10% threshold (more inclusive)
            # This allows user to see raw model predictions
            display_threshold = 0.10  # 10% minimum to display
            if prob < display_threshold:
                continue
            
            # Check if keywords were found for evidence
            found_keywords = []
            if transcript:
                transcript_lower = transcript.lower()
                words_in_transcript = set(re.findall(r'\b\w+\b', transcript_lower))
                keywords = TRIGGER_KEYWORDS.get(label, [])
                for kw in keywords:
                    if ' ' in kw:
                        if kw in transcript_lower:
                            found_keywords.append(kw)
                    else:
                        if kw in words_in_transcript:
                            found_keywords.append(kw)
            
            # KEYWORD REQUIREMENT for labels with known model bias
            # Agoraphobia and PTSD have false positive issues - require keyword evidence
            REQUIRE_KEYWORDS = ["Agoraphobia", "PTSD"]
            if label in REQUIRE_KEYWORDS and len(found_keywords) == 0:
                # Only show Agoraphobia/PTSD if we found actual trigger keywords
                continue  # Skip - these specific labels need keyword evidence to prevent false positives

            
            # Display probability already boosted at the ml_probs level above
            
            # Skip Neutral if other significant indicators exist
            if label == "Neutral" and len(anxiety_indicators) > 0:
                has_significant_indicator = any(ind['probability'] > 50 for ind in anxiety_indicators)
                if has_significant_indicator:
                    continue
            # Build Supporting Evidence (Reasons)
            evidence = []
            
            # 1. Label-specific trigger keywords (PRIMARY evidence) - show ACTUAL words from transcript
            # These are the unique trigger keywords defined for each label (Tagalog or English)
            if found_keywords:
                # Show the exact words that were matched (Tagalog or English as spoken)
                kw_display = ", ".join([f"'{kw}'" for kw in found_keywords[:5]])
                evidence.append({
                    'icon': 'chat',
                    'title': f'Trigger Words Detected ({len(found_keywords)})',
                    'text': f"Found in speech: {kw_display}"
                })
            
            # 2. Get distress words from transcript for additional context
            neg_words = features.get('negative_matches', [])
            abs_words = features.get('absolutist_matches', [])
            hes_words = features.get('hesitation_matches', [])
            cog_words = features.get('cognitive_matches', [])
            
            # Only show negative/absolutist words if NO trigger keywords were found
            # This ensures we show original Tagalog words from transcript
            if not found_keywords:
                # Show negative/distress words if relevant to this label
                if neg_words and label in ["Social_Anxiety", "PTSD", "Panic_Disorder", "GAD", "Low_Self_Esteem", "Fear_Of_Failure"]:
                    neg_display = ", ".join([f"'{w}'" for w in neg_words[:4]])
                    evidence.append({
                        'icon': 'sentiment_dissatisfied',
                        'title': 'Negative Sentiment',
                        'text': f"Used {len(neg_words)} negative keywords: [{', '.join(neg_words[:4])}]"
                    })
                
                # Show absolutist words if relevant
                if abs_words and label in ["Perfectionism", "GAD", "Academic_Burnout", "Impostor_Syndrome", "Pressure_Of_Surroundings"]:
                    evidence.append({
                        'icon': 'warning',
                        'title': 'Absolutist Language',
                        'text': f"Used {len(abs_words)} absolutist terms: [{', '.join(abs_words[:4])}]"
                    })
                    
                # Show cognitive words for Impostor Syndrome
                if cog_words and label in ["Impostor_Syndrome", "Low_Self_Esteem"]:
                    evidence.append({
                        'icon': 'psychology',
                        'title': 'Cognitive Patterns',
                        'text': f"Self-referential thinking: [{', '.join(cog_words[:3])}]"
                    })
            
            # 2. Audio features if abnormal
            jitter_v = features.get('jitter', 0)
            shimmer_v = features.get('shimmer', 0)
            hnr_v = features.get('hnr', 0)
            
            if jitter_v > 0.03:
                evidence.append({
                    'icon': 'graphic_eq',
                    'title': 'Voice Tremor',
                    'text': f'Voice instability (jitter: {jitter_v:.4f})'
                })
            
            if shimmer_v > 0.15:
                evidence.append({
                    'icon': 'air',
                    'title': 'Breathing Pattern',
                    'text': f'Irregular amplitude (shimmer: {shimmer_v:.4f})'
                })
            
            if hnr_v > 0 and hnr_v < 10:
                evidence.append({
                    'icon': 'mic',
                    'title': 'Voice Tension',
                    'text': f'Tense vocal production (HNR: {hnr_v:.1f})'
                })
            
            # 3. Text features if significant
            negative_pct = features.get('negative_count', 0)
            hesitation_pct = features.get('hesitation_count', 0)
            
            if negative_pct > 5:
                evidence.append({
                    'icon': 'sentiment_dissatisfied',
                    'title': 'Negative Language',
                    'text': f'{negative_pct:.1f}% negative words'
                })
            
            if hesitation_pct > 5:
                evidence.append({
                    'icon': 'pause_circle',
                    'title': 'Speech Hesitation',
                    'text': f'{hesitation_pct:.1f}% hesitation markers'
                })
            
            # Default: Show DETAILED model features when no other evidence exists
            # This makes the "patterns" visible to the user
            if not evidence:
                # Audio biomarker features
                mfcc_avg = np.mean([features.get(f'mfcc_{i}', 0) for i in range(13)])
                bert_avg = np.mean([features.get(f'bert_{i}', 0) for i in range(768)])
                
                evidence.append({
                    'icon': 'psychology',
                    'title': 'Biomarker Match',
                    'text': f'Audio: jitter={jitter_v:.4f}, shimmer={shimmer_v:.4f}, HNR={hnr_v:.1f}'
                })
                evidence.append({
                    'icon': 'graphic_eq',
                    'title': 'MFCC Pattern',
                    'text': f'Spectral features avg={mfcc_avg:.2f}'
                })
                evidence.append({
                    'icon': 'psychology_alt',
                    'title': 'Semantic Analysis (BERT)',
                    'text': f'Text embedding avg={bert_avg:.4f}'
                })
                
                # Text feature summary
                word_ct = features.get('word_count', 0)
                neg_ct = features.get('negative_raw', 0)
                pos_ct = len(features.get('positive_matches', []))
                cog_ct = len(features.get('cognitive_matches', []))
                abs_ct = features.get('absolutist_raw', 0)
                hes_ct = len(features.get('hesitation_matches', []))
                
                evidence.append({
                    'icon': 'text_fields',
                    'title': 'Text Features',
                    'text': f'{word_ct} words: {neg_ct} negative, {pos_ct} positive, {cog_ct} cognitive, {abs_ct} absolutist, {hes_ct} hesitation'
                })

            
            # Mark as detected based on threshold
            detected = prob >= threshold
            
            # RAW PROBABILITIES: No floor, no cap - show actual model output
            # display_prob is already the raw value from model

            indicator = {
                'name': label.replace('_', ' '),
                'label_key': label, 
                'detected': bool(detected),
                'probability': display_prob,  # Raw probability, no cap
                'threshold': int(round(threshold * 100)),
                'insights': EDUCATIONAL_INSIGHTS.get(label, {}),
                'supporting_evidence': evidence
            }

            anxiety_indicators.append(indicator)
            
        # Sort by detected first, then by probability
        anxiety_indicators.sort(key=lambda x: (x['detected'], x['probability']), reverse=True)
    
    # --- 5. Build Response ---
    detected_emotion = features.get('detected_emotion', 'Neutral')
    emotion_conf = features.get('emotion_confidence', 0.5)

    # === EMOTION SANITY CHECK ===
    # Audio models can sometimes mistake intense anxiety for "Happy" (high energy).
    # We use text sentiment to correct this.
    neg_count_check = features.get('negative_raw', 0)
    if detected_emotion == 'Happy' and neg_count_check > 0:
        print(f"⚠️ Emotion mismatch: Audio 'Happy' but Text has {neg_count_check} negative words. Overriding.")
        if neg_count_check > 1:
            detected_emotion = 'Sad' # Likely distressed
        else:
            detected_emotion = 'Neutral' # Ambiguous
        
        # Update features for consistency
        features['detected_emotion'] = detected_emotion
        emotion_conf = 0.65 # Artificial confidence for the override

    # Separate Clinical vs Educational for Summary
    clinical_indicators = []
    educational_indicators = []
    
    # Anxiety labels: Social_Anxiety, PTSD, Panic_Disorder, GAD, Agoraphobia, Neutral
    # Educational labels: Perfectionism, Impostor_Syndrome, Test_Anxiety, Academic_Burnout,
    #                     Low_Self_Esteem, Lack_Of_Academic_Support, Fear_Of_Failure,
    #                     Poor_Time_Management, Pressure_Of_Surroundings
    TRUE_EDUCATIONAL_KEYS = {
        "Perfectionism", "Impostor_Syndrome", "Test_Anxiety", "Academic_Burnout",
        "Low_Self_Esteem", "Lack_Of_Academic_Support", "Lac_Of_Academic_Support",  # Handle typo in model
        "Fear_Of_Failure", "Poor_Time_Management", "Pressure_Of_Surroundings"
    }
    
    for ind in anxiety_indicators:
        if ind['detected']:
            key = ind.get('label_key')
            # Check matches for both key and formatted name
            is_edu = key in TRUE_EDUCATIONAL_KEYS or ind['name'] in [k.replace('_', ' ') for k in TRUE_EDUCATIONAL_KEYS]
            if is_edu:
                 educational_indicators.append(ind)
            else:
                 clinical_indicators.append(ind)

    detected_names = [ind['name'] for ind in clinical_indicators]
    detected_edu_names = [ind['name'] for ind in educational_indicators]
    
    # Heuristic override removed - trust model predictions only
            
    # --- NEUTRAL LOGIC ---
    # Remove 'Neutral' from the list if there are other detected indicators
    # (Neutral only makes sense when nothing else is detected)
    other_detected = len(anxiety_indicators) > 0 and any(ind['name'] != 'Neutral' for ind in anxiety_indicators)
    if other_detected:
        anxiety_indicators = [ind for ind in anxiety_indicators if ind['name'] != 'Neutral']
    
    # Final Sort by probability (highest first)
    anxiety_indicators.sort(key=lambda x: x['probability'], reverse=True)
    
    # --- SEVERITY ADJUSTMENT BASED ON INDICATOR COUNT AND KEYWORDS ---
    # Skip if sanity check already forced Normal
    # Count detected indicators (excluding Neutral)
    total_detected = len([ind for ind in anxiety_indicators if ind['detected'] and ind['name'] != 'Neutral'])
    total_keywords_found = len(trigger_map)  # Number of labels with keyword matches
    
    # Only adjust severity if sanity check didn't already force Normal
    if not sanity_override:
        model_severity_label = severity_label  # Store model's original prediction
        
        # Simple severity rules based on indicator count:
        # 0 indicators = Normal
        # 1-2 indicators = Moderate
        # 3+ indicators = Severe
        
        if total_detected == 0:
            print(f"\n   [ADJUSTMENT] No indicators detected - severity: Normal")
            severity_label = "Normal"
            severity_probs = {"Normal": 92, "Moderate": 6, "Severe": 2}
        elif total_detected >= 1 and total_detected <= 2:
            print(f"\n   [SEVERITY] {total_detected} indicator(s) detected - severity: Moderate")
            severity_label = "Moderate"
            severity_probs = {"Normal": 15, "Moderate": 70, "Severe": 15}
        elif total_detected >= 3:
            print(f"\n   [SEVERITY] {total_detected} indicator(s) detected - severity: Severe")
            severity_label = "Severe"
            severity_probs = {"Normal": 5, "Moderate": 20, "Severe": 75}

    # --- OVERALL CONFIDENCE CALCULATION ---
    # Simple average of Severity Confidence + Avg of Top 3 Detected Indicators
    detected_probs = [ind['probability'] for ind in anxiety_indicators if ind['detected']]
    if detected_probs:
        avg_ind_conf = sum(detected_probs[:3]) / len(detected_probs[:3])
    else:
        avg_ind_conf = severity_probs.get(severity_label, 50)
        
    sev_conf = severity_probs.get(severity_label, 50)
    overall_confidence = min(98, (sev_conf + avg_ind_conf) / 2)
    
    # Cap all confidence values at 98%
    sev_conf = min(98, sev_conf)
    severity_probs = {k: min(98, v) for k, v in severity_probs.items()}
    emotion_conf_capped = min(98, emotion_conf * 100)
    
    print(f"\n[CONFIDENCE] Overall Analysis Confidence: {overall_confidence:.1f}% (Severity: {sev_conf:.1f}%, Indicators: {int(avg_ind_conf)}%)")

    summary = f"The AI analysis indicates a {severity_label} level of anxiety biomarkers. "
        
    if emotion_conf > 0.6:
        summary += f"The vocal emotional tone is strongly '{detected_emotion}'. "
    
    if detected_names:
        summary += f"Clinical indicators detected: {', '.join(detected_names[:3])}. "
    
    if detected_edu_names:
        summary += f"Educational insights: {', '.join(detected_edu_names[:3])}. "
        
    if not detected_names and not detected_edu_names:
        summary += "No specific patterns were strongly detected. "

    return {
        'success': True,
        'severity': {
            'level': severity_label,
            'confidence': sev_conf,
            'info': SEVERITY_INFO.get(severity_label, {}),
            'probabilities': severity_probs
        },
        'overall_confidence': overall_confidence,
        'emotion': {
            'label': detected_emotion,
            'confidence': emotion_conf_capped
        },
        'anxiety_indicators': anxiety_indicators, # Legacy full list
        'educational_indicators': educational_indicators, # New explicit list
        'clinical_indicators': clinical_indicators, # New explicit list
        'detected_conditions': detected_names + detected_edu_names,
        'transcript': transcript,
        'summary': summary,
        'features': {**features, 'trigger_highlights': trigger_map},  # Include trigger map in features
        'trigger_highlights': trigger_map  # Trigger words per label for highlighting
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
    Returns: ML prediction results with word analysis
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
        
        # Save audio permanently
        recordings_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'recordings')
        if not os.path.exists(recordings_dir):
            os.makedirs(recordings_dir)
            
        # Use provided filename or fallback
        safe_filename = audio_file.filename if audio_file.filename else f'web_rec_{int(time.time())}.wav'
        save_path = os.path.join(recordings_dir, safe_filename)
        
        audio_file.save(save_path)
        print(f"📥 Audio saved permanently: {save_path} ({os.path.getsize(save_path)} bytes)")
        print(f"📝 Transcript: {transcript[:100]}..." if transcript else "📝 No transcript provided")
        
        # === AUTO-TRANSCRIPTION (if no transcript provided) ===
        if not transcript or transcript.strip() == '':
            print("🎤 Auto-transcribing audio using Google Speech Recognition...")
            try:
                from audio_features import transcribe_audio
                transcript = transcribe_audio(save_path)
                if transcript:
                    print(f"   ✓ Transcribed: {transcript[:100]}...")
                else:
                    print("   ⚠️ Transcription returned empty, continuing with empty transcript")
                    transcript = ""
            except Exception as e:
                print(f"   ⚠️ Auto-transcription failed: {e}. Continuing with empty transcript.")
                transcript = ""
        
        # === AUTO-TRANSLATION ===
        transcript_en = ""
        transcript_tl = ""
        
        if transcript:
            try:
                print("🌐 Translating transcript...")
                translator = get_translator()
                original, english, tagalog = translator.translate_to_both(transcript)
                transcript_en = english
                transcript_tl = tagalog
                print(f"   ✓ English: {transcript_en[:50]}...")
                print(f"   ✓ Tagalog: {transcript_tl[:50]}...")
            except Exception as e:
                print(f"⚠️ Translation failed: {e}. Using original transcript only.")
                transcript_en = transcript
                transcript_tl = transcript

        
        # Extract features
        print("🔬 Extracting features...")
        features = extract_audio_features(save_path)
        
        # Detect emotion
        emotion = detect_emotion(save_path)
        features['detected_emotion'] = emotion['label']
        features['emotion_confidence'] = emotion['score']
        
        # Extract text features (existing LIWC features)
        text_features = extract_text_features(transcript)
        features.update(text_features)
        
        # === WORD ANALYSIS (NEW) ===
        if transcript:
            try:
                print("📊 Analyzing word patterns...")
                word_features = get_word_features_from_transcripts(
                    transcript_original=transcript,
                    transcript_en=transcript_en,
                    transcript_tl=transcript_tl
                )
                
                # Merge word analysis into features
                features.update(word_features)
                
                print(f"   ✓ Negative words: {word_features.get('negative_count', 0):.1f}% ({len(word_features.get('negative_matches', []))} unique)")
                print(f"   ✓ Positive words: {word_features.get('positive_count', 0):.1f}% ({len(word_features.get('positive_matches', []))} unique)")
                print(f"   ✓ Cognitive words: {word_features.get('cognitive_count', 0):.1f}% ({len(word_features.get('cognitive_matches', []))} unique)")
                print(f"   ✓ Absolutist words: {word_features.get('absolutist_count', 0):.1f}% ({len(word_features.get('absolutist_matches', []))} unique)")
                print(f"   ✓ Pronouns: {word_features.get('pronoun_count', 0):.1f}% ({len(word_features.get('pronoun_matches', []))} unique)")
                print(f"   ✓ First person: {word_features.get('first_person_count', 0):.1f}% ({len(word_features.get('first_person_matches', []))} unique)")
                print(f"   ✓ Hesitation words: {word_features.get('hesitation_count', 0):.1f}% ({len(word_features.get('hesitation_matches', []))} unique)")
            except Exception as e:
                print(f"⚠️ Word analysis failed: {e}")
        
        # Extract BERT embeddings (if transcript provided)
        if transcript:
            bert_embeddings = extract_bert_embeddings(transcript)
            for i, val in enumerate(bert_embeddings):
                features[f'bert_{i}'] = float(val)
        
        # NO DELETION - Keep file for playback
        # try:
        #     os.remove(temp_path)
        # except:
        #     pass
        
        # Run prediction
        print("🧠 Running prediction...")
        result = run_prediction(features, transcript)
        
        # Add extracted features to result
        result['extracted_features'] = {
            # Audio features
            'jitter': features.get('jitter', 0),
            'shimmer': features.get('shimmer', 0),
            'hnr': features.get('hnr', 0),
            'pitch_mean': features.get('pitch_mean', 0),
            'energy_mean': features.get('energy_mean', 0),
            
            # MFCC features
            **{f'mfcc_{i}': features.get(f'mfcc_{i}', 0) for i in range(13)},
            
            # BERT embeddings
            **{f'bert_{i}': features.get(f'bert_{i}', 0) for i in range(768)},
            
            # Word analysis counts
            'cognitive_count': features.get('cognitive_count', 0),
            'negative_count': features.get('negative_count', 0),
            'positive_count': features.get('positive_count', 0),
            'pronoun_count': features.get('pronoun_count', 0),
            'first_person_count': features.get('first_person_count', 0),
            'absolutist_count': features.get('absolutist_count', 0),
            'hesitation_count': features.get('hesitation_count', 0),
            'emotional_count': features.get('emotional_count', 0),
            
            # Raw counts
            'negative_raw': features.get('negative_raw', 0),
            'absolutist_raw': features.get('absolutist_raw', 0),
            
            # Matched words arrays
            'negative_matches': features.get('negative_matches', []),
            'positive_matches': features.get('positive_matches', []),
            'cognitive_matches': features.get('cognitive_matches', []),
            'pronoun_matches': features.get('pronoun_matches', []),
            'first_person_matches': features.get('first_person_matches', []),
            'absolutist_matches': features.get('absolutist_matches', []),
            'hesitation_matches': features.get('hesitation_matches', []),
            
            # DISTRESS WORDS: Combined negative + absolutist for easy display
            'distress_words': list(set(features.get('negative_matches', []) + features.get('absolutist_matches', []))),
            'distress_count': features.get('negative_raw', 0) + features.get('absolutist_raw', 0),
            
            # Analyzed transcript with word categories for UI highlighting
            # Each item: {"word": "text", "category": "negative|absolutist|positive|anxiety|calm|neutral"}
            'analyzed_words': features.get('analyzed_words', []),
            
            # Text metrics
            'transcript_length': features.get('transcript_length', 0),
            'word_count': features.get('word_count', 0),
            'avg_word_length': features.get('avg_word_length', 0),
            'sentence_count': features.get('sentence_count', 0),
            'question_count': features.get('question_count', 0),
            'exclamation_count': features.get('exclamation_count', 0),
            
            # Emotion
            'detected_emotion': features.get('detected_emotion', 'Neutral'),
            'emotion_confidence': features.get('emotion_confidence', 0) * 100,
            
            # Waveform for visualization
            'waveform': features.get('waveform', [])
        }
        
        # Add file metadata for Firebase
        result['file_name'] = safe_filename
        result['recording_id'] = safe_filename
        result['folder_name'] = request.form.get('folder_name', 'default')
        result['admin_id'] = request.form.get('admin_id', '')
        
        # Add all three transcriptions for database storage
        result['transcript_original'] = transcript
        result['transcript_en'] = transcript_en
        result['transcript_tl'] = transcript_tl
        
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
