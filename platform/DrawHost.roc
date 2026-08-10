## Internal drawing transport, opaque GPU resources, and hosted effects.
##
## This module is intentionally not exposed by the platform package.
import Assets
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
	PreparedText :: Box(U64)

	Font : [DefaultFont, LoadedFont(FontResource)]

	RenderTexture :: Assets.TextureView.{
		texture : RenderTexture -> Assets.TextureView
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

	Rectangle : { x : F32, y : F32, width : F32, height : F32, color : Color.Rgba }
	Scissor : { x : F32, y : F32, width : F32, height : F32 }
	RectangleLines : { x : F32, y : F32, width : F32, height : F32, color : Color.Rgba, thickness : F32 }
	RoundedRectangle : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color.Rgba }
	RoundedRectangleLines : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color.Rgba, thickness : F32 }
	RectangleGradientV : { x : F32, y : F32, width : F32, height : F32, color_top : Color.Rgba, color_bottom : Color.Rgba }
	RectangleGradientH : { x : F32, y : F32, width : F32, height : F32, color_left : Color.Rgba, color_right : Color.Rgba }
	Circle : { center : Math.Vec2, radius : F32, color : Color.Rgba }
	CircleLines : { center : Math.Vec2, radius : F32, color : Color.Rgba, thickness : F32 }
	CircleGradient : { center : Math.Vec2, radius : F32, color_inner : Color.Rgba, color_outer : Color.Rgba }
	Line : { start : Math.Vec2, end : Math.Vec2, color : Color.Rgba, thickness : F32 }
	Triangle : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color.Rgba }
	TriangleLines : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color.Rgba, thickness : F32 }
	Polygon : { points : List(Math.Vec2), color : Color.Rgba }
	PolygonLines : { points : List(Math.Vec2), color : Color.Rgba, thickness : F32 }
	Fps : { pos : Math.Vec2, size : F32, color : Color.Rgba }
	Text : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : Font }
	TextAligned : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : Font, align_x : F32, align_y : F32 }
	GlyphMetric : { codepoint : U32, advance : F32 }
	FontMetrics : { base_size : F32, line_spacing : F32, fallback_advance : F32, glyphs : List(GlyphMetric) }
	PrepareText : { text : Str, size : F32, spacing : F32, font : Font }
	PrepareTextResult : { prepared : PreparedText, width : F32, height : F32, err : U8 }
	PreparedTextDraw : { prepared : PreparedText, pos : Math.Vec2, color : Color.Rgba }
	LoadFont : { path : Str, size : I32 }
	LoadFontBytes : { format : U8, bytes : List(U8), size : I32 }
	LoadStoreFont : { store : Assets.Store, path : Str, size : I32 }
	RenderTextureSize : { width : I32, height : I32 }
	LoadShader : { vertex_path : Str, fragment_path : Str }
	LoadShaderSource : { vertex_source : Str, fragment_source : Str }
	LoadStoreShader : { store : Assets.Store, vertex_path : Str, fragment_path : Str }
	TextureDraw : { texture : Assets.TextureView, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }
	TextureQuad : { texture : Assets.TextureView, source : Math.Rect, top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2, q_top_left : F32, q_bottom_left : F32, q_bottom_right : F32, q_top_right : F32, tint : Color.Rgba }
	ShaderLocation : { shader : Shader, name : Str }
	ShaderFloat : { uniform : Uniform, value : F32 }
	ShaderInt : { uniform : Uniform, value : I32 }
	ShaderVec2 : { uniform : Uniform, value : Math.Vec2 }
	ShaderVec3 : { uniform : Uniform, value : { x : F32, y : F32, z : F32 } }
	ShaderVec4 : { uniform : Uniform, value : { x : F32, y : F32, z : F32, w : F32 } }
	ShaderTexture : { uniform : Uniform, texture : Assets.TextureView }
	FontResult : { font : FontResource, err : U8 }
	RenderTextureResult : { target : RenderTexture, err : U8 }
	ShaderResult : { shader : Shader, err : U8 }

	begin_camera! : Camera.Camera2D => U8
	end_camera! : () => {}
	begin_blend! : U8 => U8
	end_blend! : () => {}
	begin_render_texture! : RenderTexture => U8
	end_render_texture! : () => {}
	begin_scissor! : Scissor => U8
	end_scissor! : () => {}
	begin_shader! : Shader => U8
	end_shader! : () => {}
	circle! : Circle => {}
	circle_gradient! : CircleGradient => {}
	circle_lines! : CircleLines => {}
	clear! : Color.Rgba => {}
	fps! : Fps => {}
	line! : Line => {}
	load_font! : LoadFont => FontResult
	load_font_bytes! : LoadFontBytes => FontResult
	load_store_font! : LoadStoreFont => FontResult
	load_render_texture! : RenderTextureSize => RenderTextureResult
	load_shader! : LoadShader => ShaderResult
	load_shader_source! : LoadShaderSource => ShaderResult
	load_store_shader! : LoadStoreShader => ShaderResult
	font_metrics! : Font => FontMetrics
	prepare_text! : PrepareText => PrepareTextResult
	draw_prepared_text! : PreparedTextDraw => {}
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
