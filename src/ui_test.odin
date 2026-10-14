package main

import "core:testing"

ui_apply :: proc(ui: ^UI, events: []Value) {
	data := test_encode(Value(events)); defer delete(data)
	s := Test_Stream{data = data, available = len(data), chunk = len(data)}
	r := nd_reader_new(test_read, &s); defer nd_reader_free(r)
	assert(nd_reader_parse(r) == 1)
	ui_redraw(ui, nd_reader_root(r))
	assert(nd_reader_error(r) == 0)
}

@(test)
test_redraw_requires_current_flush :: proc(t: ^testing.T) {
	ui: UI; ui_init(&ui); defer ui_destroy(&ui)
	ui_apply(&ui, {[]Value{"grid_resize", []Value{i64(1), i64(3), i64(1)}}, []Value{"flush", []Value{}}})
	testing.expect(t, ui.flushed)
	ui_apply(&ui, {[]Value{"grid_line", []Value{i64(1), i64(0), i64(0), []Value{[]Value{"x", i64(0)}}}}})
	testing.expect(t, !ui.flushed)
	ui_apply(&ui, {[]Value{"flush", []Value{}}})
	testing.expect(t, ui.flushed)
	ui_apply(&ui, {[]Value{"flush", []Value{}}, []Value{"grid_clear", []Value{i64(1)}}})
	testing.expect(t, !ui.flushed)
}

@(test)
test_neovim_012_highlight_attributes :: proc(t: ^testing.T) {
	ui: UI; ui_init(&ui); defer ui_destroy(&ui)
	attrs := make(map[string]Value); defer delete(attrs)
	attrs["foreground"] = i64(0xff8040); attrs["background"] = i64(0x102030)
	attrs["dim"] = true; attrs["blink"] = true; attrs["conceal"] = true; attrs["overline"] = true
	ui_apply(&ui, {[]Value{"hl_attr_define", []Value{i64(7), attrs}}, []Value{"flush", []Value{}}})
	h := ui_highlight(&ui, 7)
	testing.expect(t, h.dim && h.blink && h.conceal && h.overline)
	testing.expect(t, h.foreground == 0x875038)
	testing.expect(t, !highlight_text_visible(h, 0))
	h.conceal = false
	testing.expect(t, highlight_text_visible(h, 499))
	testing.expect(t, !highlight_text_visible(h, 500))
	testing.expect(t, highlight_text_visible(h, 1000))
}

@(test)
test_multigrid_layers_cursor_and_hit_testing :: proc(t: ^testing.T) {
	ui: UI; ui_init(&ui); defer ui_destroy(&ui)
	ui_apply(&ui, {
		[]Value{"grid_resize", []Value{i64(1), i64(8), i64(4)}, []Value{i64(2), i64(4), i64(2)}, []Value{i64(3), i64(2), i64(1)}},
		[]Value{"grid_line", []Value{i64(2), i64(0), i64(0), []Value{[]Value{"a", i64(0), i64(4)}}}, []Value{i64(3), i64(0), i64(0), []Value{[]Value{"f", i64(0), i64(2)}}}},
		[]Value{"win_pos", []Value{i64(2), i64(100), i64(1), i64(1), i64(4), i64(2)}},
		[]Value{"win_float_pos", []Value{i64(3), i64(101), "NW", i64(2), i64(0), i64(1), true, i64(50), i64(1), i64(1), i64(2)}},
		[]Value{"grid_cursor_goto", []Value{i64(3), i64(0), i64(1)}},
		[]Value{"flush", []Value{}},
	})
	testing.expect(t, ui.grid.cells[9].text == "a" && ui.grid.cells[10].text == "f")
	testing.expect(t, ui.cursor_row == 1 && ui.cursor_col == 3)
	grid, row, col := ui_hit_grid(&ui, 1, 3)
	testing.expect(t, grid == 3 && row == 0 && col == 1)
	ui_apply(&ui, {[]Value{"win_hide", []Value{i64(3)}}, []Value{"flush", []Value{}}})
	testing.expect(t, ui.grid.cells[10].text == "a")
	grid, row, col = ui_hit_grid(&ui, 1, 3)
	testing.expect(t, grid == 2 && row == 0 && col == 2)
	ui_apply(&ui, {[]Value{"grid_destroy", []Value{i64(3)}}, []Value{"flush", []Value{}}})
	testing.expect(t, !(3 in ui.grids))
}
