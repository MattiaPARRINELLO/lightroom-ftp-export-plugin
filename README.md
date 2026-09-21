# MPRNL FTP Exporter

Plugin **Lightroom Classic** qui envoie les photos directement vers un serveur
FTP — sans étape « exporter puis téléverser à la main » — puis exécute des
commandes sur le serveur en SSH après chaque export.

**Site : [mprnl.fr](https://mprnl.fr)**

> Ce dépôt est un **fork** de
> [`Pixilive/lightroom-ftp-export-plugin`](https://github.com/Pixilive/lightroom-ftp-export-plugin),
> rebrandé et considérablement étendu. Voir la section [Attribution](#attribution).

## Fonctionnalités

### Export

- Destination FTP intégrée à la boîte d'export de Lightroom (serveur,
  utilisateur, mot de passe, port, mode passif/actif).
- **Navigation dans les dossiers du serveur depuis l'interface** : descente en
  un clic, saut à n'importe quel niveau du chemin en un clic, création de
  dossier, chemin affiché en permanence dans la « Destination finale ».
- **Sous-dossier automatique `AAAA-MM-JJ`**, calculé sur la date de prise de
  vue de la **première** photo de la série (une séance qui se prolonge après
  minuit reste sous la date de départ), créé automatiquement.
- **Envois simultanés** (1 à 4, 3 par défaut) avec reconnexion et **3 tentatives
  par fichier** en cas d'échec, puis **proposition de reprendre** les envois
  en échec.
- **Trois barres de progression distinctes** : rendu des photos, transferts
  (avec le nom du fichier en cours) et réindexation du serveur.

### Masques IA

Lightroom ne recalcule pas les masques générés par IA tout seul. Au lancement
de l'export, le plugin **vérifie les photos concernées et propose de les
recalculer** avant d'envoyer quoi que ce soit.

### Commandes SSH après l'export

- Exécution systématique après chaque export complet (via `plink.exe`,
  fourni avec PuTTY), **après** la fin de tous les transferts.
- Compte SSH **identique au compte FTP** : aucun identifiant à ressaisir.
- Clé d'hôte récupérée automatiquement (`ssh-keyscan`), ou épinglable.
- **Résultat du scan affiché** à la fin de l'export.

## Installation

1. Récupère le dossier `MPRNL-FTP-Exporter.lrplugin` (Release ou clone du dépôt).
2. Place-le à un endroit permanent de ton disque (Lightroom le lit en place).
3. Dans Lightroom Classic : **Fichier → Gestionnaire des plugins…**
4. **Ajouter**, puis sélectionner le dossier `MPRNL-FTP-Exporter.lrplugin`.
5. Vérifie que le statut indique **« Installé et en cours d'exécution »**.

## Utilisation

1. Sélectionne tes photos, puis **Fichier → Exporter…**
2. Dans **« Exporter vers »**, choisis **« MPRNL FTP Exporter »**.
3. Renseigne le **Dossier distant** (bouton **Parcourir…** pour naviguer).
4. Clique sur **Exporter**.

Tout le reste (serveur, SSH, envois simultanés…) se règle dans la section
**« Réglages avancés »**, fermée par défaut : une fois configuré, on n'y
revient plus.

Une fois réglé, enregistre le tout en **preset d'export Lightroom** (bouton
« Ajouter » en bas à gauche de la fenêtre d'export).

## Documentation détaillée

L'ensemble des réglages, le journal de diagnostic, les contraintes du SDK
Lightroom et les notes de sécurité sont décrits dans
**[DOCUMENTATION.md](DOCUMENTATION.md)**.

## Compatibilité

Lightroom Classic 15.3 et suivants (SDK 15.3), Windows et macOS.
Serveur FTP requis ; `plink.exe` (PuTTY) requis pour les commandes SSH.

## Attribution

Fork de [`Pixilive/lightroom-ftp-export-plugin`](https://github.com/Pixilive/lightroom-ftp-export-plugin),
initialement écrit et maintenu par
[Pixilive](https://about.pixi.live). Les modifications, extensions et le
rebranding de cette version sont proposés ici ; l'auteur d'origine reste
crédité.

Le dépôt amont ne comporte **aucune licence explicite**. Ce fork est donc
distribué à titre de contribution / usage personnel, sans retrait des
droits d'auteur de l'auteur d'origine.

## Support

Un bug ou une question ? Ouvre une *issue* sur ce dépôt.
