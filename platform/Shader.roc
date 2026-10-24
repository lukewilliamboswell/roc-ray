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

Shader(uniforms) :: { resource : Resource.Shader, uniforms : uniforms, values : List(Host.ShaderUniformValue) }.{

	## Compile shader stages from source strings and validate the complete
	## application-uniform schema. Legal in `init!`, `update!`, and tasks;
	## refused in `render!`.
	from_source! : LoadShaderSource, uniforms => Try(Shader(uniforms), [ShaderLoadFailed, ResourceLimit, UniformNotFound(Str), UniformReflectionUnavailable, UniformTypeMismatch({ name : Str, expected : ShaderUniformType, actual : ShaderUniformType }), UnsupportedUniformType(Str)])
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	from_source! = |cfg, uniforms| {
		schema = uniform_schema(uniforms)?
		# Rebuilt with a match, never `?`. A hosted call's error union is fixed
		# by the host, so it cannot widen into this function's row. The compiler
		# misses that when the row is an alias such as `ShaderLoadSourceError`,
		# and `?` then reads the host's `Ok` as an `Err` (roc-lang/roc#12555).
		shader = match Host.shader_load_source!(cfg) {
			Ok(loaded) => loaded
			Err(ShaderLoadFailed) => return Err(ShaderLoadFailed)
			Err(ResourceLimit) => return Err(ResourceLimit)
		}
		bind_shader_uniforms!(shader, schema)?
		values = uniform_values(uniforms)
		Ok(Shader.({ resource: shader, uniforms, values: values.values }))
	}

	## Compile shader stage files resolved through an explicit asset store.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	from_store! : Assets.Store, LoadShader, uniforms => Try(Shader(uniforms), [PathInvalid, NotFound, ReadFailed, ShaderLoadFailed, ResourceLimit, UniformNotFound(Str), UniformReflectionUnavailable, UniformTypeMismatch({ name : Str, expected : ShaderUniformType, actual : ShaderUniformType }), UnsupportedUniformType(Str)])
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	from_store! = |store, cfg, uniforms| {
		schema = uniform_schema(uniforms)?
		# Rebuilt with a match, never `?`; see `from_source!`.
		shader = match Host.shader_load_store!({ store: store.for_host(), vertex_path: cfg.vertex_path, fragment_path: cfg.fragment_path }) {
			Ok(loaded) => loaded
			Err(PathInvalid) => return Err(PathInvalid)
			Err(NotFound) => return Err(NotFound)
			Err(ReadFailed) => return Err(ReadFailed)
			Err(ShaderLoadFailed) => return Err(ShaderLoadFailed)
			Err(ResourceLimit) => return Err(ResourceLimit)
		}
		bind_shader_uniforms!(shader, schema)?
		values = uniform_values(uniforms)
		Ok(Shader.({ resource: shader, uniforms, values: values.values }))
	}

	## Return a shader sharing its compiled program and binding layout with a
	## replaced, type-checked uniform record. This is pure.
	with_uniforms : Shader(uniforms), uniforms -> Shader(uniforms)
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	with_uniforms = |Shader.(shader), values| {
		encoded = uniform_values(values)
		Shader.({ ..shader, uniforms: values, values: encoded.values })
	}

	## Resource-free shader value for pure tests.
	stub : uniforms -> Shader(uniforms)
		where [
			uniforms.encoder_for : UniformFormat -> (uniforms, UniformState -> Try(UniformState, UniformEncodeError)),
		]
	stub = |uniforms| {
		encoded = uniform_values(uniforms)
		Shader.({ resource: Resource.Handle.stub({}), uniforms, values: encoded.values })
	}

	## Private frame payload assembled from the retained uniform record.
	for_frame : Shader(uniforms) -> { resource : Resource.Shader, values : List(Host.ShaderUniformValue) }
	for_frame = |Shader.({ resource, values, .. })| { resource, values }

}

ShaderUniformType : [Array(U32), Bool, Float, Int, Sampler2D, Vec2, Vec3, Vec4, Unknown(U32)]

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
	encode_f32 = |value, state| record_uniform(state, Host.shader_uniform_kind_float, Host.ShaderUniformValue.Float(value))
	encode_i32 : I32, UniformState -> Try(UniformState, UniformEncodeError)
	encode_i32 = |value, state| record_uniform(state, Host.shader_uniform_kind_int, Host.ShaderUniformValue.Int(value))
	encode_bool : Bool, UniformState -> Try(UniformState, UniformEncodeError)
	encode_bool = |value, state| record_uniform(state, Host.shader_uniform_kind_bool, Host.ShaderUniformValue.Bool(value))
	encode_vec2 : Math.Vec2, UniformState -> Try(UniformState, UniformEncodeError)
	encode_vec2 = |value, state| record_uniform(state, Host.shader_uniform_kind_vec2, Host.ShaderUniformValue.Vec2({ x: value.x, y: value.y }))
	encode_vec3 : Math.Vec3, UniformState -> Try(UniformState, UniformEncodeError)
	encode_vec3 = |value, state| record_uniform(state, Host.shader_uniform_kind_vec3, Host.ShaderUniformValue.Vec3({ x: value.x, y: value.y, z: value.z }))
	encode_vec4 : Math.Vec4, UniformState -> Try(UniformState, UniformEncodeError)
	encode_vec4 = |value, state| record_uniform(state, Host.shader_uniform_kind_vec4, Host.ShaderUniformValue.Vec4({ x: value.x, y: value.y, z: value.z, w: value.w }))
	encode_color : Color.Rgba, UniformState -> Try(UniformState, UniformEncodeError)
	encode_color = |color, state| {
		value = normalized_color(color)
		record_uniform(state, Host.shader_uniform_kind_vec4, Host.ShaderUniformValue.Vec4({ x: value.x, y: value.y, z: value.z, w: value.w }))
	}
	encode_texture : Assets.Texture, UniformState -> Try(UniformState, UniformEncodeError)
	encode_texture = |texture, state| {
		record_uniform(state, Host.shader_uniform_kind_sampler2d, Host.ShaderUniformValue.Sampler2D(texture))
	}
}

UniformEncodeMode : [SchemaMode, ValueMode]

UniformEncodeError : [NestedUniformRecord(Str)]

UniformState : {
	field : [Field(Str), NoField],
	mode : UniformEncodeMode,
	schema : List(Host.ShaderUniformSchema),
	values : List(Host.ShaderUniformValue),
}

empty_uniform_state : UniformEncodeMode -> UniformState
empty_uniform_state = |mode| { field: NoField, mode, schema: [], values: [] }

record_uniform : UniformState, Host.ShaderUniformKind, Host.ShaderUniformValue -> Try(UniformState, UniformEncodeError)
record_uniform = |state, kind, value| {
	match state.field {
		NoField => crash "uniform value was encoded outside its record field"
		Field(name) => match state.mode {
			SchemaMode => Ok({ ..state, schema: state.schema.append({ kind, name }) })
			ValueMode => Ok({ ..state, values: state.values.append(value) })
		}
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

bind_shader_uniforms! : Resource.Shader, List(Host.ShaderUniformSchema) => Try({}, [ResourceLimit, UniformNotFound(Str), UniformReflectionUnavailable, UniformTypeMismatch({ name : Str, expected : ShaderUniformType, actual : ShaderUniformType })])
bind_shader_uniforms! = |shader, schema|
	match Host.shader_bind_uniforms!(shader, schema) {
		Ok({}) => Ok({})
		Err(ResourceLimit) => Err(ResourceLimit)
		Err(UniformReflectionUnavailable) => Err(UniformReflectionUnavailable)
		Err(UniformNotFound(index)) => Err(UniformNotFound(schema_entry(schema, index).name))
		Err(UniformTypeMismatch({ actual, array_len, index })) => {
			entry = schema_entry(schema, index)
			Err(UniformTypeMismatch({ name: entry.name, expected: shader_type_from_kind(entry), actual: shader_type_from_gl(actual, array_len) }))
		}
	}

schema_entry : List(Host.ShaderUniformSchema), U8 -> Host.ShaderUniformSchema
schema_entry = |schema, index|
	match List.get(schema, U8.to_u64(index)) {
		Ok(entry) => entry
		Err(_) => crash "shader host returned an invalid uniform index"
	}

shader_type_from_kind : Host.ShaderUniformSchema -> ShaderUniformType
shader_type_from_kind = |kind|
	match kind.kind {
		Float => Float
		Int => Int
		Bool => Bool
		Vec2 => Vec2
		Vec3 => Vec3
		Vec4 => Vec4
		Sampler2D => Sampler2D
	}

shader_type_from_gl : U32, U32 -> ShaderUniformType
shader_type_from_gl = |gl_type, array_len|
	if array_len != 1 {
		Array(array_len)
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
	uniform_schema(uniforms) == Ok([
		{ kind: Host.shader_uniform_kind_float, name: "amount" },
		{ kind: Host.shader_uniform_kind_bool, name: "enabled" },
		{ kind: Host.shader_uniform_kind_int, name: "index" },
	])
}
