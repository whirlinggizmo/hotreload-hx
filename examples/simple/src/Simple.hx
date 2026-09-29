/**
	hotreload's simple: the reloaded class, wgrender-hx's simple example (a port of
	wgrender's examples/simple.c) as it is there, with its state kept across reloads.
	Edit it while it runs (the message, the colours, how the sprite bobs) and save.

	Scene: an animated model, a bobbing 3D sprite, looping music, two TTF fonts, a
	centered message that reports what the mouse is over (scene picking), and a debug
	overlay with timers, mouse state and the platform name.
**/
import wgr.*;

class Simple {
	static inline final DEBUG_FONT_PATH = "fonts/JetBrainsMono/JetBrainsMono-Regular.ttf";
	static inline final KOMIKA_FONT_PATH = "fonts/Komika/KOMIKAH_.ttf";
	static inline final CHARACTER_PATH = "models/woman_casual/woman_casual.glb";
	static inline final SPRITE_PATH = "sprites/logo/wg-logo-bw-alpha.png";
	static inline final MUSIC_PATH = "music/a_hero_is_born.mp3";

	public static inline final SCREEN_WIDTH = 1024;
	public static inline final SCREEN_HEIGHT = 1280;
	static inline final DEBUG_FONT_SIZE = 18;
	static inline final KOMIKA_FONT_SIZE = 24;

	static inline final SPRITE_Y_OFFSET = 3.0;
	static inline final BOB_SPEED = 4.0;
	static inline final BOB_HEIGHT = 1.5;

	// kept across reloads: the handles of what's loaded, and where the timers are
	@:hot static var elapsed = 0.0;
	@:hot static var countdownTimer = 0.0;
	@:hot static var debugFont:Font;
	@:hot static var greyAlpha:Color = Color.BLACK;
	@:hot static var komikaFont:Font;
	@:hot static var sprite:Sprite3D;
	@:hot static var model:Model;
	@:hot static var bgm:Sound;
	@:hot static var camera:Camera3D;
	@:hot static var scene:Scene;
	@:hot static var backgroundColor:Color = Color.RAYWHITE;
	@:hot static var message = "";
	@:hot static var platformText = "";

	// --- assets: the path is local and ready; create the resource, then the object ---

	static function load(path:String, onReady:(path:String) -> Void):Void {
		final onFailed = (path:String) -> Log.error('failed to import asset: $path');
		if (!Asset.ensureAsync(path).then(onReady, onFailed))
			onFailed(path);
	}

	static function loadAssets():Void {
		load(MUSIC_PATH, path -> {
			final audio = new Audio(path);
			bgm = new Sound(audio);
			audio.release(); // the sound holds its own reference
			bgm.setLoop(true);
			bgm.play();
		});

		load(CHARACTER_PATH, path -> {
			final mesh = new Mesh(path);
			model = new Model(mesh);
			mesh.release(); // the model holds its own reference
			model.setAnimation(1);
			model.setAnimationSpeed(1.0);
			model.setAnimationLoop(true);
			model.setPosition(0, 0, 0);
			model.setTint(Color.RAYWHITE);
			scene.add(model);
		});

		load(SPRITE_PATH, path -> {
			final texture = new Texture(path);
			sprite = new Sprite3D(texture);
			texture.release(); // the sprite holds its own reference
			sprite.setFacing(Free); // librl's default: oriented by its rotation
			sprite.setPosition(0, SPRITE_Y_OFFSET, 0);
			sprite.setTint(Color.RAYWHITE);
			scene.add(sprite);
		});

		// Fonts are sized per draw call in wgrender, so one font handle serves any size.
		load(DEBUG_FONT_PATH, path -> debugFont = new Font(path));
		load(KOMIKA_FONT_PATH, path -> komikaFont = new Font(path));
	}

	// --- reloads ---

	@:beforeHotReload static function sayBeforeReload()
		Sys.println('simple: reloading (elapsed ${fixed(elapsed, 2)}, remaining ${fixed(countdownTimer, 2)})');

	@:afterHotReload static function sayReloaded()
		Sys.println('simple: reloaded (elapsed ${fixed(elapsed, 2)}, remaining ${fixed(countdownTimer, 2)})');

	// --- lifecycle ---

	public static function onInit():Void {
		Asset.setHost(Assets.defaultBase());
		Asset.setManifest(Assets.MANIFEST);
		Log.setLevel(Warn);
		Wgr.setTargetFps(60);

		countdownTimer = 30.0;
		message = "Hot reloaded!";
		platformText = 'Platform: ${Wgr.getPlatform()}';

		camera = new Camera3D(Perspective); // default fov: pi/4 (45 degrees)
		camera.setView(new Vec3(12, 12, 12), new Vec3(0, 1, 0));
		scene = new Scene();
		scene.setActiveCamera(camera);

		// same lighting as librl's c-simple: a directional light plus ambient 0.25
		final sun = new Light(Directional);
		sun.setDirection(new Vec3(-0.6, -1.0, -0.5));
		sun.setIntensity(3.0);
		scene.add(sun);
		scene.setAmbient(Color.WHITE, 0.25);
		backgroundColor = Color.rgba(245, 245, 245, 255);
		greyAlpha = Color.rgba(0, 0, 0, 128);

		loadAssets();
	}

	static function update(dt:Float):Void {
		elapsed += dt;
		countdownTimer -= dt;

		if (!model.isNone())
			model.animate(dt);
		if (!sprite.isNone()) {
			final y = Math.sin(elapsed * BOB_SPEED) * BOB_HEIGHT + SPRITE_Y_OFFSET;
			sprite.setPosition(0, y, 0);
		}
	}

	static function updatePickMessage(mouse:MouseState):Void {
		final pick = scene.pick(mouse.x, mouse.y);
		final what = if (!pick.hit) "" else if (pick.handle == model) "Model" else if (pick.handle == sprite)
			"Sprite" else "";
		if (what == "") {
			message = "Nothing picked!";
			return;
		}
		message = '$what pick: Mouse position (mouse.x:${mouse.x}, mouse.y:${mouse.y}) '
			+ 'pick result y: ${fixed(pick.pointWorld.y, 6)}';
	}

	// Draw with the TTF font once it's loaded, the built-in font until then.
	static function drawText(font:Font, text:String, x:Float, y:Float, size:Int, color:Color):Void {
		if (!font.isNone())
			font.draw(text, x, y, size, color);
		else
			Text.draw(text, Std.int(x), Std.int(y), size, color);
	}

	static function drawCenteredMessage():Void {
		final screen = Window.getScreenSize();
		final size = !komikaFont.isNone() ? komikaFont.measure(message,
			KOMIKA_FONT_SIZE) : new Vec2(Text.measure(message, KOMIKA_FONT_SIZE), KOMIKA_FONT_SIZE);
		drawText(komikaFont, message, (screen.x - size.x) / 2, (screen.y - size.y) / 2, KOMIKA_FONT_SIZE, Color.RED);
	}

	static function drawOverlay(mouse:MouseState):Void {
		drawText(debugFont, 'Remaining: ${fixed(countdownTimer, 2)}', 10, 36, DEBUG_FONT_SIZE, Color.BLACK);
		drawText(debugFont, 'Elapsed: ${fixed(elapsed, 2)}', 10, 56, DEBUG_FONT_SIZE, Color.BLACK);
		drawText(debugFont, 'Mouse: (${mouse.x}, ${mouse.y}) w:${fixed(mouse.wheel, 1)} '
			+ 'b:[${mouse.left}, ${mouse.right}, ${mouse.middle}]', 10, 76, DEBUG_FONT_SIZE, Color.BLACK);
		drawText(debugFont, platformText, 10, 96, DEBUG_FONT_SIZE, Color.BLACK);

		debugFont.drawFps(10, 10, DEBUG_FONT_SIZE, greyAlpha);
	}

	@:hot public static function frame(dt:Float, tickFraction:Float):Void {
		final mouse = Input.getMouseState();

		// Escape quits on desktop; a web page has nothing to quit to.
		#if !emscripten
		if (Input.isKeyPressed(Escape))
			Wgr.requestQuit();
		#end

		update(dt);
		updatePickMessage(mouse);

		Render.beginFrame();
		Render.clearBackground(backgroundColor);
		scene.draw();
		drawCenteredMessage();
		drawOverlay(mouse);
		Render.endFrame();
	}

	/** Haxe has no printf, and Std.string drops trailing zeros — so, by hand. **/
	static function fixed(value:Float, decimals:Int):String {
		final negative = value < 0;
		var digits = Std.string(Math.round(Math.abs(value) * Math.pow(10, decimals)));
		while (digits.length <= decimals)
			digits = "0" + digits;
		final point = digits.length - decimals;
		return (negative ? "-" : "") + digits.substr(0, point)
			+ (decimals > 0 ? "." + digits.substr(point) : "");
	}
}
