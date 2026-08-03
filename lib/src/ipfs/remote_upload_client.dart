import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

String normalizeGatewayBase(String value) {
  var normalizedValue = value.trim();
  if (normalizedValue.isEmpty) {
    return normalizedValue;
  }

  final hasHttpScheme =
      normalizedValue.toLowerCase().startsWith('http://') ||
      normalizedValue.toLowerCase().startsWith('https://');
  if (!hasHttpScheme) {
    normalizedValue = 'https://$normalizedValue';
  }

  if (normalizedValue.contains('{cid}')) {
    return normalizedValue;
  }

  if (!normalizedValue.endsWith('/ipfs/')) {
    if (normalizedValue.endsWith('/ipfs')) {
      normalizedValue = '$normalizedValue/';
    } else if (normalizedValue.endsWith('/')) {
      normalizedValue = '${normalizedValue}ipfs/';
    } else {
      normalizedValue = '$normalizedValue/ipfs/';
    }
  }

  return normalizedValue;
}

enum RemoteUploadTarget {
  pinata,
  filebase,
  kubo,
}

extension RemoteUploadTargetLabel on RemoteUploadTarget {
  String get label {
    switch (this) {
      case RemoteUploadTarget.pinata:
        return 'Pinata';
      case RemoteUploadTarget.filebase:
        return 'Filebase RPC';
      case RemoteUploadTarget.kubo:
        return 'Kubo RPC';
    }
  }

  String get defaultUploadEndpoint {
    switch (this) {
      case RemoteUploadTarget.pinata:
        return 'https://api.pinata.cloud/pinning/pinFileToIPFS';
      case RemoteUploadTarget.filebase:
        return 'https://rpc.filebase.io/api/v0/add';
      case RemoteUploadTarget.kubo:
        return 'http://127.0.0.1:5001/api/v0/add';
    }
  }

  String get defaultGatewayBase {
    switch (this) {
      case RemoteUploadTarget.pinata:
        return 'https://gateway.pinata.cloud/ipfs/';
      case RemoteUploadTarget.filebase:
        return 'https://ipfs.filebase.io/ipfs/';
      case RemoteUploadTarget.kubo:
        return 'http://127.0.0.1:8080/ipfs/';
    }
  }
}

class RemoteUploadConfig {
  const RemoteUploadConfig({
    required this.target,
    this.endpoint = '',
    this.gatewayBase = '',
    this.authToken = '',
  });

  final RemoteUploadTarget target;
  final String endpoint;
  final String gatewayBase;
  final String authToken;

  String get resolvedEndpoint {
    final trimmed = endpoint.trim();
    return trimmed.isEmpty ? target.defaultUploadEndpoint : trimmed;
  }

  String get resolvedGatewayBase {
    final trimmed = gatewayBase.trim();
    final resolved = trimmed.isEmpty ? target.defaultGatewayBase : trimmed;
    return normalizeGatewayBase(resolved);
  }
}

class RemoteUploadResult {
  const RemoteUploadResult({
    required this.cid,
    required this.target,
    required this.endpoint,
    required this.gatewayUrl,
  });

  final String cid;
  final RemoteUploadTarget target;
  final String endpoint;
  final String gatewayUrl;
}

class RemoteDownloadResult {
  const RemoteDownloadResult({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.gatewayUrl,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final String gatewayUrl;
}

class RemoteUploadClient {
  Future<RemoteUploadResult?> uploadFile({
    required RemoteUploadConfig config,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    switch (config.target) {
      case RemoteUploadTarget.pinata:
        return _uploadToPinata(
          config: config,
          bytes: bytes,
          fileName: fileName,
          mimeType: mimeType,
        );
      case RemoteUploadTarget.filebase:
      case RemoteUploadTarget.kubo:
        return _uploadToKuboCompatible(
          config: config,
          bytes: bytes,
          fileName: fileName,
          mimeType: mimeType,
        );
    }
  }

  Future<RemoteDownloadResult> downloadFile({
    required RemoteUploadConfig config,
    required String cid,
  }) async {
    final gatewayUrl = _buildGatewayUrl(config.resolvedGatewayBase, cid);
    final request = http.Request('GET', Uri.parse(gatewayUrl));

    final token = config.authToken.trim();
    if (token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    final response = await request.send();
    final bytes = await response.stream.toBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = utf8.decode(bytes, allowMalformed: true);
      throw Exception(
        'Download failed (${response.statusCode}) from $gatewayUrl: $body',
      );
    }

    final fileName =
        _extractFileName(response.headers['content-disposition']) ??
        'ipfs-${cid.substring(0, cid.length > 12 ? 12 : cid.length)}';

    return RemoteDownloadResult(
      bytes: bytes,
      fileName: fileName,
      mimeType: response.headers['content-type'] ?? '',
      gatewayUrl: gatewayUrl,
    );
  }

  Future<RemoteUploadResult> _uploadToPinata({
    required RemoteUploadConfig config,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final token = config.authToken.trim();
    if (token.isEmpty) {
      throw ArgumentError('Pinata requires a JWT or API bearer token.');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(config.resolvedEndpoint),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['pinataOptions'] = jsonEncode({'cidVersion': 1})
      ..fields['pinataMetadata'] = jsonEncode({'name': fileName})
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
        ),
      );

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Pinata upload failed (${response.statusCode}): $body');
    }

    final data = jsonDecode(body) as Map<String, dynamic>;
    final cid = data['IpfsHash'] as String?;
    if (cid == null || cid.isEmpty) {
      throw Exception('Pinata did not return an IPFS CID.');
    }

    return RemoteUploadResult(
      cid: cid,
      target: config.target,
      endpoint: config.resolvedEndpoint,
      gatewayUrl: _buildGatewayUrl(config.resolvedGatewayBase, cid),
    );
  }

  Future<RemoteUploadResult> _uploadToKuboCompatible({
    required RemoteUploadConfig config,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (config.target == RemoteUploadTarget.filebase &&
        config.authToken.trim().isEmpty) {
      throw ArgumentError('Filebase RPC requires an API token.');
    }

    final resolved = _appendQueryParameters(
      config.resolvedEndpoint,
      const {'cid-version': '1'},
    );

    final request = http.MultipartRequest('POST', Uri.parse(resolved))
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
        ),
      );

    final token = config.authToken.trim();
    if (token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        '${config.target.label} upload failed (${response.statusCode}): $body',
      );
    }

    final cid = _extractKuboHash(body);
    if (cid == null || cid.isEmpty) {
      throw Exception('${config.target.label} did not return an IPFS CID.');
    }

    return RemoteUploadResult(
      cid: cid,
      target: config.target,
      endpoint: config.resolvedEndpoint,
      gatewayUrl: _buildGatewayUrl(config.resolvedGatewayBase, cid),
    );
  }

  String? _extractKuboHash(String body) {
    final lines = const LineSplitter()
        .convert(body)
        .where((line) => line.trim().isNotEmpty)
        .toList();
    for (final line in lines.reversed) {
      try {
        final decoded = jsonDecode(line) as Map<String, dynamic>;
        final hash = decoded['Hash'] as String?;
        if (hash != null && hash.isNotEmpty) {
          return hash;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  String? _extractFileName(String? contentDisposition) {
    if (contentDisposition == null || contentDisposition.isEmpty) {
      return null;
    }

    final utf8Match = RegExp(
      r"filename\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    if (utf8Match != null) {
      return Uri.decodeComponent(utf8Match.group(1)!);
    }

    final plainMatch = RegExp(
      r'filename="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    return plainMatch?.group(1);
  }

  String _appendQueryParameters(
    String endpoint,
    Map<String, String> parameters,
  ) {
    final uri = Uri.parse(endpoint);
    final merged = {...uri.queryParameters, ...parameters};
    return uri.replace(queryParameters: merged).toString();
  }

  String _buildGatewayUrl(String gatewayBase, String cid) {
    final trimmed = gatewayBase.trim();
    if (trimmed.contains('{cid}')) {
      return trimmed.replaceAll('{cid}', cid);
    }

    final needsSlash = trimmed.isNotEmpty && !trimmed.endsWith('/');
    return '${needsSlash ? '$trimmed/' : trimmed}$cid';
  }
}
