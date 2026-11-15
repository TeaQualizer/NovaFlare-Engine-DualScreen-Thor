/*
 * Drop into: source/mobile/android/ThorScreen.hx   (package mobile.android)
 *
 * Haxe side of the Thor dual-screen bridge.
 *
 * Design note (important):
 *   An Android Presentation is a Dialog with its OWN View hierarchy. It is not an
 *   OpenFL Stage, so a FlxCamera cannot be "attached" to it. On Android this engine
 *   runs FlxG.renderTile (hardware), where FlxCamera has no BitmapData buffer, so
 *   framebuffer readback is unreliable. Instead:
 *
 *     - camBottom is a REAL FlxCamera in PlayState (so every Psych Lua function works).
 *     - Its flashSprite is hidden, so assigned objects never appear on the main screen,
 *       but Flixel still calls draw() on them (which keeps framePixels up to date).
 *     - Every 50ms we walk modchartSprites / modchartTexts, pick the objects whose
 *       .cameras contains camBottom, and mirror their LIVE state into native Android
 *       Views through a single JNI call carrying a JSON string.
 *
 *   That means setObjectCamera(tag, 'bottom') is the ONLY Lua-side change needed.
 *   doTweenX / setProperty / scale / alpha / angle / playAnim / setTextString etc.
 *   all keep working because we read the object state, not a screenshot.
 *
 *   Known limitation: shaders, filters, blend modes, scrollFactor and camera zoom
 *   are NOT mirrored. If you need pixel-exact Flixel rendering on the lower screen,
 *   you need a second EGL surface (Presentation + ANativeWindow + shared context),
 *   which is a much larger native project.
 *
 * Patch points (see patch_points.txt):
 *   1. source/Main.hx            -> init(): ThorScreen.start()
 *   2. source/games/PlayState.hx -> declare + create camBottom
 *   3. source/scripts/lua/LuaUtils.hx -> cameraFromString(): add 'bottom' alias
 */

package mobile.android;

#if android

import flixel.FlxCamera;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.text.FlxText;
import games.PlayState;
import general.backend.Paths;
import haxe.Json;
import haxe.crypto.Base64;
import haxe.ds.StringMap;
import lime.system.JNI;
import openfl.display.BitmapData;
import openfl.display.PNGEncoderOptions;
import openfl.events.Event;
import openfl.Lib;
import openfl.utils.ByteArray;

class ThorScreen {
	/** Virtual coordinate space of the lower screen (3.92" 1240x1080). */
	public static final BOTTOM_W:Int = 1240;
	public static final BOTTOM_H:Int = 1080;

	/** Mirror tick. 20 Hz is plenty for a 60 Hz lower panel and keeps JNI/PNG cost low. */
	static final TICK_MS:Int = 50;

	static var _initJNI:Null<Dynamic> = null;
	static var _updateJNI:Null<Dynamic> = null;
	static var _isActiveJNI:Null<Dynamic> = null;
	static var _dismissJNI:Null<Dynamic> = null;

	static var _started:Bool = false;
	static var _lastTick:Int = 0;
	static var _bgSent:Bool = false;
	static var _menuPng:Null<String> = null;

	/** tag -> last frame key, so animated sprites only re-encode when the frame changes. */
	static var _frameCache:StringMap<String> = new StringMap<String>();
	/** tags present on the previous tick, used to emit "remove" entries. */
	static var _seen:StringMap<Bool> = new StringMap<Bool>();

	public static function start():Void {
		if (_started) return;
		_started = true;

		final cls:String = 'org/novaflare/thor/ThorPresentation';
		_initJNI = JNI.createStaticMethod(cls, 'init', '()V', false, true);
		_updateJNI = JNI.createStaticMethod(cls, 'update', '(Ljava/lang/String;)V', false, true);
		_isActiveJNI = JNI.createStaticMethod(cls, 'isActive', '()Z', false, true);
		_dismissJNI = JNI.createStaticMethod(cls, 'dismiss', '()V', false, true);

		if (_initJNI == null || _updateJNI == null) {
			trace('[Thor] ThorPresentation Java class not found; dual screen disabled.');
			_started = false;
			return;
		}

		_initJNI();
		_menuPng = encodeMenuDesat();
		_lastTick = Lib.getTimer();
		Lib.current.addEventListener(Event.ENTER_FRAME, onEnterFrame);
	}

	public static function stop():Void {
		if (!_started) return;
		Lib.current.removeEventListener(Event.ENTER_FRAME, onEnterFrame);
		if (_dismissJNI != null) _dismissJNI();
		_started = false;
		_bgSent = false;
		_frameCache = new StringMap<String>();
		_seen = new StringMap<Bool>();
	}

	static function onEnterFrame(_:Event):Void {
		final now:Int = Lib.getTimer();
		if (now - _lastTick < TICK_MS) return;
		_lastTick = now;
		tick();
	}

	/** Can also be called manually from MusicBeatState.update() if you prefer. */
	public static function tick():Void {
		if (_updateJNI == null) return;
		if (_isActiveJNI != null && !_isActiveJNI()) return;

		final inPlay:Bool = PlayState.instance != null && Std.isOfType(FlxG.state, PlayState);
		final payload:Dynamic = {menu: !inPlay, objects: [], remove: []};

		if (!inPlay) {
			// Every state except PlayState: static MenuDesat background, no object layer.
			if (!_bgSent && _menuPng != null) {
				payload.bg = _menuPng;
				_bgSent = true;
			}
			for (tag in _seen.keys()) payload.remove.push(tag);
			_seen = new StringMap<Bool>();
			_frameCache = new StringMap<String>();
		} else {
			// MenuDesat stays behind the camBottom layer. Set hideBg = true in Java
			// if you want a black gameplay background instead.
			if (!_bgSent && _menuPng != null) {
				payload.bg = _menuPng;
				_bgSent = true;
			}
			syncObjects(payload);
		}

		_updateJNI(Json.stringify(payload));
	}

	static function syncObjects(payload:Dynamic):Void {
		final ps:PlayState = PlayState.instance;
		if (ps == null || ps.camBottom == null) return;
		final cam:FlxCamera = ps.camBottom;
		final current:StringMap<Bool> = new StringMap<Bool>();

		#if LUA_ALLOWED
		for (tag => spr in ps.modchartSprites) {
			if (spr == null || !isOnBottom(spr, cam)) continue;
			current.set(tag, true);

			final frameKey:String = getFrameKey(spr);
			var png:Null<String> = null;
			if (_frameCache.get(tag) != frameKey) {
				final bmp:Null<BitmapData> = getFrameBitmap(spr);
				if (bmp != null) {
					png = encodeBitmap(bmp);
					_frameCache.set(tag, frameKey);
				}
			}

			payload.objects.push({
				tag: tag,
				type: 'sprite',
				png: png,
				x: spr.x,
				y: spr.y,
				w: spr.width,
				h: spr.height,
				sx: spr.scale.x,
				sy: spr.scale.y,
				angle: spr.angle,
				alpha: spr.alpha,
				visible: spr.visible,
				flipX: spr.flipX,
				color: (spr.color : Int)
			});
		}

		for (tag => txt in ps.modchartTexts) {
			if (txt == null || !isOnBottom(txt, cam)) continue;
			current.set(tag, true);
			payload.objects.push({
				tag: tag,
				type: 'text',
				text: txt.text,
				x: txt.x,
				y: txt.y,
				w: txt.fieldWidth,
				size: txt.size,
				color: (txt.color : Int),
				align: alignString(txt.alignment),
				sx: txt.scale.x,
				sy: txt.scale.y,
				angle: txt.angle,
				alpha: txt.alpha,
				visible: txt.visible
			});
		}
		#end

		for (tag in _seen.keys()) if (!current.exists(tag)) payload.remove.push(tag);
		_seen = current;
	}

	static inline function isOnBottom(obj:Dynamic, cam:FlxCamera):Bool {
		final cams:Array<FlxCamera> = obj.cameras;
		if (cams == null) return false;
		for (c in cams) if (c == cam) return true;
		return false;
	}

	/**
	 * In tile render mode useFramePixels defaults to false, so force it on and
	 * refresh the current animation frame before reading framePixels.
	 */
	static function getFrameBitmap(spr:FlxSprite):Null<BitmapData> {
		try {
			if (!spr.useFramePixels) spr.useFramePixels = true;
			spr.drawFrame(true);
			final bmp:BitmapData = spr.updateFramePixels();
			if (bmp != null) return bmp;
		} catch (e:Dynamic) {
			trace('[Thor] framePixels failed: $e');
		}
		return spr.pixels; // full atlas as last resort
	}

	static inline function getFrameKey(spr:FlxSprite):String {
		final anim = spr.animation != null ? spr.animation.curAnim : null;
		final idx:Int = anim != null ? anim.curFrame : 0;
		return '${idx}_${spr.flipX}_${spr.flipY}_${(spr.color : Int)}';
	}

	static inline function alignString(a:FlxTextAlign):String {
		return Std.string(a).toLowerCase();
	}

	static function encodeMenuDesat():Null<String> {
		try {
			final spr:FlxSprite = new FlxSprite();
			spr.loadGraphic(Paths.image('menuDesat'));
			final bmp:BitmapData = spr.pixels;
			return bmp != null ? encodeBitmap(bmp) : null;
		} catch (e:Dynamic) {
			trace('[Thor] menuDesat load failed: $e');
			return null;
		}
	}

	static inline function encodeBitmap(bmp:BitmapData):String {
		final ba:ByteArray = bmp.encode(bmp.rect, new PNGEncoderOptions(true));
		// openfl.utils.ByteArray is an abstract over ByteArrayData, which extends
		// haxe.io.Bytes on cpp; the @:to conversion makes this assignment valid.
		final bytes:haxe.io.Bytes = ba;
		return Base64.encode(bytes);
	}
}

#else

class ThorScreen {
	public static final BOTTOM_W:Int = 1240;
	public static final BOTTOM_H:Int = 1080;
	public static function start():Void {}
	public static function stop():Void {}
	public static function tick():Void {}
}

#end
