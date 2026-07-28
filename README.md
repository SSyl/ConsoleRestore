# ConsoleRestore

Brings back Palworld's native UE console.

Proof of concept for mod developers, not a player-facing mod: it writes a non-reflected engine member
at a derived offset, has a known input-routing bug, and has only been run against one build.

Palworld 1.0.1 (UE 5.1.1), UE4SS Lua. Drop into `UE4SS\Mods\`, `enabled.txt` enables it, backtick
cycles `None -> Typing -> Open -> None`.

**Expect it to feel rough.** UI keybinds still reach the game while the console is open, so typing a
command opens menus behind it and Enter gets swallowed. You'll usually need a few presses of Escape
to unwind those before Enter actually reaches the console. That's the known bug below, not something
you've installed wrong.

## What's actually going on

The console was never removed. `ALLOW_CONSOLE` is on in Palworld's shipping build, so the engine
creates one at startup and registers it with `GLog`:

```
PalConsole /Engine/Transient.PalGameEngine_2147482588:PalGameViewportClient_2147482213.PalConsole_2147482212
```

That's why `ConsoleEnablerMod` looks broken here. It isn't. It exists to create the console object
that shipping builds normally skip, finds one already present, and exits.

Only the toggle is disabled. Any key in `UInputSettings::ConsoleKeys` is eaten above
`UConsole::InputKey`, and only while `ViewportConsole` is non-null, so `InputKey_InputLine` never runs
and `ConsoleState` never leaves `NAME_None`.

| `ViewportConsole` | console key |
|---|---|
| `UPalConsole` | eaten |
| stock `UConsole` swapped in | eaten |
| nulled out | passes through to gameplay |

A stock `UConsole` can't eat a console key without opening, since the same `if` body calls
`FakeGotoState` and that always assigns `ConsoleState`. So it's eaten upstream, and it isn't a
`UPalConsole` override.

## What the mod does

Everything downstream of `ConsoleState` is stock engine code (`PostRender_Console`, `InputChar`, and
the `ConsoleState != NAME_None` block in `InputKey_InputLine`), so it skips the blocked path and
writes the variable directly via `RegisterCustomProperty`.

`ConsoleState` isn't a `UPROPERTY`, so it's anchored to `HistoryBuffer`, which is. The anchor is read
at runtime with `UStruct:ForEachProperty` and `FProperty:GetOffset_Internal`; the deltas come from
`Console.h` field order.

| Member | Location |
|---|---|
| `TArray<FString> HistoryBuffer` | reflected, read at runtime (0x68 here) |
| `FName ConsoleState` | anchor + 0x70 |
| `bCaptureKeyInput:1, bCtrl:1, bShift:1` | anchor + 0x48 |

Anchoring absorbs layout drift above `HistoryBuffer`. Nothing reflected exists after `ConsoleState`,
so it can't be bracketed from both sides. The backstop is a read-back check that refuses to write
unless `ConsoleState` reads `None`, `Typing` or `Open`. `refusing to write` in `UE4SS.log` means the
layout moved.

## Known issues

**UI keybinds leak while it's open.** Movement is blocked, menus aren't, so Escape takes a few
presses. `UPalGameViewportClient` derives from `UCommonGameViewportClient`, whose `InputKey` hands the
CommonUI action router every key before `Super::InputKey`, and the guard exempting an open console is
`#if !UE_BUILD_SHIPPING`. Same in `IsKeyPriorityAboveUI`. Both key off `UE_BUILD_SHIPPING` rather than
`ALLOW_CONSOLE`, so enabling the console for shipping doesn't re-enable them. Epic changed both to
`#if ALLOW_CONSOLE` later; 5.1 predates that.

**Held keys stick.** A key held when the console opens never delivers its release, because
`InputKey_InputLine` consumes non-pressed events once `ConsoleState != None`. Stock UE avoids this via
`FlushPlayerInput()` in `FakeGotoState`, which this bypasses. `FlushPressedKeys` isn't reflected.

**Mouse look isn't suppressed.** Axis input doesn't route through the console.
`SetIgnoreLookInput`/`SetIgnoreMoveInput` are reflected and do mask this and the held-key case, but
were left out to keep this minimal.

## Finishing it properly

One C++ hook fixes all three and deletes most of this mod: offer the key to `ViewportConsole` at the
top of `UPalGameViewportClient::InputKey`, before the original runs, reinstating the block CommonUI
compiles out. That runs ahead of the kill switch so the real console key works and the offsets go
away, goes through `FakeGotoState` so the flush and focus handling happen properly, and returns
before the action router so the leak stops.

`UCommonGameViewportClient::OnRerouteInput` looks cleaner than a vtable patch, since `ExecuteIfBound`
returning true skips `HandleRerouteInput` entirely. Open question: whether it's static or
per-instance. Either way it's a plain `DECLARE_DELEGATE_FourParams` with no `UPROPERTY`, so Lua can't
reach it.

## Tried and didn't work: `APlayerController::ConsoleKey`

`APlayerController::ConsoleKey(FKey)` is a reflected `UFUNCTION` that calls
`ViewportConsole->InputKey` directly, which would have bypassed the kill switch and needed no offsets
at all. It does nothing here, measured with `ConsoleState` read either side of the call:

```
ConsoleKey(Tilde) on Class /Script/Pal.PalConsole:   ConsoleState None -> None
ConsoleKey(Tilde) on Class /Script/Engine.Console:   ConsoleState None -> None
```

UE 5.3 guards it with `#if ALLOW_CONSOLE`, but 5.1 most likely still has `#if !UE_BUILD_SHIPPING`.
The other candidate is the `FKey` argument not marshalling through `ProcessEvent`; untested, since
neither outcome makes it usable.

## License

[Unlicense](LICENSE). Public domain, do whatever you want with it. No attribution needed.
