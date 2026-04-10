extends "res://Scripts/Interface.gd"

# UI elements we create
var _stockButton: Button = null
var _repLabel: Label = null
var _stockVisible = false
var _uiInjected = false
var _savedSupply: Array = []  # Cache of normal supply when viewing stock
var _cashAvailable = false
var _inOurReset = false  # True when we're calling ResetTrading ourselves
var _lastKnownSupplyCount: int = -1
var _lastKnownInvCount: int = -1

func _get_ti():
	if Engine.has_meta("TraderImprovements"):
		return Engine.get_meta("TraderImprovements")
	return null

# --- Override: Add rep to trader info ---

func UpdateTraderInfo():
	super()
	var ti = _get_ti()
	if !ti or !trader:
		return

	# Move stats up slightly to make room for rep at the bottom
	var statsPanel = traderUI.get_node_or_null("Panel/Stats")
	if statsPanel and !_repLabel:
		statsPanel.offset_top = 216

	# Add rep label below the existing stats, above the buttons
	if !_repLabel:
		var panel = traderUI.get_node_or_null("Panel")
		if panel:
			_repLabel = Label.new()
			_repLabel.add_theme_font_size_override("font_size", 14)
			_repLabel.add_theme_color_override("font_color", Color(0, 1, 0, 1))
			_repLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_repLabel.position = Vector2(16, 316)
			_repLabel.size = Vector2(176, 20)
			panel.add_child(_repLabel)

	if _repLabel:
		var rep = ti.get_rep(trader.traderData.name)
		var tier = ti.get_rep_tier(trader.traderData.name)
		var tierName = ti.get_rep_tier_name(tier)
		_repLabel.text = tierName + " (" + str(rep) + ")"

# --- Override: Minimize completed tasks + add dailies ---

func InitializeTasks():
	for element in taskList.get_children():
		element.queue_free()

	var taskNotes = Loader.LoadTaskNotes()
	var ti = _get_ti()

	# Add daily tasks first
	if ti and trader:
		var dailies = ti.get_daily_tasks(trader.traderData.name)
		for daily_def in dailies:
			var is_completed = ti.is_daily_completed(trader.traderData.name, daily_def["id"])
			_create_daily_task_ui(daily_def, is_completed)

	# Regular tasks - completed ones get minimized
	for taskData in trader.traderData.tasks:
		var newTask = task.instantiate()
		taskList.add_child(newTask)
		newTask.Initialize(taskData, self)

		if taskNotes.has(taskData):
			newTask.noted = true

		if trader.tasksCompleted.has(taskData.name):
			newTask.Completed()
			# Minimize completed tasks
			newTask.custom_minimum_size.y = 0
			for child in newTask.get_node("Margin/Elements").get_children():
				if child.name != "Title" and child.name != "Highlight":
					child.hide()
			newTask.size.y = 0
		else:
			newTask.Default()

func _create_daily_task_ui(daily_def: Dictionary, is_completed: bool):
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 0)
	taskList.add_child(panel)

	var highlight = ColorRect.new()
	highlight.anchors_preset = Control.PRESET_FULL_RECT
	highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_completed:
		highlight.color = Color8(0, 255, 0, 16)
	else:
		highlight.color = Color8(255, 200, 0, 16)
	panel.add_child(highlight)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	margin.add_child(vbox)

	# Title row
	var titleRow = HBoxContainer.new()
	vbox.add_child(titleRow)

	var titleLabel = Label.new()
	titleLabel.text = daily_def["name"] + " [Daily]"
	titleLabel.add_theme_font_size_override("font_size", 13)
	titleLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titleRow.add_child(titleLabel)

	# Description
	var desc = Label.new()
	desc.text = daily_def["description"]
	desc.add_theme_font_size_override("font_size", 11)
	desc.modulate = Color(0.7, 0.7, 0.7)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(desc)

	# Deliver/Receive info
	var deliverText = "Deliver: "
	for d in daily_def["deliver"]:
		var item_data = _find_item_data_by_file(d["file"])
		deliverText += (item_data.name if item_data else d["file"]) + " x" + str(d["amount"]) + "  "

	var receiveText = "Receive: "
	for r in daily_def["receive"]:
		var item_data = _find_item_data_by_file(r["file"])
		receiveText += (item_data.name if item_data else r["file"]) + " x" + str(r["amount"]) + "  "

	var deliverLabel = Label.new()
	deliverLabel.text = deliverText
	deliverLabel.add_theme_font_size_override("font_size", 11)
	vbox.add_child(deliverLabel)

	var receiveLabel = Label.new()
	receiveLabel.text = receiveText
	receiveLabel.add_theme_font_size_override("font_size", 11)
	receiveLabel.modulate = Color(0.4, 1.0, 0.4)
	vbox.add_child(receiveLabel)

	var btnRow = HBoxContainer.new()
	btnRow.add_theme_constant_override("separation", 4)
	vbox.add_child(btnRow)

	if is_completed:
		var doneLabel = Label.new()
		doneLabel.text = "Completed today"
		doneLabel.add_theme_font_size_override("font_size", 11)
		doneLabel.modulate = Color(0.4, 1.0, 0.4)
		btnRow.add_child(doneLabel)
	else:
		var completeBtn = Button.new()
		completeBtn.text = "Complete Daily"
		completeBtn.custom_minimum_size = Vector2(120, 26)
		completeBtn.add_theme_font_size_override("font_size", 11)
		completeBtn.pressed.connect(_on_daily_complete.bind(daily_def, panel))
		btnRow.add_child(completeBtn)

	# Add/Remove notes button
	var ti = _get_ti()
	if ti:
		var is_noted = ti.is_daily_noted(daily_def["id"])
		var noteBtn = Button.new()
		noteBtn.custom_minimum_size = Vector2(100, 26)
		noteBtn.add_theme_font_size_override("font_size", 11)
		if is_noted:
			noteBtn.text = "Added"
			noteBtn.disabled = true
		else:
			noteBtn.text = "Add to Notes"
			noteBtn.pressed.connect(_on_daily_note.bind(daily_def, noteBtn))
		btnRow.add_child(noteBtn)

func _on_daily_note(daily_def: Dictionary, btn: Button):
	var ti = _get_ti()
	if !ti or !trader:
		return
	ti.add_daily_note(daily_def, trader.traderData.name)
	btn.text = "Added"
	btn.disabled = true
	InitializeNotes()
	PlayClick()

func _on_daily_complete(daily_def: Dictionary, panel: PanelContainer):
	var ti = _get_ti()
	if !ti or !trader:
		return

	# Check if player has required items in inventory
	for d in daily_def["deliver"]:
		if !_has_inventory_item(d["file"], d["amount"]):
			PlayError()
			return

	# Remove delivered items
	for d in daily_def["deliver"]:
		_remove_inventory_item(d["file"], d["amount"])

	# Give received items
	for r in daily_def["receive"]:
		var item_data = _find_item_data_by_file(r["file"])
		if item_data:
			if item_data.stackable:
				var sd = SlotData.new()
				sd.itemData = item_data
				sd.amount = r["amount"]
				sd.condition = 100
				Create(sd, inventoryGrid, true)
			else:
				# Non-stackable: create one item per unit
				for _i in r["amount"]:
					var sd = SlotData.new()
					sd.itemData = item_data
					sd.condition = 100
					Create(sd, inventoryGrid, true)

	# Mark as completed, add rep
	ti.complete_daily(trader.traderData.name, daily_def["id"])
	ti.add_rep(trader.traderData.name, 2)

	# Refresh
	UpdateTraderInfo()
	UpdateStats(true)
	PlayClick()
	trader.PlayTraderTask()

	# Rebuild tasks to show completion
	_on_tasks_pressed()

func _has_inventory_item(file_name: String, amount: int) -> bool:
	var found = 0
	for element in inventoryGrid.get_children():
		if element.slotData and element.slotData.itemData:
			if element.slotData.itemData.file == file_name:
				if element.slotData.itemData.stackable:
					found += element.slotData.amount
				else:
					found += 1
	return found >= amount

func _remove_inventory_item(file_name: String, amount: int):
	var remaining = amount
	var to_remove = []

	for element in inventoryGrid.get_children():
		if remaining <= 0:
			break
		if element.slotData and element.slotData.itemData:
			if element.slotData.itemData.file == file_name:
				if element.slotData.itemData.stackable:
					if element.slotData.amount <= remaining:
						remaining -= element.slotData.amount
						to_remove.append(element)
					else:
						element.slotData.amount -= remaining
						element.UpdateDetails()
						remaining = 0
				else:
					remaining -= 1
					to_remove.append(element)

	for element in to_remove:
		inventoryGrid.Pick(element)
		element.queue_free()

func InitializeNotes():
	super()

	# Add noted dailies to the notes list
	var ti = _get_ti()
	if !ti:
		return

	var noted = ti.get_noted_dailies()
	if noted.size() == 0:
		return

	for note in noted:
		var panel = PanelContainer.new()
		notesList.add_child(panel)

		var highlight = ColorRect.new()
		highlight.anchors_preset = Control.PRESET_FULL_RECT
		highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
		highlight.color = Color8(255, 200, 0, 16)
		panel.add_child(highlight)

		var margin = MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 8)
		margin.add_theme_constant_override("margin_right", 8)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_bottom", 4)
		panel.add_child(margin)

		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 2)
		margin.add_child(vbox)

		var titleRow = HBoxContainer.new()
		vbox.add_child(titleRow)

		var titleLabel = Label.new()
		titleLabel.text = note.get("name", "Daily") + " [" + note.get("trader", "") + "]"
		titleLabel.add_theme_font_size_override("font_size", 13)
		titleLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		titleRow.add_child(titleLabel)

		var removeBtn = Button.new()
		removeBtn.text = "Remove"
		removeBtn.custom_minimum_size = Vector2(70, 24)
		removeBtn.add_theme_font_size_override("font_size", 11)
		removeBtn.pressed.connect(_on_remove_daily_note.bind(note.get("id", "")))
		titleRow.add_child(removeBtn)

		# Deliver/Receive summary
		var deliverText = "Deliver: "
		for d in note.get("deliver", []):
			var item_data = _find_item_data_by_file(d["file"])
			deliverText += (item_data.name if item_data else d["file"]) + " x" + str(d["amount"]) + "  "

		var receiveText = "Receive: "
		for r in note.get("receive", []):
			var item_data = _find_item_data_by_file(r["file"])
			receiveText += (item_data.name if item_data else r["file"]) + " x" + str(r["amount"]) + "  "

		var infoLabel = Label.new()
		infoLabel.text = deliverText + "\n" + receiveText
		infoLabel.add_theme_font_size_override("font_size", 11)
		infoLabel.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(infoLabel)

	# Hide hint if we added notes
	if noted.size() > 0:
		notesHint.visible = false

func _on_remove_daily_note(task_id: String):
	var ti = _get_ti()
	if ti:
		ti.remove_daily_note(task_id)
	InitializeNotes()
	PlayClick()

func _find_item_data_by_file(file_name: String) -> ItemData:
	var scene = Database.get(file_name)
	if scene and scene is PackedScene:
		var path = scene.resource_path.replace(".tscn", ".tres")
		if ResourceLoader.exists(path):
			var res = load(path)
			if res is ItemData:
				return res
	return null

# --- Override: Add rep on trade completion ---

func CompleteDeal():
	# Flag stays true until after _on_accept_pressed calls ResetTrading
	_inOurReset = true
	super()
	var ti = _get_ti()
	if ti and trader:
		ti.add_rep(trader.traderData.name, 1)
		UpdateTraderInfo()
	# Defer clearing the flag so the ResetTrading call from _on_accept_pressed
	# still sees _inOurReset = true
	call_deferred("_clear_our_reset")

func _clear_our_reset():
	_inOurReset = false
	_lastKnownSupplyCount = supplyGrid.get_child_count()
	_lastKnownInvCount = inventoryGrid.get_child_count()

# --- Override: Add Stock button alongside Supply ---

func Open():
	if !_uiInjected and trader:
		_inject_stock_ui()
	if _stockButton:
		_stockButton.hide()
	_stockVisible = false
	_inOurReset = true
	super()
	_inOurReset = false
	if trader and _stockButton:
		_stockButton.show()
	_cashAvailable = Engine.has_meta("CashMain")

func _physics_process(delta):
	super(delta)
	# Continuously snapshot counts while trading so we always have
	# the "before" state when ResetTrading is called
	if gameData.isTrading and trader and !_inOurReset:
		_lastKnownSupplyCount = supplyGrid.get_child_count()
		_lastKnownInvCount = inventoryGrid.get_child_count()

func ResetTrading():
	if gameData.isTrading and trader and !_inOurReset and _cashAvailable:
		var supplyNow = supplyGrid.get_child_count()
		var invNow = inventoryGrid.get_child_count()
		var supplyChanged = _lastKnownSupplyCount >= 0 and supplyNow != _lastKnownSupplyCount
		var invChanged = _lastKnownInvCount >= 0 and invNow != _lastKnownInvCount
		if supplyChanged or invChanged:
			var ti = _get_ti()
			if ti:
				ti.add_rep(trader.traderData.name, 1)
				UpdateTraderInfo()
	super()

func Close():
	if _stockVisible:
		_restore_supply()
	_stockVisible = false
	_cashAvailable = false
	super()

func _inject_stock_ui():
	if _uiInjected:
		return

	var buttonsContainer = supplyButton.get_parent()
	if buttonsContainer:
		buttonsContainer.columns = 3
		_stockButton = Button.new()
		_stockButton.text = "Stock"
		_stockButton.toggle_mode = true
		_stockButton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_stockButton.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_stockButton.button_group = supplyButton.button_group
		_stockButton.pressed.connect(_on_stock_pressed)
		buttonsContainer.add_child(_stockButton)

	_uiInjected = true

func _on_stock_pressed():
	tasksUI.hide()
	supplyUI.show()
	_inOurReset = true
	ResetTrading()
	_inOurReset = false
	ResetInput()

	if !_stockVisible:
		_savedSupply.clear()
		for sd in trader.supply:
			_savedSupply.append(sd)
		ClearSupplyGrid()
		_fill_stock_grid()
		_stockVisible = true
	else:
		_restore_supply()
		_stockVisible = false

	PlayClick()

func _restore_supply():
	ClearSupplyGrid()
	if _savedSupply.size() > 0:
		trader.supply = _savedSupply.duplicate()
		FillSupplyGrid()
	_savedSupply.clear()
	_stockVisible = false

func _fill_stock_grid():
	var ti = _get_ti()
	if !ti or !trader:
		return

	var tier = ti.get_rep_tier(trader.traderData.name)
	var stock_files = ti.get_stock_items(trader.traderData.name, tier)

	for file_name in stock_files:
		var item_data = _find_item_data_by_file(file_name)
		if item_data:
			var sd = SlotData.new()
			sd.itemData = item_data
			sd.condition = 100
			if item_data.stackable and item_data.defaultAmount > 0:
				sd.amount = item_data.defaultAmount
			Create(sd, supplyGrid, false)

# --- Supply/Tasks button presses need to hide stock ---

func _on_supply_pressed():
	if _stockVisible:
		_restore_supply()
	_inOurReset = true
	super()
	_inOurReset = false

func _on_tasks_pressed():
	if _stockVisible:
		_restore_supply()
	_inOurReset = true
	super()
	_inOurReset = false
