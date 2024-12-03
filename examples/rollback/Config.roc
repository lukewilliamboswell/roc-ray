module [baseUrl, rollback]

import Rollback

baseUrl : Str
baseUrl = "wss://matchbox-10.fly.dev"

rollback : Rollback.Config
rollback = {
    millisPerTick: 1000 // 120,
    maxRollbackTicks: 16,
    tickAdvantageLimit: 10,
    sendMostRecent: 20,
}
