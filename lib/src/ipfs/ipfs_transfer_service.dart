import 'dart:io' show File;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'remote_upload_client.dart';

class PublishedImage {
  const PublishedImage({
    required this.cid,
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    required this.remoteTarget,
    required this.uploadEndpoint,
    required this.gatewayUrl,
    this.remoteUploadMessage,
  });

  final String cid;
  final String fileName;
  final Uint8List bytes;
  final String mimeType;
  final RemoteUploadTarget remoteTarget;
  final String uploadEndpoint;
  final String gatewayUrl;
  final String? remoteUploadMessage;

  bool get isImage => mimeType.startsWith('image/');
}

class DownloadedImage {
  const DownloadedImage({
    required this.cid,
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    required this.localPath,
    required this.gatewayUrl,
  });

  final String cid;
  final String fileName;
  final Uint8List bytes;
  final String mimeType;
  final String localPath;
  final String gatewayUrl;

  bool get isImage => mimeType.startsWith('image/');
}

class IpfsTransferService {
  IpfsTransferService({RemoteUploadClient? remoteUploadClient})
    : _remoteUploadClient = remoteUploadClient ?? RemoteUploadClient();

  final RemoteUploadClient _remoteUploadClient;

  Future<PublishedImage?> pickAndPublishImage({
    required RemoteUploadConfig remoteUploadConfig,
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

    final fileName = _sanitizeFileName(
      file.name.isEmpty ? 'shared-image' : file.name,
    );
    final mimeType =
        lookupMimeType(fileName, headerBytes: bytes) ??
        lookupMimeType('', headerBytes: bytes) ??
        'application/octet-stream';

    final remoteUpload = await _remoteUploadClient.uploadFile(
      config: remoteUploadConfig,
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    );

    if (remoteUpload == null) {
      throw StateError('Choose a remote upload target first.');
    }

    final cid = _normalizeImmutableCid(remoteUpload.cid);
    return PublishedImage(
      cid: cid,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      remoteTarget: remoteUpload.target,
      uploadEndpoint: remoteUpload.endpoint,
      gatewayUrl: remoteUpload.gatewayUrl,
      remoteUploadMessage:
          'Uploaded to ${remoteUpload.target.label} via ${remoteUpload.endpoint}.',
    );
  }

  Future<DownloadedImage> downloadByCid({
    required String rawCid,
    required RemoteUploadConfig remoteUploadConfig,
  }) async {
    final cid = _normalizeImmutableCid(rawCid);
    final remoteFile = await _remoteUploadClient.downloadFile(
      config: remoteUploadConfig,
      cid: cid,
    );

    final mimeType =
        remoteFile.mimeType.isEmpty
            ? lookupMimeType(remoteFile.fileName, headerBytes: remoteFile.bytes) ??
                'application/octet-stream'
            : remoteFile.mimeType;

    var fileName = _sanitizeFileName(remoteFile.fileName);
    if (!_hasExtension(fileName)) {
      fileName = '$fileName${_extensionForMime(mimeType)}';
    }

    final localPath = await _writeExportFile(fileName, remoteFile.bytes);
    return DownloadedImage(
      cid: cid,
      fileName: fileName,
      bytes: remoteFile.bytes,
      mimeType: mimeType,
      localPath: localPath,
      gatewayUrl: remoteFile.gatewayUrl,
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

  Future<void> shareGatewayUrl(String gatewayUrl) {
    return SharePlus.instance.share(
      ShareParams(
        text: gatewayUrl,
        subject: 'IPFS gateway URL',
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

  Future<void> dispose() async {}

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
    var cid = rawCid.trim();
    if (cid.isEmpty) {
      throw ArgumentError('Enter a CID first.');
    }

    cid = cid.replaceFirst(RegExp(r'^ipfs://', caseSensitive: false), '');
    cid = cid.replaceFirst(RegExp(r'^/ipfs/'), '');

    final gatewayMatch = RegExp(
      r'/ipfs/([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(cid);
    if (gatewayMatch != null) {
      cid = gatewayMatch.group(1)!;
    }

    final isCidV0 = RegExp(r'^Qm[1-9A-HJ-NP-Za-km-z]{44,}$').hasMatch(cid);
    final isCidV1 = RegExp(r'^b[a-z2-7]{20,}$').hasMatch(cid);
    if (!isCidV0 && !isCidV1) {
      throw ArgumentError(
        'Invalid CID. Paste the full immutable CID, usually starting with "bafy..." or "Qm...".',
      );
    }

    return cid;
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
