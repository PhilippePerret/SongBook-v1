# TODO rendu SVG tablature — points signalés par Phil (2026-08-28)

Tenu à jour à chaque point traité. Ne pas supprimer un point sans qu'il soit résolu ET vérifié visuellement.

- [x] 1. Barre de mesure en tout DÉBUT de système à supprimer.
- [x] 2. Notes trop collées à leur barre de gauche — décaler de quelques pixels à droite (pas trop). (NOTE_INSET 6→10pt, à confirmer visuellement par Phil)
- [x] 3. Système de hampe de noire (LilyPond) perdu — toute note (sauf ronde) doit avoir une hampe, pas seulement croche et moins.
- [x] 4. Hampes de croches ridiculement petites — agrandir. (STEM_HEIGHT 8→22pt)
- [x] 5. Hampes de croches doivent être attachées (beam) par temps, pas en crochets individuels.
- [x] 6. Erreur de calcul : dernière note de plein de mesures considérée croche au lieu de noire. INVESTIGUÉ : parsing vérifié correct sur les .tab réels (dénominateur = exactement celui du fichier source, dernière note bien noire partout où le fichier le dit). Pas de bug de calcul trouvé — symptôme probablement dû à l'absence de hampe sur les noires (point 3, résolu) qui rendait noires/croches indiscernables. À reconfirmer visuellement par Phil sur le nouveau rendu.
- [x] 7. Systèmes beaucoup trop écartés — réduire l'espacement. (empilement interne au SVG supprimé — chaque système est maintenant un élément autonome, espacé par le mécanisme standard de l'appli, pas un espacement custom)
- [x] 8. Lignes de portée doivent s'arrêter à la dernière barre du système. (résolu de fait par le point 9 — chaque système a désormais sa largeur PROPRE, plus de largeur globale partagée)
- [x] 9. Chaque système = élément de pagination indépendant. Vérifié bout en bout sur Blackbird : le système incomplet de "refrain+intro" (1 mesure) a basculé seul sur la page suivante pendant que les 2 précédents restaient sur la page courante.
- [x] 10. 6 mesures/système. Vérifié : 447pt = 15(marge) + 6×72(mesure) sur la largeur de colonne de Blackbird.

## État (lot 1)
Les 10 points sont traités et vérifiés (code + régénération réelle de Blackbird, sauf 2 et 6 : implémentés mais à valider VISUELLEMENT par Phil, pas de métrique objective possible pour ces deux-là).

## Lot 2 (2026-08-28, après relecture du lot 1)

- [x] 11. Systèmes ENCORE trop séparés (redemandé) — cause : `distribute_v_gutters` étire les gouttières pour occuper tout le "slack" de la page, plafonné à `MAX_V_DIST[:default]`=40pt. Fix : nouveau type `:tabla_system` (`MIN_V_DIST`=6/`MAX_V_DIST`=9), appliqué UNIQUEMENT entre 2 systèmes de LA MÊME tablature (`PageElement#gutter_type`, jamais sur la gouttière qui précède le 1er système). Vérifié visuellement (net resserrement, systèmes quasi collés).
- [x] 12. Barre de fin absente sur le 1er système de "intro.tab". Cause trouvée : la barre finale (dans le SVG source, vérifié) tombait PILE sur le bord droit du viewBox — rognée par le moteur de rendu PDF à l'intégration. Fix : `RIGHT_MARGIN` (2pt) de coussin après la dernière barre.
- [x] 13. Hampes non alignées sur les notes — décalage fixe (×1.3 taille chiffre) remplacé par un décalage proportionnel à la largeur RÉELLE du chiffre (1 ou 2 caractères).
- [x] 14. Chiffres de la métrique trop écartés — écart resserré (span 11pt→8pt).
- [x] 15. Fusion incorrecte : les barres de fin de CHAQUE fichier source forçaient une coupure de mesure à la jonction ("amorce" 1 temps → mesure fantôme). Fix : `merge_tab_contents` retire désormais les barres de chaque source avant concaténation ("bout à bout sans traitement") — seule la métrique décide des mesures du morceau fusionné.
- [x] 16. Mesure vide en tête de "intro" — CONSÉQUENCE DIRECTE du point 15, résolue par le même fix (vérifié : le temps de silence de "amorce" fusionne maintenant dans la 1ère mesure réelle, plus de mesure fantôme).
- [x] 17. Refrain sans barre de fin sur les 2 premiers systèmes — MÊME CAUSE que le point 12, résolu par le même fix (`RIGHT_MARGIN`).
- [ ] 18. Système final à 1 seule mesure restante : la remonter dans le système précédent (mettre N+1 mesures) plutôt que la laisser seule sur son propre système.
- [x] 19. Écartement entre les lignes de la portée trop grand — `LINE_SPACING` 8pt→6pt (portée -25% de hauteur).

## État (lot 2)
17/18 traités et vérifiés sur régénération réelle de Blackbird (tests + PDF→PNG). Point 18 NON traité.

## Lot 3 (2026-08-28, redemandé après relecture du lot 2)

- [x] 20. Hampes ENCORE désalignées (point 13 insuffisant) — le décalage proportionnel restait un décalage. Fix : hampe posée EXACTEMENT sur l'abscisse du chiffre (aucun décalage), plus de risque de collision (la hampe reste au-dessus de la portée, le chiffre est sur la ligne — jamais sur la même hauteur).
- [x] 21. Systèmes ENCORE trop écartés (point 11 insuffisant) — `MIN_V_DIST`/`MAX_V_DIST[:tabla_system]` resserrés encore (6/9 → 3/5).
- [x] 22. Lignes de portée encore rapprochables — `LINE_SPACING` 6pt→5pt.
- [x] 23. Titre trop loin (trop haut) au-dessus de la tablature — cause : la marge réservée au-dessus de CHAQUE système pour les hampes/ligatures/nom d'accord était FIXE (toujours réservée en entier, même quand rien n'en avait besoin) ; le titre semblait loin parce que tout cet espace vide se trouvait entre lui et la 1ère portée. Fix : marge devenue DYNAMIQUE — calculée par système selon son contenu réel (hampe la plus haute nécessaire, présence ou non d'un nom d'accord). `STEM_HEIGHT` aussi ramenée de 22pt à 15pt (la marge ne gaspille plus systématiquement le maximum, plus besoin de compenser large).

## État (lot 3)
23/24 traités et vérifiés (tests + régénération réelle de Blackbird). Point 18 toujours non traité.

## Lot 4 (2026-08-28, redemandé après relecture du lot 3)

- [x] 24. Hampes trop près des notes (point 20 : désalignement réglé, mais trop courtes/collées) — `STEM_HEIGHT` 15pt→19pt, nouvel écart `STEM_GAP` (3.5pt, indépendant de `LINE_SPACING`) entre la ligne de corde et le pied de hampe (avant : moitié de `LINE_SPACING`, donc de plus en plus petit à chaque resserrement des lignes).
- [x] 25. Fond des chiffres non transparent (recouvrait la ligne de corde du dessus) — le rectangle blanc de masquage est supprimé ; c'est maintenant la ligne de corde elle-même qui est coupée localement à l'emplacement de chaque chiffre (`line_with_gaps`), jamais masquée par-dessus.
- [x] 26. Trop d'espace en fin de mesure — algo refait : position de départ fixe contre la barre gauche (`NOTE_INSET`, inchangée), espace restant divisé par le nombre de PLUS PETITE VALEUR de durée de la mesure (`unit:` du frontmatter, `Tablator::UNIT_DENOMINATOR` — défaut croche), chaque note placée au slot correspondant (`slot_x`). Remplace l'ancien double-retrait (marge des deux côtés de la mesure).

## État (lot 4)
26/27 traités et vérifiés (tests + régénération réelle de Blackbird). Point 18 toujours non traité.

## Lot 5 (2026-08-28, config nommée + preset "mini-tablatures")

- [x] 27. Garder la config actuelle enregistrée "en dur", nommée, avec toutes les valeurs (mesures/système, écart entre systèmes, taille des chiffres, etc.) — `tools/tablator/presets.rb`, `Tablator::PRESETS["regular-tablatures"]`. Tout `renderer.rb` lit désormais ses tailles/écarts via `Tablator.param(:clé)` (plus AUCUNE constante en dur dans `renderer.rb`) ; `Layout.min_v_dist`/`max_v_dist(:tabla_system)` lisent aussi le preset actif (`system_gap_min`/`system_gap_max`) au lieu d'une valeur figée. Vérifié : régénération de Blackbird avec le preset par défaut → rendu strictement identique au lot 4 (refactor sans effet de bord).
- [x] 28. Config "mini-tablatures" (9 mesures/système, tout proportionnellement plus petit, ~×0.65) — `Tablator::PRESETS["mini-tablatures"]`, activable via `Tablator.active_preset = "mini-tablatures"`. Vérifié par régénération réelle de Blackbird avec ce preset (envoyée).
- [x] 29 (bug trouvé EN FAISANT le point 28, pas demandé par Phil) : le cache disque des SVG (`.export/`) ne changeait pas de nom selon le preset actif → un changement de preset servait un SVG périmé tant que les `.tab` sources n'avaient pas changé. Fix : le preset actif fait maintenant partie de la clé de cache.

## État (lot 5)
29/29 traités et vérifiés (tests + régénération réelle de Blackbird, 2 presets).

## Question ouverte de Phil (pas encore tranchée, pas implémentée)
"Comment compter le nombre de mesures par système : en nombre de mesures (variable, une mesure 6/8 ou en double-croches n'a pas la même largeur qu'une 4/4 en croches), ou en nombre de PLUS PETITE DURÉE (le nombre de 'slots' du point 26, `unit:`) ?" Fait, sans trancher : `measures_per_system` (presets) compte des MESURES ; `measure_width` (largeur d'une mesure) ne dépend QUE de la métrique (`target_beats × beat_width`), jamais de `unit:` — deux tabs avec la même métrique mais un `unit:` différent (croche vs double-croche) ont donc AUJOURD'HUI la même largeur de mesure alors que l'une est visuellement 2× plus dense que l'autre. Compter en "plus petite durée" rendrait la largeur d'une mesure proportionnelle à sa densité réelle (une mesure en double-croches deviendrait plus large qu'une en croches, à métrique égale) — cohérent avec l'algo du point 26 qui, lui, utilise déjà `unit:` PAR mesure. Pas implémenté, en attente de décision.
