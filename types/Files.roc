## Filesystem result vocabulary shared by RocRay and reusable packages.
##
## Hosted file effects live in the platform. The package owns their public
## result types so an injected effect bundle can preserve the exact outcome
## without making a reusable package depend on RocRay.

Files := [].{

	## Why a bounded UTF-8 file read produced no string.
	ReadTextError : [NotFound, ReadFailed, Busy, Unavailable, TooLarge, NotUtf8]
}
