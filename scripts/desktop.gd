extends TileMapLayer

@export var mouse: Node2D


func _ready() -> void:
	randomize_layout()


func randomize_layout() -> void:
	clear()
	var taken = []
	var max_x = floor(get_window().size.x / tile_set.tile_size.x)
	var max_y = floor(get_window().size.y / tile_set.tile_size.y)
	print(max_x, max_y)
	for x in range(2):
		for y in range(2):
			var pos = Vector2i(randi_range(0, max_x), randi_range(0, max_y))
			while pos in taken:
				pos = Vector2i(randi_range(0, max_x), randi_range(0, max_y))
			taken.append(pos)
			set_cell(pos, 1, Vector2i(x, y), 0)


func _input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("click"):
		var map_pos = local_to_map(mouse.position)
		print(map_pos)
