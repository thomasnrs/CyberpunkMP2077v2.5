#pragma once

// clang-format off

// This file is generated from the Game's Reflection data

#include <cstdint>
#include <RED4ext/Common.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/PuppetBase.hpp>

namespace RED4ext
{
namespace game
{
struct Puppet : game::PuppetBase
{
    static constexpr const char* NAME = "gamePuppet";
    static constexpr const char* ALIAS = NAME;

    uint8_t unk268[0x420 - 0x268]; // 268
    Red::Handle<move::Component> moveComponent; // 420 - from 2.31, UNVERIFIED on 2.5 (see Probe.cpp)
    uint8_t unk430[0x618 - 0x430]; // 430
};
RED4EXT_ASSERT_SIZE(Puppet, 0x618);
} // namespace game
using gamePuppet = game::Puppet;
} // namespace RED4ext

// clang-format on
