extends Resource

var refreshCooldown: int = 0
var stockReplenishCooldown: int = 0

# Rep thresholds per trader [tier1, tier2, tier3, tier4, tier5]
var repThresholds: Dictionary = {
	"Generalist": [100, 200, 300, 400, 500],
	"Doctor": [100, 200, 300, 400, 500],
	"Gunsmith": [100, 200, 300, 400, 500],
}
