module [
    Program,
    Color,
    Rectangle,
    Vector2,
    setWindowSize,
    getScreenSize,
    exit,
    drawText,
    measureText,
    setWindowTitle,
    drawRectangle,
    getMousePosition,
    MouseButtons,
    mouseButtons,
    setTargetFPS,
    setDrawFPS,
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
Color : { r : U8, g : U8, b : U8, a : U8 }

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

## Draw text on the screen using the default font.
drawText : { text : Str, posX : F32, posY : F32, fontSize : I32, color : Color } -> Task {} *
drawText = \{ text, posX, posY, fontSize, color } ->
    Effect.drawText posX posY fontSize text color.r color.g color.b color.a
    |> Task.mapErr \{} -> crash "unreachable drawText"

## Measure the width of a text string using the default font.
measureText : { text : Str, size : I32 } -> Task I64 *
measureText = \{ text, size } ->
    Effect.measureText text size
    |> Task.mapErr \{} -> crash "unreachable measureText"

## Draw a rectangle on the screen.
drawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color } -> Task {} *
drawRectangle = \{ x, y, width, height, color } ->
    Effect.drawRectangle x y width height color.r color.g color.b color.a
    |> Task.mapErr \{} -> crash "unreachable drawRectangle"

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
