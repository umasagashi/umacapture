package com.umasagashi.umacapture;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;

import java.util.function.Consumer;

public class BroadcastChannel {
    private static final String CHANNEL = "dev.flutter.umasagashi/broadcast/";
    private static final String ARGUMENT_NAME = "message";

    private static class ActionReceiver extends BroadcastReceiver {
        private final Consumer<String> callback;

        ActionReceiver(Consumer<String> callback) {
            this.callback = callback;
        }

        @Override
        public void onReceive(Context context, Intent intent) {
            Bundle extras = intent.getExtras();
            String message = extras.getString(ARGUMENT_NAME);
            callback.accept(message);
        }
    }

    private static String getActionName(Class<?> receiverClass) {
        return CHANNEL + receiverClass.getName();
    }

    private final Context broadcastContext;
    private final ActionReceiver receiver;

    BroadcastChannel(Context context, Class<?> receiverClass, Consumer<String> callback) {
        receiver = new ActionReceiver(callback);
        broadcastContext = context;

        IntentFilter filter = new IntentFilter();
        filter.addAction(getActionName(receiverClass));
        broadcastContext.registerReceiver(receiver, filter);
    }

    public void unregister() {
        broadcastContext.unregisterReceiver(receiver);
    }

    public static void send(Context context, Class<?> receiverClass, String arg) {
        Intent message = new Intent();
        message.putExtra(ARGUMENT_NAME, arg);
        message.setAction(getActionName(receiverClass));
        context.sendBroadcast(message);
    }
}
