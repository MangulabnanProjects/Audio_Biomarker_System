// File generated manually for Firebase configuration
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAnlrlVM5VTMvkhwgpSYiciFBd2Zd-FWGw',
    appId: '1:911226358765:web:70767683156e0dd79275e4',
    messagingSenderId: '911226358765',
    projectId: 'audioanalysisdb',
    authDomain: 'audioanalysisdb.firebaseapp.com',
    storageBucket: 'audioanalysisdb.firebasestorage.app',
  );

  // Android config - using same project
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAnlrlVM5VTMvkhwgpSYiciFBd2Zd-FWGw',
    appId: '1:911226358765:android:YOUR_ANDROID_APP_ID',
    messagingSenderId: '911226358765',
    projectId: 'audioanalysisdb',
    storageBucket: 'audioanalysisdb.firebasestorage.app',
  );

  // iOS config placeholder
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAnlrlVM5VTMvkhwgpSYiciFBd2Zd-FWGw',
    appId: '1:911226358765:ios:YOUR_IOS_APP_ID',
    messagingSenderId: '911226358765',
    projectId: 'audioanalysisdb',
    storageBucket: 'audioanalysisdb.firebasestorage.app',
    iosBundleId: 'com.audiorecorder.audioRecorder',
  );

  // macOS config placeholder
  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAnlrlVM5VTMvkhwgpSYiciFBd2Zd-FWGw',
    appId: '1:911226358765:ios:YOUR_MACOS_APP_ID',
    messagingSenderId: '911226358765',
    projectId: 'audioanalysisdb',
    storageBucket: 'audioanalysisdb.firebasestorage.app',
    iosBundleId: 'com.audiorecorder.audioRecorder',
  );

  // Windows config placeholder
  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyAnlrlVM5VTMvkhwgpSYiciFBd2Zd-FWGw',
    appId: '1:911226358765:web:70767683156e0dd79275e4',
    messagingSenderId: '911226358765',
    projectId: 'audioanalysisdb',
    authDomain: 'audioanalysisdb.firebaseapp.com',
    storageBucket: 'audioanalysisdb.firebasestorage.app',
  );
}
