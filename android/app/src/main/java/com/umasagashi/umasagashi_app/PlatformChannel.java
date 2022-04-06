package com.umasagashi.umasagashi_app;

import androidx.core.util.Consumer;

import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

public class PlatformChannel {
    private static final String CHANNEL = "dev.flutter.umasagashi_app/capturing_channel";
    private final MethodChannel channel;

    private Map<String, Consumer<String>> methodMap;

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
