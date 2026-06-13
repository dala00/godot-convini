extends Node2D
# コンビニ レジ打ちゲーム — 全体管理（参考メモの「コード生成中心・薄いtscn」流儀）
#
# 画面: 左=レジ＋客の列（縦長）／右=レジ打ちプレイ画面
# 操作: バーコードをクリック→スキャン→商品がマウスに追従（置くまで）。もう一度クリックで置く。R:90度回転。
# 干渉: カゴ・袋・商品はすべてソリッド。追従中の商品は壁や他の商品を通り抜けられず、ぶつかると止まる。
#       → 箱(カゴ)から出すのも、袋に入れるのも一苦労。
# ルール: 全部袋に詰めたら次の客。客が10人たまると爆発→外観シーンで派手にゲームオーバー。
# スコア: さばいた客の人数。難易度: 時間で商品数も客の増える速さも逓増。

# ---- レイアウト ----
const VW := 1280.0
const VH := 720.0
const LEFT_PANEL_W := 300.0
const MAX_CUSTOMERS := 10
const WALL_T := 14.0

# 干渉の挙動: false=壁ずり（ぶつかっても止まるだけで追従継続）／ true=ぶつかったら追従が外れて落ちる
const DETACH_ON_HIT := false

const CELL := 64
const COLS := 6
const ROWS := 5
var BAG_ORIGIN := Vector2(360, 300)        # 袋グリッド左上（内側）。上に広い操作スペースを確保

const BCOLS := 4
const BROWS := 4
var BASKET_ORIGIN := Vector2(912, 320)     # カゴ内側左上

# プレイ可動域（追従中の商品をこの中にクランプ）
var PLAY_MIN := Vector2(306, 100)
var PLAY_MAX := Vector2(1274, 712)

# ---- 商品カタログ（プレースホルダ色／後でtextureを差し込む） ----
var CATALOG := [
	{"name": "おにぎり", "w": 1, "h": 1, "color": Color(0.95, 0.93, 0.85), "tex": "onigiri"},
	{"name": "サンド", "w": 2, "h": 1, "color": Color(0.98, 0.9, 0.7), "tex": "sand"},
	{"name": "缶ジュース", "w": 1, "h": 2, "color": Color(0.85, 0.3, 0.3), "tex": "can"},
	{"name": "牛乳", "w": 1, "h": 2, "color": Color(0.92, 0.92, 0.98), "tex": "milk"},
	{"name": "ペットボトル", "w": 1, "h": 3, "color": Color(0.5, 0.75, 0.95), "tex": "pet"},
	{"name": "お菓子", "w": 2, "h": 2, "color": Color(0.95, 0.7, 0.2), "tex": "snack"},
	{"name": "カップ麺", "w": 2, "h": 2, "color": Color(0.9, 0.55, 0.3), "tex": "cup"},
	{"name": "弁当", "w": 3, "h": 2, "color": Color(0.6, 0.4, 0.25), "tex": "bento"},
]
var CUSTOMER_COLORS := [
	Color(0.9, 0.5, 0.5), Color(0.5, 0.7, 0.9), Color(0.6, 0.8, 0.5),
	Color(0.9, 0.8, 0.4), Color(0.8, 0.6, 0.9), Color(0.5, 0.85, 0.85),
	Color(0.95, 0.65, 0.4),
]

# ---- 状態 ----
enum GS { PLAYING, GAMEOVER }
var gstate: int = GS.PLAYING

var font_jp: Font = null
var walls: Array = []          # 壁のRect2（カゴ・袋の3辺ずつ。上は開口）
var occ := []                  # 袋の占有 [COLS][ROWS]
var queue := []                # 客の列。queue[0]=接客中
var active_products := []      # 接客中の客の商品ノード
var dragging: Product = null   # マウス追従中の商品
var drag_offset := Vector2.ZERO
var ghost_col := -1
var ghost_row := -1
var ghost_valid := false

var elapsed := 0.0
var spawn_accum := 0.0
var score := 0
var explosion: CPUParticles2D = null
var shake := 0.0

# 効果音（_build_sfxでコード合成）
var sfx_scan: AudioStreamWAV = null
var sfx_place: AudioStreamWAV = null
var sfx_error: AudioStreamWAV = null
var sfx_clear: AudioStreamWAV = null
var sfx_gameover: AudioStreamWAV = null
var bgm_player: AudioStreamPlayer = null
var bgm_started := false

func _ready() -> void:
	randomize()
	font_jp = _make_jp_font()
	_load_textures()
	_build_sfx()
	_start_bgm()
	_build_walls()
	_reset_occ()
	_spawn_customer()
	set_process(true)
	set_process_unhandled_input(true)

func _load_textures() -> void:
	for c in CATALOG:
		var path := "res://sprites/%s.png" % c.get("tex", "")
		if ResourceLoader.exists(path):
			var t = load(path)
			if t != null:
				c["texture"] = t

func _make_jp_font() -> Font:
	# 同梱フォント（サブセット化したOFLの日本語）を使う。
	# SystemFontはWeb書き出しでOSフォントが無く文字化けするため、必ず埋め込みフォントを優先。
	var path := "res://fonts/convini_jp.ttf"
	if ResourceLoader.exists(path):
		var f = load(path)
		if f is Font:
			return f
	# フォールバック（フォント未取り込み時のデスクトップ用）
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Meiryo", "Yu Gothic UI", "MS Gothic", "Noto Sans CJK JP"])
	return sf

func _build_walls() -> void:
	walls.clear()
	var bag_w := COLS * CELL
	var bag_h := ROWS * CELL
	# 袋：左・右・下（上は開口）
	walls.append(Rect2(BAG_ORIGIN.x - WALL_T, BAG_ORIGIN.y, WALL_T, bag_h))
	walls.append(Rect2(BAG_ORIGIN.x + bag_w, BAG_ORIGIN.y, WALL_T, bag_h))
	walls.append(Rect2(BAG_ORIGIN.x - WALL_T, BAG_ORIGIN.y + bag_h, bag_w + WALL_T * 2, WALL_T))
	# カゴ：左・右・下（上は開口）
	var bk_w := BCOLS * CELL
	var bk_h := BROWS * CELL
	walls.append(Rect2(BASKET_ORIGIN.x - WALL_T, BASKET_ORIGIN.y, WALL_T, bk_h))
	walls.append(Rect2(BASKET_ORIGIN.x + bk_w, BASKET_ORIGIN.y, WALL_T, bk_h))
	walls.append(Rect2(BASKET_ORIGIN.x - WALL_T, BASKET_ORIGIN.y + bk_h, bk_w + WALL_T * 2, WALL_T))

func _reset_occ() -> void:
	occ.clear()
	for c in COLS:
		var colarr := []
		for r in ROWS:
			colarr.append(null)
		occ.append(colarr)

# ============================================================
#  客・難易度
# ============================================================
func _spawn_interval() -> float:
	return clampf(8.0 - elapsed * 0.05, 2.6, 8.0)

func _make_customer() -> Dictionary:
	var budget := int(clampf(2.0 + elapsed * 0.10, 2.0, 14.0))
	var prods := []
	var area := 0
	var guard := 0
	while area < budget and prods.size() < 7 and guard < 60:
		guard += 1
		var c: Dictionary = CATALOG[randi() % CATALOG.size()]
		if elapsed < 18.0 and c.w * c.h > 2:
			continue
		if area + c.w * c.h > budget + 2:
			continue
		prods.append(c)
		area += c.w * c.h
	if prods.is_empty():
		prods.append(CATALOG[0])
	var col_idx := queue.size() % CUSTOMER_COLORS.size()
	return {"color": CUSTOMER_COLORS[col_idx], "products": prods}

func _spawn_customer() -> void:
	if gstate != GS.PLAYING:
		return
	queue.append(_make_customer())
	if queue.size() == 1:
		_activate_front()
	if queue.size() >= MAX_CUSTOMERS:
		_game_over()

func _activate_front() -> void:
	_clear_active_products()
	_reset_occ()
	if queue.is_empty():
		return
	var cust: Dictionary = queue[0]
	# カゴの中身は「重力で落として積もった」初期配置：ランダムなX位置に落とし、
	# 下にある物（または床）の上に乗せる。縦並びも横並びも出て、積まれると取り出しにくい。
	var left := BASKET_ORIGIN.x
	var right := BASKET_ORIGIN.x + BCOLS * CELL
	var floor_y := BASKET_ORIGIN.y + BROWS * CELL
	var bucket := 8.0
	var ncols := int((right - left) / bucket)
	var surf := []                       # 各バケットの現在の表面y（小さいほど高く積まれている）
	for i in ncols:
		surf.append(floor_y)
	var specs: Array = cust["products"].duplicate()
	specs.shuffle()
	for spec in specs:
		var p := Product.new()
		add_child(p)
		p.setup(spec, CELL, font_jp)
		var sz := p.px_size()
		var maxx: float = right - sz.x
		var x: float = left if maxx <= left else randf_range(left, maxx)
		var bi0: int = clampi(int((x - left) / bucket), 0, ncols - 1)
		var bi1: int = clampi(int((x + sz.x - left) / bucket), 0, ncols - 1)
		var top := floor_y
		for bi in range(bi0, bi1 + 1):
			top = min(top, surf[bi])
		var py: float = max(top - sz.y, PLAY_MIN.y)
		p.position = Vector2(x, py)
		for bi in range(bi0, bi1 + 1):
			surf[bi] = py
		active_products.append(p)

func _clear_active_products() -> void:
	for p in active_products:
		if is_instance_valid(p):
			p.queue_free()
	active_products.clear()
	dragging = null

func _check_cleared() -> void:
	if active_products.is_empty():
		return
	for p in active_products:
		if p.state != Product.State.PLACED:
			return
	score += 1
	_play(sfx_clear)
	queue.pop_front()
	if queue.is_empty():
		_clear_active_products()
		_reset_occ()
	else:
		_activate_front()

# ============================================================
#  袋グリッド配置
# ============================================================
func _cell_from_pos(top_left: Vector2) -> Vector2i:
	var rel := top_left - BAG_ORIGIN
	return Vector2i(int(round(rel.x / CELL)), int(round(rel.y / CELL)))

func _can_place(p: Product, c: int, r: int) -> bool:
	if c < 0 or r < 0 or c + p.grid_w > COLS or r + p.grid_h > ROWS:
		return false
	for dx in p.grid_w:
		for dy in p.grid_h:
			var o = occ[c + dx][r + dy]
			if o != null and o != p:
				return false
	return true

func _set_occ(p: Product, c: int, r: int, val) -> void:
	for dx in p.grid_w:
		for dy in p.grid_h:
			occ[c + dx][r + dy] = val

func _free_occ_of(p: Product) -> void:
	for c in COLS:
		for r in ROWS:
			if occ[c][r] == p:
				occ[c][r] = null

# ============================================================
#  入力（スキャン／掴む・置く／回転）
# ============================================================
func _unhandled_input(event: InputEvent) -> void:
	# 最初のユーザー操作でBGM開始（ブラウザの自動再生制限対策）
	if not bgm_started and bgm_player != null and event is InputEventMouseButton and event.pressed:
		bgm_player.play()
		bgm_started = true
	if gstate == GS.GAMEOVER:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_restart()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R and dragging != null:
		_try_rotate()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if dragging != null:
			_try_drop()
		else:
			_try_grab(event.position)

func _try_grab(mp: Vector2) -> void:
	for i in range(active_products.size() - 1, -1, -1):
		var p: Product = active_products[i]
		if p.state == Product.State.BASKET:
			if p.barcode_contains(mp):
				p.state = Product.State.DRAGGING
				p.scan_flash = 1.0
				_play(sfx_scan)
				dragging = p
				drag_offset = mp - p.position
				_raise(p)
				return
		elif p.state == Product.State.SCANNED or p.state == Product.State.PLACED:
			if p.contains_point(mp):
				if p.state == Product.State.PLACED:
					_free_occ_of(p)
				p.state = Product.State.DRAGGING
				dragging = p
				drag_offset = mp - p.position
				_raise(p)
				return

func _try_drop() -> void:
	var p := dragging
	var c := _cell_from_pos(p.position)
	if _can_place(p, c.x, c.y):
		p.state = Product.State.PLACED
		p.col = c.x
		p.row = c.y
		p.position = BAG_ORIGIN + Vector2(c.x * CELL, c.y * CELL)
		_set_occ(p, c.x, c.y, p)
		dragging = null
		_play(sfx_place)
		_check_cleared()
	else:
		# 袋に収まらない位置 → その場に「置いた」状態（loose）にする。以後も掴み直せる。
		p.state = Product.State.SCANNED
		dragging = null
		_play(sfx_error)

func _try_rotate() -> void:
	var p := dragging
	p.rotate90()
	# 回転で可動域や障害物にめり込むなら戻す
	var sz := p.px_size()
	if p.position.x < PLAY_MIN.x or p.position.y < PLAY_MIN.y or p.position.x + sz.x > PLAY_MAX.x or p.position.y + sz.y > PLAY_MAX.y:
		p.rotate90(); p.rotate90(); p.rotate90()
		return
	var rect := Rect2(p.position, sz)
	for ob in _obstacles_for(p):
		if rect.intersects(ob):
			p.rotate90(); p.rotate90(); p.rotate90()
			return

func _raise(p: Product) -> void:
	move_child(p, get_child_count() - 1)

# ============================================================
#  追従＆連続衝突
# ============================================================
func _obstacles_for(except: Product) -> Array:
	var arr := walls.duplicate()
	for p in active_products:
		if p == except:
			continue
		arr.append(Rect2(p.position, p.px_size()))
	return arr

func _move_dragging() -> void:
	var p := dragging
	var size := p.px_size()
	var target := get_global_mouse_position() - drag_offset
	var pos := p.position
	var motion := target - pos
	var dist := motion.length()
	if dist < 0.01:
		return
	var steps: int = clampi(int(ceil(dist / 6.0)), 1, 600)
	var step := motion / float(steps)
	var obs := _obstacles_for(p)
	var hit := false
	for s in steps:
		# X軸
		pos.x = clampf(pos.x + step.x, PLAY_MIN.x, PLAY_MAX.x - size.x)
		var rx := Rect2(pos, size)
		for ob in obs:
			if rx.intersects(ob):
				hit = true
				if step.x > 0:
					pos.x = ob.position.x - size.x
				elif step.x < 0:
					pos.x = ob.position.x + ob.size.x
				rx = Rect2(pos, size)
		# Y軸
		pos.y = clampf(pos.y + step.y, PLAY_MIN.y, PLAY_MAX.y - size.y)
		var ry := Rect2(pos, size)
		for ob in obs:
			if ry.intersects(ob):
				hit = true
				if step.y > 0:
					pos.y = ob.position.y - size.y
				elif step.y < 0:
					pos.y = ob.position.y + ob.size.y
				ry = Rect2(pos, size)
		if hit and DETACH_ON_HIT:
			break
	p.position = pos
	if hit and DETACH_ON_HIT:
		# ぶつかったら追従が外れて、その場に落ちる
		p.state = Product.State.SCANNED
		dragging = null
		ghost_col = -1

func _process(delta: float) -> void:
	if gstate == GS.PLAYING:
		elapsed += delta
		spawn_accum += delta
		if spawn_accum >= _spawn_interval():
			spawn_accum = 0.0
			_spawn_customer()
		if dragging != null:
			_move_dragging()
			var c := _cell_from_pos(dragging.position)
			ghost_col = c.x
			ghost_row = c.y
			ghost_valid = _can_place(dragging, c.x, c.y)
		else:
			ghost_col = -1
	if shake > 0.0:
		shake = max(0.0, shake - delta)
	queue_redraw()

# ============================================================
#  サウンド（簡易ビープ）
# ============================================================
# 1サンプル分の波形値（phaseは「累積サイクル数」）
func _osc(wave: String, phase: float) -> float:
	match wave:
		"square":
			return 1.0 if fmod(phase, 1.0) < 0.5 else -1.0
		"tri":
			var x := fmod(phase, 1.0)
			return 4.0 * abs(x - 0.5) - 1.0
		"saw":
			return 2.0 * fmod(phase, 1.0) - 1.0
		"noise":
			return randf() * 2.0 - 1.0
		_:
			return sin(phase * TAU)

# セグメント列から効果音(AudioStreamWAV)を合成する。
# segment例: {"freq":440, "freq2":880(任意・スイープ先), "dur":0.1, "wave":"sine",
#             "vol":0.4, "env":"decay"|"attackdecay"|"flat"}
func _make_sfx(segments: Array) -> AudioStreamWAV:
	var sr := 22050
	var total := 0
	for s in segments:
		total += int(sr * float(s.get("dur", 0.1)))
	var data := PackedByteArray()
	data.resize(total * 2)
	var idx := 0
	for s in segments:
		var n := int(sr * float(s.get("dur", 0.1)))
		var wave: String = s.get("wave", "sine")
		var vol: float = s.get("vol", 0.45)
		var f: float = s.get("freq", 440.0)
		var f2: float = s.get("freq2", f)
		var env_mode: String = s.get("env", "decay")
		var phase := 0.0
		for i in n:
			var frac := float(i) / float(max(1, n))
			var cf: float = lerp(f, f2, frac)
			phase += cf / sr
			var sample := _osc(wave, phase)
			var env := 1.0
			match env_mode:
				"decay":
					env = 1.0 - frac
				"attackdecay":
					env = sin(frac * PI)
				_:
					env = 1.0
			var sv := sample * env * vol
			var v := int(clampf(sv, -1.0, 1.0) * 32767.0)
			data[idx * 2] = v & 0xFF
			data[idx * 2 + 1] = (v >> 8) & 0xFF
			idx += 1
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sr
	wav.stereo = false
	wav.data = data
	return wav

func _build_sfx() -> void:
	sfx_scan = _make_sfx([
		{"freq": 1760.0, "dur": 0.07, "wave": "sine", "vol": 0.45, "env": "decay"},
	])
	# 設置成功：軽い上昇「ポンッ」
	sfx_place = _make_sfx([
		{"freq": 620.0, "dur": 0.045, "wave": "tri", "vol": 0.4, "env": "attackdecay"},
		{"freq": 980.0, "dur": 0.08, "wave": "tri", "vol": 0.45, "env": "decay"},
	])
	# 置けない：低い「ブッ」
	sfx_error = _make_sfx([
		{"freq": 200.0, "dur": 0.05, "wave": "square", "vol": 0.3, "env": "flat"},
		{"freq": 150.0, "dur": 0.11, "wave": "square", "vol": 0.32, "env": "decay"},
	])
	# 客クリア：ドアチャイム「ピンポーン」
	sfx_clear = _make_sfx([
		{"freq": 1175.0, "dur": 0.16, "wave": "sine", "vol": 0.45, "env": "attackdecay"},
		{"freq": 784.0, "dur": 0.30, "wave": "sine", "vol": 0.45, "env": "decay"},
	])
	# ゲームオーバー：爆発ノイズ＋悲しい下降音
	sfx_gameover = _make_sfx([
		{"freq": 90.0, "dur": 0.6, "wave": "noise", "vol": 0.5, "env": "decay"},
		{"freq": 392.0, "dur": 0.2, "wave": "tri", "vol": 0.4, "env": "attackdecay"},
		{"freq": 330.0, "dur": 0.2, "wave": "tri", "vol": 0.4, "env": "attackdecay"},
		{"freq": 262.0, "dur": 0.45, "wave": "tri", "vol": 0.42, "env": "decay"},
	])

func _start_bgm() -> void:
	# BGM（ループ再生）。書き出し版でも含まれるよう load() でインポート済みリソースを使う。
	var path := "res://sounds/Caribbean_Passion.mp3"
	if not ResourceLoader.exists(path):
		return
	var stream = load(path)
	if stream == null:
		return
	if stream is AudioStreamMP3:
		stream.loop = true
	bgm_player = AudioStreamPlayer.new()
	bgm_player.stream = stream
	bgm_player.volume_db = -11.0      # SFXが埋もれないよう控えめに
	add_child(bgm_player)
	# ブラウザは自動再生を禁止するため、Webでは最初のクリックで再生開始する。
	if OS.has_feature("web"):
		bgm_started = false
	else:
		bgm_player.play()
		bgm_started = true

func _play(stream: AudioStream) -> void:
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	add_child(player)
	player.stream = stream
	player.play()
	player.finished.connect(func(): player.queue_free())

# ============================================================
#  ゲームオーバー（外観シーン＋爆発）
# ============================================================
func _game_over() -> void:
	if gstate == GS.GAMEOVER:
		return
	gstate = GS.GAMEOVER
	_play(sfx_gameover)
	_clear_active_products()
	queue.clear()
	shake = 1.2
	explosion = CPUParticles2D.new()
	add_child(explosion)
	explosion.position = Vector2(VW * 0.5, VH * 0.55)
	explosion.amount = 260
	explosion.lifetime = 1.6
	explosion.one_shot = false
	explosion.explosiveness = 0.85
	explosion.spread = 180.0
	explosion.initial_velocity_min = 200.0
	explosion.initial_velocity_max = 650.0
	explosion.gravity = Vector2(0, 220)
	explosion.scale_amount_min = 3.0
	explosion.scale_amount_max = 9.0
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 0.6, 1))
	grad.add_point(0.4, Color(1, 0.5, 0.1, 1))
	grad.set_color(1, Color(0.4, 0.1, 0.1, 0))
	explosion.color_ramp = grad

func _restart() -> void:
	if explosion != null and is_instance_valid(explosion):
		explosion.queue_free()
		explosion = null
	_clear_active_products()
	queue.clear()
	_reset_occ()
	elapsed = 0.0
	spawn_accum = 0.0
	score = 0
	shake = 0.0
	gstate = GS.PLAYING
	_spawn_customer()

# ============================================================
#  描画
# ============================================================
func _draw() -> void:
	if shake > 0.0:
		var off := Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 14.0
		draw_set_transform(off, 0.0, Vector2.ONE)
	if gstate == GS.GAMEOVER:
		_draw_gameover()
		return
	draw_rect(Rect2(0, 0, VW, VH), Color(0.16, 0.18, 0.22), true)
	draw_rect(Rect2(LEFT_PANEL_W, 0, VW - LEFT_PANEL_W, VH), Color(0.22, 0.25, 0.30), true)
	_draw_left_panel()
	_draw_bag()
	_draw_basket()
	_draw_walls()
	_draw_topbar()

func _draw_left_panel() -> void:
	draw_rect(Rect2(0, 0, LEFT_PANEL_W, VH), Color(0.12, 0.13, 0.16), true)
	draw_line(Vector2(LEFT_PANEL_W, 0), Vector2(LEFT_PANEL_W, VH), Color(0, 0, 0), 3.0)
	draw_rect(Rect2(20, 20, LEFT_PANEL_W - 40, 60), Color(0.3, 0.3, 0.38), true)
	draw_rect(Rect2(20, 20, LEFT_PANEL_W - 40, 60), Color(0, 0, 0), false, 2.0)
	_text("レジ", Vector2(30, 58), 22, Color(0.95, 0.95, 1.0))
	# 客数（爆発間近は赤点滅）
	var danger := queue.size() >= MAX_CUSTOMERS - 2
	var qcol := Color(1, 0.8, 0.8)
	if danger:
		qcol = Color(1, 0.25, 0.2) if (int(elapsed * 4.0) % 2 == 0) else Color(1, 0.7, 0.2)
	_text("並んでいる客: %d / %d" % [queue.size(), MAX_CUSTOMERS], Vector2(20, 108), 16, qcol)
	if danger:
		_text("まもなく爆発!!", Vector2(150, 108), 16, qcol)
	var slot_h := 52.0
	var top := 120.0
	for i in MAX_CUSTOMERS:
		var y := top + i * slot_h
		var filled := i < queue.size()
		var slot := Rect2(20, y, LEFT_PANEL_W - 40, slot_h - 8)
		var base_bg := Color(0.18, 0.19, 0.23) if filled else Color(0.1, 0.1, 0.12)
		if danger and filled:
			base_bg = base_bg.lerp(Color(0.4, 0.12, 0.1), 0.5)
		draw_rect(slot, base_bg, true)
		draw_rect(slot, Color(0, 0, 0, 0.5), false, 1.0)
		if filled:
			var cust: Dictionary = queue[i]
			var ccol: Color = cust["color"]
			var hx := slot.position.x + 24.0
			var hy := slot.position.y + slot.size.y * 0.5 + sin(elapsed * 3.0 + i) * 1.2
			# 表情: 先頭(接客中)は普通、後ろほど＆混雑時ほど不機嫌
			var mood := 0.0   # 1=笑顔 0=普通 -1=怒り
			if i == 0:
				mood = 0.2
			else:
				mood = -clampf((float(i) + (queue.size() - 3)) / 7.0, 0.0, 1.0)
			_draw_person(Vector2(hx, hy), ccol, mood)
			var label := "接客中" if i == 0 else "待ち %d" % i
			_text(label, Vector2(slot.position.x + 50, hy - 6), 15, Color(1, 1, 1) if i == 0 else Color(0.82, 0.82, 0.86))
			_text("商品 %d 個" % cust["products"].size(), Vector2(slot.position.x + 50, hy + 12), 13, Color(0.7, 0.85, 0.7))
			if i == 0:
				draw_rect(slot, Color(1, 0.9, 0.3), false, 2.5)

# 客アイコン（頭＋顔＋体）。mood: 1=笑顔/0=普通/-1=怒り
func _draw_person(c: Vector2, body_col: Color, mood: float) -> void:
	var skin := Color(0.98, 0.86, 0.74)
	# 体（肩）
	draw_rect(Rect2(c.x - 13, c.y + 2, 26, 16), body_col, true)
	draw_rect(Rect2(c.x - 13, c.y + 2, 26, 4), body_col.lightened(0.2), true)
	# 頭
	draw_circle(Vector2(c.x, c.y - 7), 11.0, skin)
	# 目
	var eye := Color(0.15, 0.12, 0.1)
	draw_circle(Vector2(c.x - 4, c.y - 8), 1.7, eye)
	draw_circle(Vector2(c.x + 4, c.y - 8), 1.7, eye)
	# 怒り眉
	if mood < -0.3:
		draw_line(Vector2(c.x - 6, c.y - 12), Vector2(c.x - 2, c.y - 10), eye, 1.5)
		draw_line(Vector2(c.x + 6, c.y - 12), Vector2(c.x + 2, c.y - 10), eye, 1.5)
	# 口（mood>0=笑顔の弧 / mood<0=への字）
	var my := c.y - 2.0
	if mood > 0.1:
		draw_arc(Vector2(c.x, my - 1), 4.0, 0.2 * PI, 0.8 * PI, 8, eye, 1.5)
	elif mood < -0.3:
		draw_arc(Vector2(c.x, my + 4), 4.0, 1.2 * PI, 1.8 * PI, 8, eye, 1.5)
	else:
		draw_line(Vector2(c.x - 3, my + 1), Vector2(c.x + 3, my + 1), eye, 1.5)

func _draw_bag() -> void:
	var bag_rect := Rect2(BAG_ORIGIN, Vector2(COLS * CELL, ROWS * CELL))
	draw_rect(bag_rect, Color(0.86, 0.78, 0.62), true)
	_text("袋 (BAG)  ← ここに詰める", BAG_ORIGIN + Vector2(0, -22), 18, Color(0.95, 0.9, 0.8))
	for c in COLS:
		for r in ROWS:
			var cellrect := Rect2(BAG_ORIGIN + Vector2(c * CELL, r * CELL), Vector2(CELL, CELL))
			draw_rect(cellrect, Color(0.97, 0.94, 0.86, 0.18), true)
			draw_rect(cellrect, Color(0.35, 0.28, 0.18, 0.5), false, 1.0)
	if dragging != null and ghost_col >= 0 and ghost_row >= 0 and ghost_col + dragging.grid_w <= COLS and ghost_row + dragging.grid_h <= ROWS:
		var gpos := BAG_ORIGIN + Vector2(ghost_col * CELL, ghost_row * CELL)
		var gsz := Vector2(dragging.grid_w * CELL, dragging.grid_h * CELL)
		var gcol := Color(0.3, 1, 0.3, 0.45) if ghost_valid else Color(1, 0.3, 0.3, 0.4)
		draw_rect(Rect2(gpos, gsz), gcol, true)

func _draw_basket() -> void:
	var bk := Rect2(BASKET_ORIGIN, Vector2(BCOLS * CELL, BROWS * CELL))
	draw_rect(bk, Color(0.30, 0.34, 0.40), true)
	_text("カゴ (商品)", BASKET_ORIGIN + Vector2(0, -22), 18, Color(0.9, 0.95, 1.0))

func _draw_walls() -> void:
	for w in walls:
		draw_rect(w, Color(0.45, 0.38, 0.28), true)
		draw_rect(w, Color(0.2, 0.16, 0.1), false, 1.0)

func _draw_topbar() -> void:
	_text("さばいた客: %d 人" % score, Vector2(LEFT_PANEL_W + 20, 40), 26, Color(1, 1, 0.7))
	_text("時間: %d 秒" % int(elapsed), Vector2(LEFT_PANEL_W + 300, 40), 20, Color(0.85, 0.9, 1.0))
	_text("バーコードをクリック→商品がマウスに追従／もう一度クリックで置く／R:回転", Vector2(LEFT_PANEL_W + 20, 72), 14, Color(0.8, 0.85, 0.9))

func _draw_gameover() -> void:
	for i in 24:
		var t := i / 24.0
		var col := Color(0.15, 0.05, 0.1).lerp(Color(0.6, 0.2, 0.1), t)
		draw_rect(Rect2(0, t * VH, VW, VH / 24.0 + 1), col, true)
	draw_rect(Rect2(0, VH * 0.72, VW, VH * 0.28), Color(0.12, 0.12, 0.14), true)
	var b := Rect2(VW * 0.28, VH * 0.36, VW * 0.44, VH * 0.36)
	draw_rect(b, Color(0.85, 0.85, 0.8), true)
	draw_rect(Rect2(b.position.x, b.position.y, b.size.x, 34), Color(0.2, 0.5, 0.8), true)
	_text("CONVINI", Vector2(b.position.x + 16, b.position.y + 25), 22, Color(1, 1, 1))
	draw_rect(Rect2(b.position.x + 20, b.position.y + 60, b.size.x - 40, b.size.y - 80), Color(0.5, 0.7, 0.85, 0.7), true)
	var flash: float = clampf(shake, 0.0, 1.0)
	if flash > 0.0:
		draw_rect(Rect2(0, 0, VW, VH), Color(1, 0.9, 0.6, flash * 0.5), true)
	_text_center("GAME OVER", Vector2(VW * 0.5, VH * 0.2), 64, Color(1, 0.3, 0.2))
	_text_center("客が10人たまって爆発した！", Vector2(VW * 0.5, VH * 0.28), 26, Color(1, 0.9, 0.8))
	_text_center("さばいた客: %d 人" % score, Vector2(VW * 0.5, VH * 0.85), 36, Color(1, 1, 0.7))
	_text_center("クリックでリスタート", Vector2(VW * 0.5, VH * 0.92), 22, Color(0.9, 0.9, 0.9))

func _text(s: String, pos: Vector2, size: int, col: Color) -> void:
	if font_jp != null:
		draw_string(font_jp, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _text_center(s: String, center: Vector2, size: int, col: Color) -> void:
	if font_jp == null:
		return
	var w := font_jp.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font_jp, center - Vector2(w * 0.5, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
