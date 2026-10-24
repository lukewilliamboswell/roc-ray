## Shared host-owned texture value.
##
## The handle is an opaque, reference-counted native resource identity. Width
## and height are descriptive pixel metadata kept directly on the value for
## pure layout and source-rectangle calculations.

import Resource

Texture := {
	handle : TextureHandle,
	width : F32,
	height : F32,
}.{
	TextureHandle : Resource.Texture

	## Encode this texture as one semantic leaf for formats that support
	## textures. Shader uniform records use this for one GLSL `sampler2D`.
	encoder_for : encoding -> (Texture, state -> Try(state, err))
		where [
			encoding.encode_texture : Texture, state -> Try(state, err),
		]
	encoder_for = |_encoding| {
		Encoding : encoding

		|texture, state| Encoding.encode_texture(texture, state)
	}

	## Resource-free texture value for pure tests.
	##
	## The handle never resolves to a host resource. Copy this value with the
	## dimensions needed by the test. Do not use it to test drawing, mutation,
	## sampling configuration, or resource lifetime.
	stub : Texture
	stub = {
		handle: Resource.Handle.stub({}),
		width: 0,
		height: 0,
	}
}
