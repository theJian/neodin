package main

import "core:testing"
import "core:strings"
import "core:time"

@(test)
test_native_cmdline_and_unicode :: proc(t: ^testing.T) {
	ui: UI; ui_init(&ui); defer ui_destroy(&ui)
	ui_apply(&ui, {
		[]Value{"cmdline_show", []Value{[]Value{[]Value{i64(0), "界é"}}, i64(3), ":", "", i64(0), i64(1), i64(0)}},
		[]Value{"cmdline_show", []Value{[]Value{[]Value{i64(0), "1+2"}}, i64(3), "=", "", i64(0), i64(2), i64(0)}},
		[]Value{"flush", []Value{}},
	})
	testing.expect(t, widgets_active_cmdline(&ui.widgets).level == 2)
	ui_apply(&ui, {[]Value{"cmdline_hide", []Value{i64(2), false}}, []Value{"flush", []Value{}}})
	line := widgets_active_cmdline(&ui.widgets)
	testing.expect(t, line.level == 1 && line.pos == 3)
	testing.expect(t, text_cells(rich_plain(line.content), false, line.pos) == 2)
	testing.expect(t, text_cells("é界👨‍👩‍👧‍👦") == 5)
	testing.expect(t, len(graphemes("é界👨‍👩‍👧‍👦")) == 3)
}

@(test)
test_message_identity_append_and_clear :: proc(t: ^testing.T) {
	ui: UI; ui_init(&ui); defer ui_destroy(&ui)
	ui_apply(&ui, {
		[]Value{"msg_show", []Value{"progress", []Value{[]Value{i64(0), "Loading"}}, false, false, false, "job", ""}},
		[]Value{"msg_show", []Value{"echo", []Value{[]Value{i64(0), "other"}}, false, false, false, i64(0), "typed_cmd"}},
		[]Value{"msg_show", []Value{"progress", []Value{[]Value{i64(0), "Done"}}, false, false, false, "job", ""}},
		[]Value{"msg_show", []Value{"echo", []Value{[]Value{i64(0), "!"}}, false, false, true, i64(0), ""}},
		[]Value{"msg_showmode", []Value{[]Value{[]Value{i64(0), "INSERT"}}}},
		[]Value{"flush", []Value{}},
	})
	testing.expect(t, len(ui.widgets.messages) == 2)
	testing.expect(t, rich_plain(ui.widgets.messages[0].content) == "Done")
	testing.expect(t, rich_plain(ui.widgets.messages[1].content) == "other!")
	ui_apply(&ui, {[]Value{"msg_clear", []Value{}}, []Value{"flush", []Value{}}})
	testing.expect(t, len(ui.widgets.messages) == 0 && rich_plain(ui.widgets.showmode) == "INSERT")
}

@(test)
test_neovim_012_external_widgets :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 60, 18)
	testing.expect(t, editor_wait(&r, &ui))
	rpc_input(&r, ":echo '界'")
	testing.expect(t, editor_wait(&r, &ui))
	line := widgets_active_cmdline(&ui.widgets)
	testing.expect(t, line != nil)
	if line != nil {testing.expect(t, rich_plain(line.content) == "echo '界'")}
	rpc_input(&r, "<Esc>")
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.cmd('tabnew'); vim.api.nvim_echo({{'first','WarningMsg'}},true,{}); vim.cmd('echon \"second\"'); vim.cmd('messages')")
	testing.expect(t, editor_wait(&r, &ui))
	testing.expect(t, len(ui.widgets.tabs) == 2 && ui.widgets.current_tab == ui.widgets.tabs[1].handle)
	testing.expect(t, ui.widgets.history_visible && len(ui.widgets.history) > 0)
	testing.expect(t, strings.contains(rich_plain(ui.widgets.history[len(ui.widgets.history)-1].content), "first"))
	rpc_input(&r, "i")
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.fn.complete(1, {{word='alpha',kind='v',menu='source',info='details'}, {word='beta'}})")
	testing.expect(t, editor_wait(&r, &ui))
	testing.expect(t, ui.widgets.popup.visible && len(ui.widgets.popup.items) == 2)
	if len(ui.widgets.popup.items) > 0 {testing.expect(t, ui.widgets.popup.items[0].info == "details")}
	rpc_input(&r, "<C-e><Esc>")
	testing.expect(t, editor_wait(&r, &ui))
	testing.expect(t, !ui.widgets.popup.visible)
}

@(test)
test_neovim_012_progress_and_floating_statusline :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 60, 18)
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.api.nvim_echo({{'Starting'}},false,{kind='progress',source='neodin-test',id='build',title='Build',status='running',percent=10})")
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.api.nvim_echo({{'Finished'}},false,{kind='progress',source='neodin-test',id='build',title='Build',status='success',percent=100})")
	testing.expect(t, editor_wait(&r, &ui))
	count := 0
	finished := false
	deadline := time.tick_now()
	for !finished && time.tick_since(deadline) < 5*time.Second {
		editor_pump(&r, &ui); count = 0
		for message in ui.widgets.messages {
			if message.id == "s:build" {
				count += 1
				finished = strings.contains(rich_plain(message.content), "Finished") && !strings.contains(rich_plain(message.content), "Starting")
			}
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, finished)
	testing.expect(t, count == 1)
	rpc_lua(&r, "local b=vim.api.nvim_create_buf(false,true); vim.api.nvim_buf_set_lines(b,0,-1,false,{'Float text'}); local w=vim.api.nvim_open_win(b,true,{relative='editor',row=2,col=3,width=20,height=4,border='rounded'}); vim.wo[w].statusline='Floating status'; vim.wo[w].winblend=20; vim.o.laststatus=2")
	testing.expect(t, editor_wait(&r, &ui))
	found := false
	for _, g in ui.grids {
		if g.kind != .Float || !g.visible {continue}
		b := strings.builder_make(context.temp_allocator)
		for cell in g.grid.cells {strings.write_string(&b, cell.text)}
		if strings.contains(strings.to_string(b), "Floating status") {found = true}
	}
	testing.expect(t, found)
}

@(test)
test_neovim_012_core_ui2 :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 60, 18)
	testing.expect(t, editor_wait(&r, &ui))
	result := editor_eval(&r, &ui, "require('vim._core.ui2').enable(); vim.api.nvim_echo({{'UI2 message'}},true,{}); return 'enabled'")
	testing.expect(t, result == "enabled"); delete(result)
	rpc_input(&r, ":echo 'ui2 command'")
	testing.expect(t, editor_wait(&r, &ui))
	found := false
	start := time.tick_now()
	for !found && time.tick_since(start) < 5*time.Second {
		editor_pump(&r, &ui)
		for _, g in ui.grids {
			b := strings.builder_make(context.temp_allocator)
			for cell in g.grid.cells {strings.write_string(&b, cell.text)}
			if strings.contains(strings.to_string(b), "echo 'ui2 command'") {found = true}
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, found)
	rpc_input(&r, "<Esc>")
	testing.expect(t, editor_wait(&r, &ui))
	result = editor_eval(&r, &ui, "return tostring(type(vim.pack.add)=='function' and type(vim.snippet.expand)=='function')")
	testing.expect(t, result == "true"); delete(result)
}
