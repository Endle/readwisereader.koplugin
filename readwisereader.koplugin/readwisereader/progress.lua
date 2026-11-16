-- Two-way reading position sync with Reader's reading_progress, a fraction from
-- 0 to 1 that Reader apps open a document at. Reader exposes no location inside
-- the text, only this fraction: the share of the document's words that lie
-- before the top of the view. Measured on a 150,000-word EPUB, Reader counts
-- the words of its text run together, with no space where one paragraph ends
-- and the next begins, so the last word of one and the first of the next are
-- a single word; counted any other way its number is some 200 words off.
-- KOReader's own percentage is page / pages, which runs well ahead wherever
-- pages hold few words: covers, images, chapter breaks. So positions are
-- converted through a map of the words before each page, and compared as pages
-- of this device.
--
-- This module is the decision logic only and uses no KOReader modules.
local Progress = {
    -- Seconds after the last page turn before the position is synced.
    PUSH_DELAY = 10,
    -- Seconds without a sync after which the next page turn syncs at once: the
    -- book may have been read in Reader while this device slept, and not every
    -- device tells KOReader that it woke up.
    IDLE_AFTER = 300,
    -- Seconds between looks at Reader while a book lies open and no page is
    -- turned: the book may be read in Reader meanwhile, on a phone next to this
    -- device.
    WATCH_EVERY = 30,
    -- Where KOReader is not told that the device slept, the clock is looked at
    -- every TICK seconds; one that ran more than SLEPT seconds ahead of that
    -- means the device was asleep.
    TICK = 5,
    SLEPT = 20,
    -- Seconds automatic sync stays quiet after a failed request: RETRY_FIRST
    -- after the first, twice as long after each further one, RETRY_AFTER at most.
    RETRY_FIRST = 10,
    RETRY_AFTER = 300,
    -- Reader treats 1 as finished and sync stops listing finished documents, which
    -- removes them from the device. A document from the sync folder is therefore
    -- never sent as more than this.
    DOWNLOADED_MAX = 0.99,
}

-- A usable fraction, or nil.
function Progress.fraction(value)
    if type(value) ~= "number" or value ~= value then
        return nil
    end
    return math.max(0, math.min(1, value))
end

-- Words as Reader counts a position: runs of anything but whitespace, in text
-- whose paragraphs follow each other without a break. KOReader hands text over
-- with a line break between paragraphs.
function Progress.words(text)
    if type(text) ~= "string" then
        return 0
    end
    local joined = text:gsub("[\r\n]+", "")
    local _, count = joined:gsub("%S+", "")
    return count
end

-- A map of the book: `before[page]` is the number of words before the top of
-- that page. Without one, or for a book with no text, every page weighs the
-- same, which is all there is to go by for a PDF. The last page, whose end
-- nothing marks, counts as an average page.
function Progress.map(pages, before)
    local total = before and before[pages] or 0
    if total <= 0 or pages < 2 then
        before = {}
        for page = 1, pages do
            before[page] = page - 1
        end
        return { pages = pages, before = before, total = pages }
    end
    return { pages = pages, before = before, total = total + total / (pages - 1) }
end

-- Reader's fraction for the top of a page. The last page stands for the whole
-- book: whoever is on it has nothing left to turn to.
function Progress.fractionAt(map, page)
    if page >= map.pages then
        return 1
    end
    return map.before[math.max(1, page)] / map.total
end

-- The page a fraction falls on: the last one that starts at or before it. Half
-- a word of slack keeps a fraction made by fractionAt on its own page.
function Progress.pageAt(map, fraction)
    local target = fraction * map.total + 0.5
    local low, high = 1, map.pages
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if map.before[middle] <= target then
            low = middle
        else
            high = middle - 1
        end
    end
    return low
end

-- The state of the last sync, { here =, there = } as fractions, in pages of
-- this device as it is paginated now. nil when there is none to go by.
function Progress.pages(map, state)
    if type(state) ~= "table" or not Progress.fraction(state.here) or not Progress.fraction(state.there) then
        return nil
    end
    return { here = Progress.pageAt(map, state.here), there = Progress.pageAt(map, state.there) }
end

-- `step` is the size of one page in the unit positions are given in: 1 when
-- they are pages. Positions closer than half a page are the same page.
local function apart(a, b, step)
    return math.abs(a - b) >= step / 2
end

-- `state` is { here =, there = }: both positions as the last sync left them.
local function known(state)
    return type(state) == "table" and type(state.here) == "number" and type(state.there) == "number"
end

-- Whether this device has moved since the last sync.
function Progress.moved(state, here, step)
    return not known(state) or apart(here, state.here, step)
end

-- What to do with this device at `here` and Reader at `there`:
--   "pull"  move this device to Reader's position
--   "push"  send this device's position to Reader
--   nil     nothing
-- Reader is followed forwards only. A Reader app that had the book open keeps
-- the place it remembered and writes it over a newer one sent from here (seen
-- 24 seconds after a send), so a Reader that has fallen behind is put right
-- instead of followed. This device is followed both ways: going back here is
-- always the reader's own doing. With no sync yet, the furthest position wins.
-- `watching` is a look at Reader while the book lies open: one that is behind
-- may be an app showing the book right now, which would only write its place
-- again, so it is left for the next page turn or opening to put right.
function Progress.decide(state, here, there, step, watching)
    if not apart(here, there, step) then
        return nil
    end
    local here_moved = not known(state) or apart(here, state.here, step)
    local there_moved = not known(state) or apart(there, state.there, step)
    if there > here then
        if there_moved then
            return "pull"
        end
        -- Reader is where it was: this device went back.
        return here_moved and "push" or nil
    end
    return (here_moved or there_moved and not watching) and "push" or nil
end

-- Seconds to stay quiet after `failures` failed requests in a row.
function Progress.retryDelay(failures)
    return math.min(Progress.RETRY_AFTER, Progress.RETRY_FIRST * 2 ^ math.max(0, failures - 1))
end

-- The value to send for a position on this device.
function Progress.sendable(here, downloaded)
    return downloaded and math.min(here, Progress.DOWNLOADED_MAX) or here
end

-- The outcome of a sync as text, to cross from the subprocess that made the
-- requests: { action =, there =, was = } or { failed = }.
function Progress.encode(result)
    if result.failed then
        return "failed\n" .. tostring(result.failed)
    end
    return string.format("%s\n%.17g\n%.17g", result.action or "none", result.there, result.was or result.there)
end

-- A subprocess that died leaves no text, which is a failure too.
function Progress.decode(text)
    local lines = {}
    for line in (type(text) == "string" and text or ""):gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local there = tonumber(lines[2])
    if lines[1] == "failed" or not there then
        return { failed = lines[1] == "failed" and lines[2] or "getting an answer" }
    end
    return { action = lines[1] ~= "none" and lines[1] or nil, there = there, was = tonumber(lines[3]) }
end

function Progress.percent(fraction)
    return string.format("%d%%", math.floor(fraction * 100 + 0.5))
end

return Progress
