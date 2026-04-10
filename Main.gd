extends Node

var gameData = preload("res://Resources/GameData.tres")
var LT_Master: LootTable = preload("res://Loot/LT_Master.tres")

const SAVE_PATH = "user://TraderImprovements.cfg"

# Rep data per trader
var _rep: Dictionary = {}
# Daily task tracking
var _dailyDay: int = 0
var _dailyCompleted: Dictionary = {}
# Per-save random seed for daily generation
var _dailySeed: int = 0
# Noted dailies (shown in task notes area)
var _notedDailies: Array = []  # Array of { trader, name, description, deliver, receive }
# Cached item pools per trader (built once)
var _traderPools: Dictionary = {}  # { "Generalist": { "deliver": [], "reward": [] } }

func _ready():
	overrideScript("res://TraderImprovements/TIInterface.gd")
	overrideScript("res://TraderImprovements/TITask.gd")
	_load_data()
	if _dailySeed == 0:
		_dailySeed = randi()
		_save_data()
	_build_item_pools()
	Engine.set_meta("TraderImprovements", self)
	print("Trader Improvements: Loaded")

func overrideScript(modded_path: String):
	var script: Script = load(modded_path)
	if !script:
		print("Trader Improvements: Failed to load " + modded_path)
		return
	script.reload()
	var parentScript = script.get_base_script()
	script.take_over_path(parentScript.resource_path)

# --- Item Pool Building ---

func _build_item_pools():
	_traderPools.clear()
	for trader_name in ["Generalist", "Doctor", "Gunsmith"]:
		var deliver_items: Array = []
		var reward_items: Array = []

		for item in LT_Master.items:
			if !item:
				continue
			# Check trader tag
			var tagged = false
			if trader_name == "Generalist" and item.generalist:
				tagged = true
			elif trader_name == "Doctor" and item.doctor:
				tagged = true
			elif trader_name == "Gunsmith" and item.gunsmith:
				tagged = true
			if !tagged:
				continue

			# Skip furniture, weapons (too complex for daily trades), and keys
			if item.type == "Furniture" or item.type == "Weapon" or item.type == "Key":
				continue

			# Categorize by value
			if item.value <= 200:
				deliver_items.append(item)
			if item.value >= 50:
				reward_items.append(item)

		_traderPools[trader_name] = {
			"deliver": deliver_items,
			"reward": reward_items
		}

# --- Rep System ---

func get_rep(trader_name: String) -> int:
	return _rep.get(trader_name, 0)

func add_rep(trader_name: String, amount: int):
	_rep[trader_name] = get_rep(trader_name) + amount
	_save_data()

func get_rep_tier(trader_name: String) -> int:
	var rep = get_rep(trader_name)
	if rep >= 100:
		return 5
	elif rep >= 60:
		return 4
	elif rep >= 30:
		return 3
	elif rep >= 15:
		return 2
	elif rep >= 5:
		return 1
	return 0

func get_rep_tier_name(tier: int) -> String:
	match tier:
		0: return "Unknown"
		1: return "Acquaintance"
		2: return "Trusted"
		3: return "Reliable"
		4: return "Valued"
		5: return "Partner"
	return "Unknown"

# --- Daily Tasks ---

func get_current_day() -> int:
	return Simulation.day

func is_daily_completed(trader_name: String, task_id: String) -> bool:
	_check_daily_reset()
	if !_dailyCompleted.has(trader_name):
		return false
	return task_id in _dailyCompleted[trader_name]

func complete_daily(trader_name: String, task_id: String):
	_check_daily_reset()
	if !_dailyCompleted.has(trader_name):
		_dailyCompleted[trader_name] = []
	if task_id not in _dailyCompleted[trader_name]:
		_dailyCompleted[trader_name].append(task_id)
	_save_data()

func is_daily_noted(task_id: String) -> bool:
	for note in _notedDailies:
		if note.get("id", "") == task_id:
			return true
	return false

func add_daily_note(daily_def: Dictionary, trader_name: String):
	if is_daily_noted(daily_def["id"]):
		return
	_notedDailies.append({
		"id": daily_def["id"],
		"trader": trader_name,
		"name": daily_def["name"],
		"description": daily_def["description"],
		"deliver": daily_def["deliver"],
		"receive": daily_def["receive"],
	})
	_save_data()

func remove_daily_note(task_id: String):
	for i in _notedDailies.size():
		if _notedDailies[i].get("id", "") == task_id:
			_notedDailies.remove_at(i)
			_save_data()
			return

func get_noted_dailies() -> Array:
	return _notedDailies

func _check_daily_reset():
	var today = get_current_day()
	if _dailyDay != today:
		_dailyDay = today
		_dailyCompleted.clear()
		_save_data()

func get_daily_tasks(trader_name: String) -> Array:
	_check_daily_reset()
	var tier = get_rep_tier(trader_name)
	var num_slots = tier + 1  # Tier 0 = 1 slot, Tier 5 = 6 slots

	var pool = _traderPools.get(trader_name, {})
	var deliver_pool: Array = pool.get("deliver", [])
	var reward_pool: Array = pool.get("reward", [])

	if deliver_pool.size() == 0 or reward_pool.size() == 0:
		return []

	var tasks = []
	var day = get_current_day()

	for slot in num_slots:
		# Deterministic seed per save + day + trader + slot
		var task_seed = hash(str(_dailySeed) + str(day) + trader_name + str(slot))
		var rng = RandomNumberGenerator.new()
		rng.seed = task_seed

		# Difficulty scales with slot index
		var difficulty = slot  # 0 = easiest, 5 = hardest
		var diff_label = _get_difficulty_label(difficulty)

		# Pick deliver item - higher difficulty = pick from higher value items
		var deliver_item = _pick_item_by_difficulty(deliver_pool, difficulty, rng)
		if !deliver_item:
			continue

		# Pick reward item - should be different from deliver and higher value
		var reward_item = _pick_reward(reward_pool, deliver_item, difficulty, rng)
		if !reward_item:
			continue

		# Scale quantities by difficulty and item value
		var deliver_amount = _calc_deliver_amount(deliver_item, difficulty, rng)
		var reward_amount = _calc_reward_amount(reward_item, difficulty, rng)

		var task_id = trader_name + "_daily_" + str(day) + "_" + str(slot)

		tasks.append({
			"id": task_id,
			"name": diff_label + ": " + deliver_item.name,
			"description": "Bring me " + str(deliver_amount) + "x " + deliver_item.name + " and I'll give you " + str(reward_amount) + "x " + reward_item.name + ".",
			"deliver": [{"file": deliver_item.file, "amount": deliver_amount}],
			"receive": [{"file": reward_item.file, "amount": reward_amount}],
			"difficulty": difficulty,
		})

	return tasks

func _get_difficulty_label(difficulty: int) -> String:
	match difficulty:
		0: return "Simple"
		1: return "Easy"
		2: return "Moderate"
		3: return "Challenging"
		4: return "Difficult"
		5: return "Expert"
	return "Task"

func _pick_item_by_difficulty(pool: Array, difficulty: int, rng: RandomNumberGenerator):
	if pool.size() == 0:
		return null
	# Sort pool by value, pick from appropriate range
	var sorted = pool.duplicate()
	sorted.sort_custom(func(a, b): return a.value < b.value)

	# Divide into segments based on difficulty
	var segment_size = max(1, sorted.size() / 6)
	var start = clampi(difficulty * segment_size, 0, sorted.size() - 1)
	var end = clampi(start + segment_size, 1, sorted.size())
	var segment = sorted.slice(start, end)

	if segment.size() == 0:
		segment = [sorted[rng.randi() % sorted.size()]]

	return segment[rng.randi() % segment.size()]

func _pick_reward(pool: Array, deliver_item, difficulty: int, rng: RandomNumberGenerator):
	if pool.size() == 0:
		return null
	# Filter out the deliver item and pick something of equal or higher value
	var candidates = []
	for item in pool:
		if item.file != deliver_item.file:
			candidates.append(item)

	if candidates.size() == 0:
		return pool[rng.randi() % pool.size()]

	# Bias toward higher value for harder tasks
	candidates.sort_custom(func(a, b): return a.value < b.value)
	var segment_size = max(1, candidates.size() / 6)
	var start = clampi(difficulty * segment_size, 0, candidates.size() - 1)
	var end = clampi(start + segment_size, 1, candidates.size())
	var segment = candidates.slice(start, end)

	if segment.size() == 0:
		segment = [candidates[rng.randi() % candidates.size()]]

	return segment[rng.randi() % segment.size()]

func _calc_deliver_amount(item, difficulty: int, rng: RandomNumberGenerator) -> int:
	if item.stackable and item.defaultAmount > 0:
		# Stackable: scale amount with difficulty
		var base = clampi(item.defaultAmount, 1, 30)
		var mult = 1.0 + difficulty * 0.5
		return clampi(int(base * mult), 1, item.defaultAmount * 3)
	else:
		# Non-stackable: 1-3 based on difficulty
		return clampi(1 + difficulty / 2, 1, 3)

func _calc_reward_amount(item, difficulty: int, rng: RandomNumberGenerator) -> int:
	if item.stackable and item.defaultAmount > 0:
		var base = clampi(item.defaultAmount, 1, 30)
		var mult = 1.0 + difficulty * 0.3
		return clampi(int(base * mult), 1, item.defaultAmount * 2)
	else:
		return clampi(1 + difficulty / 3, 1, 2)

# --- Always-Stock Items by Tier ---

func get_stock_items(trader_name: String, tier: int) -> Array:
	var items = []

	# Tier 0 - Basic essentials (always available)
	if trader_name == "Generalist":
		items.append_array(["Water_Bottle", "Crackers", "Matches", "Ammo_9x18", "Canned_Peas"])
	elif trader_name == "Doctor":
		items.append_array(["Bandage_Improvised", "Splint_Improvised", "Tissues"])
	elif trader_name == "Gunsmith":
		items.append_array(["Ammo_9x18", "Ammo_9x19", "Ammo_12x70", "Weapon_Repair_Kit"])

	# Tier 1 - Acquaintance (5 rep)
	if tier >= 1:
		if trader_name == "Generalist":
			items.append_array(["Canned_Meat", "Canned_Peaches", "Soda_Lemon", "Battery", "Splint", "Cigarettes"])
		elif trader_name == "Doctor":
			items.append_array(["Bandage", "Splint", "Wipes", "Deodorant"])
		elif trader_name == "Gunsmith":
			items.append_array(["Ammo_45ACP", "Ammo_545x39", "Makarov_Magazine", "Jaeger_140"])

	# Tier 2 - Trusted (15 rep)
	if tier >= 2:
		if trader_name == "Generalist":
			items.append_array(["Ammo_9x19", "Canned_Tuna", "Canned_Pear", "Bandage", "Field_Ration", "Coffee"])
		elif trader_name == "Doctor":
			items.append_array(["Tourniquet_Improvised", "Painkillers", "Cold_Medicine", "Antiseptic"])
		elif trader_name == "Gunsmith":
			items.append_array(["Glock_17_Magazine", "Kobra", "RGD-5"])

	# Tier 3 - Reliable (30 rep)
	if tier >= 3:
		if trader_name == "Generalist":
			items.append_array(["Ammo_12x70", "Canned_Tomatoes", "Canned_Pineapple", "Tourniquet", "Energy_Drink", "Sleeping_Bag"])
		elif trader_name == "Doctor":
			items.append_array(["Antibiotics", "Lotion", "Balm", "Melatonin", "Map"])
		elif trader_name == "Gunsmith":
			items.append_array(["Ammo_762x39", "Ammo_223", "Ammo_46x30", "AKM_Magazine", "PRO", "Micro"])

	# Tier 4 - Valued (60 rep)
	if tier >= 4:
		if trader_name == "Generalist":
			items.append_array(["Ammo_45ACP", "Canned_Meatballs", "Canned_Pea_Soup", "Painkillers", "Energy_Powder", "Thermal_Blanket"])
		elif trader_name == "Doctor":
			items.append_array(["Tourniquet", "Medkit", "Saline", "Thermal_Blanket", "Map_Tactical"])
		elif trader_name == "Gunsmith":
			items.append_array(["Ammo_308", "STANAG_Magazine", "ACOG", "PBS", "Armor_Plate_II"])

	# Tier 5 - Partner (100 rep)
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
	var cfg = ConfigFile.new()

	cfg.set_value("meta", "seed", _dailySeed)

	for trader_name in _rep:
		cfg.set_value("rep", trader_name, _rep[trader_name])

	cfg.set_value("daily", "day", _dailyDay)
	for trader_name in _dailyCompleted:
		cfg.set_value("daily_completed", trader_name, _dailyCompleted[trader_name])

	cfg.set_value("notes", "count", _notedDailies.size())
	for i in _notedDailies.size():
		var note = _notedDailies[i]
		var key = "note_" + str(i)
		cfg.set_value(key, "id", note.get("id", ""))
		cfg.set_value(key, "trader", note.get("trader", ""))
		cfg.set_value(key, "name", note.get("name", ""))
		cfg.set_value(key, "description", note.get("description", ""))
		cfg.set_value(key, "deliver", note.get("deliver", []))
		cfg.set_value(key, "receive", note.get("receive", []))

	cfg.save(SAVE_PATH)

func _load_data():
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
