import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'File Explorer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const FileExplorerPage(),
    );
  }
}

class FileExplorerPage extends StatefulWidget {
  final String? folderPath;

  const FileExplorerPage({super.key, this.folderPath});

  @override
  State<FileExplorerPage> createState() => _FileExplorerPageState();
}

class _FileExplorerPageState extends State<FileExplorerPage> {
  List<FileSystemEntity> _files = [];
  final Map<String, int> _folderSizes = {};
  final Map<String, int> _fileSizes = {};
  final Map<String, bool> _calculatingStatus = {};
  final Map<String, String> _errorMessages = {};
  final Map<String, int> _partialSizes =
      {}; // Track current progress during calculation
  int _totalDirectorySize = 0;
  bool _isCalculatingTotalSize = false;
  bool _hasPermissionIssues = false;
  bool _showSystemDirectories = false; // Toggle for showing system directories
  Timer? _uiUpdateTimer;
  bool _needsResorting = false; // Flag to track if sorting is needed
  
  // Static cache to persist across widget rebuilds and navigation
  static final Map<String, int> _globalFolderSizeCache = {};
  static final Map<String, int> _globalFileSizeCache = {};
  static final Map<String, String> _globalErrorCache = {};

  @override
  void initState() {
    super.initState();
    _checkAndRequestPermissions();
  }

  @override
  void dispose() {
    _uiUpdateTimer?.cancel();
    super.dispose();
  }

  Future<void> _getFolderContents() async {
    setState(() {
      _isCalculatingTotalSize = true;
      _hasPermissionIssues = false;
      _needsResorting = false; // Reset sorting flag
      // Clear previous data
      _folderSizes.clear();
      _fileSizes.clear();
      _calculatingStatus.clear();
      _errorMessages.clear();
      _partialSizes.clear();
    });

    // Start the UI update timer
    _startUIUpdateTimer();

    final directory = widget.folderPath != null
        ? Directory(widget.folderPath!)
        : Directory('/'); // Start from root directory
    try {
      final List<FileSystemEntity> files = [];
      
      // Use a more robust approach to list directory contents
      await for (final entity
          in directory.list(recursive: false, followLinks: false)) {
        // Skip system-protected directories in root to avoid permission issues (unless user wants to see them)
        if ((widget.folderPath == null || widget.folderPath == '/') &&
            !_showSystemDirectories) {
          if (_isSystemProtectedDirectory(entity.path)) {
            print('Skipping system-protected directory: ${entity.path}');
            continue;
          }
        }
        files.add(entity);
      }

      // Initial sort by type (directories first), then by name
      files.sort((a, b) {
        if (a is Directory && b is! Directory) {
          return -1;
        } else if (a is! Directory && b is Directory) {
          return 1;
        } else {
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        }
      });

      if (!mounted) return;
      setState(() {
        _files = files;
      });

      // Initialize calculating status for all items, but check cache first
      for (final file in files) {
        if (file is Directory) {
          // Check if we have cached data for this directory
          if (_globalFolderSizeCache.containsKey(file.path)) {
            final cachedSize = _globalFolderSizeCache[file.path]!;
            _folderSizes[file.path] = cachedSize;
            _calculatingStatus[file.path] = false;
            if (cachedSize < 0) {
              _errorMessages[file.path] =
                  _globalErrorCache[file.path] ?? "Access denied";
              _hasPermissionIssues = true;
            }
          } else {
            _calculatingStatus[file.path] = true;
          }
        } else if (file is File) {
          // Check if we have cached data for this file
          if (_globalFileSizeCache.containsKey(file.path)) {
            final cachedSize = _globalFileSizeCache[file.path]!;
            _fileSizes[file.path] = cachedSize;
            _calculatingStatus[file.path] = false;
            if (cachedSize < 0) {
              _errorMessages[file.path] =
                  _globalErrorCache[file.path] ?? "Access denied";
              _hasPermissionIssues = true;
            }
          } else {
            _calculatingStatus[file.path] = true;
          }
        } else {
          _calculatingStatus[file.path] = true;
        }
      }

      // Sort immediately based on cached data
      _sortFilesBySize();

      // Separate files and directories for different handling
      final fileEntities = files.whereType<File>().toList();
      final directoryEntities = files.whereType<Directory>().toList();

      // Filter out already cached items
      final uncachedFiles = fileEntities
          .where((file) => !_globalFileSizeCache.containsKey(file.path))
          .toList();
      final uncachedDirectories = directoryEntities
          .where((dir) => !_globalFolderSizeCache.containsKey(dir.path))
          .toList();

      // If everything is cached, we still need to ensure proper sorting
      if (uncachedFiles.isEmpty && uncachedDirectories.isEmpty) {
        // All data is cached, update total and do final sort
        print('All data cached - doing immediate sort and total calculation');
        _stopUIUpdateTimer();
        _sortFilesBySize(); // Sort immediately when all data is cached
        _updateTotalSizeAndUI();
        return;
      }

      // Calculate file sizes first (these are quick) - only for uncached files
      final fileFutures =
          uncachedFiles.map((file) => _calculateAndStoreFileSize(file));

      // Start directory calculations in parallel (these take longer) - only for uncached directories
      final directoryFutures =
          uncachedDirectories.map((dir) => _calculateAndStoreFolderSize(dir));

      // Wait for all calculations to complete
      await Future.wait([...fileFutures, ...directoryFutures]);
      
      // Print cache statistics for debugging
      final cacheStats = getCacheStats();
      print(
          'Cache stats - Folders: ${cacheStats['folders']}, Files: ${cacheStats['files']}, Errors: ${cacheStats['errors']}');
      print(
          'Calculated this session - Files: ${uncachedFiles.length}, Directories: ${uncachedDirectories.length}');
      
      // Debug: Print Applications folder size if it exists
      if (_globalFolderSizeCache.containsKey('/Applications')) {
        print(
            'Applications folder cached size: ${_formatBytes(_globalFolderSizeCache['/Applications']!, 2)}');
      }
      if (_folderSizes.containsKey('/Applications')) {
        print(
            'Applications folder local size: ${_formatBytes(_folderSizes['/Applications']!, 2)}');
      }
      
      // Final update when all calculations are complete
      if (mounted) {
        _stopUIUpdateTimer();
        _updateTotalSizeAndUI();
      }
    } catch (e) {
      // Handle any type of exception during directory listing
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print('Error accessing directory: ${directory.path}, error: $e');
      }
      if (!mounted) return;
      setState(() {
        _files = [];
        _hasPermissionIssues = true;
        _isCalculatingTotalSize = false;
      });
      _showPermissionDialog(directory.path, e.toString());
    }
  }

  void _startUIUpdateTimer() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) {
        _updateTotalSizeAndUI();
      }
    });
  }

  void _stopUIUpdateTimer() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
  }

  // Method to clear cache if needed (could be useful for debugging or settings)
  static void clearCache() {
    _globalFolderSizeCache.clear();
    _globalFileSizeCache.clear();
    _globalErrorCache.clear();
  }

  // Method to get cache statistics
  static Map<String, int> getCacheStats() {
    return {
      'folders': _globalFolderSizeCache.length,
      'files': _globalFileSizeCache.length,
      'errors': _globalErrorCache.length,
    };
  }

  // Check and request necessary permissions on app start
  Future<void> _checkAndRequestPermissions() async {
    if (!Platform.isMacOS) {
      _getFolderContents();
      return;
    }

    // Test if we have basic file system access
    final hasBasicAccess = await _testBasicFileAccess();
    final hasFullDiskAccess = await _testFullDiskAccess();

    if (!hasBasicAccess || !hasFullDiskAccess) {
      _showPermissionRequestDialog(hasBasicAccess, hasFullDiskAccess);
    } else {
      _getFolderContents();
    }
  }

  // Test basic file system access
  Future<bool> _testBasicFileAccess() async {
    try {
      final testDir = Directory('/Applications');
      await testDir.list(recursive: false, followLinks: false).take(1).toList();
      return true;
    } catch (e) {
      return false;
    }
  }

  // Test Full Disk Access by trying to access a protected directory
  Future<bool> _testFullDiskAccess() async {
    try {
      // Try to access a directory that requires Full Disk Access
      final testDir = Directory('/Library/Application Support');
      await testDir.list(recursive: false, followLinks: false).take(1).toList();
      return true;
    } catch (e) {
      return false;
    }
  }

  // Show permission request dialog with specific guidance
  void _showPermissionRequestDialog(
      bool hasBasicAccess, bool hasFullDiskAccess) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.security, color: Colors.red),
              SizedBox(width: 8),
              Text('Permissions Required'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This app needs access to your files to calculate storage usage.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning,
                            size: 16, color: Colors.red.shade600),
                        const SizedBox(width: 4),
                        Text(
                          'Required: Full Disk Access',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.red.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Without this permission, many files and applications will show "Access denied".',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'To grant permissions:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Click "Open System Settings" below\n'
                '2. Go to Privacy & Security → Full Disk Access\n'
                '3. Click the lock icon and enter your password\n'
                '4. Enable the toggle for this app\n'
                '5. Return to this app and click "Continue"',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '💡 Tip: After granting permission, restart this app for best results.',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                // Continue with limited access
                _getFolderContents();
              },
              child: const Text('Continue with Limited Access'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openSystemPreferences();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: const Text('Open System Settings'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _calculateAndStoreFolderSize(Directory directory) async {
    // Check if already cached
    if (_globalFolderSizeCache.containsKey(directory.path)) {
      return; // Already calculated and cached
    }

    try {
      // Check if directory is accessible first
      try {
        await directory
            .list(recursive: false, followLinks: false)
            .take(1)
            .toList();
      } catch (e) {
        // If we can't even list the directory, mark as permission error
        if (!mounted) return;
        
        // Update data without triggering immediate UI update
        _folderSizes[directory.path] = -1;
        _calculatingStatus[directory.path] = false;
        _errorMessages[directory.path] = "Permission denied";
        _hasPermissionIssues = true;
        
        // Cache the error result
        _globalFolderSizeCache[directory.path] = -1;
        _globalErrorCache[directory.path] = "Permission denied";
        return;
      }

      final size = await _calculateFolderSize(directory);
      if (!mounted) return;
      
      // Update data without triggering immediate UI update
      _folderSizes[directory.path] = size;
      _calculatingStatus[directory.path] = false;
      // Ensure partial size is cleared when calculation completes
      _partialSizes.remove(directory.path);
      if (size < 0) {
        _errorMessages[directory.path] = "Access denied";
        _hasPermissionIssues = true;
      }
      
      // Mark that we need resorting since size data changed
      _needsResorting = true;
      
      // Cache the result
      _globalFolderSizeCache[directory.path] = size;
      if (size < 0) {
        _globalErrorCache[directory.path] = "Access denied";
      }
    } on PathAccessException catch (e) {
      // Handle PathAccessException specifically (common on macOS)
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error calculating size for directory: ${directory.path}, error: $e');
      }
      if (!mounted) return;
      
      // Update data without triggering immediate UI update
      _folderSizes[directory.path] = -1; // Indicate error
      _calculatingStatus[directory.path] = false;
      _partialSizes.remove(directory.path); // Clean up partial size
      _errorMessages[directory.path] = "Permission denied";
      _hasPermissionIssues = true;
      
      // Cache the error result
      _globalFolderSizeCache[directory.path] = -1;
      _globalErrorCache[directory.path] = "Permission denied";
    } on FileSystemException catch (e) {
      // Handle FileSystemException (including subclasses)
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error calculating size for directory: ${directory.path}, error: $e');
      }
      if (!mounted) return;
      
      // Update data without triggering immediate UI update
      _folderSizes[directory.path] = -1; // Indicate error
      _calculatingStatus[directory.path] = false;
      _partialSizes.remove(directory.path); // Clean up partial size
      _errorMessages[directory.path] = "Permission denied";
      _hasPermissionIssues = true;
      
      // Cache the error result
      _globalFolderSizeCache[directory.path] = -1;
      _globalErrorCache[directory.path] = "Permission denied";
    } catch (e) {
      // Handle any other type of exception
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error calculating size for directory: ${directory.path}, error: $e');
      }
      if (!mounted) return;
      
      // Update data without triggering immediate UI update
      _folderSizes[directory.path] = -1; // Indicate error
      _calculatingStatus[directory.path] = false;
      _partialSizes.remove(directory.path); // Clean up partial size
      _errorMessages[directory.path] = "Permission denied";
      _hasPermissionIssues = true;
      
      // Cache the error result
      _globalFolderSizeCache[directory.path] = -1;
      _globalErrorCache[directory.path] = "Permission denied";
    }
  }

  Future<void> _calculateAndStoreFileSize(File file) async {
    // Check if already cached
    if (_globalFileSizeCache.containsKey(file.path)) {
      return; // Already calculated and cached
    }

    try {
      // For files, we can get size instantly using sync method for better performance
      int size;
      try {
        size = file.lengthSync();
      } catch (e) {
        // Fallback to async if sync fails
        size = await file.length();
      }

      if (!mounted) return;
      
      // Update data without triggering immediate UI update
      _fileSizes[file.path] = size;
      _calculatingStatus[file.path] = false;
      
      // Mark that we need resorting since size data changed
      _needsResorting = true;
      
      // Cache the result
      _globalFileSizeCache[file.path] = size;
    } on FileSystemException catch (e) {
      print('Error calculating size for file: ${file.path}, error: $e');
      if (!mounted) return;
      
      // Update data without triggering immediate UI update
      _fileSizes[file.path] = -1; // Indicate error
      _calculatingStatus[file.path] = false;
      _errorMessages[file.path] = "Permission denied";
      _hasPermissionIssues = true;
      
      // Cache the error result
      _globalFileSizeCache[file.path] = -1;
      _globalErrorCache[file.path] = "Permission denied";
    }
  }

  Future<int> _calculateFolderSize(Directory directory) async {
    try {
      int totalSize = 0;
      bool hasPermissionError = false;
      int accessibleFiles = 0;
      int lastSortTriggerSize = 0; // Track when to trigger resorting
      final String dirPath = directory.path;

      // Initialize partial size
      _partialSizes[dirPath] = 0;

      // Special handling for .app bundles - try to get bundle size first
      if (dirPath.endsWith('.app')) {
        final bundleSize = await _calculateAppBundleSize(directory);
        if (bundleSize >= 0) {
          // Clear partial size when done
          _partialSizes.remove(dirPath);
          return bundleSize;
        }
        // If bundle size calculation fails, continue with regular method
      }

      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final fileSize = await entity.length();
            totalSize += fileSize;
            accessibleFiles++;
            
            // Update partial size without immediate UI update - let the timer handle it
            _partialSizes[dirPath] = totalSize;
            
            // Trigger resorting when size changes significantly (every 10MB)
            if ((totalSize - lastSortTriggerSize) > 10 * 1024 * 1024) {
              _needsResorting = true;
              lastSortTriggerSize = totalSize;
            }

            // Add a small delay every 200 files to make progress visible and allow UI updates
            // Reduced frequency to improve performance
            if (accessibleFiles % 200 == 0) {
              await Future.delayed(const Duration(milliseconds: 2));
            }
          } on PathAccessException {
            hasPermissionError = true;
            // Continue processing other files instead of failing completely
          } on FileSystemException {
            hasPermissionError = true;
            // Continue processing other files instead of failing completely
          } catch (e) {
            hasPermissionError = true;
          }
        }
      }

      // Clear partial size when calculation is complete
      _partialSizes.remove(dirPath);

      // If we have some accessible files, return the partial size
      // Only return -1 if we couldn't access anything at all
      if (hasPermissionError && accessibleFiles == 0) {
        return -1; // Indicate complete permission issues
      }
      return totalSize;
    } on PathAccessException catch (e) {
      // Handle PathAccessException specifically (common on macOS)
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error listing directory for size calculation: ${directory.path}, error: $e');
      }
      // Clear partial size on error
      _partialSizes.remove(directory.path);
      return -1;
    } on FileSystemException catch (e) {
      // Only print errors for specific cases, not common permission denials
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error listing directory for size calculation: ${directory.path}, error: $e');
      }
      // Clear partial size on error
      _partialSizes.remove(directory.path);
      return -1;
    } catch (e) {
      // Handle other types of errors
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error listing directory for size calculation: ${directory.path}, error: $e');
      }
      // Clear partial size on error
      _partialSizes.remove(directory.path);
      return -1;
    }
  }

  // Special method to calculate app bundle size using system tools
  Future<int> _calculateAppBundleSize(Directory appBundle) async {
    try {
      // Use 'du' command to get app bundle size - this often works better than recursive listing
      final result = await Process.run(
        'du',
        ['-sk', appBundle.path],
        runInShell: false,
      );

      if (result.exitCode == 0) {
        final output = result.stdout.toString().trim();
        final sizeStr = output.split('\t')[0];
        final sizeInKB = int.tryParse(sizeStr);
        if (sizeInKB != null) {
          return sizeInKB * 1024; // Convert KB to bytes
        }
      }

      // Fallback: try to get size using Finder's method via AppleScript
      final appleScriptResult = await Process.run(
        'osascript',
        [
          '-e',
          'tell application "Finder" to get size of (POSIX file "${appBundle.path}" as alias)'
        ],
      );

      if (appleScriptResult.exitCode == 0) {
        final sizeStr = appleScriptResult.stdout.toString().trim();
        final size = int.tryParse(sizeStr);
        if (size != null && size > 0) {
          return size;
        }
      }

      return -1; // Indicate we couldn't get the size
    } catch (e) {
      print('Error calculating app bundle size for ${appBundle.path}: $e');
      return -1;
    }
  }

  void _updateTotalSizeAndUI() {
    int total = 0;
    int completedFolders = 0;
    int calculatingFolders = 0;
    int partialSizeCount = 0;

    // Add all folder sizes (only if calculation is complete)
    for (final entry in _folderSizes.entries) {
      final path = entry.key;
      final size = entry.value;
      final isCalculating = _calculatingStatus[path] ?? false;

      if (!isCalculating) {
        completedFolders++;
        // Only add if calculation is complete and size is positive
        if (size > 0) {
          total += size;
        }
      } else {
        calculatingFolders++;
      }
    }
    
    // Add all file sizes (only if calculation is complete)
    for (final entry in _fileSizes.entries) {
      final path = entry.key;
      final size = entry.value;
      // Only add if calculation is complete (not calculating) and size is positive
      if (size > 0 && !(_calculatingStatus[path] ?? false)) {
        total += size;
      }
    }
    
    // Add partial sizes for folders still being calculated (avoid double counting)
    for (final entry in _partialSizes.entries) {
      final path = entry.key;
      final partialSize = entry.value;
      // Only add partial size if the folder is still calculating and we don't have a final size yet
      if (partialSize > 0 &&
          (_calculatingStatus[path] ?? false) &&
          !_folderSizes.containsKey(path)) {
        total += partialSize;
        partialSizeCount++;
      }
    }

    final wasCalculating = _isCalculatingTotalSize;
    final isStillCalculating =
        _calculatingStatus.values.any((calculating) => calculating);

    // Debug logging when total changes significantly
    if ((_totalDirectorySize - total).abs() > 1024 * 1024) {
      // Log if change > 1MB
      print(
          'Total size change: ${_formatBytes(_totalDirectorySize, 2)} → ${_formatBytes(total, 2)}');
      print(
          '  Completed folders: $completedFolders, Calculating: $calculatingFolders, Partial: $partialSizeCount');
    }

    setState(() {
      // Only update if the new total is different to avoid unnecessary rebuilds
      if (_totalDirectorySize != total) {
        _totalDirectorySize = total;
      }
      _isCalculatingTotalSize = isStillCalculating;
    });

    // Only sort if data has changed significantly or we need resorting
    if (_needsResorting || (_isCalculatingTotalSize && _files.length < 50)) {
      // For small lists, sort more frequently for better UX
      // For large lists, rely on the needsResorting flag
      _sortFilesBySize();
      _needsResorting = false;
    }

    // When calculation is finished, stop the timer and do a final sort
    if (wasCalculating && !isStillCalculating) {
      _stopUIUpdateTimer();
      print('All calculations complete - doing final sort');
      _sortFilesBySize();
      _needsResorting = false;
    }
  }

  void _sortFilesBySize() {
    setState(() {
      _files.sort((a, b) {
        // Get sizes for comparison - check both local and cached data
        int sizeA = 0;
        int sizeB = 0;
        bool isCalculatingA = _calculatingStatus[a.path] ?? false;
        bool isCalculatingB = _calculatingStatus[b.path] ?? false;

        // Get size for item A
        if (a is Directory) {
          // First check local map
          if (_folderSizes.containsKey(a.path)) {
            sizeA = _folderSizes[a.path]!;
          } else if (_globalFolderSizeCache.containsKey(a.path)) {
            // If not in local, check global cache
            sizeA = _globalFolderSizeCache[a.path]!;
          } else if (_partialSizes.containsKey(a.path)) {
            // Use partial size if available
            sizeA = _partialSizes[a.path]!;
          }
        } else if (a is File) {
          // First check local map
          if (_fileSizes.containsKey(a.path)) {
            sizeA = _fileSizes[a.path]!;
          } else if (_globalFileSizeCache.containsKey(a.path)) {
            // If not in local, check global cache
            sizeA = _globalFileSizeCache[a.path]!;
          }
        }

        // Get size for item B
        if (b is Directory) {
          // First check local map
          if (_folderSizes.containsKey(b.path)) {
            sizeB = _folderSizes[b.path]!;
          } else if (_globalFolderSizeCache.containsKey(b.path)) {
            // If not in local, check global cache
            sizeB = _globalFolderSizeCache[b.path]!;
          } else if (_partialSizes.containsKey(b.path)) {
            // Use partial size if available
            sizeB = _partialSizes[b.path]!;
          }
        } else if (b is File) {
          // First check local map
          if (_fileSizes.containsKey(b.path)) {
            sizeB = _fileSizes[b.path]!;
          } else if (_globalFileSizeCache.containsKey(b.path)) {
            // If not in local, check global cache
            sizeB = _globalFileSizeCache[b.path]!;
          }
        }

        // Debug print for troubleshooting Applications folder specifically - only during final sort
        if ((a.path.contains('Applications') ||
                b.path.contains('Applications')) &&
            !(_calculatingStatus.values.any((calculating) => calculating))) {
          print(
              'Final Sort: ${a.path.split('/').last} (${_formatBytes(sizeA, 2)}) vs ${b.path.split('/').last} (${_formatBytes(sizeB, 2)})');
        }

        // Handle negative sizes (errors) - put them at the end
        if (sizeA < 0 && sizeB >= 0) return 1;
        if (sizeB < 0 && sizeA >= 0) return -1;
        if (sizeA < 0 && sizeB < 0) {
          // Both have errors, sort by name
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        }

        // If both are still calculating and have zero or partial sizes,
        // maintain original order to avoid constant re-sorting
        if (isCalculatingA && isCalculatingB && sizeA == 0 && sizeB == 0) {
          return 0; // Keep original order
        }

        // Sort by size descending (largest first)
        final sizeComparison = sizeB.compareTo(sizeA);
        if (sizeComparison != 0) {
          return sizeComparison;
        }

        // If sizes are equal, sort by name
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    });
  }

  void _showPermissionDialog(String path, String error) {
    final isSystemDir = _isSystemProtectedDirectory(path);
    final permissionType = _getPermissionType(path);
    final isAppBundle = path.endsWith('.app');
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.security,
                  color: isAppBundle ? Colors.red : Colors.orange),
              const SizedBox(width: 8),
              const Expanded(child: Text('Permission Required')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Cannot access: $path'),
              const SizedBox(height: 8),
              Text('Error: $error'),
              const SizedBox(height: 16),
              if (isAppBundle) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.apps,
                              size: 16, color: Colors.red.shade600),
                          const SizedBox(width: 4),
                          Text(
                            'Application Bundle Access',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.red.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Some application files are protected by macOS. Full Disk Access is required to calculate complete app sizes.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: Colors.blue.shade600),
                          const SizedBox(width: 4),
                          Text(
                            'Required Permission: $permissionType',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.blue.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isSystemDir
                            ? 'This is a protected system directory. Full Disk Access is required.'
                            : 'This directory requires specific permissions to access.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'To allow this app to access files and folders:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'macOS Sonoma (14.0+):\n'
                '1. Open System Settings → Privacy & Security\n'
                '2. Click "Full Disk Access"\n'
                '3. Enable the toggle for this app\n\n'
                'macOS Monterey/Ventura (12.0-13.x):\n'
                '1. Open System Preferences → Security & Privacy\n'
                '2. Click the Privacy tab\n'
                '3. Select "Full Disk Access" from the list\n'
                '4. Click the lock to make changes\n'
                '5. Add this application to the list',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                // Recheck permissions after user potentially granted them
                _recheckPermissions();
              },
              child: const Text('Recheck Permissions'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openSystemPreferences();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: const Text('Open System Settings'),
            ),
          ],
        );
      },
    );
  }

  // Recheck permissions and refresh if needed
  Future<void> _recheckPermissions() async {
    final hasBasicAccess = await _testBasicFileAccess();
    final hasFullDiskAccess = await _testFullDiskAccess();

    if (hasBasicAccess && hasFullDiskAccess) {
      // Clear cache and refresh
      clearCache();
      _getFolderContents();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Permissions granted! Refreshing data...'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                '⚠️ Full Disk Access still required for complete functionality'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _openSystemPreferences() async {
    try {
      if (Platform.isMacOS) {
        // For macOS Sonoma 14.0+ (System Settings)
        final systemSettingsResult = await Process.run(
          'open',
          [
            '-b',
            'com.apple.systempreferences',
            '/System/Library/PreferencePanes/Security.prefPane'
          ],
        );

        if (systemSettingsResult.exitCode == 0) {
          return;
        }

        // Fallback for older macOS versions - try new System Settings first
        var uri = Uri.parse(
            'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles');
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
          return;
        }
        
        // Try opening System Settings/Preferences directly
        final openResult = await Process.run(
            'open', ['/System/Applications/System Preferences.app']);
        if (openResult.exitCode != 0) {
          // Final fallback - try to open System Settings (macOS 13+)
          await Process.run(
              'open', ['/System/Applications/System Settings.app']);
        }
      }
    } catch (e) {
      print('Error opening system preferences: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Please manually open System Settings/Preferences:'),
                SizedBox(height: 4),
                Text('Privacy & Security → Full Disk Access',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Copy Path',
              onPressed: () {
                // You could implement clipboard copy here if needed
              },
            ),
          ),
        );
      }
    }
  }

  void _openFolder(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FileExplorerPage(folderPath: path),
      ),
    );
  }

  Future<void> _openInFinder(String path) async {
    try {
      if (Platform.isMacOS) {
        // Use 'open -R' to reveal the file/folder in Finder
        final result = await Process.run('open', ['-R', path]);
        if (result.exitCode != 0) {
          print('Error opening in Finder: ${result.stderr}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Could not open in Finder'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e) {
      print('Error opening in Finder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open in Finder'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  String _formatBytes(int bytes, int decimals) {
    if (bytes < 0) return "Access denied";
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  String _getDisplayTitle() {
    if (widget.folderPath == null || widget.folderPath == '/') {
      return 'Macintosh HD'; // Root directory
    }
    
    // Extract the folder name from the path
    final parts = widget.folderPath!.split('/');
    return parts.isNotEmpty ? parts.last : 'Root';
  }

  bool _isSystemProtectedDirectory(String path) {
    // List of directories that typically require special permissions on macOS
    const protectedDirs = [
      '/System',
      '/private',
      '/usr',
      '/bin',
      '/sbin',
      '/var',
      '/tmp',
      '/etc',
      '/dev',
      '/Library/Application Support',
      '/Library/Caches',
      '/Library/Logs',
    ];

    // For root level, also check these specific directories
    if (path == '/System' ||
        path == '/private' ||
        path == '/usr' ||
        path == '/dev' ||
        path == '/Library' ||
        path == '/bin' ||
        path == '/sbin' ||
        path == '/var' ||
        path == '/tmp' ||
        path == '/etc') {
      return true;
    }

    return protectedDirs.any((dir) => path.startsWith(dir));
  }

  bool _isExpectedPermissionError(String path, String errorMessage) {
    // Common directories and patterns that we expect to have permission issues
    const expectedPaths = [
      '/Volumes',
      '/dev',
      '/Library/Application Support/Apple',
      '/Library/Application Support/com.apple',
      '/Library/Application Support/Apple/ParentalControls',
      '/System/Library',
      '/System/Library/DirectoryServices',
      '/Applications/flutter',
      '/Applications/Xcode',
      '/private',
      '/usr',
      '/bin',
      '/sbin',
      '/var',
      '/tmp',
      '/etc',
    ];

    // User directories that require special permissions
    const userProtectedPaths = [
      '/Users/',
      'Desktop/',
      'Documents/',
      'Downloads/',
      'Pictures/',
      'Movies/',
      'Music/',
      'Library/',
      '.Trash/',
    ];

    // Check if the path starts with any expected problematic directory
    final isExpectedPath = expectedPaths.any((dir) => path.startsWith(dir));

    // Check for user protected directories
    final isUserProtectedPath =
        userProtectedPaths.any((dir) => path.contains(dir));

    // Also check for app bundles and frameworks which commonly have permission issues
    final isAppBundle = path.contains('.app/') ||
        path.contains('.framework/') ||
        path.contains('.xcframework/');

    // Check for mounted volumes
    final isMountedVolume = path.startsWith('/Volumes/');

    // Check for common permission error messages
    final isPermissionError = errorMessage.contains('Permission denied') ||
        errorMessage.contains('Operation not permitted') ||
        errorMessage.contains('PathAccessException') ||
        errorMessage.contains('Not a directory') ||
        errorMessage.contains('Directory listing failed');

    return (isExpectedPath ||
            isAppBundle ||
            isMountedVolume ||
            isUserProtectedPath) &&
        isPermissionError;
  }

  String _getPermissionType(String path) {
    if (path.contains('/Desktop/')) return 'Desktop Access';
    if (path.contains('/Documents/')) return 'Documents Access';
    if (path.contains('/Downloads/')) return 'Downloads Access';
    if (path.contains('/Pictures/')) return 'Photos Access';
    if (path.contains('/Movies/') || path.contains('/Music/'))
      return 'Media Access';
    if (path.contains('/Library/')) return 'Library Access';
    if (path.startsWith('/System') ||
        path.startsWith('/usr') ||
        path.startsWith('/private')) {
      return 'Full Disk Access';
    }
    return 'File Access';
  }

  Future<void> _clearCaches() async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const AlertDialog(
          title: Text('Clearing Caches'),
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Clearing system and user caches...'),
            ],
          ),
        );
      },
    );

    try {
      final List<String> results = [];
      int successCount = 0;
      int totalOperations = 3;

      // Clear system caches (requires sudo)
      try {
        final systemResult = await Process.run(
          'osascript',
          [
            '-e',
            'do shell script "find /Library/Caches -mindepth 1 -delete 2>/dev/null || true" with administrator privileges'
          ],
        );
        if (systemResult.exitCode == 0) {
          results.add('✓ System caches cleared');
          successCount++;
        } else {
          results.add('⚠️ System caches: ${systemResult.stderr}');
        }
      } catch (e) {
        results.add('❌ System caches: Permission denied or canceled');
      }

      // Clear user caches
      try {
        final userHome = Platform.environment['HOME'] ?? '';
        if (userHome.isNotEmpty) {
          final userCachesResult = await Process.run(
            'find',
            ['$userHome/Library/Caches', '-mindepth', '1', '-delete'],
            runInShell: false,
          );
          if (userCachesResult.exitCode == 0) {
            results.add('✓ User caches cleared');
            successCount++;
          } else {
            results.add('⚠️ User caches: Some files could not be deleted');
          }
        } else {
          results.add('❌ User caches: Could not determine home directory');
        }
      } catch (e) {
        results.add('❌ User caches: ${e.toString()}');
      }

      // Clear user logs
      try {
        final userHome = Platform.environment['HOME'] ?? '';
        if (userHome.isNotEmpty) {
          final userLogsResult = await Process.run(
            'find',
            ['$userHome/Library/Logs', '-mindepth', '1', '-delete'],
            runInShell: false,
          );
          if (userLogsResult.exitCode == 0) {
            results.add('✓ User logs cleared');
            successCount++;
          } else {
            results.add('⚠️ User logs: Some files could not be deleted');
          }
        } else {
          results.add('❌ User logs: Could not determine home directory');
        }
      } catch (e) {
        results.add('❌ User logs: ${e.toString()}');
      }

      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
      }

      // Show detailed results
      if (mounted) {
        final bool allSuccess = successCount == totalOperations;
        final bool partialSuccess = successCount > 0;

        // Show results dialog
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Row(
                children: [
                  Icon(
                    allSuccess
                        ? Icons.check_circle
                        : partialSuccess
                            ? Icons.warning
                            : Icons.error,
                    color: allSuccess
                        ? Colors.green
                        : partialSuccess
                            ? Colors.orange
                            : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Text(allSuccess
                      ? 'Success'
                      : partialSuccess
                          ? 'Partial Success'
                          : 'Failed'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '$successCount of $totalOperations operations completed:'),
                  const SizedBox(height: 12),
                  ...results.map((result) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child:
                            Text(result, style: const TextStyle(fontSize: 12)),
                      )),
                  if (!allSuccess) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '💡 Some files may be in use or require different permissions. This is normal.',
                        style: TextStyle(
                            fontSize: 11, fontStyle: FontStyle.italic),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );

        // Also show a brief snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(allSuccess
                ? 'All caches cleared successfully!'
                : partialSuccess
                    ? 'Caches partially cleared ($successCount/$totalOperations)'
                    : 'Cache clearing failed'),
            backgroundColor: allSuccess
                ? Colors.green
                : partialSuccess
                    ? Colors.orange
                    : Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );

        // Refresh the current view if any operation succeeded
        if (partialSuccess) {
          // Clear our internal cache as well since sizes may have changed
          clearCache();
          _getFolderContents();
        }
      }
    } catch (e) {
      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
      }

      print('Error clearing caches: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error clearing caches: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_getDisplayTitle()),
        leading: widget.folderPath != null && widget.folderPath != '/'
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              )
            : null,
        actions: [
          // Permission recheck button
          if (Platform.isMacOS)
            IconButton(
              icon: Icon(
                Icons.verified_user,
                color: _hasPermissionIssues ? Colors.red : Colors.green,
              ),
              onPressed: _recheckPermissions,
              tooltip: _hasPermissionIssues
                  ? 'Recheck Permissions (Issues detected)'
                  : 'Recheck Permissions (All good)',
            ),
          // Cache clear button (only show in root)
          if (widget.folderPath == null || widget.folderPath == '/')
            IconButton(
              icon: const Icon(Icons.cleaning_services, color: Colors.red),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Row(
                        children: [
                          Icon(Icons.cleaning_services, color: Colors.red),
                          SizedBox(width: 8),
                          Text('Clear Caches'),
                        ],
                      ),
                      content: const Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('This will clear:'),
                          SizedBox(height: 8),
                          Text('• System caches (/Library/Caches/)'),
                          Text('• User caches (~/Library/Caches/)'),
                          Text('• User logs (~/Library/Logs/)'),
                          SizedBox(height: 12),
                          Text(
                            'Administrator privileges will be required for system caches.',
                            style: TextStyle(
                                fontSize: 12, fontStyle: FontStyle.italic),
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _clearCaches();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Clear Caches'),
                        ),
                      ],
                    );
                  },
                );
              },
              tooltip: 'Clear System and User Caches',
            ),
          // Toggle for system directories (only show in root)
          if (widget.folderPath == null || widget.folderPath == '/')
            IconButton(
              icon: Icon(
                _showSystemDirectories
                    ? Icons.visibility
                    : Icons.visibility_off,
                color: _showSystemDirectories ? Colors.blue : Colors.grey,
              ),
              onPressed: () {
                setState(() {
                  _showSystemDirectories = !_showSystemDirectories;
                });
                // Refresh the folder contents with new setting
                _getFolderContents();
              },
              tooltip: _showSystemDirectories
                  ? 'Hide System Directories'
                  : 'Show System Directories (requires Full Disk Access)',
            ),
          if (_hasPermissionIssues)
            IconButton(
              icon: const Icon(Icons.warning, color: Colors.orange),
              onPressed: () => _showPermissionDialog(
                widget.folderPath ?? 'Current directory',
                'Some files or folders cannot be accessed due to permission restrictions',
              ),
              tooltip: 'Permission Issues Detected',
            ),
        ],
      ),
      body: Column(
        children: [
          // Status bar showing total directory size
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            color: _hasPermissionIssues
                ? Colors.orange.shade50
                : Colors.blue.shade50,
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      _hasPermissionIssues ? Icons.warning : Icons.info_outline,
                      color: _hasPermissionIssues ? Colors.orange : Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Total Size: ',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _hasPermissionIssues
                            ? Colors.orange.shade800
                            : Colors.blue.shade800,
                      ),
                    ),
                    _isCalculatingTotalSize
                        ? Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _hasPermissionIssues
                                      ? Colors.orange.shade600
                                      : Colors.blue.shade600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                  '${_formatBytes(_totalDirectorySize, 2)}...'),
                            ],
                          )
                        : Text(
                            _formatBytes(_totalDirectorySize, 2),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: _hasPermissionIssues
                                  ? Colors.orange.shade700
                                  : Colors.blue.shade700,
                            ),
                          ),
                  ],
                ),
                if (_hasPermissionIssues) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 16, color: Colors.orange),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Some items require additional permissions. Tap warning icon for details.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else if (!_isCalculatingTotalSize) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.sort_by_alpha,
                          size: 16, color: Colors.blue.shade600),
                      const SizedBox(width: 4),
                      Text(
                        'Sorted by size (largest first)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue.shade600,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // File list
          Expanded(
            child: ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index];
                final isDirectory = file is Directory;
                final isCalculating = _calculatingStatus[file.path] ?? false;
                final hasError = _errorMessages.containsKey(file.path);

                String sizeText = '';
                if (hasError) {
                  sizeText = _errorMessages[file.path]!;
                  // Add specific message for app bundles
                  if (file.path.endsWith('.app')) {
                    sizeText = 'Requires Full Disk Access';
                  }
                } else if (isDirectory) {
                  final size = _folderSizes[file.path];
                  final partialSize = _partialSizes[file.path];
                  
                  if (size != null) {
                    if (size >= 0) {
                      sizeText = _formatBytes(size, 2);
                      // Add indicator if this might be partial due to permissions
                      if (_isSystemProtectedDirectory(file.path)) {
                        sizeText += ' (partial)';
                      }
                    } else {
                      sizeText = _formatBytes(
                          size, 2); // This will show "Access denied"
                    }
                  } else if (isCalculating &&
                      partialSize != null &&
                      partialSize > 0) {
                    // Show current progress instead of "Computing..."
                    sizeText = '${_formatBytes(partialSize, 2)}...';
                  } else if (isCalculating) {
                    sizeText = 'Computing...';
                  } else {
                    sizeText = 'Unknown';
                  }
                } else if (file is File) {
                  final size = _fileSizes[file.path];
                  if (size != null) {
                    sizeText = _formatBytes(size, 2);
                  } else if (isCalculating) {
                    sizeText = 'Reading...';
                  } else {
                    sizeText = 'Unknown';
                  }
                } else {
                  sizeText = file is Link ? 'Symbolic Link' : 'Unknown';
                }

                return ListTile(
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isDirectory ? Icons.folder : Icons.insert_drive_file,
                        color: hasError ? Colors.orange : null,
                      ),
                      if (hasError)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.warning,
                            size: 16,
                            color: Colors.orange,
                          ),
                        ),
                    ],
                  ),
                  title: Text(
                    file.path.split('/').last,
                    style: TextStyle(
                      color: hasError ? Colors.orange.shade700 : null,
                    ),
                  ),
                  subtitle: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Text(
                              sizeText,
                              style: TextStyle(
                                color: hasError ? Colors.orange.shade600 : null,
                                fontStyle: hasError ? FontStyle.italic : null,
                              ),
                            ),
                            if (isCalculating) ...[
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    hasError
                                        ? Colors.orange.shade400
                                        : Colors.blue.shade400,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Finder button
                      IconButton(
                        icon: Icon(
                          Icons.folder_open,
                          size: 20,
                          color: Colors.grey.shade600,
                        ),
                        onPressed: () => _openInFinder(file.path),
                        tooltip: 'Open in Finder',
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                      // Arrow for folders
                      if (isDirectory && !hasError)
                        IconButton(
                          icon: Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                            color: Colors.grey.shade600,
                          ),
                          onPressed: () => _openFolder(file.path),
                          tooltip: 'Open folder',
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                    ],
                  ),
                  onTap: () {
                    if (isDirectory && !hasError) {
                      _openFolder(file.path);
                    } else {
                      _openInFinder(file.path);
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
