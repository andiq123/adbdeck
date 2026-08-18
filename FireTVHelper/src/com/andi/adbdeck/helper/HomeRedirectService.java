package com.andi.adbdeck.helper;

import android.accessibilityservice.AccessibilityService;
import android.content.ComponentName;
import android.content.Intent;
import android.provider.Settings;
import android.view.accessibility.AccessibilityEvent;

public final class HomeRedirectService extends AccessibilityService {
    private static final String ENABLED = "adbdeck_launcher_enabled";
    private static final String COMPONENT = "adbdeck_launcher_component";
    private long lastRedirect;

    @Override protected void onServiceConnected() {
        redirect();
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return;
        CharSequence source = event.getPackageName();
        if (source == null || !(source.equals("com.amazon.tv.launcher") || source.equals("com.amazon.firehomestarter"))) return;
        redirect();
    }

    private void redirect() {
        if (Settings.Secure.getInt(getContentResolver(), ENABLED, 0) != 1) return;
        long now = System.currentTimeMillis();
        if (now - lastRedirect < 900) return;
        ComponentName target = ComponentName.unflattenFromString(Settings.Secure.getString(getContentResolver(), COMPONENT));
        if (target == null || target.getPackageName().startsWith("com.amazon.")) return;
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setComponent(target)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        if (home.resolveActivity(getPackageManager()) == null) return;
        lastRedirect = now;
        startActivity(home);
    }

    @Override public void onInterrupt() { }
}
