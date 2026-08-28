# TODO rendu SVG tablature — points signalés par Phil (2026-08-28)

Tenu à jour à chaque point traité. Ne pas supprimer un point sans qu'il soit résolu ET vérifié visuellement.

- [ ] 1. Barre de mesure en tout DÉBUT de système à supprimer.
- [ ] 2. Notes trop collées à leur barre de gauche — décaler de quelques pixels à droite (pas trop).
- [ ] 3. Système de hampe de noire (LilyPond) perdu — toute note (sauf ronde) doit avoir une hampe, pas seulement croche et moins.
- [ ] 4. Hampes de croches ridiculement petites — agrandir.
- [ ] 5. Hampes de croches doivent être attachées (beam) par temps, pas en crochets individuels.
- [ ] 6. Erreur de calcul : dernière note de plein de mesures considérée croche au lieu de noire.
- [ ] 7. Systèmes beaucoup trop écartés — réduire l'espacement.
- [ ] 8. Lignes de portée doivent s'arrêter à la dernière barre du système (pas continuer sur la largeur pleine si le système a moins de mesures).
- [ ] 9. Chaque système doit être un élément de pagination INDÉPENDANT (2 systèmes page N, système suivant page N+1 si besoin) — pas un seul bloc SVG monolithique.
- [ ] 10. Le nombre de 6 mesures/système n'est pas respecté — à corriger.

## État
En cours — traitement séquentiel, tests + régénération Blackbird à chaque lot de corrections.
