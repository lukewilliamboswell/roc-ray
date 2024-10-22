module [
    Keys,
    KeyState,
    KeyboardKey,
    pack,
    readKey,
]

Keys := List U8

pack : List U8 -> Keys
pack = \bytes -> @Keys bytes

readKey : Keys, KeyboardKey -> KeyState
readKey = \@Keys bytes, requestedKey ->
    when List.get bytes (keyToU64 requestedKey) is
        Ok byte -> keyStateFromU8 byte
        Err OutOfBounds -> crash "bug in key bytes encoding"

KeyboardKey : [
    KeyApostrophe, # = 39,
    KeyComma, # = 44,
    KeyMinus, # = 45,
    KeyPeriod, # = 46,
    KeySlash, # = 47,
    KeyZero, # = 48,
    KeyOne, # = 49,
    KeyTwo, # = 50,
    KeyThree, # = 51,
    KeyFour, # = 52,
    KeyFive, # = 53,
    KeySix, # = 54,
    KeySeven, # = 55,
    KeyEight, # = 56,
    KeyNine, # = 57,
    KeySemicolon, # = 59,
    KeyEqual, # = 61,
    KeyA, # = 65,
    KeyB, # = 66,
    KeyC, # = 67,
    KeyD, # = 68,
    KeyE, # = 69,
    KeyF, # = 70,
    KeyG, # = 71,
    KeyH, # = 72,
    KeyI, # = 73,
    KeyJ, # = 74,
    KeyK, # = 75,
    KeyL, # = 76,
    KeyM, # = 77,
    KeyN, # = 78,
    KeyO, # = 79,
    KeyP, # = 80,
    KeyQ, # = 81,
    KeyR, # = 82,
    KeyS, # = 83,
    KeyT, # = 84,
    KeyU, # = 85,
    KeyV, # = 86,
    KeyW, # = 87,
    KeyX, # = 88,
    KeyY, # = 89,
    KeyZ, # = 90,
    KeySpace, # = 32,
    KeyEscape, # = 256,
    KeyEnter, # = 257,
    KeyTab, # = 258,
    KeyBackspace, # = 259,
    KeyInsert, # = 260,
    KeyDelete, # = 261,
    KeyRight, # = 262,
    KeyLeft, # = 263,
    KeyDown, # = 264,
    KeyUp, # = 265,
    KeyPageUp, # = 266,
    KeyPageDown, # = 267,
    KeyHome, # = 268,
    KeyEnd, # = 269,
    KeyCapsLock, # = 280,
    KeyScrollLock, # = 281,
    KeyNumLock, # = 282,
    KeyPrintScreen, # = 283,
    KeyPause, # = 284,
    KeyF1, # = 290,
    KeyF2, # = 291,
    KeyF3, # = 292,
    KeyF4, # = 293,
    KeyF5, # = 294,
    KeyF6, # = 295,
    KeyF7, # = 296,
    KeyF8, # = 297,
    KeyF9, # = 298,
    KeyF10, # = 299,
    KeyF11, # = 300,
    KeyF12, # = 301,
    KeyLeftShift, # = 340,
    KeyLeftControl, # = 341,
    KeyLeftAlt, # = 342,
    KeyLeftSuper, # = 343,
    KeyRightShift, # = 344,
    KeyRightControl, # = 345,
    KeyRightAlt, # = 346,
    KeyRightSuper, # = 347,
    KeyKBMenu, # = 348,
    KeyLeftBracket, # = 91,
    KeyBackslash, # = 92,
    KeyRightBracket, # = 93,
    KeyGrave, # = 96,
    KeyKP0, # = 320,
    KeyKP1, # = 321,
    KeyKP2, # = 322,
    KeyKP3, # = 323,
    KeyKP4, # = 324,
    KeyKP5, # = 325,
    KeyKP6, # = 326,
    KeyKP7, # = 327,
    KeyKP8, # = 328,
    KeyKP9, # = 329,
    KeyKPDecimal, # = 330,
    KeyKPDivide, # = 331,
    KeyKPMultiply, # = 332,
    KeyKPSubtract, # = 333,
    KeyKPAdd, # = 334,
    KeyKPEnter, # = 335,
    KeyKPEqual, # = 336,
    KeyBack, # = 4,
    KeyVolumeUp, # = 24,
    KeyVolumeDown, # = 25,
]

KeyState : [
    Pressed,
    Released,
    Down,
    Up,
    PressedRepeat,
]

keyStateFromU8 : U8 -> KeyState
keyStateFromU8 = \n ->
    when n is
        0 -> Pressed
        1 -> Released
        2 -> Down
        3 -> Up
        4 -> PressedRepeat
        _ -> crash "unreachable key state from host"

keyToU64 : KeyboardKey -> U64
keyToU64 = \key ->
    when key is
        KeyApostrophe -> 39
        KeyComma -> 44
        KeyMinus -> 45
        KeyPeriod -> 46
        KeySlash -> 47
        KeyZero -> 48
        KeyOne -> 49
        KeyTwo -> 50
        KeyThree -> 51
        KeyFour -> 52
        KeyFive -> 53
        KeySix -> 54
        KeySeven -> 55
        KeyEight -> 56
        KeyNine -> 57
        KeySemicolon -> 59
        KeyEqual -> 61
        KeyA -> 65
        KeyB -> 66
        KeyC -> 67
        KeyD -> 68
        KeyE -> 69
        KeyF -> 70
        KeyG -> 71
        KeyH -> 72
        KeyI -> 73
        KeyJ -> 74
        KeyK -> 75
        KeyL -> 76
        KeyM -> 77
        KeyN -> 78
        KeyO -> 79
        KeyP -> 80
        KeyQ -> 81
        KeyR -> 82
        KeyS -> 83
        KeyT -> 84
        KeyU -> 85
        KeyV -> 86
        KeyW -> 87
        KeyX -> 88
        KeyY -> 89
        KeyZ -> 90
        KeySpace -> 32
        KeyEscape -> 256
        KeyEnter -> 257
        KeyTab -> 258
        KeyBackspace -> 259
        KeyInsert -> 260
        KeyDelete -> 261
        KeyRight -> 262
        KeyLeft -> 263
        KeyDown -> 264
        KeyUp -> 265
        KeyPageUp -> 266
        KeyPageDown -> 267
        KeyHome -> 268
        KeyEnd -> 269
        KeyCapsLock -> 280
        KeyScrollLock -> 281
        KeyNumLock -> 282
        KeyPrintScreen -> 283
        KeyPause -> 284
        KeyF1 -> 290
        KeyF2 -> 291
        KeyF3 -> 292
        KeyF4 -> 293
        KeyF5 -> 294
        KeyF6 -> 295
        KeyF7 -> 296
        KeyF8 -> 297
        KeyF9 -> 298
        KeyF10 -> 299
        KeyF11 -> 300
        KeyF12 -> 301
        KeyLeftShift -> 340
        KeyLeftControl -> 341
        KeyLeftAlt -> 342
        KeyLeftSuper -> 343
        KeyRightShift -> 344
        KeyRightControl -> 345
        KeyRightAlt -> 346
        KeyRightSuper -> 347
        KeyKBMenu -> 348
        KeyLeftBracket -> 91
        KeyBackslash -> 92
        KeyRightBracket -> 93
        KeyGrave -> 96
        KeyKP0 -> 320
        KeyKP1 -> 321
        KeyKP2 -> 322
        KeyKP3 -> 323
        KeyKP4 -> 324
        KeyKP5 -> 325
        KeyKP6 -> 326
        KeyKP7 -> 327
        KeyKP8 -> 328
        KeyKP9 -> 329
        KeyKPDecimal -> 330
        KeyKPDivide -> 331
        KeyKPMultiply -> 332
        KeyKPSubtract -> 333
        KeyKPAdd -> 334
        KeyKPEnter -> 335
        KeyKPEqual -> 336
        KeyBack -> 4
        KeyVolumeUp -> 24
        KeyVolumeDown -> 25

keyFromU64 : U64 -> Result KeyboardKey [Ignored]
keyFromU64 = \key ->
    when key is
        39 -> Ok KeyApostrophe
        44 -> Ok KeyComma
        45 -> Ok KeyMinus
        46 -> Ok KeyPeriod
        47 -> Ok KeySlash
        48 -> Ok KeyZero
        49 -> Ok KeyOne
        50 -> Ok KeyTwo
        51 -> Ok KeyThree
        52 -> Ok KeyFour
        53 -> Ok KeyFive
        54 -> Ok KeySix
        55 -> Ok KeySeven
        56 -> Ok KeyEight
        57 -> Ok KeyNine
        59 -> Ok KeySemicolon
        61 -> Ok KeyEqual
        65 -> Ok KeyA
        66 -> Ok KeyB
        67 -> Ok KeyC
        68 -> Ok KeyD
        69 -> Ok KeyE
        70 -> Ok KeyF
        71 -> Ok KeyG
        72 -> Ok KeyH
        73 -> Ok KeyI
        74 -> Ok KeyJ
        75 -> Ok KeyK
        76 -> Ok KeyL
        77 -> Ok KeyM
        78 -> Ok KeyN
        79 -> Ok KeyO
        80 -> Ok KeyP
        81 -> Ok KeyQ
        82 -> Ok KeyR
        83 -> Ok KeyS
        84 -> Ok KeyT
        85 -> Ok KeyU
        86 -> Ok KeyV
        87 -> Ok KeyW
        88 -> Ok KeyX
        89 -> Ok KeyY
        90 -> Ok KeyZ
        32 -> Ok KeySpace
        256 -> Ok KeyEscape
        257 -> Ok KeyEnter
        258 -> Ok KeyTab
        259 -> Ok KeyBackspace
        260 -> Ok KeyInsert
        261 -> Ok KeyDelete
        262 -> Ok KeyRight
        263 -> Ok KeyLeft
        264 -> Ok KeyDown
        265 -> Ok KeyUp
        266 -> Ok KeyPageUp
        267 -> Ok KeyPageDown
        268 -> Ok KeyHome
        269 -> Ok KeyEnd
        280 -> Ok KeyCapsLock
        281 -> Ok KeyScrollLock
        282 -> Ok KeyNumLock
        283 -> Ok KeyPrintScreen
        284 -> Ok KeyPause
        290 -> Ok KeyF1
        291 -> Ok KeyF2
        292 -> Ok KeyF3
        293 -> Ok KeyF4
        294 -> Ok KeyF5
        295 -> Ok KeyF6
        296 -> Ok KeyF7
        297 -> Ok KeyF8
        298 -> Ok KeyF9
        299 -> Ok KeyF10
        300 -> Ok KeyF11
        301 -> Ok KeyF12
        340 -> Ok KeyLeftShift
        341 -> Ok KeyLeftControl
        342 -> Ok KeyLeftAlt
        343 -> Ok KeyLeftSuper
        344 -> Ok KeyRightShift
        345 -> Ok KeyRightControl
        346 -> Ok KeyRightAlt
        347 -> Ok KeyRightSuper
        348 -> Ok KeyKBMenu
        91 -> Ok KeyLeftBracket
        92 -> Ok KeyBackslash
        93 -> Ok KeyRightBracket
        96 -> Ok KeyGrave
        320 -> Ok KeyKP0
        321 -> Ok KeyKP1
        322 -> Ok KeyKP2
        323 -> Ok KeyKP3
        324 -> Ok KeyKP4
        325 -> Ok KeyKP5
        326 -> Ok KeyKP6
        327 -> Ok KeyKP7
        328 -> Ok KeyKP8
        329 -> Ok KeyKP9
        330 -> Ok KeyKPDecimal
        331 -> Ok KeyKPDivide
        332 -> Ok KeyKPMultiply
        333 -> Ok KeyKPSubtract
        334 -> Ok KeyKPAdd
        335 -> Ok KeyKPEnter
        336 -> Ok KeyKPEqual
        4 -> Ok KeyBack
        24 -> Ok KeyVolumeUp
        25 -> Ok KeyVolumeDown
        _ -> Err Ignored

expect
    bytes = List.repeat 2u8 350
    keys = pack bytes
    state = readKey keys KeyLeft
    state == Down

expect
    range = List.range { start: At 0, end: At 350 }
    allKeys = List.keepOks range \i ->
        when keyFromU64 i is
            Ok key -> Ok (key, i)
            Err Ignored -> Err Ignored
    List.all allKeys \(key, i) ->
        keyToU64 key == i
