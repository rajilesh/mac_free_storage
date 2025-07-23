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
  Timer? _uiUpdateTimer;
  
  // Static cache to persist across widget rebuilds and navigation
  static final Map<String, int> _globalFolderSizeCache = {};
  static final Map<String, int> _globalFileSizeCache = {};
  static final Map<String, String> _globalErrorCache = {};

  @override
  void initState() {
    super.initState();
    _getFolderContents();
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
    _uiUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
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
        setState(() {
          _folderSizes[directory.path] = -1;
          _calculatingStatus[directory.path] = false;
          _errorMessages[directory.path] = "Permission denied";
          _hasPermissionIssues = true;
        });
        // Cache the error result
        _globalFolderSizeCache[directory.path] = -1;
        _globalErrorCache[directory.path] = "Permission denied";
        return;
      }

      final size = await _calculateFolderSize(directory);
      if (!mounted) return;
      setState(() {
        _folderSizes[directory.path] = size;
        _calculatingStatus[directory.path] = false;
        if (size < 0) {
          _errorMessages[directory.path] = "Access denied";
          _hasPermissionIssues = true;
        }
      });
      
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
      setState(() {
        _folderSizes[directory.path] = -1; // Indicate error
        _calculatingStatus[directory.path] = false;
        _errorMessages[directory.path] = "Permission denied";
        _hasPermissionIssues = true;
      });
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
      setState(() {
        _folderSizes[directory.path] = -1; // Indicate error
        _calculatingStatus[directory.path] = false;
        _errorMessages[directory.path] = "Permission denied";
        _hasPermissionIssues = true;
      });
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
      setState(() {
        _folderSizes[directory.path] = -1; // Indicate error
        _calculatingStatus[directory.path] = false;
        _errorMessages[directory.path] = "Permission denied";
        _hasPermissionIssues = true;
      });
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
      setState(() {
        _fileSizes[file.path] = size;
        _calculatingStatus[file.path] = false;
      });
      
      // Cache the result
      _globalFileSizeCache[file.path] = size;
    } on FileSystemException catch (e) {
      print('Error calculating size for file: ${file.path}, error: $e');
      if (!mounted) return;
      setState(() {
        _fileSizes[file.path] = -1; // Indicate error
        _calculatingStatus[file.path] = false;
        _errorMessages[file.path] = "Permission denied";
        _hasPermissionIssues = true;
      });
      
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
      final String dirPath = directory.path;

      // Initialize partial size
      _partialSizes[dirPath] = 0;

      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final fileSize = await entity.length();
            totalSize += fileSize;
            accessibleFiles++;
            
            // Update partial size but don't trigger UI update here
            _partialSizes[dirPath] = totalSize;
            
            // Add a small delay to make the progress visible for small directories
            if (accessibleFiles % 10 == 0) {
              await Future.delayed(const Duration(milliseconds: 1));
            }
          } on PathAccessException {
            // Don't print permission errors for individual files as they're expected
            hasPermissionError = true;
            // Continue processing other files instead of failing completely
          } on FileSystemException {
            // Don't print permission errors for individual files as they're expected
            hasPermissionError = true;
            // Continue processing other files instead of failing completely
          } catch (e) {
            // Handle other unexpected errors
            hasPermissionError = true;
          }
        }
      }

      // Clear partial size when done
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
      return -1;
    } on FileSystemException catch (e) {
      // Only print errors for specific cases, not common permission denials
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error listing directory for size calculation: ${directory.path}, error: $e');
      }
      return -1;
    } catch (e) {
      // Handle other types of errors
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error listing directory for size calculation: ${directory.path}, error: $e');
      }
      return -1;
    }
  }

  void _updateTotalSizeAndUI() {
    int total = 0;

    // Add all folder sizes
    for (final size in _folderSizes.values) {
      if (size > 0) total += size;
    }
    
    // Add all file sizes
    for (final size in _fileSizes.values) {
      if (size > 0) total += size;
    }
    
    // Add partial sizes for folders still being calculated
    for (final size in _partialSizes.values) {
      if (size > 0) total += size;
    }

    final wasCalculating = _isCalculatingTotalSize;
    final isStillCalculating =
        _calculatingStatus.values.any((calculating) => calculating);

    setState(() {
      _totalDirectorySize = total;
      _isCalculatingTotalSize = isStillCalculating;
    });

    // Sort regularly during calculation to show updated order as sizes are computed
    _sortFilesBySize();

    // When calculation is finished, stop the timer and do a final sort
    if (wasCalculating && !isStillCalculating) {
      _stopUIUpdateTimer();
      print('All calculations complete - doing final sort');
      _sortFilesBySize();
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
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.security, color: Colors.orange),
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
                          ? 'This is a protected system directory. Access may be restricted even with Full Disk Access.'
                          : 'This directory requires specific permissions to access.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'To allow this app to access files and folders:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                permissionType == 'Full Disk Access'
                    ? '1. Open System Preferences → Security & Privacy\n'
                        '2. Click the Privacy tab\n'
                        '3. Select "Full Disk Access" from the list\n'
                        '4. Click the lock to make changes\n'
                        '5. Add this application to the list'
                    : '1. Open System Preferences → Security & Privacy\n'
                        '2. Click the Privacy tab\n'
                        '3. Select "$permissionType" from the list\n'
                        '4. Click the lock to make changes\n'
                        '5. Add this application to the list\n\n'
                        'Or enable "Full Disk Access" for complete access.',
                style: const TextStyle(fontSize: 14),
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
                _openSystemPreferences();
              },
              child: const Text('Open System Preferences'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSystemPreferences() async {
    try {
      if (Platform.isMacOS) {
        final uri = Uri.parse(
            'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles');
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        } else {
          // Fallback to general security preferences
          final fallbackUri = Uri.parse(
              'x-apple.systempreferences:com.apple.preference.security');
          if (await canLaunchUrl(fallbackUri)) {
            await launchUrl(fallbackUri);
          }
        }
      }
    } catch (e) {
      print('Error opening system preferences: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Please manually open System Preferences > Security & Privacy > Privacy > Full Disk Access'),
            duration: Duration(seconds: 5),
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
