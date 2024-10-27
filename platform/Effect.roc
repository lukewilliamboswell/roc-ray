hosted Effect
    exposes [
        Texture,
        RenderTexture,
        Sound,
        Music,
        LoadedMusic,
        Camera,
        RawUUID,
        PeerMessage,
        getScreenSize!,
        exit!,
        drawText!,
        measureText!,
        drawLine!,
        drawRectangle!,
        drawRectangleGradientV!,
        drawRectangleGradientH!,
        drawCircle!,
        drawCircleGradient!,
        setTargetFPS!,
        setDrawFPS!,
        takeScreenshot!,
        createCamera!,
        updateCamera!,
        initWindow!,
        beginDrawing!,
        endDrawing!,
        beginTexture!,
        endTexture!,
        beginMode2D!,
        endMode2D!,
        log!,
        toLogLevel,
        loadTexture!,
        drawTextureRec!,
        loadSound!,
        playSound!,
        createRenderTexture!,
        drawRenderTextureRec!,
        loadFileToStr!,
        sendToPeer!,
        loadMusicStream!,
        playMusicStream!,
        getMusicTimePlayed!,
        stopMusicStream!,
        pauseMusicStream!,
        resumeMusicStream!,
    ]
    imports []

import InternalColor exposing [RocColor]
import InternalVector exposing [RocVector2]
import InternalRectangle exposing [RocRectangle]

getScreenSize! : {} => { height : I32, width : I32, z : I64 }

exit! : {} => {}

toLogLevel : _ -> I32
toLogLevel = \level ->
    when level is
        LogAll -> 0
        LogTrace -> 1
        LogDebug -> 2
        LogInfo -> 3
        LogWarning -> 4
        LogError -> 5
        LogFatal -> 6
        LogNone -> 7

RawUUID : {
    upper : U64,
    lower : U64,
    zzz1 : U64,
    zzz2 : U64,
    zzz3 : U64,
}

PeerMessage : {
    id : Effect.RawUUID,
    bytes : List U8,
}

log! : Str, I32 => {}

initWindow! : Str, F32, F32 => {}

drawText! : RocVector2, I32, Str, RocColor => {}
measureText! : Str, I32 => I64

drawLine! : RocVector2, RocVector2, RocColor => {}

drawRectangle! : RocRectangle, RocColor => {}
drawRectangleGradientV! : RocRectangle, RocColor, RocColor => {}
drawRectangleGradientH! : RocRectangle, RocColor, RocColor => {}
drawCircle! : RocVector2, F32, RocColor => {}
drawCircleGradient! : RocVector2, F32, RocColor, RocColor => {}

setTargetFPS! : I32 => {}
setDrawFPS! : Bool, RocVector2 => {}

takeScreenshot! : Str => {}

beginDrawing! : RocColor => {}
endDrawing! : {} => {}

Camera := Box {}
createCamera! : RocVector2, RocVector2, F32, F32 => Camera
updateCamera! : Camera, RocVector2, RocVector2, F32, F32 => {}

beginMode2D! : Camera => {}
endMode2D! : Camera => {}

Texture := Box {}
loadTexture! : Str => Texture
drawTextureRec! : Texture, RocRectangle, RocVector2, RocColor => {}
drawRenderTextureRec! : RenderTexture, RocRectangle, RocVector2, RocColor => {}

Sound := Box {}
loadSound! : Str => Sound
playSound! : Sound => {}

Music := Box {}
LoadedMusic : { music : Music, lenSeconds : F32 }
loadMusicStream! : Str => LoadedMusic
playMusicStream! : Music => {}
stopMusicStream! : Music => {}
pauseMusicStream! : Music => {}
resumeMusicStream! : Music => {}
getMusicTimePlayed! : Music => F32

RenderTexture := Box {}
createRenderTexture! : RocVector2 => RenderTexture
beginTexture! : RenderTexture, RocColor => {}
endTexture! : RenderTexture => {}

loadFileToStr! : Str => Str

sendToPeer! : List U8, RawUUID => {}
