package main

import "core:c"

when ODIN_OS == .Windows {
	foreign import rpc_lib {"../build/neodin_rpc.lib", "system:Advapi32.lib", "system:utf8proc.lib", "system:uv.lib"}
} else when ODIN_OS == .Darwin {
	foreign import rpc_lib {"../build/libneodin_rpc.a", "system:CoreText.framework", "system:CoreFoundation.framework", "system:utf8proc", "system:uv"}
} else {
	foreign import rpc_lib {"../build/libneodin_rpc.a", "system:fontconfig", "system:utf8proc", "system:uv"}
}

Node :: struct {data, tree: rawptr}
Kind :: enum c.int {Missing, Nil, Bool, Int, Uint, Float, Double, Str, Bin, Array, Map, Ext}
Read_Fn :: #type proc "c" (rawptr, [^]byte, c.size_t) -> c.size_t

@(default_calling_convention="c")
foreign rpc_lib {
	nd_transport_spawn :: proc(argv: [^]cstring, forward_stdin: c.int) -> rawptr ---
	nd_transport_exited :: proc(transport: rawptr, code: ^c.int) -> c.int ---
	nd_transport_stop :: proc(transport: rawptr, terminate: c.int) ---
	nd_transport_connect :: proc(address: cstring) -> rawptr ---
	nd_transport_free :: proc(transport: rawptr) ---
	nd_transport_read :: proc(transport: rawptr, data: [^]byte, size: c.size_t) -> c.size_t ---
	nd_transport_eof :: proc(transport: rawptr) -> c.int ---
	nd_transport_write :: proc(transport: rawptr, data: [^]byte, size: c.size_t) -> c.int ---
	nd_char_width :: proc(codepoint: i32, ambiguous_double: c.int) -> c.int ---
	nd_grapheme_break :: proc(previous, current: i32, state: ^i32) -> c.int ---
	nd_font_path :: proc(name: cstring) -> cstring ---
	nd_reader_new :: proc(read: Read_Fn, user: rawptr) -> rawptr ---
	nd_reader_parse :: proc(r: rawptr) -> c.int ---
	nd_reader_error :: proc(r: rawptr) -> c.int ---
	nd_reader_root :: proc(r: rawptr) -> Node ---
	nd_reader_free :: proc(r: rawptr) ---
	nd_kind :: proc(n: Node) -> Kind ---
	nd_int :: proc(n: Node) -> i64 ---
	nd_number :: proc(n: Node) -> f64 ---
	nd_handle :: proc(n: Node) -> i64 ---
	nd_bool :: proc(n: Node) -> bool ---
	nd_str :: proc(n: Node) -> [^]byte ---
	nd_strlen :: proc(n: Node) -> u32 ---
	nd_count :: proc(n: Node) -> u32 ---
	nd_at :: proc(n: Node, i: u32) -> Node ---
	nd_get :: proc(n: Node, key: cstring) -> Node ---
	nd_writer_new :: proc() -> rawptr ---
	nd_array :: proc(w: rawptr, n: u32) ---
	nd_array_end :: proc(w: rawptr) ---
	nd_map :: proc(w: rawptr, n: u32) ---
	nd_map_end :: proc(w: rawptr) ---
	nd_write_int :: proc(w: rawptr, n: i64) ---
	nd_write_number :: proc(w: rawptr, n: f64) ---
	nd_write_bool :: proc(w: rawptr, b: bool) ---
	nd_write_nil :: proc(w: rawptr) ---
	nd_write_str :: proc(w: rawptr, p: [^]byte, n: u32) ---
	nd_writer_finish :: proc(w: rawptr, data: ^[^]byte, size: ^c.size_t) -> c.int ---
	nd_free :: proc(p: rawptr) ---
}

node_int :: proc(n: Node) -> int {return int(nd_int(n))}
node_handle :: proc(n: Node) -> int {return int(nd_handle(n))}
node_number :: proc(n: Node) -> f64 {
	if nd_kind(n) == .Int || nd_kind(n) == .Uint {return f64(node_int(n))}
	return nd_number(n)
}
node_string :: proc(n: Node) -> string {
	if nd_kind(n) != .Str {return ""}
	return string(nd_str(n)[:nd_strlen(n)])
}
node_bool :: proc(n: Node) -> bool {
	return nd_kind(n) == .Bool && nd_bool(n)
}
node_count :: proc(n: Node) -> int {
	if nd_kind(n) != .Array {return 0}
	return int(nd_count(n))
}
node_at :: proc(n: Node, i: int) -> Node {return nd_at(n, u32(i))}
put_string :: proc(w: rawptr, s: string) {nd_write_str(w, raw_data(s), u32(len(s)))}

Value :: union {i64, f64, bool, string, []Value, map[string]Value}
put_value :: proc(w: rawptr, value: Value) {
	switch v in value {
	case i64: nd_write_int(w, v)
	case f64: nd_write_number(w, v)
	case bool: nd_write_bool(w, v)
	case string: put_string(w, v)
	case []Value:
		nd_array(w, u32(len(v)))
		for x in v {put_value(w, x)}
		nd_array_end(w)
	case map[string]Value:
		nd_map(w, u32(len(v)))
		for k, x in v {put_string(w, k); put_value(w, x)}
		nd_map_end(w)
	case: nd_write_nil(w)
	}
}
