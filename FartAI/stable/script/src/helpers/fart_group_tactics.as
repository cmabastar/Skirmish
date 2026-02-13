// FartAI: Group-Based Attack and Kiting Tactics
// Units are organized into tactical groups that attack and kite together.
// Groups coordinate movement to maintain formation while engaging enemies.

#include "../define.as"
#include "../global.as"
#include "../unit.as"
#include "generic_helpers.as"
#include "fart_aggression.as"

namespace FartGroupTactics {

    // Group configuration
    const int MIN_GROUP_SIZE = 5;       // Minimum units to form an attack group
    const int IDEAL_GROUP_SIZE = 12;    // Preferred group size
    const int MAX_GROUP_SIZE = 25;      // Cap per group to avoid deathballs
    const float GROUP_RADIUS = 800.0f;  // Max spread for units in a group
    const float KITE_DISTANCE = 400.0f; // Distance to pull back when kiting

    // Group states
    enum GroupState {
        FORMING = 0,    // Gathering units
        MOVING = 1,     // Moving to target
        ATTACKING = 2,  // Engaging enemy
        KITING = 3,     // Pulling back while shooting
        RETREATING = 4  // Full retreat to base
    }

    // Tactical group structure
    class TacticalGroup {
        int id;
        GroupState state;
        array<CCircuitUnit@> members;
        AIFloat3 rallyPoint;
        AIFloat3 targetPos;
        float groupPower;
        int lastUpdateFrame;
        int formingStartFrame;

        TacticalGroup() {
            id = -1;
            state = GroupState::FORMING;
            groupPower = 0.0f;
            lastUpdateFrame = 0;
            formingStartFrame = 0;
            rallyPoint = AIFloat3(0, 0, 0);
            targetPos = AIFloat3(0, 0, 0);
        }

        int GetSize() {
            int count = 0;
            for (uint i = 0; i < members.length(); ++i) {
                if (members[i] !is null) count++;
            }
            return count;
        }

        void PruneDeadUnits() {
            for (int i = int(members.length()) - 1; i >= 0; --i) {
                if (members[i] is null) {
                    members.removeAt(i);
                }
            }
        }

        float GetAverageHealth() {
            float total = 0.0f;
            int count = 0;
            for (uint i = 0; i < members.length(); ++i) {
                CCircuitUnit@ u = members[i];
                if (u is null) continue;
                total += u.GetHealthPercent();
                count++;
            }
            return (count > 0) ? (total / float(count)) : 0.0f;
        }

        AIFloat3 GetCenterOfMass() {
            float cx = 0.0f;
            float cz = 0.0f;
            int count = 0;
            for (uint i = 0; i < members.length(); ++i) {
                CCircuitUnit@ u = members[i];
                if (u is null) continue;
                AIFloat3 pos = u.GetPos(ai.frame);
                cx += pos.x;
                cz += pos.z;
                count++;
            }
            if (count == 0) return rallyPoint;
            return AIFloat3(cx / float(count), 0, cz / float(count));
        }
    }

    // Active groups
    array<TacticalGroup@> ActiveGroups;
    int NextGroupId = 0;

    // Units waiting to be assigned to a group
    array<CCircuitUnit@> UnassignedUnits;

    // Update interval
    int LastUpdateFrame = 0;
    const int UPDATE_INTERVAL = 5 * SECOND;

    // Initialize the group tactics system
    void Init() {
        ActiveGroups.resize(0);
        UnassignedUnits.resize(0);
        NextGroupId = 0;
        LastUpdateFrame = 0;
        GenericHelpers::LogUtil("[FartAI][GroupTactics] System initialized", 1);
    }

    // Register a new combat unit for group assignment
    void AddUnit(CCircuitUnit@ unit) {
        if (unit is null) return;

        // Only track mobile combat units (not builders, not static)
        const CCircuitDef@ cdef = unit.circuitDef;
        if (cdef is null) return;
        if (!cdef.IsMobile()) return;
        if (cdef.IsRoleAny(Unit::Role::BUILDER.mask)) return;

        // Don't add aircraft - they have their own system
        if (cdef.IsAbleToFly()) return;

        UnassignedUnits.insertLast(unit);
        GenericHelpers::LogUtil("[FartAI][GroupTactics] Unit id=" + unit.id + " added to pool (pool=" + UnassignedUnits.length() + ")", 4);
    }

    // Remove a unit from all tracking
    void RemoveUnit(CCircuitUnit@ unit) {
        if (unit is null) return;

        // Remove from unassigned pool
        for (int i = int(UnassignedUnits.length()) - 1; i >= 0; --i) {
            if (UnassignedUnits[i] is unit) {
                UnassignedUnits.removeAt(i);
                return;
            }
        }

        // Remove from active groups
        for (uint g = 0; g < ActiveGroups.length(); ++g) {
            TacticalGroup@ grp = ActiveGroups[g];
            if (grp is null) continue;
            for (int i = int(grp.members.length()) - 1; i >= 0; --i) {
                if (grp.members[i] is unit) {
                    grp.members.removeAt(i);
                    GenericHelpers::LogUtil("[FartAI][GroupTactics] Unit removed from group " + grp.id + " (remaining=" + grp.GetSize() + ")", 4);
                    return;
                }
            }
        }
    }

    // Main update - called from military update
    void Update() {
        if (ai.frame < LastUpdateFrame + UPDATE_INTERVAL) return;
        LastUpdateFrame = ai.frame;

        // Prune dead units from all groups
        PruneAllGroups();

        // Try to form new groups from unassigned units
        TryFormGroups();

        // Update each active group's state
        for (uint g = 0; g < ActiveGroups.length(); ++g) {
            TacticalGroup@ grp = ActiveGroups[g];
            if (grp is null) continue;
            UpdateGroup(grp);
        }

        // Clean up dissolved groups
        CleanupGroups();
    }

    void PruneAllGroups() {
        // Prune unassigned pool
        for (int i = int(UnassignedUnits.length()) - 1; i >= 0; --i) {
            if (UnassignedUnits[i] is null) {
                UnassignedUnits.removeAt(i);
            }
        }
        // Prune group members
        for (uint g = 0; g < ActiveGroups.length(); ++g) {
            if (ActiveGroups[g] !is null) {
                ActiveGroups[g].PruneDeadUnits();
            }
        }
    }

    void TryFormGroups() {
        // Need at least MIN_GROUP_SIZE units to form a group
        // Factor in aggression: more aggressive = smaller min group (attacks sooner)
        int adjustedMinSize = MIN_GROUP_SIZE;
        if (FartAggression::CurrentLevel == FartAggression::AggressionLevel::AGGRESSIVE) {
            adjustedMinSize = 3;
        } else if (FartAggression::CurrentLevel == FartAggression::AggressionLevel::BERSERKER) {
            adjustedMinSize = 2;
        }

        if (int(UnassignedUnits.length()) < adjustedMinSize) return;

        // Form a new group
        TacticalGroup@ newGroup = TacticalGroup();
        newGroup.id = NextGroupId++;
        newGroup.state = GroupState::FORMING;
        newGroup.formingStartFrame = ai.frame;

        int toAssign = IDEAL_GROUP_SIZE;
        if (int(UnassignedUnits.length()) < toAssign) {
            toAssign = int(UnassignedUnits.length());
        }
        if (toAssign > MAX_GROUP_SIZE) {
            toAssign = MAX_GROUP_SIZE;
        }

        float totalPower = 0.0f;
        for (int i = 0; i < toAssign; ++i) {
            CCircuitUnit@ u = UnassignedUnits[0];
            if (u !is null) {
                newGroup.members.insertLast(u);
                const CCircuitDef@ cdef = u.circuitDef;
                if (cdef !is null) {
                    totalPower += cdef.IsRoleAny(Unit::Role::HEAVY.mask) ? cdef.costM * 1.5f : cdef.costM;
                }
            }
            UnassignedUnits.removeAt(0);
        }

        newGroup.groupPower = totalPower;

        // Set rally point near our base
        newGroup.rallyPoint = Global::Map::StartPos;

        ActiveGroups.insertLast(newGroup);

        GenericHelpers::LogUtil(
            "[FartAI][GroupTactics] New group " + newGroup.id + " formed: size=" + newGroup.GetSize() +
            " power=" + totalPower + " minRequired=" + adjustedMinSize,
            2);
    }

    void UpdateGroup(TacticalGroup@ grp) {
        if (grp is null) return;
        grp.lastUpdateFrame = ai.frame;

        int size = grp.GetSize();
        if (size == 0) return;

        float avgHealth = grp.GetAverageHealth();

        switch (grp.state) {
            case GroupState::FORMING: {
                // Wait for group to reach minimum size or timeout (30 seconds)
                int adjustedMinSize = MIN_GROUP_SIZE;
                if (FartAggression::CurrentLevel >= FartAggression::AggressionLevel::AGGRESSIVE) {
                    adjustedMinSize = 3;
                }

                bool ready = (size >= adjustedMinSize);
                bool timeout = (ai.frame > grp.formingStartFrame + 30 * SECOND) && (size >= 2);

                if (ready || timeout) {
                    grp.state = GroupState::MOVING;
                    GenericHelpers::LogUtil(
                        "[FartAI][GroupTactics] Group " + grp.id + " ready to move: size=" + size +
                        " power=" + grp.groupPower + (timeout ? " (timeout)" : ""),
                        3);
                }
                break;
            }

            case GroupState::MOVING: {
                // Check if we encounter enemies - transition to attack or kite
                float enemyThreatNearby = aiEnemyMgr.mobileThreat;
                if (enemyThreatNearby > 0.0f) {
                    // Evaluate: can we take this fight?
                    if (grp.groupPower > enemyThreatNearby * FartAggression::GetAttackThresholdMultiplier()) {
                        grp.state = GroupState::ATTACKING;
                        GenericHelpers::LogUtil(
                            "[FartAI][GroupTactics] Group " + grp.id + " engaging: power=" + grp.groupPower +
                            " vs threat=" + enemyThreatNearby, 3);
                    } else {
                        // Kite: we're outmatched but can harass
                        grp.state = GroupState::KITING;
                        GenericHelpers::LogUtil(
                            "[FartAI][GroupTactics] Group " + grp.id + " kiting: power=" + grp.groupPower +
                            " vs threat=" + enemyThreatNearby, 3);
                    }
                }
                break;
            }

            case GroupState::ATTACKING: {
                // Check health - if group is taking heavy losses, kite
                if (avgHealth < 0.5f) {
                    grp.state = GroupState::KITING;
                    GenericHelpers::LogUtil(
                        "[FartAI][GroupTactics] Group " + grp.id + " kiting due to low health: avgHP=" + avgHealth, 3);
                }
                // Check if group is too small, retreat
                if (size < 2) {
                    grp.state = GroupState::RETREATING;
                    GenericHelpers::LogUtil(
                        "[FartAI][GroupTactics] Group " + grp.id + " retreating: only " + size + " units left", 3);
                }
                break;
            }

            case GroupState::KITING: {
                // Kite logic: keep engaging but maintain distance
                // If health recovers or reinforcements arrive, re-engage
                if (avgHealth > 0.7f && size >= MIN_GROUP_SIZE) {
                    grp.state = GroupState::ATTACKING;
                    GenericHelpers::LogUtil(
                        "[FartAI][GroupTactics] Group " + grp.id + " re-engaging after kite recovery", 3);
                }
                // If health is critical, retreat
                if (avgHealth < 0.25f || size < 2) {
                    grp.state = GroupState::RETREATING;
                    GenericHelpers::LogUtil(
                        "[FartAI][GroupTactics] Group " + grp.id + " full retreat: avgHP=" + avgHealth + " size=" + size, 3);
                }
                break;
            }

            case GroupState::RETREATING: {
                // Dissolve group when retreating - units go back to pool
                for (uint i = 0; i < grp.members.length(); ++i) {
                    CCircuitUnit@ u = grp.members[i];
                    if (u !is null) {
                        UnassignedUnits.insertLast(u);
                    }
                }
                grp.members.resize(0);
                GenericHelpers::LogUtil(
                    "[FartAI][GroupTactics] Group " + grp.id + " dissolved after retreat", 2);
                break;
            }
        }
    }

    void CleanupGroups() {
        for (int g = int(ActiveGroups.length()) - 1; g >= 0; --g) {
            TacticalGroup@ grp = ActiveGroups[g];
            if (grp is null || grp.GetSize() == 0) {
                ActiveGroups.removeAt(g);
            }
        }
    }

    // Called by military manager when making tasks for combat units
    // Returns true if the group system handled the unit's task
    IUnitTask@ TryMakeGroupTask(CCircuitUnit@ u) {
        if (u is null) return null;

        // Find which group this unit belongs to
        for (uint g = 0; g < ActiveGroups.length(); ++g) {
            TacticalGroup@ grp = ActiveGroups[g];
            if (grp is null) continue;

            for (uint i = 0; i < grp.members.length(); ++i) {
                if (grp.members[i] is u) {
                    return MakeTaskForGroupState(u, grp);
                }
            }
        }

        // Unit not in any group - let default handler take over
        return null;
    }

    IUnitTask@ MakeTaskForGroupState(CCircuitUnit@ u, TacticalGroup@ grp) {
        if (u is null || grp is null) return null;

        // For FORMING state: rally near base
        if (grp.state == GroupState::FORMING) {
            // Let the default handler manage idle units during formation
            return null;
        }

        // For active combat states, defer to the engine's default military task
        // but the group tracking influences when/how we decide to engage
        // The actual fight/move commands come from the C++ engine based on threat analysis
        return null;
    }

    // Get stats for logging
    string GetStatusString() {
        int forming = 0;
        int moving = 0;
        int attacking = 0;
        int kiting = 0;
        int retreating = 0;
        int totalUnits = 0;

        for (uint g = 0; g < ActiveGroups.length(); ++g) {
            TacticalGroup@ grp = ActiveGroups[g];
            if (grp is null) continue;
            int sz = grp.GetSize();
            totalUnits += sz;
            switch (grp.state) {
                case GroupState::FORMING:    forming++; break;
                case GroupState::MOVING:     moving++; break;
                case GroupState::ATTACKING:  attacking++; break;
                case GroupState::KITING:     kiting++; break;
                case GroupState::RETREATING: retreating++; break;
            }
        }

        return "groups=" + ActiveGroups.length() +
               " (forming=" + forming + " moving=" + moving +
               " attacking=" + attacking + " kiting=" + kiting +
               " retreating=" + retreating + ")" +
               " unitsInGroups=" + totalUnits +
               " unassigned=" + UnassignedUnits.length();
    }

} // namespace FartGroupTactics
