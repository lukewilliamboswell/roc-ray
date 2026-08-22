## Private host-boundary records shared by the Roc adapter and native host.
##
## This module is intentionally absent from the platform's `exposes` list.
## Applications see `Capture.Status`; the flat record it is decoded from stays
## below that boundary.
AppHost := [].{

	## One cycle's sampled recording state. Unions do not cross the host
	## boundary, so this arrives flat and `AppTransport.capture_status` turns it
	## into the public `Capture.Status`.
	RawCaptureStatus : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
		bytes : U64,
	}
}
