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

## Rendu
- Toutes les règles sont définies dans `./Manuel/_dev/regles_esthetiques.adoc`
- Le vers entier est mesuré/dessiné EN CONTINU (`word_tokens`/`line_tokens_x`/`chord_x_at_offset`/`spread_chord_positions`, `layout.rb`), jamais segment par segment. Accords repositionnés APRÈS le texte, jamais l'inverse.
- `resolve_block`/`fetch_block` (`page_builder.rb`) : jamais de crash sur bloc `.gab` introuvable — correction auto si un seul candidat du même type, mapping positionnel si plusieurs, conflict log + bloc vide en dernier recours.
- `parse_lyr` (`page_builder.rb`) : nom répété SANS corps = rappel du contenu déjà défini ; nom répété AVEC corps différent = suffixé (`nom-2`...), jamais écrasé ; contenu identique sous nom différent = aliasé vers le même `Block`.

## building.log
Couverture large (`Layout.log_build`) : layout résolu par chanson.