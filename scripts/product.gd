extends Node2D
class_name Product

# 商品。プレースホルダはコードで描く矩形＋バーコード。
# 後でBlender撮影のPNGスプライト(texture)に差し替え可能。

enum State { BASKET, SCANNED, DRAGGING, PLACED }

var type_name: String = ""
var base_w: int = 1
var base_h: int = 1
var grid_w: int = 1
var grid_h: int = 1
var body_color: Color = Color.WHITE
var cell: int = 70
var state: int = State.BASKET
var col: int = 0          # 袋に置いたときのグリッド座標
var row: int = 0
var rot_steps: int = 0    # 90度回転の回数（テクスチャ描画用）
var font: Font = null
var texture: Texture2D = null
var scan_flash: float = 0.0   # スキャン演出
var _bars: Array = []         # バーコードの縞パターン

func setup(spec: Dictionary, cell_px: int, jp_font: Font) -> void:
	type_name = spec.get("name", "?")
	base_w = int(spec.get("w", 1))
	base_h = int(spec.get("h", 1))
	grid_w = base_w
	grid_h = base_h
	body_color = spec.get("color", Color(0.8, 0.8, 0.8))
	cell = cell_px
	font = jp_font
	if spec.has("texture") and spec["texture"] != null:
		texture = spec["texture"]
	_gen_bars()
	queue_redraw()

func _gen_bars() -> void:
	_bars.clear()
	var n := 14
	for i in n:
		_bars.append(1.0 + randf() * 2.5)

func px_size() -> Vector2:
	return Vector2(grid_w * cell, grid_h * cell)

func rect_local() -> Rect2:
	return Rect2(Vector2.ZERO, px_size())

func contains_point(global_p: Vector2) -> bool:
	return rect_local().has_point(global_p - global_position)

func barcode_rect_local() -> Rect2:
	# 商品の絵を隠さないよう、下端中央に小さく配置（ここがスキャン用クリック領域）
	var s := px_size()
	var bw: float = min(s.x * 0.82, 54.0)
	var bh: float = min(s.y * 0.3, 20.0)
	return Rect2(Vector2((s.x - bw) * 0.5, s.y - bh - 5.0), Vector2(bw, bh))

func barcode_contains(global_p: Vector2) -> bool:
	return barcode_rect_local().has_point(global_p - global_position)

func rotate90() -> void:
	var t := grid_w
	grid_w = grid_h
	grid_h = t
	rot_steps = (rot_steps + 1) % 4
	queue_redraw()

func _process(delta: float) -> void:
	if scan_flash > 0.0:
		scan_flash = max(0.0, scan_flash - delta * 2.5)
		queue_redraw()

func _draw() -> void:
	var s := px_size()
	var body := Rect2(Vector2.ZERO, s)
	if texture != null:
		# スプライト表示。回転に合わせてテクスチャも90度ずつ回す（元footprint比率を保つ）
		var bw := base_w * cell
		var bh := base_h * cell
		draw_set_transform(s * 0.5, rot_steps * PI * 0.5, Vector2.ONE)
		draw_texture_rect(texture, Rect2(-Vector2(bw, bh) * 0.5, Vector2(bw, bh)), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		# プレースホルダ：角丸風の矩形（簡易）
		draw_rect(body, body_color.darkened(0.25), true)
		draw_rect(body.grow(-3.0), body_color, true)
		# 上部にハイライト
		draw_rect(Rect2(3, 3, s.x - 6, max(4.0, s.y * 0.18)), body_color.lightened(0.35), true)
	# 枠
	var border_col := Color.BLACK
	if state == State.PLACED:
		border_col = Color(0.1, 0.35, 0.1)
	draw_rect(body, border_col, false, 2.0)
	# 名前ラベル
	if font != null:
		draw_string(font, Vector2(6, 16), type_name, HORIZONTAL_ALIGNMENT_LEFT, s.x - 8, 14, Color(0.05, 0.05, 0.05))
	# バーコード（未スキャンのみ：ここをクリックでスキャン）
	if state == State.BASKET:
		var br := barcode_rect_local()
		draw_rect(br.grow(2.0), Color(1, 1, 1, 0.95), true)
		draw_rect(br.grow(2.0), Color(0.2, 0.2, 0.2), false, 1.0)
		var x := br.position.x + 3.0
		var total := 0.0
		for w in _bars:
			total += w + 2.0
		var bscale: float = (br.size.x - 6.0) / maxf(1.0, total)
		var i := 0
		for w in _bars:
			var bw: float = w * bscale
			if i % 2 == 0:
				draw_rect(Rect2(x, br.position.y + 3.0, bw, br.size.y - 6.0), Color.BLACK, true)
			x += (bw + 2.0 * bscale)
			i += 1
	# スキャン演出フラッシュ
	if scan_flash > 0.0:
		draw_rect(body, Color(1, 1, 0.6, scan_flash * 0.8), true)
