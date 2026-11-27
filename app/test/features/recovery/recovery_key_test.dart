import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/app.dart';
import 'package:granite_lake/core/services/granite_lake_secure_state_service.dart';
import 'package:granite_lake/core/state/granite_lake_controller.dart';
import 'package:granite_lake/features/profile/screens/recovery_key_screen.dart';

const _gate = MethodChannel('granite_lake/biometric_gate');
const _fakeKey = 'suiprivkey1abcdefgh';

class _Controller extends GraniteLakeController {
  _Controller({this.failure});

  final String? failure;
  int reveals = 0;
  int discards = 0;

  @override
  Future<void> discardUnregisteredIdentity() async => discards++;

  @override
  Future<SecureOperationResult<String>> revealRecoveryKey() async {
    reveals++;
    final message = failure;
    return message == null
        ? const SecureOperationResult<String>.success(_fakeKey)
        : SecureOperationResult<String>.failure(message);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  GraniteLakeSecureStateService service() =>
      GraniteLakeSecureStateService(storage: const FlutterSecureStorage());

  group('export and import', () {
    test('the exported key restores the same wallet', () async {
      final created = (await service().createIdentity()).data!;

      // Typed back as displayed: grouped, upper-cased by a keyboard.
      final typed = RecoveryKeyScreen.grouped(
        created.suiPrivateKey!,
      ).toUpperCase();
      final imported = await service().importIdentity('  $typed\n');

      expect(imported.data?.walletAddress, created.walletAddress);
      expect(imported.data?.publicKeyHex, created.publicKeyHex);
    });

    test('rejects a wrong key without echoing it', () async {
      final created = (await service().createIdentity()).data!;
      final damaged = '${created.suiPrivateKey!.substring(0, 60)}qqqq';

      for (final input in ['', 'hello', damaged]) {
        final result = await service().importIdentity(input);

        expect(result.isSuccess, isFalse);
        expect(result.message, isNot(contains('suiprivkey1')));
      }
    });
  });

  group('required save', () {
    test('stays pending after a restart until confirmed', () async {
      await service().createIdentity();
      // A new service instance, as after the app is killed.
      expect(await service().isRecoveryKeySavePending(), isTrue);

      await service().confirmRecoveryKeySaved();
      expect(await service().isRecoveryKeySavePending(), isFalse);
    });

    test('is not required for an imported key', () async {
      final created = (await service().createIdentity()).data!;

      await service().importIdentity(created.suiPrivateKey!);

      expect(await service().isRecoveryKeySavePending(), isFalse);
    });
  });

  group('reveal', () {
    final binding = BiometricBindingRecord(
      boundAt: DateTime.utc(2026),
      modalities: const ['FINGERPRINT'],
      gateAlias: 'alias',
    );
    const payload = BiometricGatePayload(ciphertextBase64: 'c', ivBase64: 'i');

    void mockGate(Future<Object?> Function(MethodCall call)? handler) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_gate, handler);

    tearDown(() => mockGate(null));

    test('needs a biometric unlock every time', () async {
      var prompts = 0;
      mockGate((call) async {
        expect(call.method, 'unlockBiometricGate');
        prompts++;
        return jsonEncode({'sentinelBase64': 's', 'suiPrivateKey': _fakeKey});
      });

      for (var i = 0; i < 2; i++) {
        final result = await service().revealRecoveryKey(
          biometricBinding: binding,
          biometricGatePayload: payload,
        );
        expect(result.data, _fakeKey);
      }
      expect(prompts, 2);
    });

    test('gives nothing when the prompt is cancelled', () async {
      mockGate((_) async => throw PlatformException(code: 'auth_cancelled'));

      final result = await service().revealRecoveryKey(
        biometricBinding: binding,
        biometricGatePayload: payload,
      );

      expect(result.isSuccess, isFalse);
      expect(result.data, isNull);
    });

    test('gives nothing without biometric protection', () async {
      final result = await service().revealRecoveryKey(
        biometricBinding: null,
        biometricGatePayload: null,
      );

      expect(result.isSuccess, isFalse);
    });
  });

  group('screen', () {
    Future<_Controller> pump(WidgetTester tester) async {
      final controller = _Controller();
      await tester.pumpWidget(
        GraniteLakeScope(
          controller: controller,
          child: const MaterialApp(home: RecoveryKeyScreen()),
        ),
      );
      return controller;
    }

    final shown = find.text(RecoveryKeyScreen.grouped(_fakeKey));

    testWidgets('hides the key until asked, and again in the background', (
      tester,
    ) async {
      final controller = await pump(tester);
      expect(shown, findsNothing);
      expect(controller.reveals, 0);

      await tester.tap(find.text('SHOW RECOVERY KEY'));
      await tester.pumpAndSettle();
      expect(shown, findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        // Frames only draw again once the app is back.
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(shown, findsNothing);
    });

    testWidgets('copy puts the ungrouped key on the clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      await pump(tester);
      await tester.tap(find.text('SHOW RECOVERY KEY'));
      await tester.pumpAndSettle();
      expect(copied, isEmpty);

      await tester.tap(find.text('COPY'));
      await tester.pump();

      expect(copied, [_fakeKey]);
    });

    testWidgets('offers no way to skip', (tester) async {
      await pump(tester);

      expect(find.textContaining('SKIP'), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);
    });

    testWidgets('offers to start again only if biometrics changed', (
      tester,
    ) async {
      for (final (message, offered) in [
        ('Biometric verification was cancelled or denied.', false),
        (GraniteLakeSecureStateService.biometricChangedMessage, true),
      ]) {
        final controller = _Controller(failure: message);
        await tester.pumpWidget(
          GraniteLakeScope(
            controller: controller,
            child: MaterialApp(home: RecoveryKeyScreen(key: ValueKey(message))),
          ),
        );
        await tester.tap(find.text('SHOW RECOVERY KEY'));
        await tester.pumpAndSettle();

        expect(
          find.text('START AGAIN'),
          offered ? findsOneWidget : findsNothing,
        );
        if (offered) {
          await tester.tap(find.text('START AGAIN'));
          expect(controller.discards, 1);
        }
      }
    });

    testWidgets('continue needs the saved confirmation', (tester) async {
      await pump(tester);
      await tester.tap(find.text('SHOW RECOVERY KEY'));
      await tester.pumpAndSettle();

      ElevatedButton button() =>
          tester.widget(find.widgetWithText(ElevatedButton, 'CONTINUE'));
      expect(button().onPressed, isNull);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });
  });
}
