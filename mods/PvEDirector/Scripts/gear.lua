-- All wearable gear and guns in SIGIS_ExampleItemData: { row, price[, ammo row] }, and every head and body mesh. See tools/offline-audit/gearrows.txt.
local G = {
    guns = {
        { "P08Pistol", 325, "9mmAmmo" },
        { "WelrodPistol", 525, "32Ammo" },
        { "M712Pistol", 1125, "10mmAmmo" },
        { "StenSMG", 1400, "9mmAmmo" },
        { "KlobbSMG", 1450, "32Ammo" },
        { "UziSmg", 1500, "9mmAmmo" },
        { "1911Pistol", 1525, "45Ammo" },
        { "SPP1Pistol", 1525, "DartAmmo" },
        { "M1ParaRifle", 1750, "32Ammo" },
        { "WebleyPistol", 1850, "32Ammo" },
        { "MosinObrezPistol", 1945, "54RAmmo" },
        { "SterlingRifle_Short", 2450, "9mmAmmo" },
        { "CustomMat49", 2800, "45Ammo" },
        { "SterlingRifle", 2850, "9mmAmmo" },
        { "Mat49Rifle", 2900, "32Ammo" },
        { "TerminatorShotgun", 3150, "12GaugeAmmo" },
        { "SterlingSpecial", 3200, "9mmAmmo" },
        { "SawedOffDouble", 3280, "12GaugeAmmo" },
        { "1911GPistol", 3525, "45Ammo" },
        { "PPSHSmg", 3750, "10mmAmmo" },
        { "AC14Rifle", 4500, "556Ammo" },
        { "MP40Rifle", 4655, "10mmAmmo" },
        { "Mas44Rifle", 4950, "762Ammo" },
        { "LongDoubleBarrel", 4950, "12GaugeAmmo" },
        { "MiniThumper", 5250, "40mmAmmo" },
        { "TrenchShotgun", 5280, "12GaugeAmmo" },
        { "M712SpecialSMG", 5425, "45Ammo" },
        { "SVT40Rifle", 5850, "54RAmmo" },
        { "LiberatorShotgun", 6280, "12GaugeAmmo" },
        { "DeLisleRifle", 6280, "45Ammo" },
        { "M45CarlSMG", 6450, "9mmAmmo" },
        { "M50ReisingRifle", 6680, "45Ammo" },
        { "GreaseGun", 7100, "45Ammo" },
        { "Mac10Rifle", 7280, "45Ammo" },
        { "DaewooK1Rifle", 7280, "556Ammo" },
        { "ViperMk1", 7600, "9mmAmmo" },
        { "M16Rifle", 7725, "556Ammo" },
        { "ThompsonSMG", 7750, "45Ammo" },
        { "JohnsonRifle", 8055, "300Ammo" },
        { "HeavyLiberatorShotgun", 8240, "12GaugeAmmo" },
        { "KrasaRifle", 8280, "762Ammo" },
        { "ThompsonSpecial", 8525, "45Ammo" },
        { "StonerRifle", 8750, "556Ammo" },
        { "ChinaLake", 9180, "40mmAmmo" },
        { "BARRifle", 9570, "300Ammo" },
        { "STG44Rifle", 9760, "762Ammo" },
        { "EM2Rifle", 9760, "556Ammo" },
        { "APSRifle", 10760, "DartAmmo" },
        { "FALRifle", 11250, "300Ammo" },
        { "Jackhammer", 11280, "12GaugeAmmo" },
        { "BrenMk2Rifle", 11375, "762Ammo" },
        { "DP28Rifle", 11550, "54RAmmo" },
        { "LPOFlamethrower", 11755, "FlameFuel" },
        { "HeavyThompsonSMG", 12250, "45Ammo" },
        { "SVURifle", 12750, "DartAmmo" },
        { "MG42Rifle", 13125, "762Ammo" },
        { "HeavyMG42Rifle", 15125, "762Ammo" },
    },
    helmets = {
        { "BABeret", 396 },
        { "ClothCap", 455 },
        { "LeatherCap", 655 },
        { "GuildBeret", 700 },
        { "PirateHelmet", 825 },
        { "PirateHelmetBlue", 825 },
        { "SASBeret", 900 },
        { "CivilianHelmet", 925 },
        { "BAHelmet", 1375 },
        { "RiotHelmet", 1575 },
        { "SafetyHelmet", 1896 },
        { "StahlhelmHelmet", 2350 },
        { "SecurityHelmet", 2785 },
        { "CommandoCap", 3250 },
        { "BaronCap", 3250 },
        { "BAHeavyHelmet", 3275 },
        { "BrodieHelmet", 3875 },
        { "M1Helmet", 4290 },
        { "HeavyM1Helmet", 4290 },
        { "GuildHelmet", 4290 },
        { "RedStahlhelmHelmet", 6150 },
        { "HeavyRiotHelmet", 6525 },
        { "M5Helmet", 7150 },
        { "PilotHelmet", 7350 },
        { "WardenRiotHelmet", 7750 },
        { "WeldersMask", 7965 },
        { "HeavyPilotHelmet", 9350 },
        { "PSHHelmet", 9375 },
        { "CustomPSHHelmet", 10295 },
        { "HeavyStahlhelmHelmet", 10750 },
    },
    chests = {
        { "PouchRig", 390 },
        { "LeatherJerkinChest", 855 },
        { "M1FlakChest", 900 },
        { "M1FlakRig", 1320 },
        { "M2FlakChest", 1565 },
        { "MK3FlakVest", 2165 },
        { "Mk3FlakRig", 2750 },
        { "HalfPlateChest", 2975 },
        { "PlateRig", 3065 },
        { "CEPlate", 3150 },
        { "BAFlakVest", 3650 },
        { "CEFullPlate", 3750 },
        { "ShermanPlate", 3850 },
        { "FullPlateChest", 4350 },
        { "ShermanRig", 4350 },
        { "PilotArmourChest", 6265 },
        { "BAHeavyVest", 7650 },
        { "HeavyPilotArmourChest", 8265 },
        { "PanzerChest", 8575 },
        { "FullShermanPlate", 8575 },
        { "PanzerRig", 9105 },
        { "FullShermanRig", 9105 },
        { "FullPanzerChest", 12055 },
        { "FullPanzerRig", 14500 },
    },
    bags = {
        { "SackBag", 325 },
        { "LightBag", 1225 },
        { "MedicBag", 1825 },
        { "CommandoBag", 2015 },
        { "RadioBag", 2015 },
        { "BarrelBag", 4500 },
        { "FreebooterBag", 9015 },
    },
    meds = {
        { "CannedFood", 8 },
        { "ChocolateBar", 10 },
        { "WaterBottle", 10 },
        { "LargeWaterBottle", 10 },
        { "Cracker", 12 },
        { "Biscuit", 14 },
        { "Ale", 15 },
        { "BandageAid", 225 },
        { "PirateBandageAid", 350 },
        { "Ration", 425 },
        { "Aspirin", 750 },
        { "Methamphetamine", 1005 },
        { "Morphine", 1125 },
        { "SmallFirstAid", 1500 },
        { "PirateFirstAid", 1700 },
        { "Cocaine", 3005 },
        { "LargeFirstAid", 4030 },
    },
    -- What else people carry in bags and pockets (rolled for station guards): every other row of item type 3 (valuables,
    -- food, scrap, tools), sealed loot boxes (type 20) and gun attachments (type 15), test rows left out.
    loot = {
        { "JunkScrap", 20 }, { "SyntheticScrap", 40 }, { "Fabric", 42 }, { "Gunpowder", 45 }, { "MetalScrap", 50 },
        { "MetalSheet", 55 }, { "Cable", 56 }, { "Lockpick", 56 }, { "HiGunpowder", 95 }, { "ToolKit", 142 },
        { "FuelBottle", 145 }, { "LeatherStrips", 215 }, { "Disinfectant", 215 }, { "LargeCable", 355 },
        { "PanzerChoc", 410 }, { "ReinforcedMetalSheet", 625 }, { "BottleCaps", 650 }, { "Flathead", 750 },
        { "Chemicals", 800 }, { "IndustrialAlcohol", 825 }, { "BankNotes", 825 }, { "Wrench", 850 },
        { "NickelOre", 875 }, { "CopperCoin", 1000 }, { "Hammer", 1070 }, { "WorkBelt", 1280 }, { "MotorOil", 1365 },
        { "KrasaStockBlueprint", 1550 }, { "IndustrialPaper", 1575 }, { "WorkGloves", 1580 }, { "Transmitter", 2100 },
        { "Mat49MagBlueprint", 2100 }, { "TobaccoPouch", 2150 }, { "Mat49SuppressorBlueprint", 2250 },
        { "WorkApron", 2350 }, { "KlobbDrumBlueprint", 2350 }, { "DartAmmoBlueprint", 2400 },
        { "SVT40DrumBlueprint", 2500 }, { "ArmouryToken", 2700 }, { "M45DrumBlueprint", 2700 },
        { "Krasa30MagBlueprint", 2800 }, { "SilverCoin", 3250 }, { "MineToken", 3250 }, { "PortToken", 3250 },
        { "CopperHorn", 3250 }, { "Fuse", 3250 }, { "CableSpool", 3250 }, { "KrasaSuppressorBlueprint", 3500 },
        { "TerraToken", 3550 }, { "PortableRadio", 3800 }, { "ColonyToken", 3850 }, { "PlanetKillerToken", 3925 },
        { "OutpostToken", 4150 }, { "PenalToken", 4150 }, { "FortressToken", 4175 }, { "TableFan", 4200 },
        { "BarrelBagBlueprint", 4500 }, { "SilverRing", 4800 }, { "PrisonSecurityToken", 4850 },
        { "BaronToken", 5200 }, { "1911GBlueprint", 5800 }, { "TrenchGunBlueprint", 6000 }, { "Lubricator", 7500 },
        { "AlliedDocument", 7750 }, { "HeavyShieldBlueprint", 8000 }, { "SilverTankard", 8200 }, { "GoldCoin", 8500 },
        { "ClusterBomb", 8900 }, { "NavyDocument", 9000 }, { "GoldRing", 9250 }, { "RedDiamond", 10900 },
        { "KingdomDocument", 11250 }, { "CEPasscode", 12500 }, { "HeavyThompsonBlueprint", 12500 },
        { "HeavyMG42Blueprint", 15000 }, { "KAWarbond", 16250 }, { "AirCompressor", 19200 }, { "CEWarbond", 19700 },
        { "UAWarbond", 21300 }, { "GoldCandelabra", 24000 }, { "Warbond", 25000 }, { "DieselDrill", 27000 },
        { "DieselEngine", 31500 }, { "AAMissile", 31500 }, { "SilverBullion", 45000 }, { "NuclearMaterial", 65000 },
        { "GoldBullion", 82500 },
    },
    boxes = {
        { "BiscuitTin", 650 }, { "RationCrate", 3500 }, { "MedicalCrate", 6500 }, { "GrenadeBox", 7500 },
        { "JewelleryBox", 8550 }, { "AmmoBox", 8550 }, { "BasicSupplyDrop", 11500 }, { "KAStrongbox", 11650 },
        { "UAStrongbox", 12250 }, { "CEStrongbox", 14125 }, { "SmallStrongbox", 21250 }, { "LargeStrongbox", 28500 },
    },
    parts = {
        { "KlobbDefaultMag", 350 }, { "Mat49DefaultMag", 350 }, { "M45DefaultMag", 350 }, { "StenCompensator", 580 },
        { "StenWoodStock", 620 }, { "UziExtendedMag", 640 }, { "KlobbExtendedMag", 650 }, { "M712Stock", 685 },
        { "M712Magazine", 730 }, { "M50Reising_magSmall", 730 }, { "M712MagSmall", 730 }, { "K1DefaultMag", 730 },
        { "ThompsonDefaultMag", 730 }, { "M16DefaultMag", 730 }, { "BARDefaultMag", 730 }, { "BARExtendedMag", 730 },
        { "UziDefaultMag", 730 }, { "PPSHDefaultMag", 730 }, { "StenDefaultMag", 730 }, { "FALDefaultMag", 730 },
        { "M1ParaDefaultMag", 730 }, { "SVT40DefaultMag", 730 }, { "KrasaDefaultMag", 730 },
        { "BrenDefaultMag", 730 }, { "DelisleDefaultMag", 730 }, { "JohnsonDefaultMag", 730 },
        { "SterlingDefaultMag", 730 }, { "MosinDefaultMag", 730 }, { "UziMetalSock", 755 },
        { "KlobbSuppressor", 785 }, { "GreaseGunStock01", 820 }, { "StenMK2Supressor01", 825 },
        { "ThompsonWoodStock", 875 }, { "UziWoodenStock", 895 }, { "M45Compensator", 895 }, { "UziSupressor", 915 },
        { "FALCompensator", 915 }, { "StenDrumMag", 920 }, { "MP40MetalStock", 945 },
        { "M50Reising_Compensator", 950 }, { "M1ParaCompensator", 950 }, { "DelisleExtendedMag", 970 },
        { "Mat49ExtendedMag", 1015 }, { "MP40Suppressor", 1050 }, { "M50Reising_Supressor", 1125 },
        { "M1ParaSuppressor", 1125 }, { "M16ExtendedMag", 1130 }, { "FALExtendedMag", 1130 }, { "APSStock01", 1175 },
        { "BARCompensator", 1200 }, { "M712Suppressor01", 1225 }, { "M50Reising_magLarge", 1250 },
        { "SterlingRegularMag", 1250 }, { "JohnsonCompensator", 1280 }, { "Mat49Stock", 1325 },
        { "JohnsonExtendedMag", 1330 }, { "KrasaCompensator", 1350 }, { "GreaseGunSuppressor01", 1350 },
        { "PPSHDrumMag", 1375 }, { "ViperSuppressor", 1375 }, { "AC14DefaultMag", 1375 }, { "KrasaWireStock", 1420 },
        { "ViperMk1DrumMag", 1500 }, { "Mat49WoodenStock", 1525 }, { "M16Suppressor", 1550 },
        { "KlobbDrumMag", 1565 }, { "M1Para30Mag", 1600 }, { "BrenSight", 1600 }, { "MosinExtendedMag", 1655 },
        { "SVT4020Mag", 1735 }, { "TrenchgunDrumMag", 1800 }, { "Mat49Suppressor", 1850 }, { "M45Suppressor", 1850 },
        { "K1WireStock", 1875 }, { "K1Compensator", 1920 }, { "Mac10Suppressor", 1925 }, { "M45DrumMag", 2155 },
        { "Mac10HeavyBarrel", 2380 }, { "SVT40DrumMag", 2400 }, { "MosinExtendedBarrel", 2500 },
        { "Krasa30Mag", 2730 }, { "SVT40Supressor", 2750 }, { "556ExtendedMag", 3130 }, { "SVT40Scope", 3150 },
        { "KrasaSuppressor", 3150 }, { "M16Scope", 3525 }, { "Bren30Mag", 3730 }, { "ThompsonDrumMag", 3850 },
        { "BrenDrumMag", 4150 },
    },
    heads = {
        "/Game/Characters/MainPlayer/Meshes/Heads/Bandit_Head_Skel_01.Bandit_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Baron_Head_Skel_01.Baron_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Colonist_Head_Skel_01.Colonist_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Commando_Head_Skel_01.Commando_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Commando_Head_Skel_02.Commando_Head_Skel_02",
        "/Game/Characters/MainPlayer/Meshes/Heads/Hunter_Head_Artic_Skel_01.Hunter_Head_Artic_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Hunter_Head_Green_Skel_01.Hunter_Head_Green_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Hunter_Head_Red_Skel_01.Hunter_Head_Red_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Hunter_Head_Skel_01.Hunter_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Miner_Head_Skel_01.Miner_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Nomad_Blood_Head_Skel_01.Nomad_Blood_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Nomad_Head_Crimson_Skel_01.Nomad_Head_Crimson_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Nomad_Head_Green_Skel_01.Nomad_Head_Green_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Nomad_Head_Skel_01.Nomad_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Nomad_Head_Yellow_Skel_01.Nomad_Head_Yellow_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Outlaw_Head_Skel_01.Outlaw_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Outlaw_Head_Skel_02.Outlaw_Head_Skel_02",
        "/Game/Characters/MainPlayer/Meshes/Heads/Outlaw_Head_Skel_03.Outlaw_Head_Skel_03",
        "/Game/Characters/MainPlayer/Meshes/Heads/Prisoner_Head_Skel_01.Prisoner_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_Blue_Skel_01.Raider_Head_Blue_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_Orange_Skel_01.Raider_Head_Orange_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_RedWhite_Skel_01.Raider_Head_RedWhite_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_Red_Skel_01.Raider_Head_Red_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_Skel_01.Raider_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_Sun_Skel_01.Raider_Head_Sun_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_Tan_Skel_01.Raider_Head_Tan_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_White_Skel_01.Raider_Head_White_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Raider_Head_Yellow_Skel_01.Raider_Head_Yellow_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/SAS_Head_Skel_01.SAS_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/SAS_Head_Skel_02.SAS_Head_Skel_02",
        "/Game/Characters/MainPlayer/Meshes/Heads/SAS_Major_Head_Skel_01.SAS_Major_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Security_Head_Army_Skel_01.Security_Head_Army_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Security_Head_Skel_01.Security_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Space_Pirate_Head_Skel_01.Space_Pirate_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Steel_Worker_Head_Skel_01.Steel_Worker_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/UA_Commander_Head_Skel_01.UA_Commander_Head_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/UA_Mask_Goggles_Skel_01.UA_Mask_Goggles_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/UA_Mask_Skel_01.UA_Mask_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/UA_Medic_Mask_Skel_01.UA_Medic_Mask_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Heads/Warden_Head_Skel_01.Warden_Head_Skel_01",
    },
    bodies = {
        "/Game/Characters/MainPlayer/Meshes/Bodies/Bandit_Body_Skel_01.Bandit_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Baron_Body_Skel_01.Baron_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Colonist_Body_Skel_01.Colonist_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Commando_Body_Blue_Skel_01.Commando_Body_Blue_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Commando_Body_Skel_01.Commando_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Hunter_Body_Artic_Skel_01.Hunter_Body_Artic_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Hunter_Body_Green_Skel_01.Hunter_Body_Green_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Hunter_Body_Red_Skel_01.Hunter_Body_Red_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Hunter_Body_Skel_01.Hunter_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Miner_Body_Skel_01.Miner_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Nomad_Body_Crimson_Skel_01.Nomad_Body_Crimson_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Nomad_Body_Green_Skel_01.Nomad_Body_Green_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Nomad_Body_Skel_01.Nomad_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Nomad_Body_Yellow_Skel_01.Nomad_Body_Yellow_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Outlaw_Body_Skel_01.Outlaw_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Outlaw_Body_Skel_02.Outlaw_Body_Skel_02",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Outlaw_Body_Skel_03.Outlaw_Body_Skel_03",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Prisoner_Body_Skel_01.Prisoner_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_Blue_Skel_01.Raider_Body_Blue_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_Orange_Skel_01.Raider_Body_Orange_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_RedWhite_Skel_01.Raider_Body_RedWhite_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_Red_Skel_01.Raider_Body_Red_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_Skel_01.Raider_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_Sun_Skel_01.Raider_Body_Sun_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_Tan_Skel_01.Raider_Body_Tan_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_White_Skel_01.Raider_Body_White_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Raider_Body_Yellow_Skel_01.Raider_Body_Yellow_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/SAS_Black_Body_Skel_01.SAS_Black_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/SAS_Body_Skel_01.SAS_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/SAS_Major_Body_Skel_01.SAS_Major_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/SAS_Operative_Body_Skel_01.SAS_Operative_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Security_Body_Army_Skel_01.Security_Body_Army_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Security_Body_Prison_Skel_01.Security_Body_Prison_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Security_Body_Skel_01.Security_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Space_Pirate_Body_Skel_01.Space_Pirate_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Steam/Raider_Body_Blood_Skel_01.Raider_Body_Blood_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Steel_Worker_Body_Skel_01.Steel_Worker_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/UA_Body_Skel_01.UA_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/UA_Body_Vest_Skel_01.UA_Body_Vest_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/UA_Commander_Body_Skel_01.UA_Commander_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/UA_Medic_Body_Skel_01.UA_Medic_Body_Skel_01",
        "/Game/Characters/MainPlayer/Meshes/Bodies/Warden_Body_Skel_01.Warden_Body_Skel_01",
    },
}

-- Heads and helmets: a helmet is a thin shell over the skull, and a bulky head (goggles, filters, ear pieces) pokes
-- through a tight one (bots looked like they wore two helmets merged into each other). headfit.lua, generated by
-- tools/headfit/make_headfit.py, lists the heads each helmet row fits over.
local okFit, FIT = pcall(require, "headfit")
if not okFit then FIT = {} end

local function meshName(head) return head and (tostring(head):match("([%w_]+)$")) or nil end

-- Does this head (a mesh path or name) fit under this helmet row? No helmet, or a row the table doesn't know: yes.
function G.fits(helmet, head)
    local list = helmet and FIT[helmet]
    if not list then return true end
    local name = meshName(head)
    for _, h in ipairs(list) do if h == name then return true end end
    return false
end

-- A random head path that fits under the helmet row.
function G.headFor(helmet)
    local ok = {}
    for _, path in ipairs(G.heads) do if G.fits(helmet, path) then ok[#ok + 1] = path end end
    if #ok == 0 then ok = G.heads end
    return ok[math.random(#ok)]
end

-- Bosses' own pieces: never handed out as a stand-in for a helmet that didn't fit (a roll can still give one).
G.SIGNATURE = { BaronCap = true, WardenRiotHelmet = true }
local NEAREST = 4 -- the stand-in is one of this many fitting helmets nearest in price

-- A helmet row near `helmet`'s price that fits over this head (keeps a person's face, swaps the helmet). Picked at random
-- from the NEAREST fitting rows, boss pieces left out: always taking the single nearest made the Baron Cap (mid-priced,
-- fits every face) the helmet of every recruit with a bulky face (#195). Nil when nothing fits: no helmet.
-- `plain`: a boss piece is swapped too, even when it fits (your crew aren't the Baron).
function G.helmetFor(helmet, head, plain)
    if not helmet or (G.fits(helmet, head) and not (plain and G.SIGNATURE[helmet])) then return helmet end
    local price
    for _, r in ipairs(G.helmets) do if r[1] == helmet then price = r[2] end end
    local near = {}
    for _, r in ipairs(G.helmets) do
        if not G.SIGNATURE[r[1]] and G.fits(r[1], head) then
            near[#near + 1] = { row = r[1], gap = math.abs(r[2] - (price or r[2])) }
        end
    end
    if #near == 0 then return nil end
    table.sort(near, function(a, b) return a.gap < b.gap end)
    return near[math.random(math.min(NEAREST, #near))].row
end

-- Guns a rolled kit may carry (rivalbodies.lua rollKit). Not the flamethrower (#413): in a bot's hands it kept
-- firing without stopping, and the main game took it off its bots too. Gear.guns stays whole for prices and loot.
G.botGuns = {}
for _, row in ipairs(G.guns) do
    if row[1] ~= "LPOFlamethrower" then G.botGuns[#G.botGuns + 1] = row end
end

return G
