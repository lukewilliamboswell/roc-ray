module [Input, read, blank, toByte, fromByte]

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

upMask : U8
upMask = Num.shiftLeftBy 1 0

downMask : U8
downMask = Num.shiftLeftBy 1 1

leftMask : U8
leftMask = Num.shiftLeftBy 1 2

rightMask : U8
rightMask = Num.shiftLeftBy 1 3

toByte : Input -> U8
toByte = \input ->
    merge = \previous, direction, mask ->
        when direction input is
            Up -> previous
            Down -> Num.bitwiseOr previous mask

    0
    |> merge .up upMask
    |> merge .down downMask
    |> merge .left leftMask
    |> merge .right rightMask

fromByte : U8 -> Input
fromByte = \byte ->
    lookup = \mask ->
        if (Num.bitwiseAnd mask byte) != 0 then
            Down
        else
            Up

    {
        up: lookup upMask,
        down: lookup downMask,
        left: lookup leftMask,
        right: lookup rightMask,
    }

expect
    cycled = blank |> toByte |> fromByte
    cycled == blank

expect
    justUp = { Input.blank & up: Down }
    cycled = justUp |> toByte |> fromByte
    cycled == justUp

expect
    upLeft = { Input.blank & up: Down, left: Down }
    cycled = upLeft |> toByte |> fromByte
    cycled == upLeft

expect
    allDown = { up: Down, left: Down, right: Down, down: Down }
    cycled = allDown |> toByte |> fromByte
    cycled == allDown
