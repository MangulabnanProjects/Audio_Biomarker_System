"""
Word Analysis Module for Mobile Audio Biomarker System
Analyzes transcribed text for specific word categories and indicators
Designed for Firebase integration with multi-transcript support
"""

import re
from typing import Dict, List, Tuple, Any


# ==========================================
# WORD LISTS - Comprehensive Categories
# ==========================================

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
    'sad', 'angry', 'afraid', 'anxious', 'worried', 'depressed', 'stressed', 'nervous', 'scared', 
    'lungkot', 'galit', 'takot', 'kaba',
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
    'happy', 'good', 'great', 'excellent', 'love', 'joy', 'wonderful', 'blessed', 
    'mabuti', 'masaya', 'maganda', 'galing',
    'excited', 'glad', 'calm', 'relaxed', 'peaceful', 'content', 'satisfied', 'proud', 'confident',
    'strong', 'brave', 'courage', 'hopeful', 'optimistic', 'inspired', 'motivated', 'energetic',
    'thankful', 'grateful', 'appreciate', 'enjoy', 'fun', 'funny', 'smile',
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

PRONOUNS_WORDS = [
    # -- Original List (First Person) --
    'i', 'me', 'my', 'mine', 'myself', 'we', 'us', 'our', 'ako', 'ko', 'akin', 'kami', 'tayo',
    # -- English Additions (2nd/3rd Person) --
    'ours', 'ourselves',
    'you', 'your', 'yours', 'yourself', 'yourselves',
    'he', 'him', 'his', 'himself',
    'she', 'her', 'hers', 'herself',
    'it', 'its', 'itself',
    'they', 'them', 'their', 'theirs', 'themselves',
    # -- Tagalog Additions --
    'amin', 'atin', 'namin', 'natin', 'kata', 'kita',
    'ka', 'ikaw', 'mo', 'iyo', 'kayo', 'ninyo', 'inyo',
    'siya', 'niya', 'kaniya', 'kanya',
    'sila', 'nila', 'kanila'
]

FIRST_PERSON_WORDS = [
    # -- Original List --
    'i', 'me', 'my', 'mine', 'myself', 'ako', 'ko', 'akin',
    # -- English Additions --
    'we', 'us', 'our', 'ours', 'ourselves',
    # -- Tagalog Additions --
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
    'tsaka', 'yung', 'sa', 
    'kano', 'anong', 'basta', 'siguro', 'yata'
]


# ==========================================
# PATTERN COMPILATION
# ==========================================

def compile_pattern(word_list: List[str]) -> re.Pattern:
    """
    Compile regex pattern from word list
    Uses word boundaries for accurate matching
    """
    escaped = [re.escape(w) for w in word_list]
    return re.compile(r'\b(' + '|'.join(escaped) + r')\b', re.IGNORECASE)


# Compile patterns once at module load
COG_PATTERN = compile_pattern(COGNITIVE_WORDS)
NEG_PATTERN = compile_pattern(NEGATIVE_WORDS)
POS_PATTERN = compile_pattern(POSITIVE_WORDS)
PRO_PATTERN = compile_pattern(PRONOUNS_WORDS)
FP_PATTERN = compile_pattern(FIRST_PERSON_WORDS)
ABS_PATTERN = compile_pattern(ABSOLUTIST_WORDS)
HES_PATTERN = compile_pattern(HESITATION_WORDS)


# ==========================================
# ANALYSIS FUNCTIONS
# ==========================================

def analyze_single_transcript(text: str, pattern: re.Pattern) -> Tuple[int, List[str]]:
    """
    Analyze a single transcript for pattern matches
    
    Args:
        text: Transcript text to analyze
        pattern: Compiled regex pattern
        
    Returns:
        Tuple of (count, unique_words_found)
    """
    if not text or not isinstance(text, str):
        return 0, []
    
    matches = pattern.findall(text)
    count = len(matches)
    unique_words = sorted(list(set(m.lower() for m in matches)))
    
    return count, unique_words


def analyze_category_multi_transcript(
    transcript_original: str = "",
    transcript_en: str = "",
    transcript_tl: str = "",
    pattern: re.Pattern = None
) -> Dict[str, Any]:
    """
    Analyze category across multiple transcripts
    Returns max count and combined unique words
    
    Args:
        transcript_original: Original transcript
        transcript_en: English translation
        transcript_tl: Tagalog translation
        pattern: Compiled regex pattern for category
        
    Returns:
        Dictionary with count, matches array, and raw count
    """
    if pattern is None:
        return {
            'count': 0,
            'matches': [],
            'raw': 0
        }
    
    transcripts = [transcript_original, transcript_en, transcript_tl]
    all_words_found = set()
    max_count = 0
    
    for transcript in transcripts:
        if transcript:
            count, unique_words = analyze_single_transcript(transcript, pattern)
            
            # Use max count among translations
            if count > max_count:
                max_count = count
            
            # Collect unique words from all transcripts
            all_words_found.update(unique_words)
    
    return {
        'count': max_count,
        'matches': list(all_words_found),
        'raw': max_count
    }


def analyze_word_features(
    transcript_original: str = "",
    transcript_en: str = "",
    transcript_tl: str = "",
    word_count: int = 0
) -> Dict[str, Any]:
    """
    Complete word analysis for all categories
    
    Args:
        transcript_original: Original transcript
        transcript_en: English translation
        transcript_tl: Tagalog translation
        word_count: Total word count (if 0, will be calculated)
        
    Returns:
        Dictionary with all word analysis features formatted for Firebase
    """
    
    # Calculate word count if not provided
    if word_count == 0 and transcript_original:
        word_count = len(transcript_original.split())
    
    # Prevent division by zero
    if word_count == 0:
        word_count = 1
    
    # Analyze all categories
    cognitive_result = analyze_category_multi_transcript(
        transcript_original, transcript_en, transcript_tl, COG_PATTERN
    )
    
    negative_result = analyze_category_multi_transcript(
        transcript_original, transcript_en, transcript_tl, NEG_PATTERN
    )
    
    positive_result = analyze_category_multi_transcript(
        transcript_original, transcript_en, transcript_tl, POS_PATTERN
    )
    
    pronoun_result = analyze_category_multi_transcript(
        transcript_original, transcript_en, transcript_tl, PRO_PATTERN
    )
    
    first_person_result = analyze_category_multi_transcript(
        transcript_original, transcript_en, transcript_tl, FP_PATTERN
    )
    
    absolutist_result = analyze_category_multi_transcript(
        transcript_original, transcript_en, transcript_tl, ABS_PATTERN
    )
    
    hesitation_result = analyze_category_multi_transcript(
        transcript_original, transcript_en, transcript_tl, HES_PATTERN
    )
    
    # Calculate emotional_count (combination of positive + negative)
    emotional_raw = negative_result['raw'] + positive_result['raw']
    
    # Calculate percentages (per 100 words)
    cognitive_count = (cognitive_result['raw'] / word_count) * 100
    negative_count = (negative_result['raw'] / word_count) * 100
    positive_count = (positive_result['raw'] / word_count) * 100
    pronoun_count = (pronoun_result['raw'] / word_count) * 100
    first_person_count = (first_person_result['raw'] / word_count) * 100
    absolutist_count = (absolutist_result['raw'] / word_count) * 100
    hesitation_count = (hesitation_result['raw'] / word_count) * 100
    emotional_count = (emotional_raw / word_count) * 100
    
    # Return Firebase-compatible format
    return {
        # Counts (percentages)
        'cognitive_count': round(cognitive_count, 2),
        'negative_count': round(negative_count, 2),
        'positive_count': round(positive_count, 2),
        'pronoun_count': round(pronoun_count, 2),
        'first_person_count': round(first_person_count, 2),
        'absolutist_count': round(absolutist_count, 2),
        'hesitation_count': round(hesitation_count, 2),
        'emotional_count': round(emotional_count, 2),
        
        # Raw counts
        'negative_raw': negative_result['raw'],
        'absolutist_raw': absolutist_result['raw'],
        
        # Matched words (arrays)
        'negative_matches': negative_result['matches'],
        'positive_matches': positive_result['matches'],
        'cognitive_matches': cognitive_result['matches'],
        'pronoun_matches': pronoun_result['matches'],
        'first_person_matches': first_person_result['matches'],
        'absolutist_matches': absolutist_result['matches'],
        'hesitation_matches': hesitation_result['matches'],
    }


# ==========================================
# CONVENIENCE FUNCTIONS
# ==========================================

def get_word_features_from_transcripts(
    transcript_original: str = "",
    transcript_en: str = "",
    transcript_tl: str = ""
) -> Dict[str, Any]:
    """
    Convenience wrapper for word analysis
    Automatically calculates word count from original transcript
    
    Args:
        transcript_original: Original transcript
        transcript_en: English translation
        transcript_tl: Tagalog translation
        
    Returns:
        Complete word analysis dictionary
    """
    word_count = len(transcript_original.split()) if transcript_original else 0
    return analyze_word_features(transcript_original, transcript_en, transcript_tl, word_count)


# ==========================================
# TESTING
# ==========================================

if __name__ == "__main__":
    # Test example
    test_transcript = """
    Masaya naman ako kasi ang dami ko na nagagawain. Masaya dahil matatapos na yung system. 
    Hindi na ako nakakaroon ng takot or something. Kasi matatapos na yung system ngayon. 
    Alam ko mga pag-defense kami na maayos.
    """
    
    # Test English translation (simulated)
    test_en = """
    I'm happy because I've accomplished a lot. Happy because the system will be finished. 
    I'm not experiencing fear or something anymore. Because the system will be finished now. 
    I know our defense will go well.
    """
    
    # Test Tagalog version (pure)
    test_tl = test_transcript
    
    results = get_word_features_from_transcripts(test_transcript, test_en, test_tl)
    
    print("=" * 60)
    print("WORD ANALYSIS TEST RESULTS")
    print("=" * 60)
    print(f"Negative Count: {results['negative_count']}%")
    print(f"Negative Matches: {results['negative_matches']}")
    print(f"Cognitive Count: {results['cognitive_count']}%")
    print(f"Cognitive Matches: {results['cognitive_matches']}")
    print(f"First Person Count: {results['first_person_count']}%")
    print(f"Emotional Count: {results['emotional_count']}%")
    print("=" * 60)
