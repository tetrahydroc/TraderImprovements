extends Resource

var refreshCooldown: int = 0
var stockReplenishCooldown: int = 0

# Rep thresholds per trader [tier1, tier2, tier3, tier4, tier5]
var repThresholds: Dictionary = {
	"Generalist": [5, 15, 30, 60, 100],
	"Doctor": [5, 15, 30, 60, 100],
	"Gunsmith": [5, 15, 30, 60, 100],
}
