import "package:droid_edge_server/engines/litert_lm_engine.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("MethodChannelLiteRtLmEngine Platform Channel Bridge", () {
    test("is strictly lazy on construction and short-circuits on non-Android", () async {
      const channel = MethodChannel("test/litert_lm_non_android");
      final recordedCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        recordedCalls.add(call);
        return true;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final engine = MethodChannelLiteRtLmEngine(
        channel: channel,
        isAndroidOverride: false,
      );

      expect(recordedCalls, isEmpty);
      expect(await engine.isSupported(), isFalse);
      expect(await engine.getDeviceRamGb(), isNull);
      expect(await engine.getModelsDirectory(), isNull);
      expect(await engine.pickModelFile(), isNull);
      expect(
        await engine.runInference(
          prompt: "hello",
          modelPath: "/tmp/model.litertlm",
          forceJson: false,
        ),
        isNull,
      );
      await engine.cancelInference();
      await engine.unloadModel();
      await engine.dispose();
      expect(recordedCalls, isEmpty);
    });

    test("marshals Android MethodChannel calls and handles OOM/picker errors cleanly", () async {
      const channel = MethodChannel("test/litert_lm_android");
      final recordedCalls = <MethodCall>[];
      var throwOom = false;
      var throwInvalidPick = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        recordedCalls.add(call);
        switch (call.method) {
          case "isSupported":
            return true;
          case "getDeviceRamGb":
            return 8;
          case "getModelsDirectory":
            return "/storage/emulated/0/Android/data/app/files/models";
          case "pickModelFile":
            if (throwInvalidPick) {
              throw PlatformException(
                code: "INVALID_MODEL_EXTENSION",
                message: "Please select a valid .litertlm model file.",
              );
            }
            return "/storage/emulated/0/Download/gemma.litertlm";
          case "runInference":
            if (throwOom) {
              throw PlatformException(code: "LITERT_OOM", message: "Out of RAM");
            }
            return "Refined output";
          case "cancelInference":
          case "unloadModel":
          case "dispose":
            return null;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final engine = MethodChannelLiteRtLmEngine(
        channel: channel,
        isAndroidOverride: true,
      );
      expect(recordedCalls, isEmpty);

      expect(await engine.isSupported(), isTrue);
      expect(await engine.getDeviceRamGb(), 8.0);
      expect(
        await engine.getModelsDirectory(),
        "/storage/emulated/0/Android/data/app/files/models",
      );
      expect(
        await engine.pickModelFile(),
        "/storage/emulated/0/Download/gemma.litertlm",
      );

      throwInvalidPick = true;
      await expectLater(
        engine.pickModelFile(),
        throwsA(isA<PlatformException>()),
      );

      final ok = await engine.runInference(
        prompt: "Extract receipt",
        modelPath: "/sdcard/Download/gemma.litertlm",
        forceJson: true,
      );
      expect(ok, "Refined output");
      final inferCall = recordedCalls.last;
      expect(inferCall.arguments, {
        "prompt": "Extract receipt",
        "modelPath": "/sdcard/Download/gemma.litertlm",
        "forceJson": true,
      });

      throwOom = true;
      expect(
        await engine.runInference(
          prompt: "Extract receipt",
          modelPath: "/sdcard/Download/gemma.litertlm",
          forceJson: true,
        ),
        isNull,
      );

      await engine.cancelInference();
      await engine.unloadModel();
      await engine.dispose();
      await engine.dispose();

      expect(
        recordedCalls.where((c) => c.method == "dispose"),
        hasLength(1),
      );
      expect(
        await engine.runInference(
          prompt: "after dispose",
          modelPath: "/sdcard/Download/gemma.litertlm",
          forceJson: false,
        ),
        isNull,
      );
    });
  });
}
