-- Restores Palworld's native UE console. Press the backtick key to cycle it through
-- None -> Typing -> Open -> None, matching the engine's own toggle order.
--
-- Palworld ships with the console fully intact: PalGameEngine creates a UPalConsole at startup,
-- registers it with GLog, and ALLOW_CONSOLE is on. Only the toggle is disabled. Any key present in
-- UInputSettings::ConsoleKeys is consumed above UConsole::InputKey, and only while ViewportConsole
-- is non-null, so InputKey_InputLine never runs and ConsoleState never leaves NAME_None. That is
-- also why ConsoleEnablerMod does nothing here: it takes its "console already exists" branch.
--
-- Everything that reads ConsoleState is stock (PostRender_Console, InputChar, and the
-- ConsoleState != NAME_None block in InputKey_InputLine), so this writes the variable directly.
-- APlayerController::ConsoleKey would have been the reflected way in, but its body is compiled out
-- of UE 5.1 shipping builds: calling it leaves ConsoleState untouched.

local UEHelpers = require("UEHelpers")

local ToggleKey = Key.OEM_THREE

-- ConsoleState and the bCaptureKeyInput/bCtrl/bShift word are not reflected, so they are located
-- relative to HistoryBuffer, which is. Deltas come from Console.h field order and are checked
-- against the class size of 0x130. Anchoring this way survives layout drift above HistoryBuffer,
-- which is where engine version differences usually land.
local ConsoleStateDelta = 0x70
local ConsoleInputFlagsDelta = 0x48
local CaptureKeyInputOnly = 1

local NextConsoleState = { None = "Typing", Typing = "Open", Open = "None" }
local ProbesRegistered = false

local function Log(Format, ...)
    if select("#", ...) > 0 then
        print("[ConsoleRestore] " .. string.format(Format, ...) .. "\n")
    else
        print("[ConsoleRestore] " .. Format .. "\n")
    end
end

local function FindPropertyOffset(Class, PropertyName)
    local FoundOffset = nil
    Class:ForEachProperty(function(Property)
        local okName, name = pcall(function() return Property:GetFName():ToString() end)
        if okName and tostring(name) == PropertyName then
            FoundOffset = Property:GetOffset_Internal()
            return true
        end
    end)
    return FoundOffset
end

local function RegisterConsoleProbes()
    local ConsoleClass = StaticFindObject("/Script/Engine.Console")
    if not ConsoleClass:IsValid() then
        Log("could not find /Script/Engine.Console, the toggle will not work")
        return false
    end

    local HistoryBufferOffset = FindPropertyOffset(ConsoleClass, "HistoryBuffer")
    if HistoryBufferOffset == nil then
        Log("could not locate UConsole::HistoryBuffer, the toggle will not work")
        return false
    end

    local ConsoleStateOffset = HistoryBufferOffset + ConsoleStateDelta
    local ConsoleInputFlagsOffset = HistoryBufferOffset + ConsoleInputFlagsDelta
    Log("HistoryBuffer at 0x%X -> ConsoleState 0x%X, input flags 0x%X",
        HistoryBufferOffset, ConsoleStateOffset, ConsoleInputFlagsOffset)

    for _, ClassPath in ipairs({ "/Script/Engine.Console", "/Script/Pal.PalConsole" }) do
        local okState = pcall(RegisterCustomProperty, {
            ["Name"] = "ConsoleStateProbe",
            ["Type"] = PropertyTypes.NameProperty,
            ["BelongsToClass"] = ClassPath,
            ["OffsetInternal"] = ConsoleStateOffset,
        })
        local okFlags = pcall(RegisterCustomProperty, {
            ["Name"] = "ConsoleInputFlagsProbe",
            ["Type"] = PropertyTypes.IntProperty,
            ["BelongsToClass"] = ClassPath,
            ["OffsetInternal"] = ConsoleInputFlagsOffset,
        })
        if not (okState and okFlags) then Log("could not register probes on %s", ClassPath) end
    end

    return true
end

local function GetGameViewport()
    local Engine = UEHelpers.GetEngine()
    if not Engine:IsValid() then return nil, "no engine" end

    local GameViewport = Engine.GameViewport
    if not GameViewport:IsValid() then return nil, "no game viewport" end

    return GameViewport
end

local function ToggleConsole()
    if not ProbesRegistered then Log("toggle unavailable, probes were not registered") return end

    local GameViewport, reason = GetGameViewport()
    if not GameViewport then Log("toggle aborted, %s", reason) return end

    local ViewportConsole = GameViewport.ViewportConsole
    if not ViewportConsole:IsValid() then Log("toggle aborted, no console attached") return end

    local okRead, CurrentState = pcall(function() return ViewportConsole.ConsoleStateProbe:ToString() end)
    if not okRead then Log("could not read ConsoleState: %s", tostring(CurrentState)) return end

    -- A wrong offset would read something that is not a console state name. Refuse rather than
    -- write, since the write would land in a neighbouring member.
    local TargetState = NextConsoleState[tostring(CurrentState)]
    if TargetState == nil then
        Log("refusing to write: ConsoleState read '%s', expected None, Typing or Open. Offsets are "
            .. "wrong for this build.", tostring(CurrentState))
        return
    end

    ViewportConsole.ConsoleStateProbe = UEHelpers.FindOrAddFName(TargetState)

    -- Mirrors what each toggle branch of InputKey_InputLine does. Without it InputChar_Typing
    -- appends the toggle key's own character to the input line.
    ViewportConsole.ConsoleInputFlagsProbe = CaptureKeyInputOnly
end

ProbesRegistered = RegisterConsoleProbes()
RegisterKeyBind(ToggleKey, function()
    local okToggle, err = pcall(ToggleConsole)
    if not okToggle then Log("toggle threw: %s", tostring(err)) end
end)
