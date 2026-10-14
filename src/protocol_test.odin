package main

import "core:slice"
import "core:c"
import "core:testing"
import "core:time"
import "core:os"

Test_Stream :: struct {data: []byte, available, offset, chunk: int}
test_read :: proc "c" (user: rawptr, data: [^]byte, size: c.size_t) -> c.size_t {
	s := (^Test_Stream)(user)
	n := min(int(size), s.available-s.offset, s.chunk)
	copy(data[:n], s.data[s.offset:s.offset+n]); s.offset += n
	return c.size_t(n)
}
test_encode :: proc(value: Value) -> []byte {
	w := nd_writer_new(); put_value(w, value)
	p: [^]byte; n: c.size_t
	assert(nd_writer_finish(w, &p, &n) == 0)
	defer nd_free(p)
	return slice.clone(p[:int(n)])
}

@(test)
test_fragmented_rpc :: proc(t: ^testing.T) {
	data := test_encode(Value([]Value{i64(2), "redraw", []Value{[]Value{"grid_line", []Value{i64(1), i64(0), i64(0), []Value{[]Value{"界", i64(7)}, []Value{""}, []Value{"x", i64(2), i64(3)}}}}, []Value{"flush", []Value{}}}}))
	defer delete(data)
	s := Test_Stream{data = data, chunk = 1}
	r := nd_reader_new(test_read, &s); defer nd_reader_free(r)
	for i in 0..<len(data)-1 {
		s.available = i+1
		testing.expect(t, nd_reader_parse(r) == 0)
		testing.expect(t, nd_reader_error(r) == 0)
	}
	s.available = len(data)
	testing.expect(t, nd_reader_parse(r) == 1)
	ui: UI; ui_init(&ui); defer ui_destroy(&ui)
	grid_resize(&ui_grid(&ui, 1).grid, 8, 2)
	ui_redraw(&ui, node_at(nd_reader_root(r), 2))
	testing.expect(t, ui.grid.cells[0].text == "界")
	testing.expect(t, ui.grid.cells[1].text == "")
	testing.expect(t, ui.grid.cells[4].text == "x")
	testing.expect(t, ui.grid.cells[4].highlight == 2)
	testing.expect(t, ui.flushed)
}

@(test)
test_scroll_and_resize :: proc(t: ^testing.T) {
	g: Grid; grid_resize(&g, 4, 4); defer grid_destroy(&g)
	for y in 0..<4 {for x in 0..<4 {grid_set(&g, y, x, "row", y*4+x)}}
	grid_scroll(&g, 1, 4, 1, 3, 1, 0)
	testing.expect(t, g.cells[5].highlight == 9)
	testing.expect(t, g.cells[13].text == "")
	testing.expect(t, g.cells[4].highlight == 4)
	grid_scroll(&g, 0, 4, 0, 4, -1, -1)
	testing.expect(t, g.cells[0].text == "")
	testing.expect(t, g.cells[5].highlight == 0 && g.cells[5].text == "row")
	grid_resize(&g, 2, 2)
	testing.expect(t, g.cells[3].text == "row")
}

@(test)
test_embedded_neovim :: proc(t: ^testing.T) {
	r: RPC
	if !rpc_start(&r, "nvim", {"--clean", "-n"}) {testing.expect(t, false); return}
	defer rpc_destroy(&r)
	ui: UI; ui_init(&ui); defer ui_destroy(&ui)
	rpc_attach(&r, 40, 10)
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5*time.Second {
		for nd_reader_parse(r.reader) != 0 {
			m := nd_reader_root(r.reader)
			if node_int(node_at(m, 0)) == 1 {rpc_response(&r, m)}
			if node_int(node_at(m, 0)) == 2 && node_string(node_at(m, 1)) == "redraw" {ui_redraw(&ui, node_at(m, 2))}
		}
		if r.attached && ui.flushed {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, r.attached && ui.flushed)
	testing.expect(t, ui.grid.width == 40 && ui.grid.height == 10)
	rpc_input(&r, "iNeodin works<Esc>")
	for time.tick_since(deadline) < 5*time.Second {
		rpc_flush_input(&r)
		for nd_reader_parse(r.reader) != 0 {
			m := nd_reader_root(r.reader)
			if node_int(node_at(m, 0)) == 1 {rpc_response(&r, m)}
			if node_int(node_at(m, 0)) == 2 && node_string(node_at(m, 1)) == "redraw" {ui_redraw(&ui, node_at(m, 2))}
		}
		if len(ui.grid.cells) > 0 && ui.grid.cells[0].text == "N" && !r.input_inflight {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, ui.grid.cells[0].text == "N" && ui.grid.cells[6].text == " ")
	testing.expect(t, nd_reader_error(r.reader) == 0)
}

@(test)
test_version_gate_before_ui_attach :: proc(t: ^testing.T) {
	cases := []struct {major: i64, minor: Value, supported: bool}{
		{0, i64(11), false}, {0, i64(12), true}, {0, i64(13), true},
		{1, i64(0), true}, {0, "12", false},
	}
	for scenario in cases {
		version := make(map[string]Value); defer delete(version)
		version["major"] = scenario.major; version["minor"] = scenario.minor; version["patch"] = i64(0)
		metadata := make(map[string]Value); defer delete(metadata)
		metadata["version"] = version
		data := test_encode(Value([]Value{i64(1), i64(1), nil, []Value{i64(7), metadata}}))
		defer delete(data)
		s := Test_Stream{data = data, available = len(data), chunk = len(data)}
		reader := nd_reader_new(test_read, &s); defer nd_reader_free(reader)
		testing.expect(t, nd_reader_parse(reader) == 1)
		output, input, err := os.pipe()
		if err != nil {testing.expect(t, false); return}
		defer os.close(output); defer os.close(input)
		r := RPC{input = input, serial = 1, ui_size = {80, 24}, pending = make(map[i64]Pending)}
		defer delete(r.pending)
		r.pending[1] = {.Api_Info, "nvim_get_api_info", 0}
		rpc_response(&r, nd_reader_root(reader))
		testing.expect(t, r.failed == !scenario.supported)
		has_data, _ := os.pipe_has_data(output)
		testing.expect(t, has_data == scenario.supported)
		if !scenario.supported {
			testing.expect(t, len(r.pending) == 0 && r.channel == 0)
			continue
		}
		buffer: [512]byte
		n, read_err := os.read(output, buffer[:])
		testing.expect(t, read_err == nil)
		request_stream := Test_Stream{data = buffer[:n], available = n, chunk = n}
		request_reader := nd_reader_new(test_read, &request_stream); defer nd_reader_free(request_reader)
		testing.expect(t, nd_reader_parse(request_reader) == 1)
		request := nd_reader_root(request_reader)
		testing.expect(t, node_string(node_at(request, 2)) == "nvim_ui_attach")
		args := node_at(request, 3)
		testing.expect(t, node_int(node_at(args, 0)) == 80 && node_int(node_at(args, 1)) == 24)
		testing.expect(t, r.channel == 7 && !r.attached)
	}
}
