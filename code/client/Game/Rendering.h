#include <RED4ext/GpuApi/DeviceData.hpp>

namespace Game::Rendering
{
// The swap chains and the direct queue used to be read from a hand-mapped render context
// (found through a displacement at Present+0x1F, fields at 0xC97F38 and 0x13BC4D0). Both
// moved on 2.5 (0xCEBF30, 0x14104D0), so this goes through the SDK's GpuApi layout, which
// is maintained per patch.
inline RED4ext::GpuApi::SDeviceData* GetDeviceData() noexcept
{
    return RED4ext::GpuApi::GetDeviceData();
}

constexpr auto CRenderNode_Present_DoInternal = Core::RawFunc<
    /* hash = */ 2468877568UL,
    /* type = */ void* (*)(int32_t*, uint8_t, UINT)>();

constexpr auto CRenderGlobal_Resize = Core::RawFunc<
    /* hash = */ 239671909UL,
    /* type = */ void* (*)(uint32_t a1, uint32_t a2, uint32_t a3, uint8_t a4, int32_t* a5)>();

constexpr auto CRenderGlobal_Shutdown = Core::RawFunc<
    /* hash = */ 3192982283UL,
    /* type = */ void* (*)(uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4)>();
}