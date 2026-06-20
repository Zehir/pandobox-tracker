extends Node
class_name USB2SNES

enum Opcode {
	DEVICE_LIST,
	ATTACH,
	APP_VERSION,
	NAME,
	CLOSE,
	INFO,
	BOOT,
	MENU,
	RESET,
	BINARY,
	STREAM,
	FENCE,
	GET_ADDRESS,
	PUT_ADDRESS,
	PUT_IPS,
	GET_FILE,
	PUT_FILE,
	LIST,
	REMOVE,
	RENAME,
	MAKE_DIR,
}

enum Space {
	SNES,
	CMD,
}

enum Status {
	CLOSED,
	CONNECTING,
	OPEN,
	ATTACHED,
	ERROR,
}

const MIN_WATCH_INTERVAL_MS := roundi(1000.0 / 60.0)
const DEFAULT_ADDR = "ws://localhost:23074"

signal status_changed(new_status: Status)
signal error_message_changed(message: String)
signal connected
signal disconnected(code: int, reason: String)

@export var addr: String = "ws://localhost:23074"
@export var auto_connect: bool = true

var status: Status = Status.CLOSED:
	set(value):
		if status == value:
			return
		status = value
		status_changed.emit(value)

var error_message: String = "":
	set(message):
		if error_message == message:
			return
		error_message = message
		error_message_changed.emit(message)


var _ws := WebSocketPeer.new()
var _connect_in_progress: bool = false
var _processing: bool = false
var _requests: Array[Request] = []
#var _watchers: Dictionary[int, Watcher] = {}


func _init(_addr: String = DEFAULT_ADDR, _auto_connect: bool = true) -> void:
	addr = _addr
	auto_connect = _auto_connect
	set_process(false)


#region Lifecycles calls
func _ready() -> void:
	if auto_connect:
		open.call_deferred()


func _exit_tree() -> void:
	close()


func _process(_delta: float) -> void:
	_poll_socket()
	_process_requests()

	#_update_watchers()
#endregion

#region Utils
func is_open() -> bool:
	return status == Status.OPEN


func is_attached() -> bool:
	return status == Status.ATTACHED
#endregion

#region Actions
func open() -> bool:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return true

	# In case an other process call the open function we make it wait
	while _connect_in_progress:
		await get_tree().process_frame
		if _ws.get_ready_state() != WebSocketPeer.STATE_CONNECTING:
			# The pool is handled in the first call
			return _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

	status = Status.CONNECTING
	error_message = ""
	_connect_in_progress = true
	var err := _ws.connect_to_url(addr)
	if err != OK:
		_connect_in_progress = false
		status = Status.ERROR
		error_message = "Error connecting to USB2SNES server (code %s)" % err
		set_process(false)
		return false


	while _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_ws.poll()
		await get_tree().process_frame

	_connect_in_progress = false

	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		status = Status.OPEN
		connected.emit()
		set_process(true)
		return true

	status = Status.ERROR
	error_message = "Connection failed"
	set_process(false)
	return false


func close() -> void:
	#stop_all_watchers()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			send(Command.new(Opcode.CLOSE))
			_ws.close()
		WebSocketPeer.STATE_CONNECTING:
			_ws.close()

	#_cancel_pending_commands(null)
	set_process(false)
	_processing = false
	_connect_in_progress = false
	status = Status.CLOSED
	disconnected.emit(1000, "Manually disconnected")


func send(command: Command, callback: Callable = Callable()) -> bool:
	var opened: bool = await open()
	if not opened:
		return false

	_requests.append(Request.new(command, callback))
	_process_requests()
	return true


func read(address: int, length: int = 1) -> PackedByteArray:
	var snes_bus_address := 0xf50000 + (address - 0x7e0000)
	var command := Command.new(Opcode.GET_ADDRESS, [_to_hex(snes_bus_address), _to_hex(length)])
	var result: Signal = Signal()
	send(command, result.emit)
	return await result

#
#func create_watcher(callback: Callable, address: int, length: int = 1, interval_ms: float = 500.0) -> int:
	#var resolved_interval := maxf(interval_ms, MIN_WATCH_INTERVAL_MS)
	#var watcher_id := _next_watcher_id
	#_next_watcher_id += 1
#
	#_watchers[watcher_id] = {
		#"address": address,
		#"length": length,
		#"interval_ms": resolved_interval,
		#"callback": callback,
		#"stopped": false,
		#"running": false,
		#"next_tick_ms": 0,
	#}
#
	#return watcher_id
#
#
#func stop_watcher(watcher_id: int) -> void:
	#if not _watchers.has(watcher_id):
		#return
#
	#var watcher: Dictionary = _watchers[watcher_id]
	#watcher["stopped"] = true
	#_watchers.erase(watcher_id)
#
#
#func stop_all_watchers() -> void:
	#var ids := _watchers.keys()
	#for watcher_id in ids:
		#stop_watcher(int(watcher_id))

#
#func use_memory(address: int, length: int = 1, options: Dictionary = {}) -> MemoryBinding:
	#var interval_ms := float(options.get("interval", 500.0))
	#var immediate := bool(options.get("immediate", true))
	#return MemoryBinding.new(self, address, length, interval_ms, immediate)
##endregion

func _poll_socket() -> void:
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		if status != Status.CLOSED and status != Status.ERROR:
			status = Status.CLOSED
			disconnected.emit(_ws.get_close_code(), _ws.get_close_reason())
		return

	_ws.poll()

	while _ws.get_available_packet_count() > 0:
		var packet := _ws.get_packet()
		var result: Variant = null

		if _ws.was_string_packet():
			var text: String = packet.get_string_from_utf8()
			var parsed: Variant = JSON.parse_string(text)
			if parsed != null:
				if parsed is Dictionary and parsed.has("Results"):
					result = parsed.get("Results")
				else:
					result = parsed
			else:
				result = text
		else:
			result = packet

		_on_message(result)


func _on_message(result: Variant) -> void:
	var request: Request = _requests.pop_front()
	request.respond(result)
	_processing = false
	_process_requests()


func _process_requests() -> void:
	#if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		#status = Status.ERROR
		#error_message = "USB2SNES socket is not open"
		#return

	if _processing or _requests.is_empty():
		return

	_processing = true
	var request: Request = _requests[0]
	var command: Command = request.get_command()

	_ws.send_text(command.get_serialized())
	if command.opcode == Opcode.ATTACH:
		status = Status.ATTACHED

	if not command.is_expecting_reply():
		_processing = false
		_requests.pop_front()
		_process_requests()

#
#func _cancel_pending_commands(fallback: Variant) -> void:
	#for command in _commands:
		#if command.has("request_id"):
			#emit_signal("command_resolved", int(command["request_id"]), fallback)
	#_commands.clear()

#
#func _update_watchers() -> void:
	#if _watchers.is_empty():
		#return
#
	#var now_ms := Time.get_ticks_msec()
	#var watcher_ids := _watchers.keys()
#
	#for watcher_id_value in watcher_ids:
		#var watcher_id := int(watcher_id_value)
		#if not _watchers.has(watcher_id):
			#continue
#
		#var watcher: Dictionary = _watchers[watcher_id]
		#if bool(watcher.get("stopped", false)):
			#continue
		#if bool(watcher.get("running", false)):
			#continue
		#if now_ms < int(watcher.get("next_tick_ms", 0)):
			#continue
#
		#watcher["running"] = true
		#watcher["next_tick_ms"] = now_ms + int(round(float(watcher.get("interval_ms", 500.0))))
		#_watchers[watcher_id] = watcher
		#_run_watcher_tick(watcher_id)

#
#func _run_watcher_tick(watcher_id: int) -> void:
	#if not _watchers.has(watcher_id):
		#return
#
	#var watcher: Dictionary = _watchers[watcher_id]
	#if bool(watcher.get("stopped", false)):
		#return
#
	#var result: PackedByteArray = await read(int(watcher["address"]), int(watcher["length"]))
#
	#if not _watchers.has(watcher_id):
		#return
#
	#watcher = _watchers[watcher_id]
	#if bool(watcher.get("stopped", false)):
		#return
#
	#var callback: Callable = watcher.get("callback", Callable())
	#if callback.is_valid():
		#callback.call(result)
#
	#watcher["running"] = false
	#if _watchers.has(watcher_id):
		#_watchers[watcher_id] = watcher


func _to_hex(value: int) -> String:
	return "%x" % value



class Command extends RefCounted:
	var opcode: Opcode:
		set(value):
			opcode = value
			is_dirty = true

	var operands: Array[String]:
		set(value):
			operands = value.duplicate()
			is_dirty = true

	var flags: Array[String]:
		set(value):
			flags = value.duplicate()
			is_dirty = true

	var space: Space:
		set(value):
			space = value
			is_dirty = true

	var is_dirty: bool = true
	var _serialized: String = ""


	func _init(_opcode: Opcode, _operands: Array[String] = [], _flags: Array[String] = [], _space: Variant = Space.SNES) -> void:
		opcode = _opcode
		#TODO check if the setters are used here to avoid duplicate
		operands = _operands.duplicate()
		flags = _flags.duplicate()
		space = _space


	func is_expecting_reply() -> bool:
		if opcode == Opcode.ATTACH:
			return false
		return true


	func get_serialized() -> String:
		if is_dirty:
			is_dirty = false
			var payload: Dictionary[String, Variant] = {
				"Opcode": String(Opcode.find_key(opcode)).to_pascal_case(),
				"Space": String(Space.find_key(space)),
			}
			if not flags.is_empty():
				payload["Flags"] = flags
			if not operands.is_empty():
				payload["Operands"] = operands
			_serialized = JSON.stringify(payload)
		return _serialized


class Request extends RefCounted:
	static var _next_request_id: int = 1

	var _request_id: int
	var _command: Command
	var _callback: Callable

	func _init(command: Command, callback: Callable = Callable()) -> void:
		_request_id  = _next_request_id
		_next_request_id += 1
		_command = command
		_callback = callback

	func respond(data: Variant):
		if _callback.is_valid():
			_callback.call(data)

	func get_command() -> Command:
		return _command


class Watcher extends  RefCounted:
	enum Status {
		RUNNING,
		STOPPED,
	}

	static var _next_watcher_id: int = 1

	var _watcher_id: int
	var _callback: Callable
	var _address: int
	var _length: int
	var _interval_ms: int
	var status: Status = Status.STOPPED

	func _init(callback: Callable, address: int, length: int = 1, interval_ms: int = 500) -> void:
		_watcher_id = _next_watcher_id
		_next_watcher_id += 1
		_callback = callback
		_address = address
		_length = length
		_interval_ms = maxi(interval_ms, MIN_WATCH_INTERVAL_MS)



#
#class MemoryBinding:
	#extends RefCounted
#
	#signal updated(data)
#
	#var _client: USB2SNES
	#var _address: int
	#var _length: int
	#var _interval_ms: float
	#var _immediate: bool
#
	#var value: PackedByteArray = PackedByteArray()
	#var watcher_id: int = -1
#
	#func _init(client: USB2SNES, address: int, length: int, interval_ms: float, immediate: bool) -> void:
		#_client = client
		#_address = address
		#_length = length
		#_interval_ms = interval_ms
		#_immediate = immediate
		#if _immediate:
			#start()
#
	#func is_watching() -> bool:
		#return watcher_id != -1
#
	#func start() -> void:
		#stop()
		#watcher_id = _client.create_watcher(_on_data, _address, _length, _interval_ms)
#
	#func stop() -> void:
		#if watcher_id == -1:
			#return
		#_client.stop_watcher(watcher_id)
		#watcher_id = -1
#
	#func refresh() -> PackedByteArray:
		#var data: Variant = await _client.read(_address, _length)
		#if data is PackedByteArray:
			#_on_data(data)
			#return data
		#return PackedByteArray()
#
	#func _on_data(data: PackedByteArray) -> void:
		#value = data
		#emit_signal("updated", value)
