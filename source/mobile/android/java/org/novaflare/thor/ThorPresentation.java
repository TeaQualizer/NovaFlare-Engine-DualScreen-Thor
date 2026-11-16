/* 添加了更多的参考 希望cambottom能找到问题
 * DIAGNOSTIC BUILD. A green status overlay is drawn on the lower screen so you
 * can locate a black screen WITHOUT adb/logcat. Set DIAGNOSTICS = false once the
 * lower screen is confirmed working.
 *
 * No Project.xml change is required: source/mobile/android/java is already a <java path>.
 * Extension.mainActivity is used exactly the same way as org.novaflare.crash.NativeCrashDialog.
 *
 * IMPORTANT: Presentation is an Android Dialog window (its own View hierarchy), NOT an
 * OpenFL Stage. A FlxCamera cannot be attached to it. ThorScreen.hx mirrors the live state
 * of Lua objects into native Android Views instead. The Haxe -> Java channel is ONE JNI
 * method taking a JSON string, so no byte[] / primitive-array marshalling is needed.
 *
 * STAGE 3 (Lua objects not appearing): `menu` is now REPORT-ONLY. Previously applyJson()
 * hid the whole object layer and transform() forced every object View to GONE whenever
 * menuMode was true, so a single wrong inPlay guess blanked out every Lua object with
 * no exception anywhere. The object layer is now always VISIBLE; Haxe emits an explicit
 * "remove" list when leaving PlayState. payload.stats is printed on the probe overlay.
 *
 * STAGE 5 (sprites still blank, probe said pngOk=0 pngErr=0 len=1202):
 *   BitmapData.encode() produced no bytes on this Android hardware/tile target -
 *   the SAME failure that caused the stage-1 black background. Sprites now use
 *   the raw packaged atlas PNG (Assets.getBytes) exactly like MenuDesat does:
 *   Haxe sends the full atlas ONCE per tag + a tiny frame rect every tick, and
 *   Java decodes once into atlasBmps then Bitmap.createBitmap() crops per frame.
 *   Also: every object View now gets EXPLICIT width/height. A WRAP_CONTENT
 *   ImageView with no bitmap is 0x0, so even the magenta diagnostic placeholder
 *   was invisible before. The legacy `png` field is kept as a fallback.
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

    /** Turn OFF after verifying the lower screen renders. */
    private static final boolean DIAGNOSTICS = true;

    /** Virtual coordinate space of camBottom. Must match ThorScreen.BOTTOM_W / BOTTOM_H. */
    public static final int VIRTUAL_W = 1240;
    public static final int VIRTUAL_H = 1080;

    private static volatile Presentation presentation;
    private static volatile FrameLayout root;
    private static volatile FrameLayout layer;
    private static volatile ImageView background;
    private static volatile TextView probe;
    /** Report-only. MUST NOT be used to hide the object layer any more. */
    private static volatile boolean menuMode = true;
    private static volatile boolean listenerRegistered = false;

    private static volatile String status = "not initialised";
    private static volatile String lastBgKey = "";
    private static volatile int updateCount = 0;
    private static volatile int lastObjCount = 0;
    private static volatile int lastRemoveCount = 0;
    private static volatile String lastStats = "(no stats yet - old Haxe build?)";

    private static final Map<String, View> objectViews = new HashMap<String, View>();
    private static final Map<String, String> lastPng = new HashMap<String, String>();
    /** Stage 5: decoded full atlas per tag, cropped to the current frame rect. */
    private static final Map<String, Bitmap> atlasBmps = new HashMap<String, Bitmap>();
    private static final Map<String, String> lastAtlasKey = new HashMap<String, String>();
    private static final Map<String, String> lastRect = new HashMap<String, String>();

    private ThorPresentation() {}

    private static Activity activity() {
        return Extension.mainActivity;
    }

    /** Called from Haxe with signature ()V. */
    public static void init() {
        final Activity a = activity();
        Log.i(TAG, "init() activity=" + (a != null));
        if (a == null) {
            status = "init: Extension.mainActivity is NULL";
            refreshProbe();
            return;
        }
        status = "init: posted to UI thread";
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
                resetState("dismissed");
            }
        });
    }

    /**
     * The single Haxe -> Java channel. Signature: (Ljava/lang/String;)V
     * Every drop is now reported on the probe overlay instead of returning silently.
     */
    public static void update(final String json) {
        final Activity a = activity();
        updateCount++;
        if (a == null || json == null) {
            status = "update #" + updateCount + ": activity=" + (a != null)
                   + " json=" + (json != null) + " -> DROPPED";
            refreshProbe();
            Log.w(TAG, status);
            return;
        }
        final String head = json.length() > 120 ? json.substring(0, 120) : json;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                if (root == null) {
                    status = "update #" + updateCount + ": root NULL -> DROPPED"
                           + " (Presentation.onCreate not finished, or dismissed)";
                    refreshProbe();
                    Log.w(TAG, status);
                    return;
                }
                try {
                    JSONObject o = new JSONObject(json);
                    JSONArray arr = o.optJSONArray("objects");
                    JSONArray rem = o.optJSONArray("remove");
                    int objs = arr == null ? 0 : arr.length();
                    int removes = rem == null ? 0 : rem.length();
                    lastObjCount = objs;
                    lastRemoveCount = removes;
                    lastStats = formatStats(o.optJSONObject("stats"));
                    boolean hasBg = o.optString("bg", "").length() > 0;
                    status = "update #" + updateCount + " OK"
                           + " | menu=" + o.optBoolean("menu", true)
                           + " | objs=" + objs + " rm=" + removes
                           + " | bgInJson=" + hasBg
                           + " | len=" + json.length();
                    applyJson(o);
                    refreshProbe();
                    if (updateCount % 20 == 1) {
                        Log.i(TAG, status + " | " + lastStats.replace('\n', ' ') + " | " + head);
                    }
                } catch (Throwable t) {
                    status = "update EXCEPTION: " + t;
                    refreshProbe();
                    Log.e(TAG, status, t);
                }
            }
        });
    }

    private static String formatStats(JSONObject st) {
        if (st == null) return "(payload has no stats - old Haxe build?)";
        return "inPlay=" + st.optBoolean("inPlay", false)
             + " lua=" + st.optBoolean("lua", false)
             + " ps=" + st.optBoolean("ps", false)
             + "\nstate=" + st.optString("state", "?")
             + "\ncamBottom=" + st.optBoolean("camBottom", false)
             + " camInList=" + st.optBoolean("camInList", false)
             + "\nsprites=" + st.optInt("sprites", 0)
             + " texts=" + st.optInt("texts", 0)
             + " onBottom=" + st.optInt("onBottom", 0)
             + "\nonCam=" + st.optInt("onCam", 0)
             + " byTag=" + st.optInt("byTag", 0)
             + " catchAll=" + st.optBoolean("catchAll", false)
             + "\ncamFixed=" + st.optInt("camFixed", 0)
             + " camStuck=" + st.optInt("camStuck", 0)
             + " rawOk=" + st.optInt("rawOk", 0)
             + " rawMiss=" + st.optInt("rawMiss", 0)
             + " rectOk=" + st.optInt("rectOk", 0)
             + "\npngOk=" + st.optInt("pngOk", 0)
             + " pngErr=" + st.optInt("pngErr", 0)
             + " err=" + st.optString("err", "")
             + "\nsrc=" + st.optString("src", "")
             + "\nkeys=" + st.optString("keys", "")
             + "\ncams=" + st.optString("cams", "");
    }

    /** Draws the state ON the lower screen. No logcat needed. */
    private static void refreshProbe() {
        if (!DIAGNOSTICS) return;
        final TextView tv = probe;
        if (tv == null) return;
        final FrameLayout r = root;
        final FrameLayout l = layer;
        final String s = "THOR DIAGNOSTICS\n" + status
                + "\nupdates=" + updateCount + "  showing=" + isActive()
                + "\nroot=" + (r == null ? "NULL" : r.getWidth() + "x" + r.getHeight())
                + "  menu=" + menuMode
                + "\nlayer=" + (l == null ? "NULL" : "vis=" + l.getVisibility()
                        + " children=" + l.getChildCount())
                + "  objectViews=" + objectViews.size()
                + "\nbgApplied=" + (lastBgKey.length() > 0)
                + "  objs=" + lastObjCount + " rm=" + lastRemoveCount
                + "\n--- HAXE STATS ---\n" + lastStats;
        tv.post(new Runnable() {
            @Override public void run() { tv.setText(s); }
        });
    }

    private static void resetState(String reason) {
        presentation = null;
        root = null;
        layer = null;
        background = null;
        probe = null;
        lastBgKey = "";
        lastPng.clear();
        lastAtlasKey.clear();
        lastRect.clear();
        atlasBmps.clear();
        objectViews.clear();
        lastObjCount = 0;
        lastRemoveCount = 0;
        lastStats = "(reset: " + reason + ")";
        status = reason;
    }

    private static void createOnUiThread(Activity a) {
        if (isActive()) return;
        Display display = findDisplay(a);
        if (display == null) {
            status = "NO usable secondary display";
            refreshProbe();
            Log.w(TAG, status);
            return;
        }
        Log.i(TAG, "selected display id=" + display.getDisplayId()
                + " " + display.getWidth() + "x" + display.getHeight()
                + " flags=" + display.getFlags() + " " + display);
        status = "display #" + display.getDisplayId()
               + " " + display.getWidth() + "x" + display.getHeight();

        lastBgKey = "";
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
                // STAGE 3: always visible. Haxe sends an explicit "remove" list
                // when leaving PlayState; hiding by `menu` silently blanked all
                // Lua objects and was the main cause of "nothing shows up".
                layer.setVisibility(View.VISIBLE);
                root.addView(layer, new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT));

                if (DIAGNOSTICS) {
                    probe = new TextView(getContext());
                    probe.setTextColor(Color.GREEN);
                    probe.setTextSize(TypedValue.COMPLEX_UNIT_PX, 20f);
                    probe.setPadding(20, 20, 20, 20);
                    probe.setBackgroundColor(Color.argb(180, 0, 0, 0));
                    // Tap the probe once to hide it and inspect the WHOLE lower
                    // screen: the stats board covers roughly y=0..330, so any
                    // object placed above that can look "missing" otherwise.
                    probe.setOnClickListener(new View.OnClickListener() {
                        @Override public void onClick(View v) { v.setVisibility(View.GONE); }
                    });
                    probe.setClickable(true);
                    // Added last => drawn on top of the background and object layer.
                    root.addView(probe, new FrameLayout.LayoutParams(
                            FrameLayout.LayoutParams.MATCH_PARENT,
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            Gravity.TOP));
                }

                setContentView(root);

                Window w = getWindow();
                if (w != null) {
                    // Do NOT steal focus from the game, otherwise FNF pauses on focus loss.
                    w.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
                    w.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL);
                    w.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                    w.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS);
                }
                status += " | onCreate OK, waiting for update()";
                Log.i(TAG, "Presentation.onCreate: root/probe created");
                refreshProbe();
            }
        };

        presentation.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override public void onDismiss(DialogInterface dialog) {
                Log.i(TAG, "Presentation dismissed");
                resetState("dismissed by system");
            }
        });

        try {
            presentation.show();
        } catch (Throwable t) {
            status = "Presentation.show() FAILED: " + t;
            refreshProbe();
            Log.e(TAG, status, t);
            presentation = null;
            return;
        }

        registerDisplayListener(a);
        status += " | show() OK isShowing=" + isActive();
        Log.i(TAG, "Secondary display ready: " + display.getDisplayId());
        refreshProbe();
    }

    /** Prefer DISPLAY_CATEGORY_PRESENTATION, fall back to the smallest non-default display. */
    private static Display findDisplay(Activity a) {
        DisplayManager dm = (DisplayManager) a.getSystemService(Context.DISPLAY_SERVICE);
        if (dm == null) return null;

        Display[] all = dm.getDisplays();
        Log.i(TAG, "DisplayManager reports " + (all == null ? 0 : all.length) + " display(s)");
        if (all != null) {
            for (Display d : all) {
                Log.i(TAG, "  display id=" + d.getDisplayId()
                        + " " + d.getWidth() + "x" + d.getHeight()
                        + " flags=" + d.getFlags() + " " + d);
            }
        }

        Display best = null;
        Display[] presentationDisplays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        if (presentationDisplays != null) {
            for (Display d : presentationDisplays) {
                if (d.getDisplayId() == Display.DEFAULT_DISPLAY) continue;
                if (best == null || area(d) < area(best)) best = d;
            }
        }
        if (best == null && all != null) {
            for (Display d : all) {
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
        // `menu` is now report-only. Never derive the object layer visibility
        // from it: a single wrong inPlay guess on the Haxe side would otherwise
        // hide every Lua object with no error in logcat at all.
        menuMode = obj.optBoolean("menu", true);
        if (layer != null) layer.setVisibility(View.VISIBLE);

        String bg = obj.optString("bg", "");
        if (bg != null && bg.length() > 0 && background != null) {
            // Haxe re-pushes the same PNG every 3s; decode only when it changes.
            String key = bg.length() + ":" + bg.hashCode();
            if (!key.equals(lastBgKey)) {
                try {
                    byte[] bytes = Base64.decode(bg, Base64.DEFAULT);
                    Bitmap bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                    if (bmp != null) {
                        background.setImageBitmap(bmp);
                        lastBgKey = key;
                        status += " | bg decoded " + bmp.getWidth() + "x" + bmp.getHeight();
                        Log.i(TAG, "menuDesat decoded " + bmp.getWidth() + "x" + bmp.getHeight()
                                + " from " + bytes.length + " bytes");
                    } else {
                        status += " | bg decode returned NULL (" + bytes.length + " bytes)";
                        Log.w(TAG, status);
                    }
                } catch (Throwable t) {
                    status += " | bg decode FAILED: " + t;
                    Log.w(TAG, status, t);
                }
            }
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
                Log.i(TAG, "created TextView for " + tag);
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
            // Explicit width: a WRAP_CONTENT TextView with an empty string can
            // collapse to 0px and look identical to "the object never arrived".
            applySize(tv, o, false);
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
            // Diagnostic placeholder: a magenta box means "Haxe sent this
            // object but no PNG ever decoded" (encodeBitmap failed on Android).
            if (DIAGNOSTICS) iv.setBackgroundColor(Color.MAGENTA);
            layer.addView(iv, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT));
            objectViews.put(tag, iv);
            lastPng.remove(tag);
            // A freshly created ImageView has no bitmap. Invalidate the rect
            // cache so the very next tick re-crops from the cached full atlas.
            lastRect.remove(tag);
            Log.i(TAG, "created ImageView for " + tag + " (type=" + type + ")");
        }

        // ---- STAGE 5: primary image source = raw packaged atlas PNG ----
        // Haxe sends the whole atlas once (and re-sends it on the 3s background
        // repush). Decode it once, cache it, then crop the tiny frame rect that
        // arrives on every tick. This avoids BitmapData.encode() entirely.
        String atlas = o.optString("atlas", "");
        // A JSON null can surface as the literal string "null", and "null" is
        // exactly 4 legal Base64 chars -> the mysterious 3-byte stub in logcat.
        // Real PNG Base64 is always far longer than 16 chars.
        if (atlas == null || "null".equals(atlas) || atlas.length() < 16) atlas = "";
        if (atlas.length() > 0) {
            String key = atlas.length() + ":" + atlas.hashCode();
            if (!key.equals(lastAtlasKey.get(tag))) {
                try {
                    byte[] bytes = Base64.decode(atlas, Base64.DEFAULT);
                    if (!isPngBytes(bytes)) {
                        Log.w(TAG, "atlas NOT PNG for " + tag + " (" + bytes.length
                                + " bytes) head=" + atlas.substring(0, Math.min(24, atlas.length())));
                    } else {
                        Bitmap full = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                        if (full != null) {
                            atlasBmps.put(tag, full);
                            lastAtlasKey.put(tag, key);
                            // New atlas -> force a fresh crop on the next tick.
                            lastRect.remove(tag);
                            Log.i(TAG, "decoded atlas for " + tag + " "
                                    + full.getWidth() + "x" + full.getHeight());
                        } else {
                            Log.w(TAG, "atlas decode NULL for " + tag + " (" + bytes.length + " bytes)");
                        }
                    }
                } catch (Throwable t) {
                    Log.w(TAG, "bad atlas for " + tag + ": " + t.getMessage());
                }
            }
        }

        Bitmap full = atlasBmps.get(tag);
        int fx = o.optInt("fx", -1);
        int fy = o.optInt("fy", -1);
        int fw = o.optInt("fw", -1);
        int fh = o.optInt("fh", -1);
        boolean cropped = false;
        if (full != null && fw > 0 && fh > 0) {
            String rectKey = fx + "," + fy + "," + fw + "," + fh;
            if (!rectKey.equals(lastRect.get(tag))) {
                try {
                    int cx = Math.max(0, Math.min(fx, full.getWidth() - 1));
                    int cy = Math.max(0, Math.min(fy, full.getHeight() - 1));
                    int cw = Math.max(1, Math.min(fw, full.getWidth() - cx));
                    int ch = Math.max(1, Math.min(fh, full.getHeight() - cy));
                    Bitmap crop = Bitmap.createBitmap(full, cx, cy, cw, ch);
                    iv.setImageBitmap(crop);
                    if (DIAGNOSTICS) iv.setBackgroundColor(Color.TRANSPARENT);
                    iv.setPivotX(crop.getWidth() * 0.5f);
                    iv.setPivotY(crop.getHeight() * 0.5f);
                    lastRect.put(tag, rectKey);
                    cropped = true;
                } catch (Throwable t) {
                    Log.w(TAG, "atlas crop failed for " + tag + " (" + fx + "," + fy
                            + " " + fw + "x" + fh + " on "
                            + full.getWidth() + "x" + full.getHeight() + "): " + t.getMessage());
                }
            } else {
                cropped = true; // already showing this exact frame
            }
        } else if (full != null && iv.getDrawable() == null) {
            // No usable frame rect: show the whole atlas rather than nothing.
            iv.setImageBitmap(full);
            if (DIAGNOSTICS) iv.setBackgroundColor(Color.TRANSPARENT);
            cropped = true;
        }

        // ---- legacy BitmapData.encode() fallback ----
        String png = o.optString("png", "");
        if (!cropped && png != null && png.length() > 0 && !png.equals(lastPng.get(tag))) {
            try {
                byte[] bytes = Base64.decode(png, Base64.DEFAULT);
                Bitmap bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                if (bmp != null) {
                    iv.setImageBitmap(bmp);
                    lastPng.put(tag, png);
                    if (DIAGNOSTICS) iv.setBackgroundColor(Color.TRANSPARENT);
                    iv.setPivotX(bmp.getWidth() * 0.5f);
                    iv.setPivotY(bmp.getHeight() * 0.5f);
                    Log.i(TAG, "decoded legacy sprite png for " + tag + " "
                            + bmp.getWidth() + "x" + bmp.getHeight());
                } else {
                    Log.w(TAG, "legacy png decode NULL for " + tag + " (" + bytes.length + " bytes)");
                }
            } catch (Throwable t) {
                Log.w(TAG, "bad legacy sprite png for " + tag + ": " + t.getMessage());
            }
        }

        int tint = o.optInt("color", 0xFFFFFFFF);
        if (tint != 0xFFFFFFFF) iv.setColorFilter(tint, PorterDuff.Mode.MULTIPLY);
        else iv.clearColorFilter();

        // STAGE 5: give the ImageView a real size. WRAP_CONTENT + no bitmap was
        // a 0x0 view, which made even the magenta placeholder invisible.
        applySize(iv, o, true);
        transform(iv, o);
        boolean flipX = o.optBoolean("flipX", false);
        if (flipX) iv.setScaleX(-Math.abs(iv.getScaleX()));
    }

    /**
     * Explicit LayoutParams size. Frame dims (fw/fh) are preferred for sprites
     * because transform() already applies scale via setScaleX/setScaleY; using
     * the scaled sprite width here would double-apply it.
     */
    private static void applySize(View v, JSONObject o, boolean useHeight) {
        int w = o.optInt("fw", 0);
        int h = o.optInt("fh", 0);
        if (w <= 0) w = (int) o.optDouble("w", 0);
        if (h <= 0) h = (int) o.optDouble("h", 0);
        if (w <= 0 && (!useHeight || h <= 0)) return;
        android.view.ViewGroup.LayoutParams raw = v.getLayoutParams();
        if (!(raw instanceof FrameLayout.LayoutParams)) return;
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) raw;
        boolean changed = false;
        if (w > 0 && lp.width != w) { lp.width = w; changed = true; }
        if (useHeight && h > 0 && lp.height != h) { lp.height = h; changed = true; }
        if (changed) v.setLayoutParams(lp);
    }

    /** Reject the tiny stub that Assets.getBytes() returns for a bad asset id. */
    private static boolean isPngBytes(byte[] b) {
        if (b == null || b.length < 8) return false;
        return (b[0] & 0xFF) == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G'
                && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A;
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
        // STAGE 3: only the object's own `visible` flag matters. The old
        // "&& !menuMode" hid every object View whenever the payload said menu.
        boolean visible = o.optBoolean("visible", true);
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
        lastAtlasKey.remove(tag);
        lastRect.remove(tag);
        atlasBmps.remove(tag);
        if (v != null && layer != null) layer.removeView(v);
    }
}
