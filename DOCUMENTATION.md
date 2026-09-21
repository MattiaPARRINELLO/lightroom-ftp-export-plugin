# MPRNL FTP Exporter — documentation

Plugin Lightroom Classic qui exporte les photos rendues vers un serveur FTP,
avec deux ajouts par rapport à la version d'origine :

1. **Choix interactif du dossier distant** (parcourir / naviguer / créer).
2. **Exécution de commandes SSH après l'export** (via `plink.exe`).

---

## 1. L'interface

La fenêtre d'export ne montre que l'essentiel, et tout le reste est replié.

```
Destination
  Dossier distant  [____________________________] [Parcourir…]
  ☐ Sous-dossier automatique au format AAAA-MM-JJ
  Destination finale : cloud.mprnl.fr/data/admin/files / AAAA-MM-JJ

Réglages avancés                     mattiaparrinello.fr · 3 session(s) · SSH actif
  [Réglages avancés…]                          ← un clic pour tout déplier
```

**Section « Réglages avancés »** (fermée à chaque ouverture, un clic pour
l'ouvrir) contient tout ce qui ne se touche qu'une seule fois :

- **Connexion** : Serveur, Utilisateur, Mot de passe, Port, Mode, et le bouton
  **« Tester la connexion FTP »** ;
- **SSH** : serveur (repris du FTP), `plink.exe`, port, clé d'hôte, et le
  bouton **« Tester la connexion SSH »** ;
- **Envois simultanés** (3 par défaut) ;
- **Journal d'export…** ;
- les commandes SSH exécutées, en lecture seule.

Il n'y a **pas de case pour activer ou désactiver le SSH** : les commandes
s'exécutent après chaque export. De même, la proposition de recalcul des
masques IA est faite systématiquement, sans case à cocher.

## 2. Dossier distant

- **Dossier distant** : chemin de destination sur le serveur.
  La valeur par défaut est `cloud.mprnl.fr/data/admin/files`.
  - `/` seul = racine du compte FTP ;
  - `cloud.mprnl.fr/data/admin/files` = chemin relatif au dossier de connexion.
- **Destination finale** : récapitulatif permanent du chemin qui sera
  réellement utilisé, date incluse — c'est le meilleur garde-fou contre les
  fautes de frappe.
- **Sous-dossier automatique au format AAAA-MM-JJ** (case à cocher, activée
  par défaut) : les fichiers sont rangés dans un sous-dossier daté, créé au
  besoin. La date retenue est celle de **la première photo** de la série — une
  séance qui se prolonge après minuit reste donc sous la date de départ.

  Si le dossier n'apparaît pas, regarde le journal (bouton « Journal
  d'export… ») : chaque étape y est tracée —

  ```
  Photos à exporter : 24
  Sous-dossier par date : option = true | 24 photo(s)
  Sous-dossier par date : getRawMetadata('dateTimeOriginal') -> 1758496200 (number)
  Sous-dossier par date : 2026-09-21  (source : dateTimeOriginal)
  Destination : base = ... | dossier = .../2026-09-21 | sous-dossier = 2026-09-21
  ```

  La ligne « option = false » signifie que la case est décochée, et
  « AUCUNE photo fournie » que Lightroom n'a pas transmis la sélection.
- **Bouton « Parcourir… »** : déploie un **panneau de navigation intégré**
  (pas de fenêtre séparée) :
  - **chemin cliquable** affiché en fil d'Ariane
    (`/ › cloud.mprnl.fr › data › admin › files`) : un menu déroulant listant
    tous les niveaux, dont la sélection **y saute en un clic**. Il se met à
    jour **dès la navigation**, indépendamment du succès de la lecture ;
  - liste de sous-dossiers : **un clic pour y entrer** (plus de bouton
    « Ouvrir » à valider ensuite) ;
  - **Créer** un nouveau dossier, **Rafraîchir** ;
  - **« Utiliser ce dossier »** pour valider, **« Fermer »** pour abandonner.

Un seul niveau est lu à la fois : les sous-dossiers ne sont chargés que
lorsqu'on les ouvre. Chaque lecture est une seule requête FTP.

Le dossier choisi est mémorisé dans les presets d'export Lightroom.

> Le navigateur se connecte réellement au serveur, avec les identifiants FTP
> saisis dans la même fenêtre. Si le mot de passe n'est pas encore renseigné,
> la connexion échouera — le bouton **« Tester la connexion FTP »** permet de
> vérifier avant.

---

## 3. Pendant l'export

Une **barre de progression Lightroom** s'affiche avec le nombre de photos à
envoyer, **le nom du fichier en cours** et un bouton **Annuler** fonctionnel.

**Deux barres distinctes.** Comme le rendu des photos et leur transfert sont
deux choses différentes, il y a maintenant :

| Barre | Ce qu'elle mesure |
| --- | --- |
| **Export de N photos** | la préparation des fichiers par Lightroom (`Préparation : IMG_4821.jpg`) |
| **Envoi vers le serveur** | les transferts (`7 / 24 — IMG_4819.jpg`) |

C'est la seconde qui te dit où en sont réellement les envois.

**Envois simultanés.** Réglable dans les **Réglages avancés** — **3 par
défaut**. Sur beaucoup de petits fichiers, c'est nettement plus rapide.
Attention : certains hébergeurs limitent le nombre de connexions par compte ;
si tu vois des erreurs de connexion, remets la valeur à **1**.

**Tentatives et reprise.** Chaque fichier est tenté **3 fois**, avec
reconnexion complète de la session FTP entre les tentatives. À la fin de
l'export, si des fichiers ont échoué, une **copie est conservée** et le plugin
propose de **réessayer** leur envoi immédiatement.

Les fichiers temporaires rendus par Lightroom sont supprimés au fur et à
mesure de l'envoi, pour ne pas saturer le disque sur les grosses séries.

**Journal.** Le bouton **« Journal d'export… »** affiche le déroulement
complet dans une zone de texte sélectionnable (donc copiable). Le fichier
reste aussi disponible dans `%TEMP%\mprnl-export.log`.

> Limite du SDK : `LrFtp` n'expose **aucun réglage de timeout**, et un
> transfert bloqué ne peut pas être interrompu. Si ce cas se présente, il
> faudra passer par `curl` (qui gère `--max-time`).

---

## 4. Masques IA avant l'export

Lightroom ne recalcule pas automatiquement les masques générés par IA (sujet,
ciel, personnes, retouches IA…). Ses propres exports se contentent d'un
avertissement.

Ici, le plugin va plus loin : **à chaque export**, il **vérifie les photos à
envoyer** et, si certaines ont des réglages IA obsolètes, il **propose de les
recalculer avant l'export** (pas de case à cocher, la proposition est
toujours faite) :

> *12 photo(s) de cet export ont des masques IA à recalculer.*
> **[Mettre à jour et exporter]** / **[Exporter sans mettre à jour]**

La mise à jour se fait via `catalog:updateAISettings()`. Lightroom ignore les
photos qui n'ont pas besoin d'être recalculées. **Pas de case à cocher** : la
proposition est faite à chaque export, uniquement quand il y a quelque chose à
recalculer.

> La détection (`LrPhoto:needsUpdateAISettings()`, SDK 15.3+) est testée à
> l'exécution : sur une version plus ancienne de Lightroom, l'étape est
> simplement ignorée, sans erreur.

---

## 5. Commandes SSH après l'export

Réglages dans la section **« Réglages avancés »** :

1. Vérifie le chemin de `plink.exe` (bouton **« Détecter »**) et, si besoin,
   le port SSH (22 par défaut).
2. Clique sur **« Tester la connexion SSH »** pour valider.

> Le compte SSH est **le même que le compte FTP** : le serveur, l'utilisateur
> et le mot de passe sont repris automatiquement de la section
> « Destination »/« Réglages avancés ». Rien à ressaisir.

### Quand les commandes sont-elles exécutées ?

**À la fin de chaque export**, systématiquement — **même si l'envoi a échoué**,
puisque le scan est global et ne dépend pas de ce qui vient d'arriver. Il n'y
a **pas de case à cocher** : l'option est toujours active.

Seul un export **annulé** les empêche de partir.

Chaque cas est tracé dans `%TEMP%\mprnl-export.log`, par exemple :

```
SSH : ignoré (export annulé)
Exécution SSH (12 fichier(s) envoyé(s)) : cd cloud.mprnl.fr && ./occ files:scan --all
SSH OK : ...
```

Et le **résultat du scan est affiché** à la fin de l'export, dans une boîte de
dialogue : c'est ce qui te dit si la galerie a bien pris les photos (Nextcloud
répond par exemple `Added 24 files`).

### Barre de progression dédiée

Les commandes serveur ont **leur propre barre de progression**
(« Réindexation du serveur »), indépendante de celle de l'envoi. Elle reste
affichée tant que le scan tourne, ce qui évite de croire que l'opération est
terminée alors qu'elle continue.

### Ordre d'exécution

Les commandes SSH sont lancées **strictement après la fin de tous les envois** :

1. boucle d'envoi de **tous** les fichiers (avec tentatives et reconnexion) ;
2. **fermeture propre de la session FTP** (`QUIT`) ;
3. une **marge de 3 secondes** pour que le serveur ait fini de prendre en
   compte les fichiers ;
4. exécution des commandes.

Le journal le montre dans cet ordre :

```
Envoi terminé : 24 réussi(s), 0 échec(s)
Pause de 3 s avant les commandes serveur
Exécution SSH (24 fichier(s) envoyé(s)) : cd cloud.mprnl.fr && ./occ files:scan --all
SSH OK : ...
```

La marge est définie par la constante `SETTLE_DELAY_SECONDS` dans
`MPRNLExportServiceProvider.lua` (mettre à `0` pour la désactiver).

### Durée

Le scan Nextcloud (`occ files:scan --all`) peut prendre du temps sur une grosse
instance — c'est normal. C'est justement pour ça qu'il a sa propre barre de
progression : tu vois qu'il travaille encore.

### Identifiants mémorisés

Le mot de passe est stocké dans le trousseau système dès la première
connexion réussie (test FTP, test SSH ou export). Aux ouvertures suivantes, il
est rechargé automatiquement dès que le nom d'utilisateur est connu.

### Prérequis : plink.exe

Lightroom n'a pas d'API SSH. Le plugin utilise **`plink.exe`**, le client en
ligne de commande fourni avec PuTTY :

1. Télécharge PuTTY : <https://www.putty.org/>
2. Installe-le (ou copie simplement `plink.exe` quelque part).
3. Le plugin détecte automatiquement les emplacements habituels
   (`C:\Program Files\PuTTY\plink.exe`, …). Sinon, clique sur **« Détecter »**
   ou saisis le chemin complet.

> PuTTY **0.77 ou plus récent** est recommandé (option `-pwfile`, qui évite
> de faire apparaître le mot de passe dans la ligne de commande). Avec une
> version plus ancienne, le plugin bascule automatiquement sur `-pw`.

### Clé d'hôte du serveur

`plink` refuse de se connecter à un serveur dont la clé d'hôte est inconnue —
et sa question interactive **ne peut pas** recevoir de réponse automatique
(plink la lit depuis la console, pas depuis l'entrée standard : il se bloque
indéfiniment). Le plugin procède donc autrement :

- **Par défaut**, il récupère la clé du serveur avec **`ssh-keyscan`** (livré
  avec Windows 10/11), puis la transmet à `plink` via `-hostkey`. C'est ce que
  fait la case **« Récupérer automatiquement la clé d'hôte »**, cochée par
  défaut. `plink` tourne alors toujours en mode `-batch` : aucune question,
  donc aucun blocage possible.
- **Pour épingler la clé** (plus sûr), colle la clé OpenSSH
  (`ssh-ed25519 AAAA…`) ou son empreinte (`SHA256:…`) dans le champ
  **« Clé d'hôte »**. Elle sera alors vérifiée à chaque connexion, et toute
  autre clé sera refusée.

> La récupération automatique fait confiance au serveur au moment de la
> récupération (comportement « trust on first use », comme un `ssh` classique).
> Pour une vérification stricte, épingle la clé dans le champ prévu.

### Commandes exécutées

Elles sont définies dans `MPRNLSsh.lua`, en haut du fichier :

```lua
MPRNLSsh.COMMANDS = {
	"cd cloud.mprnl.fr && ./occ files:scan --all",
}
```

Chaque ligne est exécutée dans la même session SSH. Variables de
substitution disponibles : `{remote_path}`, `{ftp_host}`, `{date}`.

---

## Fichiers du plugin

| Fichier | Rôle |
| --- | --- |
| `Info.lua` | Manifeste du plugin (nom, version, point d'entrée). |
| `MPRNLExportServiceProvider.lua` | Cœur de l'export : upload FTP puis commandes SSH. |
| `MPRNLExportDialogSections.lua` | Interface de la boîte de dialogue d'export. |
| `MPRNLFtpBrowser.lua` | Utilitaires FTP (connexion, listing, création de dossier, chemins). |
| `MPRNLSsh.lua` | Exécution des commandes via `plink.exe`. |

## Notes techniques (pour les modifications futures)

Deux pièges du SDK Lightroom qui ont déjà provoqué des bugs ici :

- **Toujours utiliser `LrTasks.pcall`, jamais `pcall`**, autour d'un appel
  réseau (`LrFtp.create`, `getContents`, `exists`, `putFile`, `makeDirectory`)
  ou d'un dialogue modal. Ces appels « yield » pour ne pas figer l'interface,
  et un `pcall` Lua standard ne supporte pas un yield : il lève
  `attempt to yield across C-call boundary`.
- **`os` est réduit** : seuls `clock`, `date`, `time` et `tmpname` existent
  (`os.getenv` a été supprimé). `io`, `math` et `string` sont disponibles.

## Sécurité

- Les mots de passe (FTP et SSH) sont stockés dans le **trousseau système**
  via `LrPasswords`, jamais dans les presets.
- Les commandes SSH sont écrites dans un fichier temporaire, puis supprimé.
- Le mot de passe SSH est écrit dans un fichier temporaire (option `-pwfile`
  de plink) qui est supprimé immédiatement après exécution.
