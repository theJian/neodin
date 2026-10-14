package main

import "core:testing"
import "core:strings"
import sdl "vendor:sdl3"

@(test)
test_key_translation :: proc(t: ^testing.T) {
	testing.expect(t, key_input({key = sdl.K_A}, false) == "")
	testing.expect(t, key_input({key = sdl.K_A, mod = sdl.KMOD_CTRL}, false) == "<C-a>")
	testing.expect(t, key_input({key = sdl.K_TAB, mod = sdl.KMOD_SHIFT}, false) == "<S-Tab>")
	testing.expect(t, key_input({key = sdl.K_F12}, false) == "<F12>")
	testing.expect(t, key_input({key = sdl.K_ESCAPE}, false) == "<Esc>")
	testing.expect(t, text_input("a<中文") == "a<LT>中文")
	when ODIN_OS == .Darwin {
		testing.expect(t, key_input({key = sdl.K_A, mod = sdl.KMOD_ALT}, false) == "")
		testing.expect(t, key_input({key = sdl.K_A, mod = sdl.KMOD_ALT}, true) == "<A-a>")
	} else {
		testing.expect(t, key_input({key = sdl.K_A, mod = sdl.KMOD_LCTRL|sdl.KMOD_RALT}, false) == "")
	}
}
@(test)
test_input_chunk_boundaries :: proc(t: ^testing.T) {
	text := strings.repeat("x", 1022); defer delete(text)
	unicode := strings.concatenate({text, "界"}); defer delete(unicode)
	testing.expect(t, input_chunk(transmute([]byte)unicode) == 1022)
	keys := strings.concatenate({text, "<C-a>"}); defer delete(keys)
	testing.expect(t, input_chunk(transmute([]byte)keys) == 1022)
}

@(test)
test_mouse_coordinates_at_fractional_dpi :: proc(t: ^testing.T) {
	d := Display{cell_width = 15, cell_height = 30, padding = 6, scale = 1.5, density = 1}
	ui := UI{grid = Grid{width = 80, height = 24}}
	row, col := mouse_position(&d, &ui, 36, 66)
	testing.expect(t, row == 2 && col == 2)
	d.density = 2
	row, col = mouse_position(&d, &ui, 18, 33)
	testing.expect(t, row == 2 && col == 2)
}
