local MPRNLExportDialogSections = require 'MPRNLExportDialogSections'
local MPRNLFtpBrowser = require 'MPRNLFtpBrowser'
local MPRNLSsh = require 'MPRNLSsh'

local exportServiceProvider = {}

-- On délègue la construction du formulaire et son initialisation au fichier
-- dédié, pour ne pas tout entasser au même endroit.
exportServiceProvider.startDialog = MPRNLExportDialogSections.startDialog
exportServiceProvider.sectionsForTopOfDialog = MPRNLExportDialogSections.sectionsForTopOfDialog

-- Ce sont les "réglages" que Lightroom va se souvenir pour ce plugin
-- (et sauvegarder dans un preset si l'utilisateur en crée un).
-- ftpPassword n'est PAS dans cette liste : le mot de passe n'est jamais écrit
-- en clair dans un preset. Il est géré séparément par LrPasswords
-- (voir MPRNLExportDialogSections.lua et plus bas). Le compte SSH étant le
-- même que le compte FTP, ce seul mot de passe suffit.
exportServiceProvider.exportPresetFields = {
	{ key = 'ftpServer', default = 'mattiaparrinello.fr' },
	{ key = 'ftpUsername', default = '' },
	{ key = 'ftpPort', default = 21 },
	{ key = 'ftpPassiveMode', default = 'normal' },

	-- Dossier de destination sur le serveur ('' = dossier de connexion du compte).
	{ key = 'ftpRemotePath', default = 'cloud.mprnl.fr/data/admin/files' },

	-- Sous-dossier automatique au format AAAA-MM-JJ, calculé sur la date de
	-- prise de vue de la PREMIÈRE photo exportée.
	{ key = 'useDateSubfolder', default = true },

	-- Nombre d'envois simultanés (connexions FTP en parallèle).
	{ key = 'ftpConcurrentUploads', default = 3 },

	-- Réglages SSH. Le compte SSH est le MÊME que le compte FTP (serveur,
	-- utilisateur et mot de passe sont repris de la section FTP) : seuls le
	-- port, plink.exe et la gestion de la clé d'hôte sont propres au SSH.
	-- Les commandes sont systématiquement exécutées après l'export, il n'y a
	-- donc pas de case à cocher.
	{ key = 'sshPort', default = 22 },
	{ key = 'sshPlinkPath', default = '' },
	{ key = 'sshHostKey', default = '' },
	{ key = 'sshAutoAcceptHostKey', default = true },
}

-- On n'a pas besoin de la section "Emplacement d'exportation" standard de
-- Lightroom (qui sert à choisir un dossier sur le disque), puisqu'on envoie
-- les fichiers vers un serveur. Les fichiers sont donc rendus dans un dossier
-- temporaire, supprimé automatiquement à la fin de l'export.
exportServiceProvider.hideSections = { 'exportLocation' }

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPasswords = import 'LrPasswords'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

-- Coffre du trousseau système (FTP et SSH, c'est le même compte).
local PASSWORD_SERVICE_NAME = "MPRNL Lightroom FTP Export"

-- Nombre de tentatives par fichier en cas d'échec d'envoi (coupure réseau,
-- session FTP tombée, serveur surchargé...). Entre deux tentatives, la
-- connexion FTP est refaite intégralement.
local UPLOAD_ATTEMPTS = 3

-- Marge de sécurité avant les commandes serveur : l'envoi est terminé et la
-- session FTP refermée, mais certains serveurs encaissent les fichiers de
-- façon légèrement différée. Mettre à 0 pour désactiver.
local SETTLE_DELAY_SECONDS = 3

-- 1970-01-01 → 2001-01-01, en secondes (époques Lightroom / Unix).
local LR_EPOCH_OFFSET = 978307200

-- Nombre maximum de sessions d'envoi simultanées acceptées.
local MAX_CONCURRENCY = 4


local function trim( value )
	if value == nil then return '' end
	return ( tostring( value ):gsub( '^%s+', '' ):gsub( '%s+$', '' ) )
end

-- Journal de diagnostic de l'export.
-- Sert à savoir si processRenderedPhotos() a réellement été appelé et où il
-- s'est arrêté (« il ne se passe rien » n'est pas diagnosticable autrement).
local function logExport( message )
	local directory = LrPathUtils.getStandardFilePath( 'temp' ) or '.'

	local file = io.open( LrPathUtils.child( directory, 'mprnl-export.log' ), 'a' )
	if file then
		file:write( os.date( '%Y-%m-%d %H:%M:%S' ) .. '  ' .. tostring( message ) .. '\r\n' )
		file:close()
	end
end

local function listPhotosToExport( exportSession )
	local photos = {}
	for _, photo in exportSession:photosToExport() do
		photos[ #photos + 1 ] = photo
	end

	-- Repli : si l'export ne renvoie rien, on prend les photos sélectionnées.
	if #photos == 0 then
		local catalog = LrApplication.activeCatalog()
		photos = catalog:getTargetPhotos() or {}
	end

	logExport( "Photos à exporter : " .. #photos )

	return photos
end


--=============================================================================
-- Sous-dossier automatique, d'après la date de prise de vue de la 1re photo
--
-- Une séance qui se prolonge après minuit reste ainsi rangée sous la date du
-- jour de départ.
--=============================================================================

-- Conversion "jours depuis 1970-01-01" → (année, mois, jour), en pur Lua :
-- on ne passe pas par os.date(), dont l'implémentation peut varier dans
-- l'environnement restreint de Lightroom. Algorithme de Howard Hinnant.
local function daysSinceEpochToYmd( days )
	days = days + 719468

	local era = math.floor( days / 146097 )
	local doe = days - era * 146097

	local yoe = math.floor(
		( doe
			- math.floor( doe / 1460 )
			+ math.floor( doe / 36524 )
			- math.floor( doe / 146096 )
		) / 365
	)

	local y = yoe + era * 400
	local doy = doe - ( 365 * yoe + math.floor( yoe / 4 ) - math.floor( yoe / 100 ) )
	local mp = math.floor( ( 5 * doy + 2 ) / 153 )

	local d = doy - math.floor( ( 153 * mp + 2 ) / 5 ) + 1
	local m = mp + ( mp < 10 and 3 or -9 )

	if m <= 2 then
		y = y + 1
	end

	return y, m, d
end

local function captureDateFolder( propertyTable, photos )
	logExport( string.format(
		"Sous-dossier par date : option = %s | %d photo(s)",
		tostring( propertyTable.useDateSubfolder ),
		#photos
	) )

	if #photos == 0 then
		logExport( "Sous-dossier par date : AUCUNE photo fournie — étape ignorée" )
		return nil
	end

	-- Plusieurs sources possibles selon le type de photo (RAW, JPEG, DNG...).
	local rawTime = nil
	local source = nil

	for _, key in ipairs( { 'dateTimeOriginal', 'dateTimeDigitized', 'dateTime' } ) do
		local ok, value = LrTasks.pcall( function()
			return photos[1]:getRawMetadata( key )
		end )

		logExport( string.format(
			"Sous-dossier par date : getRawMetadata('%s') -> %s (%s)",
			key,
			tostring( value ),
			type( value )
		) )

		if ok and type( value ) == 'number' and value > 0 then
			rawTime = value
			source = key
			break
		end
	end

	if rawTime == nil then
		logExport( "Sous-dossier par date : date de prise de vue introuvable — envoi à la racine" )
		return nil
	end

	-- Lightroom encode l'heure locale de prise de vue comme s'il s'agissait de
	-- GMT : on formate en UTC pour retrouver la bonne date « murale ».
	local unixSeconds = rawTime + LR_EPOCH_OFFSET
	local year, month, day = daysSinceEpochToYmd( math.floor( unixSeconds / 86400 ) )
	local folder = string.format( '%04d-%02d-%02d', year, month, day )

	logExport( "Sous-dossier par date : " .. folder .. "  (source : " .. source .. ")" )

	return folder
end


--=============================================================================
-- Réglages IA (masques générés par IA : sujet, ciel, personnes, retouches...)
--
-- Lightroom ne les recalcule pas tout seul. Ses propres exports affichent un
-- avertissement quand des masques peuvent être obsolètes ; ici on va plus loin
-- et on propose de les mettre à jour AVANT l'export.
--
-- L'API de détection (`needsUpdateAISettings`) n'existe que sur les versions
-- récentes du SDK : on la teste à l'exécution et, si elle est absente, on ne
-- fait rien plutôt que de proposer une mise à jour à chaque export.
--=============================================================================

local function offerAISettingsUpdate( exportContext, photos )
	if #photos == 0 then
		return
	end

	if photos[1].needsUpdateAISettings == nil then
		logExport( "Réglages IA : API de détection absente sur cette version — étape ignorée" )
		return
	end

	local outdated = {}
	for _, photo in ipairs( photos ) do
		local ok, needs = LrTasks.pcall( function()
			return photo:needsUpdateAISettings()
		end )

		if ok and needs then
			outdated[ #outdated + 1 ] = photo
		end
	end

	if #outdated == 0 then
		logExport( "Réglages IA : tous à jour" )
		return
	end

	logExport( string.format( "Réglages IA : %d photo(s) à recalculer", #outdated ) )

	local answer = LrDialogs.confirm(
		string.format(
			"%d photo(s) de cet export ont des masques IA à recalculer.",
			#outdated
		),
		"Lightroom ne les recalcule pas automatiquement : sans mise à jour, l'export "
			.. "risque d'envoyer des masques obsolètes (sujet, ciel, personnes, retouches IA...).\n\n"
			.. "Cette mise à jour peut prendre du temps sur une grosse série.",
		"Mettre à jour et exporter",
		"Exporter sans mettre à jour"
	)

	if answer ~= 'ok' then
		logExport( "Réglages IA : mise à jour refusée par l'utilisateur" )
		return
	end

	local catalog = LrApplication.activeCatalog()

	-- withProlongedWriteAccessDo : opération potentiellement longue.
	catalog:withProlongedWriteAccessDo( "Mise à jour des réglages IA", function()
		catalog:updateAISettings( outdated )
	end )

	logExport( "Réglages IA : mise à jour terminée" )
end


--=============================================================================
-- Reprise : on garde une copie des fichiers dont l'envoi a échoué, pour
-- pouvoir proposer de réessayer à la fin de l'export (Lightroom supprime son
-- dossier temporaire dès la fin de l'opération).
--=============================================================================

local function retryDirectory()
	local directory = LrPathUtils.child(
		LrPathUtils.getStandardFilePath( 'temp' ) or '.',
		'mprnl-reprise'
	)
	LrFileUtils.createAllDirectories( directory )
	return directory
end

local function keepForRetry( localPath, filename )
	local target = LrPathUtils.child( retryDirectory(), filename )

	if LrFileUtils.exists( target ) then
		LrFileUtils.delete( target )
	end

	local ok = LrFileUtils.copy( localPath, target )
	if ok then
		return target
	end

	return nil
end


--=============================================================================
-- Export
--=============================================================================

-- C'est LA fonction obligatoire : Lightroom l'appelle une fois les photos
-- rendues, pour qu'on en fasse quelque chose. Ici : on les envoie sur le
-- serveur FTP (plusieurs sessions en parallèle), puis on exécute
-- éventuellement les commandes SSH configurées.
function exportServiceProvider.processRenderedPhotos( functionContext, exportContext )

	local exportSession = exportContext.exportSession
	local propertyTable = exportContext.propertyTable

	logExport( "=== Export démarré ===" )

	local photos = listPhotosToExport( exportSession )
	local basePath = trim( propertyTable.ftpRemotePath )

	-- --- Réglages IA -------------------------------------------------------
	-- Proposition systématique : pas de case à cocher.
	offerAISettingsUpdate( exportContext, photos )

	-- --- Sous-dossier par date de prise de vue ----------------------------
	local dateFolder = nil
	if propertyTable.useDateSubfolder ~= false then
		dateFolder = captureDateFolder( propertyTable, photos )
	else
		logExport( "Sous-dossier par date : option désactivée" )
	end

	local targetPath = MPRNLFtpBrowser.childPath( basePath, dateFolder or '' )

	logExport( string.format(
		"Destination : base = %s | dossier = %s | sous-dossier = %s",
		( basePath == '' and "/" or basePath ),
		( targetPath == '' and "/" or targetPath ),
		dateFolder or "(désactivé ou date introuvable)"
	) )

	if propertyTable.useDateSubfolder ~= false and dateFolder == nil then
		logExport( "Sous-dossier par date : date de prise de vue introuvable — envoi à la racine" )
	end

	-- --- Réglages de connexion --------------------------------------------
	local ftpSettings = {
		server = propertyTable.ftpServer,
		username = propertyTable.ftpUsername,
		password = propertyTable.ftpPassword,
		port = propertyTable.ftpPort,
		protocol = 'ftp',
		passive = propertyTable.ftpPassiveMode,
		path = targetPath,
	}

	-- --- Barre de progression de l'export (rendu par Lightroom) -----------
	local nPhotos = exportSession:countRenditions()

	local progressScope = exportContext:configureProgress {
		title = ( nPhotos > 1 )
			and string.format( "Export de %d photos", nPhotos )
			or "Export d'une photo",
		-- Cette barre avance au rythme du RENDU des photos par Lightroom.
		-- L'envoi a sa propre barre (voir uploadScope plus bas).
	}

	-- --- Dossier de destination -------------------------------------------
	progressScope:setCaption( "Préparation du dossier de destination…" )

	local folderOk, folderError = MPRNLFtpBrowser.ensureFolder( ftpSettings, targetPath )

	if not folderOk then
		logExport( "ÉCHEC du dossier de destination : " .. tostring( folderError ) )
		LrDialogs.message(
			"MPRNL – FTP",
			"Impossible de préparer le dossier de destination.\n\n"
				.. tostring( folderError )
				.. "\n\nRéglages utilisés :\n"
				.. MPRNLFtpBrowser.describeSettings( ftpSettings ),
			"critical"
		)
		return
	end

	-- --- Mémorisation du mot de passe -------------------------------------
	if propertyTable.ftpUsername and propertyTable.ftpUsername ~= "" then
		LrPasswords.store( PASSWORD_SERVICE_NAME, propertyTable.ftpPassword, propertyTable.ftpUsername )
	end

	-- --- Envoi, avec plusieurs sessions en parallèle ----------------------
	local concurrency = tonumber( propertyTable.ftpConcurrentUploads ) or 3
	concurrency = math.floor( concurrency )
	if concurrency < 1 then concurrency = 1 end
	if concurrency > MAX_CONCURRENCY then concurrency = MAX_CONCURRENCY end

	logExport( "Début de l'envoi — " .. concurrency .. " session(s) simultanée(s)" )
	progressScope:setCaption( "Préparation des photos…" )

	-- Barre de progression dédiée à l'ENVOI, indépendante de celle du rendu :
	-- c'est elle qui dit où on en est des transferts.
	local uploadScope = LrProgressScope {
		title = "Envoi vers le serveur",
		caption = string.format( "0 / %d", nPhotos ),
		cannotCancel = true,
	}

	-- File d'attente partagée entre le producteur (rendu) et les sessions d'envoi.
	local queue = {}
	local queueFirst, queueLast = 1, 0
	local producing = true
	local canceled = false
	local workersActive = concurrency
	local failures = {}          -- { label = "...", retryPath = ... }
	local uploadedCount = 0
	local completedCount = 0     -- envoyés + échecs (pour la barre d'envoi)

	-- La file est volontairement courte : le rendu ne doit pas prendre
	-- d'avance sur l'envoi, sinon Lightroom afficherait « c'est fini » alors
	-- que des transferts sont encore en cours.
	local QUEUE_MAX = math.max( 1, concurrency )

	local function queueLength()
		return queueLast - queueFirst + 1
	end

	local function addFailure( label, retryPath )
		failures[ #failures + 1 ] = { label = label, retryPath = retryPath }
	end

	-- Une session d'envoi : sa propre connexion FTP, boucle sur la file.
	local function worker()
		local connection = nil
		local connectError = nil

		local function ensureConnection()
			if connection then return true end
			connection, connectError = MPRNLFtpBrowser.connect( ftpSettings )
			return connection ~= nil
		end

		local function closeConnection()
			if connection then
				MPRNLFtpBrowser.disconnect( connection )
				connection = nil
			end
		end

		while not canceled do
			local item = nil
			if queueFirst <= queueLast then
				item = queue[ queueFirst ]
				queue[ queueFirst ] = nil
				queueFirst = queueFirst + 1
			end

			if item == nil then
				if not producing then
					break
				end
				LrTasks.sleep( 0.1 )
			else
				uploadScope:setCaption( string.format(
					"%d / %d — %s",
					completedCount,
					nPhotos,
					item.filename
				) )

				local sent = false
				local lastReason = "raison inconnue"

				for attempt = 1, UPLOAD_ATTEMPTS do
					if ensureConnection() then
						-- LrTasks.pcall : putFile() « yield » pendant le transfert.
						local okPut, putResult = LrTasks.pcall( function()
							return connection:putFile( item.localPath, item.filename )
						end )

						if okPut and putResult ~= false then
							sent = true
							break
						end

						lastReason = okPut and "envoi refusé par le serveur" or tostring( putResult )
					else
						lastReason = tostring( connectError )
					end

					if attempt < UPLOAD_ATTEMPTS then
						logExport( string.format(
							"Tentative %d/%d échouée pour %s (%s) — nouvelle tentative",
							attempt, UPLOAD_ATTEMPTS, item.filename, tostring( lastReason )
						) )
						closeConnection()
						LrTasks.sleep( 2 )
					end
				end

				if sent then
					uploadedCount = uploadedCount + 1
					-- On libère le fichier temporaire au fur et à mesure.
					LrFileUtils.delete( item.localPath )
				else
					logExport( "ÉCHEC envoi " .. item.filename .. " : " .. tostring( lastReason ) )
					local kept = keepForRetry( item.localPath, item.filename )
					addFailure(
						item.filename .. "  (" .. tostring( lastReason ) .. ")",
						kept
					)
				end

				completedCount = completedCount + 1
				uploadScope:setPortionComplete( completedCount, nPhotos )
			end
		end

		closeConnection()
	end

	for _ = 1, concurrency do
		LrTasks.startAsyncTask( function()
			local ok, err = LrTasks.pcall( worker )
			if not ok then
				logExport( "Erreur d'une session d'envoi : " .. tostring( err ) )
				addFailure( "Session d'envoi : " .. tostring( err ), nil )
			end
			workersActive = workersActive - 1
		end, "MPRNLUpload" )
	end

	-- Production : rendu des photos, puis mise en file d'attente. La file est
	-- bornée pour que le rendu ne prenne pas trop d'avance sur l'envoi.
	--
	-- On protège la boucle : si le rendu lève une erreur, il faut ABSOLUMENT
	-- repasser `producing` à false. Sinon les sessions d'envoi restent en
	-- attente d'une file qui ne sera plus jamais remplie et tournent à vide
	-- jusqu'à la fermeture de Lightroom.
	local producerOk, producerError = LrTasks.pcall( function()
		for _, rendition in exportContext:renditions { stopIfCanceled = true } do

			local success, pathOrMessage = rendition:waitForRender()

			if progressScope:isCanceled() then
				canceled = true
				break
			end

			if success then
				local filename = LrPathUtils.leafName( pathOrMessage )

				-- Le producteur ne remplit jamais la file au-delà de sa
				-- capacité : c'est ce qui garantit que le rendu reste collé à
				-- l'envoi. À l'inverse, si l'envoi est plus rapide, la file se
				-- vide et les sessions dorment — aucun frein n'est ajouté.
				while queueLength() >= QUEUE_MAX and not canceled do
					if progressScope:isCanceled() then
						canceled = true
						break
					end
					LrTasks.sleep( 0.05 )
				end

				if canceled then break end

				queueLast = queueLast + 1
				queue[ queueLast ] = { localPath = pathOrMessage, filename = filename }

				progressScope:setCaption( string.format( "Préparation : %s", filename ) )
			else
				logExport( "ÉCHEC rendu : " .. tostring( pathOrMessage ) )
				addFailure( tostring( pathOrMessage ), nil )
			end
		end
	end )

	producing = false

	-- Attente de la fin des sessions d'envoi.
	while workersActive > 0 do
		LrTasks.sleep( 0.1 )
	end

	uploadScope:done()

	if not producerOk then
		logExport( "ÉCHEC pendant la préparation des photos : " .. tostring( producerError ) )
		error( producerError )
	end

	if canceled then
		logExport( string.format( "ANNULÉ par l'utilisateur (%d envoyé(s))", uploadedCount ) )
	else
		logExport( string.format(
			"Envoi terminé : %d réussi(s), %d échec(s)",
			uploadedCount,
			#failures
		) )
	end

	-- --- Reprise éventuelle des fichiers en échec -------------------------
	if #failures > 0 and not canceled then
		local retryable = {}
		for _, failure in ipairs( failures ) do
			if failure.retryPath then
				retryable[ #retryable + 1 ] = failure
			end
		end

		if #retryable > 0 then
			local answer = LrDialogs.confirm(
				string.format( "%d fichier(s) n'ont pas pu être envoyés.", #failures ),
				"Une copie des fichiers en échec a été conservée.\n\n"
					.. "Voulez-vous réessayer leur envoi maintenant ?",
				"Réessayer",
				"Ne pas réessayer"
			)

			if answer == 'ok' then
				local connection, connectError = MPRNLFtpBrowser.connect( ftpSettings )

				if not connection then
					logExport( "Reprise impossible : " .. tostring( connectError ) )
					LrDialogs.message(
						"MPRNL – FTP",
						"Reconnexion impossible pour la reprise :\n\n" .. tostring( connectError ),
						"critical"
					)
				else
					local retryScope = LrProgressScope {
						title = "Nouvelle tentative d'envoi",
						caption = string.format( "%d fichier(s)…", #retryable ),
					}

					local recovered = 0

					for index, failure in ipairs( retryable ) do
						retryScope:setCaption( string.format(
							"%s  (%d/%d)",
							failure.retryPath and LrPathUtils.leafName( failure.retryPath ) or "?",
							index,
							#retryable
						) )

						local okPut, putResult = LrTasks.pcall( function()
							return connection:putFile(
								failure.retryPath,
								LrPathUtils.leafName( failure.retryPath )
							)
						end )

						if okPut and putResult ~= false then
							recovered = recovered + 1
							uploadedCount = uploadedCount + 1
							failure.recovered = true
							LrFileUtils.delete( failure.retryPath )
							failure.retryPath = nil
						else
							logExport( "Nouvel échec pour " .. tostring( failure.label ) )
						end
					end

					MPRNLFtpBrowser.disconnect( connection )
					retryScope:done()

					logExport( string.format( "Reprise : %d récupéré(s)", recovered ) )
				end
			end
		end
	end

	-- ---------------------------------------------------------------------
	-- Commandes SSH après l'export (ex. réindexation Nextcloud).
	-- ---------------------------------------------------------------------
	local sshFailed = false
	local sshOutput = nil
	local sshRan = false

	if not canceled and uploadedCount > 0 then
		progressScope:setCaption( "Prise en compte des fichiers par le serveur…" )
		logExport( "Pause de " .. SETTLE_DELAY_SECONDS .. " s avant les commandes serveur" )
		LrTasks.sleep( SETTLE_DELAY_SECONDS )
	end

	-- Les commandes sont toujours lancées après un export complet (pas de case
	-- à cocher : on veut que la galerie reste à jour). Seul un export annulé
	-- les empêche de partir.
	if canceled then
		logExport( "SSH : ignoré (export annulé)" )
	else
		sshRan = true

		-- Barre de progression dédiée aux commandes serveur.
		local scanScope = LrProgressScope {
			title = "Réindexation du serveur",
			caption = "Connexion SSH et exécution des commandes…",
		}
		if scanScope.setIndeterminate then
			scanScope:setIndeterminate( true )
		end

		local sshSettings = MPRNLSsh.settingsFromPropertyTable( propertyTable )
		local commands = MPRNLSsh.buildCommands( sshSettings, targetPath )

		logExport( string.format(
			"Exécution SSH (%d fichier(s) envoyé(s)) : %s",
			uploadedCount,
			table.concat( commands, " ; " )
		) )

		local sshOk, output = MPRNLSsh.run( sshSettings, commands )
		sshFailed = not sshOk
		sshOutput = output

		scanScope:done()

		if sshFailed then
			logExport( "ÉCHEC SSH : " .. tostring( output ) )
		else
			logExport( "SSH OK : " .. tostring( output ) )
		end
	end

	-- ---------------------------------------------------------------------
	-- Compte-rendu
	-- ---------------------------------------------------------------------
	local stillFailing = {}
	for _, failure in ipairs( failures ) do
		if not failure.recovered then
			stillFailing[ #stillFailing + 1 ] = failure.label
		end
	end

	local sshSummary = nil
	if sshRan then
		sshSummary = sshFailed and "Les commandes serveur ont échoué." or "Commandes serveur exécutées."
	end

	if canceled then
		LrDialogs.showBezel( string.format(
			"Export annulé — %d fichier(s) envoyé(s).",
			uploadedCount
		) )

	elseif #stillFailing > 0 then
		local message = string.format(
			"%d fichier(s) n'ont pas pu être envoyés :\n%s",
			#stillFailing,
			table.concat( stillFailing, "\n" )
		)

		if sshFailed then
			message = message .. "\n\nCommandes serveur en échec :\n" .. tostring( sshOutput or '' )
		elseif sshRan then
			message = message .. "\n\n" .. tostring( sshSummary )
		end

		LrDialogs.message( "MPRNL", message, sshFailed and "critical" or "warning" )

	elseif sshFailed then
		LrDialogs.message(
			"MPRNL – SSH",
			"Les commandes post-export ont échoué.\n\n" .. tostring( sshOutput or '' ),
			"critical"
		)

	elseif sshRan then
		-- Résultat du scan : c'est ce qui dit si la galerie a bien pris les photos.
		local text = string.format( "%d fichier(s) envoyé(s) sur le serveur.", uploadedCount )
			.. "\n\nRéponse du serveur :\n"
			.. tostring( sshOutput or "(vide)" )

		if #text > 3000 then
			text = text:sub( 1, 3000 ) .. "\n…(tronqué)"
		end

		LrDialogs.message( "MPRNL – Serveur", text, "info" )
		logExport( "Export terminé avec succès" )

	else
		logExport( "Export terminé avec succès" )
		LrDialogs.showBezel(
			string.format( "%d fichier(s) envoyé(s) sur le serveur.", uploadedCount ),
			3
		)
	end

end

return exportServiceProvider
