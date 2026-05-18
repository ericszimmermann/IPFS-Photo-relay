import 'dart:async';
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:dart_ipfs/dart_ipfs.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class IpfsNodeSnapshot {
  const IpfsNodeSnapshot({
    required this.peerId,
    required this.addresses,
    required this.connectedPeers,
  });

  final String peerId;
  final List<String> addresses;
  final int connectedPeers;
}

class PublishedImage {
  const PublishedImage({
    required this.cid,
    required this.fileName,
    required this.bytes,
  });

  final String cid;
  final String fileName;
  final Uint8List bytes;
}

class DownloadedImage {
  const DownloadedImage({
    required this.cid,
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    required this.localPath,
  });

  final String cid;
  final String fileName;
  final Uint8List bytes;
  final String mimeType;
  final String localPath;

  bool get isImage => mimeType.startsWith('image/');
}

class IpfsTransferService {
  IPFSNode? _node;
  Future<void>? _startup;

  Future<IpfsNodeSnapshot> ensureStarted() async {
    if (_node?.isRunning ?? false) {
      return _snapshot();
    }

    _startup ??= _startNode();
    try {
      await _startup;
    } finally {
      _startup = null;
    }

    return _snapshot();
  }

  Future<PublishedImage?> pickAndPublishImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );

    if (result == null) {
      return null;
    }

    final file = result.files.single;
    final bytes = file.bytes ?? await _readBytesFromPath(file.path);
    if (bytes == null || bytes.isEmpty) {
      throw Exception('The selected file could not be read.');
    }

    await ensureStarted();

    final fileName = _sanitizeFileName(
      file.name.isEmpty ? 'shared-image' : file.name,
    );
    final cid = _normalizeImmutableCid(
      await _node!.addDirectory({fileName: bytes}),
    );
    await _node!.pin(cid);

    return PublishedImage(cid: cid, fileName: fileName, bytes: bytes);
  }

  Future<DownloadedImage> downloadByCid(String rawCid) async {
    final cid = _normalizeImmutableCid(rawCid);

    await ensureStarted();

    final links = await _safeListDirectory(cid);
    final shortCid = cid.length > 12 ? cid.substring(0, 12) : cid;

    String fileName = 'ipfs-$shortCid';
    Uint8List? bytes;

    if (links.isNotEmpty) {
      final firstLink = links.first;
      fileName = _sanitizeFileName(
        firstLink.name.isEmpty ? fileName : firstLink.name,
      );
      bytes = await _node!.get(cid, path: firstLink.name);
    }

    bytes ??= await _node!.get(cid);
    if (bytes == null || bytes.isEmpty) {
      throw Exception('No content could be resolved for CID "$cid".');
    }

    final mimeType =
        lookupMimeType(fileName, headerBytes: bytes) ??
        lookupMimeType('', headerBytes: bytes) ??
        'application/octet-stream';

    if (!_hasExtension(fileName)) {
      fileName = '$fileName${_extensionForMime(mimeType)}';
    }

    await _node!.pin(cid);
    final localPath = await _writeExportFile(fileName, bytes);

    return DownloadedImage(
      cid: cid,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      localPath: localPath,
    );
  }

  Future<void> shareCid(String cid) {
    return SharePlus.instance.share(
      ShareParams(
        text: cid,
        subject: 'IPFS content identifier',
      ),
    );
  }

  Future<void> shareDownloadedFile(DownloadedImage image) {
    return SharePlus.instance.share(
      ShareParams(
        text: 'Fetched from IPFS via CID ${image.cid}',
        subject: image.fileName,
        files: [
          XFile(
            image.localPath,
            mimeType: image.mimeType,
            name: image.fileName,
          ),
        ],
      ),
    );
  }

  Future<void> dispose() async {
    final node = _node;
    if (node != null && node.isRunning) {
      await node.stop();
    }
  }

  Future<void> _startNode() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final baseDirectory = Directory('${supportDirectory.path}/ipfs_node');
    await baseDirectory.create(recursive: true);

    _node = await IPFSNode.create(
      IPFSConfig(
        offline: false,
        debug: false,
        verboseLogging: false,
        enableStructuredLogging: false,
        logLevel: 'warning',
        dataPath: baseDirectory.path,
        datastorePath: '${baseDirectory.path}/datastore',
        blockStorePath: '${baseDirectory.path}/blocks',
        keystorePath: '${baseDirectory.path}/keystore',
        network: NetworkConfig(
          enableNatTraversal: true,
          enableMDNS: true,
        ),
      ),
    );

    await _node!.start();
  }

  Future<IpfsNodeSnapshot> _snapshot() async {
    final node = _node;
    if (node == null) {
      throw StateError('The IPFS node has not been started.');
    }

    final peers = await node.connectedPeers;
    return IpfsNodeSnapshot(
      peerId: node.peerId,
      addresses: node.addresses,
      connectedPeers: peers.length,
    );
  }

  Future<List<dynamic>> _safeListDirectory(String cid) async {
    try {
      return await _node!.ls(cid);
    } catch (_) {
      return const <dynamic>[];
    }
  }

  Future<Uint8List?> _readBytesFromPath(String? path) async {
    if (path == null || path.isEmpty) {
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      return null;
    }

    return file.readAsBytes();
  }

  Future<String> _writeExportFile(String fileName, Uint8List bytes) async {
    final tempDirectory = await getTemporaryDirectory();
    final file = File('${tempDirectory.path}/$fileName');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  String _sanitizeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    return cleaned.isEmpty ? 'shared-image' : cleaned;
  }

  String _normalizeImmutableCid(String rawCid) {
    final cid = rawCid.trim();
    if (cid.isEmpty) {
      throw ArgumentError('Enter a CID first.');
    }

    try {
      final parsed = CID.decode(cid);
      if (!parsed.validate()) {
        throw const FormatException('CID validation failed.');
      }

      final canonicalCid = parsed.encode();
      if (parsed.version == 1 && !canonicalCid.startsWith('baf')) {
        throw const FormatException(
          'Expected an immutable CIDv1, usually starting with "baf...".',
        );
      }

      return canonicalCid;
    } catch (_) {
      throw ArgumentError(
        'Invalid CID. It looks truncated or malformed. Paste the full immutable CID, usually starting with "bafy..." or "Qm...".',
      );
    }
  }

  bool _hasExtension(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    return dotIndex > 0 && dotIndex < fileName.length - 1;
  }

  String _extensionForMime(String mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/heic':
        return '.heic';
      default:
        return '';
    }
  }
}
