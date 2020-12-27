--
-- Created by IntelliJ IDEA.
-- User: awweaver
-- Date: 12/27/2020
-- Time: 14:28
-- To change this template use File | Settings | File Templates.
--

tArgs = {...}

local curx, cury, curz = gps.locate(3)
local CONSTANT_Y = 110
--local getData
--local calcData
local quarrySize = 0
local quarryStart
local newX, newZ
local x_coord, z_coord
local FUEL_CHEST = 16
local DUMP_CHEST = 15

function findChunks(x_coord, z_coord)
    if x_coord % 16 ~= 0 then
        print("You gave me this: "..x_coord.." "..z_coord)
        newX = x_coord - (x_coord % 16)
        newZ = z_coord - (z_coord % 16)
        quarryStart = vector.new(newX, CONSTANT_Y, newZ)
        print("New X on chunk boarder "..newX)
        print("New Z on chunk boarder "..newZ)
        print("Not changing Y because it is not needed, will use a constant y value of 110")
    else
        print("Coordinates are already on chunk-boarders, proceeding")
    end
end

function getData()
    while(math.ceil(math.sqrt(quarrySize)) == quarrySize or quarrySize == 0) do
        print("What size is this quarry? ")
        quarrySize = tonumber(read())
    end
    findChunks(x,z)

    local subQuarrySize = math.sqrt(quarrySize)
    print("Each Turtle will mine: "..subQuarrySize.." by "..subQuarrySize)
    print("How many turtles are there? ")
    local numTurtles = tonumber(read())
end

function calcData()
    local subQuarries = {subX = {}, subZ = {}}
    local numQuarriesSide = quarrySize / 16
    --subQuarries.subX = newX --add the FIRST coordinates to the array
    --subQuarries.subZ = newZ
    for i = 1, numQuarriesSide do
        subQuarries.subX[i] = newX + (subQuarrySize*i)
        for p = 1, numQuarriesSide do
            subQuarries.subZ[i] = newZ + (subQuarrySize*p)
            print("X: "..subQuarries.subX[i].." Z: "..subQuarries.subZ[p])
        end
        --print("X: "..newX.." Z: "..newZ)
    end
end

function sendData(subQauarry)

    turtle.select(1) --Select Turtles
    turtle.place()
    turtle.select(FUEL_CHEST) --Black Enderchest (Fuel)
    turtle.drop(1)
    turtle.select(DUMP_CHEST) --White Enderchests (Unload)
    turtle.drop(1)

end

if tArgs[1] == 0 then
    --defaultQuarry() --Default size...etc
else
    getData()
    calcData()
end