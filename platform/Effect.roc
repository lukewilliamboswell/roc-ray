hosted [
    Texture,
    RenderTexture,
    Sound,
    Music,
    LoadedMusic,
    Camera,
    RawUUID,
    PeerMessage,
    PlatformTime,
    PlatformStateFromHost,
    PeerState,
    Font,
    to_log_level,

    # EFFECTS
    get_screen_size!,
    exit!,
    draw_text!,
    draw_text_font!,
    measure_text!,
    measure_text_font!,
    draw_line!,
    draw_rectangle!,
    draw_rectangle_gradient_v!,
    draw_rectangle_gradient_h!,
    draw_circle!,
    draw_circle_gradient!,
    set_target_fps!,
    set_draw_fps!,
    take_screenshot!,
    create_camera!,
    update_camera!,
    init_window!,
    begin_drawing!,
    end_drawing!,
    begin_texture!,
    end_texture!,
    begin_mode_2d!,
    end_mode_2d!,
    log!,
    load_texture!,
    draw_texture_rec!,
    load_sound!,
    play_sound!,
    create_render_texture!,
    draw_render_texture_rec!,
    load_file_to_str!,
    send_to_peer!,
    load_music_stream!,
    play_music_stream!,
    get_music_time_played!,
    stop_music_stream!,
    pause_music_stream!,
    resume_music_stream!,
    sleep_millis!,
    random_i32!,
    load_font!,
    configure_web_rtc!,
]

import InternalColor exposing [RocColor]
import InternalVector exposing [RocVector2]
import InternalRectangle exposing [RocRectangle]

get_screen_size! : {} => { height : I32, width : I32, z : I64 }

exit! : {} => {}

to_log_level : _ -> I32
to_log_level = |level|
    when level is
        LogAll -> 0
        LogTrace -> 1
        LogDebug -> 2
        LogInfo -> 3
        LogWarning -> 4
        LogError -> 5
        LogFatal -> 6
        LogNone -> 7

RawUUID : {
    upper : U64,
    lower : U64,
    zzz1 : U64,
    zzz2 : U64,
    zzz3 : U64,
}

PeerMessage : {
    id : Effect.RawUUID,
    bytes : List U8,
}

PlatformTime : {
    init_start : U64,
    init_end : U64,
    render_start : U64,
    last_render_start : U64,
    last_render_end : U64,
}

PlatformStateFromHost : {
    frame_count : U64,
    keys : List U8,
    mouse_buttons : List U8,
    timestamp : PlatformTime,
    mouse_pos_x : F32,
    mouse_pos_y : F32,
    mouse_wheel : F32,
    peers : PeerState,
    messages : List PeerMessage,
}

PeerState : {
    connected : List Effect.RawUUID,
    disconnected : List Effect.RawUUID,
}

log! : Str, I32 => {}

init_window! : Str, F32, F32 => {}

draw_text! : Str, RocVector2, F32, F32, RocColor => {}
draw_text_font! : Font, Str, RocVector2, F32, F32, RocColor => {}

measure_text! : Str, F32, F32 => RocVector2
measure_text_font! : Font, Str, F32, F32 => RocVector2

draw_line! : RocVector2, RocVector2, RocColor => {}

draw_rectangle! : RocRectangle, RocColor => {}
draw_rectangle_gradient_v! : RocRectangle, RocColor, RocColor => {}
draw_rectangle_gradient_h! : RocRectangle, RocColor, RocColor => {}
draw_circle! : RocVector2, F32, RocColor => {}
draw_circle_gradient! : RocVector2, F32, RocColor, RocColor => {}

set_target_fps! : I32 => {}
set_draw_fps! : Bool, RocVector2 => {}

take_screenshot! : Str => {}

begin_drawing! : RocColor => {}
end_drawing! : {} => {}

Camera := Box {}
create_camera! : RocVector2, RocVector2, F32, F32 => Result Camera Str
update_camera! : Camera, RocVector2, RocVector2, F32, F32 => {}

begin_mode_2d! : Camera => {}
end_mode_2d! : Camera => {}

Texture := Box {}
load_texture! : Str => Result Texture Str
draw_texture_rec! : Texture, RocRectangle, RocVector2, RocColor => {}
draw_render_texture_rec! : RenderTexture, RocRectangle, RocVector2, RocColor => {}

Sound := Box {}
load_sound! : Str => Result Sound Str
play_sound! : Sound => {}

Music := Box {}
LoadedMusic : { music : Music, len_seconds : F32 }
load_music_stream! : Str => Result LoadedMusic Str
play_music_stream! : Music => {}
stop_music_stream! : Music => {}
pause_music_stream! : Music => {}
resume_music_stream! : Music => {}
get_music_time_played! : Music => F32

RenderTexture := Box {}
create_render_texture! : RocVector2 => Result RenderTexture Str
begin_texture! : RenderTexture, RocColor => {}
end_texture! : RenderTexture => {}

load_file_to_str! : Str => Result Str Str

send_to_peer! : List U8, RawUUID => {}

random_i32! : I32, I32 => I32

sleep_millis! : U64 => {}

Font := Box U64
load_font! : Str => Result Font Str

configure_web_rtc! : Str => {}
