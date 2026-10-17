## Host-owned GPU shaders and their typed application uniform records.
##
## Shader construction belongs here because a shader is a resource independent
## of a particular presentation frame. Applying one remains a `Draw.Frame`
## operation (`frame.with_shader!`).

import Resource
import Assets
import Color
import Host
import Math

Shader(uniforms) :: { resource : Resource.Shader, uniforms : uniforms, values : { floats : List(F32), ints : List(I32), textures : List(Assets.Texture) } }.{

	## Compile shader stages from source strings and validate the complete
	## application-uniform schema.
	from_source! : LoadShaderSource, uniforms => Try(Shader(uniforms), [ShaderLoadFailed, ResourceLimit, UniformNotFound(Str), UniformReflectionUnavailable, UniformTypeMismatch({ name : Str, expected : ShaderUniformType, actual : ShaderUniformType }), UnsupportedUniformType(Str)])
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	from_source! = |cfg, uniforms| {
		schema = uniform_schema(uniforms)?
		shader = Host.shader_load_source!(cfg)?
		bind_shader_uniforms!(shader, schema, 0)?
		values = uniform_values(uniforms)
		Ok(Shader.({ resource: shader, uniforms, values: { floats: values.floats, ints: values.ints, textures: values.textures } }))
	}

	## Compile shader stage files resolved through an explicit asset store.
	## Legal in `init!` and tasks; refused in `update!` and `render!`.
	from_store! : Assets.Store, LoadShader, uniforms => Try(Shader(uniforms), [PathInvalid, NotFound, ReadFailed, ShaderLoadFailed, ResourceLimit, UniformNotFound(Str), UniformReflectionUnavailable, UniformTypeMismatch({ name : Str, expected : ShaderUniformType, actual : ShaderUniformType }), UnsupportedUniformType(Str)])
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	from_store! = |store, cfg, uniforms| {
		schema = uniform_schema(uniforms)?
		shader = Host.shader_load_store!({ store: store.for_host(), vertex_path: cfg.vertex_path, fragment_path: cfg.fragment_path })?
		bind_shader_uniforms!(shader, schema, 1)?
		values = uniform_values(uniforms)
		Ok(Shader.({ resource: shader, uniforms, values: { floats: values.floats, ints: values.ints, textures: values.textures } }))
	}

	## Return a shader sharing its compiled program and binding layout with a
	## replaced, type-checked uniform record. This is pure.
	with_uniforms : Shader(uniforms), uniforms -> Shader(uniforms)
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	with_uniforms = |Shader.(shader), values| {
		encoded = uniform_values(values)
		Shader.({ ..shader, uniforms: values, values: { floats: encoded.floats, ints: encoded.ints, textures: encoded.textures } })
	}

	## Resource-free shader value for pure tests.
	stub : uniforms -> Shader(uniforms)
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	stub = |uniforms| {
		encoded = uniform_values(uniforms)
		Shader.({ resource: Resource.Handle.stub({}), uniforms, values: { floats: encoded.floats, ints: encoded.ints, textures: encoded.textures } })
	}

	## Private frame payload assembled from the retained uniform record.
	for_frame : Shader(uniforms) -> { resource : Resource.Shader, floats : List(F32), ints : List(I32), textures : List(Assets.Texture) }
	for_frame = |Shader.({ resource, values, .. })| { resource, floats: values.floats, ints: values.ints, textures: values.textures }

	## Opaque three-component shader uniform value.
	Vec3 := { x : F32, y : F32, z : F32 }.{
		encoder_for : encoding -> (Vec3, state -> Try(state, err))
			where [encoding.encode_vec3 : Vec3, state -> Try(state, err)]
		encoder_for = |_encoding| {
			Encoding : encoding
			|value, state| Encoding.encode_vec3(value, state)
		}
	}

	vec3 : F32, F32, F32 -> Vec3
	vec3 = |x, y, z| { x, y, z }

	## Opaque four-component shader uniform value.
	Vec4 := { x : F32, y : F32, z : F32, w : F32 }.{
		encoder_for : encoding -> (Vec4, state -> Try(state, err))
			where [encoding.encode_vec4 : Vec4, state -> Try(state, err)]
		encoder_for = |_encoding| {
			Encoding : encoding
			|value, state| Encoding.encode_vec4(value, state)
		}
	}

	vec4 : F32, F32, F32, F32 -> Vec4
	vec4 = |x, y, z, w| { x, y, z, w }
}

ShaderUniformType : [Array, Bool, Float, Int, Sampler2D, Vec2, Vec3, Vec4, Unknown(U32)]

LoadShader : {
	vertex_path : Str,
	fragment_path : Str,
}

LoadShaderSource : {
	vertex_source : Str,
	fragment_source : Str,
}

UniformFormat := [Default].{
	rename_field : UniformFormat, Str -> Str
	rename_field = |_, name| name

	encode_record : UniformState, U64, (UniformState, (UniformState, Str, (UniformState -> Try(UniformState, UniformEncodeError)) -> Try(UniformState, UniformEncodeError)) -> Try(UniformState, UniformEncodeError)) -> Try(UniformState, UniformEncodeError)
	encode_record = |state, _, write_fields|
		match state.field {
			Field(name) => Err(NestedUniformRecord(name))
			NoField => write_fields(
				state,
				|cursor, name, write_value| {
					encoded = write_value({ ..cursor, field: Field(name) })?
					Ok({ ..encoded, field: NoField })
				},
			)
		}

	encode_f32 : F32, UniformState -> Try(UniformState, UniformEncodeError)
	encode_f32 = |value, state| encode_float_values(state, 0, [value])
	encode_i32 : I32, UniformState -> Try(UniformState, UniformEncodeError)
	encode_i32 = |value, state| encode_int_values(state, 1, [value])
	encode_bool : Bool, UniformState -> Try(UniformState, UniformEncodeError)
	encode_bool = |value, state| encode_int_values(state, 2, [if value 1 else 0])
	encode_vec2 : Math.Vec2, UniformState -> Try(UniformState, UniformEncodeError)
	encode_vec2 = |value, state| encode_float_values(state, 3, [value.x, value.y])
	encode_vec3 : Vec3, UniformState -> Try(UniformState, UniformEncodeError)
	encode_vec3 = |value, state| encode_float_values(state, 4, [value.x, value.y, value.z])
	encode_vec4 : Vec4, UniformState -> Try(UniformState, UniformEncodeError)
	encode_vec4 = |value, state| encode_float_values(state, 5, [value.x, value.y, value.z, value.w])
	encode_color : Color.Rgba, UniformState -> Try(UniformState, UniformEncodeError)
	encode_color = |color, state| {
		value = normalized_color(color)
		encode_float_values(state, 6, [value.x, value.y, value.z, value.w])
	}
	encode_texture : Assets.Texture, UniformState -> Try(UniformState, UniformEncodeError)
	encode_texture = |texture, state| {
		next = record_uniform_kind(state, 7)?
		match next.mode {
			SchemaMode => Ok(next)
			ValueMode => Ok({ ..next, textures: next.textures.append(texture) })
		}
	}
}

UniformEncodeMode : [SchemaMode, ValueMode]

UniformEncodeError : [NestedUniformRecord(Str)]

UniformState : {
	field : [Field(Str), NoField],
	floats : List(F32),
	ints : List(I32),
	mode : UniformEncodeMode,
	schema : List(Host.ShaderUniformSchema),
	textures : List(Assets.Texture),
}

empty_uniform_state : UniformEncodeMode -> UniformState
empty_uniform_state = |mode| { field: NoField, floats: [], ints: [], mode, schema: [], textures: [] }

record_uniform_kind : UniformState, U8 -> Try(UniformState, UniformEncodeError)
record_uniform_kind = |state, kind|
	match state.field {
		NoField => crash "uniform value was encoded outside its record field"
		Field(name) => match state.mode {
			SchemaMode => Ok({ ..state, schema: state.schema.append({ kind, name }) })
			ValueMode => Ok(state)
		}
	}

encode_float_values : UniformState, U8, List(F32) -> Try(UniformState, UniformEncodeError)
encode_float_values = |state, kind, values| {
	next = record_uniform_kind(state, kind)?
	match next.mode {
		SchemaMode => Ok(next)
		ValueMode => Ok({ ..next, floats: next.floats.concat(values) })
	}
}

encode_int_values : UniformState, U8, List(I32) -> Try(UniformState, UniformEncodeError)
encode_int_values = |state, kind, values| {
	next = record_uniform_kind(state, kind)?
	match next.mode {
		SchemaMode => Ok(next)
		ValueMode => Ok({ ..next, ints: next.ints.concat(values) })
	}
}

encode_uniforms : uniforms, UniformEncodeMode -> Try(UniformState, UniformEncodeError)
	where [uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError))]
encode_uniforms = |uniforms, mode| {
	Shape : uniforms
	encode = Shape.encoder_for(UniformFormat.Default)
	encode(uniforms, empty_uniform_state(mode))
}

uniform_schema : uniforms -> Try(List(Host.ShaderUniformSchema), [UnsupportedUniformType(Str)])
	where [uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError))]
uniform_schema = |uniforms|
	match encode_uniforms(uniforms, SchemaMode) {
		Ok(state) => Ok(state.schema)
		Err(NestedUniformRecord(name)) => Err(UnsupportedUniformType(name))
	}

uniform_values : uniforms -> UniformState
	where [uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError))]
uniform_values = |uniforms|
	match encode_uniforms(uniforms, ValueMode) {
		Ok(state) => state
		Err(NestedUniformRecord(_)) => crash "nested shader uniform record escaped construction validation"
	}

bind_shader_uniforms! : Resource.Shader, List(Host.ShaderUniformSchema), U8 => Try({}, [ResourceLimit, UniformNotFound(Str), UniformReflectionUnavailable, UniformTypeMismatch({ name : Str, expected : ShaderUniformType, actual : ShaderUniformType })])
bind_shader_uniforms! = |shader, schema, operation|
	match Host.shader_bind_uniforms!({ operation, schema, shader }) {
		Ok({}) => Ok({})
		Err(ResourceLimit) => Err(ResourceLimit)
		Err(UniformReflectionUnavailable) => Err(UniformReflectionUnavailable)
		Err(UniformNotFound(index)) => Err(UniformNotFound(schema_entry(schema, index).name))
		Err(UniformTypeMismatch({ actual, array_len, index })) => {
			entry = schema_entry(schema, index)
			Err(UniformTypeMismatch({ name: entry.name, expected: shader_type_from_kind(entry.kind), actual: shader_type_from_gl(actual, array_len) }))
		}
	}

schema_entry : List(Host.ShaderUniformSchema), U8 -> Host.ShaderUniformSchema
schema_entry = |schema, index|
	match List.get(schema, U8.to_u64(index)) {
		Ok(entry) => entry
		Err(_) => crash "shader host returned an invalid uniform index"
	}

shader_type_from_kind : U8 -> ShaderUniformType
shader_type_from_kind = |kind|
	match kind {
		0 => Float
		1 => Int
		2 => Bool
		3 => Vec2
		4 => Vec3
		5 => Vec4
		6 => Vec4
		7 => Sampler2D
		_ => Unknown(U8.to_u32(kind))
	}

shader_type_from_gl : U32, U32 -> ShaderUniformType
shader_type_from_gl = |gl_type, array_len|
	if array_len != 1 {
		Array
	} else {
		match gl_type {
			0x1406 => Float
			0x1404 => Int
			0x8B56 => Bool
			0x8B50 => Vec2
			0x8B51 => Vec3
			0x8B52 => Vec4
			0x8B5E => Sampler2D
			_ => Unknown(gl_type)
		}
	}

normalized_color : Color.Rgba -> { x : F32, y : F32, z : F32, w : F32 }
normalized_color = |color| { x: U8.to_f32(color.r) / 255, y: U8.to_f32(color.g) / 255, z: U8.to_f32(color.b) / 255, w: U8.to_f32(color.a) / 255 }

expect uniform_schema({}) == Ok([])
expect {
	uniforms : { amount : F32, enabled : Bool, index : I32 }
	uniforms = { amount: 1.5, enabled: Bool.True, index: 2 }
	uniform_schema(uniforms) == Ok([{ kind: 0, name: "amount" }, { kind: 2, name: "enabled" }, { kind: 1, name: "index" }])
}
