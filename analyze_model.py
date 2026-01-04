import joblib
import numpy as np

print("Loading model...")
model_bundle = joblib.load('audio_biomarker_model_20251215_152341.pkl')

print("\n" + "="*60)
print("MODEL ANALYSIS")
print("="*60)

print(f"\n1. Model Bundle Type: {type(model_bundle)}")

if isinstance(model_bundle, dict):
    print(f"\n2. Keys in bundle: {list(model_bundle.keys())}")
    
    # Check for model
    if 'model' in model_bundle:
        model = model_bundle['model']
        print(f"\n3. Model Type: {type(model).__name__}")
        print(f"   Model: {model}")
    
    # Check for metrics/accuracy
    if 'accuracy' in model_bundle:
        print(f"\n4. Accuracy: {model_bundle['accuracy']}")
    
    if 'metrics' in model_bundle:
        print(f"\n5. Metrics: {model_bundle['metrics']}")
    
    if 'test_score' in model_bundle:
        print(f"\n6. Test Score: {model_bundle['test_score']}")
    
    if 'cv_scores' in model_bundle:
        scores = model_bundle['cv_scores']
        print(f"\n7. Cross-Validation Scores:")
        print(f"   Mean: {np.mean(scores):.4f}")
        print(f"   Std: {np.std(scores):.4f}")
        print(f"   All scores: {scores}")
    
    # Check for feature names
    if 'feature_names' in model_bundle:
        print(f"\n8. Number of features: {len(model_bundle['feature_names'])}")
    
    # Check for label encoder
    if 'label_encoder' in model_bundle:
        le = model_bundle['label_encoder']
        print(f"\n9. Classes: {le.classes_}")
    
    # List all keys with their types
    print(f"\n10. All bundle contents:")
    for key, value in model_bundle.items():
        print(f"    - {key}: {type(value).__name__}")

else:
    print(f"\n2. Model is not a dictionary. It's: {type(model_bundle)}")
    print(f"   Direct model: {model_bundle}")

print("\n" + "="*60)
