package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import "core:strconv"
import sdl "vendor:sdl3"

HELP :: `Neodin — a hardware accelerated Neovim GUI in Odin

Requires Neovim 0.12 or newer.

Usage: neodin [--config PATH] [--renderer NAME] [--] [Neovim arguments...]
       neodin --list-renderers

Config: $NEODIN_CONFIG, $XDG_CONFIG_HOME/neodin/config.json, or
        ~/.config/neodin/config.json (%APPDATA%/neodin on Windows).
Arguments after -- are passed unchanged to Neovim. Your usual init.lua loads.
Cmd-V (macOS) or Ctrl-Shift-V pastes the system clipboard without mappings.
Window close runs :confirm qall so unsaved changes can be saved or cancelled.
`
QUIT_COMMAND :: "vim.schedule(function() vim.cmd('confirm qall') end)"

App :: struct {
	rpc: RPC,
	ui: UI,
	display: Display,
	external_windows: map[int]^Display,
	config: Config,
	clipboard: Clipboard,
	preedit: string,
	clipboard_ready: bool,
	columns, rows: int,
	mouse_button: u8,
	primary_window: int,
	smoke, smoke_sent: bool,
	smoke_widgets: bool,
	smoke_external: bool,
	smoke_focus: bool,
	start: u64,
	runtime_font: bool,
	popup_bounds: [4]f64,
}
app_resize :: proc(app: ^App) {
	columns, rows := display_size(&app.display)
	if columns != app.columns || rows != app.rows {
		app.columns = columns; app.rows = rows
		if app.rpc.attached {_ = rpc_request(&app.rpc, "nvim_ui_try_resize", {i64(columns), i64(rows)})}
		app.ui.flushed = false
	}
}
app_event :: proc(app: ^App, event: ^sdl.Event) {
	r, d, ui := &app.rpc, &app.display, &app.ui
	window := sdl.GetWindowFromEvent(event^)
	for _, external in app.external_windows {if external.window == window {d = external; break}}
	view := app.ui
	if d.external {
		g, ok := app.ui.grids[d.grid_id]
		if !ok {return}
		view.grid = g.grid; ui = &view
	}
	if widgets_input(app, event, d) {return}
	mod := sdl.GetModState()
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		if r.attached {
			if d.external {rpc_lua(r, "local win=...; vim.schedule(function() local ok,err=pcall(vim.api.nvim_win_close,win,false); if not ok then vim.api.nvim_echo({{err,'ErrorMsg'}},true,{}) end end)", {i64(app.ui.grids[d.grid_id].window)})}
			else {rpc_lua(r, QUIT_COMMAND)}
		}
	case .KEY_DOWN:
		if app.preedit != "" {return}
		paste := event.key.key == sdl.K_V && event.key.mod&(sdl.KMOD_CTRL|sdl.KMOD_SHIFT) == (sdl.KMOD_CTRL|sdl.KMOD_SHIFT)
		when ODIN_OS == .Darwin {paste = paste || (event.key.key == sdl.K_V && event.key.mod&sdl.KMOD_GUI != {})}
		if paste {
			p := sdl.GetClipboardText(); defer sdl.free(p)
			rpc_paste(r, string(cstring(p)))
		} else {rpc_input(r, key_input(event.key, app.config.option_as_alt))}
	case .TEXT_INPUT:
		rpc_input(r, text_input(string(event.text.text)))
		delete(app.preedit); app.preedit = ""
	case .TEXT_EDITING:
		delete(app.preedit); app.preedit = strings.clone(string(event.edit.text)); app.ui.dirty = true
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
		app_resize_window(app, d); app.ui.dirty = true
	case .WINDOW_DISPLAY_SCALE_CHANGED:
		if display_fonts(d, app.config, max(sdl.GetWindowDisplayScale(d.window), 1)) {app_resize_window(app, d)}
		app.ui.dirty = true
	case .WINDOW_EXPOSED: app.ui.dirty = true
	case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST:
		d.focused = event.type == .WINDOW_FOCUS_GAINED; app.ui.dirty = true
		if !d.focused {app.mouse_button = 0}
		if r.attached {
			if d.focused {
				if d.external {
					if g, exists := app.ui.grids[ui.cursor_grid]; exists && g.kind != .External && g.window > 0 {app.primary_window = g.window}
					_ = rpc_request(r, "nvim_set_current_win", {i64(app.ui.grids[d.grid_id].window)})
				} else if app.primary_window > 0 {
					rpc_lua(r, "local win=...; if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end", {i64(app.primary_window)})
				}
			}
			rpc_lua(r, "vim.api.nvim_exec_autocmds(..., {})", {"FocusGained" if d.focused else "FocusLost"})
		}
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button := mouse_button_name(event.button.button)
		if button != "" {
			action := "press" if event.type == .MOUSE_BUTTON_DOWN else "release"
			mouse_input(r, d, ui, button, action, event.button.x, event.button.y, mod, int(event.button.clicks))
			app.mouse_button = event.button.button if action == "press" else 0
		}
	case .MOUSE_MOTION:
		if app.mouse_button != 0 {mouse_input(r, d, ui, mouse_button_name(app.mouse_button), "drag", event.motion.x, event.motion.y, mod)}
	case .MOUSE_WHEEL:
		wheel := event.wheel
		x, y := wheel.integer_x, wheel.integer_y
		if wheel.direction == .FLIPPED {x = -x; y = -y}
		for _ in 0..<min(abs(y), 20) {mouse_input(r, d, ui, "wheel", "up" if y > 0 else "down", wheel.mouse_x, wheel.mouse_y, mod)}
		for _ in 0..<min(abs(x), 20) {mouse_input(r, d, ui, "wheel", "right" if x > 0 else "left", wheel.mouse_x, wheel.mouse_y, mod)}
	case .DROP_FILE:
		rpc_lua(r, "local path = ...; vim.cmd('edit ' .. vim.fn.fnameescape(path))", {string(event.drop.data)})
	case .DROP_TEXT:
		rpc_paste(r, string(event.drop.data))
	case:
	}
}
app_message :: proc(app: ^App, message: Node) {
	r := &app.rpc
	switch node_int(node_at(message, 0)) {
	case 1: rpc_response(r, message)
	case 2:
		method, args := node_string(node_at(message, 1)), node_at(message, 2)
		switch method {
		case "redraw": ui_redraw(&app.ui, args)
		case "neodin_clipboard_set": clipboard_set(&app.clipboard, args)
		}
	case 0:
		id, method := i64(node_int(node_at(message, 1))), node_string(node_at(message, 2))
		if method == "neodin_clipboard_get" {clipboard_get(r, &app.clipboard, id)}
		else {
			w := nd_writer_new(); nd_array(w, 4); nd_write_int(w, 1); nd_write_int(w, id)
			put_string(w, "Unsupported GUI request"); nd_write_nil(w); nd_array_end(w); _ = rpc_send(r, w)
		}
	}
}
app_run :: proc(config: Config, nvim_args: []string, smoke: bool) -> int {
	app := App{config = config, smoke = smoke}
	ui_init(&app.ui); defer ui_destroy(&app.ui)
	defer clipboard_destroy(&app.clipboard)
	defer delete(app.preedit)
	defer if app.runtime_font {delete(app.config.font)}
	if !display_create(&app.display, config) {display_destroy(&app.display); return 1}
	defer display_destroy(&app.display)
	app.external_windows = make(map[int]^Display)
	defer {
		for _, d in app.external_windows {display_destroy(d); free(d)}
		delete(app.external_windows)
	}
	font := config.font
	if font == "" {font = font_default_path()}
	if !rpc_start(&app.rpc, config.nvim, nvim_args, fmt.tprintf("%s:h%v", font, config.font_size)) {return 1}
	defer rpc_destroy(&app.rpc)
	app.columns, app.rows = display_size(&app.display)
	rpc_attach(&app.rpc, app.columns, app.rows)
	app.start = sdl.GetTicks()
	last_visible := true
	last_text_blink := u64(0)
	for {
		event: sdl.Event
		for sdl.PollEvent(&event) {app_event(&app, &event)}
		for _ in 0..<256 {
			if nd_reader_parse(app.rpc.reader) == 0 {break}
			app_message(&app, nd_reader_root(app.rpc.reader))
		}
		state, _ := os.process_wait(app.rpc.process, 0)
		if state.exited {app.rpc.exited = true; return state.exit_code}
		if app.rpc.failed || nd_reader_error(app.rpc.reader) != 0 {fmt.eprintln("Neovim RPC connection failed"); return 1}
		if app.rpc.attached && app.rpc.channel != 0 && !app.clipboard_ready {
			rpc_lua(&app.rpc, CLIPBOARD_SETUP, {i64(app.rpc.channel)})
			app.clipboard_ready = true
		}
		rpc_flush_input(&app.rpc)
		if app.ui.font_changed {
			app.ui.font_changed = false
			app_guifont(&app)
		}
		if app.ui.flushed {
			if g, exists := app.ui.grids[app.ui.cursor_grid]; exists && g.kind != .External && g.window > 0 {app.primary_window = g.window}
			if !app_sync_windows(&app) {return 1}
			header := app.ui.showtabline == 2 || (app.ui.showtabline == 1 && len(app.ui.widgets.tabs) > 1)
			if header != app.display.tab_header {
				app.display.tab_header = header
				app.display.grid_top = app.display.padding+(app.display.cell_height if header else 0)
				app_resize(&app); app.ui.flushed = false
			}
		}
		active_display := &app.display
		if d, exists := app.external_windows[app.ui.cursor_grid]; exists {active_display = d}
		visible := cursor_visible(active_display, &app.ui, app.config)
		text_blink := sdl.GetTicks()/500
		blink_changed := false
		if text_blink != last_text_blink {
			for cell in app.ui.grid.cells {if ui_highlight(&app.ui, cell.highlight).blink {blink_changed = true; break}}
		}
		if app.ui.flushed && (app.ui.dirty || visible != last_visible || blink_changed) {
			if app.ui.dirty {app.display.cursor_epoch = sdl.GetTicks()}
			_ = sdl.SetWindowTitle(app.display.window, strings.clone_to_cstring(app.ui.title, context.temp_allocator))
			display_draw(&app.display, &app.ui, config, app.preedit)
			app_draw_external(&app)
			widgets_report_popup(&app)
			app.ui.dirty = false; last_visible = visible; last_text_blink = text_blink
		}
		if app.ui.bell {app.ui.bell = false; _ = sdl.FlashWindow(app.display.window, .BRIEFLY)}
		if smoke {
			if app.ui.flushed && !app.smoke_sent {
				rpc_input(&app.rpc, "iNeodin GPU smoke test<CR>Unicode: 中文 日本語 😀 café é<CR>Editing, splits, terminal buffers, clipboard<Esc>")
				app.smoke_sent = true
			}
			if !app.smoke_widgets && sdl.GetTicks()-app.start > 1500 && app.smoke_sent && len(app.ui.grid.cells) > 0 && app.ui.grid.cells[0].text == "N" {
				app.display.capture_path = "build/smoke.png"
				display_draw(&app.display, &app.ui, app.config, "")
				rpc_lua(&app.rpc, "vim.cmd('tab split'); vim.api.nvim_echo({{'Neodin native messages: 中文','WarningMsg'}},true,{}); vim.api.nvim_input('i'); vim.defer_fn(function() vim.fn.complete(1, {{word='Neodin',kind='v',menu='Odin',info='Native completion details'}, {word='Neovim',kind='v',menu='0.12+'}}) end, 200)")
				app.smoke_widgets = true
			}
			if !app.smoke_external && app.smoke_widgets && sdl.GetTicks()-app.start > 2500 && app.ui.flushed && app.ui.widgets.popup.visible {
				app.display.capture_path = "build/widgets.png"
				display_draw(&app.display, &app.ui, app.config, "")
				rpc_input(&app.rpc, "<C-e><Esc>")
				rpc_lua(&app.rpc, "vim.defer_fn(function() local b=vim.api.nvim_create_buf(false,true); vim.api.nvim_buf_set_lines(b,0,-1,false,{'External Neovim window','Unicode: 中文 😀'}); vim.api.nvim_open_win(b,true,{external=true,width=40,height=8}) end, 200)")
				app.smoke_external = true
			}
			if !app.smoke_focus && app.smoke_external && sdl.GetTicks()-app.start > 3500 && app.ui.flushed && len(app.external_windows) > 0 {
				for _, external in app.external_windows {external.capture_path = "build/external.png"}
				app_draw_external(&app)
				focus: sdl.Event
				focus.type = .WINDOW_FOCUS_GAINED; focus.window.windowID = sdl.GetWindowID(app.display.window)
				app_event(&app, &focus); app.smoke_focus = true
			}
			if app.smoke_focus && sdl.GetTicks()-app.start > 4000 && app.ui.flushed && app.ui.grids[app.ui.cursor_grid].kind != .External {
				fmt.println("GUI smoke test passed: embedded Neovim, multigrid, native widgets, external windows, and GPU presentation")
				return 0
			}
			if sdl.GetTicks()-app.start > 10000 {fmt.eprintln("GUI smoke test timed out"); return 1}
		}
		sdl.Delay(4)
		mem.free_all(context.temp_allocator)
	}
}
app_guifont :: proc(app: ^App) {
	if app.ui.guifont == "" {return}
	fonts := strings.split(app.ui.guifont, ",", context.temp_allocator)
	next := app.config
	next.font = ""
	for font in fonts {
		parts := strings.split(font, ":h", context.temp_allocator)
		name := parts[0]
		if !os.exists(name) {name, _ = strings.replace_all(name, "_", " ", context.temp_allocator)}
		resolved := font_resolve(name)
		if resolved == "" {continue}
		next.font = resolved
		if len(parts) > 1 {
			size_part := strings.split(parts[1], ":", context.temp_allocator)[0]
			if size, ok := strconv.parse_f32(size_part); ok {next.font_size = size}
		}
		break
	}
	if next.font == "" {fmt.eprintf("No available font in guifont=%s\n", app.ui.guifont); return}
	if config_validate(next) != "" {return}
	if display_fonts(&app.display, next, app.display.scale) {
		// The parsed font is temporary; keep an owned copy for later DPI changes.
		if app.runtime_font {delete(app.config.font)}
		app.config.font = strings.clone(next.font); app.runtime_font = true
		app.config.font_size = next.font_size
		app_resize(app)
	}
}
main :: proc() {
	config := config_default()
	path := config_path(); defer delete(path)
	required := os.get_env("NEODIN_CONFIG", context.temp_allocator) != ""
	renderer := ""
	nvim_args := make([dynamic]string); defer delete(nvim_args)
	smoke := false
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--" {append(&nvim_args, ..os.args[i+1:]); break}
		if arg == "--help" || arg == "-h" {fmt.print(HELP); return}
		if arg == "--list-renderers" {
			if !sdl.Init({.VIDEO}) {fmt.eprintln(sdl.GetError()); os.exit(1)}
			for j in 0..<sdl.GetNumRenderDrivers() {fmt.println(sdl.GetRenderDriver(j))}
			sdl.Quit(); return
		}
		if arg == "--config" || arg == "--renderer" {
			if i+1 >= len(os.args) {fmt.eprintf("%s requires a value\n", arg); os.exit(2)}
			i += 1
			if arg == "--config" {delete(path); path = strings.clone(os.args[i]); required = true}
			else {renderer = os.args[i]}
		} else if arg == "--smoke-test" {smoke = true; append(&nvim_args, "--clean", "-n")}
		else {append(&nvim_args, arg)}
	}
	if !config_load(path, required, &config) {os.exit(2)}
	if renderer != "" {config.renderer = renderer}
	if error := config_validate(config); error != "" {fmt.eprintln(error); os.exit(2)}
	code := app_run(config, nvim_args[:], smoke)
	if code != 0 {os.exit(code)}
}
