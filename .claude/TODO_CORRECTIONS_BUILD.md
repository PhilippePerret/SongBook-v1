# Corrections à traiter UNE PAR UNE, arrêt + vérification après chacune

## Messages CLI (fin de build carnet)
- [x] 1. Message final pourri ("carnet-test-imprime-v2.pdf généré : N pages") → "Carnet « VRAI TITRE » construit avec succès." en VERT, PREMIER message affiché (avant erreurs/conflits).
- [x] 2. Ordre après ce message : (a) nombre d'erreurs éventuelles, (b) accords manquants éventuels, (c) question ouvrir log conflits, (d) question ouvrir le PDF reformulée "Dois-je ouvrir le fichier du carnet « VRAI TITRE » ?"

## PDF produit (carnet-test-imprime)
- [x] 3. Page de garde : affiche le nom de fichier au lieu du VRAI titre. (cause : `FileFinder` ramassait le mauvais `.infos` du carnet, corrigé)
- [x] 4. Page de copyright : specs trop petites / pas visibles. (crash `.sub` sur `copyright:`/`credits:` vides corrigé + fonte générale toujours affichée maintenant)
- [x] 5. Page de titre : mauvais titre affiché. (même cause que 3)
- [x] 6. Pas de bandeau titre+infos sur la première chanson. (cause réelle : `parse_infos` créait `title`/`performer`/... à `nil` même absents du fichier — un `.infos` indexé partiel effaçait ceux de la chanson en fusionnant. Corrigé, vérifié visuellement)
- [x] 7. Specs propres à la chanson (`show_specs`) pas affichées. (même cause que 6 + bug "14ptpt", corrigés, vérifiés visuellement — "Arial 14pt")
- [x] 8. Page 5 : accords qui touchent le texte, chevauchement texte/diags. (plus reproduit, vérifié visuellement sur build à jour)
- [x] 9. Pages suivantes, même chanson : même problème. (idem)
- [x] 10. "À Bicyclette" garde les specs (police...) réservées à la chanson précédente (Blackbird) — fuite d'état. (même cause que 3, le carnet retombait sur le `.infos` d'une chanson indexée comme si c'était sa propre base)
- [x] 11. Table des matières : titres = id brut du tdm au lieu du vrai titre. (même cause que 3)
- [x] 12. Autre table des matières : même problème.
