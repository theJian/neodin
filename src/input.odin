package main

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

key_modifiers :: proc(mod: sdl.Keymod, mouse := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	if mod&sdl.KMOD_CTRL != {} {strings.write_string(&b, "C-")}
	if mod&sdl.KMOD_SHIFT != {} {strings.write_string(&b, "S-")}
	if mod&sdl.KMOD_ALT != {} {strings.write_string(&b, "A-")}
	if mod&sdl.KMOD_GUI != {} {strings.write_string(&b, "D-")}
	result := strings.to_string(b)
	if mouse {return strings.trim_suffix(result, "-")}
	return result
}
key_input :: proc(e: sdl.KeyboardEvent, option_as_alt: bool) -> string {
	key := ""
	switch e.key {
	case sdl.K_RETURN, sdl.K_KP_ENTER: key = "CR"
	case sdl.K_ESCAPE: key = "Esc"
	case sdl.K_BACKSPACE: key = "BS"
	case sdl.K_TAB, sdl.K_LEFT_TAB: key = "Tab"
	case sdl.K_DELETE: key = "Del"
	case sdl.K_INSERT: key = "Insert"
	case sdl.K_HOME: key = "Home"
	case sdl.K_END: key = "End"
	case sdl.K_PAGEUP: key = "PageUp"
	case sdl.K_PAGEDOWN: key = "PageDown"
	case sdl.K_UP: key = "Up"
	case sdl.K_DOWN: key = "Down"
	case sdl.K_LEFT: key = "Left"
	case sdl.K_RIGHT: key = "Right"
	case sdl.K_F1..<sdl.K_F12+1: key = fmt.tprintf("F%d", int(e.key-sdl.K_F1)+1)
	}
	mod := e.mod
	when ODIN_OS == .Darwin {
		if !option_as_alt {mod -= sdl.KMOD_ALT}
	} else {
		// AltGr produces text through SDL's text-input events.
		if .RALT in mod || .MODE in mod {return ""}
	}
	if key == "" {
		if mod&(sdl.KMOD_CTRL|sdl.KMOD_ALT|sdl.KMOD_GUI) == {} {return ""}
		if u32(e.key) < 32 || u32(e.key) >= 0x110000 {return ""}
		if e.key == sdl.K_SPACE {key = "Space"}
		else if e.key == sdl.K_LESS {key = "lt"}
		else {key = fmt.tprintf("%c", rune(e.key))}
	}
	return fmt.tprintf("<%s%s>", key_modifiers(mod), key)
}
text_input :: proc(s: string) -> string {
	result, _ := strings.replace_all(s, "<", "<LT>", context.temp_allocator)
	return result
}
mouse_position :: proc(d: ^Display, ui: ^UI, x, y: f32) -> (row, col: int) {
	return clamp(int((y*d.density-d.padding)/d.cell_height), 0, max(ui.grid.height-1, 0)),
		clamp(int((x*d.density-d.padding)/d.cell_width), 0, max(ui.grid.width-1, 0))
}
mouse_input :: proc(r: ^RPC, d: ^Display, ui: ^UI, button, action: string, x, y: f32, mod: sdl.Keymod, clicks := 1) {
	if !ui.mouse || !r.attached {return}
	row, col := mouse_position(d, ui, x, y)
	modifiers := key_modifiers(mod, true)
	if clicks > 1 {modifiers = fmt.tprintf("%s-%d", modifiers, min(clicks, 4))}
	_ = rpc_request(r, "nvim_input_mouse", {button, action, modifiers, i64(0), i64(row), i64(col)})
}
mouse_button_name :: proc(button: u8) -> string {
	switch button {
	case 1: return "left"
	case 2: return "middle"
	case 3: return "right"
	case 4: return "x1"
	case 5: return "x2"
	}
	return ""
}
