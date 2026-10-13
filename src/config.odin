package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Config :: struct {
	nvim: string,
	font: string,
	fallback_fonts: []string,
	font_size: f32,
	line_spacing: int,
	columns, rows: int,
	padding: int,
	renderer: string,
	vsync, fullscreen, cursor_blink, option_as_alt: bool,
	background_opacity: f32,
}
config_default :: proc() -> Config {
	return {nvim = "nvim", font_size = 16, columns = 100, rows = 32, padding = 4,
		renderer = "auto", vsync = true, cursor_blink = true, background_opacity = 1}
}
config_path :: proc() -> string {
	explicit := os.get_env("NEODIN_CONFIG", context.allocator); defer delete(explicit)
	if explicit != "" {return strings.clone(explicit)}
	base := os.get_env("XDG_CONFIG_HOME", context.allocator); defer delete(base)
	if base != "" {return fmt.aprintf("%s/neodin/config.json", base)}
	when ODIN_OS == .Windows {
		appdata := os.get_env("APPDATA", context.allocator); defer delete(appdata)
		return fmt.aprintf("%s/neodin/config.json", appdata)
	} else {
		home := os.get_env("HOME", context.allocator); defer delete(home)
		return fmt.aprintf("%s/.config/neodin/config.json", home)
	}
}
config_validate :: proc(c: Config) -> string {
	if c.nvim == "" {return "nvim must name a Neovim executable"}
	if c.font_size < 6 || c.font_size > 96 {return "font_size must be between 6 and 96"}
	if c.columns < 12 || c.columns > 1000 || c.rows < 3 || c.rows > 1000 {return "columns must be 12..1000 and rows 3..1000"}
	if c.padding < 0 || c.padding > 100 || c.line_spacing < 0 || c.line_spacing > 100 {return "padding and line_spacing must be 0..100"}
	if c.background_opacity < 0.1 || c.background_opacity > 1 {return "background_opacity must be 0.1..1"}
	if c.renderer == "" || c.renderer == "software" {return "renderer must be auto or a hardware backend"}
	return ""
}
config_load :: proc(path: string, required: bool, c: ^Config) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		if !required && err == .Not_Exist {return true}
		fmt.eprintf("Cannot read config %s: %v\n", path, err); return false
	}
	defer delete(data)
	if json_err := json.unmarshal(data, c); json_err != nil {fmt.eprintf("Invalid config %s: %v\n", path, json_err); return false}
	if message := config_validate(c^); message != "" {fmt.eprintf("Invalid config: %s\n", message); return false}
	return true
}

font_default_path :: proc() -> string {
	when ODIN_OS == .Darwin {return "/System/Library/Fonts/Menlo.ttc"}
	else when ODIN_OS == .Windows {
		root := os.get_env("WINDIR", context.temp_allocator)
		return fmt.tprintf("%s/Fonts/consola.ttf", root)
	} else {
		candidates := []string{
			"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
			"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
			"/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf",
		}
		for path in candidates {if os.exists(path) {return path}}
		return ""
	}
}
