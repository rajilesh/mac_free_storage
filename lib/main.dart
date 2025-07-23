import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';

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
  List<FileSystemEntity> files = [];
  List<String> logs = [];
  bool isLoading = false;
  List<Map<String, dynamic>> folderSizes = [];

  @override
  void initState() {
    super.initState();
    _listFiles();
  }

  void _listFiles() async {
    setState(() {
      isLoading = true;
      files.clear();
      folderSizes.clear();
    });

    final directory = widget.folderPath != null
        ? Directory(widget.folderPath!)
        : Directory('/'); // Root directory
    print('Accessing directory: ${directory.path}');

    try {
      final allFiles =
          await directory.list(recursive: false, followLinks: false).toList();

      setState(() {
        files.addAll(allFiles);
      });

      final folderSizeFutures = <Future<Map<String, dynamic>>>[];
      for (var file in allFiles) {
        if (file is Directory) {
          folderSizeFutures.add(_calculateFolderSize(file)
              .then((size) => {'entity': file, 'size': size}));
        }
      }

      final calculatedSizes = await Future.wait(folderSizeFutures);

      setState(() {
        folderSizes.addAll(calculatedSizes);
        files.sort((a, b) {
          final aSize = a is Directory
              ? folderSizes.firstWhere(
                  (e) => e['entity'] == a,
                  orElse: () => {'size': 0},
                )['size']
              : a.statSync().size;
          final bSize = b is Directory
              ? folderSizes.firstWhere(
                  (e) => e['entity'] == b,
                  orElse: () => {'size': 0},
                )['size']
              : b.statSync().size;
          return bSize.compareTo(aSize);
        });
        isLoading = false;
      });
    } catch (e) {
      print('Error listing files: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<int> _calculateFolderSize(Directory directory) async {
    int totalSize = 0;
    try {
      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            totalSize += await entity.length();
          } catch (e) {
            print('Could not read file length: ${entity.path}');
          }
        }
      }
    } catch (e) {
      print('Error calculating size for ${directory.path}: $e');
    }
    return totalSize;
  }

  void _openFileLocation(String path) {
    OpenFile.open(path);
  }

  void _loadFileChunkWise(String filePath) async {
    setState(() {
      isLoading = true;
      logs.clear();
    });

    final file = File(filePath);
    final stream = file.openRead();

    stream.transform(utf8.decoder).transform(LineSplitter()).listen(
      (line) {
        setState(() {
          logs.add(line);
        });
      },
      onDone: () {
        setState(() {
          isLoading = false;
        });
      },
      onError: (error) {
        setState(() {
          isLoading = false;
          logs.add('Error: $error');
        });
      },
    );
  }

  void _openFolder(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FileExplorerPage(folderPath: path),
      ),
    );
  }

  int _calculateTotalSize() {
    int totalSize = 0;

    for (var file in files) {
      if (file is Directory) {
        totalSize += folderSizes.firstWhere(
          (e) => e['entity'] == file,
          orElse: () => {'size': 0},
        )['size'] as int;
      } else {
        totalSize += file.statSync().size;
      }
    }

    return totalSize;
  }

  @override
  Widget build(BuildContext context) {
    final totalSize = _calculateTotalSize();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.folderPath ?? 'File Explorer'),
            Text(
              'Total Size: ' +
                  (totalSize > (1024 * 1024 * 1024)
                      ? (totalSize / (1024 * 1024 * 1024)).toStringAsFixed(1) +
                          ' GB'
                      : (totalSize / (1024 * 1024)).toStringAsFixed(1) + ' MB'),
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ],
        ),
        backgroundColor: Colors.blueAccent,
      ),
      body: isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blueAccent),
              ),
            )
          : files.isEmpty
              ? const Center(
                  child: Text(
                    'No files found',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8.0),
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    final fileName = file.path.split('/').last;
                    final isDirectory = file is Directory;
                    final size = isDirectory
                        ? folderSizes.firstWhere(
                            (e) => e['entity'] == file,
                            orElse: () => {'size': 0},
                          )['size'] as int
                        : file.statSync().size;

                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 4.0),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8.0),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withOpacity(0.5),
                            spreadRadius: 2,
                            blurRadius: 5,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ListTile(
                        onTap: () => _openFileLocation(file.path),
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isDirectory
                                  ? size > (1024 * 1024 * 1024)
                                      ? (size / (1024 * 1024 * 1024))
                                              .toStringAsFixed(1) +
                                          ' GB'
                                      : (size / (1024 * 1024))
                                              .toStringAsFixed(1) +
                                          ' MB'
                                  : size > (1024 * 1024 * 1024)
                                      ? (size / (1024 * 1024 * 1024))
                                              .toStringAsFixed(1) +
                                          ' GB'
                                      : (size / (1024 * 1024))
                                              .toStringAsFixed(1) +
                                          ' MB',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              isDirectory
                                  ? Icons.folder
                                  : Icons.insert_drive_file,
                              color: isDirectory ? Colors.orange : Colors.blue,
                            ),
                          ],
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        trailing: isDirectory
                            ? IconButton(
                                icon: const Icon(Icons.arrow_forward_ios,
                                    size: 16),
                                onPressed: () => _openFolder(file.path),
                              )
                            : null,
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _loadFileChunkWise('/path/to/your/file.txt'),
        backgroundColor: Colors.blueAccent,
        child: const Icon(Icons.file_download),
      ),
    );
  }
}
