module [create, update]

import Effect
import InternalVector
import RocRay exposing [Camera, Vector2]

## Create a new camera. The camera can be used to render a 2D and 3D perspective of the world.
## ```
## cameraSettings = {
##     target: player,
##     offset: { x: screenWidth / 2, y: screenHeight / 2 },
##     rotation: 0,
##     zoom: 1,
## }
##
## cameraID = Camera.create! cameraSettings
## ```
create : { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } -> Task Camera *
create = \{ target, offset, rotation, zoom } ->
    Effect.createCamera (InternalVector.fromVector2 target) (InternalVector.fromVector2 offset) rotation zoom
    |> Task.map \camera -> camera
    |> Task.mapErr \{} -> crash "unreachable createCamera"

## Update a camera's target, offset, rotation, and zoom.
## ```
## cameraSettings =
##     model.cameraSettings
##     |> &target model.player
##     |> &rotation rotation
##     |> &zoom zoom
##
## Camera.update! model.cameraID cameraSettings
## ```
update : Camera, { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } -> Task {} *
update = \camera, { target, offset, rotation, zoom } ->
    Effect.updateCamera camera (InternalVector.fromVector2 target) (InternalVector.fromVector2 offset) rotation zoom
    |> Task.mapErr \{} -> crash "unreachable updateCamera"
