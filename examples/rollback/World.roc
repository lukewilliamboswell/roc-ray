module [
    World,
    Player,
    AnimatedSprite,
    Facing,
    Intent,
    tick,
    checksum,
    positions_checksum,
    player_facing,
    initial,
    player_start,
]

import Input exposing [Input]
import Pixel exposing [PixelVec]
import Resolution exposing [width, height]

## the game state unrelated to rollback bookkeeping
World : {
    ## the player on the machine we're running on
    local_player : Player,
    ## the player on a remote machine
    remote_player : Player,
}

Player : {
    pos : PixelVec,
    animation : AnimatedSprite,
    intent : Intent,
}

AnimatedSprite : {
    frame : U8, # frame index, increments each tick
    frame_rate : U8, # frames per second
    next_animation_tick : F32, # milliseconds
}

Intent : [Walk Facing, Idle Facing]

Facing : [Up, Down, Left, Right]

TickContext : {
    tick : U64,
    timestamp_millis : U64,
    local_input : Input,
    remote_input : Input,
}

initial : World
initial = {
    local_player: player_start,
    remote_player: {
        pos: player_start.pos,
        animation: player_start.animation,
        intent: player_start.intent,
    },
}

player_start : Player
player_start =
    x = Pixel.from_pixels((width // 2))
    y = Pixel.from_pixels((height // 2))

    {
        pos: { x, y },
        animation: initial_animation,
        intent: Idle(Right),
    }

initial_animation : AnimatedSprite
initial_animation = { frame: 0, frame_rate: 10, next_animation_tick: 0 }

## used by Rollback for checking desyncs
checksum : World -> I64
checksum = |{ local_player, remote_player }|
    positions_checksum(
        {
            local_player_pos: local_player.pos,
            remote_player_pos: remote_player.pos,
        },
    )

positions_checksum : { local_player_pos : PixelVec, remote_player_pos : PixelVec } -> I64
positions_checksum = |{ local_player_pos, remote_player_pos }|
    # you would want to use a real checksum in a real game

    x_sum = Pixel.total_subpixels(local_player_pos.x) + Pixel.total_subpixels(remote_player_pos.x)
    y_sum = Pixel.total_subpixels(local_player_pos.y) + Pixel.total_subpixels(remote_player_pos.y)

    x_sum + 10 * y_sum

## advance the game state one discrete step
tick : World, TickContext -> World
tick = |state, { timestamp_millis, local_input, remote_input }|
    local_player =
        old_player = state.local_player
        animation = update_animation(old_player.animation, timestamp_millis)
        intent = input_to_intent(local_input, player_facing(old_player))
        move_player({ old_player & animation, intent }, intent)

    remote_player =
        old_remote_player = state.remote_player
        animation = update_animation(old_remote_player.animation, timestamp_millis)
        intent = input_to_intent(remote_input, player_facing(old_remote_player))
        move_player({ old_remote_player & animation, intent }, intent)

    { local_player, remote_player }

move_player : Player, Intent -> Player
move_player = |player, intent|
    { pos } = player

    move_speed = { subpixels: 80 }

    new_pos =
        when intent is
            Walk(Up) -> { pos & y: Pixel.sub(pos.y, move_speed) }
            Walk(Down) -> { pos & y: Pixel.add(pos.y, move_speed) }
            Walk(Right) -> { pos & x: Pixel.add(pos.x, move_speed) }
            Walk(Left) -> { pos & x: Pixel.sub(pos.x, move_speed) }
            Idle(_) -> pos

    { player & pos: new_pos }

input_to_intent : Input, Facing -> Intent
input_to_intent = |{ up, down, left, right }, facing|
    horizontal =
        when (left, right) is
            (Down, Up) -> Walk(Left)
            (Up, Down) -> Walk(Right)
            _same -> Idle(facing)

    vertical =
        when (up, down) is
            (Down, Up) -> Walk(Up)
            (Up, Down) -> Walk(Down)
            _same -> Idle(facing)

    when (horizontal, vertical) is
        (Walk(horizontal_facing), _) -> Walk(horizontal_facing)
        (Idle(_), Walk(vertical_facing)) -> Walk(vertical_facing)
        (Idle(idle_facing), _) -> Idle(idle_facing)

player_facing : { intent : Intent }a -> Facing
player_facing = |{ intent }|
    when intent is
        Walk(facing) -> facing
        Idle(facing) -> facing

update_animation : AnimatedSprite, U64 -> AnimatedSprite
update_animation = |animation, timestamp_millis|
    t = Num.to_f32(timestamp_millis)
    if t > animation.next_animation_tick then
        frame = Num.add_wrap(animation.frame, 1)
        millis_to_go = 1000 / (Num.to_f32(animation.frame_rate))
        next_animation_tick = t + millis_to_go
        { animation & frame, next_animation_tick }
    else
        animation
