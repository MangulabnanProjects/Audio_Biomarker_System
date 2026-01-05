"""
Translation Module for Audio Biomarker System
Provides automatic translation using free Google Translate API (googletrans)
Handles language detection and translation to English and Tagalog
"""

from typing import Dict, Tuple, Optional
import warnings
warnings.filterwarnings('ignore')


class Translator:
    """
    Translator using googletrans library (free Google Translate)
    Handles translation with caching and error handling
    """
    
    def __init__(self):
        self._translator = None
        self._cache = {}
        self._initialize()
    
    def _initialize(self):
        """Initialize Google Translate connection"""
        try:
            # Using deep-translator instead of googletrans for Python 3.13 compatibility
            from deep_translator import GoogleTranslator
            self._translator = GoogleTranslator
            print("[Translator] Deep-Translator (Google) initialized successfully")
        except ImportError as ie:
            print(f"[WARNING] deep-translator not installed. Install with: pip install deep-translator")
            print(f"[WARNING] Details: {ie}")
            self._translator = None
        except Exception as e:
            print(f"[WARNING] Translator initialization failed: {e}")
            import traceback
            traceback.print_exc()
            self._translator = None
    
    def detect_language(self, text: str) -> str:
        """
        Detect language of text
        Note: deep-translator doesn't have built-in detection, 
        we'll use a simple heuristic based on common words
        
        Args:
            text: Input text
            
        Returns:
            Language code (e.g., 'en', 'tl', 'fil')
        """
        if not text:
            return 'unknown'
        
        text_lower = text.lower()
        
        # Simple heuristic based on common words
        tagalog_indicators = ['ako', 'ko', 'ang', 'sa', 'ng', 'na', 'ay', 'mga', 'yung', 'kasi', 'pero']
        english_indicators = ['the', 'is', 'are', 'was', 'were', 'i', 'me', 'my', 'you', 'and', 'or']
        
        tagalog_count = sum(1 for word in tagalog_indicators if word in text_lower)
        english_count = sum(1 for word in english_indicators if word in text_lower)
        
        if tagalog_count > english_count:
            return 'tl'
        elif english_count > tagalog_count:
            return 'en'
        else:
            return 'unknown'
    
    def translate(self, text: str, target_lang: str) -> str:
        """
        Translate text to target language
        
        Args:
            text: Text to translate
            target_lang: Target language code ('en' for English, 'tl' for Tagalog)
            
        Returns:
            Translated text (or original if translation fails)
        """
        if not text:
            return ""
        
        # Check cache
        cache_key = f"{text[:50]}_{target_lang}"
        if cache_key in self._cache:
            return self._cache[cache_key]
        
        if not self._translator:
            print("[WARNING] Translator not available, returning original text")
            return text
        
        try:
            # Use deep-translator API
            translator_instance = self._translator(source='auto', target=target_lang)
            translated = translator_instance.translate(text)
            
            # Cache result
            self._cache[cache_key] = translated
            
            return translated
        except Exception as e:
            print(f"[WARNING] Translation to {target_lang} failed: {e}")
            return text
    
    def translate_to_both(self, text: str) -> Tuple[str, str, str]:
        """
        Translate text to both English and Tagalog
        Automatically detects source language
        
        Args:
            text: Original text
            
        Returns:
            Tuple of (original, english_translation, tagalog_translation)
        """
        if not text:
            return "", "", ""
        
        # Detect language
        detected_lang = self.detect_language(text)
        print(f"[Translator] Detected language: {detected_lang}")
        
        original = text.strip()
        
        # Translate to English
        if detected_lang in ['en', 'english']:
            english = original
        else:
            print(f"[Translator] Translating to English...")
            english = self.translate(text, 'en')
        
        # Translate to Tagalog/Filipino
        if detected_lang in ['tl', 'fil', 'tagalog', 'filipino']:
            tagalog = original
        else:
            print(f"[Translator] Translating to Tagalog...")
            tagalog = self.translate(text, 'tl')
        
        return original, english, tagalog
    
    def clear_cache(self):
        """Clear translation cache"""
        self._cache.clear()


# Global translator instance
_global_translator = None


def get_translator() -> Translator:
    """
    Get global translator instance (singleton pattern)
    
    Returns:
        Translator instance
    """
    global _global_translator
    if _global_translator is None:
        _global_translator = Translator()
    return _global_translator


def translate_transcript(transcript: str) -> Dict[str, str]:
    """
    Convenience function to translate transcript
    
    Args:
        transcript: Original transcript text
        
    Returns:
        Dictionary with keys: 'original', 'english', 'tagalog'
    """
    translator = get_translator()
    original, english, tagalog = translator.translate_to_both(transcript)
    
    return {
        'original': original,
        'english': english,
        'tagalog': tagalog
    }


# ==========================================
# TESTING
# ==========================================

if __name__ == "__main__":
    print("=" * 60)
    print("TRANSLATION MODULE TEST")
    print("=" * 60)
    
    # Test examples
    test_cases = [
        "Masaya naman ako kasi ang dami ko na nagagawain.",
        "I am feeling very anxious about my exams tomorrow.",
        "Hindi na ako nakakaroon ng takot or something."
    ]
    
    translator = get_translator()
    
    for i, text in enumerate(test_cases, 1):
        print(f"\n--- Test Case {i} ---")
        print(f"Original: {text}")
        
        detected = translator.detect_language(text)
        print(f"Detected Language: {detected}")
        
        original, english, tagalog = translator.translate_to_both(text)
        print(f"English: {english}")
        print(f"Tagalog: {tagalog}")
    
    print("\n" + "=" * 60)
    print("Translation test complete!")
    print("=" * 60)
