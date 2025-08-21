module [Input, read, blank, to_byte, from_byte]

import rr.Keys exposing [Keys]

Input : {
    up : [Up, Down],
    down : [Up, Down],
    left : [Up, Down],
    right : [Up, Down],
}

read : Keys -> Input
read = |keys|
    up = if Keys.any_down(keys, [KeyUp, KeyW]) then Down else Up
    down = if Keys.any_down(keys, [KeyDown, KeyS]) then Down else Up
    left = if Keys.any_down(keys, [KeyLeft, KeyA]) then Down else Up
    right = if Keys.any_down(keys, [KeyRight, KeyD]) then Down else Up

    { up, down, left, right }

blank : Input
blank =
    { up: Up, down: Up, left: Up, right: Up }

up_mask : U8
up_mask = Num.shift_left_by(1, 0)

down_mask : U8
down_mask = Num.shift_left_by(1, 1)

left_mask : U8
left_mask = Num.shift_left_by(1, 2)

right_mask : U8
right_mask = Num.shift_left_by(1, 3)

to_byte : Input -> U8
to_byte = |input|
    merge = |previous, direction, mask|
        when direction(input) is
            Up -> previous
            Down -> Num.bitwise_or(previous, mask)

    0
    |> merge(.up, up_mask)
    |> merge(.down, down_mask)
    |> merge(.left, left_mask)
    |> merge(.right, right_mask)

from_byte : U8 -> Input
from_byte = |byte|
    lookup = |mask|
        if (Num.bitwise_and(mask, byte)) != 0 then
            Down
        else
            Up

    {
        up: lookup(up_mask),
        down: lookup(down_mask),
        left: lookup(left_mask),
        right: lookup(right_mask),
    }

expect
    cycled = blank |> to_byte |> from_byte
    cycled == blank

expect
    just_up = { Input.blank & up: Down }
    cycled = just_up |> to_byte |> from_byte
    cycled == just_up

expect
    up_left = { Input.blank & up: Down, left: Down }
    cycled = up_left |> to_byte |> from_byte
    cycled == up_left

expect
    all_down = { up: Down, left: Down, right: Down, down: Down }
    cycled = all_down |> to_byte |> from_byte
    cycled == all_down
