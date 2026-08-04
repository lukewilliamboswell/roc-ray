## Internal drawing transport, opaque GPU resources, and hosted effects.
##
## This module is intentionally not exposed by the platform package.
import AssetsHost
import Camera
import Color
import Math

DrawHost := [].{

	## Zero-sized frame capability constructed only by the platform adapter.
	Frame :: {}.{
		for_host : Frame
		for_host = Frame.({})
	}

	FontResource :: Box(U64)

	Font : [DefaultFont, LoadedFont(FontResource)]

	RenderTexture :: AssetsHost.Texture.{
		from_texture : AssetsHost.Texture -> RenderTexture
		from_texture = |texture| RenderTexture.(texture)

		texture : RenderTexture -> AssetsHost.Texture
		texture = |RenderTexture.(texture)| texture
	}

	Shader :: Box(U64).{
		from_resource : Box(U64) -> Shader
		from_resource = |resource| Shader.(resource)
	}

	Uniform :: { shader : Shader, location : I32 }.{
		from_shader_location : Shader, I32 -> Uniform
		from_shader_location = |shader, location| { shader, location }
	}

	Rectangle : { x : F32, y : F32, width : F32, height : F32, color : Color }
	Scissor : { x : F32, y : F32, width : F32, height : F32 }
	RectangleLines : { x : F32, y : F32, width : F32, height : F32, color : Color, thickness : F32 }
	RoundedRectangle : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color }
	RoundedRectangleLines : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color, thickness : F32 }
	RectangleGradientV : { x : F32, y : F32, width : F32, height : F32, color_top : Color, color_bottom : Color }
	RectangleGradientH : { x : F32, y : F32, width : F32, height : F32, color_left : Color, color_right : Color }
	Circle : { center : Math.Vec2, radius : F32, color : Color }
	CircleLines : { center : Math.Vec2, radius : F32, color : Color, thickness : F32 }
	CircleGradient : { center : Math.Vec2, radius : F32, color_inner : Color, color_outer : Color }
	Line : { start : Math.Vec2, end : Math.Vec2, color : Color, thickness : F32 }
	Triangle : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color }
	TriangleLines : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color, thickness : F32 }
	Polygon : { points : List(Math.Vec2), color : Color }
	PolygonLines : { points : List(Math.Vec2), color : Color, thickness : F32 }
	Fps : { pos : Math.Vec2, size : F32, color : Color }
	Text : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color, font : Font }
	TextAligned : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color, font : Font, align_x : F32, align_y : F32 }
	MeasureText : { text : Str, size : F32, spacing : F32, font : Font }
	TextSize : { width : F32, height : F32 }
	LoadFont : { path : Str, size : I32 }
	RenderTextureSize : { width : I32, height : I32 }
	LoadShader : { vertex_path : Str, fragment_path : Str }
	LoadShaderSource : { vertex_source : Str, fragment_source : Str }
	TextureDraw : { texture : AssetsHost.Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color }
	TextureQuad : { texture : AssetsHost.Texture, source : Math.Rect, top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2, tint : Color }
	ShaderLocation : { shader : Shader, name : Str }
	ShaderFloat : { uniform : Uniform, value : F32 }
	ShaderInt : { uniform : Uniform, value : I32 }
	ShaderVec2 : { uniform : Uniform, value : Math.Vec2 }
	ShaderVec3 : { uniform : Uniform, value : { x : F32, y : F32, z : F32 } }
	ShaderVec4 : { uniform : Uniform, value : { x : F32, y : F32, z : F32, w : F32 } }
	ShaderTexture : { uniform : Uniform, texture : AssetsHost.Texture }
	FontResult : { font : FontResource, err : U8 }
	RenderTextureResult : { target : RenderTexture, err : U8 }
	ShaderResult : { shader : Shader, err : U8 }

	begin_camera! : Camera.Camera2D => {}
	end_camera! : () => {}
	begin_blend! : U8 => Bool
	end_blend! : () => {}
	begin_render_texture! : RenderTexture => Bool
	end_render_texture! : () => {}
	begin_scissor! : Scissor => {}
	end_scissor! : () => {}
	begin_shader! : Shader => Bool
	end_shader! : () => {}
	circle! : Circle => {}
	circle_gradient! : CircleGradient => {}
	circle_lines! : CircleLines => {}
	clear! : Color => {}
	fps! : Fps => {}
	line! : Line => {}
	load_font! : LoadFont => FontResult
	load_render_texture! : RenderTextureSize => RenderTextureResult
	load_shader! : LoadShader => ShaderResult
	load_shader_source! : LoadShaderSource => ShaderResult
	measure_text! : MeasureText => TextSize
	polygon! : Polygon => {}
	polygon_lines! : PolygonLines => {}
	rectangle! : Rectangle => {}
	rectangle_gradient_h! : RectangleGradientH => {}
	rectangle_gradient_v! : RectangleGradientV => {}
	rectangle_lines! : RectangleLines => {}
	rounded_rectangle! : RoundedRectangle => {}
	rounded_rectangle_lines! : RoundedRectangleLines => {}
	text! : Text => {}
	text_aligned! : TextAligned => {}
	draw_texture! : TextureDraw => {}
	draw_texture_quad! : TextureQuad => {}
	triangle! : Triangle => {}
	triangle_lines! : TriangleLines => {}
	shader_location! : ShaderLocation => I32
	set_shader_float! : ShaderFloat => {}
	set_shader_int! : ShaderInt => {}
	set_shader_vec2! : ShaderVec2 => {}
	set_shader_vec3! : ShaderVec3 => {}
	set_shader_vec4! : ShaderVec4 => {}
	set_shader_texture! : ShaderTexture => {}
}
