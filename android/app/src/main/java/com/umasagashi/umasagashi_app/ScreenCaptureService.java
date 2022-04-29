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
import android.hardware.HardwareBuffer;
import android.hardware.display.DisplayManager;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.IBinder;
import android.util.DisplayMetrics;
import android.util.Size;
import android.view.WindowManager;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

import java.nio.ByteBuffer;

import io.flutter.Log;

@RequiresApi(api = Build.VERSION_CODES.R)
public class ScreenCaptureService extends Service implements ImageReader.OnImageAvailableListener {
    private static final String LOG_TAG = "ScreenCapture";
    private static final String VIRTUAL_DISPLAY_ID = "umasagashi_app_virtual_display";
    private static final String NOTIFICATION_CHANNEL_ID = "umasagashi_app_capture";
    private static final String NOTIFICATION_TITLE = "Title Here";
    private static final String NOTIFICATION_DESCRIPTION = "Description Here";
    private static final int REQUEST_CODE = 1234;

    private ImageReader mImageReader;
    private final Size minimumSize = new Size(540, 960);

    public native void initializeNativeCounterpart(String config);

    public native void updateNativeFrame(ByteBuffer frame, int width, int height, int rowStride, int scaledWidth, int scaledHeight);

    public native void startEventLoop();

    public native void joinEventLoop();

    public void notifyPlatform(String arg) {
        Log.d(LOG_TAG, String.format("notifyPlatform %s", arg));

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
        Log.d(LOG_TAG, "config " + config);
        initializeNativeCounterpart(config);

        startForeground(1, createNotification());

        final DisplayMetrics metrics = new DisplayMetrics();
        ((WindowManager) getSystemService(WINDOW_SERVICE)).getDefaultDisplay().getRealMetrics(metrics);
        Log.d(LOG_TAG, "getRealMetrics " + metrics);

        mImageReader = ImageReader.newInstance(
            metrics.widthPixels, metrics.heightPixels, PixelFormat.RGBA_8888,
            2, HardwareBuffer.USAGE_CPU_READ_OFTEN);
        mImageReader.setOnImageAvailableListener(this, null);

        ((MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE))
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
        Toast.makeText(this, "Capture Started", Toast.LENGTH_LONG).show();
        startEventLoop();
        super.onCreate();
    }

    @Override
    public void onDestroy() {
        Log.d(LOG_TAG, "onDestroy");
        Toast.makeText(this, "Capture Stopped", Toast.LENGTH_LONG).show();
        mImageReader.close();
        joinEventLoop();
        super.onDestroy();
    }

    @Override
    public void onImageAvailable(ImageReader imageReader) {
        final Image image = imageReader.acquireLatestImage();
        if (image == null) {
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

        final float scale = Math.max(
            (float) minimumSize.getWidth() / width,
            (float) minimumSize.getHeight() / height
        );
        final int scaledWidth = Math.round((float) width * scale);
        final int scaledHeight = Math.round((float) height * scale);

        updateNativeFrame(buffer, width, height, rowStride, scaledWidth, scaledHeight);

        image.close();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
