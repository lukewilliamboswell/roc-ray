module [
    Shader,
    RenderShader,
    ShaderLocation,
    RenderShaderLocation,
    load!,
    get_location!,
    set_value!,
    set_value_vec2!,
    set_value_matrix!,
    new!,
    set_f32!,
    set_vec2!,
    set_mat4!,
    set_texture!,
]

import InternalMatrix exposing [ Matrix ]
import InternalVector
import Effect
import RocRay

RenderShaderLocation : [ Loaded ShaderLocation, Empty, Invalid Str ]

RenderShader : {
    shader: Shader,
    locations: Dict Str RenderShaderLocation,
}

Shader : Effect.Shader

new! : Str, Str, List Str => Result RenderShader [LoadErr(Str)]
new! = |vertex, fragment, uniforms|
    shader = load!(vertex, fragment)?
    locations = List.walk!(uniforms, Dict.empty({}), |a, u|
        location = get_location!(shader, u)
        Dict.insert a u location
    )
    Ok { shader, locations }

ShaderLocation := { loc: I32 }

load! : Str, Str => Result Shader [ LoadErr Str ]_
load! = |vertex, fragment|
    Effect.load_shader! vertex fragment
    |> Result.map_err(LoadErr)

get_location! : Shader, Str => RenderShaderLocation
get_location! = |shader, identifier|
    Effect.get_shader_location! shader identifier
    |> Result.try |loc| if loc < 0 then Err "Invalid location id (${Inspect.to_str loc}) received for ${identifier}" else Ok loc
    |> Result.map_ok |loc| Loaded @ShaderLocation({ loc })
    |> Result.map_err |str| Invalid str
    |> |result|
        when result is
            Ok payload -> payload
            Err err ->
                RocRay.log! "Error finding location of \"${identifier}\" -- ${Inspect.to_str err}" LogAll
                err



set_f32! = |rs, key, value|
    location = Dict.get(rs.locations, key) |> Result.with_default Empty
    set_value! rs.shader location value
    rs

set_vec2! = |rs, key, value|
    location = Dict.get(rs.locations, key) |> Result.with_default Empty
    set_value_vec2! rs.shader location value
    rs

set_mat4! = |rs, key, value|
    location = Dict.get(rs.locations, key) |> Result.with_default Empty
    set_value_matrix! rs.shader location value
    rs

set_texture! = |rs, key, texture|
    location = Dict.get(rs.locations, key) |> Result.with_default Empty
    when location is
        Loaded @ShaderLocation({loc}) ->
            Effect.set_shader_value_texture! rs.shader loc texture
        _ -> {}

set_value! : Shader, RenderShaderLocation, F32 => {}
set_value! = |shader, location, value|
    when location is
        Loaded @ShaderLocation({ loc }) -> Effect.set_shader_value! shader loc value
        _ -> {}

set_value_vec2! : Shader, RenderShaderLocation, { x: F32, y: F32 } => {}
set_value_vec2! = |shader, location, {x, y}|
    when location is
        Loaded @ShaderLocation({ loc }) -> Effect.set_shader_value_vec2! shader loc InternalVector.from_xy(x, y)
        _ -> {}

set_value_matrix! : Shader, RenderShaderLocation, Matrix => {}
set_value_matrix! = |shader, location,  { m0, m4, m8, m12, m1, m5, m9, m13, m2, m6, m10, m14, m3, m7, m11, m15 }|
    when location is
        Loaded @ShaderLocation({ loc }) ->
            Effect.set_shader_value_matrix!(shader, loc,
                m0, m4, m8, m12,
                m1, m5, m9, m13,
                m2, m6, m10, m14,
                m3, m7, m11, m15)
        _ -> {}
