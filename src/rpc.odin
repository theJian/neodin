package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

Pending_Kind :: enum {General, Attach, Input, Api_Info, Paste}
Pending :: struct {kind: Pending_Kind, method: string, bytes: int}
Input_Job :: struct {kind: Pending_Kind, text: string, offset: int}
RPC :: struct {
	process: os.Process,
	input, output: ^os.File,
	reader: rawptr,
	transport: rawptr,
	serial: i64,
	pending: map[i64]Pending,
	input_queue: [dynamic]Input_Job,
	input_inflight: bool,
	attached, failed: bool,
	channel: int,
	ui_size: [2]int,
	exited: bool,
	spawned: bool,
}

pipe_read :: proc "c" (user: rawptr, data: [^]byte, size: c.size_t) -> c.size_t {
	context = runtime.default_context()
	r := (^RPC)(user)
	if r.transport != nil {return nd_transport_read(r.transport, data, size)}
	has_data, err := os.pipe_has_data(r.output)
	if err != nil {return ~c.size_t(0)}
	if !has_data {return 0}
	n, read_err := os.read(r.output, data[:int(size)])
	if read_err != nil || n == 0 {return ~c.size_t(0)}
	return c.size_t(n)
}

rpc_start :: proc(r: ^RPC, executable: string, args: []string, guifont := "") -> bool {
	stdin_r, stdin_w, err := os.pipe()
	if err != nil {fmt.eprintln("Neovim stdin:", err); return false}
	defer os.close(stdin_r)
	stdout_r, stdout_w, out_err := os.pipe()
	if out_err != nil {os.close(stdin_w); return false}
	defer os.close(stdout_w)
	command := make([dynamic]string)
	defer delete(command)
	append(&command, executable, "--embed", "--cmd", "let g:neodin = 1")
	if guifont != "" {
		escaped, _ := strings.replace_all(guifont, "'", "''", context.temp_allocator)
		append(&command, "--cmd", fmt.tprintf("let &guifont = '%s'", escaped))
	}
	append(&command, ..args)
	p, start_err := os.process_start({command = command[:], stdin = stdin_r, stdout = stdout_w, stderr = os.stderr})
	if start_err != nil {
		os.close(stdin_w); os.close(stdout_r)
		fmt.eprintln("Cannot start Neovim:", start_err)
		return false
	}
	r.process = p; r.input = stdin_w; r.output = stdout_r
	r.spawned = true
	r.pending = make(map[i64]Pending)
	r.reader = nd_reader_new(pipe_read, r)
	if r.reader == nil {rpc_destroy(r); return false}
	return true
}

rpc_connect :: proc(r: ^RPC, address: string) -> bool {
	r.transport = nd_transport_connect(strings.clone_to_cstring(address, context.temp_allocator))
	if r.transport == nil {fmt.eprintf("Cannot connect to Neovim at %s\n", address); return false}
	r.pending = make(map[i64]Pending)
	r.reader = nd_reader_new(pipe_read, r)
	if r.reader == nil {rpc_destroy(r); return false}
	return true
}

rpc_destroy :: proc(r: ^RPC, terminate := true) {
	// Closing stdin gives Neovim EOF; force termination only after a bounded wait.
	if r.transport != nil {nd_transport_free(r.transport)}
	else if r.spawned {
		os.close(r.input)
		if !r.exited {
			state, _ := os.process_wait(r.process, 250_000_000)
			if !state.exited && terminate {_ = os.process_kill(r.process); _, _ = os.process_wait(r.process)}
		}
		os.close(r.output)
	}
	if r.reader != nil {nd_reader_free(r.reader)}
	for job in r.input_queue {delete(job.text)}
	delete(r.pending); delete(r.input_queue)
	r^ = {}
}

rpc_send :: proc(r: ^RPC, w: rawptr) -> bool {
	data: [^]byte
	size: c.size_t
	err := nd_writer_finish(w, &data, &size)
	defer nd_free(data)
	if err != 0 {r.failed = true; return false}
	if r.transport != nil {
		if nd_transport_write(r.transport, data, size) == 0 {r.failed = true; return false}
		return true
	}
	remaining := data[:int(size)]
	for len(remaining) > 0 {
		n, write_err := os.write(r.input, remaining)
		if write_err != nil || n == 0 {r.failed = true; return false}
		remaining = remaining[n:]
	}
	return true
}

rpc_request :: proc(r: ^RPC, method: string, args: []Value, kind := Pending_Kind.General, bytes := 0) -> i64 {
	r.serial += 1
	w := nd_writer_new()
	nd_array(w, 4); nd_write_int(w, 0); nd_write_int(w, r.serial)
	put_string(w, method); put_value(w, Value(args)); nd_array_end(w)
	r.pending[r.serial] = {kind, method, bytes}
	_ = rpc_send(r, w)
	return r.serial
}

rpc_input :: proc(r: ^RPC, text: string) {
	if text != "" {append(&r.input_queue, Input_Job{.Input, strings.clone(text), 0})}
}
rpc_paste :: proc(r: ^RPC, text: string) {
	if text != "" {append(&r.input_queue, Input_Job{.Paste, strings.clone(text), 0})}
}
rpc_pop_input :: proc(r: ^RPC) {
	delete(r.input_queue[0].text)
	copy(r.input_queue[:], r.input_queue[1:]); resize(&r.input_queue, len(r.input_queue)-1)
}
rpc_flush_input :: proc(r: ^RPC) {
	if !r.attached || r.input_inflight || len(r.input_queue) == 0 {return}
	job := &r.input_queue[0]
	remaining := job.text[job.offset:]
	if job.kind == .Input {
		n := input_chunk(transmute([]byte)remaining)
		_ = rpc_request(r, "nvim_input", {remaining[:n]}, .Input, n)
	} else {
		n := min(len(remaining), 4096)
		for n < len(remaining) && remaining[n]&0xc0 == 0x80 {n -= 1}
		phase := i64(2)
		if job.offset == 0 {phase = 1}
		if n == len(remaining) {phase = -1 if job.offset == 0 else 3}
		_ = rpc_request(r, "nvim_paste", {remaining[:n], true, phase}, .Paste, n)
	}
	r.input_inflight = true
}

rpc_response :: proc(r: ^RPC, message: Node) {
	id := i64(node_int(node_at(message, 1)))
	p, ok := r.pending[id]
	if !ok {return}
	delete_key(&r.pending, id)
	error := node_at(message, 2)
	if nd_kind(error) != .Nil {
		fmt.eprintf("Neovim %s failed: %s\n", p.method, node_string(node_at(error, 1)))
		if p.kind == .Attach || p.kind == .Api_Info {r.failed = true}
		if p.kind == .Input || p.kind == .Paste {r.input_inflight = false; rpc_pop_input(r)}
		return
	}
	result := node_at(message, 3)
	switch p.kind {
	case .Attach: r.attached = true
	case .Api_Info:
		version, valid := neovim_version(result)
		if !valid {
			fmt.eprintln("Cannot read Neovim version from API metadata")
			r.failed = true; return
		}
		if !neovim_version_supported(version) {
			fmt.eprintf("Neodin requires Neovim 0.12 or newer (found %d.%d.%d)\n", version.major, version.minor, version.patch)
			r.failed = true; return
		}
		r.channel = node_int(node_at(result, 0))
		rpc_attach_ui(r)
	case .Input, .Paste:
		r.input_inflight = false
		job := &r.input_queue[0]
		if p.kind == .Input {job.offset += clamp(node_int(result), 0, p.bytes)}
		else if node_bool(result) {job.offset += p.bytes}
		else {job.offset = len(job.text)}
		if job.offset >= len(job.text) {rpc_pop_input(r)}
	case .General:
	}
}

input_chunk :: proc(bytes: []byte) -> int {
	n := min(len(bytes), 1024)
	if n == len(bytes) {return n}
	for n > 0 && bytes[n]&0xc0 == 0x80 {n -= 1}
	// Do not split a <C-...> token, including the escaped literal <LT>.
	for i := n-1; i >= 0; i -= 1 {
		if bytes[i] == '>' {break}
		if bytes[i] == '<' {n = i; break}
	}
	return n if n > 0 else min(len(bytes), 1024)
}
rpc_lua :: proc(r: ^RPC, code: string, args: []Value = nil) {
	_ = rpc_request(r, "nvim_exec_lua", {code, Value(args)})
}

rpc_attach :: proc(r: ^RPC, columns, rows: int) {
	r.ui_size = {columns, rows}
	_ = rpc_request(r, "nvim_get_api_info", nil, .Api_Info)
}

Neovim_Version :: struct {major, minor, patch: int}
neovim_version :: proc(api_info: Node) -> (version: Neovim_Version, valid: bool) {
	if node_count(api_info) < 2 {return}
	metadata := node_at(api_info, 1)
	if nd_kind(metadata) != .Map {return}
	n := nd_get(metadata, "version")
	if nd_kind(n) != .Map {return}
	fields := []struct {key: cstring, value: ^int}{
		{"major", &version.major}, {"minor", &version.minor}, {"patch", &version.patch},
	}
	for field in fields {
		value := nd_get(n, field.key)
		if nd_kind(value) != .Int && nd_kind(value) != .Uint {return}
		field.value^ = node_int(value)
		if field.value^ < 0 {return}
	}
	return version, true
}
neovim_version_supported :: proc(version: Neovim_Version) -> bool {
	return version.major > 0 || (version.major == 0 && version.minor >= 12)
}
rpc_attach_ui :: proc(r: ^RPC) {
	// --embed pauses user startup until attach, so init.lua can override this.
	rpc_lua(r, CLIPBOARD_SETUP, {i64(r.channel)})
	options := make(map[string]Value)
	options["rgb"] = true
	options["ext_linegrid"] = true
	options["ext_multigrid"] = true
	options["ext_hlstate"] = true
	options["ext_cmdline"] = true
	options["ext_popupmenu"] = true
	options["ext_tabline"] = true
	options["ext_messages"] = true
	defer delete(options)
	_ = rpc_request(r, "nvim_ui_attach", {i64(r.ui_size[0]), i64(r.ui_size[1]), options}, .Attach)
}
