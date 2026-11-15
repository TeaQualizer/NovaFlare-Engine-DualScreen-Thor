/*
 * 拼尽全力无法战胜副屏JNI，几乎没有在haxe里面搞这个的，溜溜梅透明胶带捆钢管来的
 *
 * Haxe side of the Thor dual-screen bridge. DIAGNOSTIC BUILD.
 *
 * Design note:
 *   An Android Presentation is a Dialog with its OWN View hierarchy, not an
 *   OpenFL Stage, so a FlxCamera cannot be attached to it. On Android this engine
 *   runs FlxG.renderTile (hardware), where FlxCamera has no BitmapData buffer.
 *   Instead camBottom stays a REAL FlxCamera (so every Psych Lua function works),
 *   its flashSprite is hidden, and every 50ms we mirror the LIVE state of the
 *   objects assigned to camBottom into native Android Views via one JNI call.
 *
 * 黑屏修复这块，单次推送图片貌似行不通，试试看bitmapdata
 *   1. The background is sent from the RAW packaged PNG bytes (Assets.getBytes),
 *      not from BitmapData.encode(), which is unreliable in hardware render mode.
 *   2. The background is re-pushed every 3s. Previously a one-shot send could be
 *      dropped while Presentation.onCreate() was still running on the UI thread,
 *      leaving a permanently black lower screen with no error anywhere.
 *   3. isActive() no longer hard-aborts tick(); init() is retried periodically.
 *   4. ENTER_FRAME is bound to Lib.current.stage when available.
 *   5. trace() heartbeat every 5s so the in-game debug console shows the chain.
 *
 * Java side has a matching DIAGNOSTICS overlay: set DIAGNOSTICS=false in
 * ThorPresentation.java once the lower screen is confirmed working.
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
import openfl.utils.Assets;
import openfl.utils.ByteArray;

class ThorScreen {
	/** Virtual coordinate space of the lower screen (3.92" 1240x1080). */
	public static final BOTTOM_W:Int = 1240;
	public static final BOTTOM_H:Int = 1080;

	/** Mirror tick. 20 Hz is plenty for a 60 Hz lower panel and keeps JNI/PNG cost low. */
	static final TICK_MS:Int = 50;
	/** Re-send the background periodically; Java de-duplicates by content key. */
	static final BG_REPUSH_MS:Int = 3000;
	static final INIT_RETRY_MS:Int = 2000;
	static final LOG_MS:Int = 5000;

	static var _initJNI:Null<Dynamic> = null;
	static var _updateJNI:Null<Dynamic> = null;
	static var _isActiveJNI:Null<Dynamic> = null;
	static var _dismissJNI:Null<Dynamic> = null;

	static var _started:Bool = false;
	static var _lastTick:Int = 0;
	static var _lastBgPush:Int = 0;
	static var _lastInitRetry:Int = 0;
	static var _lastLog:Int = 0;
	static var _menuPng:Null<String> = null;
	static var _frameTarget:Null<Dynamic> = null;

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

		final okInit:Bool = _initJNI != null;
		final okUpdate:Bool = _updateJNI != null;
		final okActive:Bool = _isActiveJNI != null;
		trace('[Thor] start: initJNI=$okInit updateJNI=$okUpdate isActiveJNI=$okActive');
		if (_initJNI == null || _updateJNI == null) {
			trace('[Thor] ThorPresentation Java class not found; dual screen disabled.');
			_started = false;
			return;
		}

		_initJNI();
		_menuPng = loadMenuDesatPng();
		final pngLen:Int = _menuPng != null ? _menuPng.length : 0;
		trace('[Thor] menuDesat base64 length=$pngLen');
		if (_menuPng == null)
			trace('[Thor] WARNING: no background PNG available; lower screen will show the Java diagnostic overlay only.');

		_lastTick = Lib.getTimer();
		_lastBgPush = 0;
		_lastInitRetry = _lastTick;
		_lastLog = 0;

		final st = Lib.current.stage;
		_frameTarget = st != null ? st : Lib.current;
		_frameTarget.addEventListener(Event.ENTER_FRAME, onEnterFrame);
		trace('[Thor] ENTER_FRAME bound to ' + (st != null ? 'stage' : 'Lib.current'));
	}

	public static function stop():Void {
		if (!_started) return;
		if (_frameTarget != null) _frameTarget.removeEventListener(Event.ENTER_FRAME, onEnterFrame);
		_frameTarget = null;
		if (_dismissJNI != null) _dismissJNI();
		_started = false;
		_lastBgPush = 0;
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
		final now:Int = Lib.getTimer();

		// Do NOT hard-return when isActive() is false. That silently killed every
		// tick in the previous build. Retry init() and keep pushing; Java drops
		// harmlessly when root == null and shows the reason on its probe overlay.
		if (_isActiveJNI != null && !_isActiveJNI()) {
			if (now - _lastInitRetry > INIT_RETRY_MS) {
				_lastInitRetry = now;
				if (_initJNI != null) _initJNI();
				trace('[Thor] presentation inactive, retrying init()');
			}
		}

		final inPlay:Bool = PlayState.instance != null && Std.isOfType(FlxG.state, PlayState);
		final payload:Dynamic = {menu: !inPlay, objects: [], remove: []};

		// Re-push the background periodically. A one-shot send can be lost while
		// Presentation.onCreate() is still running on the UI thread.
		if (_menuPng != null && now - _lastBgPush > BG_REPUSH_MS) {
			payload.bg = _menuPng;
			_lastBgPush = now;
		}

		if (!inPlay) {
			// Every state except PlayState: static MenuDesat background, no object layer.
			for (tag in _seen.keys()) payload.remove.push(tag);
			_seen = new StringMap<Bool>();
			_frameCache = new StringMap<String>();
		} else {
			syncObjects(payload);
		}

		final json:String = Json.stringify(payload);
		_updateJNI(json);

		if (now - _lastLog > LOG_MS) {
			_lastLog = now;
			final hasBg:Bool = payload.bg != null;
			trace('[Thor] tick inPlay=$inPlay jsonLen=${json.length} bg=$hasBg objects=${payload.objects.length}');
		}
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

	// NOTE: deliberately NOT `inline`. Haxe rejects "Cannot inline a not final
	// return" for inline functions containing early returns (the `cams == null`
	// guard and the `return true` inside the loop). These helpers run at 20 Hz,
	// so losing the inline hint has no measurable cost.
	static function isOnBottom(obj:Dynamic, cam:FlxCamera):Bool {
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

	static function getFrameKey(spr:FlxSprite):String {
		final anim = spr.animation != null ? spr.animation.curAnim : null;
		final idx:Int = anim != null ? anim.curFrame : 0;
		return '${idx}_${spr.flipX}_${spr.flipY}_${(spr.color : Int)}';
	}

	static function alignString(a:FlxTextAlign):String {
		return Std.string(a).toLowerCase();
	}

	/**
	 * Prefer the RAW packaged PNG bytes. BitmapData.encode() re-encodes through a
	 * CPU-side image buffer that may not exist in hardware/tile render mode, which
	 * was one of the silent black-screen causes. No image processing needed here:
	 * Java's BitmapFactory can decode the original bytes directly.
	 */
	static function loadMenuDesatPng():Null<String> {
		final candidates:Array<String> = [
			'shared/images/menuDesat.png',
			'assets/shared/images/menuDesat.png',
			'images/menuDesat.png'
		];
		for (p in candidates) {
			try {
				final ba = Assets.getBytes(p);
				if (ba != null && ba.length > 0) {
					final bytes:haxe.io.Bytes = ba;
					trace('[Thor] menuDesat raw bytes from $p (${ba.length} bytes)');
					return Base64.encode(bytes);
				}
			} catch (e:Dynamic) {
				trace('[Thor] Assets.getBytes($p) failed: $e');
			}
		}

		// Fallback: Polymod-aware Paths.image(), then re-encode the BitmapData.
		try {
			final spr:FlxSprite = new FlxSprite();
			spr.loadGraphic(Paths.image('menuDesat'));
			final bmp:BitmapData = spr.pixels;
			if (bmp != null) {
				trace('[Thor] menuDesat via Paths.image() fallback');
				return encodeBitmap(bmp);
			}
		} catch (e:Dynamic) {
			trace('[Thor] Paths.image() fallback failed: $e');
		}
		return null;
	}

	static function encodeBitmap(bmp:BitmapData):String {
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
