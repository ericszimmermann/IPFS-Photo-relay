import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ipfs/ipfs_transfer_service.dart';
import 'ipfs/remote_upload_client.dart';

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
    final targetName = json['target'] as String? ?? RemoteUploadTarget.pinata.name;
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

class IpfsPhotoRelayApp extends StatelessWidget {
  const IpfsPhotoRelayApp({super.key, this.startNodeOnLoad = true});

  final bool startNodeOnLoad;

  @override
  Widget build(BuildContext context) {
    const canvas = Color(0xFFF5F1E8);
    const ink = Color(0xFF153243);
    const accent = Color(0xFF1F7A8C);
    const highlight = Color(0xFFF4B942);

    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.light,
        ).copyWith(
          primary: accent,
          secondary: highlight,
          surface: Colors.white,
          onPrimary: Colors.white,
          onSurface: ink,
        );

    return MaterialApp(
      title: 'IPFS Photo Relay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: canvas,
        useMaterial3: true,
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: ink,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white.withValues(alpha: 0.92),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: ink.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: IpfsPhotoRelayPage(startNodeOnLoad: startNodeOnLoad),
    );
  }
}

class IpfsPhotoRelayPage extends StatefulWidget {
  const IpfsPhotoRelayPage({
    super.key,
    required this.startNodeOnLoad,
    this.service,
  });

  final bool startNodeOnLoad;
  final IpfsTransferService? service;

  @override
  State<IpfsPhotoRelayPage> createState() => _IpfsPhotoRelayPageState();
}

class _IpfsPhotoRelayPageState extends State<IpfsPhotoRelayPage> {
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

  // Provider list: only user-defined (custom) entries.
  late List<_ProviderEntry> _providerList;
  // -1 means no custom provider selected (use builtin/legacy selection)
  int _selectedProviderIndex = -1;

  PublishedImage? _publishedImage;
  DownloadedImage? _downloadedImage;
  RemoteUploadTarget _uploadTarget = RemoteUploadTarget.pinata;

  bool _isPublishing = false;
  bool _isDownloading = false;

  String _statusMessage =
      'Remote mode active. Upload to Pinata, Filebase RPC, or a Kubo node.';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _buildProviderList();
    _loadTargetFields(_uploadTarget);
    unawaited(_restoreCustomProviders());
    unawaited(_restorePersistedSettings());
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
    setState(() {
      _isPublishing = true;
      _errorMessage = null;
      _statusMessage = 'Picking an image and uploading it to remote IPFS...';
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

      setState(() {
        _publishedImage = publishedImage;
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

  Future<void> _downloadImage() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _statusMessage = 'Fetching the CID through the configured gateway...';
    });

    try {
      final downloadedImage = await _service.downloadByCid(
        rawCid: _cidController.text,
        remoteUploadConfig: _currentRemoteUploadConfig(),
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

  Future<void> _sharePublishedGatewayUrl() async {
    final gatewayUrl = _publishedImage?.gatewayUrl;
    if (gatewayUrl == null) {
      return;
    }

    try {
      await _service.shareGatewayUrl(gatewayUrl);
      if (!mounted) {
        return;
      }
      _showSnack('Gateway URL shared.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('Sharing failed: $error');
    }
  }

  Future<void> _shareDownloadedFile() async {
    final image = _downloadedImage;
    if (image == null) {
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


  void _persistCurrentTargetFields() {
    final selected = _selectedProviderIndex >= 0 ? _providerList[_selectedProviderIndex] : null;
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
    _persistCurrentTargetFields();

    final prefs = await _prefsFuture;
    // Persist selected provider: builtin:<name> or custom:<name>
    final selected = _selectedProviderIndex >= 0 ? _providerList[_selectedProviderIndex] : null;
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

      _loadTargetFields(_uploadTarget);
    });
  }

  Future<void> _persistCustomProviders() async {
    final prefs = await _prefsFuture;
    final customs = _providerList.where((p) => !p.isBuiltin).map((p) => p.toJson()).toList();
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
      final customs = list.whereType<Map<String, dynamic>>().map(_ProviderEntry.fromJson).toList();
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
    if (entry.isBuiltin) {
      _endpointController.text = _endpointOverrides[entry.target] ?? entry.target.defaultUploadEndpoint;
      _gatewayController.text = _gatewayOverrides[entry.target] ?? _normalizeGatewayBase(entry.target.defaultGatewayBase);
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
            _endpointController.text = _uploadTarget.defaultUploadEndpoint;
            _gatewayController.text = _normalizeGatewayBase(_uploadTarget.defaultGatewayBase);
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



  Future<dynamic> _showProviderEditorDialog(BuildContext ctx, { _ProviderEntry? existing, RemoteUploadTarget? initialTarget, }) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    RemoteUploadTarget selectedTarget = existing?.target ?? initialTarget ?? RemoteUploadTarget.pinata;
    final endpointCtrl = TextEditingController(text: existing?.endpoint ?? '');
    final gatewayCtrl = TextEditingController(text: existing?.gatewayBase ?? '');
    final authCtrl = TextEditingController(text: existing?.authToken ?? '');

    // Prefill defaults when adding a new provider
    if (existing == null) {
      nameCtrl.text = selectedTarget.label;
      endpointCtrl.text = selectedTarget.defaultUploadEndpoint;
      gatewayCtrl.text = _normalizeGatewayBase(selectedTarget.defaultGatewayBase);
      authCtrl.text = '';
    }

    return showDialog<dynamic>(
      context: ctx,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          var previousDefaultEndpoint = selectedTarget.defaultUploadEndpoint;
          var previousDefaultGateway = _normalizeGatewayBase(selectedTarget.defaultGatewayBase);

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
                    decoration: const InputDecoration(labelText: 'Provider type'),
                    items: RemoteUploadTarget.values
                        .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
                        .toList(),
                    onChanged: (t) {
                      if (t == null) return;
                      final newDefaultEndpoint = t.defaultUploadEndpoint;
                      final newDefaultGateway = _normalizeGatewayBase(t.defaultGatewayBase);

                      // Update fields when adding or when current values equal previous defaults or are empty
                      if (existing == null || endpointCtrl.text.trim().isEmpty || endpointCtrl.text.trim() == previousDefaultEndpoint) {
                        endpointCtrl.text = newDefaultEndpoint;
                      }
                      if (existing == null || gatewayCtrl.text.trim().isEmpty || gatewayCtrl.text.trim() == previousDefaultGateway) {
                        gatewayCtrl.text = newDefaultGateway;
                      }

                      selectedTarget = t;
                      previousDefaultEndpoint = newDefaultEndpoint;
                      previousDefaultGateway = newDefaultGateway;
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: endpointCtrl,
                    decoration: const InputDecoration(labelText: 'Upload endpoint'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: gatewayCtrl,
                    decoration: const InputDecoration(labelText: 'Gateway base'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: authCtrl,
                    decoration: const InputDecoration(labelText: 'Auth token (optional)'),
                  ),
                ],
              ),
            ),
            actions: [
              if (existing != null && !existing.isBuiltin)
                TextButton(
                  onPressed: () => Navigator.of(context).pop('deleted'),
                  child: const Text('Delete', style: TextStyle(color: Colors.red)),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final entry = _ProviderEntry(
                    name: nameCtrl.text.trim().isEmpty ? '${selectedTarget.label} (custom)' : nameCtrl.text.trim(),
                    target: selectedTarget,
                    endpoint: endpointCtrl.text.trim(),
                    gatewayBase: _normalizeGatewayBase(gatewayCtrl.text.trim()),
                    authToken: authCtrl.text.trim(),
                    isBuiltin: false,
                  );
                  Navigator.of(context).pop(entry);
                },
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
  }

  

  String get _uploadDescription {
    switch (_uploadTarget) {
      case RemoteUploadTarget.pinata:
        return 'Upload the file directly to Pinata and fetch it again through a Pinata gateway.';
      case RemoteUploadTarget.filebase:
        return 'Upload through Filebase\'s Kubo-compatible RPC API and retrieve through the Filebase IPFS gateway.';
      case RemoteUploadTarget.kubo:
        return 'Upload to your own Kubo API and fetch from your chosen gateway, including a VPN-exposed node.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final publishedImage = _publishedImage;
    final downloadedImage = _downloadedImage;

    return Scaffold(
      appBar: AppBar(title: const Text('IPFS Photo Relay')),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFF7E2), Color(0xFFE8F1F2)],
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
                      _SectionCard(
                        eyebrow: 'Remote Backend',
                        title: 'Choose where the file will live',
                        description:
                            'This branch is remote-only. The app uploads straight to Pinata, Filebase RPC, or your own Kubo API and later fetches the CID back through a gateway.',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: _selectedProviderIndex >= 0 ? _selectedProviderIndex : null,
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
                                    hint: const Text('No custom providers configured'),
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
                                  onPressed: _selectedProviderIndex >= 0 ? _onEditProviderPressed : null,
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Add provider',
                                  onPressed: () {
                                    final initial = _selectedProviderIndex >= 0 ? _providerList[_selectedProviderIndex].target : _uploadTarget;
                                    _showProviderEditorDialog(context, initialTarget: initial).then((result) {
                                      if (result is _ProviderEntry) {
                                        setState(() {
                                          _providerList.add(result);
                                          _selectedProviderIndex = _providerList.length - 1;
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
                            const SizedBox(height: 8),
                            const SizedBox(height: 4),
                            const SizedBox(height: 12),
                            Text(
                              _uploadDescription,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        eyebrow: 'Send',
                        title: 'Upload the image and share the CID',
                        description:
                            'Publishing uploads the file to the configured remote backend and returns the shareable CID. This is the path to use when you do not want the app to run a local IPFS node.',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
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
                              label: const Text('Select Image'),
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
                              _MetaRow(
                                label: 'Gateway URL',
                                value: publishedImage.gatewayUrl,
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
                                      publishedImage.gatewayUrl,
                                      'Gateway URL',
                                    ),
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Gateway URL'),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: _sharePublishedGatewayUrl,
                                    icon: const Icon(Icons.ios_share_rounded),
                                    label: const Text('Share Gateway URL'),
                                  ),
                                ],
                              ),
                              if (publishedImage.isImage) ...[
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
                                onPressed: _shareDownloadedFile,
                                icon: const Icon(Icons.ios_share_rounded),
                                label: const Text('Share Downloaded File'),
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
              '2. Upload the image on Phone A and share only the CID through your short-message channel.',
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
