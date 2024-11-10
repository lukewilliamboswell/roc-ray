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
    append,
    appendAll,
    updateNonLast,
    sortWith,
    fromList,
]

## A List guaranteed to contain at least one item
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

fromList : List a -> Result (NonEmptyList a) [ListWasEmpty]
fromList = \original ->
    when List.last original is
        Err ListWasEmpty -> Err ListWasEmpty
        Ok lastItem ->
            nonLast = List.dropLast original 1
            Ok (@NonEmptyList { list: nonLast, last: lastItem })

## Drop items from the list matching a predicate
## But keep the last item in the list regardless of whether it passes
dropNonLastIf : NonEmptyList a, (a -> Bool) -> NonEmptyList a
dropNonLastIf = \@NonEmptyList inner, shouldDrop ->
    list = List.dropIf inner.list shouldDrop
    @NonEmptyList { inner & list }

updateNonLast : NonEmptyList a, (List a -> List a) -> NonEmptyList a
updateNonLast = \@NonEmptyList inner, update ->
    list = update inner.list
    @NonEmptyList { inner & list }

append : NonEmptyList a, a -> NonEmptyList a
append = \@NonEmptyList inner, item ->
    @NonEmptyList {
        last: item,
        list: List.append inner.list inner.last,
    }

appendAll : NonEmptyList a, List a -> NonEmptyList a
appendAll = \@NonEmptyList inner, items ->
    when List.last items is
        Err ListWasEmpty -> @NonEmptyList inner
        Ok newLast ->
            newNonLast = List.takeFirst items (List.len items - 1)
            @NonEmptyList {
                last: newLast,
                list: List.concat inner.list newNonLast,
            }

sortWith : NonEmptyList a, (a, a -> [LT, EQ, GT]) -> NonEmptyList a
sortWith = \nonEmpty, compare ->
    fullList = toList nonEmpty
    sorted = List.sortWith fullList compare

    nonLast = List.dropLast sorted 1
    lastItem =
        when List.last sorted is
            Err _ -> crash "unreachable"
            Ok item -> item

    @NonEmptyList { list: nonLast, last: lastItem }
