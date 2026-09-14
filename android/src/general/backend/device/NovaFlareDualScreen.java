package general.backend.device;

import android.app.Presentation;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.util.Log;
import android.view.Display;
import android.view.WindowManager;
import android.view.View;
import haxe.io.Bytes;

import java.util.HashMap;
import java.util.Map;

/**
 * NovaFlare Engine - AYN Thor 双屏支持桥接类
 * 
 * 该类通过 Android Presentation API 在副屏（下屏）显示 HUD 内容。
 * 
 * 放置位置：
 * 需要将此文件放在 Android 项目的 Java 源目录中：
 * android/src/main/java/general/backend/device/NovaFlareDualScreen.java
 * 
 * 或者根据你的项目包结构调整 package 声明。
 * 
 * 双屏显示原理：
 * 1. 检测可用的二级显示器（AYN Thor 的下屏）
 * 2. 创建 android.app.Presentation 绑定到副屏
 * 3. 每帧接收来自 Haxe 的像素数据并绘制到副屏
 * 
 * 参考实现：
 * - zelda3-android: SecondScreenPresentation.java
 * - tmc-android: 类似 approach
 * - dusklight: dual-screen companion code
 */
public class NovaFlareDualScreen {
    private static final String TAG = "NovaFlareDualScreen";
    
    /** 副屏 Presentation 实例 */
    private static SecondScreenPresentation presentation = null;
    
    /** 主 Activity 上下文 */
    private static Context applicationContext = null;
    
    /** 是否已初始化 */
    private static boolean initialized = false;
    
    /** 副屏是否可见 */
    private static boolean visible = true;
    
    /**
     * 初始化双屏功能
     * 由 Main.hx 中的 initDualScreen() JNI 调用
     * 
     * @param context Android Context
     */
    public static void initDualScreen(Context context) {
        applicationContext = context.getApplicationContext();
        
        try {
            // 获取 WindowManager 来检测显示器
            WindowManager wm = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
            
            // 获取所有已连接的显示器
            Display[] displays = wm.getDisplays();
            boolean foundSecondary = false;
            
            for (Display display : displays) {
                int displayId = display.getDisplayId();
                
                // 跳过主显示器（Display.DEFAULT_DISPLAY = 0）
                if (displayId == Display.DEFAULT_DISPLAY) {
                    Log.d(TAG, "Skipping default display: " + displayId);
                    continue;
                }
                
                // 找到副屏！创建 Presentation
                Log.d(TAG, "Found secondary display: " + display.getName() 
                      + " (id=" + displayId + ", " + display.getWidth() + "x" + display.getHeight() + ")");
                
                // 创建并显示 Presentation
                showPresentation(display);
                foundSecondary = true;
                break; // 只使用第一个找到的副屏
            }
            
            if (!foundSecondary) {
                Log.w(TAG, "No secondary display found. Dual screen mode disabled.");
            } else {
                initialized = true;
                Log.d(TAG, "Dual screen initialized successfully!");
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize dual screen", e);
        }
    }
    
    /**
     * 在副屏上显示 Presentation
     */
    private static void showPresentation(Display display) {
        if (applicationContext == null) return;
        
        try {
            // 创建自定义的 Presentation
            presentation = new SecondScreenPresentation(applicationContext, display);
            presentation.getWindow().setBackgroundDrawable(new ColorDrawable(Color.BLACK));
            presentation.show();
            
            Log.d(TAG, "Presentation shown on display: " + display.getDisplayId());
        } catch (Exception e) {
            Log.e(TAG, "Failed to show presentation", e);
        }
    }
    
    /**
     * 更新下屏画面
     * 由 Main.hx 中的 updateBottomScreen() JNI 调用
     * 
     * @param pixels 像素数据（ARGB_8888 格式）
     * @param width 画面宽度
     * @param height 画面高度
     * @param displayType 显示器类型（0=下屏）
     */
    public static void updateBottomScreen(Bytes pixels, int width, int height, int displayType) {
        if (!initialized || presentation == null || pixels == null) return;
        
        try {
            // 将 haxe.io.Bytes 转换为 byte[]
            byte[] byteArray = pixels.toArray();
            
            // 在 UI 线程中更新画面
            presentation.updateBitmap(byteArray, width, height);
        } catch (Exception e) {
            Log.e(TAG, "Failed to update bottom screen", e);
        }
    }
    
    /**
     * 更新游戏状态数据（备选方案：当无法渲染完整画面时使用）
     * 由 PlayState.hx 中的备选渲染方案调用
     * 
     * @param health 当前健康值
     * @param score 当前分数
     */
    public static void updateGameState(float health, float score) {
        if (!initialized || presentation == null) return;
        
        try {
            presentation.updateGameState(health, score);
        } catch (Exception e) {
            Log.e(TAG, "Failed to update game state", e);
        }
    }
    
    /**
     * 初始化下屏 HUD（由 PlayState.hx 调用）
     */
    public static void initBottomScreen() {
        if (!initialized || presentation == null) return;
        
        try {
            presentation.initHUD();
            Log.d(TAG, "Bottom screen HUD initialized");
        } catch (Exception e) {
            Log.e(TAG, "Failed to init bottom screen HUD", e);
        }
    }
    
    /**
     * 设置下屏可见性
     * 
     * @param visible 是否可见
     */
    public static void setBottomScreenVisible(boolean visible) {
        NovaFlareDualScreen.visible = visible;
        
        if (presentation != null) {
            presentation.setVisibility(visible ? View.VISIBLE : View.GONE);
            Log.d(TAG, "Bottom screen visibility set to: " + visible);
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
        initialized = false;
        Log.d(TAG, "Dual screen destroyed");
    }
    
    /**
     * 获取双屏是否已初始化
     */
    public static boolean isInitialized() {
        return initialized;
    }
    
    // ============================================================
    // 内部类：副屏 Presentation
    // ============================================================
    
    /**
     * 副屏显示窗口
     * 继承 android.app.Presentation 以在二级显示器上显示内容
     * 
     * 参考 zelda3-android 的 SecondScreenPresentation.java 实现
     */
    private static class SecondScreenPresentation extends Presentation {
        private BottomScreenView bottomView;
        private Bitmap currentBitmap = null;
        private int bitmapWidth = 0;
        private int bitmapHeight = 0;
        private float health = 1.0f;
        private float score = 0.0f;
        private boolean hudInitialized = false;
        
        public SecondScreenPresentation(Context context, Display display) {
            super(context, display);
        }
        
        @Override
        protected void onCreate(Bundle savedInstanceState) {
            super.onCreate(savedInstanceState);
            
            // 设置窗口属性
            if (getWindow() != null) {
                getWindow().setBackgroundDrawable(new ColorDrawable(Color.BLACK));
                getWindow().setLayout(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT
                );
                
                // 保持屏幕常亮
                getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                
                // 非焦点模式：确保游戏窗口的游戏手柄输入不受影响
                getWindow().addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
                
                // 全屏模式：隐藏导航栏和状态栏
                getWindow().getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    | View.SYSTEM_UI_FLAG_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                );
            }
            
            // 创建自定义的底部屏幕视图
            bottomView = new BottomScreenView(getContext());
            setContentView(bottomView);
            
            Log.d(TAG, "SecondScreenPresentation created");
        }
        
        /**
         * 更新画面位图
         */
        public void updateBitmap(byte[] pixels, int width, int height) {
            if (!visible) return;
            
            this.bitmapWidth = width;
            this.bitmapHeight = height;
            
            // 将像素数据转换为 Bitmap
            if (currentBitmap == null 
                || currentBitmap.getWidth() != width 
                || currentBitmap.getHeight() != height) {
                
                if (currentBitmap != null) {
                    currentBitmap.recycle();
                }
                
                currentBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            }
            
            // 将 byte[] 数据填充到 Bitmap
            currentBitmap.copyPixelsFromBuffer(java.nio.ByteBuffer.wrap(pixels));
            
            // 请求重绘
            bottomView.invalidate();
        }
        
        /**
         * 更新游戏状态数据（备选方案）
         */
        public void updateGameState(float health, float score) {
            this.health = health;
            this.score = score;
            
            if (!hudInitialized) {
                hudInitialized = true;
            }
            
            bottomView.invalidate();
        }
        
        /**
         * 初始化 HUD
         */
        public void initHUD() {
            hudInitialized = true;
            bottomView.invalidate();
        }
        
        /**
         * 设置可见性
         */
        @Override
        public void setVisibility(int visibility) {
            super.setVisibility(visibility);
            if (bottomView != null) {
                bottomView.setVisibility(visibility);
            }
        }
        
        /**
         * 自定义视图：在副屏上绘制内容
         */
        private class BottomScreenView extends View {
            private final android.graphics.Paint paint = new android.graphics.Paint();
            
            public BottomScreenView(Context context) {
                super(context);
                setFocusable(false); // 不获取焦点，不影响游戏输入
                setClickable(false);
            }
            
            @Override
            protected void onDraw(Canvas canvas) {
                super.onDraw(canvas);
                
                int width = canvas.getWidth();
                int height = canvas.getHeight();
                
                // 绘制背景
                canvas.drawColor(Color.BLACK);
                
                // 如果有画面位图，绘制它
                if (currentBitmap != null && !currentBitmap.isRecycled()) {
                    // 计算缩放以填充屏幕（保持宽高比）
                    float bitmapRatio = (float) currentBitmap.getWidth() / currentBitmap.getHeight();
                    float viewRatio = (float) width / height;
                    
                    int drawWidth, drawHeight, offsetX, offsetY;
                    
                    if (bitmapRatio > viewRatio) {
                        // 位图更宽，以宽度为基准
                        drawWidth = width;
                        drawHeight = width / (int) bitmapRatio;
                        offsetX = 0;
                        offsetY = (height - drawHeight) / 2;
                    } else {
                        // 位图更高，以高度为基准
                        drawHeight = height;
                        drawWidth = height * (int) bitmapRatio;
                        offsetX = (width - drawWidth) / 2;
                        offsetY = 0;
                    }
                    
                    canvas.drawBitmap(currentBitmap, offsetX, offsetY, paint);
                } else if (hudInitialized) {
                    // 没有位图时，绘制简化 HUD 信息
                    drawSimpleHUD(canvas, width, height);
                }
            }
            
            /**
             * 绘制简化的 HUD 信息（备选方案）
             */
            private void drawSimpleHUD(Canvas canvas, int width, int height) {
                android.graphics.Paint textPaint = new android.graphics.Paint();
                textPaint.setColor(Color.WHITE);
                textPaint.setTextSize(48);
                textPaint.setAntiAlias(true);
                
                // 绘制健康值
                String healthText = "Health: " + String.format("%.1f", health * 100) + "%";
                canvas.drawText(healthText, 50, 80, textPaint);
                
                // 绘制分数
                String scoreText = "Score: " + String.valueOf((int) score);
                canvas.drawText(scoreText, 50, 140, textPaint);
                
                // 绘制提示文字
                android.graphics.Paint hintPaint = new android.graphics.Paint();
                hintPaint.setColor(Color.GRAY);
                hintPaint.setTextSize(32);
                String hint = "HUD Display (Bitmap mode unavailable)";
                canvas.drawText(hint, 50, height - 50, hintPaint);
            }
        }
    }
}
