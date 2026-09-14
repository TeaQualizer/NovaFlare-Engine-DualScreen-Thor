package general.backend.device;

import android.app.Activity;
import android.app.Presentation;
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.text.TextPaint;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

public class NovaFlareDualScreen {
    private static final String TAG = "NovaFlareDualScreen";
    
    private static Context applicationContext;
    private static SecondScreenPresentation presentation;
    private static BottomScreenView bottomView;
    
    // 缓存的 JNI 数据
    private static Bitmap currentBitmap;
    private static boolean hudInitialized = false;
    private static float cachedHealth = 1.0f;
    private static int cachedScore = 0;

    /**
     * 初始化双屏支持 (由 Haxe 端通过 JNI 调用)
     */
    public static boolean initDualScreen(Context context) {
        try {
            // 【核心修复 1】：将 Context 的处理完全移入 try-catch 块内，防止 NPE 穿透到 JNI 层
            if (context == null) {
                Log.e(TAG, "[DualScreen] Context is null, cannot initialize.");
                return false;
            }
            
            applicationContext = context.getApplicationContext();
            
            DisplayManager displayManager = (DisplayManager) applicationContext.getSystemService(Context.DISPLAY_SERVICE);
            if (displayManager == null) {
                Log.e(TAG, "[DualScreen] DisplayManager is null.");
                return false;
            }

            Display[] displays = displayManager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
            Log.i(TAG, "[DualScreen] Found " + displays.length + " presentation displays.");

            if (displays.length > 0) {
                // 优先使用第一个副屏
                Display secondaryDisplay = displays[0];
                presentation = new SecondScreenPresentation(applicationContext, secondaryDisplay);
                
                presentation.setOnDismissListener(new DialogInterface.OnDismissListener() {
                    @Override
                    public void onDismiss(DialogInterface dialog) {
                        Log.i(TAG, "[DualScreen] Presentation dismissed.");
                        presentation = null;
                        bottomView = null;
                    }
                });
                
                presentation.show();
                Log.i(TAG, "[DualScreen] Initialized successfully on display: " + secondaryDisplay.getName());
                return true;
            } else {
                Log.w(TAG, "[DualScreen] No secondary presentation displays found.");
                return false;
            }
        } catch (Exception e) {
            Log.e(TAG, "[DualScreen] Failed to initialize dual screen", e);
            return false;
        }
    }

    /**
     * 更新副屏画面 (由 Haxe 端每帧通过 JNI 调用)
     * 【核心修复 2】：将参数类型从 haxe.io.Bytes 改为 Object，并在内部安全转换为 byte[]
     */
    public static void updateBottomScreen(Object pixels, int width, int height, int format) {
        if (bottomView == null || pixels == null) return;

        try {
            byte[] pixelArray;
            // 安全地检查并转换类型
            if (pixels instanceof byte[]) {
                pixelArray = (byte[]) pixels;
            } else {
                Log.w(TAG, "[DualScreen] Received unsupported pixel data type: " + pixels.getClass().getName());
                return;
            }

            // 创建或复用 Bitmap
            if (currentBitmap == null || currentBitmap.getWidth() != width || currentBitmap.getHeight() != height) {
                if (currentBitmap != null) {
                    currentBitmap.recycle();
                }
                currentBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            }

            // 将字节数组复制到 Bitmap
            currentBitmap.copyPixelsFromBuffer(java.nio.ByteBuffer.wrap(pixelArray));

            // 通知 View 刷新
            bottomView.updateBitmap(currentBitmap);

        } catch (Exception e) {
            Log.e(TAG, "[DualScreen] Failed to update bottom screen bitmap", e);
        }
    }

    /**
     * 备选方案：更新游戏状态 (如果像素传输性能不佳)
     */
    public static void updateGameState(float health, int score) {
        cachedHealth = health;
        cachedScore = score;
        hudInitialized = true;
        
        if (bottomView != null) {
            bottomView.invalidate(); // 触发重绘
        }
    }

    /**
     * 设置副屏可见性
     */
    public static void setBottomScreenVisible(boolean visible) {
        if (presentation != null) {
            if (visible) {
                presentation.show();
            } else {
                presentation.dismiss();
            }
        }
    }

    /**
     * 销毁双屏资源
     */
    public static void destroy() {
        if (presentation != null) {
            presentation.dismiss();
            presentation = null;
        }
        if (currentBitmap != null) {
            currentBitmap.recycle();
            currentBitmap = null;
        }
        bottomView = null;
        hudInitialized = false;
    }

    /**
     * 检查是否已初始化
     */
    public static boolean isInitialized() {
        return presentation != null && bottomView != null;
    }

    // ==========================================
    // 内部类：副屏 Presentation 窗口
    // ==========================================
    private static class SecondScreenPresentation extends Presentation {
        public SecondScreenPresentation(Context context, Display display) {
            super(context, display);
        }

        @Override
        protected void onCreate(Bundle savedInstanceState) {
            super.onCreate(savedInstanceState);
            
            // 设置全屏、非焦点、常亮
            getWindow().setFlags(
                WindowManager.LayoutParams.FLAG_FULLSCREEN | 
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON |
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                WindowManager.LayoutParams.FLAG_FULLSCREEN | 
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON |
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            );

            // 沉浸式全屏
            getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
                View.SYSTEM_UI_FLAG_FULLSCREEN |
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE |
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            );

            // 创建自定义 View
            bottomView = new BottomScreenView(getContext());
            setContentView(bottomView);
        }
    }

    // ==========================================
    // 内部类：副屏渲染 View
    // ==========================================
    private static class BottomScreenView extends View {
        private Bitmap bitmap;
        private Paint paint;
        private Rect srcRect;
        private Rect dstRect;
        private TextPaint textPaint;

        public BottomScreenView(Context context) {
            super(context);
            paint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.ANTI_ALIAS_FLAG);
            textPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
            textPaint.setColor(Color.WHITE);
            textPaint.setTextSize(48f);
            textPaint.setTextAlign(Paint.Align.CENTER);
            
            setBackgroundColor(Color.BLACK);
        }

        public void updateBitmap(Bitmap bmp) {
            this.bitmap = bmp;
            invalidate(); // 请求重绘
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            
            int viewWidth = getWidth();
            int viewHeight = getHeight();

            // 优先绘制 Bitmap 画面
            if (bitmap != null && !bitmap.isRecycled()) {
                if (srcRect == null) {
                    srcRect = new Rect();
                    dstRect = new Rect();
                }
                srcRect.set(0, 0, bitmap.getWidth(), bitmap.getHeight());
                
                // 等比缩放居中
                float scale = Math.min((float) viewWidth / bitmap.getWidth(), (float) viewHeight / bitmap.getHeight());
                int scaledWidth = (int) (bitmap.getWidth() * scale);
                int scaledHeight = (int) (bitmap.getHeight() * scale);
                
                int left = (viewWidth - scaledWidth) / 2;
                int top = (viewHeight - scaledHeight) / 2;
                dstRect.set(left, top, left + scaledWidth, top + scaledHeight);
                
                canvas.drawBitmap(bitmap, srcRect, dstRect, paint);
            } 
            // 备选方案：绘制简化 HUD
            else if (hudInitialized) {
                canvas.drawText("Health: " + String.format("%.0f%%", cachedHealth * 100), viewWidth / 2f, viewHeight / 2f - 40, textPaint);
                canvas.drawText("Score: " + cachedScore, viewWidth / 2f, viewHeight / 2f + 40, textPaint);
            }
        }
    }
}
