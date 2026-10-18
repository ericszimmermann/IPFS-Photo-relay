import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ipfs/ipfs_transfer_service.dart';
import 'ipfs/remote_upload_client.dart';

class _UploadHistoryEntry {
  const _UploadHistoryEntry({
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

  static _UploadHistoryEntry? fromJson(Map<String, dynamic> json) {
    final uploadedAt = DateTime.tryParse(json['uploadedAt'] as String? ?? '');
    if (uploadedAt == null) {
      return null;
    }
    return _UploadHistoryEntry(
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

// Represents a provider entry (builtin or user-defined).
class _ProviderEntry {
  _ProviderEntry({
    required this.name,
    required this.target,
    this.endpoint = '',
    this.gatewayBase = '',
    this.authToken = '',
    this.isBuiltin = false,
  });

  final String name;
  final RemoteUploadTarget target;
  String endpoint;
  String gatewayBase;
  String authToken;
  final bool isBuiltin;

  Map<String, dynamic> toJson() => {
    'name': name,
    'target': target.name,
    'endpoint': endpoint,
    'gatewayBase': gatewayBase,
    'authToken': authToken,
  };

  static _ProviderEntry fromJson(Map<String, dynamic> json) {
    final targetName =
        json['target'] as String? ?? RemoteUploadTarget.pinata.name;
    final target = RemoteUploadTarget.values.firstWhere(
      (t) => t.name == targetName,
      orElse: () => RemoteUploadTarget.pinata,
    );
    return _ProviderEntry(
      name: json['name'] as String? ?? target.label,
      target: target,
      endpoint: json['endpoint'] as String? ?? '',
      gatewayBase: json['gatewayBase'] as String? ?? '',
      authToken: json['authToken'] as String? ?? '',
      isBuiltin: false,
    );
  }
}

class IpfsPhotoRelayApp extends StatefulWidget {
  const IpfsPhotoRelayApp({super.key, this.startNodeOnLoad = true});

  final bool startNodeOnLoad;

  @override
  State<IpfsPhotoRelayApp> createState() => _IpfsPhotoRelayAppState();
}

class _IpfsPhotoRelayAppState extends State<IpfsPhotoRelayApp> {
  static const String _prefsDarkThemeKey = 'relay.darkTheme';
  bool _isDarkTheme = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreTheme());
  }

  Future<void> _restoreTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDarkTheme = prefs.getBool(_prefsDarkThemeKey) ?? false;
      if (mounted) {
        setState(() => _isDarkTheme = isDarkTheme);
      }
    } catch (_) {
      // Keep the default light theme if local preferences are unavailable.
    }
  }

  Future<void> _toggleTheme() async {
    final isDarkTheme = !_isDarkTheme;
    setState(() => _isDarkTheme = isDarkTheme);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsDarkThemeKey, isDarkTheme);
    } catch (_) {
      // Keep the selected theme for this session if it cannot be saved.
    }
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDarkTheme = brightness == Brightness.dark;
    final canvas = isDarkTheme
        ? const Color(0xFF111B1E)
        : const Color(0xFFF5F1E8);
    final ink = isDarkTheme ? const Color(0xFFE6F1EF) : const Color(0xFF153243);
    final accent = isDarkTheme
      ? const Color(0xFF8AB4D8)
        : const Color(0xFF1F7A8C);
    const highlight = Color(0xFFF4B942);
    final cardColor = isDarkTheme ? const Color(0xFF1A292D) : Colors.white;

    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          secondary: highlight,
          surface: cardColor,
          onPrimary: Colors.white,
          onSurface: ink,
        );

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      useMaterial3: true,
      textTheme: (isDarkTheme ? ThemeData.dark() : ThemeData.light()).textTheme
          .apply(bodyColor: ink, displayColor: ink),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: cardColor.withValues(alpha: 0.92),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: ink.withValues(alpha: 0.08)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPFS Photo Relay',
      debugShowCheckedModeBanner: false,
      themeMode: _isDarkTheme ? ThemeMode.dark : ThemeMode.light,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: IpfsPhotoRelayPage(
        startNodeOnLoad: widget.startNodeOnLoad,
        onThemeToggle: _toggleTheme,
      ),
    );
  }
}

class IpfsPhotoRelayPage extends StatefulWidget {
  const IpfsPhotoRelayPage({
    super.key,
    required this.startNodeOnLoad,
    this.service,
    this.onThemeToggle,
  });

  final bool startNodeOnLoad;
  final IpfsTransferService? service;
  final VoidCallback? onThemeToggle;

  @override
  State<IpfsPhotoRelayPage> createState() => _IpfsPhotoRelayPageState();
}

class _IpfsPhotoRelayPageState extends State<IpfsPhotoRelayPage> {
  static const String _prefsUploadHistoryKey = 'relay.uploadHistory';
  static const String _prefsCustomProvidersKey = 'relay.customProviders';
  static const String _prefsUploadTargetKey = 'relay.uploadTarget';
  static const String _prefsEndpointPrefix = 'relay.endpoint.';
  static const String _prefsGatewayPrefix = 'relay.gateway.';
  static const String _prefsAuthTokenPrefix = 'relay.authToken.';

  late final IpfsTransferService _service =
      widget.service ?? IpfsTransferService();
  late final Future<SharedPreferences> _prefsFuture =
      SharedPreferences.getInstance();
  final TextEditingController _cidController = TextEditingController();
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _gatewayController = TextEditingController();
  final TextEditingController _authTokenController = TextEditingController();

  final Map<RemoteUploadTarget, String> _endpointOverrides = {};
  final Map<RemoteUploadTarget, String> _gatewayOverrides = {};
  final Map<RemoteUploadTarget, String> _authTokenOverrides = {};
  final List<_UploadHistoryEntry> _uploadHistory = [];

  // Provider list: only user-defined (custom) entries.
  late List<_ProviderEntry> _providerList;
  // -1 means no custom provider selected (use builtin/legacy selection)
  int _selectedProviderIndex = -1;
  bool _settingsRestored = false;

  PublishedImage? _publishedImage;
  DownloadedImage? _downloadedImage;
  RemoteUploadTarget _uploadTarget = RemoteUploadTarget.pinata;
  String? _selectedPublishedGatewayBase;
  // Selected gateway to use for downloads (separate from upload gateway)
  String? _selectedDownloadGateway;

  bool _isPublishing = false;
  bool _isDownloading = false;

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows);

  String _statusMessage =
      'Remote mode active. Upload to Pinata, Filebase RPC, or a Kubo node.';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _buildProviderList();
    _loadTargetFields(_uploadTarget);
    _selectedDownloadGateway = _gatewayController.text;
    unawaited(_restoreSettings());
    unawaited(_restoreUploadHistory());
  }

  @override
  void dispose() {
    unawaited(_persistSettings());
    _cidController.dispose();
    _endpointController.dispose();
    _gatewayController.dispose();
    _authTokenController.dispose();
    unawaited(_service.dispose());
    super.dispose();
  }

  Future<void> _publishImage() async {
    final isCustomProvider = _selectedProviderIndex >= 0;
    final providerName = isCustomProvider
        ? _providerList[_selectedProviderIndex].name
        : _uploadTarget.label;
    setState(() {
      _isPublishing = true;
      _errorMessage = null;
      _statusMessage = 'Picking a file and uploading it to remote IPFS...';
    });

    try {
      final publishedImage = await _service.pickAndPublishImage(
        remoteUploadConfig: _currentRemoteUploadConfig(),
      );
      if (!mounted) {
        return;
      }

      if (publishedImage == null) {
        setState(() {
          _statusMessage = 'Image selection cancelled.';
        });
        return;
      }

      await _recordSuccessfulUpload(
        publishedImage,
        providerName,
        isCustomProvider: isCustomProvider,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _publishedImage = publishedImage;
        _selectedPublishedGatewayBase = null;
        _cidController.text = publishedImage.cid;
        _statusMessage =
            'Uploaded ${publishedImage.fileName} to ${publishedImage.remoteTarget.label}.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = error.toString();
        _statusMessage = 'Upload failed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPublishing = false;
        });
      }
    }
  }

  Future<void> _recordSuccessfulUpload(
    PublishedImage image,
    String provider, {
    required bool isCustomProvider,
  }) async {
    final thumbnail = image.isImage
        ? await _createThumbnail(image.bytes)
        : null;
    final entry = _UploadHistoryEntry(
      fileName: image.fileName,
      cid: image.cid,
      provider: provider,
      targetName: image.remoteTarget.name,
      mimeType: image.mimeType,
      uploadedAt: DateTime.now(),
      isImage: image.isImage,
      isCustomProvider: isCustomProvider,
      thumbnailBase64: thumbnail == null ? null : base64Encode(thumbnail),
    );

    setState(() {
      _uploadHistory.insert(0, entry);
      if (_uploadHistory.length > 30) {
        _uploadHistory.removeRange(30, _uploadHistory.length);
      }
    });

    try {
      final prefs = await _prefsFuture;
      await prefs.setString(
        _prefsUploadHistoryKey,
        jsonEncode(_uploadHistory.map((item) => item.toJson()).toList()),
      );
    } catch (_) {
      // The completed upload remains usable even if local history cannot be saved.
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

  Future<void> _restoreUploadHistory() async {
    try {
      final prefs = await _prefsFuture;
      final raw = prefs.getString(_prefsUploadHistoryKey);
      if (raw == null || raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw) as List<dynamic>;
      final entries = decoded
          .whereType<Map<String, dynamic>>()
          .map(_UploadHistoryEntry.fromJson)
          .whereType<_UploadHistoryEntry>()
          .take(30)
          .toList();
      if (mounted) {
        setState(() {
          _uploadHistory
            ..clear()
            ..addAll(entries);
        });
      }
    } catch (_) {
      // Ignore malformed or unavailable local history.
    }
  }

  Future<void> _openUploadHistory() async {
    final entry = await Navigator.of(context).push<_UploadHistoryEntry>(
      MaterialPageRoute<_UploadHistoryEntry>(
        builder: (context) => _UploadHistoryPage(entries: _uploadHistory),
      ),
    );
    if (entry == null || !mounted) {
      return;
    }

    _loadHistoryEntry(entry);
  }

  void _loadHistoryEntry(_UploadHistoryEntry entry) {
    final target = RemoteUploadTarget.values.firstWhere(
      (item) => item.name == entry.targetName,
      orElse: () => _uploadTarget,
    );
    var restoredTarget = target;
    if (entry.isCustomProvider) {
      final providerIndex = _providerList.indexWhere(
        (provider) =>
            provider.name == entry.provider && provider.target == target,
      );
      if (providerIndex >= 0) {
        _selectedProviderIndex = providerIndex;
        restoredTarget = _providerList[providerIndex].target;
        _applyProviderToControllers(_providerList[providerIndex]);
      } else {
        restoredTarget = _uploadTarget;
      }
    } else {
      _selectedProviderIndex = -1;
      _uploadTarget = target;
      _loadTargetFields(target);
    }

    Uint8List bytes = Uint8List(0);
    if (entry.thumbnailBase64 != null) {
      try {
        bytes = base64Decode(entry.thumbnailBase64!);
      } catch (_) {
        // The CID and metadata remain usable without a thumbnail.
      }
    }

    final image = PublishedImage(
      cid: entry.cid,
      fileName: entry.fileName,
      bytes: bytes,
      mimeType: entry.mimeType,
      remoteTarget: restoredTarget,
      uploadEndpoint: _endpointController.text,
      gatewayUrl: '',
    );
    setState(() {
      _uploadTarget = restoredTarget;
      _publishedImage = image;
      _selectedPublishedGatewayBase = null;
      _cidController.text = image.cid;
      _statusMessage = 'Loaded ${image.fileName} from upload history.';
      _errorMessage = null;
    });
  }

  Future<void> _downloadImage() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _statusMessage = 'Fetching the CID through the configured gateway...';
    });

    try {
      final gatewayBase =
          (_selectedDownloadGateway != null &&
              _selectedDownloadGateway!.trim().isNotEmpty)
          ? _selectedDownloadGateway!.trim()
          : _gatewayController.text.trim();

      // Find matching custom provider to supply auth token if available
      String authToken = '';
      for (final p in _providerList) {
        if (p.gatewayBase.trim().isNotEmpty &&
            _normalizeGatewayBase(p.gatewayBase) ==
                _normalizeGatewayBase(gatewayBase)) {
          authToken = p.authToken;
          break;
        }
      }

      final cfg = RemoteUploadConfig(
        target: _uploadTarget,
        endpoint: '',
        gatewayBase: gatewayBase,
        authToken: authToken,
      );

      final downloadedImage = await _service.downloadByCid(
        rawCid: _cidController.text,
        remoteUploadConfig: cfg,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _downloadedImage = downloadedImage;
        _statusMessage =
            'Downloaded ${downloadedImage.fileName} from ${downloadedImage.gatewayUrl}.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = error.toString();
        _statusMessage = 'Download failed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  Future<void> _shareCid() async {
    final cid = _publishedImage?.cid;
    if (cid == null) {
      return;
    }

    try {
      await _service.shareCid(cid);
      if (!mounted) {
        return;
      }
      _showSnack('CID shared.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('Sharing failed: $error');
    }
  }

  Future<void> _openOrSharePublishedGatewayUrl() async {
    final publishedImage = _publishedImage;
    if (publishedImage == null) {
      return;
    }
    final gatewayUrl = _publishedGatewayUrl(publishedImage);

    try {
      if (_isDesktop) {
        await _service.openGatewayUrl(gatewayUrl);
      } else {
        await _service.shareGatewayUrl(gatewayUrl);
      }
      if (!mounted) {
        return;
      }
      _showSnack(
        _isDesktop ? 'Gateway URL opened in browser.' : 'Gateway URL shared.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('${_isDesktop ? 'Opening URL' : 'Sharing'} failed: $error');
    }
  }

  Future<void> _receiveDownloadedFile() async {
    final image = _downloadedImage;
    if (image == null) {
      return;
    }

    if (_isDesktop) {
      try {
        final savedPath = await _service.saveDownloadedFile(image);
        if (!mounted || savedPath == null) {
          return;
        }
        _showSnack('File saved to $savedPath');
      } catch (error) {
        if (mounted) {
          _showSnack('Saving failed: $error');
        }
      }
      return;
    }

    try {
      await _service.shareDownloadedFile(image);
      if (!mounted) {
        return;
      }
      _showSnack('Downloaded file shared.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('Sharing failed: $error');
    }
  }

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    _showSnack('$label copied to the clipboard.');
  }

  Future<void> _pasteIntoController(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) {
        return;
      }
      _showSnack('Clipboard is empty.');
      return;
    }

    controller.text = text;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  RemoteUploadConfig _currentRemoteUploadConfig() {
    return RemoteUploadConfig(
      target: _uploadTarget,
      endpoint: _endpointController.text,
      gatewayBase: _normalizeGatewayBase(_gatewayController.text),
      authToken: _authTokenController.text,
    );
  }

  String _normalizeGatewayBase(String value) {
    return normalizeGatewayBase(value);
  }

  List<Map<String, String>> _gatewayOptions({
    bool includeConfiguredGateway = false,
  }) {
    final options = <Map<String, String>>[];
    for (final provider in _providerList) {
      final gateway = provider.gatewayBase.trim();
      if (gateway.isNotEmpty &&
          _normalizeGatewayBase(gateway) !=
              _normalizeGatewayBase(provider.target.defaultGatewayBase)) {
        options.add({
          'label': provider.name,
          'value': _normalizeGatewayBase(gateway),
        });
      }
    }

    options.addAll(
      RemoteUploadTarget.values
          .where((target) => target != RemoteUploadTarget.kubo)
          .map(
            (target) => {
              'label': '${target.label} Public',
              'value': _normalizeGatewayBase(target.defaultGatewayBase),
            },
          ),
    );

    if (includeConfiguredGateway) {
      final configuredGateway = _normalizeGatewayBase(_gatewayController.text);
      if (configuredGateway.isNotEmpty &&
          !options.any((option) => option['value'] == configuredGateway)) {
        options.insert(0, {
          'label': 'Kubo configured',
          'value': configuredGateway,
        });
      }
    }

    return options;
  }

  String _defaultPublishedGatewayBase() {
    if (_uploadTarget == RemoteUploadTarget.kubo) {
      final configuredGateway = _gatewayController.text.trim();
      return _normalizeGatewayBase(
        configuredGateway.isEmpty
            ? _uploadTarget.defaultGatewayBase
            : configuredGateway,
      );
    }
    return _normalizeGatewayBase(_uploadTarget.defaultGatewayBase);
  }

  String _publishedGatewayUrl(PublishedImage image) {
    final gatewayBase =
        _selectedPublishedGatewayBase ?? _defaultPublishedGatewayBase();
    if (gatewayBase.isEmpty) {
      return image.gatewayUrl;
    }
    if (gatewayBase.contains('{cid}')) {
      return gatewayBase.replaceAll('{cid}', image.cid);
    }
    return '${gatewayBase.endsWith('/') ? gatewayBase : '$gatewayBase/'}${image.cid}';
  }

  void _persistCurrentTargetFields() {
    final selected = _selectedProviderIndex >= 0
        ? _providerList[_selectedProviderIndex]
        : null;
    if (selected == null) {
      // No custom selected: use legacy per-enum overrides
      _endpointOverrides[_uploadTarget] = _endpointController.text;
      _gatewayOverrides[_uploadTarget] = _normalizeGatewayBase(
        _gatewayController.text,
      );
      _authTokenOverrides[_uploadTarget] = _authTokenController.text;
    } else {
      selected.endpoint = _endpointController.text;
      selected.gatewayBase = _normalizeGatewayBase(_gatewayController.text);
      selected.authToken = _authTokenController.text;
    }
  }

  Future<void> _persistSettings() async {
    if (!_settingsRestored) {
      return;
    }

    _persistCurrentTargetFields();

    final prefs = await _prefsFuture;
    // Persist selected provider: builtin:<name> or custom:<name>
    final selected = _selectedProviderIndex >= 0
        ? _providerList[_selectedProviderIndex]
        : null;
    if (selected != null) {
      await prefs.setString(_prefsUploadTargetKey, 'custom:${selected.name}');
    } else {
      // no custom selected; persist legacy enum name for compatibility
      await prefs.setString(_prefsUploadTargetKey, _uploadTarget.name);
    }

    for (final target in RemoteUploadTarget.values) {
      final endpointKey = '$_prefsEndpointPrefix${target.name}';
      final gatewayKey = '$_prefsGatewayPrefix${target.name}';
      final tokenKey = '$_prefsAuthTokenPrefix${target.name}';

      final endpoint = _endpointOverrides[target]?.trim() ?? '';
      final gateway = _normalizeGatewayBase(
        _gatewayOverrides[target]?.trim() ?? '',
      );
      final token = _authTokenOverrides[target]?.trim() ?? '';

      if (endpoint.isEmpty) {
        await prefs.remove(endpointKey);
      } else {
        await prefs.setString(endpointKey, endpoint);
      }

      if (gateway.isEmpty) {
        await prefs.remove(gatewayKey);
      } else {
        await prefs.setString(gatewayKey, gateway);
      }

      if (token.isEmpty) {
        await prefs.remove(tokenKey);
      } else {
        await prefs.setString(tokenKey, token);
      }
    }

    await _persistCustomProviders();
  }

  RemoteUploadTarget? _targetFromName(String? name) {
    if (name == null) {
      return null;
    }

    for (final target in RemoteUploadTarget.values) {
      if (target.name == name) {
        return target;
      }
    }
    return null;
  }

  Future<void> _restoreSettings() async {
    await _restoreCustomProviders();
    await _restorePersistedSettings();
    if (mounted) {
      _settingsRestored = true;
    }
  }

  Future<void> _restorePersistedSettings() async {
    final prefs = await _prefsFuture;

    for (final target in RemoteUploadTarget.values) {
      final endpoint = prefs.getString('$_prefsEndpointPrefix${target.name}');
      final gateway = prefs.getString('$_prefsGatewayPrefix${target.name}');
      final token = prefs.getString('$_prefsAuthTokenPrefix${target.name}');

      if (endpoint != null) {
        _endpointOverrides[target] = endpoint;
      }
      if (gateway != null) {
        _gatewayOverrides[target] = gateway;
      }
      if (token != null) {
        _authTokenOverrides[target] = token;
      }
    }

    // Restore selected provider if present (supports legacy enum name and new prefixed format).
    final persisted = prefs.getString(_prefsUploadTargetKey);

    if (!mounted) {
      return;
    }

    setState(() {
      if (persisted != null) {
        if (persisted.startsWith('custom:')) {
          final name = persisted.substring('custom:'.length);
          final idx = _providerList.indexWhere((p) => p.name == name);
          if (idx >= 0) {
            _selectedProviderIndex = idx;
            _uploadTarget = _providerList[idx].target;
          }
        } else if (persisted.startsWith('builtin:')) {
          final name = persisted.substring('builtin:'.length);
          final built = _targetFromName(name);
          if (built != null) {
            _uploadTarget = built;
            _selectedProviderIndex = -1;
          }
        } else {
          // Legacy enum name
          final persistedTarget = _targetFromName(persisted);
          if (persistedTarget != null) {
            _uploadTarget = persistedTarget;
            _selectedProviderIndex = -1;
          }
        }
      }

      if (_selectedProviderIndex >= 0) {
        _applyProviderToControllers(_providerList[_selectedProviderIndex]);
      } else {
        _loadTargetFields(_uploadTarget);
      }
    });
  }

  Future<void> _persistCustomProviders() async {
    final prefs = await _prefsFuture;
    final customs = _providerList
        .where((p) => !p.isBuiltin)
        .map((p) => p.toJson())
        .toList();
    await prefs.setString(_prefsCustomProvidersKey, jsonEncode(customs));
  }

  Future<void> _restoreCustomProviders() async {
    final prefs = await _prefsFuture;
    final raw = prefs.getString(_prefsCustomProvidersKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final customs = list
          .whereType<Map<String, dynamic>>()
          .map(_ProviderEntry.fromJson)
          .toList();
      if (customs.isNotEmpty) {
        setState(() {
          _providerList.addAll(customs);
        });
      }
    } catch (_) {
      // ignore parse errors
    }
  }

  void _buildProviderList() {
    _providerList = <_ProviderEntry>[];
    _selectedProviderIndex = -1;
  }

  void _loadTargetFields(RemoteUploadTarget target) {
    _selectedPublishedGatewayBase = null;
    _endpointController.text =
        _endpointOverrides[target] ?? target.defaultUploadEndpoint;
    _gatewayController.text = _normalizeGatewayBase(
      _gatewayOverrides[target] ?? target.defaultGatewayBase,
    );
    _authTokenController.text = _authTokenOverrides[target] ?? '';
  }

  void _onSelectedProviderIndexChanged(int index) {
    _persistCurrentTargetFields();
    setState(() {
      _selectedProviderIndex = index;
      _uploadTarget = _providerList[index].target;
      _applyProviderToControllers(_providerList[index]);
    });
    unawaited(_persistSettings());
  }

  void _applyProviderToControllers(_ProviderEntry entry) {
    _selectedPublishedGatewayBase = null;
    if (entry.isBuiltin) {
      _endpointController.text =
          _endpointOverrides[entry.target] ??
          entry.target.defaultUploadEndpoint;
      _gatewayController.text =
          _gatewayOverrides[entry.target] ??
          _normalizeGatewayBase(entry.target.defaultGatewayBase);
      _authTokenController.text = _authTokenOverrides[entry.target] ?? '';
    } else {
      _endpointController.text = entry.endpoint;
      _gatewayController.text = entry.gatewayBase;
      _authTokenController.text = entry.authToken;
    }
  }

  void _onEditProviderPressed() async {
    final current = _providerList[_selectedProviderIndex];
    final result = await _showProviderEditorDialog(context, existing: current);
    if (result == null) {
      return;
    }

    if (result is String && result == 'deleted') {
      // delete only custom entries
      if (!current.isBuiltin) {
        setState(() {
          _providerList.removeAt(_selectedProviderIndex);
          if (_providerList.isEmpty) {
            _selectedProviderIndex = -1;
            _uploadTarget = RemoteUploadTarget.pinata;
            _selectedPublishedGatewayBase = null;
            _endpointController.text = _uploadTarget.defaultUploadEndpoint;
            _gatewayController.text = _normalizeGatewayBase(
              _uploadTarget.defaultGatewayBase,
            );
            _authTokenController.text = '';
          } else {
            _selectedProviderIndex = 0;
            _uploadTarget = _providerList[_selectedProviderIndex].target;
            _applyProviderToControllers(_providerList[_selectedProviderIndex]);
          }
        });
        unawaited(_persistSettings());
      }
      return;
    }

    if (result is _ProviderEntry) {
      setState(() {
        if (current.isBuiltin) {
          // saving while a builtin is selected creates a new custom copy
          _providerList.add(result);
          _selectedProviderIndex = _providerList.length - 1;
        } else {
          _providerList[_selectedProviderIndex] = result;
        }
        _uploadTarget = result.target;
        _applyProviderToControllers(result);
      });
      unawaited(_persistSettings());
    }
  }

  Future<dynamic> _showProviderEditorDialog(
    BuildContext ctx, {
    _ProviderEntry? existing,
    RemoteUploadTarget? initialTarget,
  }) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    RemoteUploadTarget selectedTarget =
        existing?.target ?? initialTarget ?? RemoteUploadTarget.pinata;
    final endpointCtrl = TextEditingController(text: existing?.endpoint ?? '');
    final gatewayCtrl = TextEditingController(
      text: existing?.gatewayBase ?? '',
    );
    final authCtrl = TextEditingController(text: existing?.authToken ?? '');

    // Prefill defaults when adding a new provider
    if (existing == null) {
      nameCtrl.text = selectedTarget.label;
      endpointCtrl.text = selectedTarget.defaultUploadEndpoint;
      gatewayCtrl.text = _normalizeGatewayBase(
        selectedTarget.defaultGatewayBase,
      );
      authCtrl.text = '';
    }

    return showDialog<dynamic>(
      context: ctx,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            var previousDefaultEndpoint = selectedTarget.defaultUploadEndpoint;
            var previousDefaultGateway = _normalizeGatewayBase(
              selectedTarget.defaultGatewayBase,
            );
            var previousDefaultName = selectedTarget.label;

            return AlertDialog(
              title: Text(existing == null ? 'Add provider' : 'Edit provider'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<RemoteUploadTarget>(
                      initialValue: selectedTarget,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Provider type',
                      ),
                      items: RemoteUploadTarget.values
                          .map(
                            (t) => DropdownMenuItem(
                              value: t,
                              child: Text(t.label),
                            ),
                          )
                          .toList(),
                      onChanged: (t) {
                        if (t == null) return;
                        final newDefaultEndpoint = t.defaultUploadEndpoint;
                        final newDefaultGateway = _normalizeGatewayBase(
                          t.defaultGatewayBase,
                        );

                        // Update fields when adding or when current values equal previous defaults or are empty
                        if (existing == null ||
                            endpointCtrl.text.trim().isEmpty ||
                            endpointCtrl.text.trim() ==
                                previousDefaultEndpoint) {
                          endpointCtrl.text = newDefaultEndpoint;
                        }
                        if (existing == null ||
                            gatewayCtrl.text.trim().isEmpty ||
                            gatewayCtrl.text.trim() == previousDefaultGateway) {
                          gatewayCtrl.text = newDefaultGateway;
                        }
                        // If the name is still the previous default (or was left blank/empty for new entries), update it too
                        final newDefaultName = t.label;
                        final currentName = nameCtrl.text.trim();
                        if (existing == null ||
                            currentName.isEmpty ||
                            currentName == previousDefaultName ||
                            currentName == '$previousDefaultName (custom)') {
                          nameCtrl.text = newDefaultName;
                        }

                        selectedTarget = t;
                        previousDefaultEndpoint = newDefaultEndpoint;
                        previousDefaultGateway = newDefaultGateway;
                        previousDefaultName = newDefaultName;
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: endpointCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Upload endpoint',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: gatewayCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Gateway base',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: authCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Auth token (optional)',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (existing != null && !existing.isBuiltin)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop('deleted'),
                    child: const Text(
                      'Delete',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final entry = _ProviderEntry(
                      name: nameCtrl.text.trim().isEmpty
                          ? '${selectedTarget.label} (custom)'
                          : nameCtrl.text.trim(),
                      target: selectedTarget,
                      endpoint: endpointCtrl.text.trim(),
                      gatewayBase: _normalizeGatewayBase(
                        gatewayCtrl.text.trim(),
                      ),
                      authToken: authCtrl.text.trim(),
                      isBuiltin: false,
                    );
                    Navigator.of(context).pop(entry);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // _uploadDescription removed (unused)

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final publishedImage = _publishedImage;
    final downloadedImage = _downloadedImage;

    final isDarkTheme = theme.brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('IPFS Photo Relay'),
        actions: [
          IconButton(
            tooltip: isDarkTheme
                ? 'Switch to light theme'
                : 'Switch to dark theme',
            onPressed: widget.onThemeToggle,
            icon: Icon(isDarkTheme ? Icons.light_mode : Icons.dark_mode),
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
          child: SelectionArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StatusCard(
                        statusMessage: _statusMessage,
                        errorMessage: _errorMessage,
                      ),
                      const SizedBox(height: 16),
                      _TipsCard(theme: theme),
                      const SizedBox(height: 16),
                      const SizedBox(height: 0),
                      _SectionCard(
                        eyebrow: 'Send',
                        title: 'Upload a file and share the CID',
                        description:
                            'Publishing uploads the file to the configured remote backend and returns the shareable CID.',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Provider selection moved into Send section: render here before upload button
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: _selectedProviderIndex >= 0
                                        ? _selectedProviderIndex
                                        : null,
                                    isExpanded: true,
                                    decoration: InputDecoration(
                                      labelText: 'Upload path',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                    ),
                                    items: _providerList
                                        .asMap()
                                        .entries
                                        .map(
                                          (e) => DropdownMenuItem<int>(
                                            value: e.key,
                                            child: Text(e.value.name),
                                          ),
                                        )
                                        .toList(),
                                    hint: const Text(
                                      'No custom providers configured',
                                    ),
                                    onChanged: (idx) {
                                      if (idx != null) {
                                        _onSelectedProviderIndexChanged(idx);
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Edit provider',
                                  onPressed: _selectedProviderIndex >= 0
                                      ? _onEditProviderPressed
                                      : null,
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Add provider',
                                  onPressed: () {
                                    final initial = _selectedProviderIndex >= 0
                                        ? _providerList[_selectedProviderIndex]
                                              .target
                                        : _uploadTarget;
                                    _showProviderEditorDialog(
                                      context,
                                      initialTarget: initial,
                                    ).then((result) {
                                      if (result is _ProviderEntry) {
                                        setState(() {
                                          _providerList.add(result);
                                          _selectedProviderIndex =
                                              _providerList.length - 1;
                                          _uploadTarget = result.target;
                                          _applyProviderToControllers(result);
                                        });
                                        unawaited(_persistSettings());
                                      }
                                    });
                                  },
                                  icon: const Icon(Icons.add_outlined),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _isPublishing ? null : _publishImage,
                              icon: _isPublishing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.add_photo_alternate_outlined,
                                    ),
                              label: const Text('Select File'),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _openUploadHistory,
                              icon: const Icon(Icons.history_rounded),
                              label: const Text('History'),
                            ),
                            if (publishedImage != null) ...[
                              const SizedBox(height: 16),
                              _MetaRow(
                                label: 'Shareable CID',
                                value: publishedImage.cid,
                              ),
                              const SizedBox(height: 8),
                              _MetaRow(
                                label: 'Upload target',
                                value: publishedImage.remoteTarget.label,
                              ),
                              const SizedBox(height: 8),
                              _MetaRow(
                                label: 'Upload endpoint',
                                value: publishedImage.uploadEndpoint,
                              ),
                              const SizedBox(height: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Builder(
                                    builder: (context) {
                                      final options = _gatewayOptions(
                                        includeConfiguredGateway:
                                            _uploadTarget ==
                                            RemoteUploadTarget.kubo,
                                      );
                                      final selectedGateway =
                                          _selectedPublishedGatewayBase ??
                                          _defaultPublishedGatewayBase();
                                      final currentValue =
                                          options.any(
                                            (option) =>
                                                option['value'] ==
                                                selectedGateway,
                                          )
                                          ? selectedGateway
                                          : options.first['value']!;

                                      return DropdownButtonFormField<String>(
                                        initialValue: currentValue,
                                        isExpanded: true,
                                        decoration: InputDecoration(
                                          labelText: 'Gateway URL',
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                        ),
                                        items: options
                                            .map(
                                              (option) =>
                                                  DropdownMenuItem<String>(
                                                    value: option['value'],
                                                    child: Text(
                                                      option['label']!,
                                                    ),
                                                  ),
                                            )
                                            .toList(),
                                        onChanged: (value) {
                                          if (value != null) {
                                            setState(() {
                                              _selectedPublishedGatewayBase =
                                                  value;
                                            });
                                          }
                                        },
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    _publishedGatewayUrl(publishedImage),
                                    style: theme.textTheme.bodyLarge,
                                  ),
                                ],
                              ),
                              if (publishedImage.remoteUploadMessage !=
                                  null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  publishedImage.remoteUploadMessage!,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        _copyText(publishedImage.cid, 'CID'),
                                    icon: const Icon(Icons.copy_rounded),
                                    label: const Text('Copy CID'),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: _shareCid,
                                    icon: const Icon(Icons.share_outlined),
                                    label: const Text('Share CID'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () => _copyText(
                                      _publishedGatewayUrl(publishedImage),
                                      'Gateway URL',
                                    ),
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Gateway URL'),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: _openOrSharePublishedGatewayUrl,
                                    icon: Icon(
                                      _isDesktop
                                          ? Icons.open_in_browser_rounded
                                          : Icons.ios_share_rounded,
                                    ),
                                    label: Text(
                                      _isDesktop
                                          ? 'Open Gateway URL'
                                          : 'Share Gateway URL',
                                    ),
                                  ),
                                ],
                              ),
                              if (publishedImage.isImage &&
                                  publishedImage.bytes.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: AspectRatio(
                                    aspectRatio: 4 / 3,
                                    child: Image.memory(
                                      publishedImage.bytes,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        eyebrow: 'Receive',
                        title: 'Fetch the image through a gateway',
                        description:
                            'Paste the CID, point the app at a gateway that can serve it, and the downloaded file can be shared into Photos or Files.',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: _cidController,
                              minLines: 1,
                              maxLines: 3,
                              decoration: InputDecoration(
                                labelText: 'CID',
                                hintText: 'bafy... or Qm...',
                                suffixIcon: IconButton(
                                  tooltip: 'Paste CID',
                                  onPressed: () =>
                                      _pasteIntoController(_cidController),
                                  icon: const Icon(Icons.content_paste_rounded),
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Download gateway selector: default gateways + configured provider gateways (non-default)
                            StatefulBuilder(
                              builder: (context, setState) {
                                final options = _gatewayOptions();

                                final currentValue =
                                    (_selectedDownloadGateway != null &&
                                        _selectedDownloadGateway!.isNotEmpty)
                                    ? _normalizeGatewayBase(
                                        _selectedDownloadGateway!,
                                      )
                                    : _normalizeGatewayBase(
                                        _gatewayController.text,
                                      );

                                return DropdownButtonFormField<String>(
                                  initialValue:
                                      options.any(
                                        (o) => o['value'] == currentValue,
                                      )
                                      ? currentValue
                                      : options.first['value'],
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Gateway to fetch from',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                  ),
                                  items: options
                                      .map(
                                        (o) => DropdownMenuItem<String>(
                                          value: o['value'],
                                          child: Text(o['label']!),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) {
                                    setState(() {
                                      _selectedDownloadGateway = v;
                                    });
                                  },
                                );
                              },
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _isDownloading ? null : _downloadImage,
                              icon: _isDownloading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.download_rounded),
                              label: const Text('Download From CID'),
                            ),
                            if (downloadedImage != null) ...[
                              const SizedBox(height: 16),
                              _MetaRow(
                                label: 'Saved as',
                                value: downloadedImage.fileName,
                              ),
                              const SizedBox(height: 8),
                              _MetaRow(
                                label: 'Type',
                                value: downloadedImage.mimeType,
                              ),
                              const SizedBox(height: 8),
                              _MetaRow(
                                label: 'Fetched from',
                                value: downloadedImage.gatewayUrl,
                              ),
                              const SizedBox(height: 12),
                              FilledButton.tonalIcon(
                                onPressed: _receiveDownloadedFile,
                                icon: Icon(
                                  _isDesktop
                                      ? Icons.save_alt_rounded
                                      : Icons.ios_share_rounded,
                                ),
                                label: Text(
                                  _isDesktop
                                      ? 'Save Downloaded File'
                                      : 'Share Downloaded File',
                                ),
                              ),
                              if (downloadedImage.isImage) ...[
                                const SizedBox(height: 16),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: AspectRatio(
                                    aspectRatio: 4 / 3,
                                    child: Image.memory(
                                      downloadedImage.bytes,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UploadHistoryPage extends StatelessWidget {
  const _UploadHistoryPage({required this.entries});

  final List<_UploadHistoryEntry> entries;

  String _formatDateTime(DateTime dateTime) {
    final localTime = dateTime.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${localTime.year}-${twoDigits(localTime.month)}-${twoDigits(localTime.day)} '
        '${twoDigits(localTime.hour)}:${twoDigits(localTime.minute)}';
  }

  Widget _thumbnail(_UploadHistoryEntry entry) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
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
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        'No successful uploads yet.',
                        style: theme.textTheme.bodyLarge,
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: entries.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return Material(
                          color: theme.colorScheme.surface,
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
                            onTap: () => Navigator.of(context).pop(entry),
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
                                  const Icon(Icons.chevron_right_rounded),
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.statusMessage, required this.errorMessage});

  final String statusMessage;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Color(0xFF153243),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.cloud_upload_outlined,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Remote IPFS Mode',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(statusMessage, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                errorMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TipsCard extends StatelessWidget {
  const _TipsCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Practical test flow',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '1. Pick one remote backend and configure both its upload endpoint and a gateway that can serve the resulting CID.',
            ),
            const SizedBox(height: 6),
            const Text(
              '2. Upload the file on Phone A and share only the CID through your short-message channel.',
            ),
            const SizedBox(height: 6),
            const Text(
              '3. On Phone B, use the same backend or another reachable gateway to fetch the CID and share the downloaded file into the device gallery or files app.',
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.child,
  });

  final String eyebrow;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow.toUpperCase(),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(description, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(value, style: theme.textTheme.bodyLarge),
      ],
    );
  }
}
