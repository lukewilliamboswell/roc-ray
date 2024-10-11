module [
    Program,
    Color,
    Rectangle,
    Vector2,
    setWindowSize,
    getScreenSize,
    exit,
    setWindowTitle,
    drawRectangle,
    getMousePosition,
    MouseButtons,
    mouseButtons,
    setTargetFPS,
    setDrawFPS,
    measureText,
    drawText,
    drawRectangle,
    drawRectangleGradientV,
    drawCircle,
    drawCircleGradient,
    rgba,
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

## Draw a rectangle on the screen.
drawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color } -> Task {} *
drawRectangle = \{ x, y, width, height, color } ->

    { r, g, b, a } = rgba color

    Effect.drawRectangle x y width height r g b a
    |> Task.mapErr \{} -> crash "unreachable drawRectangle"

## Draw a rectangle with a gradient on the screen.
drawRectangleGradientV : { x : F32, y : F32, width : F32, height : F32, top : Color, bottom : Color } -> Task {} *
drawRectangleGradientV = \{ x, y, width, height, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientV x y width height tc.r tc.g tc.b tc.a bc.r bc.g bc.b bc.a
    |> Task.mapErr \{} -> crash "unreachable drawRectangleGradientV"

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
