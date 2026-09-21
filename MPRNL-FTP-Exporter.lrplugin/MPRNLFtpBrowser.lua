--[[----------------------------------------------------------------------------
	MPRNLFtpBrowser.lua

	Utilitaires FTP sans état, utilisés par le panneau d'export :
	  - ouverture / fermeture d'une connexion,
	  - lecture du contenu d'un dossier (listing -> sous-dossiers),
	  - création d'un dossier,
	  - manipulation de chemins FTP,
	  - vérification de l'existence d'un dossier.

	Chaque opération ouvre sa propre connexion puis la referme : c'est un peu
	plus coûteux qu'une connexion persistante, mais beaucoup plus robuste
	(aucun état à maintenir entre deux clics de l'utilisateur).

	IMPORTANT : toutes les fonctions réseau doivent être appelées DEPUIS UNE
	TÂCHE ASYNCHRONE, et les appels FTP doivent être protégés par
	`LrTasks.pcall` (et non `pcall`) car ils « yield ».
--]]

local LrFtp = import 'LrFtp'
local LrTasks = import 'LrTasks'

local MPRNLFtpBrowser = {}

-- Nombre maximum de vérifications `exists()` par listing, dans le seul cas où
-- le format du listing n'a pas permis de déterminer le type des entrées.
-- Chaque appel est un aller-retour réseau : on limite strictement.
local MAX_EXISTS_CHECKS = 25


--=============================================================================
-- Chemins FTP
--=============================================================================

local function trim( value )
	if value == nil then return nil end
	value = tostring( value )
	return ( value:gsub( '^%s+', '' ):gsub( '%s+$', '' ) )
end

-- Normalise un chemin FTP : séparateur '/', pas de '/' final.
-- '' est conservé tel quel et désigne le dossier de connexion du compte.
local function normalizePath( path )
	if path == nil then return '' end
	local result = tostring( path ):gsub( '\\', '/' )
	result = result:gsub( '/+', '/' )
	result = result:gsub( '/+$', '' )
	return result
end

local function displayPath( path )
	path = normalizePath( path )
	if path == '' then return '/' end
	return path
end

-- `root` sert de butée : on ne remonte jamais au-dessus du dossier de départ.
local function parentPath( path, root )
	path = normalizePath( path )
	root = normalizePath( root or '' )
	if path == root then return nil end
	if path == '' or path == '/' then return nil end

	local parent = path:match( '^(.*)/[^/]+$' )
	if parent == nil or parent == '' then
		if root == '' then return '' end
		return '/'
	end
	return parent
end

local function childPath( path, name )
	path = normalizePath( path )
	name = trim( name ) or ''
	name = name:gsub( '^/+', '' ):gsub( '/+$', '' )
	if name == '' then return path end
	if path == '' then return name end
	if path == '/' then return '/' .. name end
	return path .. '/' .. name
end

MPRNLFtpBrowser.normalizePath = normalizePath
MPRNLFtpBrowser.displayPath = displayPath
MPRNLFtpBrowser.parentPath = parentPath
MPRNLFtpBrowser.childPath = childPath
MPRNLFtpBrowser.trim = trim


-- Décrit les réglages de connexion (jamais le mot de passe) pour les messages
-- d'erreur : indispensable pour diagnostiquer un échec de connexion.
function MPRNLFtpBrowser.describeSettings( settings )
	settings = settings or {}

	local shownPath = settings.path
	if shownPath == nil or shownPath == '' then
		shownPath = '/ (dossier de connexion)'
	end

	return string.format(
		"Serveur : %s\nPort : %s\nProtocole : %s\nMode : %s\nUtilisateur : %s\nDossier : %s",
		tostring( settings.server or '' ),
		tostring( settings.port or '' ),
		tostring( settings.protocol or 'ftp' ),
		tostring( settings.passive or '' ),
		tostring( settings.username or '' ),
		tostring( shownPath )
	)
end


--=============================================================================
-- Connexion
--=============================================================================

-- Retourne (connexion) ou (nil, message d'erreur).
-- À appeler depuis une tâche asynchrone.
function MPRNLFtpBrowser.connect( settings )
	local okCreate, conn, createErr = LrTasks.pcall( function()
		return LrFtp.create( settings, false )
	end )

	if not okCreate then
		-- LrFtp.create a levé une exception : le message est dans `conn`.
		return nil, tostring( conn )
	end

	if conn == nil then
		return nil, tostring( createErr or "(aucun détail renvoyé par Lightroom)" )
	end

	return conn
end

function MPRNLFtpBrowser.disconnect( connection )
	if connection then
		LrTasks.pcall( function() connection:disconnect() end )
	end
end


--=============================================================================
-- Analyse du listing renvoyé par LrFtp.getContents('/')
--
-- Selon les serveurs, le format peut être :
--   Unix / "ls -l"  : drwxr-xr-x 2 root root 4096 Jan 01 12:00 photos
--   MS-DOS / IIS    : 01-01-24  12:00PM       <DIR>          photos
--   MLSD (RFC 3659) : type=dir;size=0;modify=...; photos
--=============================================================================

local function parseListingLine( line )
	-- 1) Format MS-DOS / IIS :
	--    "01-01-24  12:00PM  <DIR>  nom"   (dossier)
	--    "01-01-24  12:00PM   1234  nom"   (fichier)
	if line:match( '^%d%d%-%d%d%-%d%d%s+%d%d?:%d%d' ) or line:find( '<DIR>', 1, true ) then
		local dirName = line:match( '<DIR>%s+(.+)$' )
		if dirName then
			return trim( dirName ), true
		end

		local fileName = line:match( '%d%d?:%d%d%u?%u?%s+%d+%s+(.+)$' )
		if fileName then
			return trim( fileName ), false
		end

		return trim( line:match( '(%S+)$' ) ), nil
	end

	-- 2) Format MLSD : "clé=valeur;clé=valeur; nom"
	if line:match( '^[%a]+=' ) and line:find( 'type=', 1, true ) then
		local name = line:match( '^%S+%s+(.+)$' )
		local isDir = ( line:find( 'type=dir', 1, true ) ~= nil )
			or ( line:find( 'type=cdir', 1, true ) ~= nil )
			or ( line:find( 'type=pdir', 1, true ) ~= nil )
		return trim( name ), isDir
	end

	-- 3) Format Unix "ls -l" : le premier caractère indique le type.
	local firstChar = line:sub( 1, 1 )
	if firstChar == 'd' or firstChar == '-' or firstChar == 'l' then
		local name = line:match( '%s%a%a%a%s+%d+%s+%S+%s+(.+)$' )
		if name == nil then
			-- Variante avec une date ISO : 2024-01-01 12:00
			name = line:match( '%s%d%d%d%d%-%d%d%-%d%d%s+%S+%s+(.+)$' )
		end
		if name == nil then
			-- Dernier recours : le dernier champ (ne gère pas les espaces)
			name = line:match( '(%S+)$' )
		end
		return trim( name ), ( firstChar == 'd' )
	end

	-- 4) Format inconnu : on renvoie le dernier champ, sans type.
	return trim( line:match( '(%S+)$' ) ), nil
end

local function parseListing( listing )
	local entries = {}
	local alreadySeen = {}

	for line in tostring( listing or '' ):gmatch( '[^\r\n]+' ) do
		line = trim( line )
		if line ~= '' and line:sub( 1, 1 ) ~= '#' then
			local name, isDir = parseListingLine( line )

			-- Certains serveurs suffixent les dossiers d'un « / ».
			if name then
				name = name:gsub( '/+$', '' )
			end

			if name and name ~= '' and name ~= '.' and name ~= '..' then
				if not alreadySeen[ name ] then
					alreadySeen[ name ] = true
					entries[ #entries + 1 ] = { name = name, isDir = isDir }
				end
			end
		end
	end

	return entries
end


--=============================================================================
-- Opérations
--=============================================================================

-- Liste les sous-dossiers de `path` (une seule requête dans le cas normal).
-- Retourne (dossiers, messageErreur, listingBrut).
-- À appeler depuis une tâche asynchrone, avec une connexion déjà ouverte.
local function listSubFolders( connection, path )
	local listing
	local ok, err = LrTasks.pcall( function()
		connection.path = path
		listing = connection:getContents( '/' )
	end )

	if not ok then
		return nil, "Lecture du dossier impossible (" .. tostring( err ) .. ")", nil
	end

	local entries = parseListing( listing )

	-- Le listing donne-t-il le type de CHAQUE entrée ? Si oui, aucun appel
	-- réseau supplémentaire n'est nécessaire.
	local allTyped = true
	for _, entry in ipairs( entries ) do
		if entry.isDir == nil then
			allTyped = false
			break
		end
	end

	local folders = {}
	local existsError = nil

	if allTyped then
		for _, entry in ipairs( entries ) do
			if entry.isDir then
				folders[ #folders + 1 ] = entry.name
			end
		end
	else
		-- Format inhabituel : on demande au serveur, avec un plafond.
		local checks = 0
		for _, entry in ipairs( entries ) do
			if entry.isDir == true then
				folders[ #folders + 1 ] = entry.name

			elseif entry.isDir == nil and checks < MAX_EXISTS_CHECKS then
				checks = checks + 1
				local okCheck, result = LrTasks.pcall( function()
					return connection:exists( entry.name )
				end )

				if not okCheck then
					existsError = tostring( result )
					break
				end

				if result == 'directory' then
					folders[ #folders + 1 ] = entry.name
				end
			end
		end
	end

	table.sort( folders, function( a, b ) return a:lower() < b:lower() end )

	local note = nil
	if existsError then
		note = "vérification impossible (" .. existsError .. ")"
	elseif not allTyped then
		note = "format de listing inhabituel"
	end

	return folders, note, listing
end

-- Ouvre une connexion, liste `path`, referme la connexion.
-- Retourne (dossiers, messageErreur|note, listingBrut).
function MPRNLFtpBrowser.listFolders( settings, path )
	local connection, connectError = MPRNLFtpBrowser.connect( settings )
	if not connection then
		return nil, connectError, nil
	end

	local folders, note, listing = listSubFolders( connection, path )
	MPRNLFtpBrowser.disconnect( connection )

	if folders == nil then
		return nil, note, listing
	end

	return folders, note, listing
end

-- Crée un dossier `name` dans `parentPath`. Retourne (ok, message).
function MPRNLFtpBrowser.createDirectory( settings, parent, name )
	local connection, connectError = MPRNLFtpBrowser.connect( settings )
	if not connection then
		return false, connectError
	end

	local ok, err = LrTasks.pcall( function()
		connection.path = parent
		return connection:makeDirectory( name )
	end )

	MPRNLFtpBrowser.disconnect( connection )

	if not ok then
		return false, tostring( err )
	end

	return true
end

-- Crée `path` (et ses parents manquants) sur le serveur.
-- Retourne (true) ou (false, explication).
function MPRNLFtpBrowser.ensureFolder( settings, path )
	path = normalizePath( path )
	if path == '' or path == '/' then
		return true
	end

	local connectSettings = {}
	for key, value in pairs( settings or {} ) do
		connectSettings[ key ] = value
	end
	connectSettings.path = ''

	local connection, connectError = MPRNLFtpBrowser.connect( connectSettings )
	if not connection then
		return false, connectError
	end

	local built = ''
	if path:sub( 1, 1 ) == '/' then
		built = '/'
	end

	local okAll = true
	local problem = nil

	for part in path:gmatch( '[^/]+' ) do
		local parent = built

		local okExists, kind = LrTasks.pcall( function()
			connection.path = parent
			return connection:exists( part )
		end )

		if not okExists then
			-- Impossible de vérifier : on laisse l'envoi tenter sa chance.
			break
		end

		if kind == false then
			local okMake, makeError = LrTasks.pcall( function()
				connection.path = parent
				return connection:makeDirectory( part )
			end )

			if not okMake then
				okAll = false
				problem = "Création de « " .. part .. " » impossible dans « "
					.. displayPath( parent ) .. " » (" .. tostring( makeError ) .. ")"
				break
			end
		elseif kind ~= 'directory' then
			okAll = false
			problem = "« " .. part .. " » existe déjà mais ce n'est pas un dossier"
			break
		end

		built = childPath( built, part )
	end

	MPRNLFtpBrowser.disconnect( connection )
	return okAll, problem
end

-- Vérifie qu'un dossier existe bien sur le serveur (connexion déjà ouverte).
-- Retourne (true) ou (false, explication). Ne bloque jamais en cas d'erreur
-- technique : on ne veut pas empêcher un export à cause d'un test raté.
function MPRNLFtpBrowser.remoteFolderExists( connection, path )
	local cleaned = MPRNLFtpBrowser.trim( path ) or ''
	if cleaned == '' then
		return true
	end

	cleaned = cleaned:gsub( '/+$', '' )
	local leaf = cleaned:match( '([^/]+)$' )
	local parent = cleaned:match( '^(.*)/[^/]+$' ) or ''

	if not leaf or leaf == '' then
		return true
	end

	local ok, kind = LrTasks.pcall( function()
		connection.path = parent
		return connection:exists( leaf )
	end )

	-- On rétablit systématiquement le dossier de destination.
	connection.path = tostring( path )

	if not ok then
		return true -- erreur technique : on laisse l'upload tenter sa chance
	end

	if kind == 'directory' then
		return true
	end

	return false, "Le dossier « " .. tostring( path ) .. " » n'existe pas sur le serveur."
end

return MPRNLFtpBrowser
