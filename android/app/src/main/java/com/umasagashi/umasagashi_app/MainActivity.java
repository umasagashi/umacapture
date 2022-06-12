package com.umasagashi.umasagashi_app;

import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.Log;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;

public class MainActivity extends FlutterActivity {
    private static final String LOG_TAG = "MainActivity";
    private static final int SCREEN_CAPTURE_REQUEST_CODE = 10001;

    static {
        System.loadLibrary("umasagashi_app");
    }

    private PlatformChannel platform;
    private BroadcastChannel broadcast;
    private String config;

    private void setConfig(String config) {
        this.config = config;
    }

    private boolean isCaptureRunning() {
        ActivityManager manager = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
        for (ActivityManager.RunningServiceInfo info : manager.getRunningServices(Integer.MAX_VALUE)) {
            if (ScreenCaptureService.class.getName().equals(info.service.getClassName())) {
                return true;
            }
        }
        return false;
    }

    private void startCapture() {
        if (isCaptureRunning()) {
            Toast.makeText(this, "Capture is already running", Toast.LENGTH_SHORT).show();
            return;
        }

        startActivityForResult(
            ((MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE)).createScreenCaptureIntent(),
            SCREEN_CAPTURE_REQUEST_CODE
        );
    }

    @Override
    public void onActivityResult(int requestCode, int resultCode, Intent mediaProjectionIntent) {
        if (requestCode == SCREEN_CAPTURE_REQUEST_CODE) {
            if (resultCode != RESULT_OK) {
                Toast.makeText(this, "Capture Canceled", Toast.LENGTH_SHORT).show();
                return;
            }

            Intent captureIntent = new Intent(getApplication(), ScreenCaptureService.class);
            captureIntent.putExtra("mediaProjectionIntent", mediaProjectionIntent);
            captureIntent.putExtra("config", config);
            startForegroundService(captureIntent);
        } else {
            throw new IllegalStateException("Unexpected value: " + requestCode);
        }
    }

    private void stopCapture() {
        if (!isCaptureRunning()) {
            Log.d(LOG_TAG, "Capture is not running");
            return;
        }
        stopService(new Intent(getApplication(), ScreenCaptureService.class));
    }

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Log.d(LOG_TAG, "onCreate");
        super.onCreate(savedInstanceState);
        broadcast = new BroadcastChannel(this, MainActivity.class, (arg) -> platform.notify(arg));
    }

    @Override
    protected void onDestroy() {
        Log.d(LOG_TAG, "onDestroy");
        stopCapture();
        broadcast.unregister();
        super.onDestroy();
        Log.d(LOG_TAG, "onDestroy finished");
    }

    @Override
    public void onBackPressed() {
        if (isCaptureRunning()) {
            return;
        }
        super.onBackPressed();
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        Log.d(LOG_TAG, "configureFlutterEngine");
        super.configureFlutterEngine(flutterEngine);

        platform = new PlatformChannel(flutterEngine.getDartExecutor().getBinaryMessenger());
        platform.addMethodCallHandler("setConfig", this::setConfig);
        platform.addMethodCallHandler("startCapture", this::startCapture);
        platform.addMethodCallHandler("stopCapture", this::stopCapture);
    }
}
