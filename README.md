# IPFS Photo Relay

Simple Flutter proof of concept for running an embedded IPFS node on a phone and transferring a picture to another phone using only a CID.

## What It Does

- Phone A picks an image, publishes it to an embedded IPFS node, and shares the CID to any messenger app.
- Phone B pastes the CID, resolves it through its own embedded IPFS node, downloads the content, and shares the resulting file so it can be saved to Photos or Files.
- The IPFS logic lives in a reusable service layer so it can be imported into another Flutter app later.

## Project Shape

- `lib/src/ipfs/ipfs_transfer_service.dart`: embedded node startup, publish, fetch, pin, and share helpers.
- `lib/src/ipfs_photo_relay_page.dart`: the proof-of-concept UI for the two-phone flow.
- `lib/src/app.dart`: app theme and top-level wiring.

## Running It

```bash
flutter pub get
flutter run
```

Install it on two phones, keep both apps open, then:

1. On phone A, tap `Select Image`.
2. Share the CID through a messenger app.
3. On phone B, paste the CID and tap `Download From CID`.
4. Use `Share Downloaded File` to save the image via the platform share sheet.

## Notes

- The app publishes a one-file IPFS directory instead of raw bytes so the original filename can travel with the CID.
- `flutter analyze` passes.
- `flutter test` is currently blocked on this Windows machine because the `sodium` dependency used by `dart_ipfs` tries to build a native asset and expects Visual Studio build tooling (`vswhere`) to be installed.
