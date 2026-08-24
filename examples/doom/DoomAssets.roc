## Compile-time decoded metadata for the complete E1M1 world and sprite atlases.
## Runtime rendering looks up Doom names in ordinary Roc lists; the host only
## owns the two loaded textures and never interprets map or animation policy.
import "assets/freedoom/generated/e1m1/world_atlas.json" as world_atlas_json : Str
import "assets/freedoom/generated/e1m1/sprite_atlas.json" as sprite_atlas_json : Str

DoomAssets := [].{
	Rect : { x : U64, y : U64, width : U64, height : U64 }
	WorldEntry : { name : Str, rect : Rect, kind : Str, doom_name : Str }
	SpriteAlias : { frame : Str, angle : U64, mirrored : Bool }
	SpriteEntry : { name : Str, rect : Rect, kind : Str, doom_name : Str, sprite : Str, aliases : List(SpriteAlias) }
	WorldAtlas : { width : U64, height : U64, entries : List(WorldEntry) }
	SpriteAtlas : { width : U64, height : U64, entries : List(SpriteEntry) }
	SpriteView : { rect : Rect, mirrored : Bool, doom_name : Str }

	world : WorldAtlas
	world = parse_world(world_atlas_json)

	sprites : SpriteAtlas
	sprites = parse_sprites(sprite_atlas_json)

	## Find a composed wall texture by its eight-character Doom name.
	texture : Str -> Try(Rect, [MissingTexture(Str)])
	texture = |doom_name|
		match List.find_first(world.entries, |entry| entry.kind == "texture" and entry.doom_name == doom_name) {
			Ok(entry) => Ok(entry.rect)
			Err(_) => Err(MissingTexture(doom_name))
		}

	## Find a 64x64 flat by its Doom name.
	flat : Str -> Try(Rect, [MissingFlat(Str)])
	flat = |doom_name|
		match List.find_first(world.entries, |entry| entry.kind == "flat" and entry.doom_name == doom_name) {
			Ok(entry) => Ok(entry.rect)
			Err(_) => Err(MissingFlat(doom_name))
		}

	## Resolve a sprite frame and viewing angle. Angle zero in Doom means one
	## image is valid from every direction; rotated entries can provide a second
	## alias whose pixels must be mirrored by the renderer.
	sprite : Str, Str, U64 -> Try(SpriteView, [MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	sprite = |sprite_name, frame, requested_angle| {
		angle = if requested_angle >= 1 and requested_angle <= 8 requested_angle else 1
		match List.find_first(
			sprites.entries,
			|entry|
				entry.sprite == sprite_name
					and List.any(entry.aliases, |alias| alias.frame == frame and (alias.angle == 0 or alias.angle == angle)),
		) {
			Err(_) => Err(MissingSprite({ sprite: sprite_name, frame, angle: requested_angle }))
			Ok(entry) => {
				alias = List.find_first(entry.aliases, |candidate| candidate.frame == frame and (candidate.angle == 0 or candidate.angle == angle)) ?? crash "matched sprite alias vanished"
				Ok({ rect: entry.rect, mirrored: alias.mirrored, doom_name: entry.doom_name })
			}
		}
	}
}

parse_world : Str -> DoomAssets.WorldAtlas
parse_world = |text|
	match Json.parse(text) {
		Ok(atlas) => atlas
		Err(_) => crash "generated E1M1 world_atlas.json is malformed or its schema changed"
	}

parse_sprites : Str -> DoomAssets.SpriteAtlas
parse_sprites = |text|
	match Json.parse(text) {
		Ok(atlas) => atlas
		Err(_) => crash "generated E1M1 sprite_atlas.json is malformed or its schema changed"
	}

expect {
	wall = DoomAssets.texture("AQCOMP01")
	floor = DoomAssets.flat("AQF001")
	List.len(DoomAssets.world.entries) == 158
		and match wall {
			Ok(rect) => rect.width > 0 and rect.height > 0
			Err(_) => Bool.False
		}
			and match floor {
				Ok(rect) => rect.width == 64 and rect.height == 64
				Err(_) => Bool.False
			}
}

expect {
	front = DoomAssets.sprite("POSS", "A", 1)
	back = DoomAssets.sprite("POSS", "A", 5)
	missing = DoomAssets.sprite("NOPE", "A", 1)
	match front {
		Ok(view) => view.rect.height > 0
		Err(_) => Bool.False
	}
		and match back {
			Ok(view) => view.rect.height > 0
			Err(_) => Bool.False
		}
			and match missing {
				Err(MissingSprite(_)) => Bool.True
				_ => Bool.False
			}
}
