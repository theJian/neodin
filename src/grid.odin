package main

import "core:strings"

Cell :: struct {text: string, highlight: int}
Highlight :: struct {
	foreground, background, special: int,
	reverse, bold, italic, underline, undercurl, strikethrough: bool,
	underdouble, underdotted, underdashed: bool,
	blend: int,
}
Cursor_Mode :: struct {
	shape: string,
	percentage, attr_id, blinkwait, blinkon, blinkoff: int,
}
Grid :: struct {width, height: int, cells: []Cell}
UI :: struct {
	grid: Grid,
	highlights: map[int]Highlight,
	foreground, background, special: int,
	cursor_row, cursor_col: int,
	modes: []Cursor_Mode,
	mode_index: int,
	busy, mouse, dirty, flushed, bell: bool,
	title, guifont: string,
	font_changed: bool,
}

ui_init :: proc(ui: ^UI) {
	ui.highlights = make(map[int]Highlight)
	ui.foreground = 0xffffff; ui.background = 0x181818; ui.special = 0xffffff
	ui.title = strings.clone("Neodin")
}
cell_destroy :: proc(c: ^Cell) {delete(c.text); c^ = {}}
grid_destroy :: proc(g: ^Grid) {
	for &cell in g.cells {cell_destroy(&cell)}
	delete(g.cells); g^ = {}
}
ui_destroy :: proc(ui: ^UI) {
	grid_destroy(&ui.grid); delete(ui.highlights)
	for mode in ui.modes {delete(mode.shape)}
	delete(ui.modes); delete(ui.title); delete(ui.guifont)
}
grid_resize :: proc(g: ^Grid, width, height: int) {
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
	c^ = {strings.clone(text), highlight}
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
	return h
}
ui_highlight :: proc(ui: ^UI, id: int) -> Highlight {
	h, ok := ui.highlights[id]
	if !ok {h = {foreground = -1, background = -1, special = -1}}
	if h.foreground < 0 {h.foreground = ui.foreground}
	if h.background < 0 {h.background = ui.background}
	if h.special < 0 {h.special = ui.special}
	if h.reverse {h.foreground, h.background = h.background, h.foreground}
	return h
}

ui_event :: proc(ui: ^UI, name: string, a: Node) {
	switch name {
	case "grid_resize":
		if node_int(node_at(a, 0)) == 1 {grid_resize(&ui.grid, node_int(node_at(a, 1)), node_int(node_at(a, 2)))}
	case "grid_clear":
		if node_int(node_at(a, 0)) == 1 {for &c in ui.grid.cells {cell_destroy(&c)}}
	case "grid_line":
		if node_int(node_at(a, 0)) != 1 {return}
		row, col := node_int(node_at(a, 1)), node_int(node_at(a, 2))
		cells := node_at(a, 3)
		hl := 0
		for i in 0..<node_count(cells) {
			cell := node_at(cells, i)
			text := node_string(node_at(cell, 0))
			if node_count(cell) > 1 {hl = node_int(node_at(cell, 1))}
			repeat := 1
			if node_count(cell) > 2 {repeat = node_int(node_at(cell, 2))}
			for _ in 0..<min(repeat, ui.grid.width) {grid_set(&ui.grid, row, col, text, hl); col += 1}
		}
	case "grid_scroll":
		if node_int(node_at(a, 0)) == 1 {
			grid_scroll(&ui.grid, node_int(node_at(a, 1)), node_int(node_at(a, 2)), node_int(node_at(a, 3)), node_int(node_at(a, 4)), node_int(node_at(a, 5)), node_int(node_at(a, 6)))
		}
	case "grid_cursor_goto":
		ui.cursor_row = node_int(node_at(a, 1)); ui.cursor_col = node_int(node_at(a, 2))
	case "hl_attr_define": ui.highlights[node_int(node_at(a, 0))] = highlight_parse(node_at(a, 1))
	case "default_colors_set":
		ui.foreground = node_int(node_at(a, 0)); ui.background = node_int(node_at(a, 1)); ui.special = node_int(node_at(a, 2))
		if ui.foreground < 0 {ui.foreground = 0xffffff}; if ui.background < 0 {ui.background = 0}; if ui.special < 0 {ui.special = ui.foreground}
	case "mode_info_set":
		for m in ui.modes {delete(m.shape)}; delete(ui.modes)
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
	case "option_set":
		if node_string(node_at(a, 0)) == "guifont" {
			delete(ui.guifont); ui.guifont = strings.clone(node_string(node_at(a, 1))); ui.font_changed = true
		}
	case "flush": ui.flushed = true; return
	case: return
	}
	ui.dirty = true
}
node_int_or :: proc(n: Node, fallback: int) -> int {
	if nd_kind(n) == .Missing || nd_kind(n) == .Nil {return fallback}
	return node_int(n)
}
ui_redraw :: proc(ui: ^UI, events: Node) {
	for i in 0..<node_count(events) {
		event := node_at(events, i)
		name := node_string(node_at(event, 0))
		for j in 1..<node_count(event) {ui_event(ui, name, node_at(event, j))}
	}
}
