extends "res://Scripts/Task.gd"

# Override Completed to minimize the task visually
func Completed():
	super()
	# Collapse everything except the title
	var elements = get_node_or_null("Margin/Elements")
	if elements:
		for child in elements.get_children():
			if child.name != "Title" and child.name != "Highlight":
				child.hide()
	# Shrink the panel
	custom_minimum_size.y = 0
	size.y = 0
