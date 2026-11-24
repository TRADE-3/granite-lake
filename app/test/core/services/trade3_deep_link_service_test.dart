import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/services/trade3_deep_link_service.dart';

void main() {
  group('Trade3DeepLinkService.extractPairingCode', () {
    test('extracts the code from the /?code= link shape', () {
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://granite.trade3.io/?code=bc35112c-4bdb-4aab'),
        ),
        'bc35112c-4bdb-4aab',
      );
    });

    test('extracts the code from the /pair?code= link shape', () {
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://granite.trade3.io/pair?code=abc123'),
        ),
        'abc123',
      );
    });

    test('trims whitespace-padded codes', () {
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://granite.trade3.io/pair?code=%20abc%20'),
        ),
        'abc',
      );
    });

    test('rejects links without a code', () {
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://granite.trade3.io/pair'),
        ),
        isNull,
      );
    });

    test('rejects empty codes', () {
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://granite.trade3.io/?code='),
        ),
        isNull,
      );
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://granite.trade3.io/?code=%20%20'),
        ),
        isNull,
      );
    });

    test('rejects other hosts', () {
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://evil.example.com/pair?code=abc'),
        ),
        isNull,
      );
      // A lookalike suffix host must not match: Uri lowercases the host but
      // keeps subdomain structure, so granite.trade3.io.evil.com is rejected.
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('https://granite.trade3.io.evil.com/pair?code=abc'),
        ),
        isNull,
      );
    });

    test('rejects non-https schemes', () {
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('http://granite.trade3.io/?code=abc'),
        ),
        isNull,
      );
      expect(
        Trade3DeepLinkService.extractPairingCode(
          Uri.parse('granite://pair?code=abc'),
        ),
        isNull,
      );
    });
  });
}
