--[[----------------------------------------------------------------------------
	MPRNLSsh.lua

	Exécution de commandes sur le serveur distant, après l'upload FTP.

	Lightroom n'a pas d'API SSH native : on délègue à `plink.exe` (client en
	ligne de commande fourni avec PuTTY), lancé via LrTasks.execute().

	Pourquoi plink ?
	  - le client OpenSSH de Windows ne permet pas de fournir un mot de passe
	    en ligne de commande (authentification par clé uniquement) ;
	  - plink accepte `-pwfile` (mot de passe lu depuis un fichier) et `-m`
	    (commandes lues depuis un fichier), ce qui évite tout problème
	    d'échappement avec le shell Windows.

	PuTTY 0.77 ou plus récent est requis pour `-pwfile`. Sur une version plus
	ancienne, le module retente automatiquement avec `-pw`.
--]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local MPRNLSsh = {}

--=============================================================================
-- COMMANDES À EXÉCUTER SUR LE SERVEUR APRÈS L'EXPORT
--
-- Chaque ligne est une commande shell, exécutée dans la même session SSH.
-- Elles sont envoyées à plink via un fichier (`-m`), donc pas de souci
-- d'échappement : écris-les exactement comme dans un terminal.
--
-- Variables de substitution disponibles :
--   {remote_path} : dossier choisi pour l'export (ex. /Photos/2024)
--   {ftp_host}    : hôte du serveur FTP
--   {date}        : date du jour, format AAAA-MM-JJ
--=============================================================================

MPRNLSsh.COMMANDS = {
	"cd cloud.mprnl.fr && ./occ files:scan --all",
}


--=============================================================================
-- Détection de plink.exe
--=============================================================================

local function detectPlinkImpl()
	local candidates = {}

	-- Lettre de lecteur système, déduite du dossier personnel (ex. « C: »).
	-- (os.getenv n'existe pas dans l'environnement Lua de Lightroom.)
	local home = LrPathUtils.getStandardFilePath( 'home' ) or ''
	local drive = home:match( '^(%a:)' )

	if drive then
		candidates[ #candidates + 1 ] = drive .. '\\Program Files\\PuTTY\\plink.exe'
		candidates[ #candidates + 1 ] = drive .. '\\Program Files (x86)\\PuTTY\\plink.exe'
		candidates[ #candidates + 1 ] = drive .. '\\Program Files\\PuTTY\\PLINK.EXE'
		candidates[ #candidates + 1 ] = drive .. '\\Program Files (x86)\\PuTTY\\PLINK.EXE'
	end

	-- Installation « utilisateur » : %LOCALAPPDATA%\Programs\PuTTY\plink.exe
	-- (« appData » pointe sur ...\AppData\Roaming ; on remplace par « Local ».)
	local appData = LrPathUtils.getStandardFilePath( 'appData' ) or ''
	local localAppData = appData:gsub( '\\Roaming$', '\\Local' )
	if localAppData ~= appData and localAppData ~= '' then
		candidates[ #candidates + 1 ] = localAppData .. '\\Programs\\PuTTY\\plink.exe'
	end

	-- Emplacement d'installation par défaut de Windows.
	candidates[ #candidates + 1 ] = 'C:\\Program Files\\PuTTY\\plink.exe'

	for _, path in ipairs( candidates ) do
		if LrFileUtils.exists( path ) == 'file' then
			return path
		end
	end

	return nil
end

-- Version protégée : une erreur inattendue ici ne doit jamais empêcher le
-- chargement du plugin (c'est arrivé une fois avec os.getenv, absent du
-- l'environnement Lua de Lightroom).
function MPRNLSsh.detectPlink()
	local ok, result = pcall( detectPlinkImpl )
	if ok then
		return result
	end
	return nil
end


--=============================================================================
-- Fichiers temporaires
--=============================================================================

local function tempDirectory()
	local directory = LrPathUtils.getStandardFilePath( 'temp' )
	if directory and directory ~= '' then
		return directory
	end

	-- Repli : dossier du fichier temporaire système.
	local name = os.tmpname()
	if name then
		return LrPathUtils.parent( name ) or '.'
	end

	return '.'
end

local function tempFilePath( extension )
	local base = LrPathUtils.child( tempDirectory(), 'mprnl-tmp.' .. extension )
	-- Garantit un nom libre (ajoute un suffixe si le fichier existe déjà).
	return LrFileUtils.chooseUniqueFileName( base )
end

local function writeTempFile( path, content )
	local file, err = io.open( path, 'wb' )
	if not file then
		return false, err
	end
	file:write( content )
	file:close()
	return true
end

--=============================================================================
-- Construction et exécution de la commande plink
--=============================================================================

local function quote( value )
	return '"' .. tostring( value ) .. '"'
end

-- Exécute une commande et renvoie sa sortie (stdout + stderr réunis).
local function runCapture( command, outputPath )
	LrFileUtils.delete( outputPath )

	local status = LrTasks.execute( command .. ' > ' .. quote( outputPath ) .. ' 2>&1' )

	local output = ''
	if LrFileUtils.exists( outputPath ) then
		output = LrFileUtils.readFile( outputPath ) or ''
	end
	LrFileUtils.delete( outputPath )

	return status, output
end

--=============================================================================
-- Clé d'hôte du serveur
--
-- plink refuse de se connecter à un serveur dont la clé est inconnue, et sa
-- question interactive NE PEUT PAS être alimentée par l'entrée standard
-- redirigée : plink reste alors bloqué indéfiniment (vérifié sur plink 0.85).
--
-- On récupère donc la clé avec `ssh-keyscan` (fourni avec Windows 10+) et on
-- la transmet à plink via `-hostkey`. On peut ainsi garder `-batch` : aucune
-- question, donc aucun blocage possible.
--=============================================================================

local function fetchHostKeys( settings )
	local host = tostring( settings.host or '' )
	local port = tostring( settings.port or 22 )
	if host == '' then
		return {}
	end

	local _, output = runCapture(
		'ssh-keyscan -T 8 -p ' .. port .. ' ' .. host,
		tempFilePath( 'keys' )
	)

	-- Repli : chemin explicite de l'OpenSSH livré avec Windows.
	if output == '' then
		local _, retryOutput = runCapture(
			quote( 'C:\\Windows\\System32\\OpenSSH\\ssh-keyscan.exe' )
				.. ' -T 8 -p ' .. port .. ' ' .. host,
			tempFilePath( 'keys' )
		)
		output = retryOutput
	end

	local keys = {}
	for line in tostring( output ):gmatch( '[^\r\n]+' ) do
		line = line:gsub( '^%s+', '' ):gsub( '%s+$', '' )
		if line ~= '' and line:sub( 1, 1 ) ~= '#' then
			-- Format : « hôte type-de-clé base64 »
			local keyType, keyData = line:match( '^%S+%s+(%S+)%s+(%S+)$' )
			if keyType and keyData then
				keys[ #keys + 1 ] = keyType .. ' ' .. keyData
			end
		end
	end

	return keys
end

local function buildCommand( settings, usePwfile, passwordPath, commandPath, outputPath )
	local parts = {}

	local function add( ... )
		local values = { ... }
		for _, value in ipairs( values ) do
			parts[ #parts + 1 ] = value
		end
	end

	add( quote( settings.plinkPath ) )
	-- Toujours en mode batch : plink ne posera aucune question. La clé d'hôte
	-- est fournie via -hostkey (voir fetchHostKeys).
	add( '-ssh', '-batch' )
	add( '-P', tostring( settings.port or 22 ) )
	add( '-l', quote( settings.username ) )

	if usePwfile then
		add( '-pwfile', quote( passwordPath ) )
	else
		add( '-pw', quote( settings.password or '' ) )
	end

	for _, key in ipairs( settings.hostKeys or {} ) do
		add( '-hostkey', quote( key ) )
	end

	-- En mode diagnostic, on demande à plink d'écrire lui-même un journal
	-- détaillé (indépendant de la redirection du shell).
	if settings.verbose then
		add( '-v' )
		add( '-sshlog', quote( settings.debugLogPath or '' ) )
	end

	add( '-m', quote( commandPath ) )
	add( quote( settings.host ) )

	local command = table.concat( parts, ' ' )
	command = command .. ' > ' .. quote( outputPath ) .. ' 2>&1'
	return command
end

local function escapePattern( text )
	return ( tostring( text ):gsub( '([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1' ) )
end

-- Retire le mot de passe du texte affiché (utile si on a dû passer par -pw).
local function maskSecrets( text, settings )
	local secret = settings and settings.password
	if secret and secret ~= '' then
		text = tostring( text ):gsub( escapePattern( secret ), '********' )
	end
	return text
end

local function runPlink( settings, usePwfile, passwordPath, commandPath, outputPath )
	LrFileUtils.delete( outputPath )

	local command = buildCommand( settings, usePwfile, passwordPath, commandPath, outputPath )

	-- IMPORTANT : LrTasks.execute() ne passe pas forcément la commande à
	-- cmd.exe, et la redirection « > fichier 2>&1 » n'est alors PAS interprétée.
	-- Conséquence : plink s'exécute mais sa sortie (et ses erreurs) part dans le
	-- vide, et le fichier de log n'est jamais créé.
	--
	-- On passe donc par un vrai fichier .cmd, que cmd.exe interprète : la
	-- redirection y fonctionne de façon fiable.
	local batchPath = tempFilePath( 'bat' )
	local wroteBatch = writeTempFile( batchPath, '@echo off\r\n' .. command .. '\r\n' )

	if not wroteBatch then
		return -1, '', command
	end

	local status = LrTasks.execute( 'cmd.exe /c ' .. quote( batchPath ) )

	local output = ''
	if LrFileUtils.exists( outputPath ) then
		output = LrFileUtils.readFile( outputPath ) or ''
	end

	LrFileUtils.delete( batchPath )

	return status, output, command
end


--=============================================================================
-- API publique
--=============================================================================

-- Retourne : ok (booléen), sortie (texte), code de sortie
function MPRNLSsh.run( settings, commands )
	commands = commands or MPRNLSsh.COMMANDS

	if not settings.plinkPath or settings.plinkPath == '' then
		return false, "Le chemin de plink.exe n'est pas renseigné.", -1
	end
	if not settings.host or settings.host == '' then
		return false, "L'hôte SSH n'est pas renseigné.", -1
	end
	if not settings.username or settings.username == '' then
		return false, "L'utilisateur SSH n'est pas renseigné.", -1
	end
	if not settings.password or settings.password == '' then
		return false,
			"Le mot de passe est vide.\n\n"
			.. "Le compte SSH est le même que le compte FTP : saisis le mot de passe dans "
			.. "le champ « Mot de passe » de la section « Connexion FTP », puis appuie sur "
			.. "Tab (ou Entrée) pour que la valeur soit prise en compte.", -1
	end

	-- Résolution de la clé d'hôte (voir fetchHostKeys) : indispensable, sinon
	-- plink se bloque en attendant une réponse qu'il ne peut pas recevoir.
	local hostKeys = {}
	if settings.hostKey and settings.hostKey ~= '' then
		hostKeys = { settings.hostKey } -- empreinte fournie : clé épinglée
	elseif settings.autoAcceptHostKey then
		hostKeys = fetchHostKeys( settings )
	end
	settings.hostKeys = hostKeys

	local commandText = table.concat( commands, "\n" ) .. "\n"
	local passwordText = ( settings.password or '' ) .. "\n"

	local passwordPath = tempFilePath( 'pw' )
	local commandPath = tempFilePath( 'cmd' )
	local outputPath = tempFilePath( 'log' )
	local debugPath = tempFilePath( 'sslog' )
	settings.debugLogPath = debugPath

	local wrotePassword, passwordErr = writeTempFile( passwordPath, passwordText )
	if not wrotePassword then
		return false, "Impossible d'écrire le fichier temporaire : " .. tostring( passwordErr ), -1
	end

	local wroteCommand, commandErr = writeTempFile( commandPath, commandText )
	if not wroteCommand then
		LrFileUtils.delete( passwordPath )
		return false, "Impossible d'écrire le fichier temporaire : " .. tostring( commandErr ), -1
	end

	local status, output, command = runPlink( settings, true, passwordPath, commandPath, outputPath )
	local outputFileExisted = LrFileUtils.exists( outputPath )

	-- plink antérieur à 0.77 ne connaît pas `-pwfile` : on retente avec `-pw`.
	if status ~= 0 and output and output:lower():find( 'unknown option', 1, true ) then
		status, output, command = runPlink( settings, false, passwordPath, commandPath, outputPath )
		outputFileExisted = LrFileUtils.exists( outputPath )
	end

	-- Si plink n'a rien renvoyé du tout, on relance une fois en mode détaillé
	-- pour récupérer un journal écrit par plink lui-même.
	local debugLog = ''
	if status ~= 0 and ( output == nil or output == '' ) then
		settings.verbose = true
		local retryStatus, retryOutput, retryCommand =
			runPlink( settings, true, passwordPath, commandPath, outputPath )
		settings.verbose = false

		if retryOutput and retryOutput ~= '' then
			status, output, command = retryStatus, retryOutput, retryCommand
		end
	end

	if LrFileUtils.exists( debugPath ) then
		debugLog = LrFileUtils.readFile( debugPath ) or ''
		if #debugLog > 5000 then
			debugLog = debugLog:sub( 1, 5000 ) .. "\n…(tronqué)"
		end
	end

	LrFileUtils.delete( passwordPath )
	LrFileUtils.delete( commandPath )
	LrFileUtils.delete( outputPath )
	LrFileUtils.delete( debugPath )

	if status ~= 0 then
		local text = tostring( output or '' )
		if text == '' then
			text = "(plink n'a renvoyé AUCUNE sortie)"
		end
		local lowerText = text:lower()

		-- Message d'aide si l'échec vient de la clé d'hôte.
		if lowerText:find( 'host key', 1, true ) or lowerText:find( 'hostkey', 1, true ) then
			text = text
				.. "\n\n--- Aide ---\n"
				.. "La clé d'hôte du serveur n'a pas pu être validée.\n"
				.. ( settings.autoAcceptHostKey
						and ( "ssh-keyscan n'a rien renvoyé pour « " .. tostring( settings.host ) .. " »." )
						or "L'acceptation automatique de la clé d'hôte est désactivée." )
				.. "\nTu peux aussi saisir l'empreinte attendue dans le champ « Clé d'hôte »."
		end

		local passwordInfo
		if settings.password and settings.password ~= '' then
			passwordInfo = "renseigné (" .. tostring( #settings.password ) .. " caractères)"
		else
			passwordInfo = "VIDE"
		end

		output = text
			.. "\n\n--- Réglages utilisés ---\n"
			.. "Hôte : " .. tostring( settings.host ) .. "\n"
			.. "Port : " .. tostring( settings.port or 22 ) .. "\n"
			.. "Utilisateur : " .. tostring( settings.username ) .. "\n"
			.. "Mot de passe : " .. passwordInfo .. "\n"
			.. "Clés d'hôte trouvées : " .. tostring( #( settings.hostKeys or {} ) ) .. "\n"
			.. "plink : " .. tostring( settings.plinkPath ) .. "\n"
			.. "Code de sortie : " .. tostring( status ) .. "\n"
			.. "Fichier de sortie créé : " .. ( outputFileExisted and "oui" or "NON" )
			.. "\n\n--- Commande exécutée ---\n"
			.. maskSecrets( command, settings )
			.. "\n\n--- Fichier de commandes ---\n"
			.. maskSecrets( commandText, settings )
			.. "\n\n--- Journal plink ---\n"
			.. ( debugLog ~= '' and debugLog or "(vide)" )

		-- On enregistre aussi le détail dans un fichier : le texte d'une boîte
		-- de dialogue Lightroom est difficile à copier.
		local logPath = LrPathUtils.child( tempDirectory(), 'mprnl-ssh-error.txt' )
		if writeTempFile( logPath, output ) then
			output = output .. "\n\n\nDétail complet enregistré dans :\n" .. logPath
		end
	end

	return ( status == 0 ), output, status
end

-- Test de connexion : exécute une commande inoffensive.
function MPRNLSsh.test( settings )
	return MPRNLSsh.run( settings, { "echo MPRNL_SSH_OK" } )
end

-- Construit la table de réglages attendue par run()/test() à partir du
-- tableau de propriétés de la boîte de dialogue d'export.
--
-- Le compte SSH est le MÊME que le compte FTP : l'hôte, l'utilisateur et le
-- mot de passe sont repris des champs FTP. Seuls le port (22), le chemin de
-- plink et la gestion de la clé d'hôte sont spécifiques au SSH.
function MPRNLSsh.settingsFromPropertyTable( propertyTable )
	local function trim( value )
		if value == nil then return '' end
		return ( tostring( value ):gsub( '^%s+', '' ):gsub( '%s+$', '' ) )
	end

	local host = trim( propertyTable.ftpServer )
	local username = trim( propertyTable.ftpUsername )

	-- Si l'utilisateur a saisi « utilisateur@hôte » dans le champ Serveur,
	-- on sépare les deux (sinon plink reçoit un hôte invalide).
	local beforeAt, afterAt = host:match( '^([^@]+)@(.+)$' )
	if beforeAt then
		if username == '' then
			username = beforeAt
		end
		host = afterAt
	end

	return {
		plinkPath = trim( propertyTable.sshPlinkPath ),
		host = host,
		port = tonumber( propertyTable.sshPort ) or 22,
		username = username,
		-- Le mot de passe n'est volontairement PAS « trimé » : un espace peut
		-- faire partie du mot de passe.
		password = propertyTable.ftpPassword,
		hostKey = trim( propertyTable.sshHostKey ),
		autoAcceptHostKey = propertyTable.sshAutoAcceptHostKey,
	}
end

-- Remplace les variables {remote_path}, {ftp_host} et {date} dans les
-- commandes configurées ci-dessus.
function MPRNLSsh.buildCommands( settings, remotePath )
	local date = os.date( '%Y-%m-%d' )

	local replacements = {
		{ '{remote_path}', tostring( remotePath or '' ) },
		{ '{ftp_host}', tostring( settings and settings.host or '' ) },
		{ '{date}', date },
	}

	local result = {}
	for _, command in ipairs( MPRNLSsh.COMMANDS ) do
		local text = command
		for _, pair in ipairs( replacements ) do
			local placeholder, value = pair[1], pair[2]
			-- Le '%' est spécial dans la chaîne de remplacement de gsub().
			value = value:gsub( '%%', '%%%%' )
			text = text:gsub( placeholder, value )
		end
		result[ #result + 1 ] = text
	end
	return result
end

return MPRNLSsh
