app [main, Model] { ray: platform "../platform/main.roc" }

import ray.RocRay exposing [PlatformState, Texture, Rectangle]
import ray.RocRay.Keys as Keys

width = 800
height = 600

Model : {
    player : { x: F32, y: F32 },
    direction : [Left, Right],
    dude : Texture,
    dudeAnimation : AnimatedSprite,
}

main : RocRay.Program Model _
main = { init, render }

init =

    RocRay.setTargetFPS! 60
    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Animated Sprite Example"
    RocRay.setBackgroundColor! White

    dude = RocRay.loadTexture! "examples/assets/sprite-dude/sheet.png"

    Task.ok {
        player: { x: width / 2, y: height / 2 },
        direction: Right,
        dude,
        dudeAnimation: {
            frame: 0,
            frameRate: 10,
            nextAnimationTick: 0,
        }
    }

render : Model, PlatformState -> Task Model _
render = \model, { timestampMillis, keys } ->

    dudeAnimation = updateAnimation model.dudeAnimation timestampMillis

    RocRay.drawText! { pos: {x: 10, y: 10}, text: "Rocci the Cool Dude", size: 40, color: Navy }
    RocRay.drawText! { pos: {x: 10, y: 50}, text: "Use arrow keys to walk around", size: 20, color: Green }

    RocRay.drawTextureRec! {
        texture: model.dude,
        source: dudeSpriteWalkLeft (Num.intCast dudeAnimation.frame),
        pos: model.player,
        tint: White,
    }

    newPlayerPos =
        if Keys.down keys KeyUp then
            { x: model.player.x, y: model.player.y - 10 }
        else if Keys.down keys KeyDown then
            { x: model.player.x, y: model.player.y + 10 }
        else if Keys.down keys KeyLeft then
            { x: model.player.x - 10, y: model.player.y }
        else if Keys.down keys KeyRight then
            { x: model.player.x + 10, y: model.player.y }
        else
            model.player


    Task.ok {model & player: newPlayerPos, dudeAnimation}

dudeSpriteWalkLeft : U8 -> Rectangle
dudeSpriteWalkLeft = \frameIndex ->

    x = 64 * (Num.toF32 (frameIndex % 9))

    {
        x,
        y: 580,
        width: 64,
        height: 64,
    }

AnimatedSprite : {
    frame: U8, # frame index, increments each tick
    frameRate: U8, # frames per second
    nextAnimationTick: U64, # milliseconds
}

updateAnimation : AnimatedSprite, U64 -> AnimatedSprite
updateAnimation = \{ frame, frameRate, nextAnimationTick }, timestampMillis ->

    if timestampMillis > nextAnimationTick then
        {
            frame : frame + 1,
            frameRate,
            nextAnimationTick : timestampMillis + (Num.toU64 (Num.round (1000 / (Num.toF64 frameRate))))
        }
    else
        { frame, frameRate, nextAnimationTick }
