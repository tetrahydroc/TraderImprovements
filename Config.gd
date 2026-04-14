extends Node

var McmHelpers = load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
var settings = preload("res://TraderImprovements/TISettings.tres")

var config = ConfigFile.new()

const FILE_PATH = "user://MCM/TraderImprovements"
const MOD_ID = "trader-improvements"

const TIER_NAMES = ["Acquaintance", "Trusted", "Reliable", "Valued", "Partner"]
const TRADERS = ["Generalist", "Doctor", "Gunsmith"]

func _ready() -> void:
	config.set_value("Category", "Settings", {
		"menu_pos" = 0
	})

	config.set_value("Dropdown", "refreshMode", {
		"name" = "Refresh Button",
		"tooltip" = "Controls the trader refresh button behavior",
		"default" = 1,
		"value" = 1,
		"menu_pos" = 0,
		"category" = "Settings",
		"options" = [
			"Disabled",
			"Unlimited",
			"10s Cooldown",
			"30s Cooldown",
			"1 Minute",
			"2 Minutes",
			"5 Minutes",
			"10 Minutes",
			"30 Minutes",
			"1 Hour",
			"5 Hours",
			"12 Hours",
			"24 Hours"
		]
	})

	config.set_value("Dropdown", "stockReplenishMode", {
		"name" = "Stock Shop",
		"tooltip" = "Controls the always-available stock shop. Disabled hides the Stock button entirely. Cooldown options control how long a purchased item takes to reappear.",
		"default" = 1,
		"value" = 1,
		"menu_pos" = 1,
		"category" = "Settings",
		"options" = [
			"Disabled",
			"Immediate",
			"10s Cooldown",
			"30s Cooldown",
			"1 Minute",
			"2 Minutes",
			"5 Minutes",
			"10 Minutes",
			"30 Minutes",
			"1 Hour",
			"5 Hours",
			"12 Hours",
			"24 Hours"
		]
	})

	config.set_value("Category", "Reputation Thresholds", {
		"menu_pos" = 1
	})

	var defaults = [5, 15, 30, 60, 100]
	var pos = 1
	for t in TRADERS.size():
		var trader_name = TRADERS[t]
		for i in 5:
			var key = trader_name + "_tier" + str(i + 1)
			config.set_value("Int", key, {
				"name" = trader_name + " - Tier " + str(i + 1) + " (" + TIER_NAMES[i] + ")",
				"tooltip" = "Rep needed for " + trader_name + " to reach " + TIER_NAMES[i] + ". Must be less than the next tier.",
				"default" = defaults[i],
				"value" = defaults[i],
				"minRange" = 1,
				"maxRange" = 1000,
				"menu_pos" = pos,
				"on_value_changed" = "on_tier_changed",
				"category" = "Reputation Thresholds"
			})
			pos += 1

	if McmHelpers != null:
		if !FileAccess.file_exists(FILE_PATH + "/config.ini"):
			DirAccess.open("user://").make_dir_recursive(FILE_PATH)
			config.save(FILE_PATH + "/config.ini")
		else:
			McmHelpers.CheckConfigurationHasUpdated(MOD_ID, config, FILE_PATH + "/config.ini")
			config.load(FILE_PATH + "/config.ini")

		_on_config_updated(config)

		McmHelpers.RegisterConfiguration(
			MOD_ID,
			"Trader Improvements",
			FILE_PATH,
			"Configure trader improvement settings",
			{
				"config.ini" = _on_config_updated
			},
			self
		)

func on_tier_changed(changed_id: String, new_value, menu):
	var elements = menu.GetElements()
	# Parse trader name and tier number from the valueId (e.g. "Generalist_tier2")
	var parts = changed_id.rsplit("_tier", true, 1)
	if parts.size() != 2:
		return
	var trader_name = parts[0]
	var changed_tier = int(parts[1])

	# Cascade upward: each higher tier must be at least previous + 1
	var prev_val = int(new_value)
	for i in range(changed_tier + 1, 6):
		var key = trader_name + "_tier" + str(i)
		if !elements.has(key):
			continue
		var element = elements[key]
		var current = int(element.sliderInput.value)
		if current <= prev_val:
			element.SetValue(prev_val + 1)
			prev_val = prev_val + 1
		else:
			break

	# Cascade downward: each lower tier must be at least 1 less than the next
	prev_val = int(new_value)
	for i in range(changed_tier - 1, 0, -1):
		var key = trader_name + "_tier" + str(i)
		if !elements.has(key):
			continue
		var element = elements[key]
		var current = int(element.sliderInput.value)
		if current >= prev_val:
			element.SetValue(prev_val - 1)
			prev_val = prev_val - 1
		else:
			break

func _on_config_updated(_config: ConfigFile):
	# Refresh cooldown
	var mode = _config.get_value("Dropdown", "refreshMode")["value"]
	var cooldowns = [-1, 0, 10, 30, 60, 120, 300, 600, 1800, 3600, 18000, 43200, 86400]
	if mode >= 0 and mode < cooldowns.size():
		settings.refreshCooldown = cooldowns[mode]

	# Stock replenish cooldown
	var stock_mode = _config.get_value("Dropdown", "stockReplenishMode")["value"]
	if stock_mode >= 0 and stock_mode < cooldowns.size():
		settings.stockReplenishCooldown = cooldowns[stock_mode]

	# Signal the interface to reset its cooldown timer
	settings.set_meta("refresh_changed", true)

	# Rep thresholds with cascading validation (in-memory only, don't overwrite user's config)
	for trader_name in TRADERS:
		var thresholds = []
		for i in 5:
			var val = _config.get_value("Int", trader_name + "_tier" + str(i + 1))["value"]
			if thresholds.size() > 0 and val <= thresholds[-1]:
				val = thresholds[-1] + 1
			thresholds.append(val)
		settings.repThresholds[trader_name] = thresholds
