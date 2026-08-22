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

  Ouvrir le manuel
  ----------------
    {{command: songbook manual|manuel}}
    {{command: songbook manual|manuel sujet}} # pour chercher ce texte

  Construction du carnet
  -----------------------
  Après avoir défini les fichiers (cf. le Manuel {{command: songbook manual}}) :

    {{command: songbook build}}

  Couverture
  ----------
  Pour la construire, deux moyens :
  
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
      {{command: songbook list songs "{title} ({performer})"}}
    Les balises utilisable sont : 
      title composer lyrics year performer
    ainsi que toute information définies dans les fichiers .infos des
    chansons

    Par exemple, pour obtenir la liste des interprètes contenus dans
    un carnet, on peut faire : 
      {{command: songbook list songs "{performer}" ', '}}
    Ou les uns au dessous des autres : 
      {{command: songbook list songs "{performer}" '\\n'}}
    


  Options
  -------
  -c/--cover      Produire la couverture en même temps que le carnet
  -b/--book PATH  Chemin d'accès au carnet
  -x              Faire apparaitre les repères (marges)      

  TXT

def colorize_help(text)
  text.gsub(/\{\{command:\s*(.+?)\}\}/) { "\e[38;5;208m#{$1}\e[0m" }
end
