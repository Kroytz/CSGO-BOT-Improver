#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <dhooks>

bool g_bIsHeadVisible[MAXPLAYERS+1], g_bZoomed[MAXPLAYERS + 1];
bool g_bFreezetimeEnd = false;
int g_iUSPChance[MAXPLAYERS + 1], g_iM4A1SChance[MAXPLAYERS + 1], g_iTarget[MAXPLAYERS+1] = -1;
int g_iBotTargetSpotOffset, g_iBotProfileOffset, g_iSkillOffset, g_iBotEnemyOffset, g_iEnemyVisibleOffset;
float g_fTargetPos[MAXPLAYERS + 1][3];
ConVar g_cvAimBotEnable, g_cvBotBuyEnable, g_cvBotEcoLimit;
Handle g_hLookupBone;
Handle g_hGetBonePosition;
Handle g_hBotIsVisible;
Handle g_hBotIsHiding;
Handle g_hBotPickNewAimSpotDetour;

char g_szBoneNames[][] =  {
	"neck_0", 
	"pelvis", 
	"spine_0", 
	"spine_1", 
	"spine_2", 
	"spine_3", 
	"arm_upper_L", 
	"arm_lower_L", 
	"hand_L", 
	"arm_upper_R", 
	"arm_lower_R", 
	"hand_R", 
	"leg_upper_L", 
	"ankle_L", 
	"leg_lower_L", 
	"leg_upper_R", 
	"ankle_R", 
	"leg_lower_R"
};

public Plugin myinfo = 
{
	name = "BOT Improver", 
	author = "manico", 
	description = "Improves bots aim and nade usage", 
	version = "1.6.3", 
	url = "http://steamcommunity.com/id/manico001"
};

public void OnPluginStart()
{
	HookEventEx("player_spawn", OnPlayerSpawn);
	HookEventEx("round_start", OnRoundStart);
	HookEventEx("round_freeze_end", OnFreezetimeEnd);
	HookEventEx("weapon_zoom", OnWeaponZoom);
	HookEventEx("weapon_fire", OnWeaponFire);
	
	g_cvBotEcoLimit = FindConVar("bot_eco_limit");
	g_cvAimBotEnable = CreateConVar("bot_aimlock", "1", "1 = Enable Bot Aimlock , 0 = Disable Bot Aimlock", _, true, 0.0, true, 1.0);
	g_cvBotBuyEnable = CreateConVar("bot_buy_override", "1", "1 = Use Plugin Buys for Bots, 0 = Use Buys from BotProfile.db", _, true, 0.0, true, 1.0);
	
	Handle hGameConfig = LoadGameConfigFile("botimprover.games");
	if (hGameConfig == INVALID_HANDLE)
		SetFailState("Failed to find botimprover.games game config.");
		
	if ((g_iBotTargetSpotOffset = GameConfGetOffset(hGameConfig, "CCSBot::m_targetSpot")) == -1)
	{
		SetFailState("Failed to get CCSBot::m_targetSpot offset.");
	}
	
	if ((g_iBotProfileOffset = GameConfGetOffset(hGameConfig, "CCSBot::m_pLocalProfile")) == -1)
	{
		SetFailState("Failed to get CCSBot::m_pLocalProfile offset.");
	}
	
	if ((g_iSkillOffset = GameConfGetOffset(hGameConfig, "BotProfile::m_skill")) == -1)
	{
		SetFailState("Failed to get BotProfile::m_skill offset.");
	}
	
	if ((g_iEnemyVisibleOffset = GameConfGetOffset(hGameConfig, "CCSBot::m_isEnemyVisible")) == -1)
	{
		SetFailState("Failed to get CCSBot::m_isEnemyVisible offset.");
	}
	
	if ((g_iBotEnemyOffset = GameConfGetOffset(hGameConfig, "CCSBot::m_enemy")) == -1)
	{
		SetFailState("Failed to get CCSBot::m_enemy offset.");
	}
		
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CBaseAnimating::LookupBone");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	if ((g_hLookupBone = EndPrepSDKCall()) == INVALID_HANDLE)SetFailState("Failed to create SDKCall for CBaseAnimating::LookupBone signature!");
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CBaseAnimating::GetBonePosition");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	if ((g_hGetBonePosition = EndPrepSDKCall()) == INVALID_HANDLE)SetFailState("Failed to create SDKCall for CBaseAnimating::GetBonePosition signature!");
	
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CCSBot::IsVisible");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	if ((g_hBotIsVisible = EndPrepSDKCall()) == INVALID_HANDLE)SetFailState("Failed to create SDKCall for CCSBot::IsVisible signature!");
	
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CCSBot::IsAtHidingSpot");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	if ((g_hBotIsHiding = EndPrepSDKCall()) == INVALID_HANDLE)SetFailState("Failed to create SDKCall for CCSBot::IsAtHidingSpot signature!");
	
	//CCSBot::PickNewAimSpot Detour
	g_hBotPickNewAimSpotDetour = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_CBaseEntity);
	if (!g_hBotPickNewAimSpotDetour)
		SetFailState("Failed to setup detour for CCSBot::PickNewAimSpot");
	
	if (!DHookSetFromConf(g_hBotPickNewAimSpotDetour, hGameConfig, SDKConf_Signature, "CCSBot::PickNewAimSpot"))
		SetFailState("Failed to load CCSBot::PickNewAimSpot signature from gamedata");
	
	if (!DHookEnableDetour(g_hBotPickNewAimSpotDetour, true, Detour_OnBOTPickNewAimSpot))
		SetFailState("Failed to detour CCSBot::PickNewAimSpot.");

	delete hGameConfig;
}

public void OnMapStart()
{
	CreateTimer(1.0, Timer_CheckPlayer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckPlayer(Handle hTimer, any data)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && IsFakeClient(i) && IsPlayerAlive(i))
		{	
			int iAccount = GetEntProp(i, Prop_Send, "m_iAccount");
			bool bInBuyZone = !!GetEntProp(i, Prop_Send, "m_bInBuyZone");
			
			if (GetRandomInt(1, 100) <= 5)
			{
				FakeClientCommand(i, "+lookatweapon");
				FakeClientCommand(i, "-lookatweapon");
			}
			
			if (iAccount == 800 && bInBuyZone)
			{
				if(GetRandomInt(1,100) <= 75)
				{
					FakeClientCommand(i, "buy vest");
				}
				else if (GetClientTeam(i) == CS_TEAM_CT && GetEntProp(i, Prop_Send, "m_bHasDefuser") == 0)
				{
					FakeClientCommand(i, "buy defuser");
				}
				else if(GetClientTeam(i) == CS_TEAM_T)
				{
					FakeClientCommand(i, "buy p250");
				}
			}
			else if ((iAccount > g_cvBotEcoLimit.IntValue || GetPlayerWeaponSlot(i, CS_SLOT_PRIMARY) != -1) && bInBuyZone)
			{
				if (GetEntProp(i, Prop_Data, "m_ArmorValue") < 50 || GetEntProp(i, Prop_Send, "m_bHasHelmet") == 0)
				{
					FakeClientCommand(i, "buy vesthelm");
				}
				
				if (GetClientTeam(i) == CS_TEAM_CT && GetEntProp(i, Prop_Send, "m_bHasDefuser") == 0)
				{
					FakeClientCommand(i, "buy defuser");
				}
			}
			else if (iAccount < g_cvBotEcoLimit.IntValue && iAccount > 2000 && GetEntProp(i, Prop_Send, "m_bHasDefuser") == 0 && bInBuyZone)
			{
				switch (GetRandomInt(1,10))
				{
					case 1: FakeClientCommand(i, "buy vest");
					case 5:
					{
						if (GetClientTeam(i) == CS_TEAM_CT)
							FakeClientCommand(i, "buy defuser");
						else
							FakeClientCommand(i, "buy vest");
					}
				}
			}
		}
	}
}

public void OnClientPostAdminCheck(int client)
{
	if (IsValidClient(client) && IsFakeClient(client))
	{
		g_iUSPChance[client] = GetRandomInt(1, 100);
		g_iM4A1SChance[client] = GetRandomInt(1, 100);
		
		SDKHook(client, SDKHook_WeaponCanSwitchTo, OnWeaponCanSwitch);
	}
}

public void OnRoundStart(Event eEvent, char[] szName, bool bDontBroadcast)
{
	g_bFreezetimeEnd = false;
}

public void OnFreezetimeEnd(Event eEvent, char[] szName, bool bDontBroadcast)
{
	g_bFreezetimeEnd = true;
}

public Action OnWeaponCanSwitch(int client, int iWeapon)
{
	int iDefIndex = GetEntProp(iWeapon, Prop_Send, "m_iItemDefinitionIndex");
	
	if((iDefIndex == 43 || iDefIndex == 44 || iDefIndex == 45 || iDefIndex == 46 || iDefIndex == 47 || iDefIndex == 48) && IsValidClient(g_iTarget[client]) && IsPlayerAlive(g_iTarget[client]))
	{
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public void OnWeaponZoom(Event eEvent, const char[] szName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(eEvent.GetInt("userid"));
	
	if (IsValidClient(client) && IsFakeClient(client) && IsPlayerAlive(client))
	{
		CreateTimer(0.3, Timer_Zoomed, GetClientUserId(client));
	}
}

public void OnWeaponFire(Event eEvent, const char[] szName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(eEvent.GetInt("userid"));
	if(IsValidClient(client) && IsFakeClient(client) && IsPlayerAlive(client) && IsValidClient(g_iTarget[client]))
	{
		char szWeaponName[64];
		eEvent.GetString("weapon", szWeaponName, sizeof(szWeaponName));
		
		if (strcmp(szWeaponName, "weapon_awp") == 0 || strcmp(szWeaponName, "weapon_ssg08") == 0)
		{
			g_bZoomed[client] = false;
		}
	}
}

public Action CS_OnBuyCommand(int client, const char[] szWeapon)
{
	if(g_cvBotBuyEnable.IntValue == 0)
	{
		return Plugin_Continue;
	}
	
	if (IsValidClient(client) && IsFakeClient(client) && IsPlayerAlive(client))
	{
		if (strcmp(szWeapon, "molotov") == 0 || strcmp(szWeapon, "incgrenade") == 0 || strcmp(szWeapon, "decoy") == 0 || strcmp(szWeapon, "flashbang") == 0 || strcmp(szWeapon, "hegrenade") == 0
			 || strcmp(szWeapon, "smokegrenade") == 0 || strcmp(szWeapon, "vest") == 0 || strcmp(szWeapon, "vesthelm") == 0 || strcmp(szWeapon, "defuser") == 0)
		{
			return Plugin_Continue;
		}
		else if (GetPlayerWeaponSlot(client, CS_SLOT_PRIMARY) != -1 && (strcmp(szWeapon, "galilar") == 0 || strcmp(szWeapon, "famas") == 0 || strcmp(szWeapon, "ak47") == 0
				 || strcmp(szWeapon, "m4a1") == 0 || strcmp(szWeapon, "ssg08") == 0 || strcmp(szWeapon, "aug") == 0 || strcmp(szWeapon, "sg556") == 0 || strcmp(szWeapon, "awp") == 0
				 || strcmp(szWeapon, "scar20") == 0 || strcmp(szWeapon, "g3sg1") == 0 || strcmp(szWeapon, "nova") == 0 || strcmp(szWeapon, "xm1014") == 0 || strcmp(szWeapon, "mag7") == 0
				 || strcmp(szWeapon, "m249") == 0 || strcmp(szWeapon, "negev") == 0 || strcmp(szWeapon, "mac10") == 0 || strcmp(szWeapon, "mp9") == 0 || strcmp(szWeapon, "mp7") == 0
				 || strcmp(szWeapon, "ump45") == 0 || strcmp(szWeapon, "p90") == 0 || strcmp(szWeapon, "bizon") == 0))
		{
			return Plugin_Handled;
		}
		
		int iAccount = GetEntProp(client, Prop_Send, "m_iAccount");
		
		if (strcmp(szWeapon, "m4a1") == 0)
		{
			if (g_iM4A1SChance[client] <= 30)
			{
				CSGO_SetMoney(client, iAccount - CS_GetWeaponPrice(client, CSWeapon_M4A1_SILENCER));
				CSGO_ReplaceWeapon(client, CS_SLOT_PRIMARY, "weapon_m4a1_silencer");
				
				return Plugin_Changed;
			}
			
			if (GetRandomInt(1, 100) <= 5 && iAccount >= CS_GetWeaponPrice(client, CSWeapon_AUG))
			{
				CSGO_SetMoney(client, iAccount - CS_GetWeaponPrice(client, CSWeapon_AUG));
				CSGO_ReplaceWeapon(client, CS_SLOT_PRIMARY, "weapon_aug");
				
				return Plugin_Changed;
			}
		}
		else if (strcmp(szWeapon, "mac10") == 0)
		{
			if (GetRandomInt(1, 100) <= 40 && iAccount >= CS_GetWeaponPrice(client, CSWeapon_GALILAR))
			{
				CSGO_SetMoney(client, iAccount - CS_GetWeaponPrice(client, CSWeapon_GALILAR));
				CSGO_ReplaceWeapon(client, CS_SLOT_PRIMARY, "weapon_galilar");
				
				return Plugin_Changed;
			}
		}
		else if (strcmp(szWeapon, "mp9") == 0)
		{
			if (GetRandomInt(1, 100) <= 40 && iAccount >= CS_GetWeaponPrice(client, CSWeapon_FAMAS))
			{
				CSGO_SetMoney(client, iAccount - CS_GetWeaponPrice(client, CSWeapon_FAMAS));
				CSGO_ReplaceWeapon(client, CS_SLOT_PRIMARY, "weapon_famas");
				
				return Plugin_Changed;
			}
		}
		else if (strcmp(szWeapon, "tec9") == 0 || strcmp(szWeapon, "fiveseven") == 0)
		{
			if (GetRandomInt(1, 100) <= 50)
			{
				CSGO_SetMoney(client, iAccount - CS_GetWeaponPrice(client, CSWeapon_CZ75A));
				CSGO_ReplaceWeapon(client, CS_SLOT_PRIMARY, "weapon_cz75a");
				
				return Plugin_Changed;
			}
		}
	}
	return Plugin_Continue;
}

public MRESReturn Detour_OnBOTPickNewAimSpot(int client, Handle hParams)
{
	if (g_cvAimBotEnable.IntValue == 1)
	{
		int iActiveWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (iActiveWeapon == -1) return MRES_Ignored;
		
		int iDefIndex = GetEntProp(iActiveWeapon, Prop_Send, "m_iItemDefinitionIndex");
		
		SelectBestTargetPos(client, g_fTargetPos[client]);
		
		if (!IsValidClient(g_iTarget[client]) || !IsPlayerAlive(g_iTarget[client]) || g_fTargetPos[client][2] == 0)
		{
			return MRES_Ignored;
		}
		
		switch(iDefIndex)
		{
			case 7, 8, 10, 13, 14, 16, 17, 19, 23, 24, 25, 26, 27, 28, 29, 33, 34, 35, 39, 60:
			{
				if (g_bIsHeadVisible[client])
				{
					if (GetRandomInt(1, 100) <= 70)
					{
						int iBone = LookupBone(g_iTarget[client], "spine_3");
						
						if (iBone < 0)
							return MRES_Ignored;
						
						float fBody[3], fBad[3];
						GetBonePosition(g_iTarget[client], iBone, fBody, fBad);
						
						if (BotIsVisible(client, fBody, false, -1))
						{
							g_fTargetPos[client] = fBody;
						}
					}
				}
			}
			case 2, 3, 4, 30, 32, 36, 61, 63:
			{
				if (g_bIsHeadVisible[client])
				{
					if (GetRandomInt(1, 100) <= 50)
					{
						int iBone = LookupBone(g_iTarget[client], "spine_3");
						
						if (iBone < 0)
							return MRES_Ignored;
						
						float fBody[3], fBad[3];
						GetBonePosition(g_iTarget[client], iBone, fBody, fBad);
						
						if (BotIsVisible(client, fBody, false, -1))
						{
							g_fTargetPos[client] = fBody;
						}
					}
				}
			}
			case 9, 11, 38:
			{
				if (g_bIsHeadVisible[client])
				{
					int iBone = LookupBone(g_iTarget[client], "spine_3");
					if (iBone < 0)
						return MRES_Ignored;
					
					float fBody[3], fBad[3];
					GetBonePosition(g_iTarget[client], iBone, fBody, fBad);
					
					if (BotIsVisible(client, fBody, false, -1))
					{
						g_fTargetPos[client] = fBody;
					}
				}
			}
			case 41, 42, 59, 500, 503, 505, 506, 507, 508, 509, 512, 514, 515, 516, 517, 518, 519, 520, 521, 522, 523, 525:
			{
				return MRES_Ignored;
			}
		}
		
		SetEntDataVector(client, g_iBotTargetSpotOffset, g_fTargetPos[client]);
	}
	
	return MRES_Ignored;
}

public Action OnPlayerRunCmd(int client, int & iButtons, int & iImpulse, float fVel[3], float fAngles[3], int & iWeapon, int & iSubtype, int & iCmdNum, int & iTickcount, int & iSeed, int iMouse[2])
{
	if (IsValidClient(client) && IsFakeClient(client) && IsPlayerAlive(client) && GetBotSkill(client) > 0.8)
	{
		int iActiveWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (iActiveWeapon == -1) return Plugin_Continue;
		
		int iDefIndex = GetEntProp(iActiveWeapon, Prop_Send, "m_iItemDefinitionIndex");
		
		float fClientPos[3], fTargetPos[3], fTargetDistance;
		GetClientAbsOrigin(client, fClientPos);
		bool bIsEnemyVisible = !!GetEntData(client, g_iEnemyVisibleOffset);
		g_iTarget[client] = BotGetEnemy(client);
		
		if(BotIsHiding(client) && (iDefIndex == 8 || iDefIndex == 39) && GetEntProp(iActiveWeapon, Prop_Send, "m_zoomLevel") == 0)
		{
			iButtons |= IN_ATTACK2;
		}
		else if(!BotIsHiding(client) && (iDefIndex == 8 || iDefIndex == 39) && GetEntProp(iActiveWeapon, Prop_Send, "m_zoomLevel") == 1)
		{
			iButtons |= IN_ATTACK2;
		}
		
		if(GetEntPropFloat(client, Prop_Send, "m_flMaxspeed") == 1.0)
		{
			SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", 260.0);
		}
		
		if ((iDefIndex == 9 || iDefIndex == 40) && GetEntProp(iActiveWeapon, Prop_Send, "m_zoomLevel") == 0)
		{
			g_bZoomed[client] = false;
		}
		
		if (!IsValidClient(g_iTarget[client]) || !IsPlayerAlive(g_iTarget[client]) || g_fTargetPos[client][2] == 0)
		{
			return Plugin_Continue;
		}
		
		GetClientAbsOrigin(g_iTarget[client], fTargetPos);
			
		fTargetDistance = GetVectorDistance(fClientPos, fTargetPos);
		
		if (g_bFreezetimeEnd && bIsEnemyVisible)
		{
			if (GetEntityMoveType(client) == MOVETYPE_LADDER)
			{
				return Plugin_Continue;
			}
			
			if (!(GetEntityFlags(client) & FL_ONGROUND))
			{
				return Plugin_Continue;
			}
			
			float fClientEyes[3], fClientAngles[3], fAimPunchAngle[3], fToAimSpot[3], fAimDir[3];
				
			GetClientEyePosition(client, fClientEyes);
			SubtractVectors(g_fTargetPos[client], fClientEyes, fToAimSpot);
			GetClientEyeAngles(client, fClientAngles);
			GetEntPropVector(client, Prop_Send, "m_aimPunchAngle", fAimPunchAngle);
			fClientAngles[0] += fAimPunchAngle[0] * 2.0;
			fClientAngles[1] += fAimPunchAngle[1] * 2.0;
			GetViewVector(fClientAngles, fAimDir);
			
			float fRangeToEnemy = NormalizeVector(fToAimSpot, fToAimSpot);
			float fOnTarget = GetVectorDotProduct(fToAimSpot, fAimDir);
			float fAimTolerance = Cosine(ArcTangent(32.0 / fRangeToEnemy));
			
			switch(iDefIndex)
			{
				case 7, 8, 10, 13, 14, 16, 17, 19, 23, 24, 25, 26, 28, 33, 34, 39, 60:
				{
					if (fOnTarget > fAimTolerance && fTargetDistance < 2000.0 && (!(iButtons & IN_ATTACK)))
					{
						if(!IsPlayerReloading(client)) 
						{
							iButtons |= IN_ATTACK;
						}
					}
					
					if (fOnTarget > fAimTolerance && !(GetEntityFlags(client) & FL_DUCKING) && fTargetDistance < 2000.0 && iDefIndex != 17 && iDefIndex != 19 && iDefIndex != 23 && iDefIndex != 24 && iDefIndex != 25 && iDefIndex != 26 && iDefIndex != 33 && iDefIndex != 34)
					{
						SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", 1.0);
					}
				}
				case 1:
				{
					if (fOnTarget > fAimTolerance && !(GetEntityFlags(client) & FL_DUCKING))
					{
						SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", 1.0);
					}
				}
				case 9, 40:
				{
					if (GetClientAimTarget(client, true) == g_iTarget[client] && g_bZoomed[client])
					{
						iButtons |= IN_ATTACK;
						
						SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", 1.0);
					}
				}
			}
			
			fClientPos[2] += 35.5;
				
			if (IsPointVisible(fClientPos, g_fTargetPos[client]) && fOnTarget > fAimTolerance && fTargetDistance < 2000.0 && (iDefIndex == 7 || iDefIndex == 8 || iDefIndex == 10 || iDefIndex == 13 || iDefIndex == 14 || iDefIndex == 16 || iDefIndex == 39 || iDefIndex == 60 || iDefIndex == 28))
			{
				iButtons |= IN_DUCK;
			}
		}	
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

public void OnPlayerSpawn(Event eEvent, const char[] szName, bool bDontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && IsFakeClient(i) && IsPlayerAlive(i))
		{
			CreateTimer(1.0, RFrame_CheckBuyZoneValue, GetClientSerial(i));
			
			if (g_iUSPChance[i] >= 25)
			{
				if (GetClientTeam(i) == CS_TEAM_CT)
				{
					char szUSP[32];
					
					GetClientWeapon(i, szUSP, sizeof(szUSP));
					
					if (strcmp(szUSP, "weapon_hkp2000") == 0)
					{
						CSGO_ReplaceWeapon(i, CS_SLOT_SECONDARY, "weapon_usp_silencer");
					}
				}
			}
		}
	}
}

public Action RFrame_CheckBuyZoneValue(Handle hTimer, int iSerial)
{
	int client = GetClientFromSerial(iSerial);
	
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))return Plugin_Stop;
	int iTeam = GetClientTeam(client);
	if (iTeam < 2)return Plugin_Stop;
	
	int iAccount = GetEntProp(client, Prop_Send, "m_iAccount");
	
	bool bInBuyZone = view_as<bool>(GetEntProp(client, Prop_Send, "m_bInBuyZone"));
	
	if (!bInBuyZone)return Plugin_Stop;
	
	int iPrimary = GetPlayerWeaponSlot(client, CS_SLOT_PRIMARY);
	
	char szDefaultPrimary[64];
	GetClientWeapon(client, szDefaultPrimary, sizeof(szDefaultPrimary));
	
	if ((iAccount > 2000) && (iAccount < g_cvBotEcoLimit.IntValue) && iPrimary == -1 && (strcmp(szDefaultPrimary, "weapon_hkp2000") == 0 || strcmp(szDefaultPrimary, "weapon_usp_silencer") == 0 || strcmp(szDefaultPrimary, "weapon_glock") == 0))
	{	
		int iRndPistol = GetRandomInt(1, 3);
		
		switch (iRndPistol)
		{
			case 1:
			{
				FakeClientCommand(client, "buy p250");
			}
			case 2:
			{
				FakeClientCommand(client, "buy %s", (iTeam == CS_TEAM_CT) ? "fiveseven" : "tec9");
			}
			case 3:
			{
				FakeClientCommand(client, "buy deagle");
			}
		}
	}
	return Plugin_Stop;
}

public Action Timer_Zoomed(Handle hTimer, any client)
{
	client = GetClientOfUserId(client);
	
	if(client != 0 && IsClientInGame(client))
	{
		g_bZoomed[client] = true;	
	}
	
	return Plugin_Stop;
}

stock void CSGO_SetMoney(int client, int iAmount)
{
	if (iAmount < 0)
		iAmount = 0;
	
	int iMax = FindConVar("mp_maxmoney").IntValue;
	
	if (iAmount > iMax)
		iAmount = iMax;
	
	SetEntProp(client, Prop_Send, "m_iAccount", iAmount);
}

stock int CSGO_ReplaceWeapon(int client, int iSlot, const char[] szClassname)
{
	int iWeapon = GetPlayerWeaponSlot(client, iSlot);
	
	if (IsValidEntity(iWeapon))
	{
		if (GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity") != client)
			SetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity", client);
		
		CS_DropWeapon(client, iWeapon, false, true);
		AcceptEntityInput(iWeapon, "Kill");
	}
	
	iWeapon = GivePlayerItem(client, szClassname);
	
	if (IsValidEntity(iWeapon))
		EquipPlayerWeapon(client, iWeapon);
	
	return iWeapon;
}

bool IsPlayerReloading(int client)
{
	int iPlayerWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	
	if(!IsValidEntity(iPlayerWeapon))
		return false;
	
	//Out of ammo? or Reloading? or Finishing Weapon Switch?
	if(GetEntProp(iPlayerWeapon, Prop_Data, "m_bInReload") || GetEntProp(iPlayerWeapon, Prop_Send, "m_iClip1") <= 0 || GetEntProp(iPlayerWeapon, Prop_Send, "m_iIronSightMode") == 2)
		return true;
	
	if(GetEntPropFloat(client, Prop_Send, "m_flNextAttack") > GetGameTime())
		return true;
	
	return GetEntPropFloat(iPlayerWeapon, Prop_Send, "m_flNextPrimaryAttack") >= GetGameTime();
}

public void OnClientDisconnect(int client)
{
	if (IsValidClient(client) && IsFakeClient(client))
	{
		SDKUnhook(client, SDKHook_WeaponCanSwitchTo, OnWeaponCanSwitch);
	}
}

public void SelectBestTargetPos(int client, float fTargetPos[3])
{
	if(IsValidClient(g_iTarget[client]) && IsPlayerAlive(g_iTarget[client]))
	{
		int iBone = LookupBone(g_iTarget[client], "head_0");
		if (iBone < 0)
			return;
		
		float fHead[3], fBad[3];
		GetBonePosition(g_iTarget[client], iBone, fHead, fBad);
		
		fHead[2] += 2.0;
		
		if (BotIsVisible(client, fHead, false, -1))
		{
			g_bIsHeadVisible[client] = true;
		}
		else
		{
			bool bVisibleOther = false;
			
			//Head wasn't visible, check other bones.
			for (int b = 0; b <= sizeof(g_szBoneNames) - 1; b++)
			{
				iBone = LookupBone(g_iTarget[client], g_szBoneNames[b]);
				if (iBone < 0)
					return;
				
				GetBonePosition(g_iTarget[client], iBone, fHead, fBad);
				
				if (BotIsVisible(client, fHead, false, -1))
				{
					g_bIsHeadVisible[client] = false;
					bVisibleOther = true;
					break;
				}
			}
			
			if (!bVisibleOther)
				return;
		}
		
		fTargetPos = fHead;
	}
}

stock void GetViewVector(float fVecAngle[3], float fOutPut[3])
{
	fOutPut[0] = Cosine(fVecAngle[1] / (180 / FLOAT_PI));
	fOutPut[1] = Sine(fVecAngle[1] / (180 / FLOAT_PI));
	fOutPut[2] = -Sine(fVecAngle[0] / (180 / FLOAT_PI));
}

stock bool IsPointVisible(float fStart[3], float fEnd[3])
{
	TR_TraceRayFilter(fStart, fEnd, MASK_SHOT, RayType_EndPoint, TraceEntityFilterStuff);
	return TR_GetFraction() >= 0.9;
}

public bool TraceEntityFilterStuff(int iEntity, int iMask)
{
	return iEntity > MaxClients;
}

public bool BotIsVisible(int client, float fPos[3], bool bTestFOV, int iIgnore)
{
	return SDKCall(g_hBotIsVisible, client, fPos, bTestFOV, iIgnore);
}

public bool BotIsHiding(int client)
{
	return SDKCall(g_hBotIsHiding, client);
}

public int LookupBone(int iEntity, const char[] szName)
{
	return SDKCall(g_hLookupBone, iEntity, szName);
}

public void GetBonePosition(int iEntity, int iBone, float fOrigin[3], float fAngles[3])
{
	SDKCall(g_hGetBonePosition, iEntity, iBone, fOrigin, fAngles);
}

public int BotGetEnemy(int client)
{
	return GetEntDataEnt2(client, g_iBotEnemyOffset);
}

public float GetBotSkill(int client)
{
	Address pLocalProfile = view_as<Address>(GetEntData(client, g_iBotProfileOffset));
	
	return view_as<float>(LoadFromAddress(pLocalProfile + view_as<Address>(g_iSkillOffset), NumberType_Int32));
}

stock bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsClientSourceTV(client);
}