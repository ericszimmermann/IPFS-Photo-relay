# IPFS Photo Relay

Simple Flutter proof of concept for sending a picture between two phones by sharing only a CID, while using remote IPFS infrastructure instead of an embedded on-device node.

## What Changed On This Branch

- The local `dart_ipfs` node dependency was removed.
- The app is now remote-only.
- Uploads go directly to Pinata, Filebase RPC, or a self-hosted Kubo API.
- Downloads happen through a configurable gateway instead of Bitswap or local peer discovery.

This branch is the better fit if your real delivery path is still remote anyway and you do not want the native complexity of an embedded IPFS node in the mobile app.

## What It Does

- Phone A selects an image and uploads it to a remote IPFS backend.
- The backend returns a CID, which can be shared through a short-message channel.
- Phone B pastes the CID, uses a configured gateway to fetch the file, and shares the downloaded file into Photos or Files.
- The transfer logic still lives in a reusable service layer so it can be imported into another Flutter app later.

## Project Shape

- `lib/src/ipfs/ipfs_transfer_service.dart`: file picking, remote upload, remote download, CID validation, and share helpers.
- `lib/src/ipfs/remote_upload_client.dart`: HTTP client for Pinata, Filebase RPC, Kubo-compatible upload APIs, and gateway downloads.
- `lib/src/ipfs_photo_relay_page.dart`: remote-only proof-of-concept UI.
- `lib/src/app.dart`: app theme and top-level wiring.

## Running It

```bash
flutter pub get
flutter run
```

Install it on two phones, then:

1. Choose a remote backend.
2. Confirm the upload endpoint and gateway base.
3. Enter the backend token if needed.
4. On Phone A, tap `Select Image`.
5. Share the returned CID through your messenger app.
6. On Phone B, paste the CID and tap `Download From CID`.
7. Use `Share Downloaded File` to save the file through the platform share sheet.

## Supported Remote Paths

### Pinata

- Upload endpoint default: `https://api.pinata.cloud/pinning/pinFileToIPFS`
- Gateway default: `https://gateway.pinata.cloud/ipfs/`
- Auth: Pinata JWT bearer token

### Filebase RPC

- Upload endpoint default: `https://rpc.filebase.io/api/v0/add`
- Gateway default: `https://ipfs.filebase.io/ipfs/`
- Auth: Filebase API token sent as `Authorization: Bearer <token>`

### Self-Hosted Kubo

- Upload endpoint default: `http://127.0.0.1:5001/api/v0/add`
- Gateway default: `http://127.0.0.1:8080/ipfs/`
- Auth: optional bearer token
- Good fit for a Kubo node behind VPN, reverse proxy, or another controlled network path

## Notes

- The Kubo endpoint is editable in the UI, and the gateway base is editable too.
- CID validation is now lightweight and app-local because this branch no longer depends on the Dart IPFS stack.
- `flutter analyze` should pass on this branch.
