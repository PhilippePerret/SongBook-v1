***À TENIR SOIGNEUSEMENT À JOUR***

## Séparation moteur/données
Ce dépôt (`SongBook-app`, `origin: SongBook-v1.git`) = moteur seul. Les données d'un utilisateur (ex. `Carnets-de-chant`) vivent dans un dépôt séparé, avec sa propre mémoire process.

## INTERDICTION — écrasement sans vérification
JAMAIS déplacer/renommer/écrire vers un chemin cible sans vérifier D'ABORD (ls) s'il existe déjà.

## RÈGLE — fichiers produits
Tout fichier produit va directement dans le dossier du projet, jamais laissé dans le scratchpad temporaire. Nettoyer le scratchpad immédiatement après usage.

## INTERDICTION — phrases négatives
Ne jamais formuler en négatif ("pas tab", "pas X"). Toujours dire ce que c'est, positivement.

## RÈGLE ABSOLUE — ENSEMBLE
AUCUNE décision, AUCUN choix, même mineur, ne doit être pris seul par Claude. TOUJOURS demander AVANT d'écrire un fichier.

## RÈGLE — vérification empirique
Avant d'affirmer qu'un réglage fonctionne, le tester réellement plutôt que de se fier à la doc seule.

## Specs de l'application
Toute spec technique (réglages diags, conventions de nommage, formats, etc.) va dans `_dev/specs/specs.md` — pas ici.

## Outil tabulator (Ruby) — état figé
Traduit syntaxe simplifiée (corde:case ou notes LilyPond) en tablature LilyPond → SVG, intégré dans ChordPro via `{image: src=...}`.

### Emplacement
- Code : `tools/tablator/`.
- Lien symbolique `/usr/local/bin/tabulator`.

### Syntaxe `.tab`
- Note simple : `<corde>:<case>[/<durée>]`, ex. `5:0/4.`.
- Accord : `[Arp]<corde:case corde:case ...>[/<durée>]`, ex. `Arp<4:2 3:2 2:1 1:0>/8`.
- Barre de mesure `|`, commentaire `# ...`, nom d'accord explicite `[Am7]`.
- Cordes : 1 = aiguë … 6 = grave.
- Mode `-n`/`--notes` : entrée notes classiques (`c4 d e f`), gère notes seules pas encore les accords `<...>`.
- Capodastre : texte "Capo : Ne" au-dessus, à la place du tempo.

### Frontmatter YAML
- `title`, `metrique` → `\time`.
- `chord: true` → calcul/affichage auto nom accord + hampes bas ; sinon hampes haut, pas de nom (sauf `[Nom]` explicite).
- `keep_ly: true` → garde le `.ly` à côté du `.svg`.

### Rendu LilyPond
`\new TabStaff` + `\tabFullNotation` + `\omit Staff.Clef`. Accords placés sur le 1er événement de la mesure.

### Reste à faire
- Hammer-on/pull-off, doigtés.
- `^`/`_` direction markup.
- Mode `-n` : accords.

### Config partagée avec ChordPro
- Fichier `chordpro.json` (sans point) à la racine du dépôt de données — recherché en remontant les dossiers depuis le `.tab` traité.
- Lit `pdf.fonts.chord` (même clé que ChordPro), tolère les commentaires `//`.
- Piège LilyPond : `\override #'(font-name . "...")` ne fonctionne PAS seul — il faut `\paper { #(define fonts (set-global-fonts #:sans "NomPolice" ...)) }` PUIS `\override #'(font-family . sans)` dans le markup.

### Convention de fichiers
- `<nom>.tab` : tablature simplifiée.
- `<nom>.tab.lyr` : paroles associées, texte brut.
- ChordPro GUI : `/Applications/ChordPro.app` — CLI : `/Applications/ChordPro.app/Contents/Resources/cli/chordpro fichier.cho -o fichier.pdf`.

## Outils diagrammes d'accord — DiagSchem + générateur
- `tools/DiagSchem/diagschem.rb` (commande `diag`, aide `diag -h`/`--help`) : saisie interactive du schéma texte d'un diagramme (`Nom-case : <6 tokens>`), copié dans le presse-papier.
- `sandbox/lib/generate_chord_diagrams.rb` (`GenerateChordDiagrams.run`) : lit tous les `schemas.txt` sous `assets/chords_diags/<Note>/`, génère les SVG manquants via `ChordDiagramH` (manche horizontal, actif). Sans `only:`, ne génère RIEN. Avec `only: "Nom-case"`, cible un seul accord.

## Fichiers, extensions, layouts
- `lib/file_finder.rb` (`FileFinder`) : recherche de fichier par type, root-name libre, formes longue/courte (`gabarit`/`gab`, `infos`/`inf`, `tdm`/`toc`, `lyrics`/`lyr`, `layout`/`lay`).
- `assets/layouts/*.yaml` + `_default.yaml` : cascade `_default.yaml` → layout nommé (`.infos`/`.inf` carnet, `layout:`) → `.lay`/`.layout` du carnet → `.lay`/`.layout` de la chanson, chaque étage n'écrasant que ses clés. Vocabulaire : `title_band`/`diag_position`/`lyrics_flux`/`intro_align`.
- `.gab` : un paragraphe tient toujours sur une ligne (`split("\n")`), pas de ligne vide requise entre paragraphes (contrairement au `.lyr`).
- `carnet_folder`/`format` : un nombre SANS unité dans `format:` = POUCES (convention KDP), jamais des points.
- `carnet.infos`/`.tdm` : toujours vérifier les deux formes (longue/courte) et le root-name libre avant de conclure qu'un fichier "n'existe pas".

## Export
- `export/songbooks/` (carnet entier), `export/songs/` (chanson isolée), `export/xlogs/` (logs).
- `songbook.rb song <carnet> <nom-du-.tdm>` : réutilise EXACTEMENT le pipeline réel (`CarnetBuilder.build(..., only_song:)`).

## Rendu des lignes (accords + texte)
- Le vers entier est mesuré/dessiné EN CONTINU (`word_tokens`/`line_tokens_x`/`chord_x_at_offset`/`spread_chord_positions`, `layout.rb`), jamais segment par segment. Accords repositionnés APRÈS le texte, jamais l'inverse.
- RAL2.1 câblé (`resolve_line_spacing`) : resserrement mots d'abord (`RAL2_1_WORD_SPACING_MAX = -1.0`), puis lettres si besoin (`RAL2_1_CHAR_SPACING_MAX = -0.2`). RAL2.2 (coupe fin de vers) en dernier recours.
- RAL3 câblé (`force_chord_baseline`) : dans une row côte à côte, si un bloc a un accord sur sa 1re ligne, l'autre aligne sa 1re ligne dessus.
- `CHORD_RE` (`dsl_parser.rb`) : suffixe après `-` (case/fret) accepte tout caractère sauf l'espace (`[^: ]+`).
- `resolve_block`/`fetch_block` (`page_builder.rb`) : jamais de crash sur bloc `.gab` introuvable — correction auto si un seul candidat du même type, mapping positionnel si plusieurs, conflict log + bloc vide en dernier recours.
- `parse_lyr` (`page_builder.rb`) : nom répété SANS corps = rappel du contenu déjà défini ; nom répété AVEC corps différent = suffixé (`nom-2`...), jamais écrasé ; contenu identique sous nom différent = aliasé vers le même `Block`.

## Markdown / front matter
- `GARAMOND_LETTER_SPACING = 0.15` (`markdown_page.rb`) : appliqué au texte markdown quand `text_font` contient "Garamond".

## building.log
Couverture large (`Layout.log_build`) : layout résolu par chanson, pairage RAO5, transposition, diag position/count, RAT1/RAT3, RAD5, RAL2/RAL2.1/RAL2.2, RAL3, RATDM*, alias de blocs, tabla shrink.

## Points ouverts / non validés par Phil
- `diag_position` (`left`/`both`) en écart avec le vocabulaire du Manuel (`Top`/`Bot`/`Int`/`Ext`) — pas implémenté.
- `diags_size`/`music_position` (Manuel/song/layout.adoc) : pas implémentés.
- `MIN_SIZE[:diags][:width] = 48.0`, `band_diag`/`band_strophe`, `MIN_V_DIST/MAX_V_DIST[:diags]` (2.0/2.0) : valeurs provisoires, jamais validées par Phil.
