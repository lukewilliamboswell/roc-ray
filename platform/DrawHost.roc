## Internal drawing transport, opaque GPU resources, and hosted effects.
##
## This module is intentionally not exposed by the platform package.
import AssetsHost
import Camera
import Color
import Math

DrawHost := [].{
	Font :: { resource : Box(U64) }.{
		from_resource : Box(U64) -> Font
		from_resource = |resource| { resource: resource }

		handle : Font -> U64
		handle = |font| Box.unbox(font.resource)
	}

	RenderTexture :: { texture : AssetsHost.Texture }.{
		from_texture : AssetsHost.Texture -> RenderTexture
		from_texture = |texture| { texture: texture }

		texture : RenderTexture -> AssetsHost.Texture
		texture = |target| target.texture
	}

	Shader :: { resource : Box(U64) }.{
		from_resource : Box(U64) -> Shader
		from_resource = |resource| { resource: resource }

		handle : Shader -> U64
		handle = |shader| Box.unbox(shader.resource)
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
	Text : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color, font : U64 }
	TextAligned : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color, font : U64, align_x : F32, align_y : F32 }
	MeasureText : { text : Str, size : F32, spacing : F32, font : U64 }
	TextSize : { width : F32, height : F32 }
	LoadFont : { path : Str, size : I32 }
	RenderTextureSize : { width : I32, height : I32 }
	LoadShader : { vertex_path : Str, fragment_path : Str }
	LoadShaderSource : { vertex_source : Str, fragment_source : Str }
	TextureDraw : { texture : U64, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color }
	TextureQuad : { texture : U64, source : Math.Rect, top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2, tint : Color }
	ShaderLocation : { shader : U64, name : Str }
	ShaderFloat : { shader : U64, location : I32, value : F32 }
	ShaderInt : { shader : U64, location : I32, value : I32 }
	ShaderVec2 : { shader : U64, location : I32, value : Math.Vec2 }
	ShaderVec3 : { shader : U64, location : I32, value : { x : F32, y : F32, z : F32 } }
	ShaderVec4 : { shader : U64, location : I32, value : { x : F32, y : F32, z : F32, w : F32 } }
	ShaderTexture : { shader : U64, location : I32, texture : U64 }

	begin_camera! : Camera.Camera2D => {}
	end_camera! : () => {}
	begin_blend! : U8 => Bool
	end_blend! : () => {}
	begin_frame! : () => {}
	end_frame! : () => {}
	begin_render_texture! : U64 => Bool
	end_render_texture! : () => {}
	begin_scissor! : Scissor => {}
	end_scissor! : () => {}
	begin_shader! : U64 => Bool
	end_shader! : () => {}
	circle! : Circle => {}
	circle_gradient! : CircleGradient => {}
	circle_lines! : CircleLines => {}
	clear! : Color => {}
	fps! : Fps => {}
	line! : Line => {}
	load_font! : LoadFont => Box(U64)
	load_render_texture! : RenderTextureSize => Box({ handle : U64, width : F32, height : F32 })
	load_shader! : LoadShader => Box(U64)
	load_shader_source! : LoadShaderSource => Box(U64)
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
