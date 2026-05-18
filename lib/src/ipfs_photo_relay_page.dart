import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ipfs/ipfs_transfer_service.dart';
import 'ipfs/remote_upload_client.dart';

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
  late final IpfsTransferService _service =
      widget.service ?? IpfsTransferService();
  final TextEditingController _cidController = TextEditingController();
  final TextEditingController _peerBundleController = TextEditingController();
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _authTokenController = TextEditingController();

  IpfsNodeSnapshot? _snapshot;
  PublishedImage? _publishedImage;
  DownloadedImage? _downloadedImage;
  PeerImportResult? _connectedPeer;

  RemoteUploadTarget _uploadTarget = RemoteUploadTarget.localOnly;

  bool _isStarting = false;
  bool _isPublishing = false;
  bool _isDownloading = false;
  bool _isConnectingPeer = false;

  String _statusMessage = 'Starting embedded IPFS node...';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _applyUploadTargetDefaults(_uploadTarget);
    if (widget.startNodeOnLoad) {
      _initializeNode();
    } else {
      _statusMessage = 'Node startup paused for test mode.';
    }
  }

  @override
  void dispose() {
    _cidController.dispose();
    _peerBundleController.dispose();
    _endpointController.dispose();
    _authTokenController.dispose();
    unawaited(_service.dispose());
    super.dispose();
  }

  Future<void> _initializeNode() async {
    setState(() {
      _isStarting = true;
      _errorMessage = null;
      _statusMessage = 'Starting embedded IPFS node...';
    });

    try {
      final snapshot = await _service.ensureStarted();
      if (!mounted) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
        _statusMessage =
            'Node online. Share a CID, a peer bundle, or mirror content to a remote IPFS backend.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = error.toString();
        _statusMessage = 'Node startup failed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isStarting = false;
        });
      }
    }
  }

  Future<void> _publishImage() async {
    setState(() {
      _isPublishing = true;
      _errorMessage = null;
      _statusMessage = 'Picking an image and publishing it to IPFS...';
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

      final snapshot = await _service.ensureStarted();
      if (!mounted) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
        _publishedImage = publishedImage;
        _cidController.text = publishedImage.cid;
        _statusMessage = 'Published ${publishedImage.fileName} to IPFS.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = error.toString();
        _statusMessage = 'Publishing failed.';
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
      _statusMessage = 'Resolving the CID and downloading content...';
    });

    try {
      final downloadedImage = await _service.downloadByCid(_cidController.text);
      if (!mounted) {
        return;
      }

      final snapshot = await _service.ensureStarted();
      if (!mounted) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
        _downloadedImage = downloadedImage;
        _statusMessage = 'Downloaded ${downloadedImage.fileName} from IPFS.';
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

  Future<void> _connectPeerBundle() async {
    final bundle = _peerBundleController.text.trim();
    if (bundle.isEmpty) {
      _showSnack('Paste a shared peer bundle first.');
      return;
    }

    setState(() {
      _isConnectingPeer = true;
      _errorMessage = null;
      _statusMessage = 'Importing peer bundle and opening a P2P connection...';
    });

    try {
      final connectedPeer = await _service.connectToSharedPeer(bundle);
      if (!mounted) {
        return;
      }

      final snapshot = await _service.ensureStarted();
      if (!mounted) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
        _connectedPeer = connectedPeer;
        if (connectedPeer.cid != null) {
          _cidController.text = connectedPeer.cid!;
        }
        _statusMessage = 'Connected to peer ${connectedPeer.peerId}.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = error.toString();
        _statusMessage = 'Peer import failed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isConnectingPeer = false;
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

  Future<void> _sharePeerBundle() async {
    final bundle = _publishedImage?.peerBundle;
    if (bundle == null) {
      return;
    }

    try {
      await _service.sharePeerBundle(bundle);
      if (!mounted) {
        return;
      }
      _showSnack('Peer bundle shared.');
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
      authToken: _authTokenController.text,
    );
  }

  void _applyUploadTargetDefaults(RemoteUploadTarget target) {
    switch (target) {
      case RemoteUploadTarget.localOnly:
        _endpointController.text = '';
      case RemoteUploadTarget.pinata:
        _endpointController.text = 'https://api.pinata.cloud/pinning/pinFileToIPFS';
      case RemoteUploadTarget.filebase:
        _endpointController.text = 'https://rpc.filebase.io/api/v0/add';
      case RemoteUploadTarget.kubo:
        _endpointController.text = 'http://127.0.0.1:5001/api/v0/add';
    }
  }

  String get _authTokenLabel {
    switch (_uploadTarget) {
      case RemoteUploadTarget.localOnly:
        return 'Auth token';
      case RemoteUploadTarget.pinata:
        return 'Pinata JWT';
      case RemoteUploadTarget.filebase:
        return 'Filebase API key';
      case RemoteUploadTarget.kubo:
        return 'Bearer token (optional)';
    }
  }

  String get _uploadDescription {
    switch (_uploadTarget) {
      case RemoteUploadTarget.localOnly:
        return 'Only publish to the embedded phone node.';
      case RemoteUploadTarget.pinata:
        return 'Upload the file directly to Pinata using the `pinFileToIPFS` endpoint.';
      case RemoteUploadTarget.filebase:
        return 'Upload the file through Filebase\'s official Kubo-compatible RPC API.';
      case RemoteUploadTarget.kubo:
        return 'Upload the file to a self-hosted Kubo RPC endpoint, for example over VPN.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final publishedImage = _publishedImage;
    final downloadedImage = _downloadedImage;

    return Scaffold(
      appBar: AppBar(
        title: const Text('IPFS Photo Relay'),
        actions: [
          IconButton(
            tooltip: 'Refresh node',
            onPressed: _isStarting ? null : _initializeNode,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
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
                        snapshot: _snapshot,
                        isStarting: _isStarting,
                        statusMessage: _statusMessage,
                        errorMessage: _errorMessage,
                      ),
                      const SizedBox(height: 16),
                      _TipsCard(theme: theme),
                      const SizedBox(height: 16),
                      _SectionCard(
                        eyebrow: 'Delivery Path',
                        title: 'Choose where the file should live',
                        description:
                            'Use the phone node only for direct P2P experiments, or mirror the same file to Pinata, Filebase, or a Kubo API so the CID has a stronger chance of being retrievable across networks.',
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
                                if (target == null) {
                                  return;
                                }
                                setState(() {
                                  _uploadTarget = target;
                                  _applyUploadTargetDefaults(target);
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            Text(_uploadDescription, style: theme.textTheme.bodyMedium),
                            if (_uploadTarget != RemoteUploadTarget.localOnly) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _endpointController,
                                decoration: InputDecoration(
                                  labelText: 'Endpoint',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _authTokenController,
                                obscureText: true,
                                decoration: InputDecoration(
                                  labelText: _authTokenLabel,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        eyebrow: 'Phone A',
                        title: 'Publish the image and share the route',
                        description:
                            'Publishing creates a local IPFS CID, optionally mirrors the file to a remote backend, and prepares a peer bundle with multiaddrs that you can share separately if you want to try direct P2P.',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FilledButton.icon(
                              onPressed:
                                  _isStarting || _isPublishing
                                      ? null
                                      : _publishImage,
                              icon: _isPublishing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.add_photo_alternate_outlined),
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
                                label: 'Local CID',
                                value: publishedImage.localCid,
                              ),
                              if (publishedImage.remoteCid != null) ...[
                                const SizedBox(height: 8),
                                _MetaRow(
                                  label: 'Remote CID (${publishedImage.remoteTarget?.label})',
                                  value: publishedImage.remoteCid!,
                                ),
                              ],
                              if (publishedImage.remoteUploadMessage != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  publishedImage.remoteUploadMessage!,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                              const SizedBox(height: 8),
                              _MetaRow(
                                label: 'Peer bundle',
                                value: publishedImage.peerBundle,
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () => _copyText(
                                      publishedImage.cid,
                                      'CID',
                                    ),
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
                                      publishedImage.peerBundle,
                                      'Peer bundle',
                                    ),
                                    icon: const Icon(Icons.copy_all_rounded),
                                    label: const Text('Copy Peer Bundle'),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: _sharePeerBundle,
                                    icon: const Icon(Icons.route_outlined),
                                    label: const Text('Share Peer Bundle'),
                                  ),
                                ],
                              ),
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
                        ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        eyebrow: 'Phone B',
                        title: 'Import a peer bundle and fetch by CID',
                        description:
                            'Paste a shared multiaddr bundle to try a direct P2P connection, or just paste the CID if the content was mirrored to a remote IPFS backend.',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: _peerBundleController,
                              minLines: 3,
                              maxLines: 7,
                              decoration: InputDecoration(
                                labelText: 'Peer bundle or multiaddr',
                                hintText: 'PEER_ID=...\nCID=...\nMULTIADDR=/ip4/.../tcp/.../p2p/...',
                                suffixIcon: IconButton(
                                  tooltip: 'Paste peer bundle',
                                  onPressed: () => _pasteIntoController(
                                    _peerBundleController,
                                  ),
                                  icon: const Icon(Icons.content_paste_rounded),
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed:
                                  _isStarting || _isConnectingPeer
                                      ? null
                                      : _connectPeerBundle,
                              icon: _isConnectingPeer
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.link_rounded),
                              label: const Text('Import And Connect'),
                            ),
                            if (_connectedPeer != null) ...[
                              const SizedBox(height: 12),
                              _MetaRow(
                                label: 'Connected peer',
                                value: _connectedPeer!.peerId,
                              ),
                              const SizedBox(height: 8),
                              _MetaRow(
                                label: 'Using multiaddr',
                                value: _connectedPeer!.multiaddr,
                              ),
                            ],
                            const SizedBox(height: 16),
                            TextField(
                              controller: _cidController,
                              minLines: 1,
                              maxLines: 3,
                              decoration: InputDecoration(
                                labelText: 'CID',
                                hintText: 'bafy... or Qm...',
                                suffixIcon: IconButton(
                                  tooltip: 'Paste CID',
                                  onPressed: () => _pasteIntoController(
                                    _cidController,
                                  ),
                                  icon: const Icon(Icons.content_paste_rounded),
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed:
                                  _isStarting || _isDownloading
                                      ? null
                                      : _downloadImage,
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
  const _StatusCard({
    required this.snapshot,
    required this.isStarting,
    required this.statusMessage,
    required this.errorMessage,
  });

  final IpfsNodeSnapshot? snapshot;
  final bool isStarting;
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
                  child: const Icon(Icons.hub_outlined, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Embedded Full Node',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        statusMessage,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                if (isStarting)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
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
            if (snapshot != null) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _InfoChip(
                    label: 'Peer ID',
                    value: snapshot!.peerId,
                  ),
                  _InfoChip(
                    label: 'Connected peers',
                    value: '${snapshot!.connectedPeers}',
                  ),
                  _InfoChip(
                    label: 'Listen addresses',
                    value: snapshot!.addresses.isEmpty
                        ? 'None reported yet'
                        : '${snapshot!.addresses.length}',
                  ),
                ],
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
            const Text('1. Publish the image locally, and mirror it to Pinata, Filebase RPC, or your Kubo API if you want CID-only retrieval across networks.'),
            const SizedBox(height: 6),
            const Text('2. Share the CID through your short-message channel, and share the peer bundle separately if you also want to test direct P2P dialing.'),
            const SizedBox(height: 6),
            const Text('3. On the receiving phone, import the peer bundle first when trying P2P, then fetch by CID.'),
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
        SelectableText(
          value,
          style: theme.textTheme.bodyLarge,
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, maxLines: 4, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
