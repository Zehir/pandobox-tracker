extends Control


@export var usb_2snes: USB2SNES


func _ready() -> void:
	pass


func _on_usb_2snes_status_changed(new_status: USB2SNES.Status) -> void:
	prints("new_status", USB2SNES.Status.find_key(new_status))


func _on_usb_2snes_error_message_changed(message: String) -> void:
	prints("error_message_changed", message)


func _on_usb_2snes_connected() -> void:
	usb_2snes.send(USB2SNES.Command.new(USB2SNES.Opcode.DEVICE_LIST), prints)
