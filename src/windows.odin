package main

import "core:strings"
import "core:c"
import sdl "vendor:sdl3"

app_resize_window :: proc(app: ^App, d: ^Display) {
	if !d.external {app_resize(app); return}
	columns, rows := display_size(d)
	g, ok := app.ui.grids[d.grid_id]
	if ok && app.rpc.attached && (columns != g.grid.width || rows != g.grid.height) {
		_ = rpc_request(&app.rpc, "nvim_ui_try_resize_grid", {i64(d.grid_id), i64(columns), i64(rows)})
		app.ui.flushed = false
	}
}
app_sync_windows :: proc(app: ^App) -> bool {
	remove := make([dynamic]int, allocator = context.temp_allocator)
	for id, d in app.external_windows {
		g, ok := app.ui.grids[id]
		if !ok || !g.visible || g.kind != .External {display_destroy(d); free(d); append(&remove, id)}
	}
	for id in remove {delete_key(&app.external_windows, id)}
	for id, g in app.ui.grids {
		if !g.visible || g.kind != .External {continue}
		d, exists := app.external_windows[id]
		if !exists {
			d = new(Display); d.external = true; d.grid_id = id
			config := app.config; config.columns = max(g.grid.width, 12); config.rows = max(g.grid.height, 3); config.fullscreen = false
			if !display_create(d, config) {display_destroy(d); free(d); return false}
			app.external_windows[id] = d
		}
		w, h: c.int; _ = sdl.GetWindowSize(d.window, &w, &h)
		width := c.int((f32(g.grid.width)*d.cell_width+2*d.padding)/d.density)
		height := c.int((f32(g.grid.height)*d.cell_height+2*d.padding)/d.density)
		if w != width || h != height {_ = sdl.SetWindowSize(d.window, width, height)}
	}
	return true
}
app_draw_external :: proc(app: ^App) {
	for id, d in app.external_windows {
		g := app.ui.grids[id]
		view := app.ui; view.grid = g.grid
		view.cursor_row, view.cursor_col = -1, -1
		if view.cursor_grid == id {view.cursor_row, view.cursor_col = view.cursor_local[0], view.cursor_local[1]}
		_ = sdl.SetWindowTitle(d.window, strings.clone_to_cstring(app.ui.title, context.temp_allocator))
		if app.ui.dirty {d.cursor_epoch = sdl.GetTicks()}
		display_draw(d, &view, app.config, app.preedit if view.cursor_grid == id else "")
	}
}
