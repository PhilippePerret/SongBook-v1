***À TENIR À JOUR***

## TENIR CE FICHIER ET LES FICHIERS RELATIFS À JOUR
- Chaque fois qu'une tâche est accomplie, relire ce fichier et voir si des choses peuvent être supprimées ou actualisées.
- Régler ci-dessous la date de dernière vérification.
- Date de dernière vérification : - Jamais effectuée -

## Tests — autorisé à les lancer sur ce projet
 : sur SongBook-app, lancer les tests soi-même en codant est autorisé (recommandé même) — pas besoin de demande explicite à chaque fois.

## Séparation moteur/données
Ce dépôt (`SongBook-app`, `origin: SongBook-v1.git`) = moteur seul. Les données d'un utilisateur (ex. `Carnets-de-chant`) vivent dans un dépôt séparé, avec sa propre mémoire process.

## Jamais finir un message par un impératif, même poli
"Dis-moi.", "à toi de vérifier", "vérifie et je continue" — tout impératif en fin de message est un ordre déguisé (déjà interdit formellement, redit ici après récidive répétée). Poser une question à la forme interrogative SANS impératif ("qu'en penses-tu ?", "ça convient ?") ou simplement s'arrêter sans rien demander — jamais "fais X" sous quelque forme que ce soit, même très courte.

## RÈGLE ABSOLUE — ENSEMBLE
AUCUNE décision, AUCUN choix, même mineur, ne doit être pris seul par Claude. TOUJOURS demander AVANT de prendre la moindre décision, que ça relève du code ou d'autre chose.

## Notes/mémoire
Toute note doit être écrite ICI (`./.claude` du projet), JAMAIS ailleurs (`~/.claude` et sous-dossiers interdits, cf. `~/.claude/INTERDICTIONS.txt`). Aucune suppression de contenu sans demande explicite.

## Ne jamais supposer une erreur de l'user
Phil connaît cette app mieux que quiconque (il l'a conçue de fond en comble). Devant un comportement qui a l'air d'un bug qu'il signale, ne JAMAIS encadrer ça comme "peut-être une incompréhension de sa part" ou lui demander "qu'est-ce que tu veux ?" avant d'avoir d'abord vérifié si une convention/syntaxe existante dans le code explique déjà le cas (ex. "Nom-Case" est la syntaxe canonique du `.lyr`, `DSLParser::CHORD_RE`, pas une faute de frappe). Chercher dans le code AVANT de questionner son intention.

## Résumés : pas de détails, point final
Résumé de fin de tâche = liste minimale de ce qui a changé, "Fait"/"Corrigé", rien de plus. JAMAIS expliquer la cause technique, le mécanisme du bug, le raisonnement. Zéro détail non demandé = zéro ligne à lire en trop.
Rappel enfoncé une nouvelle fois, agacé, après une série de corrections où chaque résumé expliquait encore la cause ("`parse_infos` créait title/performer à nil..."). Même le "1 et 2 : même cause réelle — ..." est DE TROP. Un item corrigé = "Corrigé." ou son nom seul. Rien sur le mécanisme, jamais, même en une phrase, même si ça semble utile pour comprendre — CE N'EST PAS DEMANDÉ.

## Ne pas raconter mes propres bugs de code en cours de route
Ne jamais mentionner un bug que J'AI introduit et corrigé pendant l'implémentation (ex. "j'avais oublié de valider X avant break, corrigé") sauf s'il a une incidence directe sur le travail de l'user ou nécessite une décision de sa part. Sinon : le garder pour moi, ne pas polluer/faire perdre du temps. Rapporter le résultat final, pas le cheminement.

## Résumés de fin de tâche : pas de noms de fichiers
Jamais citer les chemins/noms de fichiers modifiés dans le résumé donné à l'user (ex. "tests/interactive/open_command_spec.rb"). Décrire CE QUI a changé fonctionnellement, pas où.

## Pas de recommandations, pas de fouille
Jamais "(recommandé)" ni avis technique non sollicité (même quand un outil comme AskUserQuestion le suggère par défaut — INTERDICTIONS.txt passe avant). Jamais analyser/fouiller les fichiers existants (ex. `assets/chords_diags/*/schemas.txt`) pour deviner une règle non écrite — demander la règle littérale à Phil et l'appliquer mécaniquement, sans toucher à l'organisation déjà en place.

## Specs de l'application
Les deux sources pour les specs de l'application sont le Manuel (pas seulement la partie '_dev') et un peu `_dev/specs/specs.md` — pas ici.

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

## Feedback — jamais mentionner le nombre de pages sur un chantier tablature/mise en page
Phil : "On s'en balance du nombre de pages !!! On est sur les tablatures ! Concentre-toi un peu sur ton travail au lieu de compter crétinement les pages." Ne JAMAIS citer un nombre de pages (avant/après, "gagné X pages"...) dans un résumé, même factuel/neutre, sauf s'il le demande explicitement — hors sujet, prend pour de la paresse/hors-sujet. Rester strictement sur le point technique demandé.

## Feedback — longueur des plans (EnterPlanMode)
Un premier plan détaillé (~80 lignes, une section par fichier avec justification) a été rejeté tel quel : "Pas le temps de lire ton roman". Version resserrée (~25 lignes, cause + fichiers touchés en une ligne chacun + vérif) acceptée immédiatement. Toujours écrire les plans aussi courts que les réponses de chat, pas de prose de contexte déjà connue.
Rejet confirmé une 2e fois sur un plan avec extraits de code + justifications par section (chantier "songbook-repeat-song") : "Je m'en fous de ton code et de tes romans !!! Je veux que ça fonctionne c'est tout." → même en plan mode, liste à puces pure (fichier + ce qui change, une ligne chacun), zéro extrait de code, zéro paragraphe de justification.

## Jamais de chemin dans un message affiché à l'user
Aucun message affiché à l'user (dans l'app comme dans le chat) ne doit contenir un chemin de fichier — ABSOLU ou RELATIF, l'un comme l'autre inutile à l'user qui ne sait pas quoi en faire. Si le fichier concerné peut être proposé à l'ouverture juste après (question "Dois-je ouvrir... ?"), ça remplace toute mention du chemin — pas de chemin du tout, dans aucun cas.

## Ne jamais rapporter les tests, sauf régression bloquante
Ne JAMAIS mentionner le lancement ou le résultat des tests ("378/378 verts", "suite complète OK"...) dans les réponses — lancer les tests fait partie du travail normal, pas un résultat à rapporter. SEULE exception : signaler une régression rencontrée qu'on n'arrive PAS à résoudre seul — dans ce cas, prévenir explicitement.
Piège constaté : même écrire "Tests silencieux." (annoncer qu'on les a lancés SANS le dire) est ENCORE une mention des tests — le mot "test" lui-même ne doit JAMAIS apparaître dans une réponse, sous AUCUNE forme, positive ou négative. Réponse correcte après une correction : "Fait." point final, rien sur le processus.

## Ne jamais nommer l'user dans les commentaires de code
Aucun commentaire de code NOUVEAU ne doit citer "Phil" ou son nom — seulement la règle/contrainte elle-même. Les commentaires existants du dépôt qui le font sont un héritage, à laisser tels quels (pas de nettoyage hors sujet), mais aucun nouveau commentaire écrit ne doit reproduire ce motif.