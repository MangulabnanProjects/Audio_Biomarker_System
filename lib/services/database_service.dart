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
      version: 4, // Upgraded for admin_id support
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Table for Metadata/Folders configuration
    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        admin_id TEXT NOT NULL,
        created_at TEXT,
        UNIQUE(name, admin_id)
      )
    ''');

    // Table for Recordings - now with admin_id
    await db.execute('''
      CREATE TABLE recordings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        folder_name TEXT NOT NULL,
        admin_id TEXT NOT NULL,
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
      await db.execute('''
        ALTER TABLE recordings ADD COLUMN waveform_data TEXT
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        ALTER TABLE recordings ADD COLUMN transcription TEXT
      ''');
    }
    if (oldVersion < 4) {
      // Add admin_id column to existing tables
      await db.execute('''
        ALTER TABLE recordings ADD COLUMN admin_id TEXT DEFAULT ''
      ''');
      await db.execute('''
        ALTER TABLE folders ADD COLUMN admin_id TEXT DEFAULT ''
      ''');
    }
  }

  // ============ Recording Methods (Filtered by Admin) ============

  Future<int> insertRecording(Map<String, dynamic> recording) async {
    final db = await instance.database;
    return await db.insert('recordings', recording);
  }

  Future<List<Map<String, dynamic>>> getRecordings(String folderName, {String? adminId}) async {
    final db = await instance.database;
    
    if (adminId != null && adminId.isNotEmpty) {
      return await db.query(
        'recordings',
        where: 'folder_name = ? AND admin_id = ?',
        whereArgs: [folderName, adminId],
        orderBy: 'created_at DESC',
      );
    }
    
    return await db.query(
      'recordings',
      where: 'folder_name = ?',
      whereArgs: [folderName],
      orderBy: 'created_at DESC',
    );
  }

  /// Get all recordings for a specific admin
  Future<List<Map<String, dynamic>>> getAllRecordings({String? adminId}) async {
    final db = await instance.database;
    
    if (adminId != null && adminId.isNotEmpty) {
      return await db.query(
        'recordings', 
        where: 'admin_id = ?',
        whereArgs: [adminId],
        orderBy: 'created_at DESC',
      );
    }
    
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

  // ============ Folder Methods (Filtered by Admin) ============

  Future<int> insertFolder(Map<String, dynamic> folder) async {
    final db = await instance.database;
    return await db.insert(
      'folders', 
      folder,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all folders for a specific admin
  Future<List<Map<String, dynamic>>> getAllFolders({String? adminId}) async {
    final db = await instance.database;
    
    if (adminId != null && adminId.isNotEmpty) {
      return await db.query(
        'folders',
        where: 'admin_id = ?',
        whereArgs: [adminId],
        orderBy: 'created_at DESC',
      );
    }
    
    return await db.query('folders', orderBy: 'created_at DESC');
  }

  Future<int> deleteFolder(String folderName, {String? adminId}) async {
    final db = await instance.database;
    
    if (adminId != null && adminId.isNotEmpty) {
      // Delete folder and its recordings for this admin
      await db.delete(
        'recordings',
        where: 'folder_name = ? AND admin_id = ?',
        whereArgs: [folderName, adminId],
      );
      
      return await db.delete(
        'folders',
        where: 'name = ? AND admin_id = ?',
        whereArgs: [folderName, adminId],
      );
    }
    
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

