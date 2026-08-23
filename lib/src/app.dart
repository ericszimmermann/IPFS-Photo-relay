import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ipfs/ipfs_transfer_service.dart';
import 'ipfs/remote_upload_client.dart';

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

  PublishedImage? _publishedImage;
  DownloadedImage? _downloadedImage;
  RemoteUploadTarget _uploadTarget = RemoteUploadTarget.pinata;

  bool _isPublishing = false;
  bool _isDownloading = false;

  String _statusMessage =
      'Remote mode active. Upload to Pinata, Filebase RPC, IPFS.NINJA, or a Kubo node.';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTargetFields(_uploadTarget);
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

  void _applyGatewayValidation(String value) {
    final normalizedValue = _normalizeGatewayBase(value);
    if (normalizedValue != value) {
      _gatewayController.value = TextEditingValue(
        text: normalizedValue,
        selection: TextSelection.collapsed(offset: normalizedValue.length),
      );
    }
  }

  void _persistCurrentTargetFields() {
    _endpointOverrides[_uploadTarget] = _endpointController.text;
    _gatewayOverrides[_uploadTarget] = _normalizeGatewayBase(
      _gatewayController.text,
    );
    _authTokenOverrides[_uploadTarget] = _authTokenController.text;
  }

  Future<void> _persistSettings() async {
    _persistCurrentTargetFields();

    final prefs = await _prefsFuture;
    await prefs.setString(_prefsUploadTargetKey, _uploadTarget.name);

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

    final persistedTarget = _targetFromName(
      prefs.getString(_prefsUploadTargetKey),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      if (persistedTarget != null) {
        _uploadTarget = persistedTarget;
      }
      _loadTargetFields(_uploadTarget);
    });
  }

  void _loadTargetFields(RemoteUploadTarget target) {
    _endpointController.text =
        _endpointOverrides[target] ?? target.defaultUploadEndpoint;
    _gatewayController.text = _normalizeGatewayBase(
      _gatewayOverrides[target] ?? target.defaultGatewayBase,
    );
    _authTokenController.text = _authTokenOverrides[target] ?? '';
  }

  void _onUploadTargetChanged(RemoteUploadTarget target) {
    _persistCurrentTargetFields();
    setState(() {
      _uploadTarget = target;
      _loadTargetFields(target);
    });
    unawaited(_persistSettings());
  }

  void _onEndpointChanged(String _) {
    unawaited(_persistSettings());
  }

  void _onGatewayChanged(String value) {
    _applyGatewayValidation(value);
    unawaited(_persistSettings());
  }

  void _onAuthTokenChanged(String _) {
    unawaited(_persistSettings());
  }

  String get _authTokenLabel {
    switch (_uploadTarget) {
      case RemoteUploadTarget.pinata:
        return 'Pinata JWT';
      case RemoteUploadTarget.filebase:
        return 'Filebase API token';
      case RemoteUploadTarget.ipfsNinja:
        return 'IPFS.NINJA API key';
      case RemoteUploadTarget.kubo:
        return 'Bearer token (optional)';
    }
  }

  String get _uploadDescription {
    switch (_uploadTarget) {
      case RemoteUploadTarget.pinata:
        return 'Upload the file directly to Pinata and fetch it again through a Pinata gateway.';
      case RemoteUploadTarget.filebase:
        return 'Upload through Filebase\'s Kubo-compatible RPC API and retrieve through the Filebase IPFS gateway.';
      case RemoteUploadTarget.ipfsNinja:
        return 'Upload through IPFS.NINJA\'s REST API and retrieve through its public IPFS gateway.';
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
                            'This branch is remote-only. The app uploads straight to Pinata, Filebase RPC, IPFS.NINJA, or your own Kubo API and later fetches the CID back through a gateway.',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DropdownButtonFormField<RemoteUploadTarget>(
                              initialValue: _uploadTarget,
                              decoration: InputDecoration(
                                labelText: 'Upload path',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              items: RemoteUploadTarget.values
                                  .map(
                                    (target) => DropdownMenuItem(
                                      value: target,
                                      child: Text(target.label),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (target) {
                                if (target != null) {
                                  _onUploadTargetChanged(target);
                                }
                              },
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _uploadDescription,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _endpointController,
                              onChanged: _onEndpointChanged,
                              decoration: InputDecoration(
                                labelText: 'Upload endpoint',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _gatewayController,
                              onChanged: _onGatewayChanged,
                              decoration: InputDecoration(
                                labelText: 'Gateway base',
                                hintText: 'https://gateway.example.com/ipfs/',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _authTokenController,
                              onChanged: _onAuthTokenChanged,
                              obscureText: true,
                              decoration: InputDecoration(
                                labelText: _authTokenLabel,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
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
