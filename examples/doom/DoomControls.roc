## Host-input mapping for the Doom world/camera coordinate convention.
##
## DoomSim follows the original `side` convention: positive side thrust is
## facing-minus-90 degrees. RocRay's camera embeds Doom y as world z, making
## that direction screen-left. Therefore a screen-right key is a negative
## simulation-side command. Positive mouse x still rotates toward screen-right.
import DoomSim

DoomControls := [].{
	side : Bool, Bool -> I16
	side = |left, right|
		if left and !(right) 40 else if right and !(left) -40 else 0

	turn : F32 -> F32
	turn = |mouse_delta_x| mouse_delta_x * mouse_turns_per_pixel

	visual_right : DoomSim.Angle -> DoomSim.Vec2
	visual_right = |angle| {
		facing = angle.forward()
		{ x: 0 - facing.y, y: facing.x }
	}
}

mouse_turns_per_pixel = 0.0004

expect DoomControls.side(Bool.False, Bool.True) == -40
expect DoomControls.side(Bool.True, Bool.False) == 40
expect DoomControls.side(Bool.True, Bool.True) == 0

expect {
	angle = DoomSim.Angle.from_turns(0)
	right = DoomControls.visual_right(angle)
	turned = angle.add(DoomControls.turn(20)).forward()
	DoomSim.dot(turned, right) > 0
}
