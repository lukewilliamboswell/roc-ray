app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay exposing [Texture, Rectangle]
import rr.Keys
import rr.Draw
import rr.Texture

width = 800
height = 600

Model : {
    player : { x : F32, y : F32 },
    direction : [WalkUp, WalkDown, WalkLeft, WalkRight],
    dude : Texture,
    dude_animation : AnimatedSprite,
}

init! : {} => Result Model _
init! = |{}|

    RocRay.set_target_fps!(60)
    RocRay.init_window!({ title: "Animated Sprite Example" })

    dude = Texture.load!("examples/assets/sprite-dude/sheet.png")?

    Ok(
        {
            player: { x: width / 2, y: height / 2 },
            direction: WalkRight,
            dude,
            dude_animation: {
                frame: 0,
                frame_rate: 10,
                next_animation_tick: 0,
            },
        },
    )

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, { timestamp, keys }|

    (player, direction) =
        if Keys.down(keys, KeyUp) then
            ({ x: model.player.x, y: model.player.y - 10 }, WalkUp)
        else if Keys.down(keys, KeyDown) then
            ({ x: model.player.x, y: model.player.y + 10 }, WalkDown)
        else if Keys.down(keys, KeyLeft) then
            ({ x: model.player.x - 10, y: model.player.y }, WalkLeft)
        else if Keys.down(keys, KeyRight) then
            ({ x: model.player.x + 10, y: model.player.y }, WalkRight)
        else
            (model.player, model.direction)

    dude_animation = update_animation(model.dude_animation, timestamp.render_start)

    Draw.draw!(
        White,
        |{}|

            Draw.text!({ pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy })
            Draw.text!({ pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green })

            Draw.texture_rec!(
                {
                    texture: model.dude,
                    source: dude_sprite(model.direction, dude_animation.frame),
                    pos: model.player,
                    tint: White,
                },
            ),
    )

    Ok({ model & player, dude_animation, direction })

dude_sprite : [WalkUp, WalkDown, WalkLeft, WalkRight], U8 -> Rectangle
dude_sprite = |sequence, frame|
    when sequence is
        WalkUp -> sprite64x64source({ row: 8, col: frame % 9 })
        WalkDown -> sprite64x64source({ row: 10, col: frame % 9 })
        WalkLeft -> sprite64x64source({ row: 9, col: frame % 9 })
        WalkRight -> sprite64x64source({ row: 11, col: frame % 9 })

AnimatedSprite : {
    frame : U8, # frame index, increments each tick
    frame_rate : U8, # frames per second
    next_animation_tick : U64, # milliseconds
}

update_animation : AnimatedSprite, U64 -> AnimatedSprite
update_animation = |{ frame, frame_rate, next_animation_tick }, timestamp_millis|

    if timestamp_millis > next_animation_tick then
        {
            frame: Num.add_wrap(frame, 1),
            frame_rate,
            next_animation_tick: timestamp_millis + (Num.to_u64(Num.round((1000 / (Num.to_f64(frame_rate)))))),
        }
    else
        { frame, frame_rate, next_animation_tick }

# get the pixel coordinates of a 64x64 sprite in the spritesheet
sprite64x64source : { row : U8, col : U8 } -> Rectangle
sprite64x64source = |{ row, col }| {
    x: 64 * (Num.to_f32(col)),
    y: 64 * (Num.to_f32(row)),
    width: 64,
    height: 64,
}
