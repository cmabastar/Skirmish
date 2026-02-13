// FartAI: Self-Modifying Aggression System
// Dynamically adjusts aggression levels based on game state.
// All changes are logged for analysis and debugging.

#include "../define.as"
#include "../global.as"
#include "generic_helpers.as"

namespace FartAggression {

    // Aggression level enum for readability
    enum AggressionLevel {
        PASSIVE = 0,     // Turtle up, focus on economy
        CAUTIOUS = 1,    // Defend and probe
        BALANCED = 2,    // Standard play
        AGGRESSIVE = 3,  // Push hard, raid frequently
        BERSERKER = 4    // All-out assault, maximum pressure
    }

    // Current aggression state
    AggressionLevel CurrentLevel = AggressionLevel::BALANCED;
    AggressionLevel PreviousLevel = AggressionLevel::BALANCED;

    // Tracking variables for state analysis
    int LastEvalFrame = 0;
    int EvalIntervalFrames = 60 * SECOND; // Re-evaluate every 60 seconds

    // Economy snapshot history (rolling window for trend detection)
    float LastMetalIncome = 0.0f;
    float LastEnergyIncome = 0.0f;
    float MetalIncomeTrend = 0.0f;  // positive = growing, negative = shrinking
    float EnergyIncomeTrend = 0.0f;

    // Military strength tracking
    float LastOwnArmyCost = 0.0f;
    float LastEnemyThreat = 0.0f;
    float ArmyTrendRatio = 1.0f; // >1 = we're gaining, <1 = we're losing

    // Consecutive escalation/de-escalation tracking
    int ConsecutiveEscalations = 0;
    int ConsecutiveDeescalations = 0;

    // Attack threshold multipliers per aggression level
    // Lower = more aggressive (attacks with less power)
    float GetAttackThresholdMultiplier() {
        switch (CurrentLevel) {
            case AggressionLevel::PASSIVE:    return 2.0f;
            case AggressionLevel::CAUTIOUS:   return 1.5f;
            case AggressionLevel::BALANCED:   return 1.0f;
            case AggressionLevel::AGGRESSIVE: return 0.6f;
            case AggressionLevel::BERSERKER:  return 0.3f;
        }
        return 1.0f;
    }

    // Raid frequency multipliers per aggression level
    // Lower = raids more frequently with less power
    float GetRaidMinPowerMultiplier() {
        switch (CurrentLevel) {
            case AggressionLevel::PASSIVE:    return 2.0f;
            case AggressionLevel::CAUTIOUS:   return 1.3f;
            case AggressionLevel::BALANCED:   return 1.0f;
            case AggressionLevel::AGGRESSIVE: return 0.5f;
            case AggressionLevel::BERSERKER:  return 0.25f;
        }
        return 1.0f;
    }

    string LevelToString(AggressionLevel level) {
        switch (level) {
            case AggressionLevel::PASSIVE:    return "PASSIVE";
            case AggressionLevel::CAUTIOUS:   return "CAUTIOUS";
            case AggressionLevel::BALANCED:   return "BALANCED";
            case AggressionLevel::AGGRESSIVE: return "AGGRESSIVE";
            case AggressionLevel::BERSERKER:  return "BERSERKER";
        }
        return "UNKNOWN";
    }

    // Core evaluation function - called from main update loop
    void Evaluate() {
        if (ai.frame < LastEvalFrame + EvalIntervalFrames) return;
        LastEvalFrame = ai.frame;

        // Gather current state
        float metalIncome = aiEconomyMgr.metal.income;
        float energyIncome = aiEconomyMgr.energy.income;
        float metalCurrent = aiEconomyMgr.metal.current;
        float metalStorage = aiEconomyMgr.metal.storage;
        float enemyMobileThreat = aiEnemyMgr.mobileThreat;
        float enemyStaticThreat = aiEnemyMgr.staticThreat;
        float totalEnemyThreat = enemyMobileThreat + enemyStaticThreat;

        // Compute trends
        MetalIncomeTrend = metalIncome - LastMetalIncome;
        EnergyIncomeTrend = energyIncome - LastEnergyIncome;

        // Compute army ratio (our income vs enemy threat as proxy)
        float ownStrength = metalIncome * 30.0f; // rough army value proxy
        if (totalEnemyThreat > 0.0f) {
            ArmyTrendRatio = ownStrength / totalEnemyThreat;
        } else {
            ArmyTrendRatio = 2.0f; // No enemy = we're ahead
        }

        // Store previous level
        PreviousLevel = CurrentLevel;

        // Decision logic
        AggressionLevel newLevel = ComputeAggressionLevel(
            metalIncome, energyIncome, metalCurrent, metalStorage,
            totalEnemyThreat, ArmyTrendRatio, MetalIncomeTrend
        );

        // Apply smoothing: don't jump more than 1 level at a time
        if (int(newLevel) > int(CurrentLevel) + 1) {
            newLevel = AggressionLevel(int(CurrentLevel) + 1);
        } else if (int(newLevel) < int(CurrentLevel) - 1) {
            newLevel = AggressionLevel(int(CurrentLevel) - 1);
        }

        // Track consecutive changes for logging
        if (int(newLevel) > int(CurrentLevel)) {
            ConsecutiveEscalations++;
            ConsecutiveDeescalations = 0;
        } else if (int(newLevel) < int(CurrentLevel)) {
            ConsecutiveDeescalations++;
            ConsecutiveEscalations = 0;
        } else {
            // Level unchanged - no reset needed
        }

        // Apply the change
        if (newLevel != CurrentLevel) {
            GenericHelpers::LogUtil(
                "[FartAI][Aggression] LEVEL CHANGE: " + LevelToString(CurrentLevel) +
                " -> " + LevelToString(newLevel) +
                " | mi=" + metalIncome + " ei=" + energyIncome +
                " mTrend=" + MetalIncomeTrend +
                " armyRatio=" + ArmyTrendRatio +
                " enemyThreat=" + totalEnemyThreat +
                " escalations=" + ConsecutiveEscalations +
                " deescalations=" + ConsecutiveDeescalations,
                1);

            CurrentLevel = newLevel;
            ApplyAggressionToQuotas();
        }

        // Periodic state log even without changes
        if (ai.frame % (120 * SECOND) < EvalIntervalFrames) {
            GenericHelpers::LogUtil(
                "[FartAI][Aggression] STATUS: level=" + LevelToString(CurrentLevel) +
                " mi=" + metalIncome + " ei=" + energyIncome +
                " mTrend=" + MetalIncomeTrend +
                " armyRatio=" + ArmyTrendRatio +
                " enemyThreat=" + totalEnemyThreat +
                " frame=" + ai.frame,
                2);
        }

        // Update history
        LastMetalIncome = metalIncome;
        LastEnergyIncome = energyIncome;
    }

    AggressionLevel ComputeAggressionLevel(
        float metalIncome, float energyIncome,
        float metalCurrent, float metalStorage,
        float totalEnemyThreat, float armyRatio,
        float metalTrend
    ) {
        int gameMinutes = ai.frame / MINUTE;

        // Phase 1: Early game (0-8 min) - always cautious/balanced
        if (gameMinutes < 8) {
            if (metalIncome > 15.0f) return AggressionLevel::BALANCED;
            return AggressionLevel::CAUTIOUS;
        }

        // Phase 2: Mid game (8-20 min) - respond to game state
        if (gameMinutes < 20) {
            // Economy booming and enemy weak -> go aggressive
            if (armyRatio > 1.5f && metalIncome > 40.0f && metalTrend > 0.0f) {
                return AggressionLevel::AGGRESSIVE;
            }
            // Economy growing steadily -> balanced
            if (metalTrend >= 0.0f && metalIncome > 20.0f) {
                return AggressionLevel::BALANCED;
            }
            // Economy shrinking or weak -> cautious
            if (metalTrend < -2.0f || metalIncome < 15.0f) {
                return AggressionLevel::CAUTIOUS;
            }
            return AggressionLevel::BALANCED;
        }

        // Phase 3: Late game (20+ min) - full adaptive
        // Metal overflowing -> be more aggressive (spending power)
        bool metalOverflowing = (metalStorage > 0.0f && metalCurrent > metalStorage * 0.85f);

        // Strong economy and army advantage -> berserker
        if (armyRatio > 2.0f && metalIncome > 100.0f && metalOverflowing) {
            return AggressionLevel::BERSERKER;
        }

        // Clear advantage -> aggressive
        if (armyRatio > 1.3f && metalIncome > 60.0f) {
            return AggressionLevel::AGGRESSIVE;
        }

        // Even game -> balanced
        if (armyRatio > 0.7f && metalIncome > 30.0f) {
            return AggressionLevel::BALANCED;
        }

        // Losing -> cautious (rebuild)
        if (armyRatio < 0.5f) {
            return AggressionLevel::CAUTIOUS;
        }

        // Badly losing with crippled economy -> passive (turtle)
        if (armyRatio < 0.3f && metalIncome < 20.0f) {
            return AggressionLevel::PASSIVE;
        }

        return AggressionLevel::BALANCED;
    }

    // Apply the current aggression level to the engine's military quotas
    void ApplyAggressionToQuotas() {
        float attackMult = GetAttackThresholdMultiplier();
        float raidMult = GetRaidMinPowerMultiplier();

        // Base values from the current role settings
        float baseAttack = aiMilitaryMgr.quota.attack;
        float baseRaidMin = aiMilitaryMgr.quota.raid.min;
        float baseRaidAvg = aiMilitaryMgr.quota.raid.avg;

        // Apply multipliers (but clamp to minimum sensible values)
        float newAttack = baseAttack * attackMult;
        if (newAttack < 5.0f) newAttack = 5.0f;

        float newRaidMin = baseRaidMin * raidMult;
        if (newRaidMin < 5.0f) newRaidMin = 5.0f;

        float newRaidAvg = baseRaidAvg * raidMult;
        if (newRaidAvg < 10.0f) newRaidAvg = 10.0f;

        aiMilitaryMgr.quota.attack = newAttack;
        aiMilitaryMgr.quota.raid.min = newRaidMin;
        aiMilitaryMgr.quota.raid.avg = newRaidAvg;

        GenericHelpers::LogUtil(
            "[FartAI][Aggression] Applied quotas: attack=" + newAttack +
            " raidMin=" + newRaidMin + " raidAvg=" + newRaidAvg +
            " (attackMult=" + attackMult + " raidMult=" + raidMult + ")",
            2);
    }

    // Initialize aggression system at game start
    void Init() {
        CurrentLevel = AggressionLevel::CAUTIOUS; // Start cautious
        PreviousLevel = AggressionLevel::CAUTIOUS;
        LastEvalFrame = 0;
        ConsecutiveEscalations = 0;
        ConsecutiveDeescalations = 0;

        GenericHelpers::LogUtil("[FartAI][Aggression] System initialized at CAUTIOUS level", 1);
    }

} // namespace FartAggression
