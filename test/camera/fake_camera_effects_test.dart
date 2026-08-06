import 'package:flutter_test/flutter_test.dart';
import 'package:ux/testing.dart';
import 'package:ux/ux.dart';

void main() {
  test('it records commands in the order a consumer made them', () async {
    final fake = FakeXCameraEffectsBackend();

    await fake.available();
    await fake.setEffect('track:1', XCameraEffect.blur);
    await fake.setEffect('track:1', XCameraEffect.dim);
    await fake.clear();

    expect(
      fake.calls.map((c) => c.method),
      ['available', 'setEffect', 'setEffect', 'clear'],
    );
    expect(fake.calls[1].trackId, 'track:1');
    expect(fake.calls[1].effect, XCameraEffect.blur);
    expect(fake.calls[2].effect, XCameraEffect.dim);
    expect(fake.calls.last.trackId, isNull);
  });

  test('available is scripted', () async {
    final fake = FakeXCameraEffectsBackend(availableResult: false);

    expect(await fake.available(), isFalse);
    fake.availableResult = true;
    expect(await fake.available(), isTrue);
    expect(fake.calls, hasLength(2));
  });

  test('scripted command errors are thrown and still recorded', () async {
    final fake = FakeXCameraEffectsBackend()
      ..availableError = const XCameraEffectsException('integration_unavailable')
      ..setEffectError = const XCameraEffectsException('track_not_found')
      ..clearError = const XCameraEffectsException('initialization_failed');

    await expectLater(
      fake.available(),
      throwsA(
        isA<XCameraEffectsException>()
            .having((e) => e.code, 'code', 'integration_unavailable'),
      ),
    );
    await expectLater(
      fake.setEffect('track:1', XCameraEffect.blur),
      throwsA(
        isA<XCameraEffectsException>()
            .having((e) => e.code, 'code', 'track_not_found'),
      ),
    );
    await expectLater(
      fake.clear(),
      throwsA(
        isA<XCameraEffectsException>()
            .having((e) => e.code, 'code', 'initialization_failed'),
      ),
    );
    expect(fake.calls, hasLength(3));
  });

  test('a consumer sees every status driven through the fake', () async {
    final fake = FakeXCameraEffectsBackend();
    final seen = <XCameraEffectStatus>[];
    fake.status.addListener(() => seen.add(fake.status.value));

    expect(fake.status.value, const XCameraEffectStatus.idle());
    await fake.setEffect('track:1', XCameraEffect.blur);
    fake.status.value = const XCameraEffectStatus(
      phase: XCameraEffectPhase.applying,
      effect: XCameraEffect.blur,
    );
    fake.status.value = const XCameraEffectStatus(
      phase: XCameraEffectPhase.active,
      effect: XCameraEffect.blur,
    );
    fake.status.value = const XCameraEffectStatus(
      phase: XCameraEffectPhase.failed,
      effect: XCameraEffect.blur,
      code: 'processing_failed',
    );

    expect(
      seen.map((s) => s.phase),
      [
        XCameraEffectPhase.applying,
        XCameraEffectPhase.active,
        XCameraEffectPhase.failed,
      ],
    );
    expect(seen.last.code, 'processing_failed');
  });

  test('an unsupported fake throws unsupported everywhere', () async {
    final fake = FakeXCameraEffectsBackend(supported: false);
    Matcher unsupported() => throwsA(
          isA<XCameraEffectsException>()
              .having((e) => e.code, 'code', 'unsupported'),
        );

    expect(fake.supported, isFalse);
    await expectLater(fake.available(), unsupported());
    await expectLater(
      fake.setEffect('track:1', XCameraEffect.blur),
      unsupported(),
    );
    await expectLater(fake.clear(), unsupported());
    expect(fake.calls, isEmpty);
  });

  test('it substitutes for the process-wide backend', () async {
    final fake = FakeXCameraEffectsBackend();
    XCameraEffectsBackend.instance = fake;
    addTearDown(() {
      XCameraEffectsBackend.instance = MethodChannelXCameraEffectsBackend();
    });

    await XCameraEffectsBackend.instance.setEffect(
      'track:1',
      XCameraEffect.blur,
    );

    expect(fake.calls.single.method, 'setEffect');
    expect(XCameraEffectsBackend.instance.status.value,
        const XCameraEffectStatus.idle());
  });
}
