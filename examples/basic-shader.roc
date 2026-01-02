app [Model, init!, render!] { rr: platform "../platform/main.roc" }
import rr.RocRay exposing [Texture, Camera]

import rr.Camera
import rr.Draw
import rr.Keys
import rr.Shader
import rr.Mouse

import rr.Texture

width = 512 + 64
height = 512 + 64

Model : {
    camera : Camera,
    freq : F32,
    amplitude : F32,
    texture : Texture,
    paused: Bool,
    marker_pos: RocRay.Vector2,
    empty: RocRay.Texture,
    ripple_shader: Shader.RenderShader,
    scale_shader: Shader.RenderShader,
    animation_frames: U32,
}

center = { x: width / 2, y: height / 2 }
init! : {} => Result Model _
init! = |{}|
    RocRay.set_target_fps! 60
    RocRay.display_fps! { fps: Visible, pos: { x: 10, y: 10 } }
    RocRay.init_window!({ title: "Basic Shader", width, height })

    amplitude = 10.333
    freq = 2.0
    texture = Texture.load!("examples/assets/plasma.png")?
    camera = Camera.create!(
        {
            zoom: 1,
            offset: center,
            target: { x: 0, y: 0 },
            rotation: 0,
        },
    )?
    image = RocRay.gen_image_color!(1, 1, White)?
    empty_texture = Texture.from_image!(image)?

    Ok(
        {
            marker_pos: { x: 0, y: 0 },
            empty: empty_texture,
            scale_shader: Shader.new!(
                "examples/assets/shaders/scale.vert",
                "examples/assets/shaders/default.frag",
                ["time", "max", "center"]
            )?,
            ripple_shader: Shader.new!(
                "examples/assets/shaders/default.vert",
                "examples/assets/shaders/ripple.frag",
                ["time", "frequency", "amplitude"]
            )?,
            texture,
            camera,
            freq,
            amplitude,
            animation_frames: 0,
            paused: Bool.false,
        }
    )
lerp : F32, F32, F32 -> F32
lerp = |from, to, t|
    from + (to - from) * t
render! : Model, RocRay.PlatformState => Result Model []
render! = |model, pf|
    game_time = (pf.timestamp.render_start - pf.timestamp.init_start) |> Num.to_f32 |> Num.div 1e3
    marker_pos =
        if Mouse.pressed(pf.mouse.buttons.left) then
            RocRay.get_screen_to_world_2d! pf.mouse.position model.camera
        else model.marker_pos

    _ = if Bool.not(model.paused) then
        Shader.set_f32!(model.ripple_shader, "time", game_time)
        |> \_ -> {}
    else {}

    animation_frames =
        if Mouse.pressed(pf.mouse.buttons.left) then 0
        else if Bool.not(model.paused) then
            model.animation_frames + 1
        else model.animation_frames

    freq =
        (
            if Keys.down(pf.keys, KeyUp) then
                model.freq + 0.05
            else if Keys.down(pf.keys, KeyDown) then
                model.freq - 0.05
            else
                model.freq
        )
        |> Num.max 0


    amplitude =
        (

            if Keys.down(pf.keys, KeyLeft) then
                model.amplitude - 0.05
            else if Keys.down(pf.keys, KeyRight) then
                model.amplitude + 0.05
            else if Keys.pressed(pf.keys, KeySpace) then
                model.amplitude + 10
            else
                model.amplitude
        )
        |> |a| if Bool.not(model.paused) then lerp a 0 (1/ 60) else a
        |> Num.max 0.01

    iteration_duration = (60 * 2.5) |> Num.floor
    duration_f = Num.to_f32 iteration_duration
    rounds = animation_frames |> Num.to_f32 |> Num.div duration_f
    t = Num.min rounds 1.0

    Draw.draw!(
        RGBA 128 128 128 255,
        |{}|
            Draw.with_mode_2d! model.camera |{}|
                Draw.with_mode_shader!(
                    model.ripple_shader.shader,
                    |{}|
                        _ = Shader.set_f32!(model.ripple_shader, "amplitude", model.amplitude)
                            |> Shader.set_f32!("frequency", model.freq)
                        Draw.texture_pro! {
                            origin: { x: 0, y: 0 },
                            dest: { x: -256, y: -256, width: 512, height: 512 },
                            texture: model.texture,
                            source: { x: 0, y: 0, width: 512, height: 512 },
                            rotation: 0,
                            tint: Teal,
                        }
                    )

                Draw.with_mode_shader! model.scale_shader.shader |{}|
                    Shader.set_f32! model.scale_shader "time" t
                    |> Shader.set_f32! "max" 3.0
                    |> Shader.set_vec2! "center" marker_pos
                    |> \_ -> ({})
                    Draw.ring! {
                        center: marker_pos,
                        inner: 28,
                        outer: 32,
                        start: 90,
                        end: 360 + 90,
                        segments: 6,
                        color: RocRay.fade(Black, 1.0)
                    }
            text =
                """
                [Up Dn] Frequency = ${Inspect.to_str freq}
                [L R] Amp = ${Inspect.to_str amplitude}
                [Enter]Paused = ${Inspect.to_str model.paused}
                Center = ${Inspect.to_str marker_pos}
                """
            text_dims = RocRay.measure_text! { text, size: 16, spacing: 1 }
            text_pos = { x: 20, y: 20 }
            padding = 16
            Draw.rectangle! {
                rect: {
                    x: text_pos.x - (padding /2),
                    y: text_pos.y - (padding /2),
                    width: text_dims.x + padding,
                    height: text_dims.y + padding,
                },
                color: RocRay.fade(Black, 0.5)
            }
            Draw.text! {
                size: 16,
                text,
                pos: text_pos,
                color: White,
            }
            Draw.text! {
                size: 16,
                text: "Click to animate",
                pos: { x: 32, y: height - 24 },
                color: White,
            }

    )
    Ok({model & freq, amplitude,
        marker_pos,
        paused: if Keys.pressed(pf.keys, KeyEnter) then Bool.not model.paused else model.paused,
        animation_frames
    })
