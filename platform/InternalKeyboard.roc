module [KeyboardKey, KeyState, keyFromU64, keyStateFromU8]

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

keyFromU64 : U64 -> KeyboardKey
keyFromU64 = \key ->
    if key == 39 then
        KeyApostrophe
    else if key == 44 then
        KeyComma
    else if key == 45 then
        KeyMinus
    else if key == 46 then
        KeyPeriod
    else if key == 47 then
        KeySlash
    else if key == 48 then
        KeyZero
    else if key == 49 then
        KeyOne
    else if key == 50 then
        KeyTwo
    else if key == 51 then
        KeyThree
    else if key == 52 then
        KeyFour
    else if key == 53 then
        KeyFive
    else if key == 54 then
        KeySix
    else if key == 55 then
        KeySeven
    else if key == 56 then
        KeyEight
    else if key == 57 then
        KeyNine
    else if key == 59 then
        KeySemicolon
    else if key == 61 then
        KeyEqual
    else if key == 65 then
        KeyA
    else if key == 66 then
        KeyB
    else if key == 67 then
        KeyC
    else if key == 68 then
        KeyD
    else if key == 69 then
        KeyE
    else if key == 70 then
        KeyF
    else if key == 71 then
        KeyG
    else if key == 72 then
        KeyH
    else if key == 73 then
        KeyI
    else if key == 74 then
        KeyJ
    else if key == 75 then
        KeyK
    else if key == 76 then
        KeyL
    else if key == 77 then
        KeyM
    else if key == 78 then
        KeyN
    else if key == 79 then
        KeyO
    else if key == 80 then
        KeyP
    else if key == 81 then
        KeyQ
    else if key == 82 then
        KeyR
    else if key == 83 then
        KeyS
    else if key == 84 then
        KeyT
    else if key == 85 then
        KeyU
    else if key == 86 then
        KeyV
    else if key == 87 then
        KeyW
    else if key == 88 then
        KeyX
    else if key == 89 then
        KeyY
    else if key == 90 then
        KeyZ
    else if key == 32 then
        KeySpace
    else if key == 256 then
        KeyEscape
    else if key == 257 then
        KeyEnter
    else if key == 258 then
        KeyTab
    else if key == 259 then
        KeyBackspace
    else if key == 260 then
        KeyInsert
    else if key == 261 then
        KeyDelete
    else if key == 262 then
        KeyRight
    else if key == 263 then
        KeyLeft
    else if key == 264 then
        KeyDown
    else if key == 265 then
        KeyUp
    else if key == 266 then
        KeyPageUp
    else if key == 267 then
        KeyPageDown
    else if key == 268 then
        KeyHome
    else if key == 269 then
        KeyEnd
    else if key == 280 then
        KeyCapsLock
    else if key == 281 then
        KeyScrollLock
    else if key == 282 then
        KeyNumLock
    else if key == 283 then
        KeyPrintScreen
    else if key == 284 then
        KeyPause
    else if key == 290 then
        KeyF1
    else if key == 291 then
        KeyF2
    else if key == 292 then
        KeyF3
    else if key == 293 then
        KeyF4
    else if key == 294 then
        KeyF5
    else if key == 295 then
        KeyF6
    else if key == 296 then
        KeyF7
    else if key == 297 then
        KeyF8
    else if key == 298 then
        KeyF9
    else if key == 299 then
        KeyF10
    else if key == 300 then
        KeyF11
    else if key == 301 then
        KeyF12
    else if key == 340 then
        KeyLeftShift
    else if key == 341 then
        KeyLeftControl
    else if key == 342 then
        KeyLeftAlt
    else if key == 343 then
        KeyLeftSuper
    else if key == 344 then
        KeyRightShift
    else if key == 345 then
        KeyRightControl
    else if key == 346 then
        KeyRightAlt
    else if key == 347 then
        KeyRightSuper
    else if key == 348 then
        KeyKBMenu
    else if key == 91 then
        KeyLeftBracket
    else if key == 92 then
        KeyBackslash
    else if key == 93 then
        KeyRightBracket
    else if key == 96 then
        KeyGrave
    else if key == 320 then
        KeyKP0
    else if key == 321 then
        KeyKP1
    else if key == 322 then
        KeyKP2
    else if key == 323 then
        KeyKP3
    else if key == 324 then
        KeyKP4
    else if key == 325 then
        KeyKP5
    else if key == 326 then
        KeyKP6
    else if key == 327 then
        KeyKP7
    else if key == 328 then
        KeyKP8
    else if key == 329 then
        KeyKP9
    else if key == 330 then
        KeyKPDecimal
    else if key == 331 then
        KeyKPDivide
    else if key == 332 then
        KeyKPMultiply
    else if key == 333 then
        KeyKPSubtract
    else if key == 334 then
        KeyKPAdd
    else if key == 335 then
        KeyKPEnter
    else if key == 336 then
        KeyKPEqual
    else if key == 4 then
        KeyBack
    else if key == 24 then
        KeyVolumeUp
    else if key == 25 then
        KeyVolumeDown
    else
        crash "unkown key code from host"
