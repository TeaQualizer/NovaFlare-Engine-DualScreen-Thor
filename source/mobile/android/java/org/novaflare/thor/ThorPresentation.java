/*
 * Drop into: source/mobile/android/java/org/novaflare/thor/ThorPresentation.java
 *
 * No Project.xml change is required: source/mobile/android/java is already a <java path>.
 * Extension.mainActivity is used exactly the same way as org.novaflare.crash.NativeCrashDialog.
 *
 * IMPORTANT: Presentation is an Android Dialog window (its own View hierarchy), NOT an
 * OpenFL Stage. A FlxCamera cannot be attached to it. ThorScreen.hx mirrors the live state
 * of Lua objects into native Android Views instead. The Haxe -> Java channel is ONE JNI
 * method taking a JSON string, so no byte[] / primitive-array marshalling is needed.
 */

package org.novaflare.thor;

import android.app.Activity;
import android.app.Presentation;
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.util.TypedValue;
import android.view.Display;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.TextView;

import org.haxe.extension.Extension;
import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashMap;
import java.util.Map;

public final class ThorPresentation {
    private static final String TAG = "ThorPresentation";

    /** Virtual coordinate space of camBottom. Must match ThorScreen.BOTTOM_W / BOTTOM_H. */
    public static final int VIRTUAL_W = 1240;
    public static final int VIRTUAL_H = 1080;

    private static volatile Presentation presentation;
    private static volatile FrameLayout root;
    private static volatile FrameLayout layer;
    private static volatile ImageView background;
    private static volatile boolean menuMode = true;
    private static volatile boolean listenerRegistered = false;

    private static final Map<String, View> objectViews = new HashMap<String, View>();
    private static final Map<String, String> lastPng = new HashMap<String, String>();

    private ThorPresentation() {}

    private static Activity activity() {
        return Extension.mainActivity;
    }

    /** Called from Haxe with signature ()V. */
    public static void init() {
        final Activity a = activity();
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                createOnUiThread(a);
            }
        });
    }

    /** Called from Haxe with signature ()Z. */
    public static boolean isActive() {
        return presentation != null && presentation.isShowing();
    }

    /** Called from Haxe with signature ()V. */
    public static void dismiss() {
        final Activity a = activity();
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                if (presentation != null) {
                    try { presentation.dismiss(); } catch (Throwable ignored) {}
                }
                presentation = null;
                root = null;
                layer = null;
                background = null;
                objectViews.clear();
                lastPng.clear();
            }
        });
    }

    /**
     * The single Haxe -> Java channel. Signature: (Ljava/lang/String;)V
     * JSON shape:
     *   { "menu":true/false,
     *     "bg":"<base64 png, only sent once>",
     *     "remove":["tag", ...],
     *     "objects":[ { "tag","type":"sprite"|"text", "png", "text", "x","y","w","h",
     *                   "sx","sy","angle","alpha","visible","color","flipX","size","align" } ] }
     */
    public static void update(final String json) {
        final Activity a = activity();
        if (a == null || json == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                if (root == null) return;
                try {
                    applyJson(new JSONObject(json));
                } catch (Throwable t) {
                    Log.e(TAG, "update failed: " + t.getMessage(), t);
                }
            }
        });
    }

    private static void createOnUiThread(Activity a) {
        if (isActive()) return;
        Display display = findDisplay(a);
        if (display == null) {
            Log.w(TAG, "No usable secondary display found; dual screen disabled.");
            return;
        }

        presentation = new Presentation(a, display, android.R.style.Theme_Black_NoTitleBar_Fullscreen) {
            @Override protected void onCreate(Bundle savedInstanceState) {
                super.onCreate(savedInstanceState);

                root = new FrameLayout(getContext());
                root.setBackgroundColor(Color.BLACK);

                background = new ImageView(getContext());
                background.setScaleType(ImageView.ScaleType.CENTER_CROP);
                root.addView(background, new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT));

                layer = new FrameLayout(getContext());
                layer.setVisibility(menuMode ? View.GONE : View.VISIBLE);
                root.addView(layer, new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT));

                setContentView(root);

                Window w = getWindow();
                if (w != null) {
                    // Do NOT steal focus from the game, otherwise FNF pauses on focus loss.
                    w.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
                    w.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL);
                    w.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                    w.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS);
                }
            }
        };

        presentation.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override public void onDismiss(DialogInterface dialog) {
                objectViews.clear();
                lastPng.clear();
                root = null;
                layer = null;
                background = null;
            }
        });

        try {
            presentation.show();
        } catch (Throwable t) {
            Log.e(TAG, "Presentation.show() failed: " + t.getMessage(), t);
            presentation = null;
            return;
        }

        registerDisplayListener(a);
        Log.i(TAG, "Secondary display ready: " + display.getDisplayId());
    }

    /** Prefer DISPLAY_CATEGORY_PRESENTATION, fall back to the smallest non-default display. */
    private static Display findDisplay(Activity a) {
        DisplayManager dm = (DisplayManager) a.getSystemService(Context.DISPLAY_SERVICE);
        if (dm == null) return null;

        Display best = null;
        Display[] presentationDisplays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        if (presentationDisplays != null) {
            for (Display d : presentationDisplays) {
                if (d.getDisplayId() == Display.DEFAULT_DISPLAY) continue;
                if (best == null || area(d) < area(best)) best = d;
            }
        }
        if (best == null) {
            for (Display d : dm.getDisplays()) {
                if (d.getDisplayId() == Display.DEFAULT_DISPLAY) continue;
                // 0x4 == Display.FLAG_PRIVATE (use the literal for older SDK stubs)
                if ((d.getFlags() & 0x4) != 0) continue;
                if (best == null || area(d) < area(best)) best = d;
            }
        }
        return best;
    }

    private static int area(Display d) {
        return d.getWidth() * d.getHeight();
    }

    private static void registerDisplayListener(Activity a) {
        if (listenerRegistered) return;
        final DisplayManager dm = (DisplayManager) a.getSystemService(Context.DISPLAY_SERVICE);
        if (dm == null) return;
        listenerRegistered = true;
        dm.registerDisplayListener(new DisplayManager.DisplayListener() {
            @Override public void onDisplayAdded(int displayId) {
                if (!isActive()) init();
            }
            @Override public void onDisplayRemoved(int displayId) {
                dismiss();
            }
            @Override public void onDisplayChanged(int displayId) {}
        }, null);
    }

    private static void applyJson(JSONObject obj) throws Exception {
        boolean menu = obj.optBoolean("menu", true);
        if (menu != menuMode) {
            menuMode = menu;
            if (layer != null) layer.setVisibility(menu ? View.GONE : View.VISIBLE);
        }

        String bg = obj.optString("bg", "");
        if (bg != null && bg.length() > 0 && background != null) {
            byte[] bytes = Base64.decode(bg, Base64.DEFAULT);
            Bitmap bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            if (bmp != null) background.setImageBitmap(bmp);
        }

        JSONArray removals = obj.optJSONArray("remove");
        if (removals != null) {
            for (int i = 0; i < removals.length(); i++) removeObject(removals.optString(i, ""));
        }

        JSONArray objects = obj.optJSONArray("objects");
        if (objects != null) {
            for (int i = 0; i < objects.length(); i++) {
                JSONObject o = objects.optJSONObject(i);
                if (o != null) syncObject(o);
            }
        }
    }

    private static void syncObject(JSONObject o) {
        final String tag = o.optString("tag", "");
        if (tag.length() == 0) return;
        final String type = o.optString("type", "sprite");
        View v = objectViews.get(tag);

        if ("text".equals(type)) {
            TextView tv;
            if (v instanceof TextView) {
                tv = (TextView) v;
            } else {
                if (v != null) layer.removeView(v);
                tv = new TextView(root.getContext());
                tv.setIncludeFontPadding(false);
                tv.setTextColor(Color.WHITE);
                layer.addView(tv, new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        FrameLayout.LayoutParams.WRAP_CONTENT));
                objectViews.put(tag, tv);
                lastPng.remove(tag);
            }

            tv.setText(o.optString("text", ""));
            float sy = scaleY();
            tv.setTextSize(TypedValue.COMPLEX_UNIT_PX, (float) o.optDouble("size", 16) * sy);
            tv.setTextColor(o.optInt("color", 0xFFFFFFFF));
            String align = o.optString("align", "left");
            if ("center".equals(align)) tv.setGravity(Gravity.CENTER_HORIZONTAL);
            else if ("right".equals(align)) tv.setGravity(Gravity.RIGHT);
            else tv.setGravity(Gravity.LEFT);
            int maxW = (int) ((float) o.optDouble("w", 0) * scaleX());
            if (maxW > 0) tv.setMaxWidth(maxW);
            transform(tv, o);
            return;
        }

        ImageView iv;
        if (v instanceof ImageView) {
            iv = (ImageView) v;
        } else {
            if (v != null) layer.removeView(v);
            iv = new ImageView(root.getContext());
            iv.setScaleType(ImageView.ScaleType.FIT_XY);
            layer.addView(iv, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT));
            objectViews.put(tag, iv);
            lastPng.remove(tag);
        }

        String png = o.optString("png", "");
        if (png != null && png.length() > 0 && !png.equals(lastPng.get(tag))) {
            try {
                byte[] bytes = Base64.decode(png, Base64.DEFAULT);
                Bitmap bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                if (bmp != null) {
                    iv.setImageBitmap(bmp);
                    lastPng.put(tag, png);
                    iv.setPivotX(bmp.getWidth() * 0.5f);
                    iv.setPivotY(bmp.getHeight() * 0.5f);
                }
            } catch (Throwable t) {
                Log.w(TAG, "bad sprite png for " + tag + ": " + t.getMessage());
            }
        }

        int tint = o.optInt("color", 0xFFFFFFFF);
        if (tint != 0xFFFFFFFF) iv.setColorFilter(tint, PorterDuff.Mode.MULTIPLY);
        else iv.clearColorFilter();

        transform(iv, o);
        boolean flipX = o.optBoolean("flipX", false);
        if (flipX) iv.setScaleX(-Math.abs(iv.getScaleX()));
    }

    private static void transform(View v, JSONObject o) {
        float sx = scaleX();
        float sy = scaleY();
        v.setX((float) o.optDouble("x", 0) * sx);
        v.setY((float) o.optDouble("y", 0) * sy);
        v.setScaleX((float) o.optDouble("sx", 1) * sx);
        v.setScaleY((float) o.optDouble("sy", 1) * sy);
        v.setRotation((float) o.optDouble("angle", 0));
        v.setAlpha((float) o.optDouble("alpha", 1));
        boolean visible = o.optBoolean("visible", true) && !menuMode;
        v.setVisibility(visible ? View.VISIBLE : View.GONE);
    }

    private static float scaleX() {
        return root == null || root.getWidth() == 0 ? 1f : root.getWidth() / (float) VIRTUAL_W;
    }

    private static float scaleY() {
        return root == null || root.getHeight() == 0 ? 1f : root.getHeight() / (float) VIRTUAL_H;
    }

    private static void removeObject(String tag) {
        if (tag == null || tag.length() == 0) return;
        View v = objectViews.remove(tag);
        lastPng.remove(tag);
        if (v != null && layer != null) layer.removeView(v);
    }
}
