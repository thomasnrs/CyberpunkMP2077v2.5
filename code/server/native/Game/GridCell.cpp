#include "GridCell.h"
#include "Components/CellComponent.h"

GridCell::GridCell(TPosition aPosition)
    : m_position(aPosition)
{
    
}

GridCell::~GridCell()
{
}

void GridCell::Add(flecs::entity aEntity) noexcept
{
    m_entities.push_back(aEntity);
    aEntity.emplace<CellComponent>(this);
}

void GridCell::Remove(flecs::entity aEntity) noexcept
{
    aEntity.remove<CellComponent>();

    // erase(end()) is undefined - it wrote past the vector - for an entity this cell does
    // not hold.
    if (const auto it = std::ranges::find(m_entities, aEntity); it != m_entities.end())
        m_entities.erase(it);
}

