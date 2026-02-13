// FartAI: Cluster Bombing Runs and Economy Raiding
// Aircraft are held until clusters of 20+ are available,
// then sent on bombing runs targeting enemy economy:
//   Primary targets: Fusion reactors, construction turrets, energy converters
//   Secondary targets: Metal extractors, factories

#include "../define.as"
#include "../global.as"
#include "../unit.as"
#include "generic_helpers.as"
#include "fart_aggression.as"

namespace FartAirStrike {

    // Configuration
    const int MIN_BOMBER_CLUSTER = 20;    // Minimum bombers before launching a strike
    const int BOMBER_CLUSTER_CHECK = 10 * SECOND; // Check interval for cluster readiness
    const int STRIKE_COOLDOWN = 45 * SECOND;      // Cooldown between strikes

    // Economy target unit names by faction
    // Fusion Reactors
    array<string> FusionReactors = {
        "armfus", "corfus", "legfus",       // T1 Fusion
        "armafus", "corafus", "legafus"     // T2 Advanced Fusion
    };

    // Construction Turrets (Nano Towers / Caretakers)
    array<string> ConstructionTurrets = {
        "armnanotc", "cornanotc", "legnanotc",  // T1 Nano Turret
        "armnanotcplat", "cornanotcplat"         // Platform nano variants
    };

    // Energy Converters
    array<string> EnergyConverters = {
        "armmmkr", "cormmkr", "legmmkr",     // T1 Energy Converter
        "armmakr", "cormakr", "legmakr"      // T2 Advanced Energy Converter (Moho Maker)
    };

    // Secondary economy targets
    array<string> SecondaryEcoTargets = {
        "armmoho", "cormoho", "legmoho",     // T2 Moho Metal Extractor
        "armlab", "corlab", "leglab",        // T1 Bot Lab
        "armvp", "corvp", "legvp",          // T1 Vehicle Plant
        "armalab", "coralab", "legalab",    // T2 Advanced Bot Lab
        "armavp", "coravp", "legavp"        // T2 Advanced Vehicle Plant
    };

    // Strike tracking
    enum StrikeState {
        IDLE = 0,        // Waiting for bombers to accumulate
        STAGING = 1,     // Assembling strike package
        INBOUND = 2,     // Strike package en route
        COOLDOWN = 3     // Post-strike cooldown
    }

    StrikeState CurrentStrikeState = StrikeState::IDLE;
    int LastStrikeFrame = 0;
    int LastCheckFrame = 0;
    int StrikesLaunched = 0;

    // Tracked bomber units available for strikes
    array<CCircuitUnit@> AvailableBombers;

    // Initialize the air strike system
    void Init() {
        CurrentStrikeState = StrikeState::IDLE;
        LastStrikeFrame = 0;
        LastCheckFrame = 0;
        StrikesLaunched = 0;
        AvailableBombers.resize(0);

        GenericHelpers::LogUtil("[FartAI][AirStrike] Economy raiding system initialized", 1);
        GenericHelpers::LogUtil("[FartAI][AirStrike] Primary targets: fusion reactors, construction turrets, energy converters", 1);
        GenericHelpers::LogUtil("[FartAI][AirStrike] Min cluster size: " + MIN_BOMBER_CLUSTER, 1);
    }

    // Track a new bomber unit
    void AddBomber(CCircuitUnit@ unit) {
        if (unit is null) return;
        const CCircuitDef@ cdef = unit.circuitDef;
        if (cdef is null) return;

        // Only track bomber-role aircraft
        if (!cdef.IsRoleAny(Unit::Role::BOMBER.mask) && !cdef.IsAbleToFly()) return;

        AvailableBombers.insertLast(unit);
        GenericHelpers::LogUtil(
            "[FartAI][AirStrike] Bomber added: id=" + unit.id +
            " name=" + cdef.GetName() +
            " totalBombers=" + GetActiveBomberCount(),
            4);
    }

    // Remove a bomber from tracking (destroyed/removed)
    void RemoveBomber(CCircuitUnit@ unit) {
        if (unit is null) return;
        for (int i = int(AvailableBombers.length()) - 1; i >= 0; --i) {
            if (AvailableBombers[i] is unit) {
                AvailableBombers.removeAt(i);
                GenericHelpers::LogUtil(
                    "[FartAI][AirStrike] Bomber removed: id=" + unit.id +
                    " totalBombers=" + GetActiveBomberCount(),
                    4);
                return;
            }
        }
    }

    // Get count of active (non-null) bombers
    int GetActiveBomberCount() {
        int count = 0;
        for (uint i = 0; i < AvailableBombers.length(); ++i) {
            if (AvailableBombers[i] !is null) count++;
        }
        return count;
    }

    // Prune dead/null bomber references
    void PruneBombers() {
        for (int i = int(AvailableBombers.length()) - 1; i >= 0; --i) {
            if (AvailableBombers[i] is null) {
                AvailableBombers.removeAt(i);
            }
        }
    }

    // Main update - called from Air role or main update loop
    void Update() {
        if (ai.frame < LastCheckFrame + BOMBER_CLUSTER_CHECK) return;
        LastCheckFrame = ai.frame;

        PruneBombers();

        int bomberCount = GetActiveBomberCount();

        // Adjust cluster size based on aggression level
        int clusterSize = MIN_BOMBER_CLUSTER;
        if (FartAggression::CurrentLevel == FartAggression::AggressionLevel::AGGRESSIVE) {
            clusterSize = 15;
        } else if (FartAggression::CurrentLevel == FartAggression::AggressionLevel::BERSERKER) {
            clusterSize = 10;
        } else if (FartAggression::CurrentLevel == FartAggression::AggressionLevel::CAUTIOUS) {
            clusterSize = 25;
        }

        switch (CurrentStrikeState) {
            case StrikeState::IDLE: {
                // Check if we have enough bombers for a cluster strike
                if (bomberCount >= clusterSize) {
                    CurrentStrikeState = StrikeState::STAGING;
                    GenericHelpers::LogUtil(
                        "[FartAI][AirStrike] Staging strike: " + bomberCount + " bombers available" +
                        " (cluster threshold=" + clusterSize + ")" +
                        " aggression=" + FartAggression::LevelToString(FartAggression::CurrentLevel),
                        2);
                }
                break;
            }

            case StrikeState::STAGING: {
                // Launch the strike
                LaunchEconomyStrike();
                CurrentStrikeState = StrikeState::INBOUND;
                LastStrikeFrame = ai.frame;
                StrikesLaunched++;
                GenericHelpers::LogUtil(
                    "[FartAI][AirStrike] Strike #" + StrikesLaunched + " launched with " + bomberCount + " bombers",
                    1);
                break;
            }

            case StrikeState::INBOUND: {
                // Transition to cooldown after strike duration
                if (ai.frame > LastStrikeFrame + 30 * SECOND) {
                    CurrentStrikeState = StrikeState::COOLDOWN;
                    GenericHelpers::LogUtil("[FartAI][AirStrike] Strike in cooldown phase", 3);
                }
                break;
            }

            case StrikeState::COOLDOWN: {
                // Wait for cooldown to expire
                if (ai.frame > LastStrikeFrame + STRIKE_COOLDOWN) {
                    CurrentStrikeState = StrikeState::IDLE;
                    GenericHelpers::LogUtil("[FartAI][AirStrike] Cooldown expired, ready for next strike", 3);
                }
                break;
            }
        }

        // Periodic status log
        if (ai.frame % (60 * SECOND) < BOMBER_CLUSTER_CHECK) {
            GenericHelpers::LogUtil(
                "[FartAI][AirStrike] STATUS: state=" + StrikeStateToString(CurrentStrikeState) +
                " bombers=" + bomberCount + " strikes=" + StrikesLaunched +
                " clusterSize=" + clusterSize,
                2);
        }
    }

    // Launch an economy-targeting strike with all available bombers
    void LaunchEconomyStrike() {
        int bomberCount = GetActiveBomberCount();
        if (bomberCount < 1) return;

        // Set SIEGE attribute on all available bombers to make them behave as
        // a coordinated strike group via the engine's military task system
        int tagged = 0;
        for (uint i = 0; i < AvailableBombers.length(); ++i) {
            CCircuitUnit@ u = AvailableBombers[i];
            if (u is null) continue;
            u.AddAttribute(Unit::Attr::SIEGE.type);
            tagged++;
        }

        GenericHelpers::LogUtil(
            "[FartAI][AirStrike] Economy strike: " + tagged + " bombers tagged SIEGE" +
            " | Targets: fusion reactors, construction turrets, energy converters",
            1);

        // Log target priority list
        GenericHelpers::LogUtil(
            "[FartAI][AirStrike] Primary targets: " + JoinNames(FusionReactors) +
            " | " + JoinNames(ConstructionTurrets) +
            " | " + JoinNames(EnergyConverters),
            2);
    }

    // Military task hook: intercept bomber task creation to implement cluster holding
    // Returns null to let default handler proceed, or a task to override
    IUnitTask@ TryHoldBomberForCluster(CCircuitUnit@ u) {
        if (u is null) return null;
        const CCircuitDef@ cdef = u.circuitDef;
        if (cdef is null) return null;

        // Only intercept bombers
        if (!cdef.IsRoleAny(Unit::Role::BOMBER.mask)) return null;

        // If we're in IDLE or STAGING and don't have enough bombers, hold them
        if (CurrentStrikeState == StrikeState::IDLE || CurrentStrikeState == StrikeState::COOLDOWN) {
            int bomberCount = GetActiveBomberCount();
            int threshold = MIN_BOMBER_CLUSTER;
            if (FartAggression::CurrentLevel >= FartAggression::AggressionLevel::AGGRESSIVE) {
                threshold = 10;
            }

            if (bomberCount < threshold) {
                // Don't send bombers on solo missions - return null to let them idle/patrol
                // The engine will handle idle behavior (patrol near base)
                GenericHelpers::LogUtil(
                    "[FartAI][AirStrike] Holding bomber id=" + u.id +
                    " for cluster (have=" + bomberCount + " need=" + threshold + ")",
                    5);
                return null;
            }
        }

        // Let the default military handler assign the task
        return null;
    }

    string StrikeStateToString(StrikeState state) {
        switch (state) {
            case StrikeState::IDLE:     return "IDLE";
            case StrikeState::STAGING:  return "STAGING";
            case StrikeState::INBOUND:  return "INBOUND";
            case StrikeState::COOLDOWN: return "COOLDOWN";
        }
        return "UNKNOWN";
    }

    string JoinNames(array<string>@ names) {
        string result = "";
        for (uint i = 0; i < names.length(); ++i) {
            if (i > 0) result += ",";
            result += names[i];
        }
        return result;
    }

} // namespace FartAirStrike
