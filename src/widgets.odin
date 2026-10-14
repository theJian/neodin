package main

import "core:fmt"
import "core:strings"

Text_Chunk :: struct {text: string, highlight: int, attrs: Highlight, direct: bool}
Rich_Text :: struct {chunks: [dynamic]Text_Chunk}
Command_Line :: struct {
	content: Rich_Text,
	firstc, prompt, special: string,
	pos, indent, level, prompt_highlight: int,
	shift, visible: bool,
}
Popup_Item :: struct {word, kind, menu, info: string}
Popup :: struct {items: []Popup_Item, selected, row, col, grid: int, visible: bool}
Tab_Item :: struct {handle: int, name: string}
Message :: struct {kind, id, trigger: string, content: Rich_Text, history: bool}
Widgets :: struct {
	cmdlines: map[int]^Command_Line,
	block: [dynamic]Rich_Text,
	popup: Popup,
	tabs, buffers: []Tab_Item,
	current_tab, current_buffer: int,
	messages, history: [dynamic]Message,
	showmode, showcmd, ruler: Rich_Text,
	history_visible, empty_pending, nonempty_seen: bool,
	message_scroll: int,
}

rich_destroy :: proc(text: ^Rich_Text) {
	for chunk in text.chunks {delete(chunk.text); if chunk.direct {delete(chunk.attrs.url)}}
	delete(text.chunks); text^ = {}
}
rich_parse :: proc(node: Node) -> Rich_Text {
	text: Rich_Text
	for i in 0..<node_count(node) {
		value := node_at(node, i)
		if node_count(value) < 2 {continue}
		chunk := Text_Chunk{text = strings.clone(node_string(node_at(value, 1)))}
		first := node_at(value, 0)
		if nd_kind(first) == .Map {chunk.direct = true; chunk.attrs = highlight_parse(first)}
		else {chunk.highlight = node_int(first)}
		append(&text.chunks, chunk)
	}
	return text
}
rich_plain :: proc(text: Rich_Text, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for chunk in text.chunks {strings.write_string(&b, chunk.text)}
	return strings.to_string(b)
}
rich_set :: proc(target: ^Rich_Text, node: Node) {rich_destroy(target); target^ = rich_parse(node)}
rich_append :: proc(target: ^Rich_Text, next: Rich_Text) {append(&target.chunks, ..next.chunks[:]); delete(next.chunks)}
cmdline_destroy :: proc(line: ^Command_Line) {
	rich_destroy(&line.content); delete(line.firstc); delete(line.prompt); delete(line.special)
}
popup_destroy :: proc(popup: ^Popup) {
	for item in popup.items {delete(item.word); delete(item.kind); delete(item.menu); delete(item.info)}
	delete(popup.items); popup^ = {}
}
tabs_destroy :: proc(tabs: []Tab_Item) {for tab in tabs {delete(tab.name)}; delete(tabs)}
message_destroy :: proc(message: ^Message) {
	delete(message.kind); delete(message.id); delete(message.trigger); rich_destroy(&message.content)
}
messages_clear :: proc(messages: ^[dynamic]Message) {for &m in messages^ {message_destroy(&m)}; clear(messages)}
widgets_destroy :: proc(w: ^Widgets) {
	for _, line in w.cmdlines {cmdline_destroy(line); free(line)}
	delete(w.cmdlines)
	for &line in w.block {rich_destroy(&line)}; delete(w.block)
	popup_destroy(&w.popup); tabs_destroy(w.tabs); tabs_destroy(w.buffers)
	messages_clear(&w.messages); delete(w.messages); messages_clear(&w.history); delete(w.history)
	rich_destroy(&w.showmode); rich_destroy(&w.showcmd); rich_destroy(&w.ruler)
}
widgets_cmdline :: proc(w: ^Widgets, level: int) -> ^Command_Line {
	if line, ok := w.cmdlines[level]; ok {return line}
	line := new(Command_Line); line.level = level; w.cmdlines[level] = line
	return line
}
widgets_active_cmdline :: proc(w: ^Widgets) -> ^Command_Line {
	result: ^Command_Line
	for _, line in w.cmdlines {if line.visible && (result == nil || line.level > result.level) {result = line}}
	return result
}
tabs_parse :: proc(node: Node, field: cstring) -> []Tab_Item {
	tabs := make([]Tab_Item, node_count(node))
	for &tab, i in tabs {
		n := node_at(node, i)
		tab.handle = node_handle(nd_get(n, field)); tab.name = strings.clone(node_string(nd_get(n, "name")))
	}
	return tabs
}
message_id :: proc(node: Node) -> string {
	if nd_kind(node) == .Str && node_string(node) != "" {return fmt.aprintf("s:%s", node_string(node))}
	if (nd_kind(node) == .Int || nd_kind(node) == .Uint) && node_int(node) != 0 {return fmt.aprintf("i:%d", node_int(node))}
	return ""
}
widgets_event :: proc(ui: ^UI, name: string, a: Node) -> bool {
	w := &ui.widgets
	switch name {
	case "cmdline_show":
		level := node_int(node_at(a, 5)); line := widgets_cmdline(w, level)
		cmdline_destroy(line)
		line^ = {level = level, visible = true, content = rich_parse(node_at(a, 0)),
			pos = node_int(node_at(a, 1)), firstc = strings.clone(node_string(node_at(a, 2))),
			prompt = strings.clone(node_string(node_at(a, 3))), indent = node_int(node_at(a, 4)),
			prompt_highlight = node_int_or_index(a, 6, 0)}
		w.history_visible = false
	case "cmdline_pos": widgets_cmdline(w, node_int(node_at(a, 1))).pos = node_int(node_at(a, 0))
	case "cmdline_special_char":
		line := widgets_cmdline(w, node_int(node_at(a, 2)))
		delete(line.special); line.special = strings.clone(node_string(node_at(a, 0))); line.shift = node_bool(node_at(a, 1))
	case "cmdline_hide":
		if line, ok := w.cmdlines[node_int(node_at(a, 0))]; ok {line.visible = false}
	case "cmdline_block_show":
		for &line in w.block {rich_destroy(&line)}; clear(&w.block)
		lines := node_at(a, 0)
		for i in 0..<node_count(lines) {append(&w.block, rich_parse(node_at(lines, i)))}
	case "cmdline_block_append": append(&w.block, rich_parse(node_at(a, 0)))
	case "cmdline_block_hide": for &line in w.block {rich_destroy(&line)}; clear(&w.block)
	case "popupmenu_show":
		popup_destroy(&w.popup)
		items := node_at(a, 0)
		w.popup = {items = make([]Popup_Item, node_count(items)), selected = node_int(node_at(a, 1)),
			row = node_int(node_at(a, 2)), col = node_int(node_at(a, 3)), grid = node_int(node_at(a, 4)), visible = true}
		for &item, i in w.popup.items {
			n := node_at(items, i)
			item.word = strings.clone(node_string(node_at(n, 0))); item.kind = strings.clone(node_string(node_at(n, 1)))
			item.menu = strings.clone(node_string(node_at(n, 2))); item.info = strings.clone(node_string(node_at(n, 3)))
		}
	case "popupmenu_select": w.popup.selected = node_int(node_at(a, 0))
	case "popupmenu_hide": w.popup.visible = false
	case "tabline_update":
		tabs_destroy(w.tabs); tabs_destroy(w.buffers)
		w.current_tab = node_handle(node_at(a, 0)); w.tabs = tabs_parse(node_at(a, 1), "tab")
		w.current_buffer = node_handle(node_at(a, 2)); w.buffers = tabs_parse(node_at(a, 3), "buffer")
	case "msg_show":
		kind := node_string(node_at(a, 0))
		if kind == "empty" {w.empty_pending = true; return true}
		w.nonempty_seen = true
		id := ""
		if node_count(a) > 5 {id = message_id(node_at(a, 5))}
		index := -1
		if id != "" {for message, i in w.messages {if message.id == id {index = i; break}}}
		append_message := node_count(a) > 4 && node_bool(node_at(a, 4))
		if index < 0 && (node_bool(node_at(a, 2)) || append_message) && len(w.messages) > 0 {index = len(w.messages)-1}
		next := Message{kind = strings.clone(kind), id = id, content = rich_parse(node_at(a, 1)), history = node_bool(node_at(a, 3))}
		if node_count(a) > 6 {next.trigger = strings.clone(node_string(node_at(a, 6)))}
		if index >= 0 {
			if append_message {
				rich_append(&w.messages[index].content, next.content); next.content = {}
				message_destroy(&next)
			} else {message_destroy(&w.messages[index]); w.messages[index] = next}
		} else {append(&w.messages, next)}
		w.message_scroll = 0
	case "msg_clear": messages_clear(&w.messages)
	case "msg_showmode": rich_set(&w.showmode, node_at(a, 0))
	case "msg_showcmd": rich_set(&w.showcmd, node_at(a, 0))
	case "msg_ruler": rich_set(&w.ruler, node_at(a, 0))
	case "msg_history_show":
		messages_clear(&w.history)
		entries := node_at(a, 0)
		for i in 0..<node_count(entries) {
			n := node_at(entries, i)
			content := rich_parse(node_at(n, 1))
			if node_count(n) > 2 && node_bool(node_at(n, 2)) && len(w.history) > 0 {rich_append(&w.history[len(w.history)-1].content, content)}
			else {append(&w.history, Message{kind = strings.clone(node_string(node_at(n, 0))), content = content})}
		}
		w.history_visible = true; w.message_scroll = 0
	case: return false
	}
	return true
}
