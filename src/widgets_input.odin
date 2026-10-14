package main

import sdl "vendor:sdl3"

rect_contains :: proc(rect: sdl.FRect, x, y: f32) -> bool {
	return rect.w > 0 && rect.h > 0 && x >= rect.x && y >= rect.y && x < rect.x+rect.w && y < rect.y+rect.h
}
widgets_input :: proc(app: ^App, event: ^sdl.Event, display: ^Display = nil) -> bool {
	d := display; if d == nil {d = &app.display}
	w := &app.ui.widgets
	#partial switch event.type {
	case .KEY_DOWN:
		if w.history_visible && !d.external {
			switch event.key.key {
			case sdl.K_ESCAPE, sdl.K_RETURN, sdl.K_Q:
				w.history_visible = false; app.ui.dirty = true; return true
			case sdl.K_UP, sdl.K_PAGEUP:
				w.message_scroll += 1 if event.key.key == sdl.K_UP else max(app.ui.grid.height/2, 1)
				app.ui.dirty = true; return true
			case sdl.K_DOWN, sdl.K_PAGEDOWN:
				w.message_scroll = max(0, w.message_scroll-(1 if event.key.key == sdl.K_DOWN else max(app.ui.grid.height/2, 1)))
				app.ui.dirty = true; return true
			}
		}
	case .MOUSE_BUTTON_DOWN:
		x, y := event.button.x*d.density, event.button.y*d.density
		if event.button.button == 1 {
			for tab in d.layout.tabs {
				if rect_contains(tab.rect, x, y) {_ = rpc_request(&app.rpc, "nvim_set_current_tabpage", {i64(tab.handle)}); return true}
			}
			if d.layout.popup_visible && rect_contains(d.layout.popup, x, y) {
				item := d.layout.popup_first+int((y-d.layout.popup.y)/d.cell_height)
				options := make(map[string]Value); defer delete(options)
				_ = rpc_request(&app.rpc, "nvim_select_popupmenu_item", {i64(item), true, true, options})
				return true
			}
		}
		if !d.external && (y < d.grid_top || y >= d.grid_top+f32(app.ui.grid.height)*d.cell_height) {return true}
	case .MOUSE_BUTTON_UP:
		if event.button.button == 1 {
			x, y := event.button.x*d.density, event.button.y*d.density
			if (!d.external && (y < d.grid_top || y >= d.grid_top+f32(app.ui.grid.height)*d.cell_height)) ||
				(d.layout.popup_visible && rect_contains(d.layout.popup, x, y)) {return true}
		}
	case .MOUSE_WHEEL:
		x, y := event.wheel.mouse_x*d.density, event.wheel.mouse_y*d.density
		if rect_contains(d.layout.message, x, y) {
			delta := int(event.wheel.integer_y)
			if event.wheel.direction == .FLIPPED {delta = -delta}
			w.message_scroll = max(0, w.message_scroll+delta)
			app.ui.dirty = true; return true
		}
		if d.layout.popup_visible && rect_contains(d.layout.popup, x, y) {
			delta := int(event.wheel.integer_y)
			if event.wheel.direction == .FLIPPED {delta = -delta}
			selected := clamp(w.popup.selected-delta, 0, len(w.popup.items)-1)
			options := make(map[string]Value); defer delete(options)
			_ = rpc_request(&app.rpc, "nvim_select_popupmenu_item", {i64(selected), false, false, options})
			return true
		}
	}
	return false
}
widgets_report_popup :: proc(app: ^App) {
	d := &app.display
	if external, ok := app.external_windows[app.ui.widgets.popup.grid]; ok {d = external}
	if !d.layout.popup_visible {app.popup_bounds = {}; return}
	rect := d.layout.popup
	bounds := [4]f64{f64(rect.w/d.cell_width), f64(rect.h/d.cell_height), f64((rect.y-d.grid_top)/d.cell_height), f64((rect.x-d.padding)/d.cell_width)}
	if bounds != app.popup_bounds {
		app.popup_bounds = bounds
		_ = rpc_request(&app.rpc, "nvim_ui_pum_set_height", {i64(d.layout.popup_rows)})
		_ = rpc_request(&app.rpc, "nvim_ui_pum_set_bounds", {bounds[0], bounds[1], bounds[2], bounds[3]})
	}
}
