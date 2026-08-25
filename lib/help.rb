USAGE = <<~TXT
 ===============================================
      AIDE DE LA COMMANDE SONGBOOK
===============================================
 
  Commande
  --------
    
    {{command: songbook}}

  Description
  -----------
  Permet de construire des carnets de chant de façon automatisée et
  de produire tout le matériel qu'il faut. Propose aussi de nombreux
  outils pour se faciliter la tâche.

  Aide rapide
  ------------
    {{command: songbook -i}}
        Ouvre en mode interactif (cf. plus bas)
    {{command: songbook create song "titre" "performer"}} 
        Créer une nouvelle chanson
    {{command: songbook open song "titre}}  
        Ouvre les fichiers de la chanson et le dossier
    {{command: songbook song id "titre"}}   
        Mets l'ID de la chanson dans le PP
    {{command: songbook add chords "titre"}}  
        Assistant accords

  Ouvrir le manuel
  ----------------
    {{command: songbook manual|manuel}}
    {{command: songbook manual|manuel sujet}} # pour chercher ce texte

  Mode interactif
  ---------------
    {{command: songbook -i}}

    🎸> {{command: use song "titre"}} Toutes les commandes suivantes 
          utiliseront cette chanson. Toutes les commandes décrites ci-
          dessous pour les chansons sont valides.
    🎸> {{command: use songbook "titre"}} Toutes les commandes suivantes
          utiliseront ce carnet. Toutes les commandes décrites ci-dessous
          pour les carnets sont valides ({{command:build}}, {{command:open}}, etc.).

  Construction du carnet
  -----------------------
  Après avoir défini les fichiers (cf. le Manuel {{command: songbook manual}}) :

  Si on se trouve dans le dossier du carnet :
    {{command: songbook build}}

  Ailleurs :
    {{command: songbook build sonbgook "titre"}} {{command: songbook build sb "titre"}}

  Assistant de création de chanson
  --------------------------------
    {{command: songbook create song[ "titre de la chanson"]}}

  Assistant de création de carnet de chant
  ----------------------------------------
    {{command: songbook create songbook[ "titre du carnet"]}}
    {{command: songbook create sb[ "titre du carnet"]}}

  Couverture
  ----------
  Pour construire la couverture, deux moyens :
  (cette solution n'est pas très performante au niveau de la couver-
  ture produite — voir le manuel pour de meilleures solutions)
  
  - au moment de la construction du carnet, ajouter l'option -c ou -cover :
    {{command:songbook build -c}}
  - ouvrir un terminal dans le dossier du carnet et taper :
    {{command:songbook build cover}}
  
Dimensions de la couverture
---------------------------

Si on veut créer la couverture soi-même, Songbook peut donner les dimensions à 
partir du nombre de page du carnet :
    {{command: songbook cover dims}}

Modèle de couverture
--------------------
Le plus précis, avec un contenu préparé, est le format IDML pour 
Affinity Publisher (Canvas aujourd'hui) ou InDesign.
    {{command: songbook cover modele-idml}}
S'il l'on veut un modèle de couverture PDF à modifier soi-même :
    {{command: songbook cover modele-pdf}}

Obtenir la liste des chansons
-----------------------------

    {{command: songbook list songs}}
  
    Un argument permet de définir précisément les informations
    sorties et leur format. par exemple :
      (en se trouvant dans le dossier du carnet)
      {{command: songbook list songs "{title} ({performer})"}}
      (en mode interactif)
      {{command: songbook -i}}
      🎸> {{command: use sb "titre du carnet}}
      🎸> {{command: list songs "({performer}) {titre}" }}
    Les balises utilisable sont : 
      title composer lyrics year performer
    ainsi que toute information définies dans les fichiers .infos des
    chansons

    Par exemple, pour obtenir la liste des interprètes contenus dans
    un carnet, on peut faire : 
      {{command: songbook list songs "{performer}" ', '}}
    Ou les uns au dessous des autres : 
      {{command: songbook list songs "{performer}" '\\n'}}
    
Constructeur de diagramme
-------------------------
    {{command: diag -o}}

    {{command: songbook build diag "<schéma>"}}
    (pour construire le schéma, utilisez l'outil `diag` sans option)

  Options
  -------
  -c/--cover      Produire la couverture en même temps que le carnet
  -b/--book PATH  Chemin d'accès au carnet
  --song TITRE    Chanson de contexte pour la commande (recherche intelligente, sans persistance)
  -x              Faire apparaitre les repères (marges)

  TXT

def colorize_help(text)
  text.gsub(/\{\{command:\s*(.+?)\}\}/) { "\e[38;5;208m#{$1}\e[0m" }
end
