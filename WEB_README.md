# Audio Biomarker Web App

A simple web interface for recording voice, transcribing, and analyzing vocal biomarkers for mental health indicators.

## Setup

1. **Install dependencies:**
   ```bash
   pip install flask scikit-learn joblib librosa scipy requests
   ```

2. **Add your AssemblyAI API key:**
   - Open `app.py`
   - Find line ~234: `ASSEMBLYAI_API_KEY = "YOUR_API_KEY_HERE"`
   - Replace with your actual API key from https://www.assemblyai.com/

3. **Run the server:**
   ```bash
   python app.py
   ```

4. **Open in browser:**
   - Navigate to http://127.0.0.1:5000

## How to Use

1. **Click the microphone button** to start recording
2. **Speak for 10-30 seconds** (optimal length)
3. **Click again to stop** recording
4. Wait for analysis:
   - Audio transcription (Tagalog/English supported)
   - Feature extraction (jitter, shimmer, MFCC)
   - ML prediction for anxiety biomarkers
5. **View results:**
   - Severity level (Low/Moderate/High)
   - Detected emotion
   - Anxiety indicators with probabilities
   - Full transcription

## Features

- ✅ **Browser-based audio recording** (no file upload needed)
- ✅ **Automatic transcription** with AssemblyAI
- ✅ **Vocal biomarker extraction** (16 audio features)
- ✅ **Text analysis** (negative words, absolutist language)
- ✅ **BERT embeddings** (768 semantic features)
- ✅ **ML prediction** using trained RandomForest model
- ✅ **Real-time results** with clean UI

## Notes

- **Tagalog support:** Transcription is set to Tagalog (`language_code: 'tl'`). Change to `'en'` for English in `app.py` line 252.
- **Microphone permission:** Browser will ask for microphone access on first recording.
- **Model accuracy:** Prediction uses ~794 features (audio + text + BERT embeddings).
