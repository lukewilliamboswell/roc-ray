module [UUID, fromU64Pair, toU64Pair, toStr]

import Effect

UUID := { upper : U64, lower : U64 }
    implements [
        Eq,
        Hash,
        Inspect { toInspector: uuidInspector },
    ]

fromU64Pair : { upper : U64, lower : U64 }a -> UUID
fromU64Pair = \{ upper, lower } -> @UUID { upper, lower }

toU64Pair : UUID -> Effect.RawUUID
toU64Pair = \@UUID { upper, lower } -> { upper, lower, zzz1: 0, zzz2: 0, zzz3: 0 }

uuidInspector : UUID -> Inspector f where f implements InspectFormatter
uuidInspector = \uuid -> Inspect.str (toStr uuid)

toStr : UUID -> Str
toStr = \@UUID { upper, lower } ->

    componentOneMask = 0xFFFFFFFF00000000 # First 32 bits (8 chars)
    componentTwoMask = 0x00000000FFFF0000 # Next 16 bits (4 chars)
    componentThreeMask = 0x000000000000FFFF # Last 16 bits (4 chars)
    componentFourMask = 0xFFFF000000000000 # First 16 bits of lower (4 chars)
    componentFiveMask = 0x0000FFFFFFFFFFFF # Remaining 48 bits (12 chars)

    component1 = Num.bitwiseAnd upper componentOneMask |> Num.shiftRightZfBy 32 |> toHexStr
    component2 = Num.bitwiseAnd upper componentTwoMask |> Num.shiftRightZfBy 16 |> toHexStr
    component3 = Num.bitwiseAnd upper componentThreeMask |> toHexStr
    component4 = Num.bitwiseAnd lower componentFourMask |> Num.shiftRightZfBy 48 |> toHexStr
    component5 = Num.bitwiseAnd lower componentFiveMask |> toHexStr

    "$(component1)-$(component2)-$(component3)-$(component4)-$(component5)"

expect
    a = Inspect.toStr (@UUID { upper: 0xa1a2a3a4b1b2c1c2, lower: 0xd1d2d3d4d5d6d7d8 })
    a == "\"a1a2a3a4-b1b2-c1c2-d1d2-d3d4d5d6d7d8\""

toHexStr : U64 -> Str
toHexStr = \num ->
    if num == 0 then
        "0"
    else
        toHexStrHelp num []
        |> List.reverse # Since we built the list in reverse order
        |> Str.fromUtf8
        |> Result.withDefault "INVALID UTF8"

toHexStrHelp : U64, List U8 -> List U8
toHexStrHelp = \num, acc ->
    if num == 0 then
        acc
    else
        digit =
            when Num.bitwiseAnd num 15u64 is
                0 -> '0'
                1 -> '1'
                2 -> '2'
                3 -> '3'
                4 -> '4'
                5 -> '5'
                6 -> '6'
                7 -> '7'
                8 -> '8'
                9 -> '9'
                10 -> 'a'
                11 -> 'b'
                12 -> 'c'
                13 -> 'd'
                14 -> 'e'
                15 -> 'f'
                _ -> '0' # Should never happen for hex digits

        toHexStrHelp (Num.shiftRightBy num 4) (List.append acc digit)

expect toHexStr 0 == "0"
expect toHexStr 1 == "1"
expect toHexStr 10 == "a"
expect toHexStr 15 == "f"
expect toHexStr 16 == "10"
expect toHexStr 255 == "ff"
expect toHexStr 256 == "100"
expect toHexStr 4096 == "1000"
expect toHexStr 65535 == "ffff"
expect toHexStr 65536 == "10000"
