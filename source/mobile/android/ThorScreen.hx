/*
 * Haxe side of the Thor dual-screen bridge. DIAGNOSTIC BUILD (stage 3).
 *
 * Design note:
 *   An Android Presentation is a Dialog with its OWN View hierarchy, not an
 *   OpenFL Stage, so a FlxCamera cannot be attached to it. On Android this engine
 *   runs FlxG.renderTile (hardware), where FlxCamera has no BitmapData buffer.
 *   Instead camBottom stays a REAL FlxCamera (so every Psych Lua function works),
 *   its flashSprite is hidden, and every 50ms we mirror the LIVE state of the
 *   objects assigned to camBottom into native Android Views via one JNI call.
 *
 * Stage 1 - black screen:
 *   1. The background is sent from the RAW packaged PNG bytes (Assets.getBytes),
 *      not from BitmapData.encode(), which is unreliable in hardware render mode.
 *   2. The background is re-pushed every 3s. Previously a one-shot send could be
 *      dropped while Presentation.onCreate() was still running on the UI thread,
 *      leaving a permanently black lower screen with no error anywhere.
 *   3. isActive() no longer hard-aborts tick(); init() is retried periodically.
 *   4. ENTER_FRAME is bound to Lib.current.stage when available.
 *
 * Stage 3 - Lua objects not appearing (this build):
 *   1. Java no longer hides the object layer / object Views based on `menu`.
 *      A wrong inPlay guess used to blank out EVERY Lua object with no error.
 *   2. Each sprite's PNG encode is wrapped individually. Previously one bad
 *      bmp.encode() aborted the whole tick BEFORE _updateJNI(), so no update()
 *      reached Java at all and the lower screen kept showing only MenuDesat.
 *   3. The whole sync / Json.stringify / JNI block is try/catch protected and
 *      carries a `stats` object that Java prints on its diagnostic overlay.
 *   4. _frameCache is cleared whenever the background is re-pushed (every 3s),
 *      forcing a full PNG re-encode. This self-heals when the Presentation is
 *      recreated: Java's objectViews map is cleared but our frame cache still
 *      believed the PNG had already been delivered -> permanently blank ImageViews.
 *   5. SELF_TEST injects one synthetic luatext that bypasses Lua and camBottom.
 *
 * Java side has a matching DIAGNOSTICS overlay: set DIAGNOSTICS=false in
 * ThorPresentation.java, and SELF_TEST=false here, once everything is confirmed.
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

	/**
	 * Diagnostic self-test: injects ONE synthetic text object onto the lower
	 * screen during PlayState, bypassing Lua and camBottom completely.
	 *   green "THOR OBJECT LAYER OK" visible -> Haxe->JNI->Java View chain is fine,
	 *        so the fault is in Lua object creation / camera assignment;
	 *   NOT visible -> the fault is in syncObjects / payload / Java object layer.
	 * Set to false once verified.
	 */
	static final SELF_TEST:Bool = true;
	static final SELF_TEST_TAG:String = '__thor_selftest__';

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
		trace('[Thor] menuDesat base64 length=$pngLen luaAllowed=${hasLua()} selfTest=$SELF_TEST');
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

		// Keep inPlay permissive. Java no longer hides the object layer based on
		// `menu`, so a wrong guess here cannot blank out every Lua object. The
		// real value is reported as stats.inPlay on the lower screen.
		final ps:Null<PlayState> = PlayState.instance;
		final inPlay:Bool = ps != null && (Std.isOfType(FlxG.state, PlayState) || ps.camBottom != null);
		final stats:Dynamic = {
			inPlay: inPlay,
			state: stateName(),
			ps: ps != null,
			lua: hasLua(),
			camBottom: false,
			camInList: false,
			sprites: 0,
			texts: 0,
			onBottom: 0,
			pngOk: 0,
			pngErr: 0,
			err: ''
		};
		final payload:Dynamic = {menu: !inPlay, objects: [], remove: [], stats: stats};

		// Re-push the background periodically. A one-shot send can be lost while
		// Presentation.onCreate() is still running on the UI thread.
		if (_menuPng != null && now - _lastBgPush > BG_REPUSH_MS) {
			payload.bg = _menuPng;
			_lastBgPush = now;
			// Force a full sprite PNG re-encode on this tick. If the Presentation
			// was recreated, Java cleared objectViews while our cache still says
			// "already sent", leaving permanently blank ImageViews otherwise.
			_frameCache = new StringMap<String>();
		}

		if (!inPlay) {
			// Every state except PlayState: static MenuDesat background, no object layer.
			for (tag in _seen.keys()) payload.remove.push(tag);
			_seen = new StringMap<Bool>();
			_frameCache = new StringMap<String>();
		} else {
			// A single bad sprite must NOT abort the whole tick: otherwise no
			// update() reaches Java at all and the lower screen shows only the
			// background + a frozen diagnostic overlay.
			try {
				syncObjects(payload, stats);
			} catch (e:Dynamic) {
				stats.err = 'sync: $e';
				trace('[Thor] syncObjects exception: $e');
			}
		}

		try {
			final json:String = Json.stringify(payload);
			_updateJNI(json);
			if (now - _lastLog > LOG_MS) {
				_lastLog = now;
				trace('[Thor] tick inPlay=$inPlay state=${stats.state} lua=${stats.lua} camBottom=${stats.camBottom} sprites=${stats.sprites} texts=${stats.texts} onBottom=${stats.onBottom} pngOk=${stats.pngOk} pngErr=${stats.pngErr} objs=${payload.objects.length} jsonLen=${json.length} err=${stats.err}');
			}
		} catch (e:Dynamic) {
			trace('[Thor] Json.stringify/JNI failed: $e');
			try {
				_updateJNI('{"menu":false,"objects":[],"remove":[],"stats":{"inPlay":true,"lua":false,"camBottom":false,"sprites":0,"texts":0,"onBottom":0,"pngErr":1,"err":"hx json failed"}}');
			} catch (e2:Dynamic) {}
		}
	}

	/**
	 * Signature MUST match the two-argument call in tick(). The previous build
	 * had tick() calling syncObjects(payload, stats) while this function still
	 * took one argument, which would fail the next Haxe compile.
	 */
	static function syncObjects(payload:Dynamic, stats:Dynamic):Void {
		final ps:PlayState = PlayState.instance;
		if (ps == null) {
			stats.err = 'PlayState.instance is null';
			return;
		}

		final cam:Null<FlxCamera> = ps.camBottom;
		stats.camBottom = cam != null;
		if (cam != null) {
			try {
				for (c in FlxG.cameras.list) {
					if (c == cam) {
						stats.camInList = true;
						break;
					}
				}
			} catch (e:Dynamic) {}
		}

		final current:StringMap<Bool> = new StringMap<Bool>();
		// Local Int counters (not Dynamic arithmetic) so this compiles cleanly on
		// every hxcpp target and survives an exception mid-scan.
		var nSprites:Int = 0;
		var nTexts:Int = 0;
		var nOnBottom:Int = 0;
		var nPngOk:Int = 0;
		var nPngErr:Int = 0;

		#if LUA_ALLOWED
		// Count EVERY Lua object before filtering by camera. This is what lets
		// the probe distinguish "Lua created nothing" from "objects exist but
		// are on the wrong camera" / "camBottom was null at setObjectCamera time".
		try {
			for (tag in ps.modchartSprites.keys()) nSprites++;
			for (tag in ps.modchartTexts.keys()) nTexts++;
		} catch (e:Dynamic) {
			stats.err = 'map scan: $e';
		}

		if (cam != null) {
			for (tag => spr in ps.modchartSprites) {
				if (spr == null) continue;
				if (!isOnBottom(spr, cam)) continue;
				current.set(tag, true);
				nOnBottom++;

				var png:Null<String> = null;
				try {
					final frameKey:String = getFrameKey(spr);
					if (_frameCache.get(tag) != frameKey) {
						final bmp:Null<BitmapData> = getFrameBitmap(spr);
						if (bmp != null) {
							png = encodeBitmap(bmp);
							_frameCache.set(tag, frameKey);
							if (png != null && png.length > 0) nPngOk++;
						}
					}
				} catch (e:Dynamic) {
					nPngErr++;
					stats.err = 'png $tag: $e';
					trace('[Thor] sprite PNG failed for $tag: $e');
				}

				// Push the transform even when the PNG failed. Java will create
				// the ImageView anyway (magenta placeholder in diagnostic mode),
				// which is a far better failure mode than nothing at all.
				try {
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
				} catch (e:Dynamic) {
					stats.err = 'sprite state $tag: $e';
				}
			}

			for (tag => txt in ps.modchartTexts) {
				if (txt == null) continue;
				if (!isOnBottom(txt, cam)) continue;
				current.set(tag, true);
				nOnBottom++;
				try {
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
				} catch (e:Dynamic) {
					stats.err = 'text state $tag: $e';
				}
			}
		}
		#else
		stats.err = 'LUA_ALLOWED is not defined for this target';
		#end

		if (SELF_TEST) {
			current.set(SELF_TEST_TAG, true);
			payload.objects.push({
				tag: SELF_TEST_TAG,
				type: 'text',
				text: 'THOR OBJECT LAYER OK (Haxe self test)',
				x: 40,
				y: 980,
				w: 1160,
				size: 26,
				color: 0xFF00FF00,
				align: 'left',
				sx: 1,
				sy: 1,
				angle: 0,
				alpha: 1,
				visible: true
			});
		}

		stats.sprites = nSprites;
		stats.texts = nTexts;
		stats.onBottom = nOnBottom;
		stats.pngOk = nPngOk;
		stats.pngErr = nPngErr;

		for (tag in _seen.keys()) if (!current.exists(tag)) payload.remove.push(tag);
		_seen = current;
	}

	static function hasLua():Bool {
		#if LUA_ALLOWED
		return true;
		#else
		return false;
		#end
	}

	static function stateName():String {
		try {
			final s = FlxG.state;
			if (s == null) return 'null';
			final c = Type.getClass(s);
			return c != null ? Type.getClassName(c) : Std.string(s);
		} catch (e:Dynamic) {
			return 'err:$e';
		}
	}

	// NOTE: deliberately NOT `inline`. Haxe rejects "Cannot inline a not final
	// return" for inline functions containing early returns (the `cams == null`
	// guard and the `return true` inside the loop). These helpers run at 20 Hz,
	// so losing the inline hint has no measurable cost.
	static function isOnBottom(obj:Dynamic, cam:FlxCamera):Bool {
		try {
			final cams:Array<FlxCamera> = obj.cameras;
			if (cams == null) return false;
			for (c in cams) if (c == cam) return true;
		} catch (e:Dynamic) {
			// A mod may have replaced .cameras with something unexpected. Never
			// let that abort the whole tick.
			return false;
		}
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
		if (ba == null || ba.length == 0) return '';
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
