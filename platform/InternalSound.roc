module [SoundId, pack, unpack]

## A platform-private opaque wrapper around an index
SoundId := U32

pack : U32 -> SoundId
pack = \id -> @SoundId id

unpack : SoundId -> U32
unpack = \@SoundId id -> id
