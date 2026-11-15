/*
 * Haxe side of the Thor dual-screen bridge. DIAGNOSTIC BUILD (stage 5).
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
 *      dropped while Presentation.onCreate() was still running on the UI thread.
 *   3. isActive() no longer hard-aborts tick(); init() is retried periodically.
 *   4. ENTER_FRAME is bound to Lib.current.stage when available.
 *
 * Stage 3 - Lua objects not appearing:
 *   1. Java no longer hides the object layer / object Views based on `menu`.
 *   2. Each sprite's image encode is wrapped individually; the whole sync /
 *      Json.stringify / JNI block is try/catch protected and carries `stats`.
 *   3. _frameCache is cleared whenever the background is re-pushed (3s), so a
 *      recreated Presentation cannot leave permanently blank ImageViews.
 *   4. SELF_TEST injects one synthetic luatext bypassing Lua and camBottom.
 *
 * Stage 4 - onBottom=0 on the real device:
 *   FORCE_BY_TAG / MIRROR_ALL_IF_NONE put modchart objects on camBottom from
 *   Haxe, so the lower screen works even if LuaUtils.cameraFromString('bottom')
 *   is missing from the built binary.
 *
 * Stage 5 - sprites still blank, probe reported:
 *   "sprites=2 texts=2 onBottom=4 byTag=4 pngOk=0 pngErr=0 len=1202
 *    cams=bottomChar=null bottomPanel=null bottomScore=null bottomTitle=null"
 *
 *   THREE independent defects, all found from that one line:
 *
 *   (a) BitmapData.encode() produced NO bytes for the sprites - exactly the
 *       same hardware-render failure that caused the stage-1 black screen.
 *       len=1202 means not one PNG byte reached Java. Sprites MUST use the
 *       same raw-Assets.getBytes() route as the background. This build sends
 *       the whole atlas PNG once, plus a frame rectangle every tick; Java
 *       decodes the atlas once and crops Bitmap.createBitmap() per frame.
 *       The legacy encode() path is kept only as a fallback.
 *
 *   (b) .cameras was [null], not [camBottom]. LuaUtils.cameraFromString()
 *       returned null for 'bottom' in the local build. This build repairs the
 *       cameras array for EVERY mirrored object and reports camFixed.
 *
 *   (c) onCam was counted with `else if (tagMatchesBottom(...))`, so objects
 *       with bottom* tags could NEVER increment onCam. Fixed to independent
 *       counters, so the probe now proves whether the forced camera stuck.
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
	 *   green "THOR OBJECT LAYER OK" visible -> Haxe->JNI->Java View chain is fine;
	 *   NOT visible -> the fault is in syncObjects / payload / Java object layer.
	 * Set to false once verified.
	 */
	static final SELF_TEST:Bool = true;
	static final SELF_TEST_TAG:String = '__thor_selftest__';

	/**
	 * STAGE 4. Make the lower screen work WITHOUT relying on
	 * LuaUtils.cameraFromString('bottom') being present in the built binary.
	 *  FORCE_BY_TAG: bottom*/ds_*/thor_* tags are assigned .cameras=[camBottom]
	 *    directly from Haxe. camBottom.flashSprite is hidden, so they show ONLY
	 *    on the lower screen.
	 *  MIRROR_ALL_IF_NONE: if nothing reached camBottom, mirror every modchart
	 *    object anyway (COPY only - .cameras untouched, main screen unaffected).
	 */
	static final BOTTOM_TAG_PREFIXES:Array<String> = ['bottom', 'ds_', 'thor_'];
	static final FORCE_BY_TAG:Bool = true;
	static final MIRROR_ALL_IF_NONE:Bool = true;

	/**
	 * STAGE 5. Send sprite images as RAW packaged PNG bytes, exactly like the
	 * background. BitmapData.encode() silently returns nothing on Android
	 * hardware/tile render. Set false only to test the legacy encode() path.
	 */
	static final USE_RAW_ATLAS:Bool = true;

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

	/** tag -> last frame key, so animated sprites only re-crop when the frame changes. */
	static var _frameCache:StringMap<String> = new StringMap<String>();
	/** tag -> 'RAW' (atlas delivered) or 'MISS' (no raw asset found, use encode fallback). */
	static var _atlasCache:StringMap<String> = new StringMap<String>();
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
		trace('[Thor] menuDesat base64 length=$pngLen luaAllowed=${hasLua()} selfTest=$SELF_TEST rawAtlas=$USE_RAW_ATLAS');
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
		_atlasCache = new StringMap<String>();
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
		// `menu`, so a wrong guess here cannot blank out every Lua object.
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
			onCam: 0,
			byTag: 0,
			catchAll: false,
			camFixed: 0,
			rawOk: 0,
			rawMiss: 0,
			rectOk: 0,
			pngOk: 0,
			pngErr: 0,
			cams: '',
			src: '',
			err: ''
		};
		final payload:Dynamic = {menu: !inPlay, objects: [], remove: [], stats: stats};

		// Re-push the background periodically. A one-shot send can be lost while
		// Presentation.onCreate() is still running on the UI thread.
		if (_menuPng != null && now - _lastBgPush > BG_REPUSH_MS) {
			payload.bg = _menuPng;
			_lastBgPush = now;
			// Force a full re-delivery of every sprite atlas on this tick. If the
			// Presentation was recreated, Java cleared its decoded atlas cache
			// while our cache still says "already sent" -> permanently blank.
			_frameCache = new StringMap<String>();
			_atlasCache = new StringMap<String>();
		}

		if (!inPlay) {
			// Every state except PlayState: static MenuDesat background, no object layer.
			for (tag in _seen.keys()) payload.remove.push(tag);
			_seen = new StringMap<Bool>();
			_frameCache = new StringMap<String>();
			_atlasCache = new StringMap<String>();
		} else {
			// A single bad sprite must NOT abort the whole tick: otherwise no
			// update() reaches Java at all and the lower screen freezes.
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
				trace('[Thor] tick inPlay=$inPlay state=${stats.state} lua=${stats.lua} camBottom=${stats.camBottom} sprites=${stats.sprites} texts=${stats.texts} onCam=${stats.onCam} byTag=${stats.byTag} camFixed=${stats.camFixed} onBottom=${stats.onBottom} rawOk=${stats.rawOk} rawMiss=${stats.rawMiss} rectOk=${stats.rectOk} pngOk=${stats.pngOk} pngErr=${stats.pngErr} objs=${payload.objects.length} jsonLen=${json.length} cams=${stats.cams} src=${stats.src} err=${stats.err}');
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
	 * took one argument, which failed the next Haxe compile.
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
		var nOnCam:Int = 0;
		var nByTag:Int = 0;
		var nCamFixed:Int = 0;
		var nRawOk:Int = 0;
		var nRawMiss:Int = 0;
		var nRectOk:Int = 0;
		var nPngOk:Int = 0;
		var nPngErr:Int = 0;
		var catchAll:Bool = false;
		final dump:Array<String> = [];
		final srcDump:Array<String> = [];

		#if LUA_ALLOWED
		// Pass 1: count every Lua object and dump the camera each one is on.
		// STAGE 5: onCam and byTag are INDEPENDENT counters now. The old
		// `else if` made bottom* tags unable to ever increment onCam, so the
		// probe falsely reported onCam=0 even after the camera was repaired.
		try {
			for (tag => spr in ps.modchartSprites) {
				nSprites++;
				if (spr == null) continue;
				if (dump.length < 6) dump.push('$tag=${cameraLabel(spr, cam)}');
				if (cam == null) continue;
				if (isOnBottom(spr, cam)) nOnCam++;
				if (tagMatchesBottom(tag)) nByTag++;
			}
			for (tag => txt in ps.modchartTexts) {
				nTexts++;
				if (txt == null) continue;
				if (dump.length < 6) dump.push('$tag=${cameraLabel(txt, cam)}');
				if (cam == null) continue;
				if (isOnBottom(txt, cam)) nOnCam++;
				if (tagMatchesBottom(tag)) nByTag++;
			}
		} catch (e:Dynamic) {
			stats.err = 'map scan: $e';
		}
		stats.cams = dump.join(' ');

		// Last-resort diagnostic: when NOTHING reached camBottom by either
		// route, mirror every modchart object anyway. Copy only: .cameras is
		// left alone so the main screen keeps working and gameplay is unaffected.
		catchAll = MIRROR_ALL_IF_NONE && cam != null && nOnCam == 0 && nByTag == 0
			&& (nSprites + nTexts) > 0;
		stats.catchAll = catchAll;

		if (cam != null) {
			for (tag => spr in ps.modchartSprites) {
				if (spr == null) continue;
				final onCamNow:Bool = isOnBottom(spr, cam);
				final byTag:Bool = tagMatchesBottom(tag);
				if (!onCamNow && !byTag && !catchAll) continue;

				// STAGE 5(b): LuaUtils.cameraFromString('bottom') returned null in
				// the local build, leaving .cameras == [null]. Repair it for EVERY
				// mirrored object, not just byTag ones. If a Lua onUpdate keeps
				// re-poisoning it, camFixed keeps climbing and the probe shows it.
				if (camerasBroken(spr)) {
					try {
						spr.cameras = [cam];
						nCamFixed++;
					} catch (e:Dynamic) {
						stats.err = 'fix cam $tag: $e';
					}
				} else if (byTag && !onCamNow && FORCE_BY_TAG) {
					try { spr.cameras = [cam]; } catch (e:Dynamic) {}
				}

				current.set(tag, true);
				nOnBottom++;

				var atlas:Null<String> = null;
				var png:Null<String> = null;
				var rect:Dynamic = null;
				var srcLabel:String = 'NONE';
				try {
					final frameKey:String = getFrameKey(spr);
					final needAtlas:Bool = !_atlasCache.exists(tag);
					final needFrame:Bool = needAtlas || _frameCache.get(tag) != frameKey;

					// STAGE 5(a): primary image source = raw packaged PNG bytes.
					// The whole atlas is sent ONCE per tag (and re-sent on the 3s
					// background repush); Java decodes it once and caches it.
					if (needAtlas && USE_RAW_ATLAS) {
						final raw:Null<String> = readRawAtlas(spr);
						if (raw != null && raw.length > 0) {
							atlas = raw;
							_atlasCache.set(tag, 'RAW');
							nRawOk++;
						} else {
							_atlasCache.set(tag, 'MISS');
							nRawMiss++;
						}
					}

					// Frame rectangle is tiny, so send it every tick. Java crops
					// only when the rect changes; this is what makes animated
					// sprites work without re-encoding a PNG per frame.
					rect = frameRect(spr);
					if (rect != null) nRectOk++;

					// Legacy encode() path, only when no raw atlas is available.
					if (atlas == null && _atlasCache.get(tag) != 'RAW' && needFrame) {
						final bmp:Null<BitmapData> = getFrameBitmap(spr);
						if (bmp != null) {
							png = encodeBitmap(bmp);
							if (png != null && png.length > 0) nPngOk++;
						}
					}

					_frameCache.set(tag, frameKey);
					srcLabel = atlas != null ? 'RAW' : (_atlasCache.get(tag) == 'RAW' ? 'CROP' : 'ENC');
					if (srcDump.length < 8) srcDump.push('$tag=$srcLabel');
				} catch (e:Dynamic) {
					nPngErr++;
					stats.err = 'img $tag: $e';
					trace('[Thor] sprite image failed for $tag: $e');
				}

				// Push the transform even when the image failed. Java now gives
				// the ImageView explicit w/h, so the magenta placeholder is
				// visible instead of being a 0x0 WRAP_CONTENT view.
				try {
					payload.objects.push({
						tag: tag,
						type: 'sprite',
						atlas: atlas,
						fx: rect != null ? rect.fx : -1,
						fy: rect != null ? rect.fy : -1,
						fw: rect != null ? rect.fw : -1,
						fh: rect != null ? rect.fh : -1,
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
				final onCamNow:Bool = isOnBottom(txt, cam);
				final byTag:Bool = tagMatchesBottom(tag);
				if (!onCamNow && !byTag && !catchAll) continue;

				if (camerasBroken(txt)) {
					try {
						txt.cameras = [cam];
						nCamFixed++;
					} catch (e:Dynamic) {
						stats.err = 'fix cam $tag: $e';
					}
				} else if (byTag && !onCamNow && FORCE_BY_TAG) {
					try { txt.cameras = [cam]; } catch (e:Dynamic) {}
				}

				current.set(tag, true);
				nOnBottom++;
				var txtH:Float = 0;
				try { txtH = txt.height; } catch (e:Dynamic) {}
				try {
					payload.objects.push({
						tag: tag,
						type: 'text',
						text: txt.text,
						x: txt.x,
						y: txt.y,
						w: txt.fieldWidth,
						h: txtH,
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
				h: 40,
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
		stats.onCam = nOnCam;
		stats.byTag = nByTag;
		stats.camFixed = nCamFixed;
		stats.rawOk = nRawOk;
		stats.rawMiss = nRawMiss;
		stats.rectOk = nRectOk;
		stats.pngOk = nPngOk;
		stats.pngErr = nPngErr;
		stats.src = srcDump.join(' ');

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

	/** Case-insensitive tag-prefix test. Uses indexOf so no StringTools import is needed. */
	static function tagMatchesBottom(tag:String):Bool {
		if (tag == null) return false;
		final t:String = tag.toLowerCase();
		for (p in BOTTOM_TAG_PREFIXES) if (t.indexOf(p) == 0) return true;
		return false;
	}

	/** null / empty / [null] cameras arrays are all broken and must be repaired. */
	static function camerasBroken(obj:Dynamic):Bool {
		try {
			final cams:Array<FlxCamera> = obj.cameras;
			if (cams == null || cams.length == 0) return true;
			for (c in cams) if (c == null) return true;
		} catch (e:Dynamic) {
			return true;
		}
		return false;
	}

	/**
	 * Human-readable camera assignment for the probe overlay. Dimensions are
	 * enough to tell the cameras apart: camBottom is 1240x1080 (marked with *),
	 * every main-screen camera is 1280x720. "null" here means the array was
	 * null or contained a null element (stage-5 root cause (b)).
	 */
	static function cameraLabel(obj:Dynamic, cam:Null<FlxCamera>):String {
		try {
			final cams:Array<FlxCamera> = obj.cameras;
			if (cams == null) return 'null';
			if (cams.length == 0) return '[]';
			final parts:Array<String> = [];
			for (c in cams) {
				if (c == null) {
					parts.push('null');
					continue;
				}
				parts.push('${c.width}x${c.height}' + (c == cam ? '*' : ''));
			}
			return parts.join('+');
		} catch (e:Dynamic) {
			return 'ERR';
		}
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
	// return" for inline functions containing early returns. These helpers run
	// at 20 Hz, so losing the inline hint has no measurable cost.
	static function isOnBottom(obj:Dynamic, cam:FlxCamera):Bool {
		try {
			final cams:Array<FlxCamera> = obj.cameras;
			if (cams == null) return false;
			for (c in cams) if (c == cam) return true;
		} catch (e:Dynamic) {
			return false;
		}
		return false;
	}

	/**
	 * STAGE 5: resolve the ORIGINAL packaged PNG for a sprite's FlxGraphic,
	 * the same way loadMenuDesatPng() does. FlxGraphic.key is often prefixed by
	 * Polymod ("shared:shared/images/...png"), so several candidate OpenFL
	 * asset ids are tried. Reflect is used to stay compatible across flixel
	 * versions without compile-time field dependencies.
	 */
	static function readRawAtlas(spr:FlxSprite):Null<String> {
		try {
			final g:Dynamic = spr.graphic;
			if (g == null) return null;
			final key:String = Std.string(Reflect.field(g, 'key'));
			for (p in assetCandidates(key)) {
				try {
					final ba = Assets.getBytes(p);
					if (ba != null && ba.length > 0) {
						final bytes:haxe.io.Bytes = ba;
						trace('[Thor] raw atlas for $key from $p (${ba.length} bytes)');
						return Base64.encode(bytes);
					}
				} catch (e:Dynamic) {}
			}
			trace('[Thor] no raw atlas asset for $key');
		} catch (e:Dynamic) {
			trace('[Thor] readRawAtlas failed: $e');
		}
		return null;
	}

	/** Build de-duplicated OpenFL asset id candidates from a FlxGraphic key. */
	static function assetCandidates(rawKey:Null<String>):Array<String> {
		final out:Array<String> = [];
		if (rawKey == null) return out;
		var k:String = rawKey;
		// Strip Polymod's "library:path" prefix, but keep a colon that belongs
		// to the path itself. The .png test keeps this conservative.
		final colon:Int = k.lastIndexOf(':');
		if (colon >= 0 && k.indexOf('.png') > colon) k = k.substr(colon + 1);
		final pngIdx:Int = k.toLowerCase().lastIndexOf('.png');
		if (pngIdx < 0) return out;
		k = k.substr(0, pngIdx + 4);
		if (k.indexOf('/') >= 0) {
			final file:String = k.substr(k.lastIndexOf('/') + 1);
			pushUnique(out, k);
			pushUnique(out, 'assets/' + k);
			pushUnique(out, 'images/' + file);
			pushUnique(out, 'shared/images/' + file);
			pushUnique(out, 'assets/shared/images/' + file);
			pushUnique(out, 'assets/images/' + file);
		} else {
			pushUnique(out, 'images/' + k);
			pushUnique(out, 'shared/images/' + k);
			pushUnique(out, 'assets/shared/images/' + k);
			pushUnique(out, k);
		}
		return out;
	}

	static function pushUnique(arr:Array<String>, s:String):Void {
		if (s == null || s.length == 0) return;
		for (a in arr) if (a == s) return;
		arr.push(s);
	}

	/**
	 * Current frame rectangle inside the atlas, in source-image pixels.
	 * Java crops Bitmap.createBitmap(atlas, fx, fy, fw, fh) from the cached
	 * full bitmap, which replaces the broken BitmapData.encode() path.
	 */
	static function frameRect(spr:FlxSprite):Dynamic {
		try {
			final fr:Dynamic = Reflect.field(spr, 'frame');
			if (fr == null) return null;
			final r:Dynamic = Reflect.field(fr, 'frame');
			if (r == null) return null;
			final fw:Int = Math.round(r.width);
			final fh:Int = Math.round(r.height);
			if (fw <= 0 || fh <= 0) return null;
			return {
				fx: Math.round(r.x),
				fy: Math.round(r.y),
				fw: fw,
				fh: fh
			};
		} catch (e:Dynamic) {
			return null;
		}
	}

	/**
	 * Legacy fallback only. In tile render mode useFramePixels defaults to false,
	 * so force it on and refresh the current animation frame before reading.
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
	 * was one of the silent black-screen causes.
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
