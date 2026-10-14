package main

import "core:unicode/utf8"
import "core:c"

Grapheme :: struct {start, end, cells: int}
graphemes :: proc(text: string, ambiguous_double := false) -> []Grapheme {
	result := make([dynamic]Grapheme, allocator = context.temp_allocator)
	previous: rune
	state: i32
	for current, start in text {
		_, bytes := utf8.decode_rune_in_string(text[start:])
		width := max(0, int(nd_char_width(i32(current), c.int(1 if ambiguous_double else 0))))
		if len(result) == 0 || nd_grapheme_break(i32(previous), i32(current), &state) != 0 {
			append(&result, Grapheme{start, start+bytes, width})
		} else {
			last := &result[len(result)-1]
			last.end = start+bytes; last.cells = max(last.cells, width)
			// Emoji presentation and keycap clusters occupy two cells in Nvim.
			if current == 0xfe0f || current == 0x20e3 {last.cells = max(last.cells, 2)}
		}
		previous = current
	}
	return result[:]
}
text_cells :: proc(text: string, ambiguous_double := false, limit := max(int)) -> int {
	width := 0
	for g in graphemes(text, ambiguous_double) {if g.start >= limit {break}; width += g.cells}
	return width
}
