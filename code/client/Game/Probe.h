#pragma once

#include <RED4ext/Scripting/Natives/vehicleBaseObject.hpp>
#include <RED4ext/Scripting/Natives/moveComponent.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/ui/CharacterCustomizationState.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/ui/CharacterCustomizationSystem.hpp>

namespace Game::Probe
{
// CharacterCustomizationSystem held the player's state handle at 0x78 on 2.31; the class grew
// by 0x40 on 2.5. The handle is found by matching the vtable of a freshly created state.
// Never null: while the handle cannot be located it points at an empty handle, which callers
// already treat as "no state right now".
Red::Handle<Red::game::ui::CharacterCustomizationState>* CustomizationStateHandle(
    Red::game::ui::CharacterCustomizationSystem* apSystem);

// Hand-decoded layouts that patch 2.5 may have moved and that headers alone could not pin.
// Each is checked against the live object the first time it is used and logged once, so
// one session tells which offsets hold. A failed check disables the feature that needs the
// field instead of letting it read the wrong memory.

// vehicle::BaseObject::rigidBody was at 0x2D0 on 2.31. 2.5 inserted 8 bytes before it and
// 8 more before archetype, so it is at 0x2D8 or 0x2E0. Returns nullptr when no candidate
// passes, and callers skip the vehicle update.
Red::vehicle::RigidBody* VehicleRigidBody(Red::vehicle::BaseObject* apVehicle);

// Virtual calls made by slot offset cannot be checked by name. Logs the module RVA of the
// function in the slot so it can be disassembled, and returns true only for RVAs that have
// been confirmed on this game build.
bool VirtualSlotVerified(const void* apObject, uintptr_t aSlotOffset, const char* apWhat);

// move::Component::representation (0x138) is hand-decoded. Its parent pointer must point
// back at the component; when it does not, the controller must not be attached.
bool MoveComponentLayoutOk(Red::move::Component* apComponent);

// CharacterCustomizationState grew by 0x20 on 2.5 and the mod reads its arrays and gender
// byte at 2.31 offsets. Logs whether those still look like what they claim to be.
void CheckCustomizationState(const Red::game::ui::CharacterCustomizationState* apState, const char* apWhere);
}
