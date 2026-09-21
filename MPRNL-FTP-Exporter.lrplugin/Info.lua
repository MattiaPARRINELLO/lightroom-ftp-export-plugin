return {

	LrSdkVersion = 15.3,
	LrSdkMinimumVersion = 6.0,

	-- Identifiant unique du plugin. Doit ressembler à un nom de domaine inversé.
	-- Ne JAMAIS changer cette valeur une fois le plugin distribué : c'est ce qui
	-- permet à Lightroom de reconnaître "le même plugin" d'une mise à jour à l'autre.
	LrToolkitIdentifier = 'fr.mprnl.lightroom.ftpexport',

	LrPluginName = "MPRNL FTP Exporter",
	LrPluginInfoUrl = "https://mprnl.fr",

	-- C'est cette ligne qui dit à Lightroom : "ce plugin ajoute une destination
	-- d'export". Le fichier référencé doit exister à côté de celui-ci.
	LrExportServiceProvider = {
		title = "MPRNL FTP Exporter",
		file = 'MPRNLExportServiceProvider.lua',
	},

	VERSION = { major = 3, minor = 2, revision = 0, build = 0 },

}
