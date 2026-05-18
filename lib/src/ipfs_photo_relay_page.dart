import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ipfs/ipfs_transfer_service.dart';

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

  IpfsNodeSnapshot? _snapshot;
  PublishedImage? _publishedImage;
  DownloadedImage? _downloadedImage;

  bool _isStarting = false;
  bool _isPublishing = false;
  bool _isDownloading = false;

  String _statusMessage = 'Starting embedded IPFS node...';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.startNodeOnLoad) {
      _initializeNode();
    } else {
      _statusMessage = 'Node startup paused for test mode.';
    }
  }

  @override
  void dispose() {
    _cidController.dispose();
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
        _statusMessage = 'Node online. Share a CID with the other phone.';
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
      final publishedImage = await _service.pickAndPublishImage();
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

  Future<void> _copyCid(String cid) async {
    await Clipboard.setData(ClipboardData(text: cid));
    if (!mounted) {
      return;
    }
    _showSnack('CID copied to the clipboard.');
  }

  Future<void> _pasteCid() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) {
        return;
      }
      _showSnack('Clipboard is empty.');
      return;
    }

    _cidController.text = text;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
                  constraints: const BoxConstraints(maxWidth: 820),
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
                        eyebrow: 'Phone A',
                        title: 'Publish an image and share its CID',
                        description:
                            'Pick a photo, add it to the embedded IPFS node, then send only the CID through your messenger app.',
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
                                label: 'File',
                                value: publishedImage.fileName,
                              ),
                              const SizedBox(height: 8),
                              _MetaRow(
                                label: 'CID',
                                value: publishedImage.cid,
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () => _copyCid(publishedImage.cid),
                                    icon: const Icon(Icons.copy_rounded),
                                    label: const Text('Copy CID'),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: _shareCid,
                                    icon: const Icon(Icons.share_outlined),
                                    label: const Text('Share CID'),
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
                        title: 'Paste the CID and fetch the image',
                        description:
                            'Enter the CID received from the first phone, then resolve it through the IPFS node and share the downloaded file so it can be saved.',
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
                                  onPressed: _pasteCid,
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
              'How to try it on two phones',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            const Text('1. Install the app on both phones and keep both apps open.'),
            const SizedBox(height: 6),
            const Text('2. On phone A, publish a picture and share the CID with any messenger app.'),
            const SizedBox(height: 6),
            const Text('3. On phone B, paste the CID, download the image, and share it to Files or Photos to save it.'),
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
          Text(value, maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
