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
  int _totalDirectorySize = 0;
  bool _isCalculatingTotalSize = false;
  bool _hasPermissionIssues = false;

  @override
  void initState() {
    super.initState();
    _getFolderContents();
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
    });

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

      // Initialize calculating status for all items
      for (final file in files) {
        _calculatingStatus[file.path] = true;
      }

      // Separate files and directories for different handling
      final fileEntities = files.whereType<File>().toList();
      final directoryEntities = files.whereType<Directory>().toList();

      // Calculate file sizes first (these are quick)
      final fileFutures =
          fileEntities.map((file) => _calculateAndStoreFileSize(file));

      // Start directory calculations in parallel (these take longer)
      final directoryFutures =
          directoryEntities.map((dir) => _calculateAndStoreFolderSize(dir));

      // Wait for all calculations to complete
      await Future.wait([...fileFutures, ...directoryFutures]);
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

  Future<void> _calculateAndStoreFolderSize(Directory directory) async {
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
        _updateTotalSize();
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
      _updateTotalSize();
    } catch (e) {
      // Handle any type of exception (FileSystemException, PathAccessException, etc.)
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
      _updateTotalSize();
    }
  }

  Future<void> _calculateAndStoreFileSize(File file) async {
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
      _updateTotalSize();
    } on FileSystemException catch (e) {
      print('Error calculating size for file: ${file.path}, error: $e');
      if (!mounted) return;
      setState(() {
        _fileSizes[file.path] = -1; // Indicate error
        _calculatingStatus[file.path] = false;
        _errorMessages[file.path] = "Permission denied";
        _hasPermissionIssues = true;
      });
      _updateTotalSize();
    }
  }

  Future<int> _calculateFolderSize(Directory directory) async {
    try {
      int totalSize = 0;
      bool hasPermissionError = false;
      int accessibleFiles = 0;

      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final fileSize = await entity.length();
            totalSize += fileSize;
            accessibleFiles++;
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

      // If we have some accessible files, return the partial size
      // Only return -1 if we couldn't access anything at all
      if (hasPermissionError && accessibleFiles == 0) {
        return -1; // Indicate complete permission issues
      }
      return totalSize;
    } on FileSystemException catch (e) {
      // Only print errors for specific cases, not common permission denials
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error listing directory for size calculation: ${directory.path}, error: $e');
      }
      return -1;
    } catch (e) {
      // Handle other types of errors (like PathAccessException)
      if (!_isExpectedPermissionError(directory.path, e.toString())) {
        print(
            'Error listing directory for size calculation: ${directory.path}, error: $e');
      }
      return -1;
    }
  }

  void _updateTotalSize() {
    int total = 0;

    // Add all folder sizes
    for (final size in _folderSizes.values) {
      if (size > 0) total += size;
    }
    
    // Add all file sizes
    for (final size in _fileSizes.values) {
      if (size > 0) total += size;
    }

    setState(() {
      _totalDirectorySize = total;
      // Only mark as not calculating when all items are done
      _isCalculatingTotalSize =
          _calculatingStatus.values.any((calculating) => calculating);
    });
  }

  void _showPermissionDialog(String path, String error) {
    final isSystemDir = _isSystemProtectedDirectory(path);
    
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
              if (isSystemDir) ...[
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
                            'System Directory',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.blue.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'This is a protected system directory. Access may be restricted even with Full Disk Access.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              const Text(
                'To allow this app to access files and folders:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Open System Preferences → Security & Privacy\n'
                '2. Click the Privacy tab\n'
                '3. Select "Full Disk Access" from the list\n'
                '4. Click the lock to make changes\n'
                '5. Add this application to the list',
                style: TextStyle(fontSize: 14),
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
      '/System/Library',
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

    // Check if the path starts with any expected problematic directory
    final isExpectedPath = expectedPaths.any((dir) => path.startsWith(dir));

    // Also check for app bundles and frameworks which commonly have permission issues
    final isAppBundle = path.contains('.app/') ||
        path.contains('.framework/') ||
        path.contains('.xcframework/');

    // Check for mounted volumes
    final isMountedVolume = path.startsWith('/Volumes/');

    // Check for common permission error messages
    final isPermissionError = errorMessage.contains('Permission denied') ||
        errorMessage.contains('Operation not permitted') ||
        errorMessage.contains('PathAccessException');

    return (isExpectedPath || isAppBundle || isMountedVolume) &&
        isPermissionError;
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
                              const Text('Calculating...'),
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
