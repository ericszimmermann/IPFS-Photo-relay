import 'dart:convert';
import 'dart:typed_data';

import 'package:base32/base32.dart' as rfc4648;
import 'package:base_x/base_x.dart';

const String _base16Symbols = '0123456789abcdef';
const String _base16UpperSymbols = '0123456789ABCDEF';
const String _base58Symbols =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

enum Multibase {
  base16(code: 'f'),
  base16upper(code: 'F'),
  base32(code: 'b'),
  base32upper(code: 'B'),
  base58btc(code: 'z'),
  base64(code: 'm'),
  base64url(code: 'u'),
  base64urlpad(code: 'U');

  const Multibase({required this.code});

  final String code;

  static Multibase fromCode(String code) {
    for (final base in Multibase.values) {
      if (base.code == code) {
        return base;
      }
    }
    throw UnsupportedError('Unknown base code: $code');
  }
}

String multibaseEncode(Multibase base, Uint8List data) {
  switch (base) {
    case Multibase.base16:
      return base.code + _encodeHex(data, uppercase: false);
    case Multibase.base16upper:
      return base.code + _encodeHex(data, uppercase: true);
    case Multibase.base32:
      return base.code + rfc4648.base32.encode(data).toLowerCase();
    case Multibase.base32upper:
      return base.code + rfc4648.base32.encode(data).toUpperCase();
    case Multibase.base58btc:
      return base.code + BaseXCodec(_base58Symbols).encode(data);
    case Multibase.base64:
      return base.code + base64Encode(data).replaceAll('=', '');
    case Multibase.base64url:
      return base.code + base64UrlEncode(data).replaceAll('=', '');
    case Multibase.base64urlpad:
      return base.code + base64UrlEncode(data);
  }
}

Uint8List multibaseDecode(String data) {
  if (data.isEmpty) {
    throw ArgumentError('Input is empty');
  }

  final base = Multibase.fromCode(data.substring(0, 1));
  final payload = data.substring(1);

  switch (base) {
    case Multibase.base16:
    case Multibase.base16upper:
      return _decodeHex(payload);
    case Multibase.base32:
    case Multibase.base32upper:
      return rfc4648.base32.decode(payload.toUpperCase());
    case Multibase.base58btc:
      return BaseXCodec(_base58Symbols).decode(payload);
    case Multibase.base64:
      return base64Decode(_restorePadding(payload));
    case Multibase.base64url:
    case Multibase.base64urlpad:
      return base64Url.decode(_restorePadding(payload));
  }
}

class MultibaseEncoder extends Converter<Uint8List, String> {
  MultibaseEncoder(this._base);

  final Multibase _base;

  @override
  String convert(Uint8List input) => multibaseEncode(_base, input);
}

class MultibaseDecoder extends Converter<String, Uint8List> {
  @override
  Uint8List convert(String input) => multibaseDecode(input);
}

class MultibaseCodec extends Codec<Uint8List, String> {
  MultibaseCodec({required Multibase encodeBase})
    : encoder = MultibaseEncoder(encodeBase);

  @override
  final MultibaseEncoder encoder;

  @override
  final MultibaseDecoder decoder = MultibaseDecoder();
}

String _encodeHex(Uint8List data, {required bool uppercase}) {
  final alphabet = uppercase ? _base16UpperSymbols : _base16Symbols;
  final buffer = StringBuffer();
  for (final byte in data) {
    buffer
      ..write(alphabet[(byte >> 4) & 0x0f])
      ..write(alphabet[byte & 0x0f]);
  }
  return buffer.toString();
}

Uint8List _decodeHex(String input) {
  if (input.length.isOdd) {
    throw const FormatException('Hex input must have even length.');
  }

  final normalized = input.toLowerCase();
  final output = Uint8List(input.length ~/ 2);
  for (var i = 0; i < normalized.length; i += 2) {
    output[i ~/ 2] = int.parse(normalized.substring(i, i + 2), radix: 16);
  }
  return output;
}

String _restorePadding(String input) {
  final padding = (4 - input.length % 4) % 4;
  return input.padRight(input.length + padding, '=');
}
