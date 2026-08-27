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

## Chantier EN COURS — tablatures/partitions dans les pages de chanson (état au 2026-08-27, à reprendre)

### Syntaxe `.gab` (acquis, stable)
Sections entre accolades, DEUX formes distinctes (pas une "override" l'une de l'autre, deux natures de contenu) :
- `{nom}` / `{nom-N}` : référence vers une partie des paroles (`.lyrics`). Le chiffre `-N` seulement si PLUSIEURS occurrences — une partie unique par nature (`final`) n'a jamais de chiffre.
- `{id; tab: nom}` / `{id; score: nom}` / `{id; image: nom}` : déclare une tablature/partition/image (référencée par nom, sans extension — devinée), avec éventuellement `count:`/`position:`/`align:`/`title:`/`shrink:`. Le nom en tête (`id`) sert de titre PAR DÉFAUT si `title:` absent.
Exemple réel : `CHANSONS/Blackbird/c.gab`.

### Pipeline de rendu (implémenté aujourd'hui, testé sur Blackbird)
1. `PageBuilder.locate_resource` : cherche le fichier nommé dans `scores/`, `images/`, la racine de la chanson, PUIS tous les sous-dossiers en récursif.
2. `PageBuilder.tab_source_content` : pour un nom fusionné (`intro+couplet+intro`), ASSEMBLE D'ABORD tout le code des `.tab` sources (`merge_tab_contents`) — jamais l'inverse (Phil a dû corriger ça une fois : ne JAMAIS découper fragment par fragment AVANT fusion).
3. `Tablator.split_into_duration_measures(tokens, time)` (tools/tablator/tablator.rb) : découpe en mesures RÉELLES par accumulation de durée contre la métrique (`metrique`/`time`, défaut 4/4) — PAS par comptage des barres `|` du code (les `.tab` réels n'en ont souvent qu'une seule, malgré plusieurs mesures de contenu). Une barre explicite force quand même une coupure.
4. `PageBuilder.measures_per_page(meta, available_width_pt)` : nombre de mesures par fragment, calculé (métrique × plus petite division `unit:` × largeur dispo, constantes `SLOT_WIDTH_PT`=11.65/`SLOT_OVERHEAD_PT`=19.25, calibrées sur des notes SIMPLES sans accord ni doigté — sous-estime probablement la largeur réelle d'un contenu chargé, PAS ENCORE VALIDÉ avec Phil). Surclassable via `tabla_measures_per_page` (layout — PAS `.infos`).
5. `PageBuilder.ensure_tabla_fragments` : découpe le contenu fusionné en fragments de N mesures (`Tablator.split_into_fragments`), UN SVG PAR FRAGMENT — jamais un seul SVG multi-système. Écrits dans `<chanson>/.export/` (caché, JAMAIS dans `scores/` — Phil : "tu ne laisses pas ta merde partout"). Cache invalidé si un `.tab` source OU `tablator.rb` lui-même a changé (`svg_fresh?`).
6. `Layout.build_tabla_element_v2` : empile les fragments avec `tabla_system_spacing` (layout, défaut 16pt) entre chacun. Largeur de chaque fragment = sa taille physique NATURELLE (`Layout.svg_natural_width_pt`, lit `width="Xmm"` dans le SVG — PAS une mesure regex de l'écart entre lignes, abandonnée car peu fiable) × une échelle UNIQUE pour toute la chanson (`Layout.uniform_tab_scale`, calculée sur le fragment le plus large).
7. `score:`/`image:` matriciels (PNG/JPG) : PAS de découpe en fragments (une image ne se scinde pas en mesures) — `Layout.build_image_element`, pleine largeur de colonne par défaut.

### Réglages LilyPond fixés dans `tablator.rb` (`Tablator::LAYOUT_BLOCK`)
- `#(set-global-staff-size 20)` — FIXE, en dur (jamais changée entre deux appels : toute la mise à l'échelle de l'app en dépend).
- `Bar_number_engraver` retiré (numéros de mesure inutiles ici).
- `NonMusicalPaperColumn.line-break-permission = ##f` — force CHAQUE fragment en système UNIQUE (filet de sécurité si `measures_per_page` surestime la place).
- `proportionalNotationDuration = #(ly:make-moment 1 16)` — mesures à largeur ÉGALE (chaque mesure dure exactement 1 mesure entière par construction, donc même temps = même largeur, sans bidouille de voix invisible).
- Mode `-dcrop` de LilyPond : bug DOCUMENTÉ, supprime l'espacement entre systèmes quels que soient les réglages `\paper`/`\layout` (vérifié 2026-08-27 sur 4 réglages distincts, sortie strictement identique — https://lists.gnu.org/archive/html/lilypond-user/2021-01/msg00104.html). C'est LA raison d'être du découpage en fragments (1 système par SVG = jamais concerné).

### Restes à trancher avec Phil (session suivante)
- `SLOT_WIDTH_PT`/`SLOT_OVERHEAD_PT` (calibration mesures_per_page) : à valider/ajuster sur un contenu réel chargé (accords, doigtés) — actuellement calibré sur notes simples seulement.
- Défaut de `tabla_measures_per_page` : pas fixé à une valeur particulière (le "6" mentionné par Phil dans la conversation était un EXEMPLE illustratif, pas une consigne de valeur par défaut — à clarifier s'il en veut une différente du calcul auto).
- `score:` (partition) jamais testé en conditions réelles (aucun exemple `.gab` n'en utilise encore) — le pipeline fragments s'applique à `score:` vectoriel comme à `tab:`, mais non vérifié.
- Shrink (`shrink: true` sur la marque, `shrink_tabla`/`shrink_score`) : le re-rendu `max_height` ne gère que le cas 1 SEUL fragment (`build_tabla_element_v2`, garde `frags.size == 1`) — plusieurs fragments + shrink pas géré. `build_image_element` n'a AUCUN paramètre `max_height` (gap pré-existant, pas touché).
- Tout testé uniquement sur `CHANSONS/Blackbird` (3 tabs courtes) — jamais sur une tablature longue/réelle typique.

## Chantier en attente — suite de tests complète
Basée sur TOUT le Manuel (pas les chemins de code touchés récemment). Le Manuel a encore des trous/zones d'ombre à combler d'abord. Pas de framework choisi (rspec/minitest à trancher ensemble). Ne pas démarrer sans demande explicite.

## Specs de l'application
Les deux sources pour les specs de l'application sont le Manuel (pas seulement la partie '_dev') et un peu `_dev/specs/specs.md` — pas ici.

## Outil tabulator (Ruby) — PLUS "figé" (chantier tablatures/partitions ci-dessus le modifie activement, 2026-08-27)
Traduit syntaxe simplifiée (corde:case ou notes LilyPond) en tablature LilyPond → SVG.
- Code : `tools/tablator/`.
- Lien symbolique `/usr/local/bin/tabulator` (commande `tabla`).
- `Tablator::LAYOUT_BLOCK` (staff-size fixe, pas de numéros de mesure, mesures à largeur égale, système unique par fragment) — voir détails dans le chantier ci-dessus.

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