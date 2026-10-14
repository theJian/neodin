package main

import "core:strings"
import sdl "vendor:sdl3"

CLIPBOARD_SETUP :: `
local channel = ...
vim.g.clipboard = {
  name = 'Neodin', cache_enabled = 0,
  copy = {
    ['+'] = function(lines, regtype) vim.rpcnotify(channel, 'neodin_clipboard_set', lines, regtype) end,
    ['*'] = function(lines, regtype) vim.rpcnotify(channel, 'neodin_clipboard_set', lines, regtype) end,
  },
  paste = {
    ['+'] = function() return vim.rpcrequest(channel, 'neodin_clipboard_get') end,
    ['*'] = function() return vim.rpcrequest(channel, 'neodin_clipboard_get') end,
  },
}
vim.g.loaded_clipboard_provider = nil
vim.cmd('runtime autoload/provider/clipboard.vim')
`
Clipboard :: struct {text, regtype: string}
clipboard_destroy :: proc(c: ^Clipboard) {delete(c.text); delete(c.regtype)}
clipboard_set :: proc(c: ^Clipboard, args: Node) {
	lines := node_at(args, 0)
	b := strings.builder_make()
	for i in 0..<node_count(lines) {
		if i != 0 {strings.write_byte(&b, '\n')}
		strings.write_string(&b, node_string(node_at(lines, i)))
	}
	regtype := node_string(node_at(args, 1))
	if regtype == "V" {strings.write_byte(&b, '\n')}
	clipboard_destroy(c)
	c.text = strings.clone(strings.to_string(b)); c.regtype = strings.clone(regtype)
	strings.builder_destroy(&b)
	_ = sdl.SetClipboardText(strings.clone_to_cstring(c.text, context.temp_allocator))
}
clipboard_get :: proc(r: ^RPC, c: ^Clipboard, id: i64) {
	p := sdl.GetClipboardText(); defer sdl.free(p)
	text := string(cstring(p))
	regtype := "v"
	if text == c.text && c.regtype != "" {regtype = c.regtype}
	else if strings.has_suffix(text, "\n") {regtype = "V"}
	clipboard_reply(r, id, text, regtype)
}
clipboard_reply :: proc(r: ^RPC, id: i64, value, regtype: string) {
	text := value
	if regtype == "V" {text = strings.trim_suffix(text, "\n")}
	lines := strings.split(text, "\n", context.temp_allocator)
	w := nd_writer_new()
	nd_array(w, 4); nd_write_int(w, 1); nd_write_int(w, id); nd_write_nil(w)
	nd_array(w, 2); nd_array(w, u32(len(lines)))
	for line in lines {put_string(w, strings.trim_suffix(line, "\r"))}
	nd_array_end(w); put_string(w, regtype); nd_array_end(w); nd_array_end(w)
	_ = rpc_send(r, w)
}
