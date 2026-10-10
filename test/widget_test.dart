import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:test_dart_ipfs/src/app.dart';
import 'package:test_dart_ipfs/src/ipfs/ipfs_transfer_service.dart';
import 'package:test_dart_ipfs/src/ipfs/remote_upload_client.dart';

class _CapturingTransferService extends IpfsTransferService {
  RemoteUploadConfig? uploadConfig;
  String? openedGatewayUrl;
  String? sharedGatewayUrl;

  @override
  Future<PublishedImage?> pickAndPublishImage({
    required RemoteUploadConfig remoteUploadConfig,
  }) async {
    uploadConfig = remoteUploadConfig;
    const cid = 'bafy-custom-gateway-test';
    return PublishedImage(
      cid: cid,
      fileName: 'photo.jpg',
      bytes: Uint8List(0),
      mimeType: 'application/octet-stream',
      remoteTarget: remoteUploadConfig.target,
      uploadEndpoint: remoteUploadConfig.resolvedEndpoint,
      gatewayUrl: '${remoteUploadConfig.resolvedGatewayBase}$cid',
    );
  }

  @override
  Future<void> openGatewayUrl(String gatewayUrl) async {
    openedGatewayUrl = gatewayUrl;
  }

  @override
  Future<void> shareGatewayUrl(String gatewayUrl) async {
    sharedGatewayUrl = gatewayUrl;
  }
}

void main() {
  testWidgets('shows the remote transfer flow', (WidgetTester tester) async {
    await tester.pumpWidget(const IpfsPhotoRelayApp(startNodeOnLoad: false));

    expect(find.text('IPFS Photo Relay'), findsOneWidget);
    expect(find.text('Upload path'), findsOneWidget);
    expect(find.text('Upload a file and share the CID'), findsOneWidget);
    expect(find.text('Fetch the image through a gateway'), findsOneWidget);
    expect(find.text('Select File'), findsOneWidget);
    expect(find.text('Download From CID'), findsOneWidget);
  });

  testWidgets('restores the selected custom Kubo provider', (
    WidgetTester tester,
  ) async {
    const endpoint = 'http://100.66.192.118:5001/api/v0/add';
    const gateway = 'http://100.66.192.118:8080/ipfs/';
    SharedPreferences.setMockInitialValues({
      'relay.customProviders': jsonEncode([
        {
          'name': 'LY tailscale',
          'target': 'kubo',
          'endpoint': endpoint,
          'gatewayBase': gateway,
          'authToken': '',
        },
        {
          'name': 'Filebase path',
          'target': 'filebase',
          'endpoint': 'https://rpc.filebase.io/api/v0/add',
          'gatewayBase': 'https://ipfs.filebase.io/ipfs/',
          'authToken': 'test-token',
        },
      ]),
      'relay.uploadTarget': 'custom:LY tailscale',
    });

    final service = _CapturingTransferService();
    await tester.pumpWidget(
      MaterialApp(
        home: IpfsPhotoRelayPage(startNodeOnLoad: false, service: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LY tailscale'), findsOneWidget);
    final uploadButton = find.text('Select File');
    await tester.ensureVisible(uploadButton);
    await tester.pumpAndSettle();
    await tester.tap(uploadButton);
    await tester.pumpAndSettle();

    expect(service.uploadConfig?.resolvedEndpoint, endpoint);
    expect(service.uploadConfig?.resolvedGatewayBase, gateway);
    expect(find.text('${gateway}bafy-custom-gateway-test'), findsOneWidget);
    expect(find.text('LY tailscale'), findsNWidgets(2));

    final uploadPathDropdown = find.byType(DropdownButtonFormField<int>);
    await tester.ensureVisible(uploadPathDropdown);
    await tester.tap(uploadPathDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filebase path'));
    await tester.pumpAndSettle();
    expect(
      find.text('https://ipfs.filebase.io/ipfs/bafy-custom-gateway-test'),
      findsOneWidget,
    );
  });

  testWidgets(
    'opens gateway URLs in the browser on desktop',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});

      final service = _CapturingTransferService();
      await tester.pumpWidget(
        MaterialApp(
          home: IpfsPhotoRelayPage(startNodeOnLoad: false, service: service),
        ),
      );
      await tester.pumpAndSettle();

      final uploadButton = find.text('Select File');
      await tester.ensureVisible(uploadButton);
      await tester.pumpAndSettle();
      await tester.tap(uploadButton);
      await tester.pumpAndSettle();

      final openButton = find.text('Open Gateway URL');
      await tester.ensureVisible(openButton);
      await tester.pumpAndSettle();
      expect(
        find.text('https://gateway.pinata.cloud/ipfs/bafy-custom-gateway-test'),
        findsOneWidget,
      );
      final publishGatewayDropdown =
          find.byType(DropdownButtonFormField<String>).first;
      await tester.ensureVisible(publishGatewayDropdown);
      await tester.tap(publishGatewayDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filebase Public').last);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'https://ipfs.filebase.io/ipfs/bafy-custom-gateway-test',
        ),
        findsOneWidget,
      );
      await tester.tap(openButton);
      await tester.pumpAndSettle();

      expect(
        service.openedGatewayUrl,
        'https://ipfs.filebase.io/ipfs/bafy-custom-gateway-test',
      );
      expect(service.sharedGatewayUrl, isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  test('uses the supported remote targets only', () {
    expect(RemoteUploadTarget.values.map((target) => target.name), [
      'pinata',
      'filebase',
      'kubo',
    ]);
  });
}
