import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ipfs/ipfs_transfer_service.dart';
import 'ipfs/remote_upload_client.dart';

class UploadHistoryEntry {
  const UploadHistoryEntry({
    required this.fileName,
    required this.cid,
    required this.provider,
    required this.targetName,
    required this.mimeType,
    required this.uploadedAt,
    required this.isImage,
    required this.isCustomProvider,
    this.thumbnailBase64,
  });

  final String fileName;
  final String cid;
  final String provider;
  final String targetName;
  final String mimeType;
  final DateTime uploadedAt;
  final bool isImage;
  final bool isCustomProvider;
  final String? thumbnailBase64;

  Map<String, dynamic> toJson() => {
    'fileName': fileName,
    'cid': cid,
    'provider': provider,
    'target': targetName,
    'mimeType': mimeType,
    'uploadedAt': uploadedAt.toIso8601String(),
    'isImage': isImage,
    'isCustomProvider': isCustomProvider,
    'thumbnail': thumbnailBase64,
  };

  static UploadHistoryEntry? fromJson(Map<String, dynamic> json) {
    final uploadedAt = DateTime.tryParse(json['uploadedAt'] as String? ?? '');
    if (uploadedAt == null) {
      return null;
    }
    return UploadHistoryEntry(
      fileName: json['fileName'] as String? ?? 'Unknown file',
      cid: json['cid'] as String? ?? '',
      provider: json['provider'] as String? ?? 'Unknown provider',
      targetName: json['target'] as String? ?? RemoteUploadTarget.pinata.name,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      uploadedAt: uploadedAt,
      isImage: json['isImage'] as bool? ?? false,
      isCustomProvider: json['isCustomProvider'] as bool? ?? false,
      thumbnailBase64: json['thumbnail'] as String?,
    );
  }
}

class HistoryPageResult {
  const HistoryPageResult({this.selectedEntry, this.deletedEntries = const []});

  final UploadHistoryEntry? selectedEntry;
  final List<UploadHistoryEntry> deletedEntries;
}

class HistoryStore {
  HistoryStore({required Future<SharedPreferences> prefsFuture})
    : _prefsFuture = prefsFuture;

  static const _prefsKey = 'relay.uploadHistory';
  final Future<SharedPreferences> _prefsFuture;
  final List<UploadHistoryEntry> entries = [];

  Future<void> restore() async {
    try {
      final prefs = await _prefsFuture;
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw) as List<dynamic>;
      entries
        ..clear()
        ..addAll(
          decoded
              .whereType<Map<String, dynamic>>()
              .map(UploadHistoryEntry.fromJson)
              .whereType<UploadHistoryEntry>(),
        );
    } catch (_) {
      // Ignore malformed or unavailable local history.
    }
  }

  Future<void> recordUpload({
    required PublishedImage image,
    required String provider,
    required bool isCustomProvider,
  }) async {
    final thumbnail = image.isImage
        ? await _createThumbnail(image.bytes)
        : null;
    entries.insert(
      0,
      UploadHistoryEntry(
        fileName: image.fileName,
        cid: image.cid,
        provider: provider,
        targetName: image.remoteTarget.name,
        mimeType: image.mimeType,
        uploadedAt: DateTime.now(),
        isImage: image.isImage,
        isCustomProvider: isCustomProvider,
        thumbnailBase64: thumbnail == null ? null : base64Encode(thumbnail),
      ),
    );
    await persist();
  }

  Future<void> recordReceived({
    required DownloadedImage image,
    required String provider,
    required String targetName,
    required bool isCustomProvider,
  }) async {
    if (entries.any((entry) => entry.cid == image.cid)) {
      return;
    }
    final thumbnail = image.isImage
        ? await _createThumbnail(image.bytes)
        : null;
    entries.insert(
      0,
      UploadHistoryEntry(
        fileName: image.fileName,
        cid: image.cid,
        provider: provider,
        targetName: targetName,
        mimeType: image.mimeType,
        uploadedAt: DateTime.now(),
        isImage: image.isImage,
        isCustomProvider: isCustomProvider,
        thumbnailBase64: thumbnail == null ? null : base64Encode(thumbnail),
      ),
    );
    await persist();
  }

  Future<void> removeEntries(Iterable<UploadHistoryEntry> removed) async {
    final cids = removed.map((entry) => entry.cid).toSet();
    entries.removeWhere((entry) => cids.contains(entry.cid));
    await persist();
  }

  Future<void> persist() async {
    try {
      final prefs = await _prefsFuture;
      await prefs.setString(
        _prefsKey,
        jsonEncode(entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (_) {
      // Completed transfers remain usable if local history cannot be saved.
    }
  }

  Future<Uint8List?> _createThumbnail(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 96,
        targetHeight: 96,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final thumbnail = await image.toByteData(format: ui.ImageByteFormat.png);
      return thumbnail?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.entries});

  final List<UploadHistoryEntry> entries;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final ScrollController _scrollController = ScrollController();
  final Set<UploadHistoryEntry> _selectedEntries = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _formatDateTime(DateTime dateTime) {
    final localTime = dateTime.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${localTime.year}-${twoDigits(localTime.month)}-${twoDigits(localTime.day)} '
        '${twoDigits(localTime.hour)}:${twoDigits(localTime.minute)}';
  }

  Widget _thumbnail(UploadHistoryEntry entry) {
    if (entry.isImage && entry.thumbnailBase64 != null) {
      try {
        return Image.memory(
          base64Decode(entry.thumbnailBase64!),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              const Icon(Icons.insert_drive_file_outlined),
        );
      } catch (_) {
        return const Icon(Icons.insert_drive_file_outlined);
      }
    }
    return const Icon(Icons.insert_drive_file_outlined);
  }

  void _toggleSelection(UploadHistoryEntry entry) {
    setState(() {
      if (!_selectedEntries.add(entry)) {
        _selectedEntries.remove(entry);
      }
    });
  }

  Future<void> _deleteSelectedEntries() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete selected history?'),
        content: Text(
          'Delete ${_selectedEntries.length} selected '
          '${_selectedEntries.length == 1 ? 'entry' : 'entries'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(
        context,
      ).pop(HistoryPageResult(deletedEntries: _selectedEntries.toList()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectedEntries.isEmpty
              ? 'History'
              : '${_selectedEntries.length} selected',
        ),
        actions: [
          if (_selectedEntries.isNotEmpty)
            IconButton(
              tooltip: 'Delete selected entries',
              onPressed: _deleteSelectedEntries,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDarkTheme
                ? const [Color(0xFF172428), Color(0xFF10191C)]
                : const [Color(0xFFFFF7E2), Color(0xFFE8F1F2)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: widget.entries.isEmpty
                  ? Center(
                      child: Text(
                        'No successful uploads yet.',
                        style: theme.textTheme.bodyLarge,
                      ),
                    )
                  : ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: widget.entries.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final entry = widget.entries[index];
                        final isSelected = _selectedEntries.contains(entry);
                        return Material(
                          color: isSelected
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.12,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () {
                              if (_selectedEntries.isNotEmpty) {
                                _toggleSelection(entry);
                              } else {
                                Navigator.of(
                                  context,
                                ).pop(HistoryPageResult(selectedEntry: entry));
                              }
                            },
                            onLongPress: () => _toggleSelection(entry),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: ColoredBox(
                                      color: theme.colorScheme.surface,
                                      child: SizedBox(
                                        width: 64,
                                        height: 64,
                                        child: Center(child: _thumbnail(entry)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entry.fileName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodyLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        Text(
                                          entry.cid,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodyMedium,
                                        ),
                                        Text(
                                          '${entry.provider} | ${_formatDateTime(entry.uploadedAt)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    isSelected
                                        ? Icons.check_circle_rounded
                                        : Icons.chevron_right_rounded,
                                    color: isSelected
                                        ? theme.colorScheme.primary
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
