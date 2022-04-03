package com.umasagashi.umasagashi_app;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "dev.flutter.umasagashi_app/capturing_channel";

    static {
        System.loadLibrary("umasagashi_app");
    }

    public native void callCppFromJava(String arg);

    public void callJavaFromCpp(String arg) {
        Log.d("Android", String.format("callJavaFromCpp %s", arg));
        new Handler(Looper.getMainLooper()).post(() -> {
            channel.invokeMethod("callDartFromJava", arg);
        });
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        channel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(
                (call, result) -> {
                    if (call.method.equals("callJavaFromDart")) {
                        Log.d("Android", String.format("callJavaFromDart %s", call.arguments.toString()));
                        callCppFromJava(call.arguments.toString());
                        result.success(0);
                    }
                }
        );
    }

    private MethodChannel channel;
}
