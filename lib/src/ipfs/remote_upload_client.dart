import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

enum RemoteUploadTarget {
  localOnly,
  pinata,
  filebase,
  kubo,
}

extension RemoteUploadTargetLabel on RemoteUploadTarget {
  String get label {
    switch (this) {
      case RemoteUploadTarget.localOnly:
        return 'Local Only';
      case RemoteUploadTarget.pinata:
        return 'Pinata';
      case RemoteUploadTarget.filebase:
        return 'Filebase RPC';
      case RemoteUploadTarget.kubo:
        return 'Kubo RPC';
    }
  }
}

class RemoteUploadConfig {
  const RemoteUploadConfig({
    required this.target,
    this.endpoint = '',
    this.authToken = '',
  });

  final RemoteUploadTarget target;
  final String endpoint;
  final String authToken;

  bool get isEnabled => target != RemoteUploadTarget.localOnly;

  String get resolvedEndpoint {
    switch (target) {
      case RemoteUploadTarget.localOnly:
        return '';
      case RemoteUploadTarget.pinata:
        return endpoint.trim().isEmpty
            ? 'https://api.pinata.cloud/pinning/pinFileToIPFS'
            : endpoint.trim();
      case RemoteUploadTarget.filebase:
        return endpoint.trim().isEmpty
            ? 'https://rpc.filebase.io/api/v0/add'
            : endpoint.trim();
      case RemoteUploadTarget.kubo:
        return endpoint.trim().isEmpty
            ? 'http://127.0.0.1:5001/api/v0/add'
            : endpoint.trim();
    }
  }
}

class RemoteUploadResult {
  const RemoteUploadResult({
    required this.cid,
    required this.target,
    required this.endpoint,
  });

  final String cid;
  final RemoteUploadTarget target;
  final String endpoint;
}

class RemoteUploadClient {
  Future<RemoteUploadResult?> uploadFile({
    required RemoteUploadConfig config,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (!config.isEnabled) {
      return null;
    }

    switch (config.target) {
      case RemoteUploadTarget.localOnly:
        return null;
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
    );
  }

  Future<RemoteUploadResult> _uploadToKuboCompatible({
    required RemoteUploadConfig config,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final resolved = _appendQueryParameters(
      config.resolvedEndpoint,
      const {
        'cid-version': '1',
      },
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

  String _appendQueryParameters(
    String endpoint,
    Map<String, String> parameters,
  ) {
    final uri = Uri.parse(endpoint);
    final merged = {...uri.queryParameters, ...parameters};
    return uri.replace(queryParameters: merged).toString();
  }

}
