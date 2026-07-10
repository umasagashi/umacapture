package com.umasagashi.umacapture;

import androidx.core.util.Consumer;

import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

public class PlatformChannel {
    private static final String CHANNEL = "dev.flutter.umasagashi/capturing_channel";
    private final MethodChannel channel;

    private Map<String, Consumer<String>> methodMap;

    // NOTE: This Android channel is a leftover from the early proof-of-concept phase and is NOT maintained.
    // Windows is the only supported platform today. It is kept (rather than deleted) so a future Android
    // port has a starting point. Two known issues to fix before shipping Android:
    //   1. MainActivity only registers 3 of the 7 methods the Dart side can call (updateRecord,
    //      takeScreenshot, copyToClipboardFromFile, setPlatformConfig are missing).
    //   2. The handler below is missing a `return;` after notImplemented(): an unknown method falls through
    //      to methodMap.get(...) == null, so requireNonNull throws and the call is reported as an NPE-derived
    //      error (and replied twice) instead of a clean notImplemented. Add `return;` when reviving this.
    PlatformChannel(BinaryMessenger messenger) {
        channel = new MethodChannel(messenger, CHANNEL);
        channel.setMethodCallHandler(
            (call, result) -> {
                if (!methodMap.containsKey(call.method)) {
                    result.notImplemented();
                }
                try {
                    Objects.requireNonNull(methodMap.get(call.method)).accept(String.valueOf(call.arguments));
                    result.success(0);
                } catch (Exception e) {
                    result.error(e.getClass().getName(), e.getMessage(), null);
                }
            }
        );

        methodMap = new HashMap<>();
    }

    public void addMethodCallHandler(String name, Consumer<String> method) {
        methodMap.put(name, method);
    }

    public void addMethodCallHandler(String name, Runnable method) {
        addMethodCallHandler(name, (arg) -> method.run());
    }

    public void notify(String message) {
        channel.invokeMethod("notify", message);
    }
}
