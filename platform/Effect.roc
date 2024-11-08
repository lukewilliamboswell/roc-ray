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
        PlatformTime,
        PlatformStateFromHost,
        PeerState,
        Font,
        toLogLevel,

        # EFFECTS
        getScreenSize!,
        exit!,
        drawText!,
        drawTextFont!,
        measureText!,
        measureTextFont!,
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
        sleepMillis!,
        randomI32!,
        loadFont!,
        configureWebRTC!,
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

PlatformTime : {
    initStart : U64,
    initEnd : U64,
    renderStart : U64,
    lastRenderStart : U64,
    lastRenderEnd : U64,
}

PlatformStateFromHost : {
    frameCount : U64,
    keys : List U8,
    mouseButtons : List U8,
    timestamp : PlatformTime,
    mousePosX : F32,
    mousePosY : F32,
    mouseWheel : F32,
    peers : PeerState,
    messages : List PeerMessage,
}

PeerState : {
    connected : List Effect.RawUUID,
    disconnected : List Effect.RawUUID,
}

log! : Str, I32 => {}

initWindow! : Str, F32, F32 => {}

drawText! : Str, RocVector2, F32, F32, RocColor => {}
drawTextFont! : Font, Str, RocVector2, F32, F32, RocColor => {}

measureText! : Str, F32, F32 => RocVector2
measureTextFont! : Font, Str, F32, F32 => RocVector2

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
createCamera! : RocVector2, RocVector2, F32, F32 => Result Camera Str
updateCamera! : Camera, RocVector2, RocVector2, F32, F32 => {}

beginMode2D! : Camera => {}
endMode2D! : Camera => {}

Texture := Box {}
loadTexture! : Str => Result Texture Str
drawTextureRec! : Texture, RocRectangle, RocVector2, RocColor => {}
drawRenderTextureRec! : RenderTexture, RocRectangle, RocVector2, RocColor => {}

Sound := Box {}
loadSound! : Str => Result Sound Str
playSound! : Sound => {}

Music := Box {}
LoadedMusic : { music : Music, lenSeconds : F32 }
loadMusicStream! : Str => Result LoadedMusic Str
playMusicStream! : Music => {}
stopMusicStream! : Music => {}
pauseMusicStream! : Music => {}
resumeMusicStream! : Music => {}
getMusicTimePlayed! : Music => F32

RenderTexture := Box {}
createRenderTexture! : RocVector2 => Result RenderTexture Str
beginTexture! : RenderTexture, RocColor => {}
endTexture! : RenderTexture => {}

loadFileToStr! : Str => Result Str Str

sendToPeer! : List U8, RawUUID => {}

randomI32! : I32, I32 => I32

sleepMillis! : U64 => {}

Font := Box U64
loadFont! : Str => Result Font Str

configureWebRTC! : Str => {}
