module [
    Program,
    Color,
    Rectangle,
    Vector2,
    setWindowSize,
    getScreenSize,
    setBackgroundColor,
    exit,
    setWindowTitle,
    drawRectangle,
    getMousePosition,
    MouseButtons,
    mouseButtons,
    setTargetFPS,
    setDrawFPS,
    getFrameCount,
    measureText,
    drawText,
    drawLine,
    drawRectangle,
    drawRectangleGradient,
    drawCircle,
    drawCircleGradient,
    rgba,
    KeyBoardKey,
    getKeysPressed,
]

import Effect

## Provide an initial state and a render function to the platform.
## ```
## {
##     init : Task state {},
##     render : state -> Task state {},
## }
## ```
Program state : {
    init : Task state {},
    render : state -> Task state {},
}

## Represents a rectangle.
## ```
## { x : F32, y : F32, width : F32, height : F32 }
## ```
Rectangle : { x : F32, y : F32, width : F32, height : F32 }

## Represents a 2D vector.
## ```
## { x : F32, y : F32 }
## ```
Vector2 : { x : F32, y : F32 }

## Represents a color.
## ```
## { r : U8, g : U8, b : U8, a : U8 }
## ```
Color : [
    RGBA U8 U8 U8 U8,
    White,
    Silver,
    Gray,
    Black,
    Red,
    Maroon,
    Yellow,
    Olive,
    Lime,
    Green,
    Aqua,
    Teal,
    Blue,
    Navy,
    Fuchsia,
    Purple,
]

rgba : Color -> { r : U8, g : U8, b : U8, a : U8 }
rgba = \color ->
    when color is
        RGBA r g b a -> { r, g, b, a }
        White -> { r: 255, g: 255, b: 255, a: 255 }
        Silver -> { r: 192, g: 192, b: 192, a: 255 }
        Gray -> { r: 128, g: 128, b: 128, a: 255 }
        Black -> { r: 0, g: 0, b: 0, a: 255 }
        Red -> { r: 255, g: 0, b: 0, a: 255 }
        Maroon -> { r: 128, g: 0, b: 0, a: 255 }
        Yellow -> { r: 255, g: 255, b: 0, a: 255 }
        Olive -> { r: 128, g: 128, b: 0, a: 255 }
        Lime -> { r: 0, g: 255, b: 0, a: 255 }
        Green -> { r: 0, g: 128, b: 0, a: 255 }
        Aqua -> { r: 0, g: 255, b: 255, a: 255 }
        Teal -> { r: 0, g: 128, b: 128, a: 255 }
        Blue -> { r: 0, g: 0, b: 255, a: 255 }
        Navy -> { r: 0, g: 0, b: 128, a: 255 }
        Fuchsia -> { r: 255, g: 0, b: 255, a: 255 }
        Purple -> { r: 128, g: 0, b: 128, a: 255 }

## Exit the program.
exit : Task {} *
exit = Effect.exit |> Task.mapErr \{} -> crash "unreachable exit"

## Set the window title.
setWindowTitle : Str -> Task {} *
setWindowTitle = \title ->
    Effect.setWindowTitle title
    |> Task.mapErr \{} -> crash "unreachable setWindowTitle"

## Set the window size.
setWindowSize : { width : F32, height : F32 } -> Task {} *
setWindowSize = \{ width, height } ->
    Effect.setWindowSize (Num.round width) (Num.round height)
    |> Task.mapErr \{} -> crash "unreachable setWindowSize"

## Get the window size.
getScreenSize : Task { height : F32, width : F32 } *
getScreenSize =
    Effect.getScreenSize
    |> Task.map \{ width, height } -> { width: Num.toFrac width, height: Num.toFrac height }
    |> Task.mapErr \{} -> crash "unreachable getScreenSize"

## Get the current mouse position.
getMousePosition : Task Vector2 *
getMousePosition =
    { x, y } =
        Effect.getMousePosition
            |> Task.mapErr! \{} -> crash "unreachable getMousePosition"

    Task.ok { x, y }

## Represents the state of the mouse buttons.
## ```
## MouseButtons : {
##     back: Bool,
##     left: Bool,
##     right: Bool,
##     middle: Bool,
##     side: Bool,
##     extra: Bool,
##     forward: Bool,
## }
## ```
MouseButtons : {
    back : Bool,
    left : Bool,
    right : Bool,
    middle : Bool,
    side : Bool,
    extra : Bool,
    forward : Bool,
}

## Get the current state of the mouse buttons.
##
## Here is an example checking if the left and right mouse buttons are currently pressed:
## ```
## { left, right } = Raylib.mouseButtons!
## ```
mouseButtons : Task MouseButtons *
mouseButtons =
    # note we are unpacking and repacking the mouseButtons here as a workaround for
    # https://github.com/roc-lang/roc/issues/7142
    { back, left, right, middle, side, extra, forward } =
        Effect.mouseButtons
            |> Task.mapErr! \{} -> crash "unreachable mouseButtons"

    Task.ok {
        back,
        left,
        right,
        middle,
        side,
        extra,
        forward,
    }

## Set the target frames per second. The default value is 60.
setTargetFPS : I32 -> Task {} *
setTargetFPS = \fps -> Effect.setTargetFPS fps |> Task.mapErr \{} -> crash "unreachable setTargetFPS"

## Display the frames per second, and set the location.
## The default values are Hidden, 10, 10.
## ```
## Raylib.setDrawFPS! { fps: Visible, posX: 10, posY: 10 }
## ```
setDrawFPS : { fps : [Visible, Hidden], posX ? F32, posY ? F32 } -> Task {} *
setDrawFPS = \{ fps, posX ? 10, posY ? 10 } ->

    showFps =
        when fps is
            Visible -> Bool.true
            Hidden -> Bool.false

    Effect.setDrawFPS showFps posX posY
    |> Task.mapErr \{} -> crash "unreachable setDrawFPS"

## Get the number of frames that have been drawn since the program started.
getFrameCount : Task I64 *
getFrameCount =
    Effect.getFrameCount
    |> Task.mapErr \{} -> crash "unreachable getFrameCount"

## Set the background color to clear the window between each frame.
setBackgroundColor : Color -> Task {} *
setBackgroundColor = \color ->
    { r, g, b, a } = rgba color

    Effect.setBackgroundColor r g b a
    |> Task.mapErr \{} -> crash "unreachable setBackgroundColor"

## Measure the width of a text string using the default font.
measureText : { text : Str, size : I32 } -> Task I64 *
measureText = \{ text, size } ->
    Effect.measureText text size
    |> Task.mapErr \{} -> crash "unreachable measureText"

## Draw text on the screen using the default font.
drawText : { text : Str, x : F32, y : F32, size : I32, color : Color } -> Task {} *
drawText = \{ text, x, y, size, color } ->

    { r, g, b, a } = rgba color

    Effect.drawText x y size text r g b a
    |> Task.mapErr \{} -> crash "unreachable drawText"

## Draw a line on the screen.
drawLine : { start : Vector2, end : Vector2, color : Color } -> Task {} *
drawLine = \{ start, end, color } ->

    { r, g, b, a } = rgba color

    Effect.drawLine start.x start.y end.x end.y r g b a
    |> Task.mapErr \{} -> crash "unreachable drawLine"

## Draw a rectangle on the screen.
drawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color } -> Task {} *
drawRectangle = \{ x, y, width, height, color } ->

    { r, g, b, a } = rgba color

    Effect.drawRectangle x y width height r g b a
    |> Task.mapErr \{} -> crash "unreachable drawRectangle"

## Draw a rectangle with a gradient on the screen.
drawRectangleGradient : { x : F32, y : F32, width : F32, height : F32, top : Color, bottom : Color } -> Task {} *
drawRectangleGradient = \{ x, y, width, height, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradient x y width height tc.r tc.g tc.b tc.a bc.r bc.g bc.b bc.a
    |> Task.mapErr \{} -> crash "unreachable drawRectangleGradient"

## Draw a circle on the screen.
drawCircle : { x : F32, y : F32, radius : F32, color : Color } -> Task {} *
drawCircle = \{ x, y, radius, color } ->

    { r, g, b, a } = rgba color

    Effect.drawCircle x y radius r g b a
    |> Task.mapErr \{} -> crash "unreachable drawCircle"

## Draw a circle with a gradient on the screen.
drawCircleGradient : { x : F32, y : F32, radius : F32, inner : Color, outer : Color } -> Task {} *
drawCircleGradient = \{ x, y, radius, inner, outer } ->

    ic = rgba inner
    oc = rgba outer

    Effect.drawCircleGradient x y radius ic.r ic.g ic.b ic.a oc.r oc.g oc.b oc.a
    |> Task.mapErr \{} -> crash "unreachable drawCircleGradient"

## Get's the set of keys pressed since last time this function was called.
## Key presses are queued until read.
getKeysPressed : Task (Set KeyBoardKey) *
getKeysPressed =
    Effect.getKeysPressed
        |> Task.map \keys -> keys |> List.map keyFromU8 |> Set.fromList
        |> Task.mapErr! \{} -> crash "unreachable getKeysPressed"

KeyBoardKey : [
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

keyFromU8 : U64 -> KeyBoardKey
keyFromU8 = \key ->
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
