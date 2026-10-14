package main

import "core:strings"
import "core:math"
import "core:slice"

Cell :: struct {text: string, highlight: int, colors: [3]int, blended: bool}
Highlight :: struct {
	foreground, background, special: int,
	reverse, bold, italic, underline, undercurl, strikethrough: bool,
	underdouble, underdotted, underdashed: bool,
	dim, blink, conceal, overline: bool,
	altfont: bool,
	url: string,
	blend: int,
}
Cursor_Mode :: struct {
	shape: string,
	percentage, attr_id, blinkwait, blinkon, blinkoff: int,
}
Grid :: struct {width, height: int, cells: []Cell}
Grid_Kind :: enum {Root, Split, Float, Message, External}
Window_Grid :: struct {
	id, window: int,
	grid: Grid,
	kind: Grid_Kind,
	visible, mouse_enabled: bool,
	row, col: f64,
	anchor: string,
	anchor_grid: int,
	anchor_row, anchor_col: f64,
	zindex, compindex: int,
	screen_position: bool,
	viewport: [6]int,
	margins: [4]int,
}
UI :: struct {
	widgets: Widgets,
	grid: Grid,
	grids: map[int]^Window_Grid,
	highlights: map[int]Highlight,
	foreground, background, special: int,
	cursor_row, cursor_col: int,
	cursor_grid: int,
	cursor_local: [2]int,
	cursor_style_enabled: bool,
	modes: []Cursor_Mode,
	mode_index: int,
	busy, mouse, dirty, flushed, bell: bool,
	title, guifont: string,
	guifontwide: string,
	linespace: int,
	mousehide, mousemoveevent, mousefocus: bool,
	reconnect_address: string,
	restart: bool,
	font_changed: bool,
	ambiwidth_double: bool,
	showtabline: int,
	highlight_groups: map[string]int,
}

ui_init :: proc(ui: ^UI) {
	ui.highlights = make(map[int]Highlight)
	ui.grids = make(map[int]^Window_Grid)
	ui.widgets.cmdlines = make(map[int]^Command_Line)
	ui.highlight_groups = make(map[string]int)
	ui.showtabline = 1
	ui.mousehide = true; ui.linespace = -1
	ui.cursor_grid = 1; ui.cursor_style_enabled = true
	ui.foreground = 0xffffff; ui.background = 0x181818; ui.special = 0xffffff
	ui.title = strings.clone("Neodin")
}
cell_destroy :: proc(c: ^Cell) {delete(c.text); c^ = {}}
grid_destroy :: proc(g: ^Grid) {
	for &cell in g.cells {cell_destroy(&cell)}
	delete(g.cells); g^ = {}
}
ui_destroy :: proc(ui: ^UI) {
	widgets_destroy(&ui.widgets)
	for name, _ in ui.highlight_groups {delete(name)}; delete(ui.highlight_groups)
	grid_destroy(&ui.grid)
	for _, h in ui.highlights {delete(h.url)}; delete(ui.highlights)
	for _, g in ui.grids {grid_destroy(&g.grid); delete(g.anchor); free(g)}
	delete(ui.grids)
	for mode in ui.modes {delete(mode.shape)}
	delete(ui.modes); delete(ui.title); delete(ui.guifont); delete(ui.guifontwide); delete(ui.reconnect_address)
}
grid_resize :: proc(g: ^Grid, width, height: int) {
	if g.width == width && g.height == height {return}
	if width < 1 || height < 1 || width > 10000 || height > 10000 || width*height > 4_000_000 {return}
	next := make([]Cell, width*height)
	for y in 0..<min(g.height, height) {
		for x in 0..<min(g.width, width) {
			next[y*width+x] = g.cells[y*g.width+x]
			g.cells[y*g.width+x] = {}
		}
	}
	grid_destroy(g)
	g^ = {width, height, next}
}
grid_set :: proc(g: ^Grid, row, col: int, text: string, highlight: int) {
	if row < 0 || row >= g.height || col < 0 || col >= g.width {return}
	c := &g.cells[row*g.width+col]
	if c.text == text && c.highlight == highlight {return}
	cell_destroy(c)
	c^ = {text = strings.clone(text), highlight = highlight}
}
ui_grid :: proc(ui: ^UI, id: int) -> ^Window_Grid {
	if g, ok := ui.grids[id]; ok {return g}
	g := new(Window_Grid)
	g.id = id; g.visible = id == 1; g.mouse_enabled = true
	g.kind = .Root if id == 1 else .Split
	ui.grids[id] = g
	return g
}
ui_grid_position :: proc(ui: ^UI, id: int, depth := 0) -> (row, col: f64) {
	g, ok := ui.grids[id]
	if !ok || depth > len(ui.grids) {return}
	if g.kind != .Float || g.screen_position {return g.row, g.col}
	row, col = ui_grid_position(ui, g.anchor_grid, depth+1)
	row += g.anchor_row; col += g.anchor_col
	if strings.has_prefix(g.anchor, "S") {row -= f64(g.grid.height)}
	if strings.has_suffix(g.anchor, "E") {col -= f64(g.grid.width)}
	// Match Nvim's compositor clipping when an anchored float exceeds the grid.
	row = clamp(row, 0, f64(max(ui.grid.height-g.grid.height, 0)))
	col = clamp(col, 0, f64(max(ui.grid.width-g.grid.width, 0)))
	return
}
ui_grid_layers :: proc(ui: ^UI) -> []^Window_Grid {
	result := make([dynamic]^Window_Grid, allocator = context.temp_allocator)
	for _, g in ui.grids {if g.visible && g.kind != .Root && g.kind != .External {append(&result, g)}}
	slice.sort_by(result[:], proc(a, b: ^Window_Grid) -> bool {
		af := a.kind == .Float || a.kind == .Message
		bf := b.kind == .Float || b.kind == .Message
		if af != bf {return !af}
		if a.compindex != b.compindex {return a.compindex < b.compindex}
		if a.zindex != b.zindex {return a.zindex < b.zindex}
		return a.id < b.id
	})
	return result[:]
}
ui_compose :: proc(ui: ^UI) {
	root, ok := ui.grids[1]
	if !ok {return}
	grid_resize(&ui.grid, root.grid.width, root.grid.height)
	for cell, i in root.grid.cells {
		grid_set(&ui.grid, i/root.grid.width, i%root.grid.width, cell.text, cell.highlight)
		ui.grid.cells[i].blended = false
	}
	layers := ui_grid_layers(ui)
	// Floating layers blend against the non-floating scene, not sibling borders.
	base := make([]Cell, len(ui.grid.cells), context.temp_allocator)
	copy(base, ui.grid.cells)
	have_base := false
	for g in layers {
		if !have_base && (g.kind == .Float || g.kind == .Message) {copy(base, ui.grid.cells)
			for &cell in base {cell.text = strings.clone(cell.text, context.temp_allocator)}
			have_base = true}
		row, col := ui_grid_position(ui, g.id)
		y0, x0 := int(math.floor(row)), int(math.floor(col))
		for y in 0..<g.grid.height {for x in 0..<g.grid.width {
			dy, dx := y0+y, x0+x
			if dy < 0 || dx < 0 || dy >= ui.grid.height || dx >= ui.grid.width {continue}
			src := g.grid.cells[y*g.grid.width+x]
			i := dy*ui.grid.width+dx
			h := ui_highlight(ui, src.highlight)
			if h.blend > 0 && have_base {
				behind := ui_highlight(ui, base[i].highlight)
				text, hl := src.text, src.highlight
				fg := blend_color(h.foreground, behind.foreground, h.blend)
				if src.text == " " {
					text, hl = base[i].text, base[i].highlight
					fg = blend_color(h.background, behind.foreground, h.blend)
				}
				grid_set(&ui.grid, dy, dx, text, hl)
				ui.grid.cells[i].colors = {fg, blend_color(h.background, behind.background, h.blend), blend_color(h.special, behind.special, h.blend)}
				ui.grid.cells[i].blended = true
			} else {
				grid_set(&ui.grid, dy, dx, src.text, src.highlight)
				ui.grid.cells[i].blended = false
			}
		}}
	}
	row, col := ui_grid_position(ui, ui.cursor_grid)
	ui.cursor_row = int(math.floor(row))+ui.cursor_local[0]
	ui.cursor_col = int(math.floor(col))+ui.cursor_local[1]
	if g, found := ui.grids[ui.cursor_grid]; found && g.kind == .External {ui.cursor_row, ui.cursor_col = -1, -1}
}
ui_cell_highlight :: proc(ui: ^UI, cell: Cell) -> Highlight {
	h := ui_highlight(ui, cell.highlight)
	if cell.blended {h.foreground, h.background, h.special = cell.colors[0], cell.colors[1], cell.colors[2]}
	return h
}
ui_hit_grid :: proc(ui: ^UI, row, col: int) -> (grid, local_row, local_col: int) {
	layers := ui_grid_layers(ui)
	for i := len(layers)-1; i >= 0; i -= 1 {
		g := layers[i]
		if !g.mouse_enabled {continue}
		r, c := ui_grid_position(ui, g.id)
		y, x := row-int(math.floor(r)), col-int(math.floor(c))
		if y >= 0 && x >= 0 && y < g.grid.height && x < g.grid.width {return g.id, y, x}
	}
	return 1, row, col
}
grid_scroll :: proc(g: ^Grid, top, bottom, left, right, rows, columns: int) {
	t, b := clamp(top, 0, g.height), clamp(bottom, 0, g.height)
	l, r := clamp(left, 0, g.width), clamp(right, 0, g.width)
	if t >= b || l >= r {return}
	// Move ownership through a snapshot, so overlapping scroll regions are safe.
	snapshot := make([]Cell, (b-t)*(r-l))
	defer delete(snapshot)
	for y in t..<b {for x in l..<r {
		i := y*g.width+x
		snapshot[(y-t)*(r-l)+x-l] = g.cells[i]; g.cells[i] = {}
	}}
	for y in t..<b {for x in l..<r {
		sy, sx := y+rows, x+columns
		if sy >= t && sy < b && sx >= l && sx < r {
			i := (sy-t)*(r-l)+sx-l
			g.cells[y*g.width+x] = snapshot[i]; snapshot[i] = {}
		}
	}}
	for &c in snapshot {cell_destroy(&c)}
}

highlight_parse :: proc(n: Node) -> Highlight {
	h := Highlight{foreground = -1, background = -1, special = -1}
	fields := []struct {key: cstring, field: ^int}{
		{"foreground", &h.foreground}, {"background", &h.background}, {"special", &h.special}, {"blend", &h.blend},
	}
	for field in fields {v := nd_get(n, field.key); if nd_kind(v) != .Missing {field.field^ = node_int(v)}}
	h.reverse = node_bool(nd_get(n, "reverse"))
	h.bold = node_bool(nd_get(n, "bold")); h.italic = node_bool(nd_get(n, "italic"))
	h.underline = node_bool(nd_get(n, "underline")); h.undercurl = node_bool(nd_get(n, "undercurl"))
	h.strikethrough = node_bool(nd_get(n, "strikethrough"))
	h.underdouble = node_bool(nd_get(n, "underdouble"))
	h.underdotted = node_bool(nd_get(n, "underdotted")); h.underdashed = node_bool(nd_get(n, "underdashed"))
	h.dim = node_bool(nd_get(n, "dim")); h.blink = node_bool(nd_get(n, "blink"))
	h.conceal = node_bool(nd_get(n, "conceal")); h.overline = node_bool(nd_get(n, "overline"))
	h.altfont = node_bool(nd_get(n, "altfont")); h.url = strings.clone(node_string(nd_get(n, "url")))
	return h
}
ui_highlight :: proc(ui: ^UI, id: int) -> Highlight {
	h, ok := ui.highlights[id]
	if !ok {h = {foreground = -1, background = -1, special = -1}}
	return ui_resolve_highlight(ui, h)
}
ui_resolve_highlight :: proc(ui: ^UI, attrs: Highlight) -> Highlight {
	h := attrs
	if h.foreground < 0 {h.foreground = ui.foreground}
	if h.background < 0 {h.background = ui.background}
	if h.special < 0 {h.special = ui.special}
	if h.reverse {h.foreground, h.background = h.background, h.foreground}
	if h.dim {h.foreground = blend_color(h.foreground, h.background, 50)}
	return h
}
blend_color :: proc(front, back, percent: int) -> int {
	p := clamp(percent, 0, 100)
	result := 0
	shifts := []uint{0, 8, 16}
	for shift in shifts {
		channel := (((front>>shift)&255)*(100-p)+((back>>shift)&255)*p)/100
		result |= channel<<shift
	}
	return result
}

ui_event :: proc(ui: ^UI, name: string, a: Node) {
	if name != "flush" {ui.flushed = false}
	switch name {
	case "grid_resize":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		grid_resize(&g.grid, node_int(node_at(a, 1)), node_int(node_at(a, 2)))
	case "grid_clear":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		for &c in g.grid.cells {cell_destroy(&c)}
	case "grid_destroy":
		id := node_int(node_at(a, 0))
		if g, ok := ui.grids[id]; ok {grid_destroy(&g.grid); delete(g.anchor); free(g); delete_key(&ui.grids, id)}
	case "grid_line":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		row, col := node_int(node_at(a, 1)), node_int(node_at(a, 2))
		cells := node_at(a, 3)
		hl := 0
		for i in 0..<node_count(cells) {
			cell := node_at(cells, i)
			text := node_string(node_at(cell, 0))
			if node_count(cell) > 1 {hl = node_int(node_at(cell, 1))}
			repeat := 1
			if node_count(cell) > 2 {repeat = node_int(node_at(cell, 2))}
			for _ in 0..<min(repeat, g.grid.width) {grid_set(&g.grid, row, col, text, hl); col += 1}
		}
	case "grid_scroll":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		grid_scroll(&g.grid, node_int(node_at(a, 1)), node_int(node_at(a, 2)), node_int(node_at(a, 3)), node_int(node_at(a, 4)), node_int(node_at(a, 5)), node_int(node_at(a, 6)))
	case "grid_cursor_goto":
		ui.cursor_grid = node_int(node_at(a, 0))
		ui.cursor_local = {node_int(node_at(a, 1)), node_int(node_at(a, 2))}
	case "win_pos":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		g.window = node_handle(node_at(a, 1)); g.kind = .Split; g.visible = true
		g.row, g.col = node_number(node_at(a, 2)), node_number(node_at(a, 3))
		g.mouse_enabled = true
	case "win_float_pos":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		g.window = node_handle(node_at(a, 1)); g.kind = .Float; g.visible = true
		delete(g.anchor); g.anchor = strings.clone(node_string(node_at(a, 2)))
		g.anchor_grid = node_int(node_at(a, 3))
		g.anchor_row, g.anchor_col = node_number(node_at(a, 4)), node_number(node_at(a, 5))
		g.mouse_enabled = node_bool(node_at(a, 6)); g.zindex = node_int(node_at(a, 7))
		g.compindex = node_int_or_index(a, 8, g.zindex)
		g.screen_position = node_count(a) > 10
		if g.screen_position {g.row, g.col = node_number(node_at(a, 9)), node_number(node_at(a, 10))}
	case "win_external_pos":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		g.window = node_handle(node_at(a, 1)); g.kind = .External; g.visible = true
	case "win_hide", "win_close":
		if g, ok := ui.grids[node_int(node_at(a, 0))]; ok {g.visible = false}
	case "msg_set_pos":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		g.kind = .Message; g.visible = true; g.row = node_number(node_at(a, 1)); g.col = 0
		g.zindex = node_int_or_index(a, 4, 200); g.compindex = node_int_or_index(a, 5, 200)
	case "win_viewport":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		for i in 0..<6 {g.viewport[i] = node_int_or_index(a, i+2, 0)}
	case "win_viewport_margins":
		g := ui_grid(ui, node_int(node_at(a, 0)))
		for i in 0..<4 {g.margins[i] = node_int(node_at(a, i+2))}
	case "hl_attr_define":
		id := node_int(node_at(a, 0)); delete(ui.highlights[id].url)
		ui.highlights[id] = highlight_parse(node_at(a, 1))
	case "hl_group_set":
		group := node_string(node_at(a, 0))
		if _, exists := ui.highlight_groups[group]; !exists {group = strings.clone(group)}
		ui.highlight_groups[group] = node_int(node_at(a, 1))
	case "default_colors_set":
		ui.foreground = node_int(node_at(a, 0)); ui.background = node_int(node_at(a, 1)); ui.special = node_int(node_at(a, 2))
		if ui.foreground < 0 {ui.foreground = 0xffffff}; if ui.background < 0 {ui.background = 0}; if ui.special < 0 {ui.special = ui.foreground}
	case "mode_info_set":
		for m in ui.modes {delete(m.shape)}; delete(ui.modes)
		ui.cursor_style_enabled = node_bool(node_at(a, 0))
		modes := node_at(a, 1); ui.modes = make([]Cursor_Mode, node_count(modes))
		for &mode, i in ui.modes {
			n := node_at(modes, i)
			mode.shape = strings.clone(node_string(nd_get(n, "cursor_shape")))
			mode.percentage = node_int_or(nd_get(n, "cell_percentage"), 100)
			mode.attr_id = node_int_or(nd_get(n, "attr_id"), 0)
			mode.blinkwait = node_int_or(nd_get(n, "blinkwait"), 0)
			mode.blinkon = node_int_or(nd_get(n, "blinkon"), 0); mode.blinkoff = node_int_or(nd_get(n, "blinkoff"), 0)
		}
	case "mode_change": ui.mode_index = node_int(node_at(a, 1))
	case "busy_start": ui.busy = true
	case "busy_stop": ui.busy = false
	case "mouse_on": ui.mouse = true
	case "mouse_off": ui.mouse = false
	case "bell", "visual_bell": ui.bell = true
	case "set_title": delete(ui.title); ui.title = strings.clone(node_string(node_at(a, 0)))
	case "connect", "restart":
		delete(ui.reconnect_address); ui.reconnect_address = strings.clone(node_string(node_at(a, 0)))
		ui.restart = name == "restart"
	case "option_set":
		option := node_string(node_at(a, 0))
		if option == "mousehide" {ui.mousehide = node_bool(node_at(a, 1))}
		if option == "mousemoveevent" {ui.mousemoveevent = node_bool(node_at(a, 1))}
		if option == "mousefocus" {ui.mousefocus = node_bool(node_at(a, 1))}
		if option == "linespace" {ui.linespace = node_int(node_at(a, 1)); ui.font_changed = true}
		if option == "guifontwide" {delete(ui.guifontwide); ui.guifontwide = strings.clone(node_string(node_at(a, 1))); ui.font_changed = true}
		if node_string(node_at(a, 0)) == "showtabline" {ui.showtabline = node_int(node_at(a, 1))}
		if node_string(node_at(a, 0)) == "ambiwidth" {ui.ambiwidth_double = node_string(node_at(a, 1)) == "double"}
		if node_string(node_at(a, 0)) == "guifont" {
			delete(ui.guifont); ui.guifont = strings.clone(node_string(node_at(a, 1))); ui.font_changed = true
		}
	case "flush":
		if ui.widgets.empty_pending && !ui.widgets.nonempty_seen {messages_clear(&ui.widgets.messages)}
		ui.widgets.empty_pending = false; ui.widgets.nonempty_seen = false
		ui_compose(ui); ui.flushed = true; return
	case: if !widgets_event(ui, name, a) {return}
	}
	ui.dirty = true
}
node_int_or :: proc(n: Node, fallback: int) -> int {
	if nd_kind(n) == .Missing || nd_kind(n) == .Nil {return fallback}
	return node_int(n)
}
ui_redraw :: proc(ui: ^UI, events: Node) {
	// A previous flush cannot authorize presentation of this incomplete frame.
	ui.flushed = false
	for i in 0..<node_count(events) {
		event := node_at(events, i)
		name := node_string(node_at(event, 0))
		for j in 1..<node_count(event) {ui_event(ui, name, node_at(event, j))}
	}
}

node_int_or_index :: proc(array: Node, index, fallback: int) -> int {
	if node_count(array) <= index {return fallback}
	return node_int(node_at(array, index))
}
