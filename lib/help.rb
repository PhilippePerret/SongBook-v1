USAGE = <<~TXT
  Usage : songbook [.]
          songbook build <dossier> [-c <dossier-carnet>]
          songbook -h | --help

  <dossier> (par défaut, dossier courant) : construit un carnet entier s'il
  contient un .tdm/.toc, ou une chanson seule s'il contient un .lyr/.lyrics.

  -c <dossier-carnet> : construit la chanson EXACTEMENT comme elle serait
  construite dans ce carnet (mêmes marges, pagination, layout).
TXT
