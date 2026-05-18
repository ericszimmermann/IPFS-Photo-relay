import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:dart_ipfs/dart_ipfs.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'remote_upload_client.dart';

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
    required this.localCid,
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    required this.peerBundle,
    this.remoteCid,
    this.remoteTarget,
    this.remoteUploadMessage,
  });

  final String cid;
  final String localCid;
  final String fileName;
  final Uint8List bytes;
  final String mimeType;
  final String peerBundle;
  final String? remoteCid;
  final RemoteUploadTarget? remoteTarget;
  final String? remoteUploadMessage;
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

class PeerImportResult {
  const PeerImportResult({
    required this.peerId,
    required this.multiaddr,
    this.cid,
  });

  final String peerId;
  final String multiaddr;
  final String? cid;
}

class IpfsTransferService {
  IpfsTransferService({RemoteUploadClient? remoteUploadClient})
    : _remoteUploadClient = remoteUploadClient ?? RemoteUploadClient();

  final RemoteUploadClient _remoteUploadClient;
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

  Future<PublishedImage?> pickAndPublishImage({
    RemoteUploadConfig remoteUploadConfig = const RemoteUploadConfig(
      target: RemoteUploadTarget.localOnly,
    ),
  }) async {
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
    final mimeType =
        lookupMimeType(fileName, headerBytes: bytes) ??
        lookupMimeType('', headerBytes: bytes) ??
        'application/octet-stream';

    final localCid = _normalizeImmutableCid(await _node!.addFile(bytes));
    await _node!.pin(localCid);
    await _announceProvider(localCid);

    String cidToShare = localCid;
    String? remoteCid;
    String? remoteUploadMessage;
    RemoteUploadTarget? remoteTarget;

    if (remoteUploadConfig.isEnabled) {
      try {
        final remoteUpload = await _remoteUploadClient.uploadFile(
          config: remoteUploadConfig,
          bytes: bytes,
          fileName: fileName,
          mimeType: mimeType,
        );
        if (remoteUpload != null) {
          remoteCid = _normalizeImmutableCid(remoteUpload.cid);
          cidToShare = remoteCid;
          remoteTarget = remoteUpload.target;
          remoteUploadMessage =
              'Mirrored to ${remoteUpload.target.label} via ${remoteUpload.endpoint}.';
        }
      } catch (error) {
        remoteUploadMessage =
            'Remote upload failed. Sharing local CID instead. $error';
      }
    }

    return PublishedImage(
      cid: cidToShare,
      localCid: localCid,
      remoteCid: remoteCid,
      remoteTarget: remoteTarget,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      peerBundle: await buildPeerBundle(cid: localCid),
      remoteUploadMessage: remoteUploadMessage,
    );
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

  Future<String> buildPeerBundle({String? cid}) async {
    final snapshot = await ensureStarted();
    final usableAddresses = snapshot.addresses
        .map((address) => _normalizeMultiaddr(address, snapshot.peerId))
        .whereType<String>()
        .where(_isShareableMultiaddr)
        .toSet()
        .toList();

    final lines = <String>[
      'PEER_ID=${snapshot.peerId}',
      if (cid != null) 'CID=$cid',
      ...usableAddresses.map((address) => 'MULTIADDR=$address'),
    ];

    return lines.join('\n');
  }

  Future<PeerImportResult> connectToSharedPeer(String rawText) async {
    await ensureStarted();

    final parsed = _parsePeerBundle(rawText);
    await _node!.connectToPeer(parsed.multiaddr);
    return parsed;
  }

  Future<void> shareCid(String cid) {
    return SharePlus.instance.share(
      ShareParams(
        text: cid,
        subject: 'IPFS content identifier',
      ),
    );
  }

  Future<void> sharePeerBundle(String peerBundle) {
    return SharePlus.instance.share(
      ShareParams(
        text: peerBundle,
        subject: 'IPFS peer address bundle',
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

  Future<void> _announceProvider(String cid) async {
    final dhtHandler = _node?.dhtHandler;
    if (dhtHandler == null) {
      return;
    }

    await dhtHandler.provide(CID.decode(cid));
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

  PeerImportResult _parsePeerBundle(String rawText) {
    final lines = const LineSplitter().convert(rawText.trim());
    String? peerId;
    String? multiaddr;
    String? cid;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }

      if (line.startsWith('CID=')) {
        cid = line.substring(4).trim();
        continue;
      }

      if (line.startsWith('PEER_ID=')) {
        peerId = line.substring(8).trim();
        continue;
      }

      if (line.startsWith('MULTIADDR=')) {
        multiaddr = line.substring(10).trim();
        continue;
      }

      if (line.startsWith('/')) {
        multiaddr = line;
      }
    }

    final normalizedMultiaddr = _normalizeMultiaddr(multiaddr, peerId);
    if (normalizedMultiaddr == null) {
      throw ArgumentError(
        'No usable multiaddr found. Paste a bundle containing MULTIADDR=/.../p2p/<peerId>.',
      );
    }

    final resolvedPeerId = _extractPeerIdFromMultiaddr(normalizedMultiaddr);
    if (resolvedPeerId == null || resolvedPeerId.isEmpty) {
      throw ArgumentError(
        'The shared multiaddr must include a /p2p/<peerId> suffix.',
      );
    }

    return PeerImportResult(
      peerId: resolvedPeerId,
      multiaddr: normalizedMultiaddr,
      cid: cid == null || cid.isEmpty ? null : _normalizeImmutableCid(cid),
    );
  }

  String? _normalizeMultiaddr(String? address, String? peerId) {
    if (address == null) {
      return null;
    }

    var normalized = address.trim();
    if (normalized.isEmpty) {
      return null;
    }

    normalized = normalized.replaceAll('/ipfs/', '/p2p/');
    if (!normalized.contains('/p2p/')) {
      final resolvedPeerId = peerId?.trim();
      if (resolvedPeerId == null || resolvedPeerId.isEmpty) {
        return null;
      }
      normalized = '$normalized/p2p/$resolvedPeerId';
    }

    return normalized;
  }

  String? _extractPeerIdFromMultiaddr(String multiaddr) {
    final parts = multiaddr.split('/');
    final p2pIndex = parts.indexOf('p2p');
    if (p2pIndex == -1 || p2pIndex + 1 >= parts.length) {
      return null;
    }
    return parts[p2pIndex + 1];
  }

  bool _isShareableMultiaddr(String multiaddr) {
    return !multiaddr.contains('/ip4/0.0.0.0/') &&
        !multiaddr.contains('/ip4/127.0.0.1/') &&
        !multiaddr.contains('/ip6/::/') &&
        !multiaddr.contains('/ip6/::1/');
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
