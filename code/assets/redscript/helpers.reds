import CyberpunkMP.World.*

native func Log(const text: script_ref<String>) -> Void
native func LogWarning(const text: script_ref<String>) -> Void
native func LogError(const text: script_ref<String>) -> Void

// output goes to CET window
native func LogChannel(channel: CName, const text: script_ref<String>)
native func LogChannelWarning(channel: CName, const text: script_ref<String>) -> Void
native func LogChannelError(channel: CName, const text: script_ref<String>) -> Void

native func FTLog(const value: script_ref<String>) -> Void
native func FTLogWarning(const value: script_ref<String>) -> Void
native func FTLogError(const value: script_ref<String>) -> Void

// FTLog is a stub in the shipping game: every line the mod wrote with it went nowhere,
// which is why combat, weapon, death and hackable diagnostics never appeared in any log.
// These write to the mod's own log (the one players' logs upload) instead.
public func MpFTLog(text: String) -> Void {
    let network = GameInstance.GetNetworkWorldSystem();
    if IsDefined(network) {
        network.ScriptLog(text);
    }
}

public func MpFTLogWarning(text: String) -> Void {
    MpFTLog("WARNING " + text);
}

public func MpFTLogError(text: String) -> Void {
    MpFTLog("ERROR " + text);
}

native func Trace() -> Void
native func TraceToString() -> String