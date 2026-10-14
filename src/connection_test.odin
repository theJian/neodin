package main

import "core:testing"
import "core:time"
import "core:os"

@(test)
test_tcp_and_local_socket_connections :: proc(t: ^testing.T) {
	server: RPC; ui: UI
	if !rpc_start(&server, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&server)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&server, 50, 12)
	testing.expect(t, editor_wait(&server, &ui))
	addresses := []string{"return vim.fn.serverstart('127.0.0.1:0')", "return vim.fn.serverstart()"}
	for code in addresses {
		address := editor_eval(&server, &ui, code); defer delete(address)
		testing.expect(t, address != "")
		remote: RPC; view: UI
		if !rpc_connect(&remote, address) {testing.expect(t, false); continue}
		ui_init(&view)
		rpc_attach(&remote, 50, 12)
		testing.expect(t, editor_wait(&remote, &view))
		rpc_input(&remote, "iConnected<Esc>")
		testing.expect(t, editor_wait(&remote, &view))
		result := editor_eval(&remote, &view, "return vim.api.nvim_get_current_line()")
		testing.expect(t, result == "Connected")
		delete(result)
		rpc_lua(&remote, "vim.api.nvim_buf_set_lines(0,0,-1,false,{''})")
		testing.expect(t, editor_wait(&remote, &view))
		rpc_destroy(&remote); ui_destroy(&view)
	}
}

@(test)
test_neovim_012_restart_and_reattach :: proc(t: ^testing.T) {
	r: RPC; ui: UI
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 50, 12)
	testing.expect(t, editor_wait(&r, &ui))
	rpc_lua(&r, "vim.schedule(function() vim.cmd('restart') end)")
	start := time.tick_now()
	for time.tick_since(start) < 5*time.Second {
		editor_pump(&r, &ui)
		state, _ := os.process_wait(r.process, 0)
		if state.exited {r.exited = true; break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, r.exited && ui.restart && ui.reconnect_address != "")
	if !r.exited || ui.reconnect_address == "" {return}
	address := ui.reconnect_address
	rpc_destroy(&r)
	if !rpc_connect(&r, address) {testing.expect(t, false); return}
	rpc_attach(&r, 50, 12)
	testing.expect(t, editor_wait(&r, &ui))
	result := editor_eval(&r, &ui, "return tostring(vim.version().minor)")
	testing.expect(t, result == "12"); delete(result)
	rpc_lua(&r, "vim.schedule(function() vim.cmd('qall!') end)")
	for time.tick_since(start) < 5*time.Second && nd_transport_eof(r.transport) == 0 {
		editor_pump(&r, &ui); time.sleep(time.Millisecond)
	}
	testing.expect(t, nd_transport_eof(r.transport) != 0)
}

@(test)
test_neovim_012_connect_event :: proc(t: ^testing.T) {
	server: RPC; server_ui: UI
	if !rpc_start(&server, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&server)
	ui_init(&server_ui); defer ui_destroy(&server_ui)
	rpc_attach(&server, 50, 12)
	testing.expect(t, editor_wait(&server, &server_ui))
	address := editor_eval(&server, &server_ui, "return vim.fn.serverstart()"); defer delete(address)
	app := App{columns = 50, rows = 12}
	if !rpc_start(&app.rpc, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&app.rpc)
	ui_init(&app.ui); defer ui_destroy(&app.ui)
	rpc_attach(&app.rpc, 50, 12)
	testing.expect(t, editor_wait(&app.rpc, &app.ui))
	rpc_lua(&app.rpc, "local addr=...; vim.schedule(function() vim.cmd.connect({args={addr}}) end)", {address})
	start := time.tick_now()
	for app.ui.reconnect_address == "" && time.tick_since(start) < 5*time.Second {
		editor_pump(&app.rpc, &app.ui); time.sleep(time.Millisecond)
	}
	testing.expect(t, app.ui.reconnect_address == address && !app.ui.restart)
	if app.ui.reconnect_address == "" {return}
	testing.expect(t, app_reconnect(&app))
	testing.expect(t, editor_wait(&app.rpc, &app.ui))
	rpc_input(&app.rpc, "iTransferred<Esc>")
	testing.expect(t, editor_wait(&app.rpc, &app.ui))
	result := editor_eval(&app.rpc, &app.ui, "return vim.api.nvim_get_current_line()")
	testing.expect(t, result == "Transferred"); delete(result)
}
