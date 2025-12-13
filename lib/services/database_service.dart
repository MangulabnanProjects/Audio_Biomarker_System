import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('audio_recorder.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 3,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Table for Metadata/Folders configuration (if needed later)
    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        created_at TEXT
      )
    ''');

    // Table for Recordings
    await db.execute('''
      CREATE TABLE recordings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        folder_name TEXT NOT NULL,
        duration TEXT NOT NULL,
        size TEXT NOT NULL,
        date TEXT NOT NULL,
        created_at TEXT NOT NULL,
        waveform_data TEXT,
        transcription TEXT
      )
    ''');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add waveform_data column to existing recordings table
      await db.execute('''
        ALTER TABLE recordings ADD COLUMN waveform_data TEXT
      ''');
    }
    if (oldVersion < 3) {
      // Add transcription column to existing recordings table
      await db.execute('''
        ALTER TABLE recordings ADD COLUMN transcription TEXT
      ''');
    }
  }

  Future<int> insertRecording(Map<String, dynamic> recording) async {
    final db = await instance.database;
    return await db.insert('recordings', recording);
  }

  Future<List<Map<String, dynamic>>> getRecordings(String folderName) async {
    final db = await instance.database;
    return await db.query(
      'recordings',
      where: 'folder_name = ?',
      whereArgs: [folderName],
      orderBy: 'created_at DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getAllRecordings() async {
    final db = await instance.database;
    return await db.query('recordings', orderBy: 'created_at DESC');
  }

  Future<int> deleteRecording(int id) async {
    final db = await instance.database;
    return await db.delete(
      'recordings',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> updateRecordingTranscription(int id, String transcription) async {
    final db = await instance.database;
    return await db.update(
      'recordings',
      {'transcription': transcription},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Folder Methods
  Future<int> insertFolder(Map<String, dynamic> folder) async {
    final db = await instance.database;
    return await db.insert(
      'folders', 
      folder,
      conflictAlgorithm: ConflictAlgorithm.replace, // Replace if exists (update metadata)
    );
  }

  Future<List<Map<String, dynamic>>> getAllFolders() async {
    final db = await instance.database;
    return await db.query('folders', orderBy: 'created_at DESC');
  }

  Future<int> deleteFolder(String folderName) async {
    final db = await instance.database;
    
    // Also delete associated recordings? 
    // For now, let's keep it simple, just delete the folder entry.
    // The UI handles deleting files.
    
    return await db.delete(
      'folders',
      where: 'name = ?',
      whereArgs: [folderName],
    );
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
  }
}
