module [
    NonEmptyRingBuffer,
    capacity,
    contents,
    new,
    get,
    first,
    last,
    push,
    dropOldestWhile,
    findLatest,
]

NonEmptyRingBuffer a := Buffer a

Buffer a : {
    ## the backing list
    ## its contents are read from oldest to latest, wrapping around
    list : List (Result a [EmptySlot]),

    ## the first added item
    ## the slot `List.get list oldest` is guaranteed to have the first added item
    oldest : U64,

    ## the last added item
    ## the slot `List.get list latest` is guaranteed to have the last added item
    latest : U64,
}

capacity : U64
capacity = 256

new : a -> NonEmptyRingBuffer a
new = \item ->
    oldest = 0
    latest = 0
    list =
        List.repeat (Err EmptySlot) capacity
        |> List.set latest (Ok item)

    @NonEmptyRingBuffer { oldest, latest, list }

get : NonEmptyRingBuffer a, U64 -> Result a [OutOfBounds]
get = \@NonEmptyRingBuffer buffer, i ->
    offset = (buffer.oldest + i) % capacity
    when List.get buffer.list offset is
        Ok (Ok item) -> Ok item
        Ok (Err EmptySlot) -> Err OutOfBounds
        Err _ -> crash "invalid offset"

## access the first / oldest item, which is guaranteed to be present
first : NonEmptyRingBuffer a -> a
first = \@NonEmptyRingBuffer buffer ->
    when List.get buffer.list buffer.oldest is
        Ok (Ok item) -> item
        _ -> crash "invalid buffer"

## access the last / latest item, which is guaranteed to be present
last : NonEmptyRingBuffer a -> a
last = \@NonEmptyRingBuffer buffer ->
    when List.get buffer.list buffer.latest is
        Ok (Ok item) -> item
        _ -> crash "invalid buffer"

## Add a new item, which will become the last / latest.
## If adding an item would overflow capacity, the same buffer is returned instead.
## Letting a player get 256 frames ahead of their opponent is not advised.
push : NonEmptyRingBuffer a, a -> NonEmptyRingBuffer a
push = \@NonEmptyRingBuffer buffer, item ->
    latest = (buffer.latest + 1) % capacity
    if latest == buffer.oldest then
        @NonEmptyRingBuffer buffer
    else
        list = List.set buffer.list latest (Ok item)
        @NonEmptyRingBuffer { buffer & list, latest }

## Drop the oldest items while they meet the condition.
## Stops dropping when either condition returns false,
## or there is one latest item left in the buffer.
dropOldestWhile : NonEmptyRingBuffer a, (a -> Bool) -> NonEmptyRingBuffer a
dropOldestWhile = \@NonEmptyRingBuffer initialBuffer, shouldDrop ->
    indexes = deletableIndexes initialBuffer

    newBuffer =
        List.walkUntil indexes initialBuffer \buffer, i ->
            when List.get buffer.list i is
                Err OutOfBounds -> crash "invalid buffer"
                Ok (Err EmptySlot) -> crash "invalid buffer"
                Ok (Ok item) ->
                    if shouldDrop item then
                        list = List.set buffer.list i (Err EmptySlot)
                        oldest = (buffer.oldest + 1) % capacity
                        Continue ({ buffer & list, oldest })
                    else
                        Break buffer

    @NonEmptyRingBuffer newBuffer

findLatest : NonEmptyRingBuffer a, (a -> Bool) -> Result a [NotFound]
findLatest = \@NonEmptyRingBuffer buffer, isMatch ->
    findLast = \range ->
        List.walkBackwardsUntil range (Err NotFound) \res, i ->
            when List.get buffer.list i is
                Ok (Ok item) ->
                    if isMatch item then
                        Break (Ok item)
                    else
                        Continue res

                _ -> crash "invalid buffer"

    if buffer.oldest <= buffer.latest then
        range = List.range { start: At buffer.oldest, end: Before buffer.latest }
        findLast range
    else
        firstChunk = List.range { start: At buffer.oldest, end: Before capacity }
        secondChunk = List.range { start: At 0, end: At buffer.latest }
        when findLast firstChunk is
            Ok item -> Ok item
            Err NotFound -> findLast secondChunk

deletableIndexes : Buffer a -> List U64
deletableIndexes = \buffer ->
    if buffer.oldest <= buffer.latest then
        List.range { start: At buffer.oldest, end: Before buffer.latest }
    else
        firstChunk = List.range { start: At buffer.oldest, end: Before capacity }
        secondChunk = List.range { start: At 0, end: Before buffer.latest }
        List.concat firstChunk secondChunk

contents : NonEmptyRingBuffer a -> List a
contents = \@NonEmptyRingBuffer buffer ->
    allButLatest = List.map (deletableIndexes buffer) \i ->
        when List.get buffer.list i is
            Ok (Ok item) -> item
            _ -> crash "invalid buffer"

    latest : a
    latest =
        when List.get buffer.list buffer.latest is
            Ok (Ok item) -> item
            _ -> crash "invalid buffer"

    List.append allButLatest latest

expect
    justOne = new 1
    result = get justOne 0
    result == Ok 1

expect
    justOne = new 1
    result = get justOne 1
    result == Err OutOfBounds

expect
    justOne = new 1
    firstItem = first justOne
    firstItem == 1

expect
    justOne = new 1
    lastItem = last justOne
    lastItem == 1

expect
    ringBuffer = new 1 |> push 2 |> push 3
    firstItem = first ringBuffer
    firstItem == 1

expect
    ringBuffer = new 1 |> push 2 |> push 3
    lastItem = last ringBuffer
    lastItem == 3

expect
    ringBuffer = new 0
    fullBuffer =
        List.range { start: At 1, end: At (capacity - 1) }
        |> List.walk ringBuffer push

    reallyFullBuffer = push fullBuffer capacity
    actual = contents reallyFullBuffer
    expected = contents fullBuffer

    actual == expected

expect
    ringBuffer = new 0
    almostFullBuffer =
        List.range { start: At 1, end: At (capacity - 2) }
        |> List.walk ringBuffer push

    reallyFullBuffer = push almostFullBuffer (capacity - 1)
    actual = contents reallyFullBuffer
    almostExpected = contents almostFullBuffer

    actual != almostExpected

getInternalBuffer : NonEmptyRingBuffer a -> Buffer a
getInternalBuffer = \@NonEmptyRingBuffer buffer -> buffer

expect
    justOne = getInternalBuffer (new 1)
    deletable = deletableIndexes justOne
    deletable == []

expect
    justOne = new 1 |> push 2 |> push 3 |> getInternalBuffer
    deletable = deletableIndexes justOne
    deletable == [0, 1]

expect
    oldest = capacity - 2
    latest = 1
    list =
        List.repeat (Err EmptySlot) capacity
        |> List.set (capacity - 2) (Ok 1)
        |> List.set (capacity - 1) (Ok 2)
        |> List.set 0 (Ok 3)
        |> List.set 1 (Ok 4)

    buffer : Buffer U64
    buffer = { list, oldest, latest }

    deletable = deletableIndexes buffer
    expected = [capacity - 2, capacity - 1, 0]

    deletable == expected

expect
    ringBuffer = new 1 |> push 2 |> push 3 |> push 4 |> push 5
    freshBuffer = ringBuffer |> dropOldestWhile \n -> n < 3

    actual = contents freshBuffer
    expected = [3, 4, 5]

    actual == expected

expect
    ringBuffer = new 1 |> push 2 |> push 3 |> push 4 |> push 5
    freshBuffer = ringBuffer |> dropOldestWhile \_ -> Bool.true

    actual = contents freshBuffer
    expected = [5]

    actual == expected

expect
    ringBuffer = new 0

    fullBuffer =
        List.range { start: At 1, end: At (capacity - 1) }
        |> List.walk ringBuffer push

    freshBuffer = fullBuffer |> dropOldestWhile \_ -> Bool.true

    actual = contents freshBuffer
    expected = contents (new (capacity - 1))

    actual == expected

expect
    ringBuffer = new 1 |> push 2 |> push 3 |> push 4 |> push 5

    actual = findLatest ringBuffer \n -> n <= 2
    expected = Ok 2

    actual == expected

expect
    ringBuffer = new 1 |> push 2 |> push 3 |> push 4 |> push 5

    actual = findLatest ringBuffer \_ -> Bool.false
    expected = Err NotFound

    actual == expected

expect
    oldest = capacity - 2
    latest = 1
    list =
        List.repeat (Err EmptySlot) capacity
        |> List.set (capacity - 2) (Ok 1)
        |> List.set (capacity - 1) (Ok 2)
        |> List.set 0 (Ok 3)
        |> List.set 1 (Ok 4)

    ringBuffer : NonEmptyRingBuffer U64
    ringBuffer = @NonEmptyRingBuffer { list, oldest, latest }

    actual = findLatest ringBuffer \n -> n <= 2
    expected = Ok 2

    actual == expected

expect
    oldest = capacity - 2
    latest = 1
    list =
        List.repeat (Err EmptySlot) capacity
        |> List.set (capacity - 2) (Ok 1)
        |> List.set (capacity - 1) (Ok 2)
        |> List.set 0 (Ok 3)
        |> List.set 1 (Ok 4)

    ringBuffer : NonEmptyRingBuffer U64
    ringBuffer = @NonEmptyRingBuffer { list, oldest, latest }

    actual = findLatest ringBuffer \_ -> Bool.false
    expected = Err NotFound

    actual == expected
