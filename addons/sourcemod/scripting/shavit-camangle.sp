#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <dhooks>

#include <shavit/core>

#define PLUGIN_VERSION "1.0.0"

#define KEY_OFFSET "camangle"
#define KEY_CUSTOM "camangle_custom"

#define MOVEMENT_BUTTONS (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT)

public Plugin myinfo =
{
	name = "[shavit] Camera Angle Styles",
	author = "aren-19",
	description = "Camera angle styles.",
	version = PLUGIN_VERSION,
	url = "https://github.com/aren-19/css-mmr"
}

int gI_StyleCount = 0;
bool gB_CamStyle[STYLE_LIMIT];
bool gB_CustomStyle[STYLE_LIMIT];
bool gB_Selectable[STYLE_LIMIT];
float gF_StyleOffset[STYLE_LIMIT];

float gF_CustomOffset[MAXPLAYERS+1];
int gI_LastButtons[MAXPLAYERS+1];
int gI_LastPlainStyle[MAXPLAYERS+1];
bool gB_InTriggerTeleport[MAXPLAYERS+1];

int gI_PointTeleportDepth = 0;

bool gB_HasTeleportAngles[MAXPLAYERS+1];
float gF_TeleportAngles[MAXPLAYERS+1][2];
int gI_TeleportTick[MAXPLAYERS+1];
int gI_HijackWindow = 0;

chatstrings_t gS_ChatStrings;
Cookie gH_CustomCookie = null;
DynamicHook gH_Teleport = null;
DynamicHook gH_AcceptInput = null;

ConVar gCV_TeleportFix = null;
ConVar gCV_UseFix = null;
ConVar gCV_DefaultCustom = null;

public void OnPluginStart()
{
	gCV_TeleportFix = CreateConVar("shavit_camangle_teleport_fix", "1", "Fix restored angles on teleport.", 0, true, 0.0, true, 1.0);
	gCV_UseFix = CreateConVar("shavit_camangle_use_fix", "1", "Don't rotate on +use press.", 0, true, 0.0, true, 1.0);
	gCV_DefaultCustom = CreateConVar("shavit_camangle_custom_default", "180", "Default custom angle.", 0, true, -180.0, true, 180.0);
	AutoExecConfig(true, "plugin.shavit-camangle");

	RegConsoleCmd("sm_cam", Command_Cam, "Camera menu.");
	RegConsoleCmd("sm_camera", Command_Cam, "Camera menu.");
	RegConsoleCmd("sm_camangle", Command_CamAngle, "sm_camangle <degrees>");

	gH_CustomCookie = new Cookie("shavit_camangle_custom", "Custom camera angle", CookieAccess_Protected);

	LoadHooks();

	gI_HijackWindow = RoundToCeil(1.0 / GetTickInterval());

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			OnClientPutInServer(i);
		}
	}

	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "trigger_teleport")) != -1)
	{
		HookTriggerTeleport(entity);
	}

	entity = -1;

	while ((entity = FindEntityByClassname(entity, "point_teleport")) != -1)
	{
		HookPointTeleport(entity);
	}
}

public void OnAllPluginsLoaded()
{
	int styles = Shavit_GetStyleCount();

	if (styles > 0)
	{
		Shavit_OnStyleConfigLoaded(styles);
	}

	Shavit_OnChatConfigLoaded();
}

void LoadHooks()
{
	GameData gamedata = new GameData("sdktools.games");

	if (gamedata == null)
	{
		SetFailState("Failed to load sdktools.games gamedata.");
	}

	int offset = gamedata.GetOffset("Teleport");
	int acceptInput = gamedata.GetOffset("AcceptInput");
	delete gamedata;

	if (offset == -1 || acceptInput == -1)
	{
		SetFailState("Couldn't get the offsets for \"Teleport\" and \"AcceptInput\".");
	}

	gH_Teleport = new DynamicHook(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
	gH_Teleport.AddParam(HookParamType_VectorPtr);
	gH_Teleport.AddParam(HookParamType_VectorPtr);
	gH_Teleport.AddParam(HookParamType_VectorPtr);

	if (GetEngineVersion() == Engine_CSGO)
	{
		gH_Teleport.AddParam(HookParamType_Bool);
	}

	gH_AcceptInput = new DynamicHook(acceptInput, HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity);
	gH_AcceptInput.AddParam(HookParamType_CharPtr);
	gH_AcceptInput.AddParam(HookParamType_CBaseEntity);
	gH_AcceptInput.AddParam(HookParamType_CBaseEntity);
	gH_AcceptInput.AddParam(HookParamType_Object, 20, DHookPass_ByVal|DHookPass_ODTOR|DHookPass_OCTOR|DHookPass_OASSIGNOP);
	gH_AcceptInput.AddParam(HookParamType_Int);
}

public void Shavit_OnStyleConfigLoaded(int styles)
{
	gI_StyleCount = styles;

	for (int i = 0; i < styles; i++)
	{
		gB_CustomStyle[i] = Shavit_GetStyleSettingBool(i, KEY_CUSTOM);
		gF_StyleOffset[i] = NormalizeYaw(Shavit_GetStyleSettingFloat(i, KEY_OFFSET));
		gB_CamStyle[i] = gB_CustomStyle[i] || gF_StyleOffset[i] != 0.0;
		gB_Selectable[i] = Shavit_GetStyleSettingInt(i, "enabled") > 0 && !Shavit_GetStyleSettingBool(i, "inaccessible");
	}
}

public void Shavit_OnChatConfigLoaded()
{
	Shavit_GetChatStringsStruct(gS_ChatStrings);
}

public void OnClientPutInServer(int client)
{
	gF_CustomOffset[client] = NormalizeYaw(gCV_DefaultCustom.FloatValue);
	gI_LastButtons[client] = 0;
	gI_LastPlainStyle[client] = 0;
	gB_InTriggerTeleport[client] = false;
	gB_HasTeleportAngles[client] = false;

	if (IsFakeClient(client))
	{
		return;
	}

	gH_Teleport.HookEntity(Hook_Pre, client, DHook_Teleport);

	if (AreClientCookiesCached(client))
	{
		OnClientCookiesCached(client);
	}
}

public void OnClientCookiesCached(int client)
{
	char value[16];
	gH_CustomCookie.Get(client, value, sizeof(value));

	if (value[0] != '\0')
	{
		gF_CustomOffset[client] = NormalizeYaw(StringToFloat(value));
	}
}

public void Shavit_OnStyleChanged(int client, int oldstyle, int newstyle, int track, bool manual)
{
	gB_HasTeleportAngles[client] = false;

	if (!IsCamStyle(newstyle))
	{
		gI_LastPlainStyle[client] = newstyle;
		return;
	}

	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	char offset[32];
	FormatOffset(GetOffsetFor(client, newstyle), offset, sizeof(offset));

	Shavit_PrintToChat(client, "Camera: %s%s%s.", gS_ChatStrings.sVariable, offset, gS_ChatStrings.sText);
}

public Action Shavit_OnUserCmdPre(int client, int &buttons, int &impulse, float vel[3], float angles[3], TimerStatus status, int track, int style, int mouse[2])
{
	int lastButtons = gI_LastButtons[client];
	gI_LastButtons[client] = buttons;

	gB_InTriggerTeleport[client] = false;

	float offset;

	if (!GetStyleOffset(client, style, offset) || !CanRotate(client))
	{
		return Plugin_Continue;
	}

	if (gCV_UseFix.BoolValue && (buttons & IN_USE) && !(lastButtons & IN_USE))
	{
		return Plugin_Continue;
	}

	RotateMovement(offset, vel, buttons);

	if (!IsRestoredShownAngle(client, angles))
	{
		angles[1] = NormalizeYaw(angles[1] + offset);
	}

	return Plugin_Changed;
}

bool CanRotate(int client)
{
	return GetEntityMoveType(client) == MOVETYPE_WALK && GetEntProp(client, Prop_Send, "m_nWaterLevel") < 2;
}

void RotateMovement(float offset, float vel[3], int &buttons)
{
	float rad = DegToRad(offset);
	float c = Cosine(rad);
	float s = Sine(rad);

	if (FloatAbs(s) < 1.0e-6)
	{
		s = 0.0;
		c = (c > 0.0) ? 1.0 : -1.0;
	}
	else if (FloatAbs(c) < 1.0e-6)
	{
		c = 0.0;
		s = (s > 0.0) ? 1.0 : -1.0;
	}

	float forwardmove = vel[0];
	float sidemove = vel[1];

	vel[0] = SnapZero(forwardmove * c - sidemove * s);
	vel[1] = SnapZero(forwardmove * s + sidemove * c);

	buttons &= ~MOVEMENT_BUTTONS;

	if (vel[0] > 0.0)
	{
		buttons |= IN_FORWARD;
	}
	else if (vel[0] < 0.0)
	{
		buttons |= IN_BACK;
	}

	if (vel[1] > 0.0)
	{
		buttons |= IN_MOVERIGHT;
	}
	else if (vel[1] < 0.0)
	{
		buttons |= IN_MOVELEFT;
	}
}

bool IsRestoredShownAngle(int client, const float angles[3])
{
	if (!gB_HasTeleportAngles[client])
	{
		return false;
	}

	if (GetGameTickCount() - gI_TeleportTick[client] > gI_HijackWindow)
	{
		gB_HasTeleportAngles[client] = false;
		return false;
	}

	return angles[0] == gF_TeleportAngles[client][0] && angles[1] == gF_TeleportAngles[client][1];
}

public MRESReturn DHook_Teleport(int client, DHookParam params)
{
	if (params.IsNull(2) || gB_InTriggerTeleport[client] || gI_PointTeleportDepth > 0 || !gCV_TeleportFix.BoolValue || !IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}

	float offset;

	if (!GetStyleOffset(client, Shavit_GetBhopStyle(client), offset))
	{
		return MRES_Ignored;
	}

	float angles[3];
	params.GetVector(2, angles);

	gF_TeleportAngles[client][0] = angles[0];
	gF_TeleportAngles[client][1] = angles[1];
	gI_TeleportTick[client] = GetGameTickCount();
	gB_HasTeleportAngles[client] = true;

	angles[1] = NormalizeYaw(angles[1] - offset);
	params.SetVector(2, angles);

	return MRES_ChangedHandled;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "trigger_teleport"))
	{
		HookTriggerTeleport(entity);
	}
	else if (StrEqual(classname, "point_teleport"))
	{
		HookPointTeleport(entity);
	}
}

public void OnGameFrame()
{
	gI_PointTeleportDepth = 0;
}

void HookTriggerTeleport(int entity)
{
	SDKHook(entity, SDKHook_Touch, Hook_TriggerTeleportTouch);
	SDKHook(entity, SDKHook_TouchPost, Hook_TriggerTeleportTouchPost);
}

public Action Hook_TriggerTeleportTouch(int entity, int other)
{
	if (1 <= other <= MaxClients)
	{
		gB_InTriggerTeleport[other] = true;
	}

	return Plugin_Continue;
}

public void Hook_TriggerTeleportTouchPost(int entity, int other)
{
	if (1 <= other <= MaxClients)
	{
		gB_InTriggerTeleport[other] = false;
	}
}

void HookPointTeleport(int entity)
{
	gH_AcceptInput.HookEntity(Hook_Pre, entity, DHook_PointTeleportInput);
	gH_AcceptInput.HookEntity(Hook_Post, entity, DHook_PointTeleportInputPost);
}

public MRESReturn DHook_PointTeleportInput(int entity, DHookReturn ret, DHookParam params)
{
	gI_PointTeleportDepth++;
	return MRES_Ignored;
}

public MRESReturn DHook_PointTeleportInputPost(int entity, DHookReturn ret, DHookParam params)
{
	if (gI_PointTeleportDepth > 0)
	{
		gI_PointTeleportDepth--;
	}

	return MRES_Ignored;
}

public Action Command_Cam(int client, int args)
{
	if (IsValidClient(client))
	{
		OpenCamMenu(client);
	}

	return Plugin_Handled;
}

public Action Command_CamAngle(int client, int args)
{
	if (!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if (args < 1)
	{
		OpenCustomMenu(client);
		return Plugin_Handled;
	}

	char arg[16];
	GetCmdArg(1, arg, sizeof(arg));

	float value;

	if (StringToFloatEx(arg, value) == 0)
	{
		Shavit_PrintToChat(client, "Usage: %s!camangle <degrees>", gS_ChatStrings.sVariable);

		return Plugin_Handled;
	}

	SetCustomOffset(client, value, true);
	return Plugin_Handled;
}

void OpenCamMenu(int client)
{
	int current = Shavit_GetBhopStyle(client);

	char name[64];
	char offset[32];
	char display[128];
	char info[8];

	Menu menu = new Menu(MenuHandler_Cam);
	GetStyleName(current, name, sizeof(name));

	if (IsCamStyle(current))
	{
		FormatOffset(GetOffsetFor(client, current), offset, sizeof(offset));
		menu.SetTitle("Camera\n%s (%s)\n ", name, offset);
	}
	else
	{
		menu.SetTitle("Camera\n%s\n ", name);
	}

	int ordered[STYLE_LIMIT];
	Shavit_GetOrderedStyles(ordered, gI_StyleCount);

	bool hasCustom = false;

	for (int i = 0; i < gI_StyleCount; i++)
	{
		int style = ordered[i];

		if (!IsCamStyle(style) || !gB_Selectable[style])
		{
			continue;
		}

		hasCustom = hasCustom || gB_CustomStyle[style];

		GetStyleName(style, name, sizeof(name));
		FormatOffset(GetOffsetFor(client, style), offset, sizeof(offset));
		FormatEx(display, sizeof(display), "%s [%s]", name, offset);
		IntToString(style, info, sizeof(info));

		bool enabled = (style != current && Shavit_HasStyleAccess(client, style));
		menu.AddItem(info, display, enabled ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}

	if (menu.ItemCount == 0)
	{
		delete menu;
		Shavit_PrintToChat(client, "No camera styles.");
		return;
	}

	if (hasCustom)
	{
		menu.AddItem("custom", "Custom angle...");
	}

	if (IsCamStyle(current))
	{
		GetStyleName(gI_LastPlainStyle[client], name, sizeof(name));
		FormatEx(display, sizeof(display), "Off (%s)", name);
		menu.AddItem("off", display);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Cam(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "custom"))
		{
			OpenCustomMenu(param1);
		}
		else if (StrEqual(info, "off"))
		{
			ChangeStyle(param1, gI_LastPlainStyle[param1]);
		}
		else
		{
			ChangeStyle(param1, StringToInt(info));
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenCustomMenu(int client)
{
	int custom = FindCustomStyle(client);

	if (custom == -1)
	{
		Shavit_PrintToChat(client, "No custom camera style.");
		return;
	}

	char offset[32];
	FormatOffset(gF_CustomOffset[client], offset, sizeof(offset));

	Menu menu = new Menu(MenuHandler_Custom);
	menu.SetTitle("Custom angle: %s\n ", offset);

	menu.AddItem("5", "+5°");
	menu.AddItem("-5", "-5°");
	menu.AddItem("45", "+45°");
	menu.AddItem("-45", "-45°");
	menu.AddItem("180", "180°");

	if (!gB_CustomStyle[Shavit_GetBhopStyle(client)])
	{
		char name[64];
		char display[96];
		GetStyleName(custom, name, sizeof(name));
		FormatEx(display, sizeof(display), "Use %s", name);
		menu.AddItem("switch", display);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Custom(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "switch"))
		{
			int custom = FindCustomStyle(param1);

			if (custom != -1)
			{
				ChangeStyle(param1, custom);
			}
		}
		else
		{
			SetCustomOffset(param1, gF_CustomOffset[param1] + StringToFloat(info), false);
			OpenCustomMenu(param1);
		}
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		OpenCamMenu(param1);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void SetCustomOffset(int client, float value, bool switchStyle)
{
	int custom = FindCustomStyle(client);

	if (custom == -1)
	{
		Shavit_PrintToChat(client, "No custom camera style.");
		return;
	}

	value = NormalizeYaw(value);
	int style = Shavit_GetBhopStyle(client);

	if (value != gF_CustomOffset[client])
	{
		gF_CustomOffset[client] = value;
		gB_HasTeleportAngles[client] = false;

		char sValue[16];
		FloatToString(value, sValue, sizeof(sValue));
		gH_CustomCookie.Set(client, sValue);

		if (gB_CustomStyle[style] && Shavit_GetTimerStatus(client) != Timer_Stopped)
		{
			Shavit_StopTimer(client);
			Shavit_PrintToChat(client, "%sTimer stopped.", gS_ChatStrings.sWarning);
		}
	}

	char offset[32];
	FormatOffset(value, offset, sizeof(offset));
	Shavit_PrintToChat(client, "Custom angle: %s%s%s.", gS_ChatStrings.sVariable, offset, gS_ChatStrings.sText);

	if (switchStyle && !gB_CustomStyle[style])
	{
		ChangeStyle(client, custom);
	}
}

void ChangeStyle(int client, int style)
{
	FakeClientCommand(client, "sm_style %d", style);
}

bool IsCamStyle(int style)
{
	return 0 <= style < gI_StyleCount && gB_CamStyle[style];
}

float GetOffsetFor(int client, int style)
{
	return gB_CustomStyle[style] ? gF_CustomOffset[client] : gF_StyleOffset[style];
}

bool GetStyleOffset(int client, int style, float &offset)
{
	if (!IsCamStyle(style))
	{
		return false;
	}

	offset = GetOffsetFor(client, style);
	return offset != 0.0;
}

int FindCustomStyle(int client)
{
	int current = Shavit_GetBhopStyle(client);

	if (IsCamStyle(current) && gB_CustomStyle[current])
	{
		return current;
	}

	int ordered[STYLE_LIMIT];
	Shavit_GetOrderedStyles(ordered, gI_StyleCount);

	for (int i = 0; i < gI_StyleCount; i++)
	{
		int style = ordered[i];

		if (gB_CamStyle[style] && gB_CustomStyle[style] && gB_Selectable[style] && Shavit_HasStyleAccess(client, style))
		{
			return style;
		}
	}

	return -1;
}

void GetStyleName(int style, char[] buffer, int maxlength)
{
	if (0 <= style < gI_StyleCount)
	{
		Shavit_GetStyleSetting(style, "name", buffer, maxlength);
	}
	else
	{
		strcopy(buffer, maxlength, "?");
	}
}

void FormatOffset(float offset, char[] buffer, int maxlength)
{
	float abs = FloatAbs(offset);
	char number[16];

	if (abs == float(RoundToFloor(abs)))
	{
		FormatEx(number, sizeof(number), "%d°", RoundToFloor(abs));
	}
	else
	{
		FormatEx(number, sizeof(number), "%.1f°", abs);
	}

	if (abs == 0.0)
	{
		FormatEx(buffer, maxlength, "%s, off", number);
	}
	else if (abs >= 180.0)
	{
		FormatEx(buffer, maxlength, "%s, backwards", number);
	}
	else
	{
		FormatEx(buffer, maxlength, "%s %s", number, (offset > 0.0) ? "left" : "right");
	}
}

float NormalizeYaw(float yaw)
{
	return yaw - 360.0 * float(RoundToFloor((yaw + 180.0) / 360.0));
}

float SnapZero(float value)
{
	return (FloatAbs(value) < 1.0e-3) ? 0.0 : value;
}
