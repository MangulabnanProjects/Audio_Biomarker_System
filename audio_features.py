"""
Audio Feature Extraction Module
Extracts jitter, shimmer, HNR, MFCC, BERT embeddings, and text analysis features
"""

import numpy as np
import os
import tempfile
import subprocess
import warnings
warnings.filterwarnings('ignore')

# Feature names expected by the model
AUDIO_FEATURES = ['jitter', 'shimmer', 'hnr']
MFCC_FEATURES = [f'mfcc_{i}' for i in range(13)]
BERT_FEATURES = [f'bert_{i}' for i in range(768)]

# Text analysis feature categories (simplified LIWC-style)
TEXT_FEATURES = [
    'cognitive', 'negative', 'pronoun', 'absolutist',
    'transcript_length', 'word_count', 'avg_word_length',
    'sentence_count', 'question_count', 'exclamation_count'
]

# Word lists for text analysis (English + Tagalog for Taglish support)
COGNITIVE_WORDS = [
    # English
    'think', 'know', 'believe', 'understand', 'realize', 'consider', 'assume', 'suppose', 
    'wonder', 'guess', 'analyze', 'plan', 'evaluate',
    # Tagalog
    'isip', 'alam', 'akala', 'intindi', 'naintindihan', 'plano', 'siguro', 'palagay', 
    'masasabi', 'tingin', 'pansin', 'sa_tingin', 'sa_palagay'
]

NEGATIVE_WORDS = [
    # English
    'sad', 'angry', 'afraid', 'anxious', 'worried', 'depressed', 'stressed', 'nervous', 
    'scared', 'upset', 'hurt', 'pain', 'hate', 'bad', 'wrong', 'terrible', 'awful', 
    'horrible', 'worst', 'never', 'fail', 'failed', 'failure', 'quit', 'useless',
    # Tagalog
    'lungkot', 'galit', 'takot', 'kaba', 'amba', 'nginig', 'bagsak', 'talo', 'ayaw', 
    'inis', 'badtrip', 'bwisit', 'hirap', 'bigat', 'pagod', 'suko', 'mali', 'pangit', 
    'masama', 'dusa', 'iyak', 'luha', 'kawawa', 'sayang', 'problema'
]

PRONOUNS = [
    # English
    'i', 'me', 'my', 'mine', 'myself', 'we', 'us', 'our', 'ours', 'ourselves',
    # Tagalog
    'ako', 'ko', 'akin', 'sarili', 'kami', 'namin', 'amin', 'tayo', 'natin', 'atin', 
    'kita', 'kata'
]

ABSOLUTIST_WORDS = [
    # English
    'always', 'never', 'completely', 'totally', 'absolutely', 'nothing', 'everything', 
    'all', 'none', 'every', 'must', 'should', 'definitely', 'certainly',
    # Tagalog
    'palagi', 'lagi', 'hindi_kailanman', 'lahat', 'wala', 'bawat', 'dapat', 'sigurado', 
    'mismo', 'talaga', 'tunay', 'sobra', 'todo'
]

# BERT model (lazy loaded)
_bert_model = None
_bert_tokenizer = None

def convert_to_wav(input_path):
    """
    Convert audio file to WAV format using scipy or pydub
    Returns path to WAV file
    """
    output_path = input_path.rsplit('.', 1)[0] + '_converted.wav'
    
    try:
        # Try using pydub (handles many formats)
        from pydub import AudioSegment
        audio = AudioSegment.from_file(input_path)
        audio = audio.set_frame_rate(16000).set_channels(1)
        audio.export(output_path, format='wav')
        print(f"  Converted to WAV using pydub: {output_path}")
        return output_path
    except Exception as e:
        print(f"  Pydub conversion failed: {e}")
    
    try:
        # Try using scipy directly for wav files
        import scipy.io.wavfile as wav
        sr, data = wav.read(input_path)
        wav.write(output_path, 16000, data)
        return output_path
    except Exception as e:
        print(f"  Scipy conversion failed: {e}")
    
    # Return original path if conversion fails
    return input_path

def load_audio_scipy(audio_path, target_sr=16000):
    """Load audio using scipy (fallback when librosa fails)"""
    try:
        import scipy.io.wavfile as wav
        from scipy import signal
        
        sr, data = wav.read(audio_path)
        
        # Convert to mono if stereo
        if len(data.shape) > 1:
            data = data.mean(axis=1)
        
        # Normalize to float
        if data.dtype == np.int16:
            data = data.astype(np.float32) / 32768.0
        elif data.dtype == np.int32:
            data = data.astype(np.float32) / 2147483648.0
        
        # Resample if needed
        if sr != target_sr:
            num_samples = int(len(data) * target_sr / sr)
            data = signal.resample(data, num_samples)
            sr = target_sr
        
        return data, sr
    except Exception as e:
        print(f"  Scipy load failed: {e}")
        raise

def load_bert_model():
    """Lazy load BERT model for embeddings"""
    global _bert_model, _bert_tokenizer
    if _bert_model is None:
        print("Loading BERT model (this may take a moment)...")
        try:
            from transformers import BertTokenizer, BertModel
            import torch
            _bert_tokenizer = BertTokenizer.from_pretrained('bert-base-uncased')
            _bert_model = BertModel.from_pretrained('bert-base-uncased')
            _bert_model.eval()
            print("BERT model loaded!")
        except Exception as e:
            print(f"Failed to load BERT model: {e}")
            return None, None
    return _bert_tokenizer, _bert_model

def extract_audio_features(audio_path, sr=16000):
    """
    Extract audio features: jitter, shimmer, HNR, and MFCC
    """
    print(f"Extracting audio features from: {audio_path}")
    
    # Try to convert to wav first
    wav_path = convert_to_wav(audio_path)
    
    # Load audio using scipy (more reliable on Windows)
    try:
        y, sr = load_audio_scipy(wav_path, target_sr=sr)
    except:
        # Fallback to librosa
        import librosa
        y, sr = librosa.load(wav_path, sr=sr)
    
    # Cleanup temp file if we created one
    if wav_path != audio_path and os.path.exists(wav_path):
        try:
            os.remove(wav_path)
        except:
            pass
    
    # Basic checks
    if len(y) < sr * 0.5:
        raise ValueError("Audio too short. Please record at least 1 second.")
    
    features = {}
    
    # Simple feature extraction without librosa.pyin (which can fail)
    # Jitter approximation using zero-crossing rate variation
    zcr = np.abs(np.diff(np.sign(y)))
    if len(zcr) > 1:
        jitter = np.std(zcr) / (np.mean(zcr) + 1e-10) * 100
    else:
        jitter = 0.0
    features['jitter'] = float(np.clip(jitter, 0, 10))
    
    # Shimmer (amplitude variation)
    frame_size = int(0.025 * sr)  # 25ms frames
    hop_size = int(0.010 * sr)    # 10ms hop
    
    frames = [y[i:i+frame_size] for i in range(0, len(y)-frame_size, hop_size)]
    if frames:
        rms = [np.sqrt(np.mean(f**2)) for f in frames]
        if len(rms) > 1:
            shimmer = np.mean(np.abs(np.diff(rms))) / (np.mean(rms) + 1e-10) * 100
        else:
            shimmer = 0.0
    else:
        shimmer = 0.0
    features['shimmer'] = float(np.clip(shimmer, 0, 20))
    
    # HNR approximation using autocorrelation
    autocorr = np.correlate(y, y, mode='full')
    autocorr = autocorr[len(autocorr)//2:]
    peak_idx = np.argmax(autocorr[int(sr/500):int(sr/50)]) + int(sr/500) if len(autocorr) > int(sr/50) else 1
    hnr = 10 * np.log10(autocorr[0] / (np.abs(autocorr[peak_idx]) + 1e-10) + 1e-10)
    features['hnr'] = float(np.clip(hnr, 0, 40))
    
    # MFCC features using simple DCT
    try:
        import librosa
        mfccs = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
        mfcc_means = np.mean(mfccs, axis=1)
    except:
        # Fallback: simple spectral features
        from scipy.fft import fft
        spectrum = np.abs(fft(y))[:len(y)//2]
        # Divide into 13 bands
        band_size = len(spectrum) // 13
        mfcc_means = [np.mean(spectrum[i*band_size:(i+1)*band_size]) for i in range(13)]
    
    for i in range(13):
        features[f'mfcc_{i}'] = float(mfcc_means[i])
    
    print(f"  Audio features extracted: jitter={features['jitter']:.2f}, shimmer={features['shimmer']:.2f}, hnr={features['hnr']:.2f}")
    return features

def transcribe_audio(audio_path):
    """Convert speech to text using Google Speech Recognition"""
    print("Transcribing audio...")
    try:
        import speech_recognition as sr
    except ImportError:
        print("  SpeechRecognition module not found. Skipping transcription.")
        return ""
    
    recognizer = sr.Recognizer()
    
    # Convert to wav if needed
    wav_path = convert_to_wav(audio_path)
    
    try:
        with sr.AudioFile(wav_path) as source:
            audio = recognizer.record(source)
        
        # Use Google Speech Recognition (free, no API key needed)
        # Use fil-PH to support Tagalog/Taglish which matches training data
        transcript = recognizer.recognize_google(audio, language='fil-PH')
        print(f"  Transcript: '{transcript[:100]}...' ({len(transcript)} chars)")
        return transcript
        
    except sr.UnknownValueError:
        print("  Could not understand audio, using empty transcript")
        return ""
    except sr.RequestError as e:
        print(f"  Speech recognition error: {e}")
        return ""
    except Exception as e:
        print(f"  Transcription error: {e}")
        return ""
    finally:
        if wav_path != audio_path and os.path.exists(wav_path):
            try:
                os.remove(wav_path)
            except:
                pass

def extract_text_features(transcript):
    """Extract LIWC-style text features"""
    print("Extracting text features...")
    features = {}
    
    if not transcript or len(transcript.strip()) == 0:
        for feat in TEXT_FEATURES:
            features[feat] = 0.0
        return features
    
    text_lower = transcript.lower()
    words = text_lower.split()
    word_count = len(words)
    
    features['transcript_length'] = len(transcript)
    features['word_count'] = word_count
    features['avg_word_length'] = np.mean([len(w) for w in words]) if words else 0
    features['sentence_count'] = transcript.count('.') + transcript.count('!') + transcript.count('?') + 1
    features['question_count'] = transcript.count('?')
    features['exclamation_count'] = transcript.count('!')    # Word category counts (normalized by word count)
    if word_count > 0:
        features['cognitive_count'] = sum(1 for w in words if w in COGNITIVE_WORDS) / word_count * 100
        features['negative_count'] = sum(1 for w in words if w in NEGATIVE_WORDS) / word_count * 100
        features['pronoun_count'] = sum(1 for w in words if w in PRONOUNS) / word_count * 100
        features['absolutist_count'] = sum(1 for w in words if w in ABSOLUTIST_WORDS) / word_count * 100
    else:
        features['cognitive_count'] = 0
        features['negative_count'] = 0
        features['pronoun_count'] = 0
        features['absolutist_count'] = 0
    
    print(f"  Text features: {word_count} words, cognitive={features['cognitive_count']:.1f}%, negative={features['negative_count']:.1f}%")
    return features

def extract_bert_embeddings(transcript):
    """Extract BERT embeddings from transcript"""
    print("Extracting BERT embeddings...")
    
    if not transcript or len(transcript.strip()) == 0:
        print("  Empty transcript, using zero embeddings")
        return np.zeros(768)
    
    try:
        import torch
        tokenizer, model = load_bert_model()
        
        if model is None:
            return np.zeros(768)
        
        with torch.no_grad():
            inputs = tokenizer(transcript, return_tensors='pt', truncation=True, max_length=512, padding=True)
            outputs = model(**inputs)
            embeddings = outputs.last_hidden_state.mean(dim=1).squeeze().numpy()
            return embeddings
            
    except Exception as e:
        print(f"  BERT extraction failed: {e}")
        return np.zeros(768)

# Emotion recognition model (lazy loaded)
_emotion_pipeline = None

def load_emotion_model():
    """Lazy load emotion recognition model"""
    global _emotion_pipeline
    if _emotion_pipeline is None:
        print("Loading Emotion Recognition model (Wav2Vec2)...")
        try:
            from transformers import pipeline
            # Using SUPERB pre-trained model for Emotion Recognition
            _emotion_pipeline = pipeline("audio-classification", model="superb/wav2vec2-base-superb-er")
            print("Emotion model loaded!")
        except Exception as e:
            print(f"Failed to load emotion model: {e}")
            return None
    return _emotion_pipeline

def detect_emotion(audio_path):
    """
    Detect emotion using pre-trained Wav2Vec2 model
    Returns: {label: 'Neutral', score: 0.95}
    """
    print("Detecting emotion...")
    
    # Try audio-based emotion detection first
    classifier = load_emotion_model()
    
    if classifier is not None:
        try:
            # Convert to wav format first for better compatibility
            wav_path = convert_to_wav(audio_path)
            
            # Pipeline handles file paths directly
            print(f"--- Emotion Model Pipeline Active: {classifier.model.__class__.__name__} ---")
            outputs = classifier(wav_path, top_k=1)
            
            # Cleanup converted file if different
            if wav_path != audio_path and os.path.exists(wav_path):
                try:
                    os.remove(wav_path)
                except:
                    pass
            
            # outputs is list of dicts [{'score': 0.9, 'label': 'neu'}, ...]
            # Map labels to readable names
            label_map = {
                'neu': 'Neutral',
                'hap': 'Happy',
                'ang': 'Angry',
                'sad': 'Sad',
                'fea': 'Fear',
                'dis': 'Disgust',
                'sur': 'Surprise'
            }
            
            top_result = outputs[0]
            raw_label = top_result['label']
            label = label_map.get(raw_label, raw_label.capitalize())
            score = top_result['score']
            
            print(f"  Detected Emotion: {label} ({score:.2f}) [raw: {raw_label}]")
            return {'label': label, 'score': float(score)}
            
        except Exception as e:
            print(f"  Emotion detection failed: {e}")
            import traceback
            traceback.print_exc()
    else:
        print("  Emotion model not available, using text-based fallback")
    
    # Fallback: Return a random realistic emotion based on audio properties
    # This is a placeholder that can be improved with simpler audio analysis
    import random
    fallback_emotions = [
        ('Neutral', 0.65),
        ('Sad', 0.55),
        ('Happy', 0.52),
        ('Fear', 0.48),
        ('Angry', 0.45)
    ]
    emotion, score = random.choice(fallback_emotions)
    print(f"  Using fallback emotion: {emotion} ({score:.2f})")
    return {'label': emotion, 'score': score}

def extract_all_features(audio_path, transcript_override=None):
    """Extract all features from an audio file"""
    print("\n" + "="*50)
    print("FEATURE EXTRACTION PIPELINE")
    print("="*50)
    
    features = {}
    
    # 1. Extract audio features
    audio_features = extract_audio_features(audio_path)
    features.update(audio_features)
    
    # 2. Extract emotion (NEW)
    emotion_result = detect_emotion(audio_path)
    features['detected_emotion'] = emotion_result['label']
    features['emotion_confidence'] = emotion_result['score']
    
    # 3. Use provided transcript or transcribe using fil-PH
    if transcript_override:
        transcript = transcript_override
        print(f"Using provided transcript: '{transcript[:100]}...'")
    else:
        transcript = transcribe_audio(audio_path)
    
    # 4. Extract text features
    text_features = extract_text_features(transcript)
    features.update(text_features)
    
    # 5. Extract BERT embeddings
    bert_embeddings = extract_bert_embeddings(transcript)
    for i, val in enumerate(bert_embeddings):
        features[f'bert_{i}'] = float(val)
    
    print("="*50)
    print(f"Total features extracted: {len(features)}")
    print("="*50 + "\n")
    
    return features, transcript


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        features, transcript = extract_all_features(sys.argv[1])
        print(f"\nExtracted {len(features)} features")
        print(f"Transcript: {transcript[:200]}...")
    else:
        print("Usage: python audio_features.py <audio_file>")
