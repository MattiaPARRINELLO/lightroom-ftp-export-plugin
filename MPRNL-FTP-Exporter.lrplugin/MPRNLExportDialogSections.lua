local LrView = import 'LrView'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPasswords = import 'LrPasswords'
local LrPathUtils = import 'LrPathUtils'

local MPRNLFtpBrowser = require 'MPRNLFtpBrowser'
local MPRNLSsh = require 'MPRNLSsh'

local bind = LrView.bind

local MPRNLExportDialogSections = {}

-- Coffre du trousseau système pour le mot de passe.
-- Le compte SSH étant le même que le compte FTP, un seul coffre suffit.
-- Doit être IDENTIQUE à la valeur utilisée dans
-- MPRNLExportServiceProvider.lua.
local PASSWORD_SERVICE_NAME = "MPRNL Lightroom FTP Export"

-- Dossier de destination proposé par défaut (dossier de données Nextcloud).
local DEFAULT_REMOTE_PATH = "cloud.mprnl.fr/data/admin/files"

-- Présentation : libellés alignés à droite sur une largeur commune, comme
-- dans les panneaux d'export natifs de Lightroom.
local LABEL_WIDTH = 118
local FIELD_WIDTH = 32
local HINT_COLOR = { 0.5, 0.5, 0.5 }
local COMMAND_COLOR = { 0.35, 0.35, 0.35 }

-- Gestionnaires partagés entre startDialog() (qui enregistre les observers)
-- et sectionsForTopOfDialog() (qui construit l'interface).
local browseState = { navigate = nil }


-- Cette fonction est appelée UNE FOIS quand le dialogue d'export s'ouvre.
-- Elle sert à préparer des valeurs "calculées" qui dépendent d'autres champs.
function MPRNLExportDialogSections.startDialog( propertyTable )

	-- -----------------------------------------------------------------
	-- Valeurs par défaut pour les presets créés avant l'existence du champ
	-- -----------------------------------------------------------------

	if propertyTable.ftpRemotePath == nil or propertyTable.ftpRemotePath == "" then
		propertyTable.ftpRemotePath = DEFAULT_REMOTE_PATH
	end

	if propertyTable.useDateSubfolder == nil then
		propertyTable.useDateSubfolder = true
	end

	if propertyTable.ftpConcurrentUploads == nil then
		propertyTable.ftpConcurrentUploads = 3
	end

	-- -----------------------------------------------------------------
	-- Mot de passe : jamais dans le preset, lu depuis le trousseau
	-- -----------------------------------------------------------------

	propertyTable.ftpPassword = propertyTable.ftpPassword or ""

	local function loadStoredPassword()
		local username = propertyTable.ftpUsername
		if username and username ~= "" then
			local stored = LrPasswords.retrieve( PASSWORD_SERVICE_NAME, username )
			-- Ne jamais effacer un mot de passe déjà saisi : on ne remplace
			-- que si le trousseau contient réellement quelque chose.
			if stored and stored ~= "" then
				propertyTable.ftpPassword = stored
			end
		end
	end

	loadStoredPassword()

	propertyTable:addObserver( 'ftpUsername', loadStoredPassword )

	-- -----------------------------------------------------------------
	-- SSH : détection de plink.exe (le compte est celui du FTP)
	-- -----------------------------------------------------------------

	if propertyTable.sshPlinkPath == nil or propertyTable.sshPlinkPath == "" then
		local detected = MPRNLSsh.detectPlink()
		if detected then
			propertyTable.sshPlinkPath = detected
		end
	end

	-- -----------------------------------------------------------------
	-- Destination finale, affichée en permanence pour éviter les erreurs
	-- -----------------------------------------------------------------

	local function updateFtpDestination()
		local base = propertyTable.ftpRemotePath
		if base == nil or base == "" then
			base = "/"
		end

		local final = base
		if propertyTable.useDateSubfolder ~= false then
			final = final .. " / AAAA-MM-JJ"
		end

		propertyTable.ftpDestination = final

		local server = propertyTable.ftpServer or ""
		propertyTable.ftpSynopsis = ( server == "" )
			and "Serveur non configuré"
			or ( server .. "   ·   " .. final )
	end

	propertyTable:addObserver( 'ftpServer', updateFtpDestination )
	propertyTable:addObserver( 'ftpRemotePath', updateFtpDestination )
	propertyTable:addObserver( 'useDateSubfolder', updateFtpDestination )

	-- -----------------------------------------------------------------
	-- Synopsis de la section « Réglages avancés »
	-- -----------------------------------------------------------------

	local function updateAdvancedSynopsis()
		propertyTable.advancedSynopsis = string.format(
			"%s · %s session(s) simultanée(s) · SSH actif",
			( propertyTable.ftpServer ~= "" and propertyTable.ftpServer or "?" ),
			tostring( propertyTable.ftpConcurrentUploads or 3 )
		)
	end

	propertyTable:addObserver( 'ftpServer', updateAdvancedSynopsis )
	propertyTable:addObserver( 'ftpConcurrentUploads', updateAdvancedSynopsis )

	-- -----------------------------------------------------------------
	-- Menu « Réglages avancés » : fermé à chaque ouverture de la fenêtre
	-- -----------------------------------------------------------------

	propertyTable.advancedOpen = false
	propertyTable.advancedToggleTitle = "Réglages avancés…"

	propertyTable:addObserver( 'advancedOpen', function()
		propertyTable.advancedToggleTitle = propertyTable.advancedOpen
			and "Masquer les réglages avancés"
			or "Réglages avancés…"
	end )

	-- -----------------------------------------------------------------
	-- État du navigateur de dossiers (affiché dans le panneau d'export)
	-- -----------------------------------------------------------------

	propertyTable.ftpBrowseOpen = false
	propertyTable.ftpBrowsePath = "/"
	propertyTable.ftpBrowseItems = {}
	propertyTable.ftpBrowseSelected = nil
	propertyTable.ftpBrowseHasFolders = false
	propertyTable.ftpBrowseCanGoUp = false
	propertyTable.ftpBrowseNewName = ""
	propertyTable.ftpBrowseStatus = ""
	propertyTable.ftpBrowseJump = "/"
	propertyTable.ftpBrowseJumpItems = { { title = "/", value = "/" } }

	-- Un clic dans la liste de sous-dossiers y entre directement, et un clic
	-- dans le chemin y saute. Les observers sont enregistrés UNE SEULE FOIS :
	-- sectionsForTopOfDialog peut être rappelé sans être démarré de nouveau.
	if not propertyTable.MPRNLBrowseObserver then
		propertyTable.MPRNLBrowseObserver = true

		propertyTable:addObserver( 'ftpBrowseSelected', function()
			local selected = propertyTable.ftpBrowseSelected
			if selected and selected ~= '' and browseState.navigate then
				browseState.navigate( selected )
			end
		end )

		propertyTable:addObserver( 'ftpBrowseJump', function()
			local target = propertyTable.ftpBrowseJump
			if target ~= nil
				and target ~= propertyTable.ftpBrowsePath
				and browseState.jumpTo then
				browseState.jumpTo( target )
			end
		end )
	end

	updateFtpDestination()
	updateAdvancedSynopsis()

end


-- Cette fonction dessine réellement les champs. Elle retourne une liste de
-- "sections" (des blocs avec un titre), chacune contenant les champs.
function MPRNLExportDialogSections.sectionsForTopOfDialog( viewFactory, propertyTable )

	local f = viewFactory

	-- ------------------------------------------------------------------
	-- Petits constructeurs de lignes, pour un rendu homogène
	-- ------------------------------------------------------------------

	local function label( title )
		return f:static_text {
			title = title,
			width = LABEL_WIDTH,
			alignment = 'right',
		}
	end

	-- Ligne "Libellé : [contrôle]" (un ou plusieurs contrôles à la suite).
	local function labeledRow( title, controls )
		local children = {
			spacing = f:label_spacing(),
			label( title ),
		}
		for _, control in ipairs( controls or {} ) do
			children[ #children + 1 ] = control
		end
		return f:row( children )
	end

	-- Petit texte d'aide, aligné sous les champs.
	local function hintRow( text )
		return f:row {
			spacing = f:label_spacing(),
			f:static_text { title = "", width = LABEL_WIDTH },
			f:static_text {
				title = text,
				text_color = HINT_COLOR,
			},
		}
	end

	local function separator()
		return f:separator { fill_horizontally = true }
	end

	-- Réglages FTP courants, dans le format attendu par LrFtp.
	local function ftpSettings()
		return {
			server = propertyTable.ftpServer,
			username = propertyTable.ftpUsername,
			password = propertyTable.ftpPassword,
			port = propertyTable.ftpPort,
			protocol = 'ftp',
			passive = propertyTable.ftpPassiveMode,
			path = '',
		}
	end

	-- Mémorise le mot de passe du compte (FTP et SSH, c'est le même).
	local function storePassword()
		local username = propertyTable.ftpUsername
		if username and username ~= "" and propertyTable.ftpPassword and propertyTable.ftpPassword ~= "" then
			LrPasswords.store( PASSWORD_SERVICE_NAME, propertyTable.ftpPassword, username )
		end
	end

	-- ------------------------------------------------------------------
	-- Journal d'export, affiché dans une zone de texte sélectionnable
	-- (le texte d'une boîte de message Lightroom est difficile à copier).
	-- ------------------------------------------------------------------

	local journalPath = LrPathUtils.child(
		LrPathUtils.getStandardFilePath( 'temp' ) or '.',
		'mprnl-export.log'
	)

	local function showJournal()
		local content = nil
		if LrFileUtils.exists( journalPath ) then
			content = LrFileUtils.readFile( journalPath )
		end

		if content == nil or content == '' then
			content = "(journal vide — aucun export n'a encore écrit)"
		end

		if #content > 8000 then
			content = "…\n" .. content:sub( -8000 )
		end

		local dialogFactory = LrView.osFactory()

		LrDialogs.presentModalDialog {
			title = "Journal d'export",
			contents = dialogFactory:column {
				spacing = dialogFactory:control_spacing(),
				dialogFactory:static_text {
					title = journalPath,
					text_color = HINT_COLOR,
				},
				dialogFactory:edit_field {
					value = content,
					width_in_chars = 90,
					height_in_lines = 20,
				},
			},
			actionVerb = "Fermer",
			cancelVerb = "< exclude >",
		}
	end

	-- ------------------------------------------------------------------
	-- Navigateur de dossiers (panneau intégré, affiché à la demande)
	-- ------------------------------------------------------------------

	local browseBusy = false

	local function runBrowseTask( taskName, body )
		if browseBusy then return end
		browseBusy = true
		propertyTable.ftpBrowseStatus = "Lecture du dossier…"

		LrFunctionContext.postAsyncTaskWithContext( taskName, function( context )
			context:addCleanupHandler( function() browseBusy = false end )
			LrDialogs.attachErrorDialogToFunctionContext( context )
			body()
		end )
	end

	-- Texte d'un niveau du chemin, façon fil d'Ariane :
	-- "/a/b" → "/ › a › b"
	local function crumbTitle( p )
		if p == '' or p == '/' then
			return '/'
		end

		local text = p:gsub( '^/', '' ):gsub( '/', ' › ' )
		if p:sub( 1, 1 ) == '/' then
			text = '/' .. text
		end
		return text
	end

	local function applyFolders( path, folders, note )
		if not folders then
			propertyTable.ftpBrowseItems = {}
			propertyTable.ftpBrowseHasFolders = false
			propertyTable.ftpBrowseStatus = "Échec : " .. tostring( note )
			return
		end

		local items = {}
		for _, name in ipairs( folders ) do
			items[ #items + 1 ] = { title = name, value = name }
		end

		propertyTable.ftpBrowseItems = items
		propertyTable.ftpBrowseSelected = nil
		propertyTable.ftpBrowseHasFolders = ( #items > 0 )

		-- Racine = '/' si le chemin est absolu, sinon le dossier de connexion.
		local root = ( path:sub( 1, 1 ) == '/' ) and '/' or ''
		propertyTable.ftpBrowseCanGoUp = ( MPRNLFtpBrowser.parentPath( path, root ) ~= nil )

		local text
		if #items == 0 then
			text = "Aucun sous-dossier."
		else
			text = string.format( "%d sous-dossier(s).", #items )
		end
		if note then
			text = text .. "   (" .. note .. ")"
		end
		propertyTable.ftpBrowseStatus = text
	end

	-- Construit la liste des niveaux du chemin : elle sert à l'affichage du
	-- chemin ET permet de sauter à n'importe quel niveau en un clic.
	--
	-- C'est calculé ICI (et non après la lecture du dossier) pour que le chemin
	-- soit mis à jour même si la lecture échoue.
	local function updatePathLevels( path )
		local root = ( path:sub( 1, 1 ) == '/' ) and '/' or ''

		local levels = { { title = crumbTitle( root ), value = root } }
		local accumulated = ''

		for part in path:gmatch( '[^/]+' ) do
			if accumulated == '' then
				accumulated = ( root == '/' and '/' or '' ) .. part
			else
				accumulated = accumulated .. '/' .. part
			end

			levels[ #levels + 1 ] = { title = crumbTitle( accumulated ), value = accumulated }
		end

		-- Ordre important : les éléments d'ABORD, la valeur ENSUITE. Dans
		-- l'autre sens, le menu se recalcule après et remet la valeur sur sa
		-- première entrée — le chemin resterait bloqué sur « / ».
		propertyTable.ftpBrowseJumpItems = levels
		propertyTable.ftpBrowseJump = path
	end

	-- Marque le navigateur en cours de lecture (ne lance pas de tâche).
	local function markLoading( path )
		path = MPRNLFtpBrowser.normalizePath( path )
		propertyTable.ftpBrowsePath = path
		propertyTable.ftpBrowseSelected = nil
		propertyTable.ftpBrowseHasFolders = false
		propertyTable.ftpBrowseStatus = "Lecture du dossier…"

		updatePathLevels( path )

		return path
	end

	-- Lit le dossier et met l'interface à jour. À appeler DEPUIS une tâche
	-- déjà lancée (c'est là que passent les opérations FTP).
	local function loadInto( path )
		local folders, note = MPRNLFtpBrowser.listFolders( ftpSettings(), path )
		applyFolders( path, folders, note )
	end

	-- Lance une tâche pour lire le dossier : c'est le cas d'entrée normal,
	-- déclenché par un clic de l'utilisateur.
	local function reload( path )
		path = markLoading( path )
		runBrowseTask( "MPRNLListFolder", function()
			loadInto( path )
		end )
	end

	-- Enregistre la navigation "en un clic" :
	--  - depuis la liste des sous-dossiers (descendre d'un niveau),
	--  - depuis le chemin (sauter à un niveau supérieur).
	browseState.navigate = function( selected )
		reload( MPRNLFtpBrowser.childPath( propertyTable.ftpBrowsePath, selected ) )
	end

	browseState.jumpTo = function( target )
		reload( target )
	end

	local function openBrowser()
		propertyTable.ftpBrowseOpen = true
		reload( propertyTable.ftpRemotePath )
	end

	local function closeBrowser()
		propertyTable.ftpBrowseOpen = false
		propertyTable.ftpBrowseStatus = ""
	end

	local function createFolder()
		local name = MPRNLFtpBrowser.trim( propertyTable.ftpBrowseNewName )
		if name == nil or name == '' then return end

		if name:find( '/', 1, true ) then
			propertyTable.ftpBrowseStatus = "Le nom d'un dossier ne peut pas contenir « / »."
			return
		end

		local parent = propertyTable.ftpBrowsePath

		runBrowseTask( "MPRNLCreateFolder", function()
			local ok, err = MPRNLFtpBrowser.createDirectory( ftpSettings(), parent, name )

			if not ok then
				propertyTable.ftpBrowseStatus = "Création impossible : " .. tostring( err )
				return
			end

			propertyTable.ftpBrowseNewName = ""

			-- On est DÉJÀ dans une tâche : on ne peut pas relancer runBrowseTask
			-- (il refuse les tâches superposées). On lit donc directement.
			loadInto( markLoading( MPRNLFtpBrowser.childPath( parent, name ) ) )
		end )
	end

	local function useCurrentFolder()
		propertyTable.ftpRemotePath = propertyTable.ftpBrowsePath
		closeBrowser()
	end

	-- Teste la connexion FTP, sans lancer d'export.
	local testingFtp = false

	local function testFtpConnection()
		if testingFtp then return end
		testingFtp = true

		LrFunctionContext.postAsyncTaskWithContext( "MPRNLTestFtp", function( context )
			context:addCleanupHandler( function() testingFtp = false end )
			LrDialogs.attachErrorDialogToFunctionContext( context )

			local settings = ftpSettings()
			LrDialogs.showBezel( "Test de la connexion FTP…" )

			local connection, connectError = MPRNLFtpBrowser.connect( settings )

			if not connection then
				LrDialogs.message(
					"MPRNL – FTP",
					"Connexion refusée.\n\n"
						.. "Détail :\n"
						.. tostring( connectError )
						.. "\n\nRéglages utilisés :\n"
						.. MPRNLFtpBrowser.describeSettings( settings ),
					"critical"
				)
				return
			end

			storePassword()

			local folderOk, folderError = MPRNLFtpBrowser.remoteFolderExists(
				connection, propertyTable.ftpRemotePath
			)
			MPRNLFtpBrowser.disconnect( connection )

			if folderOk then
				LrDialogs.message(
					"MPRNL – FTP",
					"Connexion réussie.\n\n" .. MPRNLFtpBrowser.describeSettings( settings ),
					"info"
				)
			else
				LrDialogs.message(
					"MPRNL – FTP",
					"Connexion réussie, mais le dossier de destination pose problème :\n\n"
						.. tostring( folderError ),
					"warning"
				)
			end
		end )
	end

	-- Teste la connexion SSH (compte identique au FTP).
	local testingSsh = false

	local function testSshConnection()
		if testingSsh then return end
		testingSsh = true

		LrFunctionContext.postAsyncTaskWithContext( "MPRNLTestSsh", function( context )
			context:addCleanupHandler( function() testingSsh = false end )
			LrDialogs.attachErrorDialogToFunctionContext( context )

			local settings = MPRNLSsh.settingsFromPropertyTable( propertyTable )
			LrDialogs.showBezel( "Test de la connexion SSH…" )

			local ok, output = MPRNLSsh.test( settings )

			if ok then
				storePassword()
				LrDialogs.message(
					"MPRNL – SSH",
					"Connexion réussie !\n\nRéponse du serveur :\n" .. tostring( output ),
					"info"
				)
			else
				LrDialogs.message(
					"MPRNL – SSH",
					"Échec de la connexion.\n\n" .. tostring( output ),
					"critical"
				)
			end
		end )
	end

	-- Ouverture / fermeture du menu « Réglages avancés ».
	local function toggleAdvanced()
		propertyTable.advancedOpen = not propertyTable.advancedOpen
	end


	-- =================================================================
	-- Section 1 : Destination (seule chose affichée en permanence)
	-- =================================================================

	local destinationSection = {
		title = "Destination",
		synopsis = bind 'ftpSynopsis',

		labeledRow( "Dossier distant :", {
			f:edit_field {
				value = bind 'ftpRemotePath',
				width_in_chars = FIELD_WIDTH,
				fill_horizontally = 1,
				placeholder_string = "/  (racine du compte)",
			},
			f:push_button {
				title = "Parcourir…",
				action = openBrowser,
			},
		} ),

		hintRow( "Les fichiers sont envoyés dans ce dossier. « / » = racine du compte FTP." ),

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = "", width = LABEL_WIDTH },
			f:checkbox {
				title = "Sous-dossier automatique au format AAAA-MM-JJ",
				value = bind 'useDateSubfolder',
			},
		},

		hintRow( "Calculé sur la date de prise de vue de la PREMIÈRE photo : une séance qui se prolonge après minuit reste sous la date de départ." ),

		labeledRow( "Destination finale :", {
			f:static_text {
				title = bind 'ftpDestination',
				width_in_chars = 46,
				truncation = 'middle',
				selectable = true,
			},
		} ),

		-- Panneau du navigateur, affiché à la demande.
		f:column {
			visible = bind 'ftpBrowseOpen',
			spacing = f:control_spacing(),

			separator(),

			labeledRow( "Chemin :", {
				f:popup_menu {
					items = bind 'ftpBrowseJumpItems',
					value = bind 'ftpBrowseJump',
					width_in_chars = 40,
				},
			} ),

			labeledRow( "Sous-dossiers :", {
				f:popup_menu {
					items = bind 'ftpBrowseItems',
					value = bind 'ftpBrowseSelected',
					width_in_chars = 34,
					enabled = bind 'ftpBrowseHasFolders',
				},
			} ),

			labeledRow( "Nouveau dossier :", {
				f:edit_field {
					value = bind 'ftpBrowseNewName',
					width_in_chars = 22,
					placeholder_string = "nom du dossier",
				},
				f:push_button {
					title = "Créer",
					action = createFolder,
				},
				f:push_button {
					title = "Rafraîchir",
					action = function() reload( propertyTable.ftpBrowsePath ) end,
				},
			} ),

			labeledRow( "", {
				f:push_button {
					title = "Utiliser ce dossier",
					action = useCurrentFolder,
				},
				f:push_button {
					title = "Fermer",
					action = closeBrowser,
				},
			} ),

			labeledRow( "", {
				f:static_text {
					title = bind 'ftpBrowseStatus',
					text_color = HINT_COLOR,
				},
			} ),
		},
	}


	-- =================================================================
	-- Section 2 : Réglages avancés (fermée par défaut)
	-- =================================================================

	local advancedDetails = {
		spacing = f:control_spacing(),
		visible = bind 'advancedOpen',

		separator(),

		labeledRow( "Serveur :", {
			f:edit_field {
				value = bind 'ftpServer',
				width_in_chars = FIELD_WIDTH,
			},
		} ),

		labeledRow( "Utilisateur :", {
			f:edit_field {
				value = bind 'ftpUsername',
				width_in_chars = FIELD_WIDTH,
			},
		} ),

		labeledRow( "Mot de passe :", {
			f:password_field {
				value = bind 'ftpPassword',
				width_in_chars = FIELD_WIDTH,
			},
		} ),

		hintRow( "Enregistré de façon sécurisée sur cet ordinateur (trousseau système)." ),

		f:row {
			spacing = f:label_spacing(),
			label( "Port :" ),
			f:edit_field {
				value = bind 'ftpPort',
				width_in_chars = 6,
				precision = 0,
			},
			f:spacer { width = 24 },
			f:static_text { title = "Mode :", alignment = 'right' },
			f:popup_menu {
				value = bind 'ftpPassiveMode',
				width_in_chars = 14,
				items = {
					{ title = "Passif", value = "normal" },
					{ title = "Actif", value = "none" },
				},
			},
		},

		labeledRow( "", {
			f:push_button {
				title = "Tester la connexion FTP",
				action = testFtpConnection,
			},
		} ),

		separator(),

		labeledRow( "Serveur SSH :", {
			f:static_text { title = bind 'ftpServer' },
		} ),

		hintRow( "Le compte SSH est le même que le compte FTP : aucun identifiant à saisir." ),

		labeledRow( "plink.exe :", {
			f:edit_field {
				value = bind 'sshPlinkPath',
				width_in_chars = FIELD_WIDTH,
				fill_horizontally = 1,
				placeholder_string = "C:\\Program Files\\PuTTY\\plink.exe",
			},
			f:push_button {
				title = "Détecter",
				action = function()
					local detected = MPRNLSsh.detectPlink()
					if detected then
						propertyTable.sshPlinkPath = detected
					else
						LrDialogs.message(
							"MPRNL – SSH",
							"plink.exe est introuvable.\n\n"
								.. "Installe PuTTY (https://www.putty.org/) puis clique à nouveau sur « Détecter », "
								.. "ou saisis directement le chemin complet de plink.exe.",
							"info"
						)
					end
				end,
			},
		} ),

		labeledRow( "Port SSH :", {
			f:edit_field {
				value = bind 'sshPort',
				width_in_chars = 6,
				precision = 0,
			},
		} ),

		labeledRow( "Clé d'hôte :", {
			f:edit_field {
				value = bind 'sshHostKey',
				width_in_chars = FIELD_WIDTH,
				fill_horizontally = 1,
				placeholder_string = "facultatif — clé OpenSSH ou empreinte",
			},
		} ),

		hintRow( "Laisser vide : la clé du serveur est récupérée automatiquement (ssh-keyscan)." ),

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = "", width = LABEL_WIDTH },
			f:checkbox {
				title = "Récupérer automatiquement la clé d'hôte (ssh-keyscan)",
				value = bind 'sshAutoAcceptHostKey',
			},
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = "", width = LABEL_WIDTH },
			f:push_button {
				title = "Tester la connexion SSH",
				action = testSshConnection,
			},
		},

		separator(),

		labeledRow( "Envois simultanés :", {
			f:edit_field {
				value = bind 'ftpConcurrentUploads',
				width_in_chars = 4,
				precision = 0,
			},
			f:static_text {
				title = "connexions FTP en parallèle (1 à 4)",
				text_color = HINT_COLOR,
			},
		} ),

		separator(),

		labeledRow( "", {
			f:push_button {
				title = "Journal d'export…",
				action = showJournal,
			},
		} ),
	}

	-- Commandes SSH exécutées, affichées en lecture seule pour information.
	table.insert( advancedDetails, separator() )
	table.insert( advancedDetails, labeledRow( "Commandes SSH :", {
		f:static_text {
			title = "(définies dans MPRNLSsh.lua)",
			text_color = HINT_COLOR,
		},
	} ) )

	for _, command in ipairs( MPRNLSsh.COMMANDS ) do
		table.insert( advancedDetails, labeledRow( "", {
			f:static_text {
				title = command,
				text_color = COMMAND_COLOR,
			},
		} ) )
	end

	local advancedSection = {
		title = "Réglages avancés",
		synopsis = bind 'advancedSynopsis',

		f:row {
			f:push_button {
				title = bind 'advancedToggleTitle',
				action = toggleAdvanced,
			},
		},

		f:column( advancedDetails ),
	}

	return { destinationSection, advancedSection }

end

return MPRNLExportDialogSections
