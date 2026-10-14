package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:os"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Text_Key :: struct {text: string, style: u8}
Cached_Text :: struct {text: ^ttf.Text, width, height: f32}
Display :: struct {
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	engine: ^ttf.TextEngine,
	fonts: [4]^ttf.Font,
	fallbacks: [dynamic]^ttf.Font,
	text_cache: map[Text_Key]Cached_Text,
	cell_width, cell_height, glyph_height, padding: f32,
	scale: f32,
	density: f32,
	focused: bool,
	cursor_epoch: u64,
	capture_path: string,
}

display_clear_text :: proc(d: ^Display) {
	for k, text in d.text_cache {ttf.DestroyText(text.text); delete(k.text)}
	clear(&d.text_cache)
}
display_close_fonts :: proc(d: ^Display) {
	display_clear_text(d)
	for font in d.fonts {if font != nil {ttf.CloseFont(font)}}
	d.fonts = {}
	for font in d.fallbacks {ttf.CloseFont(font)}
	clear(&d.fallbacks)
}
font_resolve :: proc(requested: string) -> string {
	name := requested
	if name == "monospace" || name == "Monospace" {name = font_default_path()}
	if os.exists(name) {return name}
	resolved := nd_font_path(strings.clone_to_cstring(name, context.temp_allocator))
	if resolved == nil {return ""}
	defer nd_free(rawptr(resolved))
	return strings.clone(string(resolved), context.temp_allocator)
}
display_fonts :: proc(d: ^Display, config: Config, scale: f32) -> bool {
	path := config.font
	if path == "" {path = font_default_path()}
	path = font_resolve(path)
	font := ttf.OpenFont(strings.clone_to_cstring(path, context.temp_allocator), config.font_size*scale)
	if font == nil {fmt.eprintf("Cannot open font %s: %s\n", path, sdl.GetError()); return false}
	display_close_fonts(d)
	d.fonts[0] = font
	for i in 1..<4 {
		d.fonts[i] = ttf.CopyFont(font)
		if d.fonts[i] == nil {return false}
		style: ttf.FontStyleFlags
		if i&1 != 0 {style += {.BOLD}}
		if i&2 != 0 {style += {.ITALIC}}
		ttf.SetFontStyle(d.fonts[i], style)
	}
	fallback_paths := make([dynamic]string, allocator = context.temp_allocator)
	append(&fallback_paths, ..config.fallback_fonts)
	when ODIN_OS == .Darwin {
		append(&fallback_paths, "/System/Library/Fonts/Apple Color Emoji.ttc", "PingFang SC", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
	} else when ODIN_OS == .Linux {
		append(&fallback_paths, "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf")
	}
	for fallback_path in fallback_paths {
		fallback := font_resolve(fallback_path)
		if fallback == "" {continue}
		if f := ttf.OpenFont(strings.clone_to_cstring(fallback, context.temp_allocator), config.font_size*scale); f != nil {
			append(&d.fallbacks, f)
			for primary in d.fonts {_ = ttf.AddFallbackFont(primary, f)}
		}
	}
	for f in d.fonts {ttf.SetFontKerning(f, false)}
	w, h: c.int
	_ = ttf.GetStringSize(font, raw_data(string("M")), 1, &w, &h)
	d.cell_width = f32(max(w, 1)); d.glyph_height = f32(max(h, 1))
	d.cell_height = d.glyph_height+f32(config.line_spacing)*scale
	d.scale = scale; d.padding = f32(config.padding)*scale
	d.density = max(sdl.GetWindowPixelDensity(d.window), 1)
	return true
}
display_create :: proc(d: ^Display, config: Config) -> bool {
	if !sdl.Init({.VIDEO}) {fmt.eprintln(sdl.GetError()); return false}
	if !ttf.Init() {fmt.eprintln(sdl.GetError()); return false}
	d.text_cache = make(map[Text_Key]Cached_Text)
	w := c.int(f32(config.columns)*config.font_size*0.65+f32(2*config.padding))
	h := c.int(f32(config.rows)*config.font_size*1.4+f32(2*config.padding))
	d.window = sdl.CreateWindow("Neodin", w, h, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if d.window == nil {fmt.eprintln(sdl.GetError()); return false}
	driver := config.renderer
	if driver == "auto" {
		when ODIN_OS == .Darwin {driver = "metal,opengl"}
		else when ODIN_OS == .Windows {driver = "direct3d12,direct3d11,vulkan,opengl"}
		else {driver = "vulkan,opengl,opengles2"}
	}
	d.renderer = sdl.CreateRenderer(d.window, strings.clone_to_cstring(driver, context.temp_allocator))
	if d.renderer == nil {fmt.eprintf("Cannot create hardware renderer %s: %s\n", driver, sdl.GetError()); return false}
	if string(sdl.GetRendererName(d.renderer)) == "software" {fmt.eprintln("A hardware renderer is required"); return false}
	fmt.printf("Neodin renderer: %s\n", sdl.GetRendererName(d.renderer))
	_ = sdl.SetRenderVSync(d.renderer, 1 if config.vsync else 0)
	_ = sdl.SetWindowOpacity(d.window, config.window_opacity)
	d.engine = ttf.CreateRendererTextEngine(d.renderer)
	if d.engine == nil {return false}
	scale := max(sdl.GetWindowDisplayScale(d.window), 1)
	if !display_fonts(d, config, scale) {return false}
	_ = sdl.SetWindowSize(d.window, c.int((d.cell_width*f32(config.columns)+2*d.padding)/d.density), c.int((d.cell_height*f32(config.rows)+2*d.padding)/d.density))
	_ = sdl.SetWindowFullscreen(d.window, config.fullscreen)
	_ = sdl.StartTextInput(d.window)
	d.focused = true; d.cursor_epoch = sdl.GetTicks()
	return true
}
display_destroy :: proc(d: ^Display) {
	display_close_fonts(d); delete(d.text_cache); delete(d.fallbacks)
	if d.engine != nil {ttf.DestroyRendererTextEngine(d.engine)}
	if d.renderer != nil {sdl.DestroyRenderer(d.renderer)}
	if d.window != nil {sdl.DestroyWindow(d.window)}
	ttf.Quit(); sdl.Quit()
}
display_size :: proc(d: ^Display) -> (columns, rows: int) {
	w, h: c.int
	_ = sdl.GetRenderOutputSize(d.renderer, &w, &h)
	return max(12, int((f32(w)-2*d.padding)/d.cell_width)), max(3, int((f32(h)-2*d.padding)/d.cell_height))
}
set_color :: proc(d: ^Display, color: int) {
	_ = sdl.SetRenderDrawColor(d.renderer, u8(color>>16), u8(color>>8), u8(color), 255)
}
fill_rect :: proc(d: ^Display, color: int, rect: sdl.FRect) {
	r := rect
	set_color(d, color); _ = sdl.RenderFillRect(d.renderer, &r)
}
draw_text :: proc(d: ^Display, text: string, h: Highlight, rect: sdl.FRect) {
	if text == "" || text == " " || !highlight_text_visible(h, sdl.GetTicks()) {return}
	style := u8(0)
	if h.bold {style |= 1}; if h.italic {style |= 2}
	key := Text_Key{text, style}
	cached, ok := d.text_cache[key]
	if !ok {
		cached.text = ttf.CreateText(d.engine, d.fonts[style], raw_data(text), c.size_t(len(text)))
		if cached.text == nil {return}
		tw, th: c.int
		_ = ttf.GetTextSize(cached.text, &tw, &th)
		cached.width = f32(max(tw, 1)); cached.height = f32(max(th, 1))
		d.text_cache[Text_Key{strings.clone(text), style}] = cached
	}
	_ = ttf.SetTextColor(cached.text, u8(h.foreground>>16), u8(h.foreground>>8), u8(h.foreground), 255)
	// Bitmap fallback fonts (notably Apple Color Emoji) have fixed strike sizes.
	// Fit their atlas quads to the Neovim cell instead of clipping a 160px glyph.
	scale := min(f32(1), rect.w/cached.width, d.glyph_height/cached.height)
	_ = sdl.SetRenderScale(d.renderer, scale, scale)
	clip := sdl.Rect{c.int(rect.x/scale), c.int(rect.y/scale), c.int(math.ceil(rect.w/scale)), c.int(math.ceil(rect.h/scale))}
	_ = sdl.SetRenderClipRect(d.renderer, &clip)
	_ = ttf.DrawRendererText(cached.text, rect.x/scale, (rect.y+(d.cell_height-cached.height*scale)/2)/scale)
	_ = sdl.SetRenderClipRect(d.renderer, nil)
	_ = sdl.SetRenderScale(d.renderer, 1, 1)
}
draw_decorations :: proc(d: ^Display, h: Highlight, rect: sdl.FRect) {
	if !highlight_text_visible(h, sdl.GetTicks()) {return}
	set_color(d, h.special)
	y := rect.y+rect.h-max(d.scale, 1)
	if h.underline || h.underdouble {_ = sdl.RenderLine(d.renderer, rect.x, y, rect.x+rect.w, y)}
	if h.underdouble {_ = sdl.RenderLine(d.renderer, rect.x, y-2*d.scale, rect.x+rect.w, y-2*d.scale)}
	if h.undercurl || h.underdotted || h.underdashed {
		step := max(d.scale, 1)
		for x := f32(0); x < rect.w; x += step {
			if h.undercurl { _ = sdl.RenderPoint(d.renderer, rect.x+x, y-f32(int(x/step)%4/2)*step) }
			else if (h.underdotted && int(x/step)%2 == 0) || (h.underdashed && int(x/step)%6 < 4) {_ = sdl.RenderPoint(d.renderer, rect.x+x, y)}
		}
	}
	if h.strikethrough {set_color(d, h.foreground); _ = sdl.RenderLine(d.renderer, rect.x, rect.y+rect.h/2, rect.x+rect.w, rect.y+rect.h/2)}
	if h.overline {set_color(d, h.foreground); _ = sdl.RenderLine(d.renderer, rect.x, rect.y+d.scale, rect.x+rect.w, rect.y+d.scale)}
}
highlight_text_visible :: proc(h: Highlight, ticks: u64) -> bool {
	return !h.conceal && (!h.blink || ticks%1000 < 500)
}
cursor_visible :: proc(d: ^Display, ui: ^UI, config: Config) -> bool {
	if ui.busy {return false}
	if !config.cursor_blink || !d.focused || len(ui.modes) == 0 {return true}
	mode := ui.modes[clamp(ui.mode_index, 0, len(ui.modes)-1)]
	if mode.blinkon <= 0 || mode.blinkoff <= 0 {return true}
	elapsed := int(sdl.GetTicks()-d.cursor_epoch)
	return elapsed < mode.blinkwait || (elapsed-mode.blinkwait)%(mode.blinkon+mode.blinkoff) < mode.blinkon
}
display_draw :: proc(d: ^Display, ui: ^UI, config: Config, preedit: string) {
	if len(d.text_cache) > 8192 {display_clear_text(d)}
	set_color(d, ui.background); _ = sdl.RenderClear(d.renderer)
	g := &ui.grid
	for y in 0..<g.height {for x in 0..<g.width {
		cell := g.cells[y*g.width+x]; h := ui_cell_highlight(ui, cell)
		rect := sdl.FRect{d.padding+f32(x)*d.cell_width, d.padding+f32(y)*d.cell_height, d.cell_width, d.cell_height}
		fill_rect(d, h.background, rect)
	}}
	for y in 0..<g.height {for x in 0..<g.width {
		cell := g.cells[y*g.width+x]; h := ui_cell_highlight(ui, cell)
		rect := sdl.FRect{d.padding+f32(x)*d.cell_width, d.padding+f32(y)*d.cell_height, d.cell_width, d.cell_height}
		if x+1 < g.width && g.cells[y*g.width+x+1].text == "" {rect.w *= 2}
		draw_text(d, cell.text, h, rect); draw_decorations(d, h, rect)
	}}
	row, col := ui.cursor_row, ui.cursor_col
	if row >= 0 && row < g.height && col >= 0 && col < g.width {
		rect := sdl.FRect{d.padding+f32(col)*d.cell_width, d.padding+f32(row)*d.cell_height, d.cell_width, d.cell_height}
		if col+1 < g.width && g.cells[row*g.width+col+1].text == "" {rect.w *= 2}
		mode := Cursor_Mode{percentage = 100}
		if len(ui.modes) > 0 {mode = ui.modes[clamp(ui.mode_index, 0, len(ui.modes)-1)]}
		if cursor_visible(d, ui, config) {
			h := ui_highlight(ui, mode.attr_id)
			if mode.attr_id == 0 {h.foreground, h.background = ui.background, ui.foreground}
			if !d.focused {
				set_color(d, h.background); _ = sdl.RenderRect(d.renderer, &rect)
			} else {
				cursor := rect
				if mode.shape == "vertical" {cursor.w = max(d.scale, rect.w*f32(mode.percentage)/100)}
				if mode.shape == "horizontal" {cursor.h = max(d.scale, rect.h*f32(mode.percentage)/100); cursor.y += rect.h-cursor.h}
				fill_rect(d, h.background, cursor)
				if mode.shape != "vertical" && mode.shape != "horizontal" {draw_text(d, g.cells[row*g.width+col].text, h, rect)}
			}
		}
		if preedit != "" {
			rect.w = d.cell_width*f32(max(len(preedit), 1)); h := ui_highlight(ui, 0); h.underline = true
			fill_rect(d, h.background, rect); draw_text(d, preedit, h, rect); draw_decorations(d, h, rect)
		}
		area := sdl.Rect{c.int(rect.x/d.density), c.int(rect.y/d.density), c.int(rect.w/d.density), c.int(rect.h/d.density)}
		_ = sdl.SetTextInputArea(d.window, &area, 0)
	}
	if d.capture_path != "" {
		if surface := sdl.RenderReadPixels(d.renderer, nil); surface != nil {
			_ = sdl.SavePNG(surface, strings.clone_to_cstring(d.capture_path, context.temp_allocator))
			sdl.DestroySurface(surface)
		}
		d.capture_path = ""
	}
	_ = sdl.RenderPresent(d.renderer)
}
