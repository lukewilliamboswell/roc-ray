platform "roc-ray"
    requires { Model } {
        init! : {} => Result Model []_,
        render! : Model, RocRay.PlatformState => Result Model []_,
    }
    exposes [
        RocRay,
        Camera,
        Draw,
        Font,
        Keys,
        Mouse,
        Music,
        Network,
        RenderTexture,
        Sound,
        Texture,
        Time,
    ]
    packages {}
    imports []
    provides [init_for_host!, render_for_host!]

import RocRay
import Mouse
import InternalKeyboard
import InternalMouse
import Effect
import Network

init_for_host! : I32 => Result (Box Model) Str
init_for_host! = |_x|
    init!({})
    |> Result.map_ok(Box.box)
    |> Result.map_err(Inspect.to_str)

render_for_host! : Box Model, Effect.PlatformStateFromHost => Result (Box Model) Str
render_for_host! = |boxed_model, { frame_count, keys, mouse_buttons, timestamp, mouse_pos_x, mouse_pos_y, mouse_wheel, peers, messages }|
    model = Box.unbox(boxed_model)

    state : RocRay.PlatformState
    state = {
        frame_count,
        keys: InternalKeyboard.pack(keys),
        timestamp,
        mouse: {
            position: { x: mouse_pos_x, y: mouse_pos_y },
            buttons: mouse_buttons_for_app({ mouse_buttons }),
            wheel: mouse_wheel,
        },
        network: {
            peers: {
                connected: peers.connected |> List.map(Network.from_u64_pair),
                disconnected: peers.disconnected |> List.map(Network.from_u64_pair),
            },
            messages: messages |> List.map(|{ id, bytes }| { id: Network.from_u64_pair(id), bytes }),
        },
    }

    render!(model, state)
    |> Result.map_ok(Box.box)
    |> Result.map_err(Inspect.to_str)

mouse_buttons_for_app : { mouse_buttons : List U8 } -> Mouse.Buttons
mouse_buttons_for_app = |{ mouse_buttons }|
    buttons_to_states : Dict InternalMouse.MouseButton Mouse.ButtonState
    buttons_to_states =
        mouse_buttons
        |> List.map(InternalMouse.mouse_button_state_from_u8)
        |> List.map_with_index(|s, i| (InternalMouse.mouse_button_from_u64(i), s))
        |> Dict.from_list

    state_of : InternalMouse.MouseButton -> Mouse.ButtonState
    state_of = |button|
        Dict.get(buttons_to_states, button)
        |> Result.with_default(Up)

    {
        left: state_of(MouseButtonLeft),
        right: state_of(MouseButtonRight),
        middle: state_of(MouseButtonMiddle),
        side: state_of(MouseButtonSide),
        extra: state_of(MouseButtonExtra),
        forward: state_of(MouseButtonForward),
        back: state_of(MouseButtonBack),
    }
