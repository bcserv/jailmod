
// enforce semicolons after each code statement
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <smlib>
#include <geoip>
#include <config>
#include <stamm>
#include <clientprefs>
#include <basekeyhintbox>

#define PLUGIN_VERSION "0.6"

#define TEAM_PRISONERS	2
#define TEAM_JAILERS 	3

#define PRINT_INTERVAL 1.0

/*****************************************************************


		P L U G I N   I N F O


*****************************************************************/

public Plugin:myinfo = {
	name = "Jail Mod",
	author = "Berni",
	description = "Plugin by Berni",
	version = PLUGIN_VERSION,
	url = "http://www.mannisfunhouse.eu"
}



/*****************************************************************


		G L O B A L   V A R S


*****************************************************************/

// ConVar Handles
new
	Handle:version					= INVALID_HANDLE,
	Handle:jailerPercentage			= INVALID_HANDLE,
	Handle:muteDeads				= INVALID_HANDLE;

// Settings Vars
new
	String:general_servername[64],
	general_maxcapitulations		= 2,
	bool:filter_check_country		= false,
	bool:filter_check_language		= false,
	Handle:filter_allowed_countries	= INVALID_HANDLE,
	Handle:filter_allowed_languages	= INVALID_HANDLE,
	String:filter_kickmessage[128]	= "",
	admin_immunityflags				= ADMFLAG_GENERIC,
	Handle:models_prisoners			= INVALID_HANDLE,
	Handle:models_jailers			= INVALID_HANDLE,
	String:rules_url[256],
	String:rules_lastupdate[32];

// Definitions
new String:spawnClassNames[][]	= {
	"info_player_terrorist",
	"info_player_axis",
	"info_player_rebel"
};

// Misc
new
	bool:firstLoad					= true,
	bool:stamm_supported			= false,
	Handle:jailerSpawns				= INVALID_HANDLE,
	Handle:queue_jailerRequests		= INVALID_HANDLE,
	Handle:cookieJailersBan			= INVALID_HANDLE,
	killedCops						= 0,
	Float:time_roundStart			= 0.0,
	numCapitulations[MAXPLAYERS+1]	= { 0, ... },
	isClientBannedFromJailers[MAXPLAYERS+1] = { false, ... },
	printMessageToAll_exclude		= 0,
	bool:isClientMutedForAlives[MAXPLAYERS+1] = { false, ... };



/*****************************************************************


		P U B L I C   F O R W A R D S


*****************************************************************/

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	MarkNativeAsOptional("IsClientVip");

	return APLRes_Success;
}

public OnPluginStart()
{
	version				= CreateConVar("jailmod_version", PLUGIN_VERSION, "JailMod Version", FCVAR_PLUGIN | FCVAR_NOTIFY | FCVAR_DONTRECORD);
	SetConVarString(version, PLUGIN_VERSION);

	jailerPercentage	= CreateConVar("jailmod_jailerpercentage"	, "43", "Defines the percentage of all players allowed to be in the jailers team", FCVAR_PLUGIN, true, 0.0, true, 100.0);
	muteDeads			= CreateConVar("jailmod_mutedeads", "1", "If to mute mute people when they die or not (will be unmuted on round end), this is not affecting admins");
	
	RegConsoleCmd("sm_kill"					, Command_Kill, "Kill yourself"	, FCVAR_PLUGIN);
	RegAdminCmd("sm_reloadjailmodsettings"	, Command_ReloadJailModSettings	, ADMFLAG_ROOT);
	RegAdminCmd("sm_jban"					, Command_JBan					, ADMFLAG_BAN);

	AddCommandListener(Command_Jointeam, "jointeam");

	HookEvent("player_spawn"	, Event_PlayerSpawn, EventHookMode_Pre);
	HookEvent("player_death"	, Event_PlayerDeath);
	HookEvent("player_team"		, Event_PlayerTeam, EventHookMode_Pre);
	HookEvent("round_start"		, Event_RoundStart);
	HookEvent("round_end"		, Event_RoundEnd);

	HookUserMessage(GetUserMessageId("VGUIMenu"), UserMessageHook_VGUIMenu, true);

	jailerSpawns = CreateArray();
	queue_jailerRequests = CreateArray();

	if (CanTestFeatures() && GetFeatureStatus(FeatureType_Native, "IsClientVip") == FeatureStatus_Available) {
		stamm_supported = true;
	}

	cookieJailersBan = RegClientCookie("jailersban", "Is Client banned from Jailers Team", CookieAccess_Protected);

	LoadTranslations("common.phrases");

	LOOP_CLIENTS(client, CLIENTFILTER_INGAME) {

		if (AreClientCookiesCached(client)) {
			LoadClientCookies(client);
		}

		if (GetConVarBool(muteDeads)) {
			if (!IsPlayerAlive(client) && !HasAdminImmunity(client)) {
				MuteClientForAlives(client, true);
			}
		}
	}

	RegAdminCmd("sm_dvoice", Command_DVoice, ADMFLAG_ROOT);
	RegAdminCmd("sm_dmute", Command_DMute, ADMFLAG_ROOT);
	RegAdminCmd("sm_getcountrybyip", Command_GetCountryByIp, ADMFLAG_ROOT);
}

public Action:Command_DVoice(client, argc)
{
	decl String:arg1[MAX_NAME_LENGTH], String:arg2[MAX_NAME_LENGTH];
	GetCmdArg(1, arg1, sizeof(arg1));
	GetCmdArg(2, arg2, sizeof(arg2));

	new receiver = FindTarget(client, arg1);
	new sender = FindTarget(client, arg2);

	PrintMessage(client, "[DEBUG] GetListenOverride(%N, %N): %d", receiver, sender, GetListenOverride(receiver, sender));

	return Plugin_Handled;
}

public Action:Command_DMute(client, argc)
{
	decl String:arg1[MAX_NAME_LENGTH], String:arg2[MAX_NAME_LENGTH];
	GetCmdArg(1, arg1, sizeof(arg1));
	GetCmdArg(2, arg2, sizeof(arg2));

	new receiver = FindTarget(client, arg1);
	new sender = FindTarget(client, arg2);

	if (GetListenOverride(receiver, sender) == Listen_No) {
		SetListenOverride(receiver, sender, Listen_Default);
		PrintMessage(client, "[DEBUG] %N can hear %N again", receiver, sender);
	}
	else {
		SetListenOverride(receiver, sender, Listen_No);
		PrintMessage(client, "[DEBUG] %N can't hear %N anymore", receiver, sender);
	}

	return Plugin_Handled;
}

public Action:Command_GetCountryByIp(client, argc)
{
	if (argc == 0) {
		decl String:commandName[32];
		GetCmdArg(0, commandName, sizeof(commandName));
		ReplyToCommand(client, "Usage: %s <IP>", commandName);

		return Plugin_Handled;
	}

	decl
		String:ip_string[16],
		String:geoIpCode[3];

	GetCmdArg(1, ip_string, sizeof(ip_string));

	GeoipCode2(ip_string, geoIpCode);
	ReplyToCommand(client, "GeoIP Code of IP \"%s\": \"%s\"", ip_string, geoIpCode);

	return Plugin_Handled;
}

public OnPluginEnd()
{
	if (GetConVarBool(muteDeads)) {
		LOOP_CLIENTS(client, CLIENTFILTER_INGAME) {

			if (isClientMutedForAlives[client]) {
				MuteClientForAlives(client, false);
			}
		}
	}
}

public OnMapStart()
{
	FindJailerSpawns();

	ClearArray(queue_jailerRequests);
	
	LoadSettings(!firstLoad);
	firstLoad = false;
	
	if (models_prisoners != INVALID_HANDLE) {

		decl String:model[PLATFORM_MAX_PATH], size;

		size = GetArraySize(models_prisoners);
		for (new i=0; i < size; i++) {
			GetArrayString(models_prisoners, i, model, sizeof(model));
			PrecacheModel(model, true);
		}

		size = GetArraySize(models_jailers);
		for (new i=0; i < size; i++) {
			GetArrayString(models_jailers, i, model, sizeof(model));
			PrecacheModel(model, true);
		}
	}

	CreateTimer(PRINT_INTERVAL, Timer_PrintStats, 0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	killedCops = 0;
}

public bool:OnClientConnect(client, String:rejectMessage[], size)
{
	if (IsFakeClient(client)) {
		return true;
	}

	isClientBannedFromJailers[client] = false;

	if (!filter_check_country && !filter_check_language) {
		return true;
	}

	if (filter_check_country) {
		decl String:cl_language[32];

		GetClientInfo(client, "cl_language", cl_language, sizeof(cl_language));

		if (FindStringInArray(filter_allowed_languages, cl_language) != -1) {
			return true;
		}
	}

	if (filter_check_language) {
		decl String:ip[16], String:geoIpCode[3];
		
		GetClientIP(client, ip, sizeof(ip));
		
		if (!GeoipCode2(ip, geoIpCode)) {
			// No geocode found, we are allowing the client to join in this case...
			return true;
		}

		if (FindStringInArray(filter_allowed_countries, geoIpCode) != -1) {
			return true;
		}
	}

	strcopy(rejectMessage, size, filter_kickmessage);

	return false;
}

public OnClientPostAdminCheck(client)
{
	if (GetConVarBool(muteDeads)) {
		if (!IsPlayerAlive(client) && !HasAdminImmunity(client)) {
			MuteClientForAlives(client, true);
		}
	}
}

public OnClientPutInServer(client)
{
	ShowWelcomeMenu(client);

	//decl clients[MaxClients];
	//new numClients = Client_Get(clients, CLIENTFILTER_ALIVE);
}

public OnClientDisconnect(client)
{
	RemoveJailerJoinRequest(client);
}

public OnClientCookiesCached(client)
{
	LoadClientCookies(client);
}



/****************************************************************


		C O M M A N D S  &  G L O B A L   C A L L B A C K S


****************************************************************/

public Action:UserMessageHook_VGUIMenu(UserMsg:msg_id, Handle:bf, const players[], playersNum, bool:reliable, bool:init)
{
	decl String:type[16];
	BfReadString(bf, type, sizeof(type));

	if (strncmp(type, "class_", 6) == 0) {

		for (new i=0; i < playersNum; i++) {
			FakeClientCommandEx(players[i], "joinclass 0");
		}

		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public Action:Timer_PrintStats(Handle:timer)
{
	PrintStats();

	return Plugin_Continue;
}

public Action:Command_Kill(client, argc)
{
	if (!IsPlayerAlive(client)) {
		PrintError(client, "Das wuerde jetzt keinen Sinn machen...");
		return Plugin_Handled;
	}

	Color_ChatSetSubject(client);
	PrintMessageToAll(true, "{T}%N {G}hat sich selbst terminiert!", client);

	ForcePlayerSuicide(client);

	return Plugin_Handled;
}

public Action:Command_Jail(client, argc)
{
	if (GetClientTeam(client) != TEAM_JAILERS) {
		ReplyToCommand(client, "Error: Dieser Befehl kann nur von Polizisten ausgeführt werden.");
		return Plugin_Handled;
	}
	
	new target = GetClientAimTarget(client, true);
	
	if (target < 0) {
		PrintToChat(client, "Error: Du musst jemanden anvisieren.");
		return Plugin_Handled;
	}
	
	if (!Entity_InRange(client, target, 100.0)) {
		PrintToChat(client, "Error: The prisoner has to be very close to you to jail him.");
		return Plugin_Handled;
	}

	Jail(target);
	
	PrintToChat(client, "\x04Du hast %N in den Knast geschickt!", target);
	PrintToChat(client, "\x04%N hat dich zurück in den Knast geschickt!", client);

	return Plugin_Handled;
}

public Action:Command_JoinJailers(client, argc)
{
	if (GetClientTeam(client) == TEAM_JAILERS) {
		ReplyToCommand(client, "Error: Du bist bereits ein Cop");
		return Plugin_Handled;
	}

	if (FindValueInArray(queue_jailerRequests, client) == -1) {
		ShowJailerRequestMenu(client);
	}
	else {
		RemoveJailerJoinRequest(client);
	}

	return Plugin_Handled;
}

public Action:Command_Rules(client, argc)
{
	ShowRules(client);

	return Plugin_Handled;
}

public Action:Command_Deny_(client, argc)
{
	return Plugin_Handled;
}

public Action:Command_Games(client, argc)
{
	return Plugin_Handled;
}

public Action:Command_Capitulate(client, argc)
{
	if (GetClientTeam(client) != TEAM_PRISONERS) {
		PrintError(client, "Nur Gefangene koennen diesen Befehl benutzen");
		return Plugin_Handled;
	}

	if (!IsPlayerAlive(client)) {
		PrintError(client, "Das wuerde jetzt keinen Sinn machen...");
		return Plugin_Handled;
	}

	if (numCapitulations[client] >= general_maxcapitulations) {
		PrintError(client, "Du kannst pro Runde nur %dx kapitulieren!", general_maxcapitulations);
		printMessageToAll_exclude = client;
		PrintMessageToAll(true, "Gefangener {R}%N {G}kann nicht mehr kapitulieren (max %dx pro Runde)", client, general_maxcapitulations);
		return Plugin_Handled;
	}

	PrintMessageToAll(true, "Gefangener {R}%N {G}kapituliert ! Alle Waffen werden ihm weggenommmen...", client);
	Client_RemoveAllWeapons(client, "weapon_knife");

	numCapitulations[client]++;

	return Plugin_Handled;
}

public Action:Command_ReloadJailModSettings(client, argc)
{
	LoadSettings();

	return Plugin_Handled;
}

public Action:Command_JBan(client, argc)
{
	if (argc < 1) {
		PrintError(client, "Syntax: sm_jban <target> [0|1]");
		return Plugin_Handled;
	}

	decl
		String:target[MAX_TARGET_LENGTH],
		String:target_name[MAX_TARGET_LENGTH],
		target_list[MaxClients],
		bool:tn_is_ml,
		String:arg2[2] = "",
		bool:ban;

	GetCmdArg(1, target, sizeof(target));

	if (argc >= 2) {
		GetCmdArg(2, arg2, sizeof(arg2));
	}

	new target_count = ProcessTargetString(
			target, client,
			target_list, MaxClients,
			COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_BOTS,
			target_name, sizeof(target_name),
			tn_is_ml
	);

	if (target_count < 1) {
		ReplyToTargetError(client, target_count);
	}

	for (new i=0; i < target_count; i++) {
		new player = target_list[i];

		ban = ((arg2[0] != '0' && arg2[0] != '\0') || (arg2[0] == '\0' && !isClientBannedFromJailers[player]));

		if (ban && isClientBannedFromJailers[player]) {
			Color_ChatSetSubject(player);
			PrintError(client, "Spieler {T}%N {G}ist bereits vom Cop-Team gebannt", player);
			continue;
		}
		else if (!ban && !isClientBannedFromJailers[player]) {
			Color_ChatSetSubject(player);
			PrintError(client, "Spieler {T}%N {G}ist nicht vom Cop-Team gebannt", player);
			continue;
		}

		if (ban) {
			SetClientCookie(player, cookieJailersBan, "banned");
			isClientBannedFromJailers[player] = true;

			PrintMessage(player, "{R}Du wurdest vom {OG}Cop-Team {R}gebannt");
			printMessageToAll_exclude = player;
			Color_ChatSetSubject(client);
			PrintMessageToAll(true, "Spieler {T}%N {G}wurde vom {OG}Cop-Team {G}gebannt", player);

			if (GetClientTeam(player) == TEAM_JAILERS) {
				ChangeClientTeam(player, TEAM_PRISONERS);
			}
		}
		else {
			SetClientCookie(player, cookieJailersBan, "");
			isClientBannedFromJailers[player] = false;

			PrintMessage(player, "Du darfst nun wieder in das {OG}Cop-Team");
			printMessageToAll_exclude = player;
			Color_ChatSetSubject(client);
			PrintMessageToAll(true, "Spieler {T}%N {G}darf nun wieder in das {OG}Cop-Team", player);
		}
	}

	return Plugin_Handled;
}

public Action:Command_Jointeam(client, String:command[], argc)
{
	decl String:arg1[2];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	new prefTeam = StringToInt(arg1);

	if (prefTeam == 3) {
		ShowJailerRequestMenu(client);
		return Plugin_Handled;
	}
	else if (prefTeam == 0) {
		ChangeClientTeam(client, TEAM_PRISONERS);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));

	new Handle:models = INVALID_HANDLE;

	if (stamm_supported && IsClientVip(client, 2)) {
		return Plugin_Continue;
	}

	switch (GetClientTeam(client)) {
		case TEAM_PRISONERS: {
			models = models_prisoners;
		}
		case TEAM_JAILERS: {
			models = models_jailers;
		}
	}

	if (models != INVALID_HANDLE) {
		new size = GetArraySize(models);

		if (size > 0) {
			decl String:model[PLATFORM_MAX_PATH];

			GetArrayString(models, Math_GetRandomInt(0, size-1), model, sizeof(model));
			Entity_SetModel(client, model);
		}
	}

	if (GetConVarBool(muteDeads)) {
		if (isClientMutedForAlives[client]) {
			MuteClientForAlives(client, false);
		}
	}

	return Plugin_Continue;
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client		= GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker	= GetClientOfUserId(GetEventInt(event, "attacker"));

	new team = GetClientTeam(client);

	if (team == TEAM_JAILERS) {

		if (client != attacker && attacker != 0) {
			killedCops++;
		}
	}

	new numPrisoners, numJailers;
	Team_GetClientCounts(numPrisoners, numJailers, CLIENTFILTER_ALIVE);

	decl String:mutedText[128] = "";

	if (numPrisoners > 0 && numJailers > 0) {
		if (numJailers == 1 && team == TEAM_JAILERS) {
			new clients[1];
			new numClients = Client_Get(clients, CLIENTFILTER_TEAMTWO | CLIENTFILTER_ALIVE);
			new player = clients[0];

			if (numClients == 1) {
				PrintMessage(player, "{G}Du bist der letzte Cop. {R}Es sind noch {OG}%d {B}Gefangene uebrig%s", numPrisoners, (killedCops >= 2 ? " (Du darfst alle toeten)" : "" ));

				if (killedCops >= 2) {
					printMessageToAll_exclude = player;
					PrintMessageToAll(true, "{OG}%N {G}darf alle {R}Gefangenen {G}toeten da er/sie der letzte Cop ist ({R}%d {G}Cops wurden getoetet)", player, killedCops);
				}
			}
		}
		else if (numPrisoners == 1 && team == TEAM_PRISONERS) {
			new clients[1];
			new numClients = Client_Get(clients, CLIENTFILTER_TEAMONE | CLIENTFILTER_ALIVE);

			if (numClients == 1) {
				PrintMessageToAll(true, "{R}%N {G}hat nun {R}einen Wunsch {G}frei wenn er die letzten Anweisungen der Cops richtig befolgt hat", clients[0]);
			}
		}

		if (GetConVarBool(muteDeads)) {
			if (!HasAdminImmunity(client)) {
				Format(mutedText, sizeof(mutedText), "\n{R}Du bist nun fuer die Lebenden {OG}bis zum Ende der Runde {R}nicht mehr hoerbar (Voice)");
				MuteClientForAlives(client, true);
			}

			// Let already dead players talk to him again
			LOOP_CLIENTS(deadClient, CLIENTFILTER_DEAD) {

				if (isClientMutedForAlives[deadClient]) {
					SetListenOverride(client, deadClient, Listen_Default);
				}
			}
		}
	}

	if (attacker != 0 && attacker != client && team == TEAM_PRISONERS) {
		PrintMessage(client, "Du wurdest von {OG}Cop {G}%N {R}getoetet%s", attacker, mutedText);
	}

	PrintStats();

	return Plugin_Continue;
}

public Action:Event_PlayerTeam(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client		= GetClientOfUserId(GetEventInt(event, "userid"));
	new team		= GetEventInt(event, "team");
	new bool:silent	= GetEventBool(event, "silent");

	if (!silent) {
		if (team == TEAM_JAILERS) {
			PrintMessage(client, "Du bist dem {OG}Cop-Team {G}beigetreten. {R}Befolge die Regeln {G}und bleib {R}fair");
			printMessageToAll_exclude = client;
			PrintMessageToAll(false, "{B}%N {G}spielt nun bei den {B}Cops", client);
			return Plugin_Handled;
		}
		else if (team == TEAM_PRISONERS) {
			PrintMessageToAll(false, "{R}%N {G}spielt nun bei den {R}Gefangenen", client);
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

public Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	killedCops = 0;
	time_roundStart = GetGameTime();

	Array_Fill(numCapitulations, sizeof(numCapitulations), 0);
}

public Action:Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{	
	CheckJailerJoinRequests();

	if (GetConVarBool(muteDeads)) {
		LOOP_CLIENTS(client, CLIENTFILTER_INGAME) {

			if (isClientMutedForAlives[client]) {
				MuteClientForAlives(client, false);
			}
		}
	}
}

public MenuHandler_JailerRequestMenu(Handle:menu, MenuAction:action, param1, param2)
{
	new client = param1;

	if (action == MenuAction_Select || action == MenuAction_Cancel) {

		if (!IsClientInGame(client)) {
			return;
		}
	}

	/* If an option was selected, tell the client about the item. */
	if (action == MenuAction_Select) {
		new String:info[16];
		GetMenuItem(menu, param2, info, sizeof(info));

		if (StrEqual(info, "showrules")) {
			ShowRules(client);
		}
		else if (StrEqual(info, "accept")) {
			JailerJoinRequest(client);
			return;
		}

		ShowJailerRequestMenu(client);
	}
	else if (action == MenuAction_Cancel) {

		if (GetClientTeam(client) <= 1) {
			ChangeClientTeam(client, TEAM_PRISONERS);
		}
	}
	/* If the menu has ended, destroy it */
	else if (action == MenuAction_End) {
		CloseHandle(menu);
	}
}

public MenuHandler_WelcomeMenu(Handle:menu, MenuAction:action, param1, param2)
{
	new client = param1;

	/* If an option was selected, tell the client about the item. */
	if (action == MenuAction_Select) {
		new String:info[16];
		GetMenuItem(menu, param2, info, sizeof(info));

		if (StrEqual(info, "showrules")) {
			ShowRules(client);
		}
	}
	/* If the menu has ended, destroy it */
	else if (action == MenuAction_End) {
		CloseHandle(menu);
	}
}



/*****************************************************************


		P L U G I N   F U N C T I O N S


*****************************************************************/

PrintStats()
{
	new
		numPrisoners = 0,
		numPrisonersAlive = 0,
		numJailers = 0,
		numJailersAlive  =0;

	LOOP_CLIENTS(client, CLIENTFILTER_INGAME) {

		new team = GetClientTeam(client);

		if (team == TEAM_PRISONERS) {
			numPrisoners++;

			if (IsPlayerAlive(client)) {
				numPrisonersAlive++;
			}
		}
		else if (team == TEAM_JAILERS) {
			numJailers++;
			
			if (IsPlayerAlive(client)) {
				numJailersAlive++;
			}
		}
	}

	decl String:mutedText[64] = "";

	

	new Float:secs = GetGameTime() - time_roundStart;
	new mins_left = RoundToFloor(secs / 60);
	new secs_left = RoundFloat(secs) % 60;

	decl String:buffer[253], String:buffer_muted[253];
	Format(
		buffer, sizeof(buffer),
		"%sCops:                  %d / %d\nGefangene:         %d / %d\nGetoetete Cops:  %d",
		mutedText, numJailersAlive, numJailers, numPrisonersAlive, numPrisoners, killedCops
	);

	Format(buffer_muted, sizeof(buffer_muted), "Du bist fuer die Lebenden gemuted\n\n%s", buffer);

	if (time_roundStart > 0.0) {
		Format(buffer, sizeof(buffer), "%s\nZeit vergangen:   %d:%02.d", buffer, mins_left, secs_left);
	}

	LOOP_CLIENTS(client, CLIENTFILTER_INGAME) {

		if (GetConVarBool(muteDeads) && isClientMutedForAlives[client]) {
			BaseKeyHintBox_PrintToClient(client, PRINT_INTERVAL, buffer_muted);
		}
		else {
			BaseKeyHintBox_PrintToClient(client, PRINT_INTERVAL, buffer);
		}
	}
}

FindJailerSpawns()
{
	ClearArray(jailerSpawns);

	new entity = INVALID_ENT_REFERENCE;
	for (new i=0; i < sizeof(spawnClassNames); i++) {
		while ((entity = FindEntityByClassname(entity, spawnClassNames[i])) != INVALID_ENT_REFERENCE) {
			PushArrayCell(jailerSpawns, entity);
		}
	}

	while ((entity = FindEntityByClassname(entity, "info_player_teamspawn")) != INVALID_ENT_REFERENCE) {

		if (GetEntProp(entity, Prop_Data, "m_iInitialTeamNum") == TEAM_PRISONERS) {
			PushArrayCell(jailerSpawns, entity);
		}
	}
}

Jail(client)
{
	new arraySize = GetArraySize(jailerSpawns);
	
	if (arraySize == 0) {
		return;
	}

	new arrayIndex = Math_GetRandomInt(0, arraySize);
	new spawnPoint = GetArrayCell(jailerSpawns, arrayIndex);

	decl Float:origin[3];
	Entity_GetAbsOrigin(spawnPoint, origin);
	
	TeleportEntity(client, origin, NULL_VECTOR, NULL_VECTOR);
	Client_RemoveAllWeapons(client, "weapon_knife");
}

JailerJoinRequest(client)
{
	if (!HasAdminImmunity(client)) {

		if (!IsJailerSlotFree()) {
			new bool:isVip = (stamm_supported && IsClientVip(client, 0));

			new size = GetArraySize(queue_jailerRequests);
			new n = 0;
			
			if (isVip) {

				while (n < size) {

					if (!IsClientVip(GetArrayCell(queue_jailerRequests, n), 0)) {
						break;
					}

					n++;
				}

				if (n < size) {
					ShiftArrayUp(queue_jailerRequests, n);
					SetArrayCell(queue_jailerRequests, n, client);
				}
				else {
					n = PushArrayCell(queue_jailerRequests, client);
				}
			}
			else {
				n = PushArrayCell(queue_jailerRequests, client);
			}

			PrintMessage(
				client,
				"Du wurdest in der {RB}Cop-Warteschlange {G}eingereiht (Position %d von %d), schreibe {RB}/cop {G}in den Chat um dich wieder aus der Warteschlange zu entfernen",
				n+1,
				size+1
			);
			return;
		}
	}

	ChangeClientTeam(client, TEAM_JAILERS);
}

RemoveJailerJoinRequest(client)
{
	new index = FindValueInArray(queue_jailerRequests, client);
	
	if (index == -1) {
		return;
	}

	RemoveFromArray(queue_jailerRequests, index);
	PrintMessage(client, "Du wurdest aus der Cop-Warteschlange entfernt");
}

CheckJailerJoinRequests()
{
	new numJailers = Team_GetClientCount(TEAM_JAILERS);
	new numPrisoners = Team_GetClientCount(TEAM_PRISONERS);
	new Float:allowedPercentage = GetConVarFloat(jailerPercentage);

	new numSlotsFree;
	
	if (numJailers == 0) {
		numSlotsFree = 1;
	}
	else {
		numSlotsFree = RoundToFloor(allowedPercentage / (100.0 / float(numPrisoners))) - numJailers;
	}

	new size = GetArraySize(queue_jailerRequests);
	for (new i=0; i < size; i++) {

		new client = GetArrayCell(queue_jailerRequests, i);

		if (i > numSlotsFree) {
			PrintMessage(client, "Du bist auf {OG}Position %d von %d {G}in der {OG}Cop-Warteschlange", i+1, size);
			continue;
		}

		ChangeClientTeam(client, TEAM_JAILERS);
		RemoveFromArray(queue_jailerRequests, i--);

		if (i == -1) {
			break;
		}
	}
}

HasAdminImmunity(client)
{
	//return false;
	return Client_HasAdminFlags(client, admin_immunityflags);
}

LoadSettings(bool:reload=true)
{
	decl String:errorMessage[64], String:path[PLATFORM_MAX_PATH];
	new errorLine;

	BuildPath(Path_SM, path, sizeof(path), "configs/jailmod.cfg");
	
	new Handle:config = ConfigCreate();

	if (!ConfigReadFile(config, path, errorMessage, sizeof(errorMessage), errorLine)) {
		LogError("Can't read config file \"%s\" (Error: \"%s\" on line %d)", path, errorMessage, errorLine);
		return;
	}
	
	
	ConfigLookupString(config, "general.servername", general_servername, sizeof(general_servername));
	general_maxcapitulations = ConfigLookupInt(config, "general.max_capitulations");

	// Filters
	filter_check_country	= ConfigLookupBool(config, "filter.check_country");
	filter_check_language	= ConfigLookupBool(config, "filter.check_language");

	if (filter_check_country) {
		ConfigStringArrayToAdtArray(config, "filter.allowed_countries", filter_allowed_countries, 3);
	}
	
	if (filter_check_language) {
		ConfigStringArrayToAdtArray(config, "filter.allowed_languages", filter_allowed_languages, 32);
	}
	
	ConfigLookupString(config, "filter.kickmessage", filter_kickmessage, sizeof(filter_kickmessage));

	// Admin
	decl String:strAdminImmunityFlags[22];
	if (ConfigLookupString(config, "admin.immunityflags", strAdminImmunityFlags, sizeof(strAdminImmunityFlags))) {
		admin_immunityflags = ReadFlagString(strAdminImmunityFlags);
	}

	ConfigStringArrayToAdtArray(config, "models.prisoners"	, models_prisoners	, PLATFORM_MAX_PATH);
	ConfigStringArrayToAdtArray(config, "models.jailers"	, models_jailers	, PLATFORM_MAX_PATH);

	ConfigLookupString(config, "rules.url"			, rules_url, sizeof(rules_url));
	ConfigLookupString(config, "rules.lastupdate"	, rules_lastupdate, sizeof(rules_lastupdate));

	new Handle:downloads = ConfigLookup(config, "downloads");

	if (downloads != INVALID_HANDLE) {
		decl String:download[PLATFORM_MAX_PATH];

		new size = ConfigSettingLength(downloads);
		for (new i=0; i < size; i++) {
			ConfigSettingGetStringElement(downloads, i, download, sizeof(download));
			File_AddToDownloadsTable(download);
		}
	}

	if (!reload) {
		RegisterJailerCommand(config, "commands.joinjailers", Command_JoinJailers	, "");
		RegisterJailerCommand(config, "commands.rules"		, Command_Rules			, "");
		RegisterJailerCommand(config, "commands.deny"		, Command_Deny_			, "");
		RegisterJailerCommand(config, "commands.games"		, Command_Games			, "");
		RegisterJailerCommand(config, "commands.capitulate"	, Command_Capitulate	, "");
	}

	CloseHandle(config);
}

ConfigStringArrayToAdtArray(Handle:config, const String:path[], &Handle:adtArray, size, bool:clearArray=true)
{
	new Handle:config_array = ConfigLookup(config, path);

	if (config_array == INVALID_HANDLE) {
		return -1;
	}

	if (adtArray == INVALID_HANDLE) {
		adtArray = CreateArray(size);
	}

	if (clearArray) {
		ClearArray(adtArray);
	}

	decl String:buffer[size];
	
	new aSize = ConfigSettingLength(config_array);
	for (new i=0; i < aSize; i++) {
		ConfigSettingGetStringElement(config_array, i, buffer, size);
		PushArrayString(adtArray, buffer);
	}

	return size;
}

RegisterJailerCommand(Handle:config, const String:path[], ConCmd:callback, const String:description[])
{
	decl String:buffer[32];
	new size;

	new Handle:config_array = ConfigLookup(config, path);


	size = ConfigSettingLength(config_array);
	for (new i=0; i < size; i++) {
		ConfigSettingGetStringElement(config_array, i, buffer, sizeof(buffer));
		Format(buffer, sizeof(buffer), "sm_%s", buffer);
		RegConsoleCmd(buffer, callback, description, FCVAR_PLUGIN);
	}
}

ShowJailerRequestMenu(client)
{
	if (GetClientTeam(client) == TEAM_JAILERS) {
		PrintError(client, "Du bist bereits im Cop-Team");
		return;
	}

	if (isClientBannedFromJailers[client]) {

		if (GetClientTeam(client) <= 1) {
			ChangeClientTeam(client, TEAM_PRISONERS);
		}

		PrintError(client, "Du bist vom {OG}Cop-Team {G}gebannt");
		return;
	}

	new pos = FindValueInArray(queue_jailerRequests, client);
	if (pos != -1) {
		PrintError(client, "Du bist bereits in der Cop-Warteschlange (Position %d von %d)", pos+1, GetArraySize(queue_jailerRequests));
		return;
	}

	decl String:message_rules[128];
	Format(message_rules, sizeof(message_rules), "Ich habe die Regeln gelesen - Regeln anzeigen (zuletzt aktualisiert am %s)", rules_lastupdate);

	new Handle:menu = CreateMenu(MenuHandler_JailerRequestMenu);
	AddMenuItem(menu, "", "", ITEMDRAW_SPACER);
	SetMenuTitle(menu, "Du willst dem Cop-Team beitreten...");
	AddMenuItem(menu, "showrules",	message_rules);
	AddMenuItem(menu, "headset",	"Ich besitze ein rauschfreies Headset und kann klare Ansagen machen");
	AddMenuItem(menu, "", "", ITEMDRAW_SPACER);
	AddMenuItem(menu, "accept", 	"Bestaetigen", ITEMDRAW_CONTROL);
	AddMenuItem(menu, "", "", ITEMDRAW_SPACER);

	if (!IsJailerSlotFree()) {
		decl String:info[256];
		Format(
			info, sizeof(info),
			"Info: Das Cop-Team ist bereits voll (%d%%), du wirst in der Warteschlange eingereiht bis ein Platz frei wird (Stammspieler haben Vorrang)", 
			RoundToNearest(GetConVarFloat(jailerPercentage))
		);

		new jailerQueueSize = GetNumPlayersInJailersQueue();
		if (jailerQueueSize > 0) {
			decl String:queueMessage[64];

			Format(queueMessage, sizeof(queueMessage), "\n             %d Spieler in der Warteschlange", GetNumPlayersInJailersQueue());

			if (stamm_supported) {
				Format(queueMessage, sizeof(queueMessage), "%s (davon %d Stammspieler)", queueMessage, GetNumVIPPlayersinQueue());
			}

			StrCat(info, sizeof(info), queueMessage);
		}

		AddMenuItem(menu, "", info, ITEMDRAW_DISABLED);
	}

	SetMenuExitButton(menu, true);
	DisplayMenu(menu, client, 240);
}

ShowWelcomeMenu(client)
{
	decl String:buffer[128];

	new Handle:menu = CreateMenu(MenuHandler_WelcomeMenu);
	AddMenuItem(menu, "", "", ITEMDRAW_SPACER);
	Format(buffer, sizeof(buffer), "Willkommen auf %s, %N", general_servername, client);
	SetMenuTitle(menu, buffer);
	Format(buffer, sizeof(buffer), "Jailserver-Regeln anzeigen (zuletzt aktualisiert am %s)", rules_lastupdate);
	AddMenuItem(menu, "showrules",	buffer);
	AddMenuItem(menu, "", "", ITEMDRAW_SPACER);
	AddMenuItem(menu, "", "", ITEMDRAW_SPACER);
	Format(buffer, sizeof(buffer), "Wir wuenschen dir viel Spass auf diesem Server %N !", client);
	AddMenuItem(menu, "", buffer, ITEMDRAW_DISABLED);

	SetMenuPagination(menu,MENU_NO_PAGINATION);
	SetMenuExitButton(menu, true);
	DisplayMenu(menu, client, 60);
}

ShowRules(client)
{
	ShowMOTDPanel(client, "", rules_url, MOTDPANEL_TYPE_URL);
}

IsJailerSlotFree()
{
	new numJailers = Team_GetClientCount(TEAM_JAILERS);
	new numPrisoners = Team_GetClientCount(TEAM_PRISONERS);

	if (numJailers == 0) {
		return true;
	}

	new Float:allowedPercentage = GetConVarFloat(jailerPercentage);

	return bool:(Math_GetPercentageFloat(float(numJailers+1), float(numPrisoners)) <= allowedPercentage);
}

PrintError(client, const String:format[], any:...)
{
	decl String:buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);
	Format(buffer, sizeof(buffer), "{RB}[JailMod] {RB}Error: {G}%s", buffer);

	Client_PrintToChat(client, true, buffer);
}

PrintMessage(client, const String:format[], any:...)
{
	decl String:buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);
	Format(buffer, sizeof(buffer), "{RB}[JailMod] {G}%s", buffer);

	Client_PrintToChat(client, true, buffer);
}

PrintMessageToAll(prefix=true, const String:format[], any:...)
{
	decl
		String:myFormat[512],
		String:buffer[512],
		String:buffer2[253],
		subject;

	Format(myFormat, sizeof(myFormat), (prefix ? "{RB}[JailMod] {G}%s" : "{G}%s"), format);

	new x=0;
	LOOP_CLIENTS(client, CLIENTFILTER_INGAME) {

		if (client == printMessageToAll_exclude) {
			continue;
		}

		SetGlobalTransTarget(client);
		VFormat(buffer2, sizeof(buffer2), myFormat, 3);
		subject = Color_ParseChatText(buffer2, buffer, sizeof(buffer));

		Client_PrintToChatRaw(client, buffer, subject, true);
		x++;
	}

	/*new dev = Client_FindByName("Berni");

	if (dev != -1) {
		PrintToChat(dev, "\x01\x04[DEBUG] message, num: %d", x);
	}*/

	Color_ChatClearSubject();
	printMessageToAll_exclude = 0;
}

GetNumPlayersInJailersQueue()
{
	return GetArraySize(queue_jailerRequests);
}

GetNumVIPPlayersinQueue()
{
	new count = 0;

	new size = GetArraySize(queue_jailerRequests);
	for (new i=0; i < size; i++) {

		if (IsClientVip(GetArrayCell(queue_jailerRequests, i), 2)) {
			count++;
		}
	}

	return count;
}

LoadClientCookies(client)
{
	decl String:setting[8];
	GetClientCookie(client, cookieJailersBan, setting, sizeof(setting));

	if (StrEqual(setting, "banned")) {
		isClientBannedFromJailers[client] = true;

		if (IsClientInGame(client)) {
			if (GetClientTeam(client) == TEAM_JAILERS) {
				PrintMessage(client, "Du bist vom {OG}Cop-Team {R}gebannt {G}und spielst nun bei den {R}Gefangenen");
				ChangeClientTeam(client, TEAM_PRISONERS);
			}
		}
	}
}

MuteClientForAlives(client, bool:mute)
{
	if (GetConVarBool(muteDeads)) {
		if (mute) {
			LOOP_CLIENTS(alive, CLIENTFILTER_ALIVE) {
				SetListenOverride(alive, client, Listen_No);
			}
		}
		else {
			LOOP_CLIENTS(player, CLIENTFILTER_INGAME) {
				SetListenOverride(player, client, Listen_Default);
			}
		}

		isClientMutedForAlives[client] = mute;
	}
}
