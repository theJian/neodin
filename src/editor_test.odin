package main

import "core:strings"
import "core:testing"
import "core:time"

editor_pump :: proc(r: ^RPC, ui: ^UI) {
	for _ in 0..<256 {
		if nd_reader_parse(r.reader) == 0 {break}
		m := nd_reader_root(r.reader)
		if node_int(node_at(m, 0)) == 1 {rpc_response(r, m)}
		if node_int(node_at(m, 0)) == 2 && node_string(node_at(m, 1)) == "redraw" {ui_redraw(ui, node_at(m, 2))}
	}
	rpc_flush_input(r)
}
editor_wait :: proc(r: ^RPC, ui: ^UI) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5*time.Second {
		editor_pump(r, ui)
		if r.attached && ui.flushed && len(r.pending) == 0 && len(r.input_queue) == 0 {return true}
		if nd_reader_error(r.reader) != 0 {return false}
		time.sleep(time.Millisecond)
	}
	return false
}
editor_eval :: proc(r: ^RPC, ui: ^UI, code: string) -> string {
	id := rpc_request(r, "nvim_exec_lua", {code, []Value{}})
	start := time.tick_now()
	for time.tick_since(start) < 5*time.Second {
		for _ in 0..<256 {
			if nd_reader_parse(r.reader) == 0 {break}
			m := nd_reader_root(r.reader)
			if node_int(node_at(m, 0)) == 1 {
				if i64(node_int(node_at(m, 1))) == id {
					result := strings.clone(node_string(node_at(m, 3)))
					rpc_response(r, m); return result
				}
				rpc_response(r, m)
			}
			if node_int(node_at(m, 0)) == 2 && node_string(node_at(m, 1)) == "redraw" {ui_redraw(ui, node_at(m, 2))}
		}
		time.sleep(time.Millisecond)
	}
	return ""
}

@(test)
test_large_paste_and_ordered_input :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 50, 12)
	testing.expect(t, editor_wait(&r, &ui))
	text := strings.repeat("界<literal>é", 10000); defer delete(text)
	rpc_input(&r, "i")
	rpc_paste(&r, text)
	rpc_input(&r, "!<Esc>")
	testing.expect(t, editor_wait(&r, &ui))
	result := editor_eval(&r, &ui, "return vim.api.nvim_get_current_line()")
	defer delete(result)
	expected := strings.concatenate({text, "!"}); defer delete(expected)
	testing.expect(t, result == expected)
	// A second paste and undo verifies phase completion and undo grouping.
	rpc_paste(&r, "second paste")
	rpc_input(&r, "u")
	testing.expect(t, editor_wait(&r, &ui))
	after_undo := editor_eval(&r, &ui, "return vim.api.nvim_get_current_line()")
	defer delete(after_undo)
	testing.expect(t, after_undo == expected)
}

@(test)
test_splits_resize_mouse_and_terminal :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 50, 12)
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.api.nvim_buf_set_lines(0,0,-1,false,{'first','second','third'}); vim.cmd('vsplit'); vim.o.mouse='a'")
	_ = rpc_request(&r, "nvim_ui_try_resize", {i64(60), i64(16)})
	testing.expect(t, editor_wait(&r, &ui))
	testing.expect(t, ui.grid.width == 60 && ui.grid.height == 16 && ui.mouse)
	_ = rpc_request(&r, "nvim_input_mouse", {"left", "press", "", i64(0), i64(1), i64(1)})
	_ = rpc_request(&r, "nvim_input_mouse", {"left", "release", "", i64(0), i64(1), i64(1)})
	testing.expect(t, editor_wait(&r, &ui))
	position := editor_eval(&r, &ui, "return tostring(vim.api.nvim_win_get_cursor(0)[1])")
	defer delete(position)
	testing.expect(t, position == "2")
	_ = rpc_request(&r, "nvim_input_mouse", {"left", "press", "2", i64(0), i64(1), i64(2)})
	_ = rpc_request(&r, "nvim_input_mouse", {"left", "release", "2", i64(0), i64(1), i64(2)})
	testing.expect(t, editor_wait(&r, &ui))
	mode := editor_eval(&r, &ui, "return vim.fn.mode()")
	defer delete(mode)
	testing.expect(t, mode == "v")
	rpc_input(&r, "<Esc>")
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.cmd('enew'); vim.fn.jobstart({'nvim','--headless','--clean','+q'}, {term=true})")
	testing.expect(t, editor_wait(&r, &ui))
	type := editor_eval(&r, &ui, "return vim.bo.buftype")
	defer delete(type)
	testing.expect(t, type == "terminal")
}

@(test)
test_clipboard_provider_rpc :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 50, 12)
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.fn.has('clipboard')")
	rpc_lua(&r, CLIPBOARD_SETUP, {i64(r.channel)})
	testing.expect(t, editor_wait(&r, &ui))
	id := rpc_request(&r, "nvim_exec_lua", {"vim.fn.setreg('+', {'alpha','beta'}, 'V'); return vim.fn.getreg('+')", []Value{}})
	start := time.tick_now()
	copied, requested, replied := false, false, false
	for !replied && time.tick_since(start) < 5*time.Second {
		for _ in 0..<256 {
			if nd_reader_parse(r.reader) == 0 {break}
			m := nd_reader_root(r.reader)
			switch node_int(node_at(m, 0)) {
			case 0:
				if node_string(node_at(m, 2)) == "neodin_clipboard_get" {
					requested = true
					clipboard_reply(&r, i64(node_int(node_at(m, 1))), "alpha\nbeta\n", "V")
				}
			case 1:
				if i64(node_int(node_at(m, 1))) == id {
					replied = true
					testing.expect(t, node_string(node_at(m, 3)) == "alpha\nbeta\n")
				}
				rpc_response(&r, m)
			case 2:
				method, args := node_string(node_at(m, 1)), node_at(m, 2)
				if method == "redraw" {ui_redraw(&ui, args)}
				if method == "neodin_clipboard_set" {
					copied = true
					testing.expect(t, node_string(node_at(node_at(args, 0), 0)) == "alpha")
					testing.expect(t, node_string(node_at(args, 1)) == "V")
				}
			}
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, copied && requested && replied)
}

@(test)
test_cancel_close_preserves_unsaved_buffer :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 80, 16)
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.api.nvim_buf_set_lines(0,0,-1,false,{'unsaved work'})")
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, QUIT_COMMAND)
	start := time.tick_now()
	confirmation := false
	for time.tick_since(start) < 5*time.Second {
		editor_pump(&r, &ui)
		b := strings.builder_make(context.temp_allocator)
		for cell in ui.grid.cells {strings.write_string(&b, cell.text)}
		for message in ui.widgets.messages {strings.write_string(&b, rich_plain(message.content))}
		for _, line in ui.widgets.cmdlines {strings.write_string(&b, line.prompt); strings.write_string(&b, rich_plain(line.content))}
		if strings.contains(strings.to_string(b), "ancel") {confirmation = true; break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, confirmation)
	rpc_input(&r, "c")
	testing.expect(t, editor_wait(&r, &ui))
	result := editor_eval(&r, &ui, "return vim.api.nvim_get_current_line() .. ':' .. tostring(vim.bo.modified)")
	defer delete(result)
	testing.expect(t, result == "unsaved work:true")
}
