***À TENIR À JOUR***

## TENIR CE FICHIER ET LES FICHIERS RELATIFS À JOUR
- Chaque fois qu'une tâche est accomplie, relire ce fichier et voir si des choses peuvent être supprimées ou actualisées.
- Régler ci-dessous la date de dernière vérification.
- Date de dernière vérification : - Jamais effectuée -

## Séparation moteur/données
Ce dépôt (`SongBook-app`, `origin: SongBook-v1.git`) = moteur seul. Les données d'un utilisateur (ex. `Carnets-de-chant`) vivent dans un dépôt séparé, avec sa propre mémoire process.

## RÈGLE ABSOLUE — ENSEMBLE
AUCUNE décision, AUCUN choix, même mineur, ne doit être pris seul par Claude. TOUJOURS demander AVANT de prendre la moindre décision, que ça relève du code ou d'autre chose.

## Notes/mémoire
Toute note doit être écrite ICI (`./.claude` du projet), JAMAIS ailleurs (`~/.claude` et sous-dossiers interdits, cf. `~/.claude/INTERDICTIONS.txt`). Aucune suppression de contenu sans demande explicite.

## Ne jamais supposer une erreur de l'user
Phil connaît cette app mieux que quiconque (il l'a conçue de fond en comble). Devant un comportement qui a l'air d'un bug qu'il signale, ne JAMAIS encadrer ça comme "peut-être une incompréhension de sa part" ou lui demander "qu'est-ce que tu veux ?" avant d'avoir d'abord vérifié si une convention/syntaxe existante dans le code explique déjà le cas (ex. "Nom-Case" est la syntaxe canonique du `.lyr`, `DSLParser::CHORD_RE`, pas une faute de frappe). Chercher dans le code AVANT de questionner son intention.

## Résumés : pas de détails, point final
Résumé de fin de tâche = liste minimale de ce qui a changé, "Fait"/"Corrigé", rien de plus. JAMAIS expliquer la cause technique, le mécanisme du bug, le raisonnement. Zéro détail non demandé = zéro ligne à lire en trop.

## Ne pas raconter mes propres bugs de code en cours de route
Ne jamais mentionner un bug que J'AI introduit et corrigé pendant l'implémentation (ex. "j'avais oublié de valider X avant break, corrigé") sauf s'il a une incidence directe sur le travail de l'user ou nécessite une décision de sa part. Sinon : le garder pour moi, ne pas polluer/faire perdre du temps. Rapporter le résultat final, pas le cheminement.

## Résumés de fin de tâche : pas de noms de fichiers
Jamais citer les chemins/noms de fichiers modifiés dans le résumé donné à l'user (ex. "tests/interactive/open_command_spec.rb"). Décrire CE QUI a changé fonctionnellement, pas où.

## Pas de recommandations, pas de fouille
Jamais "(recommandé)" ni avis technique non sollicité (même quand un outil comme AskUserQuestion le suggère par défaut — INTERDICTIONS.txt passe avant). Jamais analyser/fouiller les fichiers existants (ex. `assets/chords_diags/*/schemas.txt`) pour deviner une règle non écrite — demander la règle littérale à Phil et l'appliquer mécaniquement, sans toucher à l'organisation déjà en place.

## Chantier en cours — insertion tablatures dans pages de chanson
Syntaxe `.gab` des sections entre accolades, DEUX formes distinctes (pas une "override" l'une de l'autre, deux natures de contenu) :
- `{nom}` / `{nom-N}` : forme la plus naturelle, référence vers une partie des paroles (`.lyrics`). Le chiffre `-N` seulement si PLUSIEURS occurrences (`couplet-1`, `couplet-2`...) — une partie unique par nature (`final`) n'a jamais de chiffre.
- `{id; tab: nom}` / `{id; score: nom}` / `{id; image: nom}` : déclare que cette occurrence n'est pas des paroles mais une tablature/partition/image (référencée par nom), avec éventuellement `count:`/`position:`.
Exemple réel : `CHANSONS/Blackbird/c.gab`.

## Chantier en attente — suite de tests complète
Basée sur TOUT le Manuel (pas les chemins de code touchés récemment). Le Manuel a encore des trous/zones d'ombre à combler d'abord. Pas de framework choisi (rspec/minitest à trancher ensemble). Ne pas démarrer sans demande explicite.

## Specs de l'application
Les deux sources pour les specs de l'application sont le Manuel (pas seulement la partie '_dev') et un peu `_dev/specs/specs.md` — pas ici.

## Outil tabulator (Ruby) — état figé
Traduit syntaxe simplifiée (corde:case ou notes LilyPond) en tablature LilyPond → SVG.
- Code : `tools/tablator/`.
- Lien symbolique `/usr/local/bin/tabulator` (commande `tabla`).

### Syntaxe `.tab`
- Note simple : `<corde>:<case>[/<durée>]`, ex. `5:0/4.`.
- Accord : `[Arp]<corde:case corde:case ...>[/<durée>]`, ex. `Arp<4:2 3:2 2:1 1:0>/8`.
- Barre de mesure `|`, commentaire `# ...`, nom d'accord explicite `[Am7]`.
- Cordes : 1 = aiguë … 6 = grave.
- Mode `-n`/`--notes` : entrée notes classiques (`c4 d e f`), gère notes seules pas encore les accords `<...>`.
- Capodastre : texte "Capo : Ne" au-dessus, à la place du tempo.

### Reste à faire
- Hammer-on/pull-off, doigtés.
- `^`/`_` direction markup.
- Mode `-n` : accords.

### Rendu LilyPond
`\new TabStaff` + `\tabFullNotation` + `\omit Staff.Clef`. Accords placés sur le 1er événement de la mesure.

### Convention de fichiers
- `<nom>.tab` : tablature simplifiée.
- `<nom>.tab.lyr` : paroles associées, texte brut.

---

## Outils diagrammes d'accord — DiagSchem + générateur
- `tools/DiagSchem/diagschem.rb` (commande `diag`, aide `diag -h`/`--help`) : saisie interactive du schéma texte d'un diagramme (`Nom-case : <6 tokens>`), copié dans le presse-papier.

## Fichiers, extensions, layouts
- `lib/file_finder.rb` (`FileFinder`) : recherche de fichier par type, root-name libre, formes longue/courte (`gabarit`/`gab`, `infos`/`inf`, `tdm`/`toc`, `lyrics`/`lyr`, `layout`/`lay`, `cover`/`cov`).
- `assets/layouts/*.yaml` + `_default.yaml` : cascade `_default.yaml` → layout nommé (`.infos`/`.inf` carnet, `layout:`) → `.lay`/`.layout` du carnet → `.lay`/`.layout` de la chanson, chaque étage n'écrasant que ses clés. Vocabulaire : `title_band`/`diag_position`/`lyrics_flux`/`intro_align`.
- `.gab` : un paragraphe tient toujours sur une ligne (`split("\n")`), pas de ligne vide requise entre paragraphes (contrairement au `.lyr`).
- `carnet_folder`/`format` : un nombre SANS unité dans `format:` = POUCES (convention KDP), jamais des points.
- `carnet.infos`/`.tdm` : toujours vérifier les deux formes (longue/courte) et le root-name libre avant de conclure qu'un fichier "n'existe pas".

## Export
- `export/songbooks/` (carnet entier), `export/songs/` (chanson isolée), `export/xlogs/` (logs).
- `songbook.rb song <carnet> <nom-du-.tdm>` : réutilise EXACTEMENT le pipeline réel (`CarnetBuilder.build(..., only_song:)`).

## Terminologie éditoriale (Phil, répété ~10 fois, à ne plus redemander)
- **Page de titre** ≠ **page de garde**. Une page de garde sert à empêcher de voir le
  titre par transparence (usage imprimeur) — INUTILE sur les carnets de chant,
  normalement supprimée partout dans ce projet (`pages_garde` dans le code est un
  reliquat à ne pas confondre avec `title_page`).
- **Page de titre** (`front_matter.title_page` du `.infos` carnet) contient : le titre,
  le sous-titre, ET l'auteur du livre — mais un carnet n'a pas d'auteur au sens livre
  classique, donc à sa place : "Conçu par <book_designer>" (`credits.book_designer`).
  Elle reprend aussi le nom de l'éditeur, en haut ou en bas de la page — PAR DÉFAUT
  ici, en haut.

## Rendu
- Toutes les règles sont définies dans `./Manuel/_dev/regles_esthetiques.adoc`
- Le vers entier est mesuré/dessiné EN CONTINU (`word_tokens`/`line_tokens_x`/`chord_x_at_offset`/`spread_chord_positions`, `layout.rb`), jamais segment par segment. Accords repositionnés APRÈS le texte, jamais l'inverse.
- `resolve_block`/`fetch_block` (`page_builder.rb`) : jamais de crash sur bloc `.gab` introuvable — correction auto si un seul candidat du même type, mapping positionnel si plusieurs, conflict log + bloc vide en dernier recours.
- `parse_lyr` (`page_builder.rb`) : nom répété SANS corps = rappel du contenu déjà défini ; nom répété AVEC corps différent = suffixé (`nom-2`...), jamais écrasé ; contenu identique sous nom différent = aliasé vers le même `Block`.

## building.log
Couverture large (`Layout.log_build`) : layout résolu par chanson.