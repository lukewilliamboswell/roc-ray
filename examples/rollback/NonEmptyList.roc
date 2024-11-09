module [
    NonEmptyList,
    new,
    first,
    last,
    findLast,
    findFirst,
    map,
    toList,
    dropNonLastIf,
]

NonEmptyList a := Inner a

Inner a : {
    list : List a,
    last : a,
}

new : a -> NonEmptyList a
new = \item ->
    @NonEmptyList { list: [], last: item }

first : NonEmptyList a -> a
first = \@NonEmptyList inner ->
    when List.first inner.list is
        Ok f -> f
        Err ListWasEmpty -> inner.last

last : NonEmptyList a -> a
last = \@NonEmptyList inner ->
    inner.last

findLast : NonEmptyList a, (a -> Bool) -> Result a [NotFound]
findLast = \@NonEmptyList inner, isMatch ->
    if isMatch inner.last then
        Ok inner.last
    else
        List.findLast inner.list isMatch

findFirst : NonEmptyList a, (a -> Bool) -> Result a [NotFound]
findFirst = \@NonEmptyList inner, isMatch ->
    when List.findFirst inner.list isMatch is
        Ok found -> Ok found
        Err NotFound ->
            if isMatch inner.last then
                Ok inner.last
            else
                Err NotFound

map : NonEmptyList a, (a -> b) -> NonEmptyList b
map = \@NonEmptyList inner, transform ->
    newList = List.map inner.list transform
    newLast = transform inner.last
    @NonEmptyList { list: newList, last: newLast }

toList : NonEmptyList a -> List a
toList = \@NonEmptyList inner ->
    inner.list
    |> List.append inner.last

dropNonLastIf : NonEmptyList a, (a -> Bool) -> NonEmptyList a
dropNonLastIf = \@NonEmptyList inner, shouldDrop ->
    list = List.dropIf inner.list shouldDrop
    @NonEmptyList { inner & list }
