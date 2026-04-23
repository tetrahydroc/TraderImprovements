extends Node

var gameData = preload("res://Resources/GameData.tres")
var LT_Master: LootTable = preload("res://Loot/LT_Master.tres")

const SAVE_PATH = "user://TraderImprovements.tres"
const LEGACY_CFG_PATH = "user://TraderImprovements.cfg"

# Rep data per trader
var _rep: Dictionary = {}
# Daily task tracking
var _dailyDay: int = 0
var _dailyCompleted: Dictionary = {}
# Per-save random seed for daily generation
var _dailySeed: int = 0
# Noted dailies (shown in task notes area)
var _notedDailies: Array = []
# Cached item pools per trader (built once)
var _traderPools: Dictionary = {}

# UI state
var _stockButton: Button = null
var _refreshButton: Button = null
var _repairButton: Button = null
var _repLabel: Label = null
var _tiSettings = preload("res://TraderImprovementsV2/TISettings.tres")
var _refreshCooldownTimer: float = 0.0
var _stockCooldowns: Dictionary = {}
var _stockVisible = false
var _repairVisible = false
var _uiInjected = false
var _savedSupply: Array = []
var _cashHooked = false
var _repairPanel: ScrollContainer = null
var _repairList: VBoxContainer = null

# Kill task tracking: task_id -> { "current": int, "target": int }
var _killProgress: Dictionary = {}

# Contract state: long-running kill contracts, one active per trader.
# Cleared on permadeath like rep. Persists across normal deaths.
# Structure: trader_name -> {
#   difficulty: int (0..4 = Easy..Master),
#   target: String (AI type name),
#   kill_count: int,
#   target_count: int,
#   weapon_type: String ("" = any),
#   progress: int,
#   completed: bool,
# }
var _contracts: Dictionary = {}

# Preview rolls for contracts not yet accepted. Rolled once when the
# Tasks tab first shows a trader's Accept button, then reused across
# rebuilds so the player sees a stable preview. Cleared when the player
# accepts (promoting to real contract) or abandons (letting a fresh
# roll happen next visit). Keyed by trader_name.
var _contractPreviews: Dictionary = {}

# Repair barter state: tracks stub items we've parented into supplyGrid
# so the vanilla trading UI can handle repairs like normal deals. Key is
# the stub's instance_id (ints survive queue_free, Node refs don't);
# value is {stub, target_element, target_file, cost}.
var _repairStubs: Dictionary = {}

var _lib = null

func _ready():
	_load_data()
	if _dailySeed == 0:
		_dailySeed = randi()
		_save_data()
	_build_item_pools()
	Engine.set_meta("TraderImprovements", self)

	if Engine.has_meta("RTVModLib"):
		var lib = Engine.get_meta("RTVModLib")
		if lib._is_ready:
			_on_lib_ready()
		else:
			lib.frameworks_ready.connect(_on_lib_ready)
	print("Trader Improvements V2: Loaded")

var _was_dead = false

func _unhandled_key_input(event):
	if event is InputEventKey and event.pressed and !event.echo:
		if event.keycode == KEY_F9:
			_dailySeed = randi()
			_dailyCompleted.clear()
			_killProgress.clear()
			_save_data()
			print("Trader Improvements V2: DEBUG — Rerolled daily tasks (seed=" + str(_dailySeed) + ")")

func _process(_delta):
	if gameData.isDead and !_was_dead:
		_was_dead = true
		if gameData.permadeath:
			# Permadeath wipes everything -- new save, new rep, new everything.
			_rep.clear()
			_dailyCompleted.clear()
			_killProgress.clear()
			_dailySeed = 0
			_notedDailies.clear()
			_contracts.clear()
			_contractPreviews.clear()
			_save_data()
			print("Trader Improvements V2: Cleared on permadeath")
		else:
			# Non-permadeath death: contracts must be completed in a
			# single life, so wipe them. Rep / dailies / seed persist.
			if not _contracts.is_empty():
				_contracts.clear()
				_save_data()
				print("Trader Improvements V2: Contracts cleared on death")
			_contractPreviews.clear()
	elif !gameData.isDead:
		if _was_dead:
			_load_data()
			if _dailySeed == 0:
				_dailySeed = randi()
				_save_data()
		_was_dead = false

func _on_lib_ready():
	_lib = Engine.get_meta("RTVModLib")

	# Interface hooks
	_lib.hook("interface-updatetraderinfo-post", _on_update_trader_info)
	_lib.hook("interface-initializetasks-post", _on_initialize_tasks)
	_lib.hook("interface-initializenotes-post", _on_initialize_notes)
	_lib.hook("interface-completedeal-pre", _on_complete_deal_pre)
	_lib.hook("interface-completedeal-post", _on_complete_deal_post)
	_lib.hook("interface-open-post", _on_open)
	_lib.hook("interface-close-pre", _on_close)
	_lib.hook("interface-_physics_process-post", _on_physics_process)
	_lib.hook("interface-_on_supply_pressed-pre", _on_supply_pressed)
	_lib.hook("interface-_on_tasks_pressed-pre", _on_tasks_pressed)

	# Task hooks
	_lib.hook("task-completed-post", _on_task_completed)
	# Vanilla trader tasks: hook Trader.CompleteTask so we award rep
	# when the player turns in any task (not just our daily extras).
	_lib.hook("trader-completetask-post", _on_trader_complete_task)

	# AI hooks for kill tracking
	_lib.hook("ai-death-post", _on_ai_death)

	print("Trader Improvements V2: Hooks registered")

# --- Interface reference helper ---

func _get_interface():
	var scene = get_tree().current_scene
	if !scene:
		return null
	return scene.get_node_or_null("Core/UI/Interface")

# --- Hook Callbacks: Interface ---

func _on_update_trader_info():
	var iface = _get_interface()
	if !iface or !iface.trader:
		return

	# Treat a freed _repLabel (post-respawn) as absent so we recreate it.
	var has_label := _repLabel != null and is_instance_valid(_repLabel)

	var statsPanel = iface.traderUI.get_node_or_null("Panel/Stats")
	if statsPanel and not has_label:
		statsPanel.offset_top = 216

	if not has_label:
		_repLabel = null
		var panel = iface.traderUI.get_node_or_null("Panel")
		if panel:
			_repLabel = Label.new()
			_repLabel.add_theme_font_size_override("font_size", 14)
			_repLabel.add_theme_color_override("font_color", Color(0, 1, 0, 1))
			_repLabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_repLabel.position = Vector2(16, 316)
			_repLabel.size = Vector2(176, 20)
			panel.add_child(_repLabel)

	if _repLabel:
		var rep = get_rep(iface.trader.traderData.name)
		var tier = get_rep_tier(iface.trader.traderData.name)
		var tierName = get_rep_tier_name(tier)
		_repLabel.text = tierName + " (" + str(rep) + ")"

func _on_initialize_tasks():
	var iface = _get_interface()
	if !iface or !iface.trader:
		return

	var trader_name: String = iface.trader.traderData.name

	# The vanilla InitializeTasks already ran (post hook). Prepend our
	# additions -- contracts first (above dailies), then dailies, then
	# vanilla tasks remain at the bottom.
	# Insertion order: append in document order, then move_child each
	# to index 0 in REVERSE so the final order is contract -> dailies
	# -> vanilla.
	var dailies = get_daily_tasks(trader_name)
	for daily_def in dailies:
		var is_completed = is_daily_completed(trader_name, daily_def["id"])
		var panel = _create_daily_task_ui(iface, daily_def, is_completed)
		iface.taskList.move_child(panel, 0)
	# Contract slot is always visible: either the active contract + its
	# progress + turn-in / abandon buttons, or an "Accept" button.
	var contract_panel = _create_contract_ui(iface, trader_name)
	if contract_panel != null:
		iface.taskList.move_child(contract_panel, 0)

	# Minimize completed regular tasks
	for child in iface.taskList.get_children():
		if child is PanelContainer and child.has_node("Margin/Elements"):
			# This is a vanilla task panel
			if "completed" in child and child.completed:
				child.custom_minimum_size.y = 0
				for element in child.get_node("Margin/Elements").get_children():
					if element.name != "Title" and element.name != "Highlight":
						element.hide()
				child.size.y = 0

func _on_initialize_notes():
	var iface = _get_interface()
	if !iface:
		return

	var noted = get_noted_dailies()
	if noted.size() == 0:
		return

	for note in noted:
		var panel = PanelContainer.new()
		iface.notesList.add_child(panel)

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

		if note.get("type", "deliver") == "contract":
			# Pull live progress from _contracts (contracts aren't
			# tracked in _killProgress, they have their own state).
			var trader_name: String = String(note.get("trader", ""))
			var c: Dictionary = _contracts.get(trader_name, {})
			var target_count: int = int(note.get("target_count", 0))
			var current: int = int(c.get("progress", 0))

			var descLabel = Label.new()
			descLabel.text = String(note.get("description", ""))
			descLabel.add_theme_font_size_override("font_size", 11)
			descLabel.modulate = Color(0.7, 0.7, 0.7)
			descLabel.autowrap_mode = TextServer.AUTOWRAP_WORD
			vbox.add_child(descLabel)

			var progressLabel = Label.new()
			progressLabel.text = "Progress: %d / %d" % [current, target_count]
			progressLabel.add_theme_font_size_override("font_size", 11)
			vbox.add_child(progressLabel)

			var progressBar = ProgressBar.new()
			progressBar.min_value = 0
			progressBar.max_value = target_count
			progressBar.value = current
			progressBar.custom_minimum_size = Vector2(0, 14)
			progressBar.show_percentage = false
			vbox.add_child(progressBar)

			var diff_idx: int = int(note.get("difficulty", 0))
			var rewardLabel = Label.new()
			var reward_items: String = contract_reward_summary(c)
			rewardLabel.text = "Reward: %d rep" % CONTRACT_REP_REWARDS[clampi(diff_idx, 0, CONTRACT_REP_REWARDS.size() - 1)]
			if reward_items != "":
				rewardLabel.text += " + " + reward_items
			rewardLabel.add_theme_font_size_override("font_size", 11)
			rewardLabel.modulate = Color(0.4, 1.0, 0.4)
			rewardLabel.autowrap_mode = TextServer.AUTOWRAP_WORD
			vbox.add_child(rewardLabel)
		elif note.get("type", "deliver") == "kill" and note.has("kill"):
			var kill = note["kill"]
			var current = _killProgress.get(note["id"], 0)
			var target = kill["count"]

			var progressLabel = Label.new()
			progressLabel.text = "Kills: " + str(current) + " / " + str(target)
			progressLabel.add_theme_font_size_override("font_size", 11)
			vbox.add_child(progressLabel)

			var progressBar = ProgressBar.new()
			progressBar.min_value = 0
			progressBar.max_value = target
			progressBar.value = current
			progressBar.custom_minimum_size = Vector2(0, 14)
			progressBar.show_percentage = false
			vbox.add_child(progressBar)

			var receiveText = "Reward: "
			for r in note.get("receive", []):
				var item_data = _find_item_data_by_file(r["file"])
				receiveText += (item_data.name if item_data else r["file"]) + " x" + str(r["amount"]) + "  "
			var rewardLabel = Label.new()
			rewardLabel.text = receiveText
			rewardLabel.add_theme_font_size_override("font_size", 11)
			rewardLabel.modulate = Color(0.4, 1.0, 0.4)
			vbox.add_child(rewardLabel)
		else:
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

	if noted.size() > 0:
		iface.notesHint.visible = false

# Store purchased items before vanilla CompleteDeal removes them
var _pending_bought = []

func _on_complete_deal_pre():
	_pending_bought.clear()
	var iface = _get_interface()
	if !iface:
		return
	# Repair stubs: apply repairs, deselect stubs so vanilla's supply
	# transfer loops treat them as not-in-the-deal (we don't want the
	# "fake repair item" copied into inventory).
	for element in iface.supplyGrid.get_children():
		if not element.has_meta("_ti_repair_target"):
			continue
		if not element.selected:
			continue
		var target = element.get_meta("_ti_repair_target")
		if target != null and is_instance_valid(target) and target.slotData:
			target.slotData.condition = 100.0
			if target.has_method("UpdateDetails"):
				target.UpdateDetails()
		element.selected = false
		# Hide selection visual so the stub doesn't look picked anymore
		# during the brief window before it queue_frees in the post-hook.
		if element.has_method("State"):
			element.State("Static")
	if _stockVisible:
		for element in iface.supplyGrid.get_children():
			if element.selected and element.slotData and element.slotData.itemData:
				_pending_bought.append(element.slotData.itemData.file)

func _on_complete_deal_post():
	var iface = _get_interface()
	if !iface or !iface.trader:
		return
	# Clean up any stubs we parented into supplyGrid. Queue-free them
	# and clear our tracking dict. Vanilla's supply-iteration already
	# ran in CompleteDeal -- our deselect in the pre-hook kept them off
	# its radar, but they're still parented here.
	var removed_any_stub := false
	for element in iface.supplyGrid.get_children():
		if element.has_meta("_ti_repair_target"):
			iface.supplyGrid.Pick(element)
			element.queue_free()
			removed_any_stub = true
	if removed_any_stub:
		_repairStubs.clear()
		# If we're still in repair mode, rebuild the repair list so the
		# just-fixed item drops out and stays consistent.
		if _repairVisible:
			_show_repair(iface)
	add_rep(iface.trader.traderData.name, 1)
	_on_update_trader_info()
	if _stockVisible:
		_add_stock_cooldowns(_pending_bought)
		iface.ClearSupplyGrid()
		_fill_stock_grid(iface)

func _on_open():
	var iface = _get_interface()
	if !iface:
		return

	# _uiInjected alone isn't a reliable check across respawns: when the
	# player dies and the Interface is torn down + rebuilt, our cached
	# button nodes get freed but _uiInjected stays true. Detect freed
	# refs and clear them unconditionally (even if iface.trader is null,
	# so the next interface-open with a trader will trigger a clean
	# re-inject below).
	# Death/respawn tears down Interface; our cached button refs go
	# stale. Detect freed refs here and clear them so the next trader-
	# open triggers a clean re-inject below.
	var stock_valid := _stockButton != null and is_instance_valid(_stockButton)
	if not stock_valid and _uiInjected:
		_uiInjected = false
		_stockButton = null
		_repairButton = null
		_refreshButton = null
		_repairPanel = null
		_repairList = null
		_repLabel = null
	if iface.trader and not _uiInjected:
		_inject_stock_ui(iface)
	# Guard the hide calls behind validity too -- a freed ref that we
	# didn't re-inject above (e.g. iface.trader is null) must not be
	# used. Check is_instance_valid every call since any tear-down
	# between open events could invalidate the ref.
	if _stockButton and is_instance_valid(_stockButton):
		_stockButton.hide()
	if _repairButton and is_instance_valid(_repairButton):
		_repairButton.hide()
	_stockVisible = false
	_repairVisible = false

	if iface.trader and _stockButton and is_instance_valid(_stockButton):
		if _tiSettings.stockReplenishCooldown >= 0:
			_stockButton.show()
		else:
			_stockButton.hide()
	# All three traders can repair something (see _can_trader_repair):
	# Doctor -> armor/helmet/clothing, Gunsmith -> weapons/attachments,
	# Generalist -> GENERALIST_REPAIR_WHITELIST (low-tier fallback).
	if iface.trader and _repairButton and is_instance_valid(_repairButton):
		var tname = iface.trader.traderData.name
		if tname == "Doctor" or tname == "Gunsmith" or tname == "Generalist":
			_repairButton.show()
		else:
			_repairButton.hide()
	if _tiSettings.refreshCooldown >= 0:
		if (!_refreshButton or !is_instance_valid(_refreshButton)) and _uiInjected:
			var buttonsContainer = iface.supplyButton.get_parent()
			if buttonsContainer:
				buttonsContainer.columns = 5
				_refreshButton = Button.new()
				_refreshButton.text = "Refresh"
				_refreshButton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				_refreshButton.size_flags_vertical = Control.SIZE_EXPAND_FILL
				_refreshButton.pressed.connect(_on_refresh_pressed)
				buttonsContainer.add_child(_refreshButton)
		if _refreshButton:
			_refreshButton.show()
	else:
		if _refreshButton:
			_refreshButton.hide()
	_hook_cash_system(iface)

func _on_close():
	if _stockVisible:
		var iface = _get_interface()
		if iface:
			_restore_supply(iface)
	_stockVisible = false
	_repairVisible = false
	if _repairPanel:
		_repairPanel.hide()

func _on_physics_process(delta = null):
	if _tiSettings.has_meta("refresh_changed") and _tiSettings.get_meta("refresh_changed"):
		_tiSettings.set_meta("refresh_changed", false)
		_refreshCooldownTimer = 0
		if _refreshButton:
			_refreshButton.disabled = false
			_refreshButton.text = "Refresh"

	if _refreshCooldownTimer > 0 and _refreshButton:
		var dt = get_process_delta_time()
		_refreshCooldownTimer -= dt
		if _refreshCooldownTimer <= 0:
			_refreshCooldownTimer = 0
			_refreshButton.disabled = false
			_refreshButton.text = "Refresh"
		else:
			_refreshButton.text = str(int(_refreshCooldownTimer)) + "s"

	if _stockVisible and _stockCooldowns.size() > 0:
		var now = Time.get_ticks_msec()
		var any_expired = false
		for file_name in _stockCooldowns:
			if now >= _stockCooldowns[file_name]:
				any_expired = true
				break
		if any_expired:
			var iface = _get_interface()
			if iface:
				iface.ClearSupplyGrid()
				_fill_stock_grid(iface)

func _on_supply_pressed():
	if _stockVisible:
		var iface = _get_interface()
		if iface:
			_restore_supply(iface)
	_hide_repair()

func _on_tasks_pressed():
	if _stockVisible:
		var iface = _get_interface()
		if iface:
			_restore_supply(iface)
	_hide_repair()

# --- Hook Callback: Task ---

func _on_task_completed():
	# Post hook on Task.Completed() — minimize the task panel
	# The task instance is not easily accessible from a post hook since
	# we don't receive the instance. This is handled by _on_initialize_tasks
	# which minimizes completed tasks when the task list is rebuilt.
	pass

# Post hook on Trader.CompleteTask(taskData). Fires whenever the player
# turns in any task (vanilla or mod), which is the right place to award
# rep: it's the final commit point after the delivery/reward logic ran.
# The trader instance is the caller; read traderData.name from there.
# Rep amount matches difficulty tier when available, else a flat 2.
func _on_trader_complete_task(_task_data = null):
	if _lib == null:
		return
	var trader_node = _lib._caller
	if trader_node == null or not is_instance_valid(trader_node):
		return
	if not ("traderData" in trader_node) or trader_node.traderData == null:
		return
	var trader_name: String = trader_node.traderData.name
	var reward := 2
	# Scale by vanilla TaskData.difficulty when present
	# ("Easy" / "Intermediate" / "Hard").
	if _task_data != null and "difficulty" in _task_data:
		match String(_task_data.difficulty):
			"Easy": reward = 1
			"Intermediate": reward = 2
			"Hard": reward = 4
	add_rep(trader_name, reward)
	_on_update_trader_info()

# --- Kill Task Tracking ---

func _on_ai_death(direction = null, force = null):
	var ai_node = _lib._caller
	if !ai_node:
		return

	# Identify AI type from scene path (e.g. "res://AI/Bandit/AI_Bandit.tscn")
	var ai_type = _get_ai_type(ai_node)
	if ai_type == "":
		return

	# Get player's active weapon type
	var weapon_type = _get_player_weapon_type()

	# Check time of day
	var is_night = Simulation.time < 600.0 or Simulation.time > 2100.0

	# Check all active kill dailies across all traders
	var progressed = false
	for trader_name in ["Generalist", "Doctor", "Gunsmith"]:
		var tasks = get_daily_tasks(trader_name)
		for task in tasks:
			if task["type"] != "kill":
				continue
			if is_daily_completed(trader_name, task["id"]):
				continue
			var kill = task["kill"]

			# Check target match
			if kill["target"] != ai_type:
				continue

			# Check weapon constraint
			if kill["weapon_type"] != "" and kill["weapon_type"] != weapon_type:
				continue

			# Check time constraint
			if kill["time"] == "night" and !is_night:
				continue
			if kill["time"] == "day" and is_night:
				continue

			# Progress this kill task
			if !_killProgress.has(task["id"]):
				_killProgress[task["id"]] = 0
			_killProgress[task["id"]] += 1
			progressed = true

			# Cap at target count
			if _killProgress[task["id"]] > kill["count"]:
				_killProgress[task["id"]] = kill["count"]

	# Contracts also track kills. Each trader has at most one contract,
	# and only bandit/guard/military kills count depending on trader.
	# Weapon constraint filters as with dailies; no time-of-day filter.
	for trader_name in ["Generalist", "Doctor", "Gunsmith"]:
		if not _contracts.has(trader_name):
			continue
		var c: Dictionary = _contracts[trader_name]
		if c.get("completed", false):
			continue
		if c.get("target", "") != ai_type:
			continue
		var wtype: String = c.get("weapon_type", "")
		if wtype != "" and wtype != weapon_type:
			continue
		c["progress"] = int(c.get("progress", 0)) + 1
		if c["progress"] >= int(c.get("target_count", 0)):
			c["progress"] = int(c["target_count"])
			c["completed"] = true
		_contracts[trader_name] = c
		progressed = true

	if progressed:
		_save_data()
		print("Trader Improvements V2: Kill progress updated — " + str(_killProgress))
		# Live-update notes if the interface is open
		var iface = _get_interface()
		if iface and iface.notesUI and iface.notesUI.visible:
			iface.InitializeNotes()

func _get_ai_type(ai_node) -> String:
	var path = ai_node.scene_file_path
	if path == "":
		# Fallback: check node name
		path = ai_node.name
	if "Bandit" in path:
		return "Bandit"
	if "Guard" in path:
		return "Guard"
	if "Military" in path:
		return "Military"
	return ""

func _get_player_weapon_type() -> String:
	# "Last child" isn't reliable: RigManager holds multiple rigs (primary,
	# secondary, knife) and the order depends on draw history, not which
	# weapon is currently active. Find the rig that's actually visible --
	# only one rig shows at a time when the player fires.
	var scene = get_tree().current_scene
	if !scene:
		return ""
	var rig_manager = scene.get_node_or_null("Core/Camera/Manager")
	if !rig_manager:
		return ""
	for rig in rig_manager.get_children():
		if not (rig is WeaponRig):
			continue
		if not rig.visible:
			continue
		if rig.data:
			return rig.data.weaponType
	return ""


# --- Cash System ---

func _hook_cash_system(iface):
	if _cashHooked:
		return
	if !Engine.has_meta("CashMain"):
		return
	var cash = Engine.get_meta("CashMain")
	if cash.has_signal("cash_sold"):
		cash.cash_sold.connect(_on_cash_sold)
	if cash.has_signal("cash_bought"):
		cash.cash_bought.connect(_on_cash_bought)
	_cashHooked = true

func _on_cash_sold(amount, items):
	var iface = _get_interface()
	if !iface or !iface.trader:
		return
	add_rep(iface.trader.traderData.name, 1)
	_on_update_trader_info()

func _on_cash_bought(amount, items):
	var iface = _get_interface()
	if !iface or !iface.trader:
		return
	add_rep(iface.trader.traderData.name, 1)
	_on_update_trader_info()
	if _stockVisible:
		var bought = []
		for item in items:
			if item and "slotData" in item and item.slotData and item.slotData.itemData:
				bought.append(item.slotData.itemData.file)
			elif item is SlotData and item.itemData:
				bought.append(item.itemData.file)
			elif item is ItemData:
				bought.append(item.file)
		_add_stock_cooldowns(bought)
		iface.ClearSupplyGrid()
		_fill_stock_grid(iface)

# --- Stock UI ---

func _inject_stock_ui(iface):
	if _uiInjected:
		return

	var buttonsContainer = iface.supplyButton.get_parent()
	if buttonsContainer:
		buttonsContainer.columns = 4
		_stockButton = Button.new()
		_stockButton.text = "Stock"
		_stockButton.toggle_mode = true
		_stockButton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_stockButton.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_stockButton.button_group = iface.supplyButton.button_group
		_stockButton.pressed.connect(_on_stock_pressed)
		buttonsContainer.add_child(_stockButton)

		_repairButton = Button.new()
		_repairButton.text = "Repair"
		_repairButton.toggle_mode = true
		_repairButton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_repairButton.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_repairButton.button_group = iface.supplyButton.button_group
		_repairButton.pressed.connect(_on_repair_pressed)
		buttonsContainer.add_child(_repairButton)

		if _tiSettings.refreshCooldown >= 0:
			buttonsContainer.columns = 5
			_refreshButton = Button.new()
			_refreshButton.text = "Refresh"
			_refreshButton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_refreshButton.size_flags_vertical = Control.SIZE_EXPAND_FILL
			_refreshButton.pressed.connect(_on_refresh_pressed)
			buttonsContainer.add_child(_refreshButton)
		else:
			buttonsContainer.columns = 4

	# Repair panel overlays supplyGrid (covers it visually). supplyGrid
	# itself stays in the tree because vanilla CalculateDeal iterates
	# its children for request-value totals -- we inject barter stubs
	# there that report Value() == repair cost. The panel hides when
	# the repair tab is closed.
	_repairPanel = ScrollContainer.new()
	_repairPanel.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var grid_parent: Node = iface.supplyGrid.get_parent()
	grid_parent.add_child(_repairPanel)
	_repairPanel.anchor_left = iface.supplyGrid.anchor_left
	_repairPanel.anchor_top = iface.supplyGrid.anchor_top
	_repairPanel.anchor_right = iface.supplyGrid.anchor_right
	_repairPanel.anchor_bottom = iface.supplyGrid.anchor_bottom
	_repairPanel.offset_left = iface.supplyGrid.offset_left
	_repairPanel.offset_top = iface.supplyGrid.offset_top
	_repairPanel.offset_right = iface.supplyGrid.offset_right
	_repairPanel.offset_bottom = iface.supplyGrid.offset_bottom
	_repairPanel.size = iface.supplyGrid.size
	_repairPanel.position = iface.supplyGrid.position
	_repairPanel.hide()

	_repairList = VBoxContainer.new()
	_repairList.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_repairList.add_theme_constant_override("separation", 4)
	_repairPanel.add_child(_repairList)

	_uiInjected = true

func _on_refresh_pressed():
	var iface = _get_interface()
	if !iface or !iface.trader:
		return
	if _tiSettings.refreshCooldown > 0 and _refreshCooldownTimer > 0:
		return
	if _stockVisible:
		_restore_supply(iface)
		_stockVisible = false
		iface.supplyButton.button_pressed = true
	iface.trader.CreateSupply()
	iface.Resupply()
	iface.PlayClick()
	if _tiSettings.refreshCooldown > 0 and _refreshButton:
		_refreshCooldownTimer = _tiSettings.refreshCooldown
		_refreshButton.disabled = true
		_refreshButton.text = str(_tiSettings.refreshCooldown) + "s"

func _on_stock_pressed():
	var iface = _get_interface()
	if !iface:
		return
	_hide_repair()
	iface.tasksUI.hide()
	iface.supplyUI.show()
	iface.ResetTrading()
	iface.ResetInput()

	if !_stockVisible:
		_savedSupply.clear()
		for sd in iface.trader.supply:
			_savedSupply.append(sd)
		iface.ClearSupplyGrid()
		_fill_stock_grid(iface)
		_stockVisible = true
	else:
		_restore_supply(iface)
		_stockVisible = false

	iface.PlayClick()

func _restore_supply(iface):
	iface.ClearSupplyGrid()
	if _savedSupply.size() > 0:
		iface.trader.supply = _savedSupply.duplicate()
		iface.FillSupplyGrid()
	_savedSupply.clear()
	_stockVisible = false

func _fill_stock_grid(iface):
	if !iface.trader:
		return

	var now = Time.get_ticks_msec()
	var expired = []
	for file_name in _stockCooldowns:
		if now >= _stockCooldowns[file_name]:
			expired.append(file_name)
	for file_name in expired:
		_stockCooldowns.erase(file_name)

	var tier = get_rep_tier(iface.trader.traderData.name)
	var stock_files = get_stock_items(iface.trader.traderData.name, tier)

	var stock_map: Dictionary = {}
	for file_name in stock_files:
		if _stockCooldowns.has(file_name):
			continue
		if stock_map.has(file_name):
			continue
		var item_data = _find_item_data_by_file(file_name)
		if item_data:
			var sd = SlotData.new()
			sd.itemData = item_data
			sd.condition = 100
			if item_data.stackable and item_data.defaultAmount > 0:
				sd.amount = item_data.defaultAmount
			stock_map[file_name] = sd

	for file_name in stock_map:
		iface.Create(stock_map[file_name], iface.supplyGrid, false)

func _add_stock_cooldowns(bought):
	var cooldown = _tiSettings.stockReplenishCooldown
	if cooldown <= 0:
		return
	var now = Time.get_ticks_msec()
	for file_name in bought:
		_stockCooldowns[file_name] = now + cooldown * 1000.0

# --- Daily Task UI ---

func _create_daily_task_ui(iface, daily_def, is_completed):
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 0)
	iface.taskList.add_child(panel)

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

	var titleRow = HBoxContainer.new()
	vbox.add_child(titleRow)

	var titleLabel = Label.new()
	titleLabel.text = daily_def["name"] + " [Daily]"
	titleLabel.add_theme_font_size_override("font_size", 13)
	titleLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titleRow.add_child(titleLabel)

	var desc = Label.new()
	desc.text = daily_def["description"]
	desc.add_theme_font_size_override("font_size", 11)
	desc.modulate = Color(0.7, 0.7, 0.7)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(desc)

	if daily_def["type"] == "kill":
		# Kill task: show progress bar
		var kill = daily_def["kill"]
		var current = _killProgress.get(daily_def["id"], 0)
		var target = kill["count"]
		if is_completed:
			current = target

		var progressLabel = Label.new()
		progressLabel.text = "Progress: " + str(current) + " / " + str(target)
		progressLabel.add_theme_font_size_override("font_size", 11)
		vbox.add_child(progressLabel)

		var progressBar = ProgressBar.new()
		progressBar.min_value = 0
		progressBar.max_value = target
		progressBar.value = current
		progressBar.custom_minimum_size = Vector2(0, 14)
		progressBar.show_percentage = false
		vbox.add_child(progressBar)

		var receiveText = "Reward: "
		for r in daily_def["receive"]:
			var item_data = _find_item_data_by_file(r["file"])
			receiveText += (item_data.name if item_data else r["file"]) + " x" + str(r["amount"]) + "  "

		var receiveLabel = Label.new()
		receiveLabel.text = receiveText
		receiveLabel.add_theme_font_size_override("font_size", 11)
		receiveLabel.modulate = Color(0.4, 1.0, 0.4)
		vbox.add_child(receiveLabel)
	else:
		# Deliver task: show deliver/receive
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
		if daily_def["type"] == "kill":
			var kill = daily_def["kill"]
			var current = _killProgress.get(daily_def["id"], 0)
			if current < kill["count"]:
				completeBtn.disabled = true
				completeBtn.text = "Kills: " + str(current) + "/" + str(kill["count"])
		completeBtn.pressed.connect(_on_daily_complete.bind(iface, daily_def, panel))
		btnRow.add_child(completeBtn)

	var is_noted = is_daily_noted(daily_def["id"])
	var noteBtn = Button.new()
	noteBtn.custom_minimum_size = Vector2(100, 26)
	noteBtn.add_theme_font_size_override("font_size", 11)
	if is_noted:
		noteBtn.text = "Added"
		noteBtn.disabled = true
	else:
		noteBtn.text = "Add to Notes"
		noteBtn.pressed.connect(_on_daily_note.bind(iface, daily_def, noteBtn))
	btnRow.add_child(noteBtn)

	return panel

func _on_daily_note(iface, daily_def, btn):
	if !iface.trader:
		return
	add_daily_note(daily_def, iface.trader.traderData.name)
	btn.text = "Added"
	btn.disabled = true
	# Trigger notes rebuild via the vanilla method
	iface.InitializeNotes()
	iface.PlayClick()

func _on_daily_complete(iface, daily_def, panel):
	if !iface.trader:
		return

	if daily_def["type"] == "kill":
		var kill = daily_def["kill"]
		var current = _killProgress.get(daily_def["id"], 0)
		if current < kill["count"]:
			iface.PlayError()
			return
		_killProgress.erase(daily_def["id"])
	else:
		for d in daily_def["deliver"]:
			if !_has_inventory_item(iface, d["file"], d["amount"]):
				iface.PlayError()
				return
		for d in daily_def["deliver"]:
			_remove_inventory_item(iface, d["file"], d["amount"])

	for r in daily_def["receive"]:
		var item_data = _find_item_data_by_file(r["file"])
		if item_data:
			if item_data.stackable:
				var sd = SlotData.new()
				sd.itemData = item_data
				sd.amount = r["amount"]
				sd.condition = 100
				iface.Create(sd, iface.inventoryGrid, true)
			else:
				for _i in r["amount"]:
					var sd = SlotData.new()
					sd.itemData = item_data
					sd.condition = 100
					iface.Create(sd, iface.inventoryGrid, true)

	complete_daily(iface.trader.traderData.name, daily_def["id"])
	add_rep(iface.trader.traderData.name, 2)

	_on_update_trader_info()
	iface.UpdateStats(true)
	iface.PlayClick()
	iface.trader.PlayTraderTask()

	# Rebuild tasks
	iface._on_tasks_pressed()

func _on_remove_daily_note(task_id):
	remove_daily_note(task_id)
	var iface = _get_interface()
	if iface:
		iface.InitializeNotes()
		iface.PlayClick()

# --- Contract UI ---

# Build the contract panel for this trader. One of three states:
#   no contract -> "Accept Contract" button
#   active      -> description + progress bar + Abandon
#   completed   -> description + "Turn In" + Abandon
# Returns the created panel (or null on error). Caller is responsible
# for positioning it in taskList.
func _create_contract_ui(iface, trader_name: String):
	var contract: Dictionary = get_contract(trader_name)
	var panel = PanelContainer.new()
	iface.taskList.add_child(panel)

	var highlight = ColorRect.new()
	highlight.anchors_preset = Control.PRESET_FULL_RECT
	highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Distinct blue tint so contracts stand out from dailies (yellow).
	if contract.is_empty():
		highlight.color = Color8(80, 160, 255, 24)
	elif contract.get("completed", false):
		highlight.color = Color8(0, 255, 0, 32)
	else:
		highlight.color = Color8(80, 160, 255, 32)
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

	var title = Label.new()
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titleRow.add_child(title)

	if contract.is_empty():
		# Preview the exact contract the player will accept (cached per
		# trader until accept/abandon so it doesn't shuffle on tab
		# rebuilds). Show full requirements including weapon constraint
		# so the player commits with full information.
		var preview_contract: Dictionary = get_contract_preview(trader_name)
		var diff_idx: int = int(preview_contract.get("difficulty", 0))
		title.text = "Contract [Available]"
		var preview = Label.new()
		preview.text = contract_description(preview_contract)
		preview.add_theme_font_size_override("font_size", 11)
		preview.modulate = Color(0.7, 0.9, 1.0)
		vbox.add_child(preview)

		var rew_preview = Label.new()
		var reward_text: String = contract_reward_summary(preview_contract)
		rew_preview.text = "Reward: %d rep" % CONTRACT_REP_REWARDS[diff_idx]
		if reward_text != "":
			rew_preview.text += " + " + reward_text
		rew_preview.add_theme_font_size_override("font_size", 11)
		rew_preview.modulate = Color(0.4, 1.0, 0.4)
		rew_preview.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(rew_preview)

		var btnRow = HBoxContainer.new()
		btnRow.add_theme_constant_override("separation", 4)
		vbox.add_child(btnRow)

		var acceptBtn = Button.new()
		acceptBtn.text = "Accept Contract"
		acceptBtn.custom_minimum_size = Vector2(140, 26)
		acceptBtn.add_theme_font_size_override("font_size", 11)
		acceptBtn.pressed.connect(_on_contract_accept.bind(iface, trader_name))
		btnRow.add_child(acceptBtn)
		return panel

	# Active or completed contract
	title.text = "Contract: " + contract_description(contract)

	var progress: int = int(contract.get("progress", 0))
	var target_count: int = int(contract.get("target_count", 0))
	var diff_idx: int = int(contract.get("difficulty", 0))

	var progressLabel = Label.new()
	progressLabel.text = "Progress: %d / %d" % [progress, target_count]
	progressLabel.add_theme_font_size_override("font_size", 11)
	vbox.add_child(progressLabel)

	var progressBar = ProgressBar.new()
	progressBar.min_value = 0
	progressBar.max_value = target_count
	progressBar.value = progress
	progressBar.custom_minimum_size = Vector2(0, 14)
	progressBar.show_percentage = false
	vbox.add_child(progressBar)

	var rewLabel = Label.new()
	var reward_text: String = contract_reward_summary(contract)
	rewLabel.text = "Reward: %d rep" % CONTRACT_REP_REWARDS[clampi(diff_idx, 0, CONTRACT_REP_REWARDS.size() - 1)]
	if reward_text != "":
		rewLabel.text += " + " + reward_text
	rewLabel.add_theme_font_size_override("font_size", 11)
	rewLabel.modulate = Color(0.4, 1.0, 0.4)
	rewLabel.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(rewLabel)

	var btnRow = HBoxContainer.new()
	btnRow.add_theme_constant_override("separation", 4)
	vbox.add_child(btnRow)

	if contract.get("completed", false):
		var turnInBtn = Button.new()
		turnInBtn.text = "Turn In"
		turnInBtn.custom_minimum_size = Vector2(100, 26)
		turnInBtn.add_theme_font_size_override("font_size", 11)
		turnInBtn.pressed.connect(_on_contract_turn_in.bind(iface, trader_name))
		btnRow.add_child(turnInBtn)

	var abandonCost: int = CONTRACT_ABANDON_COSTS[clampi(diff_idx, 0, CONTRACT_ABANDON_COSTS.size() - 1)]
	var abandonBtn = Button.new()
	abandonBtn.text = "Abandon (-%d rep)" % abandonCost
	abandonBtn.custom_minimum_size = Vector2(140, 26)
	abandonBtn.add_theme_font_size_override("font_size", 11)
	abandonBtn.pressed.connect(_on_contract_abandon.bind(iface, trader_name))
	btnRow.add_child(abandonBtn)

	# Add-to-notes button (same UX as dailies). Disabled once added;
	# remove happens from the notes panel like with daily notes.
	var is_noted: bool = is_daily_noted(contract_note_id(trader_name))
	var noteBtn = Button.new()
	noteBtn.custom_minimum_size = Vector2(100, 26)
	noteBtn.add_theme_font_size_override("font_size", 11)
	if is_noted:
		noteBtn.text = "Added"
		noteBtn.disabled = true
	else:
		noteBtn.text = "Add to Notes"
		noteBtn.pressed.connect(_on_contract_note.bind(iface, trader_name, noteBtn))
	btnRow.add_child(noteBtn)
	return panel

func _on_contract_note(iface, trader_name: String, btn) -> void:
	add_contract_note(trader_name)
	btn.text = "Added"
	btn.disabled = true
	iface.InitializeNotes()
	iface.PlayClick()

func _on_contract_accept(iface, trader_name: String) -> void:
	accept_contract(trader_name)
	iface.PlayClick()
	# Rebuild task list so the contract panel reflects the new state.
	iface._on_tasks_pressed()

func _on_contract_abandon(iface, trader_name: String) -> void:
	abandon_contract(trader_name)
	_on_update_trader_info()
	iface.PlayClick()
	iface._on_tasks_pressed()

func _on_contract_turn_in(iface, trader_name: String) -> void:
	if not turn_in_contract(trader_name, iface):
		iface.PlayError()
		return
	_on_update_trader_info()
	iface.UpdateStats(true)
	iface.PlayClick()
	iface.trader.PlayTraderTask()
	iface._on_tasks_pressed()

func _has_inventory_item(iface, file_name, amount):
	var found = 0
	for element in iface.inventoryGrid.get_children():
		if element.slotData and element.slotData.itemData:
			if element.slotData.itemData.file == file_name:
				if element.slotData.itemData.stackable:
					found += element.slotData.amount
				else:
					found += 1
	return found >= amount

func _remove_inventory_item(iface, file_name, amount):
	var remaining = amount
	var to_remove = []

	for element in iface.inventoryGrid.get_children():
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
		iface.inventoryGrid.Pick(element)
		element.queue_free()

# --- Repair Service ---

func _on_repair_pressed():
	var iface = _get_interface()
	if !iface:
		return
	if _stockVisible:
		_restore_supply(iface)
		_stockVisible = false
	iface.tasksUI.hide()
	iface.supplyUI.show()
	iface.ResetTrading()
	iface.ResetInput()

	if !_repairVisible:
		_show_repair(iface)
		_repairVisible = true
	else:
		_hide_repair()
		_repairVisible = false
	iface.PlayClick()

func _show_repair(iface):
	if !_repairPanel or !_repairList:
		return

	# Clear previous entries
	for child in _repairList.get_children():
		child.queue_free()

	var trader_name = iface.trader.traderData.name
	var tier = get_rep_tier(trader_name)
	# Discount: 5% per rep tier
	var discount = tier * 0.05

	# Collect repairable items from inventory + equipment.
	var items = []
	for element in iface.inventoryGrid.get_children():
		if element.slotData and element.slotData.itemData:
			var it = element.slotData.itemData
			if it.showCondition and element.slotData.condition < 100:
				if _can_trader_repair(trader_name, it):
					items.append({"element": element, "slot": "inventory"})
	for equipSlot in iface.equipment.get_children():
		if equipSlot is Slot and equipSlot.get_child_count() > 0:
			var slotItem = equipSlot.get_child(0)
			if slotItem.slotData and slotItem.slotData.itemData:
				var it2 = slotItem.slotData.itemData
				if it2.showCondition and slotItem.slotData.condition < 100:
					if _can_trader_repair(trader_name, it2):
						items.append({"element": slotItem, "slot": equipSlot.name})

	if items.size() == 0:
		var empty = Label.new()
		empty.text = "No items to repair."
		empty.add_theme_font_size_override("font_size", 12)
		empty.modulate = Color(0.5, 0.5, 0.5)
		_repairList.add_child(empty)
	else:
		# Header
		var header = Label.new()
		header.text = "Repair Service" + (" — " + str(int(discount * 100)) + "% discount" if discount > 0 else "")
		header.add_theme_font_size_override("font_size", 13)
		_repairList.add_child(header)
		_repairList.add_child(HSeparator.new())

		for item_info in items:
			_add_repair_row(iface, item_info["element"], discount)

	_repairPanel.show()
	# Hide supplyGrid visually -- the repair panel sits on top. The grid
	# node stays in the tree so vanilla CalculateDeal can still iterate
	# its children (our barter stubs live there).
	iface.supplyGrid.hide()

func _hide_repair():
	_repairVisible = false
	if _repairPanel:
		_repairPanel.hide()
	# Tear down any barter stubs we parented into supplyGrid, clear
	# any pending deal state, restore supplyGrid visibility.
	var iface = _get_interface()
	if iface:
		_clear_repair_stubs(iface)
		iface.ResetTrading()
		iface.supplyGrid.show()

func _clear_repair_stubs(iface):
	for element in iface.supplyGrid.get_children():
		if element.has_meta("_ti_repair_target"):
			iface.supplyGrid.Pick(element)
			element.queue_free()
	_repairStubs.clear()

# Generalist's whitelist: a few low-tier items from each specialist's
# domain. Lets the player patch basic gear without needing a specialist
# at hand. Stays intentionally narrow -- the specialists remain the
# go-to for most repairs.
const GENERALIST_REPAIR_WHITELIST := [
	# Low-tier armor
	"Armor_Plate_II",
	# Low-tier weapons across categories (pistol, bolt, shotgun, SMGs, short rifle)
	"Makarov",
	"Mosin",
	"Remington_870",
	"MP5K",
	"AKS-74U",
]

func _can_trader_repair(trader_name, item_data):
	if trader_name == "Gunsmith":
		return item_data.type == "Weapon" or item_data.type == "Attachment"
	elif trader_name == "Doctor":
		return item_data.type == "Armor" or item_data.type == "Clothing" or item_data.type == "Helmet"
	elif trader_name == "Generalist":
		return item_data.file in GENERALIST_REPAIR_WHITELIST
	return false

func _calc_repair_cost(item_data, condition, discount):
	# Full value at 0% condition, scales linearly with damage. Tier
	# discount shaves off the top (5% per tier).
	var damage_pct = (100.0 - condition) / 100.0
	var base_cost = int(item_data.value * damage_pct)
	base_cost = max(base_cost, 1)
	var final_cost = int(base_cost * (1.0 - discount))
	return max(final_cost, 1)

func _add_repair_row(iface, element, discount):
	var sd = element.slotData
	var item_data = sd.itemData
	var cost = _calc_repair_cost(item_data, sd.condition, discount)

	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_repairList.add_child(row)

	# Item name + condition
	var info_col = VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info_col)

	var name_lbl = Label.new()
	name_lbl.text = item_data.name
	name_lbl.add_theme_font_size_override("font_size", 12)
	info_col.add_child(name_lbl)

	var cond_lbl = Label.new()
	cond_lbl.text = "Condition: " + str(int(sd.condition)) + "%"
	cond_lbl.add_theme_font_size_override("font_size", 11)
	if sd.condition < 30:
		cond_lbl.modulate = Color(1.0, 0.3, 0.3)
	elif sd.condition < 60:
		cond_lbl.modulate = Color(1.0, 0.7, 0.3)
	else:
		cond_lbl.modulate = Color(0.7, 0.7, 0.7)
	info_col.add_child(cond_lbl)

	# Cost
	var cost_lbl = Label.new()
	cost_lbl.text = "Cost: " + str(cost)
	cost_lbl.add_theme_font_size_override("font_size", 11)
	cost_lbl.custom_minimum_size.x = 80
	row.add_child(cost_lbl)

	# Barter button: toggles a stub in supplyGrid that vanilla's
	# CalculateDeal/CompleteDeal treat as a normal supply item with
	# Value() == repair cost. The slider + Accept button all "just work".
	var barter_btn = Button.new()
	barter_btn.text = "Barter"
	barter_btn.custom_minimum_size = Vector2(70, 26)
	barter_btn.add_theme_font_size_override("font_size", 11)
	barter_btn.pressed.connect(_on_repair_barter_toggle.bind(iface, element, cost, barter_btn))
	row.add_child(barter_btn)

	# Rep button: pays using trader rep. Cost = ceil(final_cost / 50),
	# minimum 1. Always available regardless of tier.
	var rep_cost = int(ceil(cost / 50.0))
	if rep_cost < 1:
		rep_cost = 1
	var rep_btn = Button.new()
	rep_btn.text = "Rep (%d)" % rep_cost
	rep_btn.custom_minimum_size = Vector2(70, 26)
	rep_btn.add_theme_font_size_override("font_size", 11)
	rep_btn.pressed.connect(_on_repair_rep.bind(iface, element, rep_cost, rep_btn, cond_lbl))
	row.add_child(rep_btn)

	# Cash repair button (if Cash System available)
	if Engine.has_meta("CashMain"):
		var cash_btn = Button.new()
		cash_btn.text = "Cash"
		cash_btn.custom_minimum_size = Vector2(60, 26)
		cash_btn.add_theme_font_size_override("font_size", 11)
		cash_btn.pressed.connect(_on_repair_cash.bind(iface, element, cost, cash_btn, cond_lbl, discount))
		row.add_child(cash_btn)

	_repairList.add_child(HSeparator.new())

func _on_repair_barter_toggle(iface, target_element, cost, btn):
	# Toggle a repair stub in supplyGrid. The stub is a minimal Control
	# that reports Value() == repair cost and holds a _ti_repair_target
	# meta pointing at the real item to fix. Vanilla's CalculateDeal
	# sums selected supply elements' Value()s into the request side of
	# the slider; Accept routes through CompleteDeal, where our pre-hook
	# intercepts stubs with the target meta, applies repairs, and
	# deselects so vanilla's supply-transfer loops skip them.
	var target_id: int = target_element.get_instance_id()
	# If a stub for this target already exists, toggle its selection.
	for element in iface.supplyGrid.get_children():
		if element.has_meta("_ti_repair_target") \
				and element.get_meta("_ti_repair_target") == target_element:
			element.selected = not element.selected
			if element.has_method("State"):
				element.State("Selected" if element.selected else "Static")
			btn.text = "Selected" if element.selected else "Barter"
			iface.CalculateDeal()
			iface.PlayClick()
			return
	# No stub yet -- build one. Stub is a barebones Control with enough
	# fields for vanilla CalculateDeal (.selected, .Value(), .slotData,
	# .State) to interact. We inject a script at instantiation so the
	# Value() method returns our repair cost without touching the target
	# item's real slotData.
	var stub := _make_repair_stub(target_element, cost)
	stub.selected = true
	iface.supplyGrid.add_child(stub)
	_repairStubs[target_id] = {
		"stub": stub,
		"target": target_element,
		"cost": cost,
	}
	btn.text = "Selected"
	iface.CalculateDeal()
	iface.PlayClick()

# Build a minimal stub Control that vanilla's CalculateDeal + CompleteDeal
# treat as if it were a real supply item. Only the subset of Item.gd's
# interface that those two functions touch needs to be present.
func _make_repair_stub(target_element, cost: int) -> Control:
	var script := GDScript.new()
	script.source_code = """
extends Control

var selected: bool = false
var slotData: SlotData = null
var _value: int = 0

func Value() -> int:
	return _value

func State(_s: String) -> void:
	pass
"""
	script.reload()
	var stub = Control.new()
	stub.set_script(script)
	# Minimal slotData so any vanilla code that reads slotData.itemData
	# doesn't crash. Reuse target's slotData -- we never let vanilla
	# touch it because our pre-hook deselects before transfer loops.
	stub.slotData = target_element.slotData
	stub.set("_value", cost)
	stub.set_meta("_ti_repair_target", target_element)
	stub.set_meta("_ti_repair_cost", cost)
	return stub

func _on_repair_rep(iface, element, rep_cost, btn, cond_lbl):
	var trader_name = iface.trader.traderData.name
	var current_rep = get_rep(trader_name)
	if current_rep < rep_cost:
		iface.PlayError()
		return
	# Deduct the rep cost. Do NOT fire the usual +1 rep gain: the
	# player is paying in rep here, so crediting them back 1 would
	# understate the actual cost (net -1 regardless of rep_cost).
	_rep[trader_name] = current_rep - rep_cost
	_save_data()
	element.slotData.condition = 100.0
	element.UpdateDetails()
	_on_update_trader_info()
	iface.UpdateStats(true)
	iface.PlayClick()
	iface.trader.PlayTraderTrade()
	btn.text = "Done"
	btn.disabled = true
	cond_lbl.text = "Condition: 100%"
	cond_lbl.modulate = Color(0.4, 1.0, 0.4)

func _on_repair_cash(iface, element, cost, btn, cond_lbl, discount):
	if !Engine.has_meta("CashMain"):
		return
	var cash = Engine.get_meta("CashMain")
	if cash.CountCash() < cost:
		iface.PlayError()
		return

	if !cash.RemoveCash(cost):
		iface.PlayError()
		return

	element.slotData.condition = 100.0
	element.UpdateDetails()

	add_rep(iface.trader.traderData.name, 1)
	_on_update_trader_info()
	iface.UpdateStats(true)
	iface.PlayClick()
	iface.trader.PlayTraderTrade()

	btn.text = "Done"
	btn.disabled = true
	cond_lbl.text = "Condition: 100%"
	cond_lbl.modulate = Color(0.4, 1.0, 0.4)

func _find_item_data_by_file(file_name):
	# Route through the mod loader's items registry. It resolves both
	# vanilla items (from LT_Master) and mod-registered ones uniformly.
	# Falls back to the Database.get + sibling .tres trick if the registry
	# isn't initialized yet.
	if _lib != null:
		var resolved = _lib.get_entry(_lib.Registry.ITEMS, file_name)
		if resolved != null and resolved is ItemData:
			return resolved
	var scene = Database.get(file_name)
	if scene and scene is PackedScene:
		var path = scene.resource_path.replace(".tscn", ".tres")
		if ResourceLoader.exists(path):
			var res = load(path)
			if res is ItemData:
				return res
	return null

# --- Item Pool Building ---

func _build_item_pools():
	_traderPools.clear()
	for trader_name in ["Generalist", "Doctor", "Gunsmith"]:
		var deliver_items = []
		var reward_items = []

		for item in LT_Master.items:
			if !item:
				continue
			var tagged = false
			if trader_name == "Generalist" and item.generalist:
				tagged = true
			elif trader_name == "Doctor" and item.doctor:
				tagged = true
			elif trader_name == "Gunsmith" and item.gunsmith:
				tagged = true
			if !tagged:
				continue

			if item.type == "Furniture" or item.type == "Weapon" or item.type == "Key":
				continue

			if item.value <= 200:
				deliver_items.append(item)
			if item.value >= 50:
				reward_items.append(item)

		_traderPools[trader_name] = {
			"deliver": deliver_items,
			"reward": reward_items
		}

# --- Rep System ---

func get_rep(trader_name):
	return _rep.get(trader_name, 0)

func add_rep(trader_name, amount):
	_rep[trader_name] = get_rep(trader_name) + amount
	_save_data()

func get_rep_tier(trader_name):
	var rep = get_rep(trader_name)
	var thresholds = _tiSettings.repThresholds.get(trader_name, [100, 200, 300, 400, 500])
	if rep >= thresholds[4]:
		return 5
	elif rep >= thresholds[3]:
		return 4
	elif rep >= thresholds[2]:
		return 3
	elif rep >= thresholds[1]:
		return 2
	elif rep >= thresholds[0]:
		return 1
	return 0

func get_rep_tier_name(tier):
	match tier:
		0: return "Unknown"
		1: return "Acquaintance"
		2: return "Trusted"
		3: return "Reliable"
		4: return "Valued"
		5: return "Partner"
	return "Unknown"

# --- Daily Tasks ---

func get_current_day():
	return Simulation.day

func is_daily_completed(trader_name, task_id):
	_check_daily_reset()
	if !_dailyCompleted.has(trader_name):
		return false
	return task_id in _dailyCompleted[trader_name]

func complete_daily(trader_name, task_id):
	_check_daily_reset()
	if !_dailyCompleted.has(trader_name):
		_dailyCompleted[trader_name] = []
	if task_id not in _dailyCompleted[trader_name]:
		_dailyCompleted[trader_name].append(task_id)
	_save_data()

func is_daily_noted(task_id):
	for note in _notedDailies:
		if note.get("id", "") == task_id:
			return true
	return false

func add_daily_note(daily_def, trader_name):
	if is_daily_noted(daily_def["id"]):
		return
	var note = {
		"id": daily_def["id"],
		"trader": trader_name,
		"name": daily_def["name"],
		"description": daily_def["description"],
		"type": daily_def.get("type", "deliver"),
		"deliver": daily_def.get("deliver", []),
		"receive": daily_def.get("receive", []),
	}
	if daily_def.get("type", "") == "kill":
		note["kill"] = daily_def["kill"]
	_notedDailies.append(note)
	_save_data()

func remove_daily_note(task_id):
	for i in _notedDailies.size():
		if _notedDailies[i].get("id", "") == task_id:
			_notedDailies.remove_at(i)
			_save_data()
			return

func get_noted_dailies():
	return _notedDailies

# Contracts share the notes array (same panel), tagged with a distinct
# id prefix and type so the renderer can branch. IDs are stable per
# trader (only one contract per trader at a time).
func contract_note_id(trader_name: String) -> String:
	return "contract_" + trader_name

func add_contract_note(trader_name: String) -> void:
	if not _contracts.has(trader_name):
		return
	var note_id := contract_note_id(trader_name)
	if is_daily_noted(note_id):
		return
	var c: Dictionary = _contracts[trader_name]
	var diff_idx: int = int(c.get("difficulty", 0))
	var note := {
		"id": note_id,
		"trader": trader_name,
		"name": "Contract [%s]" % CONTRACT_LABELS[clampi(diff_idx, 0, CONTRACT_LABELS.size() - 1)],
		"description": contract_description(c),
		"type": "contract",
		"difficulty": diff_idx,
		"target": c.get("target", ""),
		"target_count": int(c.get("target_count", 0)),
		"weapon_type": c.get("weapon_type", ""),
	}
	_notedDailies.append(note)
	_save_data()

func _check_daily_reset():
	var today = get_current_day()
	if _dailyDay != today:
		_dailyDay = today
		_dailyCompleted.clear()
		_killProgress.clear()
		# Stale notes point at yesterday's task IDs (format:
		# <trader>_daily_<day>_<slot>). Today's tasks get new IDs, so the
		# stale notes never match any visible daily -- clear them so the
		# notes panel stays in sync with what the trader actually offers.
		_notedDailies.clear()
		_save_data()

func get_daily_tasks(trader_name):
	_check_daily_reset()
	var tier = get_rep_tier(trader_name)
	var num_slots = tier + 1

	var pool = _traderPools.get(trader_name, {})
	var deliver_pool = pool.get("deliver", [])
	var reward_pool = pool.get("reward", [])

	if deliver_pool.size() == 0 or reward_pool.size() == 0:
		return []

	var tasks = []
	var day = get_current_day()

	for slot in num_slots:
		var task_seed = hash(str(_dailySeed) + str(day) + trader_name + str(slot))
		var rng = RandomNumberGenerator.new()
		rng.seed = task_seed

		var difficulty = slot
		var diff_label = _get_difficulty_label(difficulty)
		var task_id = trader_name + "_daily_" + str(day) + "_" + str(slot)

		# Higher difficulty slots have a chance to roll kill tasks
		# Difficulty 0-1: always deliver, 2+: 40% chance of kill task
		var roll_kill = difficulty >= 2 and rng.randf() < 0.4

		if roll_kill:
			var kill_task = _generate_kill_task(trader_name, difficulty, rng, task_id, diff_label, reward_pool)
			if kill_task:
				tasks.append(kill_task)
				continue

		# Deliver task (default)
		var deliver_item = _pick_item_by_difficulty(deliver_pool, difficulty, rng)
		if !deliver_item:
			continue

		var reward_item = _pick_reward(reward_pool, deliver_item, difficulty, rng)
		if !reward_item:
			continue

		var deliver_amount = _calc_deliver_amount(deliver_item, difficulty, rng)
		var reward_amount = _calc_reward_amount(reward_item, difficulty, rng)

		tasks.append({
			"id": task_id,
			"type": "deliver",
			"name": diff_label + ": " + deliver_item.name,
			"description": "Bring me " + str(deliver_amount) + "x " + deliver_item.name + " and I'll give you " + str(reward_amount) + "x " + reward_item.name + ".",
			"deliver": [{"file": deliver_item.file, "amount": deliver_amount}],
			"receive": [{"file": reward_item.file, "amount": reward_amount}],
			"difficulty": difficulty,
		})

	return tasks

const TRADER_KILL_TARGETS = {
	"Generalist": "Bandit",
	"Doctor": "Guard",
	"Gunsmith": "Military",
}
const KILL_WEAPON_TYPES = ["", "Pistol", "Rifle", "Bolt", "Shotgun", "SMG"]  # empty = any weapon
const KILL_TIMES = ["", "night", "day"]  # empty = any time

# --- Contracts (long-running kill tasks) ---

# Difficulty index 0..4 maps to labels, kill counts, rep rewards,
# abandon-cost penalties. Difficulty available = rep_tier (clamped).
const CONTRACT_LABELS := ["Easy", "Medium", "Hard", "Expert", "Master"]
const CONTRACT_KILL_COUNTS := [25, 50, 75, 100, 125]
const CONTRACT_REP_REWARDS := [3, 5, 8, 12, 20]
const CONTRACT_ABANDON_COSTS := [1, 2, 4, 7, 10]

# Chance a rolled contract gets a weapon-type constraint. Constraints
# only apply to Hard+ (difficulty >= 2). Expert/Master roll higher.
const CONTRACT_WEAPON_CHANCE := [0.0, 0.0, 0.3, 0.5, 0.7]

# Weapon pools per trader + difficulty tier (0..4). A contract rolls one
# weapon from its tier OR the tier below (50/50; tier 0 is always tier 0).
# Mags and ammo are derived from WEAPON_MAG_MAP / WEAPON_AMMO_MAP.
const CONTRACT_WEAPON_POOLS := {
	"Generalist": [
		["Makarov", "Remington_870", "Colt_1911"],         # T1
		["Mosin", "Glock_17", "MP5K"],                     # T2
		["AKS-74U", "MP5", "P320"],                        # T3
		["AKM", "RK-62", "RK-95"],                         # T4
		["AK-12", "MP5SD", "RK-62M"],                      # T5
	],
	"Gunsmith": [
		["MP5", "Glock_17", "MP5SD"],                      # T1
		["KAR-21_223", "MK18"],                            # T2
		["M4A1", "RK-62M", "MP7"],                         # T3
		["HK416", "KAR-21_308", "M78"],                    # T4
		["VSS", "SVD", "KP-31"],                           # T5
	],
}

# Maps weapon file name -> magazine file name. Weapons omitted here have
# no magazine reward (e.g. Mosin, Remington_870).
const WEAPON_MAG_MAP := {
	"Makarov": "Makarov_Magazine",
	"Colt_1911": "Colt_1911_Magazine",
	"Glock_17": "Glock_17_Magazine",
	"MP5K": "MP5_Magazine",
	"MP5": "MP5_Magazine",
	"MP5SD": "MP5_Magazine",
	"P320": "P320_Magazine",
	"AKS-74U": "AKS-74U_Magazine",
	"AKM": "AKM_Magazine",
	"RK-62": "RK_Magazine",
	"RK-62M": "RK_Magazine",
	"RK-95": "RK_Magazine",
	"AK-12": "AK-12_Magazine",
	"KAR-21_223": "KAR-21_223_Magazine",
	"KAR-21_308": "KAR-21_308_Magazine",
	"M4A1": "STANAG_Magazine",
	"MK18": "STANAG_Magazine",
	"HK416": "STANAG_Magazine",
	"MP7": "MP7_Magazine",
	"M78": "M78_Magazine",
	"VSS": "VSS_Magazine",
	"SVD": "SVD_Magazine",
	"KP-31": "KP-31_Drum",
}

# Maps weapon file name -> ammo file name.
const WEAPON_AMMO_MAP := {
	"Makarov": "Ammo_9x18",
	"Colt_1911": "Ammo_45ACP",
	"Remington_870": "Ammo_12x70",
	"Glock_17": "Ammo_9x19",
	"MP5K": "Ammo_9x19",
	"MP5": "Ammo_9x19",
	"MP5SD": "Ammo_9x19",
	"P320": "Ammo_9x19",
	"Mosin": "Ammo_762x54R",
	"SVD": "Ammo_762x54R",
	"AKS-74U": "Ammo_545x39",
	"RK-62": "Ammo_545x39",
	"RK-62M": "Ammo_545x39",
	"RK-95": "Ammo_545x39",
	"AK-12": "Ammo_545x39",
	"AKM": "Ammo_762x39",
	"KAR-21_223": "Ammo_223",
	"M4A1": "Ammo_223",
	"MK18": "Ammo_223",
	"HK416": "Ammo_223",
	"KAR-21_308": "Ammo_308",
	"M78": "Ammo_308",
	"MP7": "Ammo_46x30",
	"VSS": "Ammo_9x39",
	"KP-31": "Ammo_9x19",
}

# Mag/ammo counts per tier index (0..4). Tier 0 = T1 = easy.
const TIER_MAG_COUNT := [1, 2, 2, 3, 3]
const TIER_AMMO_COUNT := [20, 30, 40, 60, 90]

# Doctor reward pools per tier. Each tier lists {file, min, max, nonstack}.
# nonstack=true rolls amount individual items (e.g. armor plates).
const CONTRACT_DOCTOR_POOLS := [
	# T1
	[
		[{"file": "Bandage", "min": 2, "max": 3}, {"file": "Tourniquet", "min": 1, "max": 2}, {"file": "Painkillers", "min": 1, "max": 3}],
		[{"file": "Bandage", "min": 1, "max": 3}, {"file": "Splint", "min": 1, "max": 2}, {"file": "Antiseptic", "min": 1, "max": 2}],
		[{"file": "Tourniquet", "min": 2, "max": 3}, {"file": "Painkillers", "min": 2, "max": 3}, {"file": "Bandage", "min": 1, "max": 2}],
	],
	# T2
	[
		[{"file": "IFAK", "min": 1, "max": 2, "nonstack": true}, {"file": "Antibiotics", "min": 1, "max": 2}],
		[{"file": "Bandage", "min": 2, "max": 3}, {"file": "Antibiotics", "min": 1, "max": 2}, {"file": "Painkillers", "min": 2, "max": 3}],
		[{"file": "IFAK", "min": 1, "max": 1, "nonstack": true}, {"file": "Splint", "min": 1, "max": 2}, {"file": "Tourniquet", "min": 2, "max": 3}],
	],
	# T3
	[
		[{"file": "AFAK", "min": 1, "max": 1, "nonstack": true}, {"file": "Armor_Plate_II", "min": 1, "max": 2, "nonstack": true}, {"file": "Medkit", "min": 1, "max": 1, "nonstack": true}],
		[{"file": "IFAK", "min": 1, "max": 2, "nonstack": true}, {"file": "Medkit", "min": 1, "max": 1, "nonstack": true}, {"file": "Antibiotics", "min": 2, "max": 3}],
		[{"file": "Armor_Plate_II", "min": 1, "max": 2, "nonstack": true}, {"file": "Saline", "min": 1, "max": 3}, {"file": "IFAK", "min": 1, "max": 1, "nonstack": true}],
	],
	# T4
	[
		[{"file": "Armor_Plate_III", "min": 1, "max": 2, "nonstack": true}, {"file": "Saline", "min": 1, "max": 3}, {"file": "Medkit", "min": 1, "max": 1, "nonstack": true}],
		[{"file": "Armor_Plate_IIIA", "min": 1, "max": 2, "nonstack": true}, {"file": "AFAK", "min": 1, "max": 2, "nonstack": true}, {"file": "Antibiotics", "min": 1, "max": 3}],
		[{"file": "Armor_Plate_III", "min": 1, "max": 1, "nonstack": true}, {"file": "Medkit", "min": 1, "max": 1, "nonstack": true}, {"file": "Saline", "min": 2, "max": 3}],
	],
	# T5
	[
		[{"file": "Armor_Plate_IV", "min": 1, "max": 2, "nonstack": true}, {"file": "Medkit", "min": 1, "max": 1, "nonstack": true}, {"file": "Antibiotics", "min": 1, "max": 3}],
		[{"file": "Armor_Plate_III+", "min": 1, "max": 2, "nonstack": true}, {"file": "AFAK", "min": 1, "max": 2, "nonstack": true}, {"file": "Saline", "min": 2, "max": 3}],
		[{"file": "Armor_Plate_IV", "min": 1, "max": 1, "nonstack": true}, {"file": "Saline", "min": 2, "max": 3}, {"file": "Medkit", "min": 1, "max": 1, "nonstack": true}],
	],
]

# Max difficulty index available per rep tier (0..5). Rolls pick this
# value directly -- no RNG over difficulty.
const CONTRACT_DIFFICULTY_BY_REP_TIER := [0, 1, 2, 3, 4, 4]

func get_contract(trader_name: String) -> Dictionary:
	return _contracts.get(trader_name, {})

func has_contract(trader_name: String) -> bool:
	return _contracts.has(trader_name)

func is_contract_completed(trader_name: String) -> bool:
	var c = _contracts.get(trader_name, {})
	return c.get("completed", false)

# Generate a fresh contract for this trader. Difficulty = max allowed by
# the player's current rep tier (clamped to 0..4). Weapon constraint is
# rolled probabilistically for Hard+ only. Returns the new contract dict
# (also stored into _contracts).
# Roll a fresh contract (not yet persisted). Keyed to the player's
# current rep tier. Target, difficulty, weapon constraint all decided
# here so previews and actual accepts agree bit-for-bit.
func _roll_contract_preview(trader_name: String) -> Dictionary:
	var target: String = TRADER_KILL_TARGETS.get(trader_name, "Bandit")
	var tier: int = get_rep_tier(trader_name)
	var diff_idx: int = CONTRACT_DIFFICULTY_BY_REP_TIER[clampi(tier, 0, CONTRACT_DIFFICULTY_BY_REP_TIER.size() - 1)]
	var weapon_type := ""
	if randf() < CONTRACT_WEAPON_CHANCE[diff_idx]:
		# Exclude the empty-string "any" entry -- if we're rolling a
		# constraint, commit to a specific weapon type.
		var options := []
		for wt in KILL_WEAPON_TYPES:
			if wt != "":
				options.append(wt)
		weapon_type = options[randi() % options.size()]
	return {
		"difficulty": diff_idx,
		"target": target,
		"target_count": CONTRACT_KILL_COUNTS[diff_idx],
		"progress": 0,
		"weapon_type": weapon_type,
		"completed": false,
		"rewards": _roll_contract_rewards(trader_name, diff_idx),
	}

# Roll the actual reward bundle for a contract. Weapon traders pick from
# their tier's pool OR the tier below (50/50; tier 0 always rolls tier 0),
# then attach mag + ammo scaled by the rolled tier. Doctor picks a bundle
# from their tier's pool and rolls each entry's amount in [min, max].
# Returns an array of {file, amount} entries.
func _roll_contract_rewards(trader_name: String, diff_idx: int) -> Array:
	var out: Array = []
	if trader_name == "Doctor":
		var tier_pools: Array = CONTRACT_DOCTOR_POOLS[clampi(diff_idx, 0, CONTRACT_DOCTOR_POOLS.size() - 1)]
		var bundle: Array = tier_pools[randi() % tier_pools.size()]
		for entry in bundle:
			var lo: int = int(entry.get("min", 1))
			var hi: int = int(entry.get("max", 1))
			var amt: int = lo if lo >= hi else (lo + randi() % (hi - lo + 1))
			out.append({"file": String(entry["file"]), "amount": amt})
		return out
	# Weapon traders
	var pools: Array = CONTRACT_WEAPON_POOLS.get(trader_name, [])
	if pools.is_empty():
		return out
	var rolled_tier: int = diff_idx
	if diff_idx > 0 and randf() < 0.5:
		rolled_tier = diff_idx - 1
	var weapon_pool: Array = pools[clampi(rolled_tier, 0, pools.size() - 1)]
	var weapon: String = String(weapon_pool[randi() % weapon_pool.size()])
	out.append({"file": weapon, "amount": 1})
	var mag: String = String(WEAPON_MAG_MAP.get(weapon, ""))
	if mag != "":
		out.append({"file": mag, "amount": TIER_MAG_COUNT[clampi(rolled_tier, 0, TIER_MAG_COUNT.size() - 1)]})
	var ammo: String = String(WEAPON_AMMO_MAP.get(weapon, ""))
	if ammo != "":
		out.append({"file": ammo, "amount": TIER_AMMO_COUNT[clampi(rolled_tier, 0, TIER_AMMO_COUNT.size() - 1)]})
	return out

# Get (or lazily create) the preview contract shown to the player
# before they accept. Cached per trader so repeat-viewing doesn't
# reshuffle the constraint. Cleared by accept/abandon.
func get_contract_preview(trader_name: String) -> Dictionary:
	if _contractPreviews.has(trader_name):
		return _contractPreviews[trader_name]
	var preview := _roll_contract_preview(trader_name)
	_contractPreviews[trader_name] = preview
	return preview

func accept_contract(trader_name: String) -> Dictionary:
	if _contracts.has(trader_name):
		return _contracts[trader_name]
	# Use the cached preview if one exists so the accepted contract
	# matches what the UI displayed. Fall back to a fresh roll only
	# when no preview was ever computed (edge case: API caller).
	var contract: Dictionary
	if _contractPreviews.has(trader_name):
		contract = _contractPreviews[trader_name].duplicate(true)
		_contractPreviews.erase(trader_name)
	else:
		contract = _roll_contract_preview(trader_name)
	_contracts[trader_name] = contract
	_save_data()
	return contract

# Abandon the trader's active contract. Applies the rep penalty scaled
# by difficulty. Safe to call with no active contract (no-op).
func abandon_contract(trader_name: String) -> void:
	if not _contracts.has(trader_name):
		return
	var c: Dictionary = _contracts[trader_name]
	var diff_idx: int = int(c.get("difficulty", 0))
	var penalty: int = CONTRACT_ABANDON_COSTS[clampi(diff_idx, 0, CONTRACT_ABANDON_COSTS.size() - 1)]
	_rep[trader_name] = get_rep(trader_name) - penalty
	_contracts.erase(trader_name)
	# Drop any stale preview so the next visit rolls fresh.
	_contractPreviews.erase(trader_name)
	# Drop the contract's entry in the notes panel if it was noted.
	remove_daily_note(contract_note_id(trader_name))
	_save_data()

# Turn in a completed contract. Grants the reward bundle and rep. Caller
# must verify completed == true and provide iface for item creation.
# Returns true on success, false if nothing to turn in.
func turn_in_contract(trader_name: String, iface) -> bool:
	if not _contracts.has(trader_name):
		return false
	var c: Dictionary = _contracts[trader_name]
	if not c.get("completed", false):
		return false
	var diff_idx: int = int(c.get("difficulty", 0))
	# Grant the rewards rolled at preview time. Stored on the contract so
	# the turn-in bundle exactly matches what the player saw on accept.
	var rewards: Array = c.get("rewards", [])
	for reward in rewards:
		var item_data = _find_item_data_by_file(reward["file"])
		if item_data == null:
			push_warning("[TI-Contract] reward item '%s' not found" % reward["file"])
			continue
		var amount: int = int(reward["amount"])
		if item_data.stackable:
			var sd = SlotData.new()
			sd.itemData = item_data
			sd.amount = amount
			sd.condition = 100
			iface.Create(sd, iface.inventoryGrid, true)
		else:
			for _i in range(amount):
				var sd = SlotData.new()
				sd.itemData = item_data
				sd.condition = 100
				iface.Create(sd, iface.inventoryGrid, true)
	add_rep(trader_name, CONTRACT_REP_REWARDS[clampi(diff_idx, 0, CONTRACT_REP_REWARDS.size() - 1)])
	_contracts.erase(trader_name)
	# Clear any stale preview so the next visit rolls fresh.
	_contractPreviews.erase(trader_name)
	# Drop the contract's entry in the notes panel if it was noted.
	remove_daily_note(contract_note_id(trader_name))
	_save_data()
	return true

# Format a contract's rolled reward bundle as a comma-joined
# "Name x3, Name x1" string. Resolves display names via the items
# registry; falls back to the raw file name if missing.
func contract_reward_summary(contract: Dictionary) -> String:
	if contract.is_empty():
		return ""
	var rewards: Array = contract.get("rewards", [])
	var parts := PackedStringArray()
	for reward in rewards:
		var item_data = _find_item_data_by_file(reward["file"])
		var disp: String = String(item_data.name) if item_data else String(reward["file"])
		parts.append("%s x%d" % [disp, int(reward["amount"])])
	return ", ".join(parts)

func contract_description(contract: Dictionary) -> String:
	if contract.is_empty():
		return ""
	var diff_idx: int = int(contract.get("difficulty", 0))
	var label: String = CONTRACT_LABELS[clampi(diff_idx, 0, CONTRACT_LABELS.size() - 1)]
	var target: String = String(contract.get("target", ""))
	var count: int = int(contract.get("target_count", 0))
	var desc := "%s: Kill %d %ss" % [label, count, target]
	var wt: String = String(contract.get("weapon_type", ""))
	if wt != "":
		desc += " with a " + wt
	return desc

func _generate_kill_task(trader_name, difficulty, rng, task_id, diff_label, reward_pool):
	var target = TRADER_KILL_TARGETS.get(trader_name, "Bandit")
	var kill_count = clampi(2 + difficulty, 2, 8)

	# Build condition modifiers
	var weapon_type = ""
	var time_req = ""

	# Higher difficulty can add weapon/time constraints
	if difficulty >= 3 and rng.randf() < 0.5:
		weapon_type = KILL_WEAPON_TYPES[rng.randi() % KILL_WEAPON_TYPES.size()]
	if difficulty >= 4 and rng.randf() < 0.4:
		time_req = KILL_TIMES[rng.randi() % KILL_TIMES.size()]

	# Build description
	var desc = "Kill " + str(kill_count) + " " + target + "s"
	if weapon_type != "":
		desc += " using a " + weapon_type.to_lower()
	if time_req == "night":
		desc += " at night"
	elif time_req == "day":
		desc += " during the day"

	# Pick reward
	if reward_pool.size() == 0:
		return null
	var reward_item = reward_pool[rng.randi() % reward_pool.size()]
	var reward_amount = _calc_reward_amount(reward_item, difficulty, rng)
	desc += ". Reward: " + str(reward_amount) + "x " + reward_item.name + "."

	# Task name
	var task_name = diff_label + ": " + target + " Hunt"
	if weapon_type != "":
		task_name = diff_label + ": " + weapon_type + " " + target + " Hunt"

	return {
		"id": task_id,
		"type": "kill",
		"name": task_name,
		"description": desc,
		"kill": {
			"target": target,
			"count": kill_count,
			"weapon_type": weapon_type,
			"time": time_req,
		},
		"receive": [{"file": reward_item.file, "amount": reward_amount}],
		"difficulty": difficulty,
	}

func _get_difficulty_label(difficulty):
	match difficulty:
		0: return "Simple"
		1: return "Easy"
		2: return "Moderate"
		3: return "Challenging"
		4: return "Difficult"
		5: return "Expert"
	return "Task"

func _pick_item_by_difficulty(pool, difficulty, rng):
	if pool.size() == 0:
		return null
	var sorted = pool.duplicate()
	sorted.sort_custom(func(a, b): return a.value < b.value)
	var segment_size = max(1, sorted.size() / 6)
	var start = clampi(difficulty * segment_size, 0, sorted.size() - 1)
	var end = clampi(start + segment_size, 1, sorted.size())
	var segment = sorted.slice(start, end)
	if segment.size() == 0:
		segment = [sorted[rng.randi() % sorted.size()]]
	return segment[rng.randi() % segment.size()]

func _pick_reward(pool, deliver_item, difficulty, rng):
	if pool.size() == 0:
		return null
	var candidates = []
	for item in pool:
		if item.file != deliver_item.file:
			candidates.append(item)
	if candidates.size() == 0:
		return pool[rng.randi() % pool.size()]
	candidates.sort_custom(func(a, b): return a.value < b.value)
	var segment_size = max(1, candidates.size() / 6)
	var start = clampi(difficulty * segment_size, 0, candidates.size() - 1)
	var end = clampi(start + segment_size, 1, candidates.size())
	var segment = candidates.slice(start, end)
	if segment.size() == 0:
		segment = [candidates[rng.randi() % candidates.size()]]
	return segment[rng.randi() % segment.size()]

func _calc_deliver_amount(item, difficulty, rng):
	if item.stackable and item.defaultAmount > 0:
		var base = clampi(item.defaultAmount, 1, 30)
		var mult = 1.0 + difficulty * 0.5
		return clampi(int(base * mult), 1, item.defaultAmount * 3)
	else:
		return clampi(1 + difficulty / 2, 1, 3)

func _calc_reward_amount(item, difficulty, rng):
	if item.stackable and item.defaultAmount > 0:
		var base = clampi(item.defaultAmount, 1, 30)
		var mult = 1.0 + difficulty * 0.3
		return clampi(int(base * mult), 1, item.defaultAmount * 2)
	else:
		return clampi(1 + difficulty / 3, 1, 2)

# --- Always-Stock Items by Tier ---

func get_stock_items(trader_name, tier):
	var items = []

	if trader_name == "Generalist":
		items.append_array(["Water_Bottle", "Crackers", "Matches", "Ammo_9x18", "Canned_Peas"])
	elif trader_name == "Doctor":
		items.append_array(["Bandage_Improvised", "Splint_Improvised", "Tissues"])
	elif trader_name == "Gunsmith":
		items.append_array(["Ammo_9x18", "Ammo_9x19", "Ammo_12x70", "Weapon_Repair_Kit"])

	if tier >= 1:
		if trader_name == "Generalist":
			items.append_array(["Canned_Meat", "Canned_Peaches", "Soda_Lemon", "Battery", "Splint", "Cigarettes"])
		elif trader_name == "Doctor":
			items.append_array(["Bandage", "Splint", "Wipes", "Deodorant"])
		elif trader_name == "Gunsmith":
			items.append_array(["Ammo_45ACP", "Ammo_545x39", "Makarov_Magazine", "Jaeger_140"])

	if tier >= 2:
		if trader_name == "Generalist":
			items.append_array(["Ammo_9x19", "Canned_Tuna", "Canned_Pear", "Bandage", "Field_Ration", "Coffee"])
		elif trader_name == "Doctor":
			items.append_array(["Tourniquet_Improvised", "Painkillers", "Cold_Medicine", "Antiseptic"])
		elif trader_name == "Gunsmith":
			items.append_array(["Glock_17_Magazine", "Kobra", "RGD-5"])

	if tier >= 3:
		if trader_name == "Generalist":
			items.append_array(["Ammo_12x70", "Canned_Tomatoes", "Canned_Pineapple", "Tourniquet", "Energy_Drink", "Sleeping_Bag"])
		elif trader_name == "Doctor":
			items.append_array(["Antibiotics", "Lotion", "Balm", "Melatonin", "Map"])
		elif trader_name == "Gunsmith":
			items.append_array(["Ammo_762x39", "Ammo_223", "Ammo_46x30", "AKM_Magazine", "PRO", "Micro"])

	if tier >= 4:
		if trader_name == "Generalist":
			items.append_array(["Ammo_45ACP", "Canned_Meatballs", "Canned_Pea_Soup", "Painkillers", "Energy_Powder", "Thermal_Blanket"])
		elif trader_name == "Doctor":
			items.append_array(["Tourniquet", "Medkit", "Saline", "Thermal_Blanket", "Map_Tactical"])
		elif trader_name == "Gunsmith":
			items.append_array(["Ammo_308", "STANAG_Magazine", "ACOG", "PBS", "Armor_Plate_II"])

	if tier >= 5:
		if trader_name == "Generalist":
			items.append_array(["Ammo_762x39", "Antiseptic", "Sugar", "Yeast", "Kompot", "Chocolate_War", "Beer"])
		elif trader_name == "Doctor":
			items.append_array(["IFAK", "AFAK"])
		elif trader_name == "Gunsmith":
			items.append_array(["Ammo_9x39", "Ammo_762x54R", "POSP", "EXPS", "Armor_Plate_III", "F1"])

	return items

# --- Persistence ---

func _save_data():
	var SaveScript = load("res://TraderImprovementsV2/TISave.gd")
	var save = SaveScript.new()
	save.rep = _rep.duplicate()
	save.daily_seed = _dailySeed
	save.daily_day = _dailyDay
	save.daily_completed = _dailyCompleted.duplicate()
	save.noted_dailies = _notedDailies.duplicate(true)
	save.kill_progress = _killProgress.duplicate()
	# Contracts save as a plain Dictionary. Use deep dup so inner dicts
	# aren't aliased to our live state.
	if "contracts" in save:
		save.contracts = _contracts.duplicate(true)
	ResourceSaver.save(save, SAVE_PATH)

func _load_data():
	if !FileAccess.file_exists(SAVE_PATH):
		return
	if _is_legacy_config_format(SAVE_PATH):
		_migrate_legacy_config()
		return
	var save = load(SAVE_PATH)
	if save == null:
		return
	if "rep" in save:
		_rep = save.rep.duplicate()
	if "daily_seed" in save:
		_dailySeed = save.daily_seed
	if "daily_day" in save:
		_dailyDay = save.daily_day
	if "daily_completed" in save:
		_dailyCompleted = save.daily_completed.duplicate()
	if "noted_dailies" in save:
		_notedDailies = save.noted_dailies.duplicate(true)
	if "kill_progress" in save:
		_killProgress = save.kill_progress.duplicate()
	if "contracts" in save:
		_contracts = save.contracts.duplicate(true)

func _is_legacy_config_format(path):
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var first_line = f.get_line()
	f.close()
	return not first_line.begins_with("[gd_resource")

func _migrate_legacy_config():
	var cfg = ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	_dailySeed = cfg.get_value("meta", "seed", 0)
	if cfg.has_section("rep"):
		for key in cfg.get_section_keys("rep"):
			_rep[key] = cfg.get_value("rep", key, 0)
	_dailyDay = cfg.get_value("daily", "day", 0)
	if cfg.has_section("daily_completed"):
		for key in cfg.get_section_keys("daily_completed"):
			_dailyCompleted[key] = cfg.get_value("daily_completed", key, [])
	_notedDailies.clear()
	var note_count = cfg.get_value("notes", "count", 0)
	for i in note_count:
		var key = "note_" + str(i)
		if !cfg.has_section(key):
			continue
		_notedDailies.append({
			"id": cfg.get_value(key, "id", ""),
			"trader": cfg.get_value(key, "trader", ""),
			"name": cfg.get_value(key, "name", ""),
			"description": cfg.get_value(key, "description", ""),
			"deliver": cfg.get_value(key, "deliver", []),
			"receive": cfg.get_value(key, "receive", []),
		})
	_save_data()
	print("Trader Improvements V2: Migrated legacy save format")
