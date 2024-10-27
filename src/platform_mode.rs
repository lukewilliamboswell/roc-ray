use std::cell::RefCell;

thread_local! {
    static PLATFORM_MODE: RefCell<PlatformMode> = const { RefCell::new(PlatformMode::Init) };
}

/// we check at runtime which mode the platform is in and if the effect is permitted
///
/// is an app author tries to call an effect that is not permitted in the current mode
/// the app will exit with an error code and provide a message to the user
///
/// this is used to keep the API very simple instead of having each effect return a result
/// or taking an argument which "locks" which effects are permitted.
///
/// if this is expensive for performance, we can only include this in dev builds and remove
/// it in release builds
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PlatformMode {
    Init,
    InitRaylib,
    Render,
    TextureMode,
    TextureModeDraw2D,
    FramebufferMode,
    FramebufferModeDraw2D,
}

/// effects that are only permitted in certain modes
///
/// not all effects need to be listed here
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PlatformEffect {
    BeginDrawingFramebuffer,
    EndDrawingFramebuffer,
    BeginMode2D,
    EndMode2D,
    BeginDrawingTexture,
    EndDrawingTexture,
    CreateCamera,
    UpdateCamera,
    LoadTexture,
    CreateRenderTexture,
    TakeScreenshot,
    InitWindow,
    EndInitWindow,
    LogMsg,
    SetTargetFPS,
    GetScreenSize,
    SendMsgToPeer,
    LoadSound,
    LoadMusicStream,
    LoadFileToStr,
    PlaySound,
    PlayMusicStream,
    DrawCircle,
    DrawCircleGradient,
    DrawRectangleGradientV,
    DrawRectangleGradientH,
    SetDrawFPS,
    MeasureText,
    DrawText,
    DrawRectangle,
    DrawLine,
    DrawTextureRectangle,
}

impl PlatformMode {
    /// only these modes are permitted to "draw" as raylib has a framebuffer and texture ready
    fn is_draw_mode(&self) -> bool {
        use PlatformMode::*;
        matches!(
            self,
            FramebufferMode | FramebufferModeDraw2D | TextureMode | TextureModeDraw2D
        )
    }

    fn not_init(&self) -> bool {
        !matches!(self, PlatformMode::Init)
    }

    fn after_init(&self) -> bool {
        !matches!(self, PlatformMode::Init)
    }

    fn is_effect_permitted(&self, e: PlatformEffect) -> bool {
        use PlatformEffect::*;
        use PlatformMode::*;

        // we only need to track the "permitted" effects, everything else is "not permitted"
        match (self, e) {
            // PERMITTED IN ANY MODE
            (_, SetDrawFPS)
            | (_, SetTargetFPS)
            | (_, MeasureText)
            | (_, LogMsg)
            // TODO SendMsgToPeer should only be if we have initialized the "network"
            | (_, SendMsgToPeer) => true,

            // PERMITTED ONLY AFTER INIT (NEEDS RAYLIB INIT)
            (mode, LoadFileToStr) if mode.after_init() => true,
            (mode, UpdateCamera) if mode.after_init() => true,

            // PERMITTED DURING INIT BUT AFTER RAYLIB INIT
            (InitRaylib, CreateCamera)
            | (InitRaylib, LoadSound)
            | (InitRaylib, LoadMusicStream)
            | (InitRaylib, LoadTexture)
            | (InitRaylib, CreateRenderTexture) => true,

            // MODE TRANISITIONS
            (Init, InitWindow)
            | (InitRaylib, EndInitWindow)
            | (Render, BeginDrawingFramebuffer)
            | (Render, BeginDrawingTexture)
            | (FramebufferMode, BeginMode2D)
            | (FramebufferMode, EndDrawingFramebuffer)
            | (FramebufferModeDraw2D, EndMode2D)
            | (TextureMode, EndDrawingTexture)
            | (TextureMode, BeginMode2D)
            | (TextureModeDraw2D, EndMode2D) => true,

            // PERMITTED IN RENDER
            (Render, UpdateCamera) => true,

            // PERMITTED ONLY IN RENDER
            (mode, PlaySound) if mode.not_init() => true,
            (mode, PlayMusicStream) if mode.not_init() => true,
            (mode, TakeScreenshot) if mode.not_init() => true,
            (mode, GetScreenSize) if mode.not_init() => true,

            // PERMITTED ONLY DURING DRAW MODES
            (mode, DrawCircle) if mode.is_draw_mode() => true,
            (mode, DrawCircleGradient) if mode.is_draw_mode() => true,
            (mode, DrawRectangleGradientV) if mode.is_draw_mode() => true,
            (mode, DrawRectangleGradientH) if mode.is_draw_mode() => true,
            (mode, DrawText) if mode.is_draw_mode() => true,
            (mode, DrawRectangle) if mode.is_draw_mode() => true,
            (mode, DrawLine) if mode.is_draw_mode() => true,
            (mode, DrawTextureRectangle) if mode.is_draw_mode() => true,

            // NOT PERMITTED
            (_, _) => false,
        }
    }
}

pub fn update(effect: PlatformEffect) -> Result<(), String> {
    PLATFORM_MODE.with(|m| {
        let mut mode = m.borrow_mut();

        use PlatformEffect::*;
        match *mode {
            PlatformMode::Init if matches!(effect, InitWindow) => {
                *mode = PlatformMode::InitRaylib;
                Ok(())
            }
            PlatformMode::InitRaylib if matches!(effect, EndInitWindow) => {
                *mode = PlatformMode::Render;
                Ok(())
            }
            PlatformMode::Render if matches!(effect, BeginDrawingFramebuffer) => {
                *mode = PlatformMode::FramebufferMode;
                Ok(())
            }
            PlatformMode::Render if matches!(effect, BeginDrawingTexture) => {
                *mode = PlatformMode::TextureMode;
                Ok(())
            }
            PlatformMode::FramebufferMode if matches!(effect, EndDrawingFramebuffer) => {
                *mode = PlatformMode::Render;
                Ok(())
            }
            PlatformMode::FramebufferMode if matches!(effect, BeginMode2D) => {
                *mode = PlatformMode::FramebufferModeDraw2D;
                Ok(())
            }
            PlatformMode::FramebufferModeDraw2D if matches!(effect, EndMode2D) => {
                *mode = PlatformMode::FramebufferMode;
                Ok(())
            }
            PlatformMode::TextureMode if matches!(effect, EndDrawingTexture) => {
                *mode = PlatformMode::Render;
                Ok(())
            }
            PlatformMode::TextureMode if matches!(effect, BeginMode2D) => {
                *mode = PlatformMode::TextureModeDraw2D;
                Ok(())
            }
            PlatformMode::TextureModeDraw2D if matches!(effect, EndMode2D) => {
                *mode = PlatformMode::TextureMode;
                Ok(())
            }
            current_mode if current_mode.is_effect_permitted(effect) => Ok(()),
            _ => Err(format!(
                "Effect {:?} not permitted in mode {:?}",
                effect, *mode
            )),
        }
    })
}

#[cfg(test)]
mod test_platform_mode_transitions {

    use super::*;

    fn set_platform_mode(mode: PlatformMode) {
        PLATFORM_MODE.with(|m| *m.borrow_mut() = mode);
    }

    fn get_platform_mode() -> PlatformMode {
        PLATFORM_MODE.with(|m| m.borrow().clone())
    }

    #[test]
    fn test_initial_mode() {
        assert_eq!(get_platform_mode(), PlatformMode::Init);
    }

    #[test]
    fn test_begin_drawing_framebuffer() {
        set_platform_mode(PlatformMode::Render);
        update(PlatformEffect::BeginDrawingFramebuffer).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::FramebufferMode);
    }

    #[test]
    fn test_end_drawing_framebuffer() {
        set_platform_mode(PlatformMode::FramebufferMode);
        update(PlatformEffect::EndDrawingFramebuffer).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::Render);
    }

    #[test]
    fn test_begin_texture() {
        set_platform_mode(PlatformMode::Render);
        update(PlatformEffect::BeginDrawingTexture).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::TextureMode);
    }

    #[test]
    fn test_end_texture() {
        set_platform_mode(PlatformMode::TextureMode);
        update(PlatformEffect::EndDrawingTexture).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::Render);
    }

    #[test]
    fn test_begin_mode_2d_from_framebuffer() {
        set_platform_mode(PlatformMode::FramebufferMode);
        update(PlatformEffect::BeginMode2D).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::FramebufferModeDraw2D);
    }

    #[test]
    fn test_end_mode_2d_to_framebuffer() {
        set_platform_mode(PlatformMode::FramebufferModeDraw2D);
        update(PlatformEffect::EndMode2D).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::FramebufferMode);
    }

    #[test]
    fn test_begin_mode_2d_from_texture() {
        set_platform_mode(PlatformMode::TextureMode);
        update(PlatformEffect::BeginMode2D).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::TextureModeDraw2D);
    }

    #[test]
    fn test_end_mode_2d_to_texture() {
        set_platform_mode(PlatformMode::TextureModeDraw2D);
        update(PlatformEffect::EndMode2D).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::TextureMode);
    }

    #[test]
    fn test_init_to_init_raylib() {
        set_platform_mode(PlatformMode::Init);
        update(PlatformEffect::InitWindow).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::InitRaylib);
    }

    #[test]
    fn test_init_raylib_to_render() {
        set_platform_mode(PlatformMode::InitRaylib);
        update(PlatformEffect::EndInitWindow).unwrap();
        assert_eq!(get_platform_mode(), PlatformMode::Render);
    }
}
