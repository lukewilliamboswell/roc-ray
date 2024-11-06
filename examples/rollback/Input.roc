module [Input, read, blank, TickContext]

import rr.Keys exposing [Keys]

Input : {
    up : [Up, Down],
    down : [Up, Down],
    left : [Up, Down],
    right : [Up, Down],
}

read : Keys -> Input
read = \keys ->
    up = if Keys.anyDown keys [KeyUp, KeyW] then Down else Up
    down = if Keys.anyDown keys [KeyDown, KeyS] then Down else Up
    left = if Keys.anyDown keys [KeyLeft, KeyA] then Down else Up
    right = if Keys.anyDown keys [KeyRight, KeyD] then Down else Up

    { up, down, left, right }

blank : Input
blank =
    { up: Up, down: Up, left: Up, right: Up }

TickContext : {
    tick : U64,
    timestampMillis : U64,
    localInput : Input,
    remoteInput : Input,
}
