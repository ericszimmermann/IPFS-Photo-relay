import 'package:flutter_test/flutter_test.dart';

import 'package:test_dart_ipfs/src/app.dart';

void main() {
  testWidgets('shows the remote transfer flow', (WidgetTester tester) async {
    await tester.pumpWidget(const IpfsPhotoRelayApp(startNodeOnLoad: false));

    expect(find.text('IPFS Photo Relay'), findsOneWidget);
    expect(find.text('Choose where the file will live'), findsOneWidget);
    expect(find.text('Upload the image and share the CID'), findsOneWidget);
    expect(find.text('Fetch the image through a gateway'), findsOneWidget);
    expect(find.text('Select Image'), findsOneWidget);
    expect(find.text('Download From CID'), findsOneWidget);
  });
}
