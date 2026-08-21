## Private request/response transport shared by the Roc adapter and native host.
##
## This module is intentionally absent from the platform's `exposes` list.
## Applications use `App.Request` and receive mapped messages through
## `App.Input`; raw records and correlation tickets stay below that boundary.
AppHost := [].{

	SubmittedRequest(msg) : {
		kind : U8,
		path : Str,
		millis : U64,
		deliver : Box(RawResponse -> Box(msg)),
	}

	RawResponse : {
		kind : U8,
		ticket : U64,
		err : U8,
		contents : Str,
		bytes : List(U8),
	}

	PendingResponse(msg) : {
		raw : RawResponse,
		deliver : Box(RawResponse -> Box(msg)),
	}

	RawCaptureStatus : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
		bytes : U64,
	}
}
