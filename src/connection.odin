package main

import "core:strings"

app_reconnect :: proc(app: ^App) -> bool {
	address := strings.clone(app.ui.reconnect_address); defer delete(address)
	rpc_destroy(&app.rpc, false)
	for _, d in app.external_windows {display_destroy(d); free(d)}
	clear(&app.external_windows)
	ui_destroy(&app.ui); app.ui = {}; ui_init(&app.ui)
	app.popup_bounds = {}; app.mouse_button = 0; app.primary_window = 0
	delete(app.preedit); app.preedit = ""
	if !rpc_connect(&app.rpc, address) {return false}
	rpc_attach(&app.rpc, app.columns, app.rows)
	return true
}
