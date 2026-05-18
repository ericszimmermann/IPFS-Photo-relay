import 'package:flutter_test/flutter_test.dart';

import 'package:test_dart_ipfs/src/app.dart';

void main() {
  testWidgets('shows the two-phone transfer flow', (WidgetTester tester) async {
    await tester.pumpWidget(const IpfsPhotoRelayApp(startNodeOnLoad: false));

    expect(find.text('IPFS Photo Relay'), findsOneWidget);
    expect(find.text('Choose where the file should live'), findsOneWidget);
    expect(find.text('Publish the image and share the route'), findsOneWidget);
    expect(find.text('Import a peer bundle and fetch by CID'), findsOneWidget);
    expect(find.text('Select Image'), findsOneWidget);
    expect(find.text('Download From CID'), findsOneWidget);
  });
}
