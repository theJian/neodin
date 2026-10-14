package main

import "core:strings"
import "core:fmt"
import sdl "vendor:sdl3"

Tab_Hit :: struct {rect: sdl.FRect, handle: int}
Widget_Layout :: struct {
	tabs: [dynamic]Tab_Hit,
	popup: sdl.FRect,
	popup_first, popup_rows: int,
	popup_visible: bool,
	cmdline: sdl.FRect,
	cmdline_scroll: int,
	message: sdl.FRect,
}
widget_highlight :: proc(ui: ^UI, group: string) -> Highlight {return ui_highlight(ui, ui.highlight_groups[group])}
rich_highlight :: proc(ui: ^UI, chunk: Text_Chunk, base: Highlight) -> Highlight {
	h := base
	if chunk.direct {h = ui_resolve_highlight(ui, chunk.attrs)}
	else if chunk.highlight != 0 {h = ui_highlight(ui, chunk.highlight)}
	return h
}
draw_widget_string :: proc(d: ^Display, ui: ^UI, text: string, h: Highlight, x, y, max_x: f32) -> f32 {
	position := x
	for g in graphemes(text, ui.ambiwidth_double) {
		width := f32(g.cells)*d.cell_width
		if position+width > max_x {break}
		if g.cells > 0 {draw_text(d, text[g.start:g.end], h, {position, y, width, d.cell_height})}
		position += width
	}
	return position
}
draw_rich :: proc(d: ^Display, ui: ^UI, text: Rich_Text, base: Highlight, area: sdl.FRect) -> (x, y: f32) {
	x, y = area.x, area.y
	for chunk in text.chunks {
		h := rich_highlight(ui, chunk, base)
		for g in graphemes(chunk.text, ui.ambiwidth_double) {
			value := chunk.text[g.start:g.end]
			if value == "\n" || value == "\r\n" {x = area.x; y += d.cell_height; continue}
			width := f32(g.cells)*d.cell_width
			if x+width > area.x+area.w {x = area.x; y += d.cell_height}
			if y+d.cell_height > area.y+area.h {return}
			if width > 0 {
				rect := sdl.FRect{x, y, width, d.cell_height}
				fill_rect(d, h.background, rect); draw_text(d, value, h, rect); draw_decorations(d, h, rect)
			}
			x += width
		}
	}
	return
}
widgets_draw :: proc(d: ^Display, ui: ^UI, preedit: string) {
	w := &ui.widgets
	width := f32(ui.grid.width)*d.cell_width
	bottom := d.grid_top+f32(ui.grid.height)*d.cell_height
	base := widget_highlight(ui, "MsgArea")
	footer := sdl.FRect{d.padding, bottom, width, 2*d.cell_height}
	fill_rect(d, base.background, footer)
	d.layout.cmdline = {d.padding, bottom+d.cell_height, width, d.cell_height}
	clear(&d.layout.tabs)
	if d.tab_header {
		x := d.padding
		fill_rect(d, widget_highlight(ui, "TabLineFill").background, {x, d.padding, width, d.cell_height})
		for tab in w.tabs {
			h := widget_highlight(ui, "TabLineSel" if tab.handle == w.current_tab else "TabLine")
			name := tab.name
			if at := strings.last_index_byte(name, '/'); at >= 0 {name = name[at+1:]}
			if at := strings.last_index_byte(name, '\\'); at >= 0 {name = name[at+1:]}
			if name == "" {name = "[No Name]"}
			label := fmt.tprintf(" %s ", name)
			tab_width := f32(min(text_cells(label, ui.ambiwidth_double), 28))*d.cell_width
			if x+tab_width > d.padding+width {break}
			rect := sdl.FRect{x, d.padding, tab_width, d.cell_height}
			fill_rect(d, h.background, rect)
			_ = draw_widget_string(d, ui, label, h, x, d.padding, x+tab_width)
			append(&d.layout.tabs, Tab_Hit{rect, tab.handle}); x += tab_width
		}
	}
	// Status messages occupy a dedicated footer; dialogs/history grow above it.
	_, _ = draw_rich(d, ui, w.showmode, base, d.layout.cmdline)
	ruler_width := f32(text_cells(rich_plain(w.ruler), ui.ambiwidth_double))*d.cell_width
	showcmd_width := f32(text_cells(rich_plain(w.showcmd), ui.ambiwidth_double))*d.cell_width
	_, _ = draw_rich(d, ui, w.ruler, base, {max(d.padding, d.padding+width-ruler_width), bottom+d.cell_height, ruler_width, d.cell_height})
	_, _ = draw_rich(d, ui, w.showcmd, base, {max(d.padding, d.padding+width-ruler_width-showcmd_width-d.cell_width), bottom+d.cell_height, showcmd_width, d.cell_height})
	messages := w.history[:] if w.history_visible else w.messages[:]
	d.layout.message = {}
	if len(messages) > 0 {
		rows := 0
		for message in messages {
			plain := rich_plain(message.content)
			lines := strings.split(plain, "\n", context.temp_allocator)
			for line in lines {rows += max(1, (text_cells(line, ui.ambiwidth_double)+ui.grid.width-1)/max(ui.grid.width, 1))}
		}
		visible_rows := min(rows, max(1, ui.grid.height/2))
		height := f32(visible_rows)*d.cell_height
		top := bottom+d.cell_height-height
		d.layout.message = {d.padding, top, width, height}
		fill_rect(d, base.background, d.layout.message)
		set_color(d, widget_highlight(ui, "MsgSeparator").foreground)
		_ = sdl.RenderLine(d.renderer, d.padding, top, d.padding+width, top)
		// Lay out lines once, retaining chunks so highlighting survives wrapping.
		lines := rich_lines(messages, ui.grid.width, ui.ambiwidth_double)
		start := clamp(len(lines)-visible_rows-w.message_scroll, 0, max(len(lines)-visible_rows, 0))
		for i in 0..<min(visible_rows, len(lines)-start) {
			_, _ = draw_rich(d, ui, lines[start+i], base, {d.padding, top+f32(i)*d.cell_height, width, d.cell_height})
		}
	}
	line := widgets_active_cmdline(w)
	if line != nil {
		fill_rect(d, base.background, d.layout.cmdline)
		prefix := strings.repeat(" ", max(line.indent, 0), context.temp_allocator)
		prefix = fmt.tprintf("%s%s%s", prefix, line.firstc, line.prompt)
		x := draw_widget_string(d, ui, prefix, ui_highlight(ui, line.prompt_highlight), d.padding, bottom+d.cell_height, d.padding+width-d.cell_width)
		content := rich_plain(line.content)
		cursor_cells := text_cells(content, ui.ambiwidth_double, line.pos)
		available := max(1, int((d.padding+width-x)/d.cell_width)-1)
		d.layout.cmdline_scroll = max(0, cursor_cells-available)
		_, _ = draw_rich(d, ui, rich_window(line.content, ui.ambiwidth_double, d.layout.cmdline_scroll, line.pos, line.special, line.shift), base,
			{x, bottom+d.cell_height, max(0, width-(x-d.padding)), d.cell_height})
		cursor_x := x+f32(cursor_cells-d.layout.cmdline_scroll)*d.cell_width
		cursor_x = min(cursor_x, d.padding+width-d.cell_width)
		if line.special != "" {_ = draw_widget_string(d, ui, line.special, base, cursor_x, bottom+d.cell_height, d.padding+width)}
		if preedit != "" {
			h := base; h.underline = true
			chunks := make([dynamic]Text_Chunk, allocator = context.temp_allocator)
			append(&chunks, Text_Chunk{text = preedit})
			_, _ = draw_rich(d, ui, Rich_Text{chunks}, h, {cursor_x, bottom+d.cell_height, d.padding+width-cursor_x, d.cell_height})
		}
		fill_rect(d, ui.foreground, {cursor_x, bottom+d.cell_height+d.cell_height-2*d.scale, d.cell_width, 2*d.scale})
		area := sdl.Rect{i32(cursor_x/d.density), i32((bottom+d.cell_height)/d.density), i32(d.cell_width/d.density), i32(d.cell_height/d.density)}
		_ = sdl.SetTextInputArea(d.window, &area, 0)
		if len(w.block) > 0 {
			top := bottom-f32(min(len(w.block), ui.grid.height/2))*d.cell_height
			for i in 0..<min(len(w.block), ui.grid.height/2) {
				_, _ = draw_rich(d, ui, w.block[len(w.block)-min(len(w.block), ui.grid.height/2)+i], base, {d.padding, top+f32(i)*d.cell_height, width, d.cell_height})
			}
		}
	}
	popup := &w.popup
	d.layout.popup_visible = popup.visible && len(popup.items) > 0
	if !d.layout.popup_visible {return}
	row, col := ui_grid_position(ui, popup.grid)
	row += f64(popup.row)+1; col += f64(popup.col)
	px, py := d.padding+f32(col)*d.cell_width, d.grid_top+f32(row)*d.cell_height
	if popup.grid == -1 {
		px, py = d.padding+f32(popup.col)*d.cell_width, d.layout.cmdline.y
		if line != nil {
			text := rich_plain(line.content)
			prefix := strings.concatenate({line.firstc, line.prompt}, context.temp_allocator)
			px = d.padding+f32(line.indent+text_cells(prefix, ui.ambiwidth_double)+text_cells(text, ui.ambiwidth_double, popup.col)-d.layout.cmdline_scroll)*d.cell_width
		}
	}
	rows := min(len(popup.items), 12, max(ui.grid.height, 1))
	first := clamp(popup.selected-rows+1, 0, max(len(popup.items)-rows, 0))
	cols := 8
	for item in popup.items {cols = max(cols, text_cells(strings.concatenate({item.word, " ", item.kind, " ", item.menu}, context.temp_allocator), ui.ambiwidth_double)+2)}
	cols = min(cols, max(ui.grid.width, 1))
	menu_width, menu_height := f32(cols)*d.cell_width, f32(rows)*d.cell_height
	px = clamp(px, d.padding, max(d.padding, d.padding+width-menu_width))
	if py+menu_height > bottom {py = max(d.grid_top, py-menu_height-d.cell_height)}
	d.layout.popup = {px, py, menu_width, menu_height}; d.layout.popup_first = first; d.layout.popup_rows = rows
	fill_rect(d, widget_highlight(ui, "Pmenu").background, d.layout.popup)
	for i in 0..<rows {
		item := popup.items[first+i]
		h := widget_highlight(ui, "PmenuSel" if first+i == popup.selected else "Pmenu")
		fill_rect(d, h.background, {px, py+f32(i)*d.cell_height, menu_width, d.cell_height})
		menu_label := fmt.tprintf(" %s %s %s", item.word, item.kind, item.menu)
		_ = draw_widget_string(d, ui, menu_label, h, px, py+f32(i)*d.cell_height, px+menu_width)
	}
	set_color(d, widget_highlight(ui, "PmenuBorder").foreground)
	_ = sdl.RenderRect(d.renderer, &d.layout.popup)
	if len(popup.items) > rows {
		thumb := menu_height*f32(rows)/f32(len(popup.items))
		fill_rect(d, widget_highlight(ui, "PmenuThumb").background,
			{px+menu_width-d.scale*3, py+(menu_height-thumb)*f32(first)/f32(len(popup.items)-rows), d.scale*3, max(thumb, d.scale*3)})
	}
	if popup.selected >= 0 && popup.selected < len(popup.items) && popup.items[popup.selected].info != "" {
		info := popup.items[popup.selected].info
		info_width := min(width, max(12*d.cell_width, width-menu_width-d.cell_width))
		ix := px+menu_width+d.cell_width
		if ix+info_width > d.padding+width {ix = max(d.padding, px-info_width-d.cell_width)}
		if ix+info_width <= px || ix >= px+menu_width {
			area := sdl.FRect{ix, py, info_width, menu_height}
			h := widget_highlight(ui, "PmenuExtra")
			fill_rect(d, h.background, area)
			chunks := make([dynamic]Text_Chunk, allocator = context.temp_allocator)
			append(&chunks, Text_Chunk{text = info})
			_, _ = draw_rich(d, ui, Rich_Text{chunks}, h, area)
		}
	}
}
// Borrow text slices for this frame; persistent event state owns their storage.
rich_window :: proc(text: Rich_Text, ambiguous_double: bool, start_cells, cursor_byte: int, special: string, shift: bool) -> Rich_Text {
	result := Rich_Text{chunks = make([dynamic]Text_Chunk, allocator = context.temp_allocator)}
	cells, bytes := 0, 0
	for chunk in text.chunks {
		for g in graphemes(chunk.text, ambiguous_double) {
			if cells >= start_cells {
				if shift && special != "" && bytes+g.start == cursor_byte {append(&result.chunks, Text_Chunk{text = special})}
				next := chunk; next.text = chunk.text[g.start:g.end]; append(&result.chunks, next)
			}
			cells += g.cells
		}
		bytes += len(chunk.text)
	}
	return result
}
rich_lines :: proc(messages: []Message, columns: int, ambiguous_double: bool) -> []Rich_Text {
	lines := make([dynamic]Rich_Text, allocator = context.temp_allocator)
	for message in messages {
		append(&lines, Rich_Text{chunks = make([dynamic]Text_Chunk, allocator = context.temp_allocator)})
		cells := 0
		for chunk in message.content.chunks {
			for g in graphemes(chunk.text, ambiguous_double) {
				text := chunk.text[g.start:g.end]
				if text == "\n" || text == "\r\n" || cells+g.cells > columns {
					append(&lines, Rich_Text{chunks = make([dynamic]Text_Chunk, allocator = context.temp_allocator)}); cells = 0
					if text == "\n" || text == "\r\n" {continue}
				}
				next := chunk; next.text = text
				append(&lines[len(lines)-1].chunks, next); cells += g.cells
			}
		}
	}
	return lines[:]
}
