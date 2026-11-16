-- Run from the repo root: luajit tests/progress_test.lua
package.path = "readwisereader.koplugin/?.lua;" .. package.path
local Progress = require("readwisereader/progress")

local function eq(actual, expected)
    assert(actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

-- A 400-page book: one page is 0.0025.
local STEP = 1 / 400
local function at(page) return page / 400 end

-- fraction: Reader's value is used only when it is a number
eq(Progress.fraction(0.25), 0.25)
eq(Progress.fraction(-1), 0)
eq(Progress.fraction(7), 1)
eq(Progress.fraction(nil), nil)
eq(Progress.fraction("0.5"), nil)
eq(Progress.fraction(0 / 0), nil)

-- First sync: the furthest position wins
eq(Progress.decide(nil, at(40), at(120), STEP), "pull")
eq(Progress.decide(nil, at(120), at(40), STEP), "push")
eq(Progress.decide(nil, at(120), at(120), STEP), nil)
-- A malformed state is no state
eq(Progress.decide({ here = "x" }, at(40), at(120), STEP), "pull")

-- Only Reader moved: forwards it is followed; backwards it is put right, since
-- its apps can write an older place they remembered over a newer one
local state = { here = at(100), there = at(100) }
eq(Progress.decide(state, at(100), at(180), STEP), "pull")
eq(Progress.decide(state, at(100), at(60), STEP), "push")

-- Only this device moved: send it, forwards and backwards
eq(Progress.decide(state, at(130), at(100), STEP), "push")
eq(Progress.decide(state, at(70), at(100), STEP), "push")

-- Both moved: the furthest wins
eq(Progress.decide(state, at(130), at(180), STEP), "pull")
eq(Progress.decide(state, at(180), at(130), STEP), "push")
eq(Progress.decide(state, at(50), at(60), STEP), "pull")
eq(Progress.decide(state, at(60), at(50), STEP), "push")
-- ...and both arriving at the same page is no conflict
eq(Progress.decide(state, at(150), at(150), STEP), nil)

-- Nothing moved
eq(Progress.decide(state, at(100), at(100), STEP), nil)

-- A look at Reader while the book lies open follows it forwards and sends this
-- device's own moves, but leaves a Reader that is behind alone
eq(Progress.decide(state, at(100), at(180), STEP, true), "pull")
eq(Progress.decide(state, at(130), at(100), STEP, true), "push")
eq(Progress.decide(state, at(130), at(60), STEP, true), "push")
eq(Progress.decide(state, at(100), at(60), STEP, true), nil)

-- retryDelay: short after the first failure, longer with each one
eq(Progress.retryDelay(1), 10)
eq(Progress.retryDelay(2), 20)
eq(Progress.retryDelay(5), 160)
eq(Progress.retryDelay(6), Progress.RETRY_AFTER)
eq(Progress.retryDelay(60), Progress.RETRY_AFTER)

-- Reader's fraction rarely lands exactly on a page: within half a page is the same page
eq(Progress.decide(state, at(100), at(100) + STEP * 0.4, STEP), nil)
eq(Progress.decide(state, at(100), at(100) + STEP * 0.6, STEP), "pull")
-- After a pull this device sits on the nearest page, which is not a move of its own
local pulled = { here = at(180), there = at(180) + STEP * 0.3 }
eq(Progress.moved(pulled, at(180), STEP), false)
eq(Progress.decide(pulled, at(180), at(180) + STEP * 0.3, STEP), nil)

-- A capped send leaves the two sides apart without either having moved
local capped = { here = 1, there = Progress.DOWNLOADED_MAX }
eq(Progress.decide(capped, 1, Progress.DOWNLOADED_MAX, 1 / 50), nil)

-- moved: skips the network when pages were not turned
eq(Progress.moved(nil, at(100), STEP), true)
eq(Progress.moved(state, at(100), STEP), false)
eq(Progress.moved(state, at(101), STEP), true)

-- sendable: only documents from the sync folder are capped
eq(Progress.sendable(1, true), Progress.DOWNLOADED_MAX)
eq(Progress.sendable(0.5, true), 0.5)
eq(Progress.sendable(1, false), 1)

-- words: what Reader measures a position in
eq(Progress.words("one two three\tfour  "), 4)
-- Reader runs paragraphs together: the words on either side of a break are one
eq(Progress.words("He said so.\n“Why?” she asked.\n\nNo answer."), 6)
eq(Progress.words("ends with a space \nand goes on"), 7)
eq(Progress.words(""), 0)
eq(Progress.words(nil), 0)

-- A book whose first pages hold few words (cover, title, contents), as real
-- ones do: ten pages, 100 words on each from the fourth on.
local book = Progress.map(10, { 0, 0, 5, 10, 110, 210, 310, 410, 510, 610 })
-- the last page, whose end nothing marks, counts as an average page
eq(book.total, 610 + 610 / 9)
-- page 5 of 10 is not "half": only 110 of some 680 words lie before it
eq(Progress.percent(Progress.fractionAt(book, 5)), "16%")
eq(Progress.fractionAt(book, 1), 0)
-- the last page stands for the whole book
eq(Progress.fractionAt(book, 9) < 1, true)
eq(Progress.fractionAt(book, 10), 1)
eq(Progress.fractionAt(book, 99), 1)
-- a fraction falls on the page whose words hold it
eq(Progress.pageAt(book, 0), 2)
eq(Progress.pageAt(book, 0.5), 7)
eq(Progress.pageAt(book, 1), 10)
eq(Progress.pageAt(book, 159 / book.total), 5)
eq(Progress.pageAt(book, 210 / book.total), 6)
-- and the top of every page maps back to that page, apart from empty ones
for page = 3, 10 do
    eq(Progress.pageAt(book, Progress.fractionAt(book, page)), page)
end
local long = { 0 }
for page = 2, 1151 do long[page] = long[page - 1] + 100 + page % 7 end
long = Progress.map(1151, long)
for page = 1, 1151 do
    eq(Progress.pageAt(long, Progress.fractionAt(long, page)), page)
end

-- No text to go by (a PDF, a book of images): every page weighs the same
local flat = Progress.map(400)
eq(Progress.fractionAt(flat, 1), 0)
eq(Progress.fractionAt(flat, 101), 0.25)
eq(Progress.fractionAt(flat, 400), 1)
eq(Progress.pageAt(flat, 0.25), 101)
eq(Progress.pageAt(flat, 1), 400)
eq(Progress.map(3, { 0, 0, 0 }).total, 3)
eq(Progress.map(1, { 0 }).total, 1)

-- The last sync, as pages of the book the way it is laid out now
eq(Progress.pages(flat, { here = 0.25, there = 0.5 }).here, 101)
eq(Progress.pages(flat, { here = 0.25, there = 0.5 }).there, 201)
eq(Progress.pages(flat, nil), nil)
eq(Progress.pages(flat, { here = 0.25 }), nil)
eq(Progress.pages(flat, { here = "x", there = 0.5 }), nil)
-- ...which is what decide compares, one page being 1
eq(Progress.decide(Progress.pages(flat, { here = 0.25, there = 0.25 }), 101, Progress.pageAt(flat, 0.5), 1), "pull")
eq(Progress.decide(Progress.pages(flat, { here = 0.25, there = 0.25 }), 131, Progress.pageAt(flat, 0.25), 1), "push")
eq(Progress.decide(nil, 101, 101, 1), nil)

eq(Progress.percent(0.114), "11%")
eq(Progress.percent(0.995), "100%")
eq(Progress.percent(0), "0%")

-- The outcome of a sync survives the trip from the subprocess
local outcome = Progress.decode(Progress.encode({ action = "push", there = 0.13205907906169, was = 0.11448489567531701 }))
eq(outcome.action, "push")
eq(outcome.there, 0.13205907906169)
eq(outcome.was, 0.11448489567531701)
outcome = Progress.decode(Progress.encode({ there = 0.5 }))
eq(outcome.action, nil)
eq(outcome.there, 0.5)
eq(Progress.decode(Progress.encode({ failed = "sending the position" })).failed, "sending the position")
-- ...and a subprocess that died is a failure
eq(Progress.decode("").failed, "getting an answer")
eq(Progress.decode(nil).failed, "getting an answer")
eq(Progress.decode("push\nnot a number").failed, "getting an answer")

print("ok - rules: follow the side that moved, furthest wins a conflict")

-- -----------------------------------------------------------------------------
-- The plugin's side: KOReader and HTTP are stubbed, the plugin methods are real.
-- -----------------------------------------------------------------------------
local function noop() end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local object = {}
function object:extend(value) return setmetatable(value or {}, { __index = self }) end
function object:new(value) return self:extend(value) end

-- Fixture codec, as in highlights_test: payloads cross the HTTP boundary intact.
local encoded = {}
local json = { util = { null = function() end } }
function json.encode(value)
    encoded[#encoded + 1] = copy(value)
    return "json:" .. #encoded
end
function json.decode(token)
    return copy(assert(encoded[tonumber(token:match("^json:(%d+)$"))], "invalid JSON fixture"))
end

local stored, http_calls, replies, shown, scheduled, connected, clock, children, answered, killed
local settings = {}
function settings:readSetting(key) return copy(stored[key]) end
function settings:saveSetting(key, value) stored[key] = copy(value) end
function settings:flush() end

local real_time = os.time
os.time = function() return clock end -- luacheck: ignore

local modules = {
    logger = { dbg = noop, warn = noop, err = noop, info = noop },
    datastorage = { getSettingsDir = function() return "/settings" end },
    dispatcher = { registerAction = noop },
    luasettings = { open = function() return settings end },
    clip = object,
    device = { isKindle = function() return false end, canSuspend = function() return false end },
    util = { splitFilePathName = function(path) return path:match("^(.-)([^/]+)$") end },
    gettext = function(text) return text end,
    json = json,
    rapidjson = { encode = json.encode, decode = json.decode, null = function() end },
    socketutil = { set_timeout = noop, reset_timeout = noop },
    socket = { skip = function(n, ...) return select(n + 1, ...) end, sleep = noop },
    ltn12 = {
        source = { string = function(body)
            return function()
                local chunk = body
                body = nil
                return chunk
            end
        end },
        sink = { table = function(sink)
            return function(chunk)
                if chunk then sink[#sink + 1] = chunk end
                return 1
            end
        end },
    },
    ["socket.http"] = { request = function(request)
        local body = request.source and request.source()
        http_calls[#http_calls + 1] = { url = request.url, method = request.method, body = body and json.decode(body) }
        local reply = assert(table.remove(replies, 1), "unexpected HTTP request")
        if reply.network_error then return nil, reply.network_error end
        request.sink(reply.body and json.encode(reply.body) or "")
        return 1, reply.code, {}, "HTTP " .. reply.code
    end },
    -- A subprocess runs to its end at once; its answer waits in the pipe until
    -- `answered` lets the plugin see that it is done.
    ["ffi/util"] = {
        runInSubProcess = function(run, with_pipe, double_fork)
            local pipe = with_pipe and {} or nil
            children[#children + 1] = { detached = double_fork == true, pipe = pipe }
            run(#children, pipe)
            return #children, pipe
        end,
        writeToFD = function(pipe, data) pipe.data = data end,
        readAllFromFD = function(pipe) return pipe.data or "" end,
        isSubProcessDone = function(pid) return answered or killed[pid] == true end,
        terminateSubProcess = function(pid)
            killed[pid] = true
            children[pid].pipe.data = nil
        end,
    },
    ["ui/widget/container/widgetcontainer"] = object,
    ["ui/widget/infomessage"] = object,
    ["ui/widget/notification"] = object,
    ["ui/event"] = { new = function(_, name, value) return { name = name, value = value } end },
    ["ui/network/manager"] = {
        isConnected = function() return connected end,
        runWhenOnline = function(_, callback) callback() end,
    },
    ["libs/libkoreader-lfs"] = { attributes = function() return "directory" end },
    ["ui/uimanager"] = {
        show = function(_, widget) shown[#shown + 1] = widget.text end,
        close = noop,
        scheduleIn = function(_, delay, task) scheduled[task] = delay end,
        unschedule = function(_, task) scheduled[task] = nil end,
    },
}
for _, name in ipairs{
    "ui/bidi", "docsettings", "apps/filemanager/filemanager", "ui/widget/inputdialog",
    "ui/widget/confirmbox", "ui/widget/multiconfirmbox", "readcollection", "readhistory",
    "apps/filemanager/filemanagerutil", "mime", "ui/renderimage",
} do modules[name] = {} end
for name, module in pairs(modules) do
    package.preload[name] = function() return module end
end
local Reader = dofile("readwisereader.koplugin/main.lua")

local BOOK = "/reader/[rw-id_doc-1] Book.html"
local API = "https://readwise.io/api/v3"

-- A 400-page book open at `page`, with ten words on every page: an EPUB, or
-- with `paging` a PDF, whose text is not read.
local texts
local function open(file, page, options)
    options = options or {}
    local ui = {
        menu = { registerToMainMenu = noop },
        document = {
            file = file,
            getPageCount = function() return options.pages or 400 end,
            getPageXPointer = function(_, number) return "page " .. number end,
            getTextFromXPointers = function(_, from, to)
                assert(not options.paging, "a PDF has no text to read")
                texts = texts + 1
                return string.rep("word ", 10 * (tonumber(to:match("%d+")) - tonumber(from:match("%d+"))))
            end,
        },
        page = page, events = {}, back = {}, sidecar = options.sidecar or {}, flushed = 0,
    }
    function ui:getCurrentPage() return self.page end
    ui[options.paging and "paging" or "rolling"] = {}
    ui.link = { addCurrentLocationToStack = function() ui.back[#ui.back + 1] = ui.page end }
    ui.doc_settings = {
        readSetting = function(_, key) return copy(ui.sidecar[key]) end,
        saveSetting = function(_, key, value) ui.sidecar[key] = copy(value) end,
        flush = function() ui.flushed = ui.flushed + 1 end,
    }
    function ui:handleEvent(event)
        self.events[#self.events + 1] = event
        if event.name == "GotoPage" then self.page = event.value end
        if event.name == "GotoXPointer" then self.page = tonumber(event.value:match("%d+")) end
    end
    local reader = Reader:new{ ui = ui, showProgress = noop, hideProgress = noop }
    reader:init()
    reader:onReaderReady()
    return reader, ui
end

-- The wait before a sync, or nil when none is waiting.
local function waiting(reader) return scheduled[reader.progress_task] end
-- Lets the waiting sync start, and its answer arrive.
local function sync(reader)
    if waiting(reader) then
        scheduled[reader.progress_task] = nil
        reader.progress_task()
    end
    if scheduled[reader.progress_poll] then
        scheduled[reader.progress_poll] = nil
        reader.progress_poll()
    end
end

-- The look at the clock that runs every few seconds while a book is open.
local function tick(reader)
    reader.progress_tick()
    sync(reader)
end
-- Time going by with the device awake.
local function pass(reader, seconds)
    for _ = 1, seconds / Progress.TICK do
        clock = clock + Progress.TICK
        tick(reader)
    end
end

local function reply(progress)
    return { code = 200, body = { results = {{ id = "doc-1", reading_progress = progress }} } }
end
local SENT = { code = 200, body = { id = "doc-1" } }
local function state(ui) return ui.sidecar.readwise_reader_progress end
-- Reader's fraction for the top of a page of that book.
local function top(page) return (page - 1) / 400 end
-- The sidecar of a book last synced with both sides at the top of `page`.
local function synced(page)
    return { readwise_reader_progress = { id = "doc-1", here = top(page), there = top(page) } }
end

local function test(name, run)
    stored = { readwisereader = {
        access_token = "test-token", directory = "/reader/",
    } }
    http_calls, replies, shown, scheduled, children, killed = {}, {}, {}, {}, {}, {}
    connected, answered, clock, texts = true, true, 1000000, 0
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err)) end
    eq(#replies, 0)
    print("ok - " .. name)
end

test("opening a book read further in Reader moves it there and remembers both sides", function()
    local reader, ui = open(BOOK, 40)
    eq(waiting(reader), 1)
    -- Reader's view starts a few lines into page 121
    replies = { reply(top(121) + 0.001) }
    sync(reader)
    eq(#http_calls, 1)
    eq(http_calls[1].method, "GET")
    eq(http_calls[1].url, API .. "/list/?id=doc-1")
    eq(ui.events[1].name, "GotoXPointer")
    eq(ui.page, 121)
    eq(ui.back[1], 40)
    eq(shown[1], "Reader position: 30% (was 10%)")
    eq(state(ui).id, "doc-1")
    eq(state(ui).here, top(121))
    eq(state(ui).there, top(121) + 0.001)
    -- Sitting on the page Reader pointed at is not a move of this device.
    reader:onPageUpdate()
    sync(reader)
    eq(#http_calls, 1)
end)

test("opening a book read further here sends the position to Reader", function()
    local reader, ui = open(BOOK, 121)
    replies = { reply(0.1), SENT }
    sync(reader)
    eq(#http_calls, 2)
    eq(http_calls[2].method, "PATCH")
    eq(http_calls[2].url, API .. "/update/doc-1/")
    eq(http_calls[2].body.reading_progress, 0.3)
    eq(#ui.events, 0)
    eq(#shown, 0)
    eq(state(ui).here, 0.3)
    eq(state(ui).there, 0.3)
end)

test("a position is the share of words before the page, not of pages", function()
    -- ten words a page, and the book is at the top of page 121 of 400: 30%
    local reader = open(BOOK, 121)
    replies = { reply(0), SENT }
    sync(reader)
    eq(http_calls[2].body.reading_progress, 1200 / 4000)
    -- the words are read once per layout, not at every sync
    eq(texts, 399)
    reader:onPageUpdate()
    sync(reader)
    eq(texts, 399)
    reader:onDocumentRerendered()
    reader.ui.page = 122
    reader:onPageUpdate()
    replies = { reply(0.3), SENT }
    sync(reader)
    eq(texts, 798)
end)

test("the last sync is read as pages of the book as it is laid out now", function()
    -- synced at 25% in a 400-page layout; a larger font makes it 800 pages,
    -- and the same place is now page 201
    local reader, ui = open(BOOK, 201, { sidecar = synced(101), pages = 800 })
    replies = { reply(top(101)) }
    sync(reader)
    eq(#http_calls, 1)
    eq(#ui.events, 0)
    -- two pages on: sent as its share of the words, 202 pages of 800
    ui.page = 203
    reader:onPageUpdate()
    replies = { reply(top(101)), SENT }
    sync(reader)
    eq(http_calls[3].body.reading_progress, 2020 / 8000)
end)

test("the requests run in a subprocess, and reading goes on until the answer is in", function()
    local reader, ui = open(BOOK, 121)
    answered = false
    replies = { reply(0.1), SENT }
    sync(reader)
    eq(#children, 1)
    eq(children[1].detached, false)
    eq(state(ui), nil)
    -- still no answer: look again shortly, and start nothing else meanwhile
    sync(reader)
    eq(scheduled[reader.progress_poll], 0.5)
    ui.page = 122
    reader:onPageUpdate()
    scheduled[reader.progress_task] = nil
    reader.progress_task()
    eq(#children, 1)
    eq(waiting(reader), 2)
    -- the answer is for page 121; the page turned meanwhile is sent next
    answered = true
    replies = { reply(0.3), SENT }
    scheduled[reader.progress_poll] = nil
    reader.progress_poll()
    eq(state(ui).here, top(121))
    sync(reader)
    eq(#children, 2)
    eq(http_calls[4].body.reading_progress, top(122))
    eq(state(ui).here, top(122))
end)

test("pages turned while Reader answers keep the book where the reader is", function()
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    answered = false
    replies = { reply(top(241)) }
    sync(reader)
    ui.page = 104
    reader:onPageUpdate()
    answered = true
    scheduled[reader.progress_poll] = nil
    reader.progress_poll()
    eq(ui.page, 104)
    eq(#shown, 0)
    eq(state(ui).here, top(101))
    -- the sync those turns started decides: both sides moved, Reader is further
    replies = { reply(top(241)) }
    sync(reader)
    eq(ui.page, 241)
end)

test("an answer that never comes is given up", function()
    local reader, ui = open(BOOK, 121)
    answered = false
    replies = { reply(0.1), SENT }
    sync(reader)
    clock = clock + 61
    sync(reader)
    eq(killed[1], true)
    sync(reader)
    eq(reader.progress_job, nil)
    eq(state(ui), nil)
    eq(reader.progress_retry_at ~= nil, true)
end)

test("a page turn is sent after a pause, and only when the page changed", function()
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    replies = { reply(top(101)) }
    sync(reader)
    eq(#http_calls, 1)
    -- still reading: the wait restarts with each turn
    ui.page = 102
    reader:onPageUpdate()
    eq(waiting(reader), Progress.PUSH_DELAY)
    ui.page = 103
    reader:onPageUpdate()
    replies = { reply(top(101)), SENT }
    sync(reader)
    eq(#http_calls, 3)
    eq(http_calls[3].body.reading_progress, top(103))
    eq(state(ui).here, top(103))
    eq(state(ui).there, top(103))
    -- turned away and back: nothing to send
    reader:onPageUpdate()
    sync(reader)
    eq(#http_calls, 3)
end)

test("the first page turn after a long pause syncs at once and follows Reader if it is ahead", function()
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    replies = { reply(top(101)) }
    sync(reader)
    -- the device slept with the book open, and the book was read in Reader
    clock = clock + 3600
    ui.page = 102
    reader:onPageUpdate()
    eq(waiting(reader), 1)
    replies = { reply(top(201)) }
    sync(reader)
    eq(#http_calls, 2)
    eq(ui.page, 201)
    eq(shown[1], "Reader position: 50% (was 25%)")
end)

test("reading in Reader between two page turns here is not overwritten", function()
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    replies = { reply(top(101)) }
    sync(reader)
    ui.page = 102
    reader:onPageUpdate()
    replies = { reply(top(101)), SENT }
    sync(reader)
    -- a minute in Reader on the phone, then back here
    clock = clock + 60
    ui.page = 103
    reader:onPageUpdate()
    replies = { reply(top(121)) }
    sync(reader)
    eq(#http_calls, 4)
    eq(ui.page, 121)
end)

test("going back here is sent; a Reader that fell behind is put right, not followed", function()
    -- a Reader app wrote the older place it remembered over the one sent from here
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    replies = { reply(top(61)), SENT }
    sync(reader)
    eq(#ui.events, 0)
    eq(#shown, 0)
    eq(http_calls[2].body.reading_progress, top(101))
    eq(state(ui).there, top(101))
    -- going back on this device is the reader's own doing
    ui.page = 31
    reader:onPageUpdate()
    replies = { reply(top(101)), SENT }
    sync(reader)
    eq(#ui.events, 0)
    eq(http_calls[4].body.reading_progress, top(31))
end)

test("a conflict is won by the furthest position", function()
    local reader, ui = open(BOOK, 161, { sidecar = synced(101) })
    replies = { reply(top(121)), SENT }
    sync(reader)
    eq(http_calls[2].body.reading_progress, top(161))
    eq(#ui.events, 0)

    http_calls = {}
    reader, ui = open(BOOK, 121, { sidecar = synced(101) })
    replies = { reply(top(161)) }
    sync(reader)
    eq(#http_calls, 1)
    eq(ui.page, 161)
end)

test("closing sends the last pages without waiting, and never overwrites a Reader that is ahead", function()
    local reader, ui = open(BOOK, 105, { sidecar = synced(101) })
    scheduled = {}
    replies = { reply(top(101)), SENT }
    reader:onCloseDocument()
    eq(children[1].detached, true)
    eq(http_calls[2].body.reading_progress, top(105))
    eq(waiting(reader), nil)
    -- nobody waited for the answer: the next opening finds both sides agreeing
    eq(state(ui).here, top(101))
    reader, ui = open(BOOK, 105, { sidecar = ui.sidecar })
    replies = { reply(top(105)) }
    sync(reader)
    eq(#ui.events, 0)
    eq(state(ui).here, top(105))

    http_calls = {}
    reader, ui = open(BOOK, 105, { sidecar = synced(101) })
    scheduled = {}
    replies = { reply(top(241)) }
    reader:onCloseDocument()
    eq(#http_calls, 1)
    eq(ui.page, 105)
    eq(state(ui).here, top(101))
    -- ...and the next opening follows Reader
    reader, ui = open(BOOK, 105, { sidecar = ui.sidecar })
    replies = { reply(top(241)) }
    sync(reader)
    eq(ui.page, 241)

    -- nothing read since the last sync: no request at all
    http_calls = {}
    reader = open(BOOK, 101, { sidecar = synced(101) })
    scheduled = {}
    reader:onCloseDocument()
    eq(#http_calls, 0)
end)

test("closing while Reader answers takes an answer that is in and gives up one that is not", function()
    local reader, ui = open(BOOK, 121)
    answered = false
    replies = { reply(0.1), SENT }
    sync(reader)
    answered = true
    reader:onCloseDocument()
    eq(state(ui).here, 0.3)
    eq(ui.flushed, 1)
    eq(#children, 1)
    eq(scheduled[reader.progress_poll], nil)

    -- an answer that would move the book is not followed while closing
    reader, ui = open(BOOK, 41)
    answered = false
    replies = { reply(0.6) }
    sync(reader)
    answered = true
    replies = { reply(0.6) }
    reader:onCloseDocument()
    eq(ui.page, 41)
    eq(state(ui), nil)

    -- no answer yet: the subprocess is ended and the closing one decides afresh
    children, killed, http_calls = {}, {}, {}
    reader, ui = open(BOOK, 121)
    answered = false
    replies = { reply(0.1), SENT }
    sync(reader)
    replies = { reply(0.3) }
    reader:onCloseDocument()
    eq(killed[1], true)
    eq(children[2].detached, true)
    eq(reader.progress_job, nil)
    eq(ui.flushed, 0)
end)

test("a document from the sync folder is never sent as finished", function()
    -- on its last page
    local reader, ui = open("/reader/[rw-id_doc-1] Article.html", 400)
    replies = { reply(0.5), SENT }
    sync(reader)
    eq(http_calls[2].body.reading_progress, Progress.DOWNLOADED_MAX)
    eq(state(ui).here, 1)
    eq(state(ui).there, Progress.DOWNLOADED_MAX)
    -- which leaves the two sides apart without anything left to do
    reader:onPageUpdate()
    sync(reader)
    reader, ui = open("/reader/[rw-id_doc-1] Article.html", 400, { sidecar = ui.sidecar })
    replies = { reply(Progress.DOWNLOADED_MAX) }
    sync(reader)
    eq(#http_calls, 3)
    eq(#ui.events, 0)
end)

test("a PDF goes by pages, follows Reader when opened and sends nothing", function()
    -- its category, as the last sync recorded it
    stored.readwisereader.document_tags = { ["doc-1"] = { "pdf" } }
    local reader, ui = open("/reader/[rw-id_doc-1] Paper.pdf", 41, { paging = true })
    replies = { reply(top(121)) }
    sync(reader)
    eq(ui.events[1].name, "GotoPage")
    eq(ui.page, 121)
    ui.page = 131
    reader:onPageUpdate()
    sync(reader)
    reader:onCloseDocument()
    eq(#http_calls, 1)
    -- opened again further on than Reader: nothing to send, nothing lost
    reader, ui = open("/reader/[rw-id_doc-1] Paper.pdf", 131, { paging = true, sidecar = ui.sidecar })
    replies = { reply(top(121)) }
    sync(reader)
    eq(#http_calls, 2)
    eq(ui.page, 131)
    eq(state(ui).here, top(121))
    replies = { reply(top(121)) }
    reader:onSyncReadwiseReadingPosition()
    eq(shown[2], "Reader does not accept reading positions for PDFs yet.")
end)

test("a book whose text cannot be read goes by pages", function()
    local reader, ui = open(BOOK, 121)
    ui.document.getTextFromXPointers = function() error("no text") end
    replies = { reply(0.1), SENT }
    sync(reader)
    eq(http_calls[2].body.reading_progress, top(121))
end)

test("automatic sync stays quiet offline and after a failure; manual sync waits and reports", function()
    local reader, ui = open(BOOK, 121)
    connected = false
    sync(reader)
    eq(#http_calls, 0)

    connected = true
    replies = { { network_error = "timeout" } }
    reader:onResume()
    sync(reader)
    eq(#http_calls, 1)
    ui.page = 122
    reader:onPageUpdate()
    sync(reader)
    eq(#http_calls, 1)
    eq(#shown, 0)
    eq(state(ui), nil)

    replies = { { code = 500 }, { code = 500 }, { code = 500 } }
    reader:onSyncReadwiseReadingPosition()
    eq(shown[1], "Could not reach Reader to sync the reading position.")
    eq(#children, 1)

    -- the pause ends on its own, or when the network comes back
    clock = clock + Progress.RETRY_AFTER + 1
    replies = { { network_error = "timeout" } }
    reader:onPageUpdate()
    sync(reader)
    reader:onNetworkConnected()
    replies = { reply(0.1), SENT }
    sync(reader)
    eq(state(ui).here, top(122))

    shown = {}
    ui.page = 141
    replies = { reply(top(122)), SENT }
    reader:onSyncReadwiseReadingPosition()
    eq(shown[1], "Sent 35% to Reader.")
    replies = { reply(0.35) }
    reader:onSyncReadwiseReadingPosition()
    eq(shown[2], "Already in sync at 35%.")
    replies = { reply(0.5) }
    reader:onSyncReadwiseReadingPosition()
    eq(ui.page, 201)
    eq(shown[3], "Reader position: 50% (was 35%)")
end)

test("a book left open follows Reader without a page being turned", function()
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    eq(scheduled[reader.progress_tick], Progress.TICK)
    replies = { reply(top(101)) }
    sync(reader)
    -- Reader was asked a moment ago
    pass(reader, Progress.WATCH_EVERY - Progress.TICK)
    eq(#http_calls, 1)
    eq(scheduled[reader.progress_tick], Progress.TICK)
    -- half a minute after that, the book has been read on the phone
    replies = { reply(top(104)) }
    pass(reader, Progress.TICK)
    eq(#http_calls, 2)
    eq(ui.page, 104)
    eq(shown[1], "Reader position: 26% (was 25%)")
    eq(state(ui).here, top(104))
    -- and not asked again before the next half minute is over
    pass(reader, Progress.WATCH_EVERY - Progress.TICK)
    eq(#http_calls, 2)
    -- a closed book is not watched
    scheduled = {}
    reader:onCloseDocument()
    eq(scheduled[reader.progress_tick], nil)
    pass(reader, Progress.WATCH_EVERY)
    eq(#http_calls, 2)
end)

test("a Reader that is behind is left alone while the book lies open, and put right at the next page turn", function()
    -- the Reader app shows the book at an earlier place and keeps writing it
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    replies = { reply(top(101)) }
    sync(reader)
    replies = { reply(top(61)), reply(top(61)) }
    pass(reader, 2 * Progress.WATCH_EVERY)
    eq(#http_calls, 3)
    eq(#ui.events, 0)
    eq(state(ui).there, top(101))
    ui.page = 102
    reader:onPageUpdate()
    replies = { reply(top(61)), SENT }
    sync(reader)
    eq(http_calls[5].body.reading_progress, top(102))
    -- a page turn waiting to be sent is left to its own sync
    ui.page = 103
    reader:onPageUpdate()
    for _ = 1, Progress.WATCH_EVERY / Progress.TICK do
        clock = clock + Progress.TICK
        reader.progress_tick()
    end
    eq(#http_calls, 5)
    eq(waiting(reader), Progress.PUSH_DELAY)
end)

test("a device that slept asks Reader as soon as it wakes, and soon again if the network is not back yet", function()
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    replies = { reply(top(101)) }
    sync(reader)
    -- asleep for an hour with the book open; KOReader is told nothing
    clock = clock + 3600
    connected = false
    tick(reader)
    eq(#http_calls, 1)
    -- Wi-Fi is back, the VPN is not
    connected = true
    replies = { { network_error = "closed" } }
    pass(reader, Progress.TICK)
    eq(#http_calls, 2)
    pass(reader, Progress.TICK)
    eq(#http_calls, 2)
    replies = { reply(top(141)) }
    pass(reader, Progress.TICK)
    eq(#http_calls, 3)
    eq(ui.page, 141)
    -- nothing is owed any more: the next look is half a minute away
    pass(reader, Progress.WATCH_EVERY - Progress.TICK)
    eq(#http_calls, 3)
end)

test("a sync that could not run when the book opened runs once the network is there", function()
    connected = false
    local reader, ui = open(BOOK, 101, { sidecar = synced(101) })
    sync(reader)
    pass(reader, 2 * Progress.TICK)
    eq(#http_calls, 0)
    connected = true
    -- a Reader that fell behind while this device was away is put right
    replies = { reply(top(61)), SENT }
    pass(reader, Progress.TICK)
    eq(http_calls[2].body.reading_progress, top(101))
    eq(#ui.events, 0)
end)

test("failed requests are tried again after 10 seconds, then less and less often", function()
    local reader = open(BOOK, 101, { sidecar = synced(101) })
    local function failures_after(seconds)
        local before = #http_calls
        for _ = 1, seconds / Progress.TICK do
            replies = { { network_error = "closed" } }
            pass(reader, Progress.TICK)
            replies = {}
        end
        return #http_calls - before
    end
    replies = { { network_error = "closed" } }
    sync(reader)
    eq(failures_after(10), 1)
    eq(failures_after(20), 1)
    eq(failures_after(40), 1)
    eq(failures_after(80 + 160), 2)
    eq(failures_after(300), 1)
    eq(failures_after(300), 1)
end)

test("a device that reports sleep and waking is not made to look at the clock", function()
    modules.device.canSuspend = function() return true end
    local reader = open(BOOK, 101, { sidecar = synced(101) })
    modules.device.canSuspend = function() return false end
    eq(scheduled[reader.progress_tick], Progress.WATCH_EVERY)
end)

test("a Reader document that is gone or has no position changes nothing", function()
    local reader, ui = open(BOOK, 121)
    replies = { { code = 200, body = { results = {} } } }
    sync(reader)
    eq(#http_calls, 1)
    eq(#ui.events, 0)
    eq(state(ui), nil)
    eq(reader.progress_retry_at ~= nil, true)
end)

test("other books, and the setting turned off, make no requests", function()
    local reader = open("/books/Other.epub", 121)
    eq(next(scheduled), nil)
    sync(reader)
    reader:onPageUpdate()
    sync(reader)
    reader:onCloseDocument()
    eq(#http_calls, 0)
    eq(#children, 0)
    eq(texts, 0)
    reader:onSyncReadwiseReadingPosition()
    eq(shown[1], "This book was not downloaded from Reader.")

    stored.readwisereader.sync_reading_position = false
    reader = open(BOOK, 121)
    eq(waiting(reader), nil)
    reader:onPageUpdate()
    reader:onCloseDocument()
    eq(waiting(reader), nil)
    eq(#http_calls, 0)
    eq(texts, 0)
end)

os.time = real_time -- luacheck: ignore
print("progress_test: ok")
