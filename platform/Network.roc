module [UUID, from_u64_pair, to_u64_pair, to_str, configure!]

import Effect

## Configure the WebRTC connection to the given server URL.
configure! : { server_url : Str } => {}
configure! = |{ server_url }| Effect.configure_web_rtc!(server_url)

UUID := { upper : U64, lower : U64 }
    implements [
        Eq,
        Hash,
        Inspect { to_inspector: uuid_inspector },
    ]

from_u64_pair : { upper : U64, lower : U64 }a -> UUID
from_u64_pair = |{ upper, lower }| @UUID({ upper, lower })

to_u64_pair : UUID -> Effect.RawUUID
to_u64_pair = |@UUID({ upper, lower })| { upper, lower, zzz1: 0, zzz2: 0, zzz3: 0 }

uuid_inspector : UUID -> Inspector f where f implements InspectFormatter
uuid_inspector = |uuid| Inspect.str(to_str(uuid))

to_str : UUID -> Str
to_str = |@UUID({ upper, lower })|

    component_one_mask = 0xFFFFFFFF00000000 # First 32 bits (8 chars)
    component_two_mask = 0x00000000FFFF0000 # Next 16 bits (4 chars)
    component_three_mask = 0x000000000000FFFF # Last 16 bits (4 chars)
    component_four_mask = 0xFFFF000000000000 # First 16 bits of lower (4 chars)
    component_five_mask = 0x0000FFFFFFFFFFFF # Remaining 48 bits (12 chars)

    component1 = Num.bitwise_and(upper, component_one_mask) |> Num.shift_right_zf_by(32) |> to_hex_str
    component2 = Num.bitwise_and(upper, component_two_mask) |> Num.shift_right_zf_by(16) |> to_hex_str
    component3 = Num.bitwise_and(upper, component_three_mask) |> to_hex_str
    component4 = Num.bitwise_and(lower, component_four_mask) |> Num.shift_right_zf_by(48) |> to_hex_str
    component5 = Num.bitwise_and(lower, component_five_mask) |> to_hex_str

    "${component1}-${component2}-${component3}-${component4}-${component5}"

expect
    a = Inspect.to_str(@UUID({ upper: 0xa1a2a3a4b1b2c1c2, lower: 0xd1d2d3d4d5d6d7d8 }))
    a == "\"a1a2a3a4-b1b2-c1c2-d1d2-d3d4d5d6d7d8\""

to_hex_str : U64 -> Str
to_hex_str = |num|
    if num == 0 then
        "0"
    else
        to_hex_str_help(num, [])
        |> List.reverse # Since we built the list in reverse order
        |> Str.from_utf8
        |> Result.with_default("INVALID UTF8")

to_hex_str_help : U64, List U8 -> List U8
to_hex_str_help = |num, acc|
    if num == 0 then
        acc
    else
        digit =
            when Num.bitwise_and(num, 15u64) is
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

        to_hex_str_help(Num.shift_right_by(num, 4), List.append(acc, digit))

expect to_hex_str(0) == "0"
expect to_hex_str(1) == "1"
expect to_hex_str(10) == "a"
expect to_hex_str(15) == "f"
expect to_hex_str(16) == "10"
expect to_hex_str(255) == "ff"
expect to_hex_str(256) == "100"
expect to_hex_str(4096) == "1000"
expect to_hex_str(65535) == "ffff"
expect to_hex_str(65536) == "10000"
