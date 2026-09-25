-- Black Shores emblem, centred on a CC: Tweaked monitor.
--
-- The picture is baked in at two sizes and the best one for the monitor is
-- picked automatically, so this works on any monitor (it was built for 8x4):
--   * 52x52 for an 8x4 monitor at text scale 0.5 (a 164x52 terminal)
--   * 26x26 for an 8x4 monitor at text scale 1.0 (an 82x26 terminal)
-- Any other monitor size falls back to the nearest copy, scaled to fit.
--
-- Usage: attach the monitor, then run one of
--   blackshores          draw the emblem once
--   blackshores watch    redraw whenever the monitor is resized
--
-- Image: The Black Shores emblem, Wuthering Waves (wutheringwaves.fandom.com).

local TEXT_SCALE = 0.5 -- 0.5 = smallest text, most pixels. Use 1.0+ for a
                       -- smaller, crisper picture (the 26x26 copy).

-- { width, height, rows }, largest first. One character per pixel, using the
-- same hex codes as the paint program: 0 white, 7 gray, 8 light gray, f black.
local IMAGES = {
    { 52, 52, {
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "fffffffffffffffffff77fffffffffffffffffffffffffffffff",
        "fffffffffffffffffff008ffffffffffffffffffffffffffffff",
        "ffffffff7ff78fffff80008ffffffffffff78fffffffffffffff",
        "fffffff70ff80ffffff70000fffffff780008fffffffffffffff",
        "ffffffff77ff7fffff0880008fff80000000ffffffffffffffff",
        "fffffffffffffffff808f7008f00007800077707ffffffffffff",
        "fffffffff0fffffff08ff00000077f00008ff70fffffffffffff",
        "ffffffff8087fffff00070000007f800007ff07fffffffffffff",
        "fffffffffffffffff00000000007870008fff0ffffffffffffff",
        "fffffffffffffff770000000008000000fff88ffffffffffffff",
        "fffffffffffff7000000000000000000ffff0fffffffffffffff",
        "ffffffffffff8080000000000000008ffff78877ffffffffffff",
        "fffffffffff008f800000000000008fffffff7880fffffffffff",
        "fffffffff8088ff88000000800000008ffffff70877f7fffffff",
        "ffffffff8000078000000080000000007ffff7007007ffffffff",
        "fffffffff000000000000000000088008fff7087008fffffffff",
        "ffffff7fff70000000000000007ff00007f8087008ffffffffff",
        "ffffff78ffff808800000000008ff700087087008fffffffffff",
        "7ff7fff8fffffff0000000000080078000777000ffffffffffff",
        "7f7ffff88fffff800870000000000080008f000fffffffffffff",
        "7f7fffff0fffff008ff0000800000000000700ffffffffffffff",
        "777fffff88ffff000788007f00000000000877ffffffffffffff",
        "f87fffff707ff700880000ffff7888000000f87fffffffffffff",
        "f8fffffff88ff700800007fffffffffffff7f78fffffffffffff",
        "f7fffffff807f70000007fffff788f7777ffff88ffffffffffff",
        "fffffffff780f700000ffffff8008800800008087fffffffffff",
        "ffffffffff08880000ffffff80078008fffff777f7ffffffffff",
        "ffffffffff8888008ffffff800780007fffffffff77fffffffff",
        "fffffffffff07808ffffff800780007fffffff77008fffffffff",
        "fffffffffff0887ffffff000780007fff778800877ffffffffff",
        "ffffff7ffff70fffffff00078000778000887fffffffffffffff",
        "ffffffffffff8f88fff000f80008f887ffffffffffffffffffff",
        "fffff7ffffff7070f7000f00008fffffffffffffffffffffffff",
        "fffff7fffffff0888000f00008fffffff77fffffffffffffffff",
        "ffff7fffff887807800f00008ffffffff8ffffffffffffffffff",
        "ffff88800088f70888780008fffffffff7ffffffffffffffffff",
        "fff700877fffff00f700008fffffffff77ffffffffffffffffff",
        "ffffffffffffff70780008ffffffffff7fffffffffffffffffff",
        "fffffffffffffff080008ffffffff7788fffffffffffffffffff",
        "fffffffffffffff80000ffffffffffffffffffffffffffffffff",
        "fffffffffffffff7808fffffffffffffffffffffffffffffffff",
        "ffffffffffffffff88ffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffff",
    } },

    { 26, 26, {
        "ffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffff",
        "ffffff7ff807ffffff7fffffff",
        "ffff877ff880ff88007fffffff",
        "ffff7fff8870088808f8ffffff",
        "ffff77ff800008700f7fffffff",
        "fffffff8000000007f8fffffff",
        "fffff78800000007ff787fffff",
        "ffff808800000000fff888ffff",
        "ffff700000000780770807ffff",
        "fff7ff780000087007807fffff",
        "7ff78ff0870000000807ffffff",
        "77ff8ff0800f7880087fffffff",
        "7fff78f0007ff7ff7778ffffff",
        "fffff88007ff80807777ffffff",
        "fffff880fff80807fff78fffff",
        "fffff78fff08808788877fffff",
        "ffffff78708808f7ffffffffff",
        "ff7f778808808fff7fffffffff",
        "ff8887787808ffff7fffffffff",
        "fffffff8008ffff7ffffffffff",
        "ffffffff08ffffffffffffffff",
        "ffffffff7fffffffffffffffff",
        "ffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffff",
    } },

}

-- Turn a paint hex code ('0'-'f') into a colours.* value.
local colourOf = colors.fromBlit or function(hex)
    return 2 ^ tonumber(hex, 16)
end

-- The largest baked copy that fits; if none fit, the largest scaled down.
local function chooseImage(termWidth, termHeight)
    for _, image in ipairs(IMAGES) do
        if image[1] <= termWidth and image[2] <= termHeight then return image end
    end

    local image = IMAGES[1]
    local scale = math.min(termWidth / image[1], termHeight / image[2])
    local width = math.max(1, math.floor(image[1] * scale + 0.5))
    local height = math.max(1, math.floor(image[2] * scale + 0.5))
    local rows = {}
    for y = 1, height do
        local source = image[3][math.floor((y - 0.5) * image[2] / height) + 1]
        local row = {}
        for x = 1, width do
            local sx = math.floor((x - 0.5) * image[1] / width) + 1
            row[x] = source:sub(sx, sx)
        end
        rows[y] = table.concat(row)
    end
    return { width, height, rows }
end

-- Draw the image with its top-left corner at (x, y), one run per colour.
local function draw(monitor, image, x, y)
    local width, rows = image[1], image[3]
    for row = 1, image[2] do
        local line = rows[row]
        local column = 1
        while column <= width do
            local hex = line:sub(column, column)
            local last = column
            while last < width and line:sub(last + 1, last + 1) == hex do
                last = last + 1
            end
            if hex ~= "f" then -- black is already the background
                monitor.setBackgroundColor(colourOf(hex))
                monitor.setCursorPos(x + column - 1, y + row - 1)
                monitor.write(string.rep(" ", last - column + 1))
            end
            column = last + 1
        end
    end
end

local function render(monitor)
    monitor.setTextScale(TEXT_SCALE)
    local termWidth, termHeight = monitor.getSize()
    local image = chooseImage(termWidth, termHeight)

    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    draw(monitor, image,
        math.floor((termWidth - image[1]) / 2) + 1,
        math.floor((termHeight - image[2]) / 2) + 1)
    monitor.setCursorPos(1, 1)
end

local monitor = peripheral.find("monitor")
if not monitor then
    printError("No monitor attached")
    return
end

if arg and arg[1] == "watch" then
    while true do
        render(monitor)
        os.pullEvent("monitor_resize")
    end
else
    render(monitor)
end
