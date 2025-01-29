module [base_url, rollback]

import Rollback

base_url : Str
base_url = "wss://matchbox-10.fly.dev"

rollback : Rollback.Config
rollback = {
    millis_per_tick: 1000 // 120,
    max_rollback_ticks: 16,
    tick_advantage_limit: 10,
    send_most_recent: 20,
}
