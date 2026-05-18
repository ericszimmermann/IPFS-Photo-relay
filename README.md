# IPFS Photo Relay

Simple Flutter proof of concept for transferring a picture between two phones with an embedded IPFS node, plus optional remote IPFS upload targets for more reliable cross-network retrieval.

## What It Does

- Phone A picks an image, adds it to the embedded phone node, and shares the CID.
- The app can also share a peer bundle that includes the peer ID and usable multiaddrs so Phone B can try a direct P2P connection first.
- The same file can optionally be mirrored to Pinata, Filebase RPC, or a self-hosted Kubo API, which is the more realistic path when the two phones are on different networks.
- Phone B can import the peer bundle, paste the CID, fetch the content, and share the downloaded file so it can be saved with the platform share sheet.
- The IPFS logic lives in a reusable service layer so it can be imported into another Flutter app later.

## Project Shape

- `lib/src/ipfs/ipfs_transfer_service.dart`: embedded node startup, publish, fetch, pin, provider announcement, peer bundle import/export, and share helpers.
- `lib/src/ipfs/remote_upload_client.dart`: Pinata, Filebase RPC, and Kubo-compatible multipart upload client.
- `lib/src/ipfs_photo_relay_page.dart`: proof-of-concept UI for the two-phone flow.
- `lib/src/app.dart`: app theme and top-level wiring.

## Running It

```bash
flutter pub get
flutter run
```

Install it on two phones, keep both apps open, then:

1. On Phone A, choose an upload path.
2. Tap `Select Image`.
3. Share the CID through your messenger app.
4. If you want to try direct peer dialing too, share the peer bundle separately.
5. On Phone B, optionally import the peer bundle first, then paste the CID and tap `Download From CID`.
6. Use `Share Downloaded File` to save the image via the platform share sheet.

## Upload Paths

### Local Only

The file is added only to the embedded node on the publishing phone. This is useful for direct P2P experiments, but cross-network retrieval depends on mobile reachability, provider advertisement, and the limits of the current Dart IPFS stack.

### Pinata

- Default endpoint: `https://api.pinata.cloud/pinning/pinFileToIPFS`
- Auth field: Pinata JWT bearer token
- Intended use: easier CID-only sharing when the phones are not on the same network

### Filebase RPC

- Default endpoint: `https://rpc.filebase.io/api/v0/add`
- Auth field: Filebase API key sent as `Authorization: Bearer <api-key>`
- Implemented against Filebase's Kubo-compatible RPC API

### Self-Hosted Kubo

- Default endpoint: `http://127.0.0.1:5001/api/v0/add`
- Auth field: optional bearer token
- Intended use: your own reachable Kubo node, including one exposed over VPN or reverse proxy

## Notes

- The app now publishes raw file bytes locally so the shareable CID is closer to what remote RPC add endpoints return for the same file.
- Peer bundles filter out obviously unusable listen addresses such as `0.0.0.0` and `127.0.0.1`, but direct P2P across mobile networks can still fail if neither phone is dialable.
- `flutter analyze` passes.
- `flutter test` is currently blocked on this Windows machine because the `sodium` dependency used by `dart_ipfs` tries to build a native asset and expects Visual Studio build tooling (`vswhere`) to be installed.
