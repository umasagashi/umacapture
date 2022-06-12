package com.umasagashi.umasagashi_app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjectionManager;
import android.os.IBinder;
import android.util.DisplayMetrics;
import android.util.Size;
import android.view.WindowManager;

import androidx.annotation.Nullable;

import java.nio.ByteBuffer;

import io.flutter.Log;

public class ScreenCaptureService extends Service implements ImageReader.OnImageAvailableListener {
    private static final String LOG_TAG = "ScreenCapture";
    private static final String VIRTUAL_DISPLAY_ID = "umasagashi_app_virtual_display";
    private static final String NOTIFICATION_CHANNEL_ID = "umasagashi_app_capture";
    private static final int REQUEST_CODE = 1234;

    private static final String NOTIFICATION_TITLE = "Title Here";
    private static final String NOTIFICATION_DESCRIPTION = "Description Here";

    private ImageReader mImageReader;
    private VirtualDisplay mVirtualDisplay;
    private final Size minimumSize = new Size(540, 960);

    public native void updateNativeFrame(ByteBuffer frame, int width, int height, int rowStride, int scaledWidth, int scaledHeight);

    public native void startEventLoop(String config);

    public native void joinEventLoop();

    public native boolean isRunning();

    public native void notifyCaptureStarted();

    public native void notifyCaptureStopped();

    public void notifyPlatform(String arg) {
        BroadcastChannel.send(getBaseContext(), MainActivity.class, arg);
    }

    private Notification createNotification() {
        Context context = getApplicationContext();

        NotificationChannel channel = new NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            NOTIFICATION_TITLE,
            NotificationManager.IMPORTANCE_DEFAULT);

        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        manager.createNotificationChannel(channel);

        Intent intent = new Intent(context, MainActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        intent.addFlags(Intent.FLAG_ACTIVITY_PREVIOUS_IS_TOP);

        PendingIntent pendingIntent = PendingIntent.getActivity(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        return new Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(NOTIFICATION_TITLE)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentText(NOTIFICATION_DESCRIPTION)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build();
    }

    @SuppressLint("WrongConstant")  // PixelFormat
    @Override
    public int onStartCommand(Intent captureIntent, int flags, int startId) {
        Log.d(LOG_TAG, "onStartCommand");

        final String config = captureIntent.getStringExtra("config");
        startEventLoop(config);
        notifyCaptureStarted();

        startForeground(1, createNotification());

        final DisplayMetrics metrics = new DisplayMetrics();
        ((WindowManager) getSystemService(WINDOW_SERVICE)).getDefaultDisplay().getRealMetrics(metrics);
        Log.d(LOG_TAG, "getRealMetrics " + metrics);

        mImageReader = ImageReader.newInstance(metrics.widthPixels, metrics.heightPixels, PixelFormat.RGBA_8888, 4);
        mImageReader.setOnImageAvailableListener(this, null);

        mVirtualDisplay = ((MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE))
            .getMediaProjection(Activity.RESULT_OK, captureIntent.getParcelableExtra("mediaProjectionIntent"))
            .createVirtualDisplay(
                VIRTUAL_DISPLAY_ID,
                metrics.widthPixels, metrics.heightPixels, metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                mImageReader.getSurface(), null, null
            );

        return START_NOT_STICKY;
    }

    @Override
    public void onCreate() {
        Log.d(LOG_TAG, "onCreate");
        super.onCreate();
    }

    @Override
    public void onDestroy() {
        Log.d(LOG_TAG, "onDestroy");
        mVirtualDisplay.getSurface().release();
        mVirtualDisplay.release();
        mImageReader.getSurface().release();
        mImageReader.close();
        joinEventLoop();
        notifyCaptureStopped();
        super.onDestroy();
        Log.d(LOG_TAG, "onDestroy finished");
    }

    @Override
    public void onImageAvailable(ImageReader imageReader) {
        final Image image = imageReader.acquireLatestImage();
        if (image == null) {
            return;
        }

        if (!isRunning()) {
            image.close();
            return;
        }

        final Image.Plane[] planes = image.getPlanes();
        if (planes.length != 1) {
            throw new Error("Unsupported screen format");
        }

        final Image.Plane plane = planes[0];
        final ByteBuffer buffer = plane.getBuffer().asReadOnlyBuffer();

        if (!buffer.isDirect() || plane.getPixelStride() != 4) {
            throw new Error("Unexpected image format");
        }

        final int width = imageReader.getWidth();
        final int height = imageReader.getHeight();
        final int rowStride = plane.getRowStride();

        final double scale = Math.max(
            (double) minimumSize.getWidth() / width,
            (double) minimumSize.getHeight() / height
        );
        final int scaledWidth = (int) Math.round((double) width * scale);
        final int scaledHeight = (int) Math.round((double) height * scale);

        updateNativeFrame(buffer, width, height, rowStride, scaledWidth, scaledHeight);

        image.close();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
