## Pure parts of `scripts/check_glue.roc`: which compiler is running, and
## where that compiler's glue specification is published.
Glue := [].{

	## The nightly release tag in the output of `roc version`, such as
	## `nightly-2026-10-09-258ab27`. A compiler built from source reports
	## none, and names its glue source with `--roc-repo` instead.
	nightly_tag : Str -> Try(Str, [NotANightly])
	nightly_tag = |version_output| {
		words = version_output.split_on("\n").join_map(|line| line.split_on(" ")).map(Str.trim)
		match words.keep_if(|word| word.starts_with("nightly-") and word.split_on("-").len() == 5).first() {
			Ok(tag) => Ok(tag)
			Err(_) => Err(NotANightly)
		}
	}

	## The source archive a nightly release attaches. Its only top-level
	## directory has the same name without the extension.
	source_asset : Str -> Str
	source_asset = |tag| "roc_nightly-source-${tag.drop_prefix("nightly-")}.tar.gz"

	## The lowercase hexadecimal SHA-256 in a release asset digest, which
	## GitHub writes as `sha256:<hex>`.
	sha256_of_digest : Str -> Try(Str, [NotSha256])
	sha256_of_digest = |digest| {
		text = digest.trim()
		hex = text.drop_prefix("sha256:")
		if text.starts_with("sha256:") and hex.to_utf8().len() == 64 and hex.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')) {
			Ok(hex)
		} else {
			Err(NotSha256)
		}
	}

	## The first field of a `sha256sum` line.
	sha256_of_sum : Str -> Str
	sha256_of_sum = |line| line.trim().split_on(" ").first() ?? ""
}

expect Glue.nightly_tag("Roc compiler version nightly-2026-10-09-258ab27\n") == Ok("nightly-2026-10-09-258ab27")
expect Glue.nightly_tag("Roc compiler version debug-b759efd1") == Err(NotANightly)
expect Glue.nightly_tag("nightly-build") == Err(NotANightly)
expect Glue.nightly_tag("") == Err(NotANightly)
expect Glue.source_asset("nightly-2026-10-09-258ab27") == "roc_nightly-source-2026-10-09-258ab27.tar.gz"
expect Glue.sha256_of_digest("sha256:a3407158152293bd1bf7183655374502d8da5f06192aa930ed8d240a979d2679\n") == Ok("a3407158152293bd1bf7183655374502d8da5f06192aa930ed8d240a979d2679")
expect Glue.sha256_of_digest("sha512:a3") == Err(NotSha256)
expect Glue.sha256_of_digest("") == Err(NotSha256)
expect Glue.sha256_of_sum("a340  file.tar.gz\n") == "a340"
