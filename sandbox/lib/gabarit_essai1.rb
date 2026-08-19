require "prawn"
require "prawn-svg"
require_relative "dsl_parser"
require_relative "../../lib/kdp"

module GabaritEssai1
  # Garde-fou GÉNÉRAL (règle absolue, 2026-08-17) : tout conflit qui relève d'un choix de
  # l'utilisateur (contenu trop long, élément qui empiète sur la marge ou sur un autre
  # élément, etc — PAS limité aux marges) passe par `conflict!`. Niveau de SENSIBILITÉ :
  #   1 = stoppe la construction (erreur bloquante — l'erreur doit être corrigée).
  #   2 = demande à l'utilisateur quoi faire (continuer ou stopper).
  #   3 = mémorise le conflit, continue, rapporte tout à la fin (`report_conflicts!`).
  #   4 = (DÉFAUT) continue silencieusement, log cachée seulement, rien dit à l'utilisateur.
  SENSITIVITY = 4
  # Chemin par défaut (essais isolés, `render`/`render_gab` appelés seuls) — un script de
  # production (ex. `Carnets/Carnet-*/build.rb`) le redirige vers SON propre fichier
  # `<production>-conflicts.log`, à côté du PDF produit (remarques.txt Carnet-1,
  # 2026-08-18 : un log par production, pas un fichier global partagé).
  @conflict_log_path = File.expand_path("../../_dev/conflicts.log", __dir__)
  class << self
    attr_accessor :conflict_log_path, :current_song, :current_page
  end
  CONFLICTS = []

  # Format de ligne imposé (remarques-v4.txt Carnet-1, point 1) : ni horodatage par ligne
  # (un seul temps début/fin pour tout le run, écrit par le script de production autour de
  # l'appel), ni juste le problème — chanson, page, problème ET solution adoptée.
  # `current_song`/`current_page` : contexte fixé par l'appelant (render_gab, paginate_and_draw)
  # — "?" si inconnu à ce stade (ex. accord vérifié avant la mise en page, page pas encore
  # déterminée).
  def self.conflict!(problem, solution:)
    line = "#{current_song || "?"} p.#{current_page || "?"} : #{problem} — #{solution}"
    case SENSITIVITY
    when 1
      raise line
    when 2
      warn "#{line}\nContinuer quand même ? (o/n)"
      answer = $stdin.gets.to_s.strip.downcase
      raise line unless answer == "o"
    when 3
      CONFLICTS << line
    else
      File.open(conflict_log_path, "a") { |f| f.puts line }
    end
  end

  # Niveau 3 seulement : à appeler une fois le carnet/la chanson construit(e).
  def self.report_conflicts!
    return if CONFLICTS.empty?

    warn "Conflits rencontrés :"
    CONFLICTS.each { |e| warn "- #{e}" }
  end

  CHORD_SIZE = 9
  TEXT_SIZE = 11
  # Plancher de rétrécissement d'une row côte à côte trop large (remarques.txt Carnet-1,
  # 2026-08-18) — valeur de départ, à ajuster empiriquement (Phil : "un chiffre à
  # déterminer, en constatant la diminution du texte"), PAS définitive.
  MIN_TEXT_SIZE = TEXT_SIZE - 2
  LINE_GAP = 4
  DIAG_W = 60
  DIAG_TEXT_GAP = 26
  # RAD3 : largeur plancher sous laquelle un diag ne doit jamais être réduit (valeur
  # provisoire, à ajuster — Phil, 2026-08-19).
  MIN_SIZE = { diags: { width: 48.0 } }.freeze

  # Marges : plus de valeur fixe — imposées par la classe `KDP` (2026-08-17), jamais
  # laissées au choix de l'utilisateur (esthétique, pas un réglage). Voir
  # `apply_kdp_margins`. Papier/bleed fixés ici tant qu'aucun autre besoin n'apparaît.
  KDP_PAPER = :white
  KDP_BLEED = false

  GEORGIA_DIR = File.expand_path("../../assets/fonts/Georgia", __dir__)
  HELVETICA_NEUE_DIR = File.expand_path("../../assets/fonts/HelveticaNeue", __dir__)
  # Taille de départ, standard éditorial courant pour un numéro de page — à ajuster
  # visuellement sur le livre-test (Phil, 2026-08-17).
  PAGE_NUMBER_SIZE = 10
  # Distance entre le numéro et le bord physique de la page, à l'intérieur de la marge
  # basse (jamais collé au bord). Doit rester < marge basse KDP courante.
  PAGE_NUMBER_BOTTOM_INSET_PT = 9

  def self.in_pt(inches)
    inches * 72.0
  end

  # Repositionne la zone de contenu Prawn (`pdf.bounds`) sur les VRAIES marges KDP de
  # cette page précise (recto/verso ont une marge de reliure différente) — à rappeler
  # après CHAQUE `start_new_page`, Prawn réinitialisant `bounds` sur la marge du document
  # à chaque nouvelle page.
  def self.apply_kdp_margins(pdf, kdp, page_no, page_w_pt, page_h_pt)
    lm = in_pt(kdp.left_margin(page_no))
    rm = in_pt(kdp.right_margin(page_no))
    tm = in_pt(kdp.top_margin)
    bm = in_pt(kdp.bottom_margin)
    pdf.bounds = Prawn::Document::BoundingBox.new(
      pdf, pdf, [lm, page_h_pt - tm], width: page_w_pt - lm - rm, height: page_h_pt - tm - bm
    )
  end

  # Numéro de page, coin extérieur bas (droite en recto, gauche en verso — convention
  # livre), à l'intérieur de la marge KDP (jamais flush au bord physique — bug corrigé
  # 2026-08-17 : `align: :right` sur `page_w_pt` collait le numéro pile sur le bord).
  # `pdf.canvas` bascule sur la page ENTIÈRE (pas `pdf.bounds`, qui exclut la marge).
  def self.draw_page_number(pdf, kdp, page_no, page_w_pt)
    pdf.font_families.update("Georgia" => {
      normal: File.join(GEORGIA_DIR, "Georgia-Regular.ttf"),
      bold: File.join(GEORGIA_DIR, "Georgia-Bold.ttf"),
      italic: File.join(GEORGIA_DIR, "Georgia-Italic.ttf"),
      bold_italic: File.join(GEORGIA_DIR, "Georgia-BoldItalic.ttf"),
    })
    recto = kdp.recto?(page_no)
    pdf.canvas do
      pdf.font("Georgia") do
        text_w = pdf.width_of(page_no.to_s, size: PAGE_NUMBER_SIZE, style: :bold)
        x = recto ? page_w_pt - in_pt(kdp.right_margin(page_no)) - text_w : in_pt(kdp.left_margin(page_no))
        pdf.draw_text page_no.to_s, at: [x, PAGE_NUMBER_BOTTOM_INSET_PT], size: PAGE_NUMBER_SIZE, style: :bold
      end
    end
  end

  # Équilibre optique haut/bas d'un bloc centré verticalement (page, colonne de diags...) :
  # un peu moins d'air entre ce qui précède (titre) et le bloc qu'entre le bloc et le bas de
  # page — poids appliqués aux deux gouttières extrêmes, les gouttières internes (entre
  # éléments) restent égales entre elles. Demandé par Phil (2026-08-16), pas une évidence
  # géométrique : NE PAS remettre à 1.0/1.0 sans lui redemander.
  TOP_GUTTER_WEIGHT = 0.85
  BOTTOM_GUTTER_WEIGHT = 1.15

  # Distance minimale JAMAIS franchie entre deux éléments (même sans chevauchement, trop
  # proches reste moche) et distance MAXIMALE JAMAIS dépassée (même avec beaucoup de place
  # libre, trop écartés reste moche aussi) — même valeur pour les deux directions pour
  # l'instant, à affiner par type d'élément plus tard. Valeurs de départ, à ajuster après
  # avoir vu le résultat. (Phil, 2026-08-16)
  # Table par TYPE d'élément (:diags, :title, :score, :tabla, :strophe...) — clé absente ⇒
  # valeur de :default. Seul :diags a une valeur propre pour l'instant (Phil, 2026-08-16),
  # les autres types tomberont sur :default tant qu'aucun besoin distinct n'est apparu.
  # `band_diag`/`band_strophe` : gouttière ENTRE la bande de titre et le 1er élément
  # (diag / couplet) — INDÉPENDANTE de la gouttière ENTRE éléments de même type (`diags`/
  # `default`). Les deux ne doivent jamais partager la même plage (Phil, 2026-08-19) : sinon
  # une plage resserrée pour "entre diags" resserre aussi, à tort, "sous le bandeau".
  # `tdm_num` (RATDM3) : distance entre le titre le plus long de la TDM et le chiffre de
  # page — valeur fixée à 20pt pour l'essai (Manuel, regles_esthetiques.adoc).
  MIN_V_DIST = { default: 20.0, diags: 2.0, band_diag: 10.0, band_strophe: 20.0 }.freeze
  MIN_H_DIST = { default: 8.0, diags: 4.0, tdm_num: 20.0 }.freeze
  MAX_V_DIST = { default: 80.0, diags: 2.0, band_diag: 20.0, band_strophe: 40.0 }.freeze
  MAX_H_DIST = { default: 40.0 }.freeze

  # RATDM4 : filet de conduite entre titre et numéro de page — caractère et espacement
  # réglables (Manuel).
  TDM = { leader_character: ".", leader_space: 3.0 }.freeze

  def self.min_v_dist(type = :default)
    MIN_V_DIST.fetch(type, MIN_V_DIST[:default])
  end

  def self.min_h_dist(type = :default)
    MIN_H_DIST.fetch(type, MIN_H_DIST[:default])
  end

  def self.max_v_dist(type = :default)
    MAX_V_DIST.fetch(type, MAX_V_DIST[:default])
  end

  def self.max_h_dist(type = :default)
    MAX_H_DIST.fetch(type, MAX_H_DIST[:default])
  end

  # Anti-page-clairsemée : si tout ce qui reste après la page courante ne remplirait
  # qu'une fraction (REBALANCE_MIN_FILL) de la page suivante, on repousse le dernier
  # élément de la page courante vers la suivante plutôt que de la laisser presque vide
  # en regard d'une page bien remplie. Règle demandée par Phil (2026-08-16), formulation
  # mathématique pas encore stabilisée — ce seuil est un point de départ, pas une valeur
  # définitive.
  REBALANCE_MIN_FILL = 0.4

  # Écartement CIBLE (en pt page) des lignes de la portée tab, une fois intégrée — choisie
  # au hasard pour amorcer le mécanisme, PAS une convention. Valeur provisoire : un carnet
  # test de 24 pages imprimé doit trancher les vraies tailles par défaut (Phil, 2026-08-16).
  TAB_LINE_SPACING = 8.0
  # Discrète (indication plutôt que titre) mais grasse — trop discrète sans le gras
  # (Phil, 2026-08-16).
  TAB_TITLE_SIZE = 9
  TAB_TITLE_GAP = 10
  TAB_TITLE_COLOR = "666666"

  TITLE_SIZE = 20
  INTERPRETE_SIZE = 12
  PC_SIZE = 7
  INFO_GAP = 16

  BAND_COLOR = "3A3A3A"
  BAND_GAP = 8
  # Respiration horizontale entre le texte du bandeau (titre à gauche, parolier/
  # compositeur à droite) et les bords du bandeau — même valeur des deux côtés.
  HEADER_PAD_X = 12

  ASSETS = File.expand_path("../../assets/chords_diags", __dir__)
  TABLATOR_PATH = File.expand_path("../../tools/tablator/tablator.rb", __dir__)
  PageElement = Struct.new(:height, :draw)

  # Boîte d'encre RÉELLE (llx, lly, urx, ury — unités/1000em) de chaque caractère latin
  # courant (français inclus), pour HelveticaNeue Bold/Regular — SEULE police utilisée par
  # l'app (voir `register_fonts`). Remplace l'ancienne table lue dans les AFM Core de Prawn
  # (Helvetica standard) : décalée depuis que le titre se dessine en HelveticaNeue (bug
  # constaté 2026-08-19, AIGLE — titre mal positionné, métriques désaccordées avec la police
  # réellement dessinée). Extraite via fontTools (glyf, xMin/yMin/xMax/yMax, mis à l'échelle
  # sur `unitsPerEm`) depuis `assets/fonts/HelveticaNeue/HelveticaNeue-{Bold,Regular}.ttf`.
  # Non mappé (ex. glyphe exotique) → tombe sur l'ascender/descender global, jamais un crash.
  HELVETICA_NEUE_BOLD_BBOX = {
    "!" => [61.0, 0.0, 218.0, 714.0],
    "\"" => [85.0, 393.0, 378.0, 714.0],
    "'" => [86.0, 393.0, 193.0, 714.0],
    "(" => [52.0, -181.0, 303.0, 731.0],
    ")" => [-6.0, -181.0, 244.0, 731.0],
    "," => [61.0, -165.0, 218.0, 154.0],
    "-" => [53.0, 212.0, 354.0, 334.0],
    "." => [60.0, 0.0, 217.0, 154.0],
    "/" => [-10.0, -16.0, 382.0, 731.0],
    ":" => [61.0, 0.0, 218.0, 508.0],
    ";" => [61.0, -165.0, 218.0, 508.0],
    "?" => [32.0, 0.0, 524.0, 731.0],
    "«" => [42.0, 80.0, 402.0, 463.0],
    "»" => [42.0, 80.0, 402.0, 463.0],
    "à" => [32.0, -13.0, 536.0, 785.0],
    "â" => [32.0, -13.0, 536.0, 723.0],
    "ä" => [32.0, -13.0, 536.0, 714.0],
    "á" => [32.0, -13.0, 536.0, 785.0],
    "ç" => [38.0, -217.0, 548.0, 531.0],
    "é" => [29.0, -13.0, 548.0, 785.0],
    "è" => [29.0, -13.0, 548.0, 785.0],
    "ê" => [29.0, -13.0, 548.0, 723.0],
    "ë" => [29.0, -13.0, 548.0, 714.0],
    "î" => [-45.0, 0.0, 305.0, 723.0],
    "ï" => [-40.0, 0.0, 300.0, 714.0],
    "ì" => [-62.0, 0.0, 200.0, 785.0],
    "ô" => [38.0, -13.0, 573.0, 723.0],
    "ö" => [38.0, -13.0, 573.0, 714.0],
    "ò" => [38.0, -13.0, 573.0, 785.0],
    "ù" => [54.0, -13.0, 539.0, 785.0],
    "û" => [54.0, -13.0, 539.0, 723.0],
    "ü" => [54.0, -13.0, 539.0, 714.0],
    "œ" => [38.0, -13.0, 897.0, 531.0],
    "æ" => [38.0, -13.0, 878.0, 531.0],
    "À" => [-6.0, 0.0, 692.0, 950.0],
    "Â" => [-6.0, 0.0, 692.0, 920.0],
    "Ä" => [-6.0, 0.0, 692.0, 911.0],
    "Á" => [-6.0, 0.0, 692.0, 955.0],
    "Ç" => [38.0, -217.0, 703.0, 731.0],
    "É" => [69.0, 0.0, 611.0, 955.0],
    "È" => [69.0, 0.0, 611.0, 955.0],
    "Ê" => [69.0, 0.0, 611.0, 920.0],
    "Ë" => [69.0, 0.0, 611.0, 911.0],
    "Î" => [-27.0, 0.0, 323.0, 920.0],
    "Ï" => [-22.0, 0.0, 318.0, 911.0],
    "Ì" => [-45.0, 0.0, 226.0, 955.0],
    "Ô" => [38.0, -16.0, 740.0, 920.0],
    "Ö" => [38.0, -16.0, 740.0, 911.0],
    "Ò" => [38.0, -16.0, 740.0, 955.0],
    "Ù" => [66.0, -16.0, 675.0, 955.0],
    "Û" => [66.0, -16.0, 675.0, 920.0],
    "Ü" => [66.0, -16.0, 675.0, 911.0],
    "Œ" => [38.0, -16.0, 1051.0, 731.0],
    "Æ" => [-10.0, 0.0, 944.0, 714.0],
    "0" => [21.0, -13.0, 535.0, 714.0],
    "1" => [74.0, 0.0, 392.0, 700.0],
    "2" => [21.0, 0.0, 535.0, 714.0],
    "3" => [17.0, -13.0, 538.0, 714.0],
    "4" => [16.0, 0.0, 540.0, 700.0],
    "5" => [18.0, -14.0, 538.0, 700.0],
    "6" => [21.0, -13.0, 535.0, 714.0],
    "7" => [39.0, 0.0, 517.0, 700.0],
    "8" => [14.0, -13.0, 542.0, 714.0],
    "9" => [21.0, -13.0, 535.0, 714.0],
    "A" => [-6.0, 0.0, 692.0, 714.0],
    "B" => [69.0, 0.0, 667.0, 714.0],
    "C" => [38.0, -16.0, 703.0, 731.0],
    "D" => [69.0, 0.0, 701.0, 714.0],
    "E" => [69.0, 0.0, 611.0, 714.0],
    "F" => [69.0, 0.0, 571.0, 714.0],
    "G" => [38.0, -16.0, 701.0, 731.0],
    "H" => [69.0, 0.0, 672.0, 714.0],
    "I" => [69.0, 0.0, 226.0, 714.0],
    "J" => [14.0, -16.0, 487.0, 714.0],
    "K" => [69.0, 0.0, 728.0, 714.0],
    "L" => [69.0, 0.0, 574.0, 714.0],
    "M" => [69.0, 0.0, 838.0, 714.0],
    "N" => [69.0, 0.0, 672.0, 714.0],
    "O" => [38.0, -16.0, 740.0, 731.0],
    "P" => [69.0, 0.0, 638.0, 714.0],
    "Q" => [38.0, -66.0, 740.0, 731.0],
    "R" => [69.0, 0.0, 684.0, 714.0],
    "S" => [23.0, -16.0, 625.0, 731.0],
    "T" => [13.0, 0.0, 598.0, 714.0],
    "U" => [66.0, -16.0, 675.0, 714.0],
    "V" => [-7.0, 0.0, 638.0, 714.0],
    "W" => [3.0, 0.0, 941.0, 714.0],
    "X" => [-5.0, 0.0, 673.0, 714.0],
    "Y" => [-8.0, 0.0, 676.0, 714.0],
    "Z" => [23.0, 0.0, 625.0, 714.0],
    "a" => [32.0, -13.0, 536.0, 531.0],
    "b" => [54.0, -13.0, 575.0, 714.0],
    "c" => [38.0, -13.0, 548.0, 531.0],
    "d" => [32.0, -13.0, 558.0, 714.0],
    "e" => [29.0, -13.0, 548.0, 531.0],
    "f" => [0.0, 0.0, 333.0, 714.0],
    "g" => [38.0, -195.0, 551.0, 531.0],
    "h" => [54.0, 0.0, 539.0, 714.0],
    "i" => [58.0, 0.0, 200.0, 714.0],
    "j" => [-18.0, -181.0, 209.0, 714.0],
    "k" => [67.0, 0.0, 578.0, 714.0],
    "l" => [58.0, 0.0, 200.0, 714.0],
    "m" => [58.0, 0.0, 848.0, 531.0],
    "n" => [54.0, 0.0, 539.0, 531.0],
    "o" => [38.0, -13.0, 573.0, 531.0],
    "p" => [54.0, -181.0, 580.0, 531.0],
    "q" => [32.0, -181.0, 558.0, 531.0],
    "r" => [54.0, 0.0, 387.0, 531.0],
    "s" => [29.0, -13.0, 508.0, 531.0],
    "t" => [6.0, -5.0, 338.0, 672.0],
    "u" => [54.0, -13.0, 539.0, 517.0],
    "v" => [5.0, 0.0, 515.0, 517.0],
    "w" => [6.0, 0.0, 808.0, 517.0],
    "x" => [0.0, 0.0, 537.0, 517.0],
    "y" => [-5.0, -181.0, 525.0, 517.0],
    "z" => [22.0, 0.0, 497.0, 517.0],
  }.freeze

  HELVETICA_NEUE_REGULAR_BBOX = {
    "!" => [74.0, 0.0, 185.0, 714.0],
    "\"" => [109.0, 456.0, 317.0, 714.0],
    "'" => [105.0, 456.0, 173.0, 714.0],
    "(" => [47.0, -197.0, 269.0, 731.0],
    ")" => [-9.0, -197.0, 212.0, 731.0],
    "," => [83.0, -146.0, 194.0, 111.0],
    "-" => [50.0, 238.0, 339.0, 318.0],
    "." => [83.0, 0.0, 194.0, 111.0],
    "/" => [-17.0, -16.0, 351.0, 731.0],
    ":" => [83.0, 0.0, 194.0, 517.0],
    ";" => [83.0, -146.0, 195.0, 517.0],
    "?" => [54.0, 0.0, 490.0, 731.0],
    "«" => [50.0, 114.0, 398.0, 442.0],
    "»" => [65.0, 114.0, 413.0, 442.0],
    "à" => [36.0, -11.0, 522.0, 770.0],
    "â" => [36.0, -11.0, 522.0, 751.0],
    "ä" => [36.0, -11.0, 522.0, 696.0],
    "á" => [36.0, -11.0, 522.0, 770.0],
    "ç" => [36.0, -209.0, 506.0, 529.0],
    "é" => [36.0, -11.0, 515.0, 770.0],
    "è" => [36.0, -11.0, 515.0, 770.0],
    "ê" => [36.0, -11.0, 515.0, 751.0],
    "ë" => [36.0, -11.0, 515.0, 696.0],
    "î" => [-38.0, 0.0, 261.0, 731.0],
    "ï" => [-27.0, 0.0, 250.0, 696.0],
    "ì" => [-32.0, 0.0, 172.0, 770.0],
    "ô" => [36.0, -11.0, 538.0, 751.0],
    "ö" => [36.0, -11.0, 538.0, 696.0],
    "ò" => [36.0, -11.0, 538.0, 770.0],
    "ù" => [64.0, -11.0, 492.0, 770.0],
    "û" => [64.0, -11.0, 492.0, 731.0],
    "ü" => [64.0, -11.0, 492.0, 696.0],
    "œ" => [36.0, -11.0, 867.0, 529.0],
    "æ" => [36.0, -11.0, 846.0, 529.0],
    "À" => [-6.0, 0.0, 656.0, 927.0],
    "Â" => [-6.0, 0.0, 656.0, 908.0],
    "Ä" => [-6.0, 0.0, 656.0, 873.0],
    "Á" => [-6.0, 0.0, 656.0, 927.0],
    "Ç" => [43.0, -209.0, 682.0, 731.0],
    "É" => [78.0, 0.0, 574.0, 927.0],
    "È" => [78.0, 0.0, 574.0, 927.0],
    "Ê" => [78.0, 0.0, 574.0, 908.0],
    "Ë" => [78.0, 0.0, 574.0, 873.0],
    "Î" => [-19.0, 0.0, 280.0, 908.0],
    "Ï" => [-8.0, 0.0, 269.0, 873.0],
    "Ì" => [-23.0, 0.0, 181.0, 927.0],
    "Ô" => [38.0, -16.0, 722.0, 908.0],
    "Ö" => [38.0, -16.0, 722.0, 873.0],
    "Ò" => [38.0, -16.0, 722.0, 927.0],
    "Ù" => [74.0, -16.0, 648.0, 927.0],
    "Û" => [74.0, -16.0, 648.0, 908.0],
    "Ü" => [74.0, -16.0, 648.0, 873.0],
    "Œ" => [38.0, -16.0, 1034.0, 731.0],
    "Æ" => [-6.0, 0.0, 895.0, 714.0],
    "0" => [42.0, -11.0, 514.0, 709.0],
    "1" => [87.0, 0.0, 356.0, 709.0],
    "2" => [24.0, 0.0, 494.0, 709.0],
    "3" => [29.0, -11.0, 510.0, 709.0],
    "4" => [28.0, 0.0, 515.0, 709.0],
    "5" => [35.0, -11.0, 509.0, 697.0],
    "6" => [38.0, -11.0, 519.0, 709.0],
    "7" => [50.0, 0.0, 509.0, 697.0],
    "8" => [40.0, -11.0, 516.0, 709.0],
    "9" => [34.0, -11.0, 510.0, 709.0],
    "A" => [-6.0, 0.0, 656.0, 714.0],
    "B" => [78.0, 0.0, 640.0, 714.0],
    "C" => [43.0, -16.0, 682.0, 731.0],
    "D" => [78.0, 0.0, 666.0, 714.0],
    "E" => [78.0, 0.0, 574.0, 714.0],
    "F" => [78.0, 0.0, 547.0, 714.0],
    "G" => [43.0, -16.0, 697.0, 731.0],
    "H" => [78.0, 0.0, 644.0, 714.0],
    "I" => [82.0, 0.0, 177.0, 714.0],
    "J" => [22.0, -16.0, 441.0, 714.0],
    "K" => [78.0, 0.0, 670.0, 714.0],
    "L" => [78.0, 0.0, 551.0, 714.0],
    "M" => [80.0, 0.0, 791.0, 714.0],
    "N" => [77.0, 0.0, 646.0, 714.0],
    "O" => [38.0, -16.0, 722.0, 731.0],
    "P" => [78.0, 0.0, 610.0, 714.0],
    "Q" => [38.0, -61.0, 722.0, 731.0],
    "R" => [78.0, 0.0, 656.0, 714.0],
    "S" => [37.0, -16.0, 611.0, 731.0],
    "T" => [2.0, 0.0, 573.0, 714.0],
    "U" => [74.0, -16.0, 648.0, 714.0],
    "V" => [0.0, 0.0, 613.0, 714.0],
    "W" => [12.0, 0.0, 914.0, 714.0],
    "X" => [0.0, 0.0, 612.0, 714.0],
    "Y" => [2.0, 0.0, 646.0, 714.0],
    "Z" => [22.0, 0.0, 590.0, 714.0],
    "a" => [36.0, -11.0, 522.0, 529.0],
    "b" => [67.0, -11.0, 557.0, 714.0],
    "c" => [36.0, -11.0, 506.0, 529.0],
    "d" => [36.0, -11.0, 526.0, 714.0],
    "e" => [36.0, -11.0, 515.0, 529.0],
    "f" => [12.0, 0.0, 297.0, 722.0],
    "g" => [36.0, -209.0, 510.0, 529.0],
    "h" => [64.0, 0.0, 492.0, 714.0],
    "i" => [69.0, 0.0, 154.0, 714.0],
    "j" => [-13.0, -197.0, 154.0, 714.0],
    "k" => [69.0, 0.0, 519.0, 714.0],
    "l" => [69.0, 0.0, 154.0, 714.0],
    "m" => [64.0, 0.0, 789.0, 529.0],
    "n" => [64.0, 0.0, 492.0, 529.0],
    "o" => [36.0, -11.0, 538.0, 529.0],
    "p" => [67.0, -197.0, 557.0, 529.0],
    "q" => [36.0, -197.0, 526.0, 529.0],
    "r" => [61.0, 0.0, 333.0, 531.0],
    "s" => [31.0, -11.0, 470.0, 529.0],
    "t" => [9.0, 0.0, 285.0, 672.0],
    "u" => [64.0, -11.0, 492.0, 517.0],
    "v" => [14.0, 0.0, 486.0, 517.0],
    "w" => [17.0, 0.0, 741.0, 517.0],
    "x" => [9.0, 0.0, 509.0, 517.0],
    "y" => [8.0, -207.0, 492.0, 517.0],
    "z" => [22.0, 0.0, 458.0, 517.0],
  }.freeze

  # `pdf.font_size(taille) { bloc }` ne renvoie JAMAIS la valeur du bloc (bug trouvé dans
  # Prawn lui-même : la méthode renvoie la taille de police PRÉCÉDENTE, pas le résultat du
  # yield — voir prawn/font.rb#font_size). Utilisé partout dans ce fichier pour lire
  # ascender/descender/height à une taille donnée : il faut capturer la valeur DANS le
  # bloc, jamais compter sur le retour de `font_size` (Phil, 2026-08-16).
  def self.font_metric(pdf, size)
    value = nil
    pdf.font_size(size) { value = yield }
    value
  end

  # Étendue d'encre RÉELLE du texte (pas la métrique globale de la police) : [top, bottom],
  # en pt au-dessus/en dessous de la ligne de base. Chaque caractère apporte SA PROPRE boîte
  # d'encre (voir HELVETICA_NEUE_*_BBOX) ; l'ascender/descender de la police ne sert QUE de
  # repli pour un caractère non trouvé dans la table — jamais de plancher global, sinon un
  # titre sans jambage (ex. "Le Pénitencier") hérite quand même de la réserve de descente
  # de la police entière, refaussant l'espace visuel (déjà vu, corrigé ici pour de bon).
  def self.ink_extent(pdf, text, size, style: nil)
    table = style == :bold ? HELVETICA_NEUE_BOLD_BBOX : HELVETICA_NEUE_REGULAR_BBOX
    ascent_fallback = font_metric(pdf, size) { pdf.font.ascender }
    descent_fallback = font_metric(pdf, size) { pdf.font.descender }
    top = 0.0
    bottom = 0.0
    text.each_char do |ch|
      next if ch == " "

      bbox = table[ch]
      char_top, char_bottom = bbox ? [bbox[3] / 1000.0 * size, -(bbox[1] / 1000.0 * size)] : [ascent_fallback, descent_fallback]
      top = [top, char_top].max
      bottom = [bottom, char_bottom].max
    end
    [top, bottom]
  end

  # HelveticaNeue enregistrée sous son propre nom ET sous "sans-serif" (nom générique
  # utilisé par le font-family des SVG de diags) — sinon prawn-svg retombe sur la police
  # AFM interne de Prawn (Windows-1252 seul), qui plante sur ♯/♭ (Prawn::Errors::
  # IncompatibleStringEncoding, constaté en pratique, 2026-08-18). Fixée comme police par
  # défaut du document (spec : Helvetica Neue retenue pour les carnets).
  def self.register_fonts(pdf)
    helvetica_neue = {
      normal: File.join(HELVETICA_NEUE_DIR, "HelveticaNeue-Regular.ttf"),
      bold: File.join(HELVETICA_NEUE_DIR, "HelveticaNeue-Bold.ttf"),
      italic: File.join(HELVETICA_NEUE_DIR, "HelveticaNeue-Italic.ttf"),
      bold_italic: File.join(HELVETICA_NEUE_DIR, "HelveticaNeue-BoldItalic.ttf"),
    }
    pdf.font_families.update("HelveticaNeue" => helvetica_neue, "sans-serif" => helvetica_neue)
    pdf.font "HelveticaNeue"
  end

  # page_size_in : [largeur, hauteur] en pouces. header_style: :inline (titre + infos sur
  # la ligne du titre, fond page) ou :band (bandeau foncé pleine page en haut, texte clair).
  # page_count: nombre de pages TOTAL du carnet (détermine la marge de reliure KDP,
  # cf. `KDP#gutter_margin`) ; first_page_no: numéro de la première page de cette chanson
  # dans le carnet complet (recto/verso, numérotation).
  def self.render(dsl_path, out_path, page_size_in:, page_count:, header_style: :inline, first_page_no: 1)
    song = DSLParser.parse(File.read(dsl_path))
    chord_frets = collect_chord_frets(song.blocks)
    page_size = page_size_in.map { |v| v * 72 }
    page_w_pt, page_h_pt = page_size
    kdp = KDP.new(page_count: page_count, trim_width: page_size_in[0], trim_height: page_size_in[1],
      paper: KDP_PAPER, bleed: KDP_BLEED)

    Prawn::Document.generate(out_path, page_size: page_size, margin: 0) do |pdf|
      register_fonts(pdf)
      apply_kdp_margins(pdf, kdp, first_page_no, page_w_pt, page_h_pt)
      header_bottom = header_style == :band ? draw_header_band(pdf, song.meta) : draw_header_inline(pdf, song.meta)

      diag_paths = chord_frets.filter_map { |chord, fret| diag_path(chord, fret: fret) }
      diag_w = DIAG_W
      diag_heights = diag_paths.map { |p| svg_height_for(File.read(p), diag_w) }

      # Essai 1 : page recto — "intérieur" (côté reliure) = gauche.
      diag_col_w = diag_w + DIAG_TEXT_GAP
      text_x = diag_col_w
      text_w = pdf.bounds.width - diag_col_w

      draw_diags(pdf, diag_paths, diag_heights, x: 0, avail_h: header_bottom, width: diag_w)

      chord_ascent = font_metric(pdf, CHORD_SIZE) { pdf.font.ascender }
      text_ascent = font_metric(pdf, TEXT_SIZE) { pdf.font.ascender }
      text_descent = font_metric(pdf, TEXT_SIZE) { pdf.font.descender }
      cote_a_cote = song.meta.fetch("cote_a_cote", true)

      elements = build_row_elements(pdf, song.blocks, text_x, text_w, chord_ascent, text_ascent, text_descent, cote_a_cote)
      tabla_el = build_tabla_element(pdf, song.meta, dsl_path, text_x, text_w)
      elements << tabla_el if tabla_el

      paginate_and_draw(pdf, elements, header_bottom, kdp: kdp, page_w_pt: page_w_pt, page_h_pt: page_h_pt, first_page_no: first_page_no)
    end
  end

  # Tabla (tablature/accompagnement, SVG rendu à part via Tablator). RÈGLE ABSOLUE (Phil,
  # 2026-08-16) : jamais de saut de page sans raison de place — donc pas de page dédiée,
  # c'est un élément de plus dans la MÊME pagination que les rows de couplets (voir
  # `paginate_and_draw`), il partage la page courante si la place suffit.
  def self.build_tabla_element(pdf, meta, dsl_path, x0, width)
    return nil unless meta["tabla"]

    path = File.expand_path(meta["tabla"], File.dirname(dsl_path))
    return nil unless File.exist?(path)

    svg_data = File.read(path)
    embed_w = [tab_embed_width(svg_data, TAB_LINE_SPACING), width].min
    svg_h = svg_height_for(svg_data, embed_w)

    title = meta["tabla_titre"]
    title_ascent = title ? font_metric(pdf, TAB_TITLE_SIZE) { pdf.font.ascender } : 0
    title_h = title ? font_metric(pdf, TAB_TITLE_SIZE) { pdf.font.height } + TAB_TITLE_GAP : 0

    draw = lambda do |pdf_, y|
      if title
        draw_text_colored(pdf_, title, at: [x0, y - title_ascent], size: TAB_TITLE_SIZE, style: :bold, color: TAB_TITLE_COLOR)
      end
      pdf_.svg(svg_data, at: [x0, y - title_h], width: embed_w, position: :left, enable_web_requests: false)
    end

    PageElement.new(title_h + svg_h, draw)
  end

  # --- Format .gab / .lyr / .infos (2026-08-16, essais de placement) ----------------

  # `.infos` : métadonnées, une par ligne "clé: valeur" (pas de YAML/---).
  # Clés canoniques attendues par le gabarit : titre/date/parolier/compositeur/interprete.
  # Clés alternatives tolérées (Phil, 2026-08-17 : "tu les prends comme possibles dans le
  # code" — pas de réécriture de fichier imposée) : n'écrasent JAMAIS la clé canonique si
  # elle est déjà présente.
  INFOS_KEY_ALIASES = { "title" => "titre", "year" => "date", "composer" => "compositeur", "lyrics" => "parolier" }.freeze

  def self.parse_infos(path)
    meta = {}
    File.foreach(path) do |line|
      k, v = line.strip.split(":", 2)
      meta[k.strip] = v.strip if k && v && !k.strip.empty?
    end
    INFOS_KEY_ALIASES.each { |alt, canon| meta[canon] ||= meta[alt] }
    meta
  end

  # Reprend telle quelle la logique de segments accord/texte de DSLParser#parse_line
  # (privée, donc dupliquée ici plutôt que contournée par `send`).
  # "_" (accord seul en début de vers) -> 3 espaces (Phil 2026-08-17). Voir DSLParser#parse_line.
  def self.parse_lyr_line(line)
    line = line.gsub("_", "   ")
    matches = line.to_enum(:scan, DSLParser::CHORD_RE).map { Regexp.last_match }
    return [Segment.new(chord: nil, text: line)] if matches.empty? && !line.empty?
    return [] if matches.empty?

    segments = []
    pre = line[0...matches.first.begin(0)]
    segments << Segment.new(chord: nil, text: pre) unless pre.empty?
    matches.each_with_index do |m, i|
      text_start = m.end(0)
      text_end = i + 1 < matches.length ? matches[i + 1].begin(0) : line.length
      segments << Segment.new(chord: m[1] && DSLParser.normalize_chord(m[1]), fret: m[2], text: line[text_start...text_end])
    end
    segments
  end

  # `.lyr` : couplets — chaque paragraphe commence par `{nom}` (SANS ":", à ne pas confondre
  # avec une directive `{clé: valeur}`), suivi des lignes accord/texte. Le nom est OPTIONNEL
  # (règle : rien ne doit être impossible, Phil 2026-08-17) — un paragraphe sans `{nom}` reçoit
  # `couplet-N` (N = position du paragraphe dans le fichier).
  # `{nom}` répété SANS corps : rappel — reprend à cette position le contenu déjà défini
  # sous ce nom (ex. refrain qui revient plusieurs fois dans la chanson). Répété AVEC corps :
  # redéfinition, remplace le contenu précédent (signalé en conflict log, à l'user de juger).
  # Renvoie [Hash{nom => Block}, Array<nom>] — le Hash pour être pioché par nom depuis le
  # `.gab` (`{song: nom}`), l'Array pour l'ordre réel d'apparition (avec répétitions) utilisé
  # par `default_items`.
  # Reconnaît un paragraphe comme réapparition d'un bloc déjà vu quand son CONTENU est
  # identique à un bloc déjà stocké — que ce soit via `{nom}` répété (avec ou sans corps)
  # ou un paragraphe sans nom recopiant mot pour mot un couplet/refrain déjà défini (ex.
  # AYNL, dernier refrain recopié en entier sans `{refrain}`). Sans ça, le paragraphe
  # récupère le mauvais "type" (`couplet-N` auto), ce qui casse le pairage par type (RAO5).
  # Deux paragraphes de MÊME NOM mais de contenu DIFFÉRENT restent une vraie redéfinition :
  # au lieu d'écraser (perte de contenu, interdit — Phil 2026-08-18), le 2nd est renommé en
  # suffixe (`nom-2`, `nom-3`...) pour que les deux soient rendus.
  def self.parse_lyr(path)
    blocks = {}
    order = []
    raw_bodies = {}
    paragraphs = File.read(path).split(/\n{2,}/).map(&:strip).reject(&:empty?)
    paragraphs.each_with_index do |para, i|
      lines = para.split("\n")
      header = lines.first
      if header =~ /\A\{([^:;}]+)\}\z/
        given_name = Regexp.last_match(1).strip
        body = lines[1..] || []
      else
        given_name = nil
        body = lines
      end

      key = body.join("\n")
      existing_name = body.empty? ? nil : raw_bodies[key]

      if existing_name
        name = existing_name
      elsif given_name && blocks.key?(given_name) && !body.empty?
        original = given_name
        n = 2
        n += 1 while blocks.key?("#{original}-#{n}")
        name = "#{original}-#{n}"
        conflict!("bloc \"#{original}\" redéfini", solution: "renommé en \"#{name}\" pour conserver les deux contenus")
      else
        name = given_name || "couplet-#{i + 1}"
      end

      order << name
      next if blocks.key?(name) # contenu déjà stocké (répétition par nom ou par contenu)

      raw_bodies[key] = name
      blocks[name] = Block.new(lines: body.map { |l| Line.new(segments: parse_lyr_line(l)) }, directives: {}, paired_with_previous: false)
    end
    [blocks, order]
  end

  GabItem = Struct.new(:type, :data)

  # `.gab` : suite de paragraphes — soit une directive `{clé: valeur; ...}` (classée par la
  # clé qu'elle porte : titre/tabla/diags), soit une row de contenu `{song: nom}` (une ou
  # deux, séparées par `//` pour le côte-à-côte, comme le `//` du DSL simple), soit une row
  # de blocs `.lyr` référencés DIRECTEMENT par leur nom `{nom}` (sans `song:`) — `+` entre
  # deux `{nom}` CONCATÈNE leurs paroles en un seul bloc rendu (Phil, 2026-08-19 : forcer
  # un pseudo-refrain coupé en plusieurs blocs à s'afficher comme un seul, à côté d'un
  # couplet, via `//`). Ex. `{couplet-1} // {refrain-part1-1} + {refrain-part2-1}`.
  ROW_TOKEN_RE = /\A\{[^:;}]+\}(\s*\+\s*\{[^:;}]+\})*\z/.freeze

  def self.parse_gab(path)
    File.read(path).split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
      if para.include?("{song:")
        names = para.split("//").filter_map { |chunk| chunk[/\{song:\s*([^;}]+)/, 1]&.strip }
        GabItem.new(:row, names)
      elsif (cols = para.split("//").map(&:strip)).all? { |c| c =~ ROW_TOKEN_RE }
        names = cols.map { |c| c.scan(/\{([^:;}]+)\}/).flatten.map(&:strip).join("+") }
        GabItem.new(:row, names)
      else
        inner = para[/\A\{(.*)\}\z/m, 1] || ""
        dirs = {}
        inner.split(";").each do |pair|
          k, v = pair.split(":", 2)
          next unless k && v && !k.strip.empty?

          dirs[k.strip.to_sym] = v.strip.gsub(/\A["']|["']\z/, "")
        end
        # `tabla`/`diags` avant `title` : la directive tabla porte elle-même une clé
        # `title` (sa légende) — sinon elle se ferait passer pour la config d'en-tête.
        type = %i[tabla diags title].find { |k| dirs.key?(k) } || :unknown
        GabItem.new(type, dirs)
      end
    end
  end

  # Génère le SVG de la tabla à la demande si absent, ou si le `.tab` source est plus
  # récent que le `.svg` déjà là (cache invalidé par date de fichier). `name` sans
  # extension. Renvoie le chemin du SVG, ou nil si ni SVG ni .tab n'existent.
  def self.ensure_tabla_svg(folder, name)
    svg_path = File.join(folder, "#{name}.svg")
    tab_path = File.join(folder, "#{name}.tab")
    return svg_path if File.exist?(svg_path) && (!File.exist?(tab_path) || File.mtime(tab_path) <= File.mtime(svg_path))
    return nil unless File.exist?(tab_path)

    system("ruby", TABLATOR_PATH, tab_path, "-o", File.join(folder, name), out: File::NULL, err: File::NULL) or
      raise "échec de tablator sur #{tab_path}"
    svg_path
  end

  # Tabla positionnée EXACTEMENT là où `{tabla: ...}` apparaît dans le `.gab` (au lieu de
  # toujours après les couplets) — sa place dans l'ordre du `.gab` EST sa position ("top"
  # = premier élément, "fin" = dernier). align:center la centre dans la largeur dispo.
  # max_height : si donné et que la tabla (titre + image) ne tiendrait pas dedans, l'image
  # est réduite (largeur, donc hauteur — ratio conservé) pour tenir EXACTEMENT dedans, sans
  # plancher minimal ("sans limite", Phil 2026-08-16) — le titre, lui, ne rétrécit jamais.
  def self.build_tabla_element_v2(pdf, svg_path, x0, width, align: nil, title: nil, max_height: nil)
    svg_data = File.read(svg_path)
    embed_w = [tab_embed_width(svg_data, TAB_LINE_SPACING), width].min

    title_ascent = title ? font_metric(pdf, TAB_TITLE_SIZE) { pdf.font.ascender } : 0
    title_h = title ? font_metric(pdf, TAB_TITLE_SIZE) { pdf.font.height } + TAB_TITLE_GAP : 0
    svg_h = svg_height_for(svg_data, embed_w)

    if max_height && title_h + svg_h > max_height
      target_svg_h = [max_height - title_h, 0.0].max
      vb_w, vb_h = svg_viewbox(svg_data)
      embed_w = target_svg_h * vb_w / vb_h
      svg_h = target_svg_h
    end

    svg_x = align == "center" ? x0 + [(width - embed_w) / 2.0, 0].max : x0
    draw = lambda do |pdf_, y|
      draw_text_colored(pdf_, title, at: [svg_x, y - title_ascent], size: TAB_TITLE_SIZE, style: :bold, color: TAB_TITLE_COLOR) if title
      pdf_.svg(svg_data, at: [svg_x, y - title_h], width: embed_w, position: :left, enable_web_requests: false)
    end
    PageElement.new(title_h + svg_h, draw)
  end

  # Valeurs par défaut (Phil, 2026-08-17 : "le moins de définitions possibles" — un `.gab`
  # ne sert qu'à ÉCARTER ces défauts, jamais à les répéter). PLUS TARD : fichier YAML de
  # config SongBook, pour qui veut les changer sans toucher au code.
  DEFAULT_HEADER_STYLE = "band"
  DEFAULT_DIAG_POSITION = "left" # = "intérieur"

  # `.gab` absent : couplets du `.lyr` pairés côte à côte 2 par 2, dans leur ordre
  # d'apparition RÉEL (`order`, répétitions incluses — un refrain qui revient 3 fois dans
  # la chanson est réimprimé 3 fois), jamais l'affichage "empilé" façon ChordPro, avec les
  # défauts ci-dessus.
  # Bloc sans corps (`{nom}` sans ligne dessous — voir `parse_lyr`) EXCLU du pairage : sinon
  # il gaspille toute une colonne de la row où il tombe (bug trouvé, 2026-08-18, sur "Au fur
  # et à mesure" — 2 rows sur 3 pages n'affichaient qu'un seul couplet, l'autre colonne vide).
  def self.block_kind(name)
    name.sub(/-\d+\z/, "")
  end

  def self.default_items(lyr_blocks, order)
    items = [GabItem.new(:title, { title: DEFAULT_HEADER_STYLE }), GabItem.new(:diags, { position: DEFAULT_DIAG_POSITION })]
    names = order.reject { |name| lyr_blocks.fetch(name).lines.empty? }
    pending = nil
    names.each do |name|
      if pending && block_kind(pending) == block_kind(name)
        items << GabItem.new(:row, [pending, name])
        pending = nil
      else
        items << GabItem.new(:row, [pending]) if pending
        pending = name
      end
    end
    items << GabItem.new(:row, [pending]) if pending
    items
  end

  # `name` peut être "nomA+nomB" (voir `parse_gab`, marque `+`) : concatène les lignes des
  # blocs dans l'ordre pour n'en faire qu'un seul, rendu comme un bloc normal.
  def self.resolve_block(lyr_blocks, name)
    return lyr_blocks.fetch(name) unless name.include?("+")

    parts = name.split("+").map { |n| lyr_blocks.fetch(n) }
    Block.new(lines: parts.flat_map(&:lines), directives: parts.first.directives, paired_with_previous: false)
  end

  # Orchestrateur .gab/.lyr/.infos : un dossier = une chanson + une mise en page d'essai.
  # Seule la position "left" des diags est câblée pour l'instant (Right/Top/Bot à venir).
  # `.gab` OPTIONNEL (voir `default_items`). page_count/first_page_no : voir `render`.
  def self.render_gab(folder, out_path, page_size_in:, page_count:, first_page_no: 1)
    gab_path = Dir.glob(File.join(folder, "*.gab")).first
    lyr_path = Dir.glob(File.join(folder, "*.lyr")).first
    infos_path = Dir.glob(File.join(folder, "*.infos")).first
    raise "fichiers .lyr/.infos introuvables dans #{folder}" unless lyr_path && infos_path

    meta = parse_infos(infos_path)
    self.current_song = meta["titre"] || File.basename(folder)
    self.current_page = first_page_no
    lyr_blocks, lyr_order = parse_lyr(lyr_path)
    items = gab_path ? parse_gab(gab_path) : default_items(lyr_blocks, lyr_order)
    page_size = page_size_in.map { |v| v * 72 }
    page_w_pt, page_h_pt = page_size
    kdp = KDP.new(page_count: page_count, trim_width: page_size_in[0], trim_height: page_size_in[1],
      paper: KDP_PAPER, bleed: KDP_BLEED)

    Prawn::Document.generate(out_path, page_size: page_size, margin: 0) do |pdf|
      register_fonts(pdf)
      apply_kdp_margins(pdf, kdp, first_page_no, page_w_pt, page_h_pt)
      header_style = items.find { |i| i.type == :title }&.data&.dig(:title) == "band" ? :band : :inline
      header_bottom = header_style == :band ? draw_header_band(pdf, meta) : draw_header_inline(pdf, meta)

      chord_frets = collect_chord_frets(lyr_blocks.values)
      diag_paths = chord_frets.filter_map { |chord, fret| diag_path(chord, fret: fret) }
      diag_position = (items.find { |i| i.type == :diags }&.data&.dig(:position) || "left").to_sym

      text_x, text_w, first_avail_h, side_col = layout_diags(pdf, diag_paths, diag_position, header_bottom)

      chord_ascent = font_metric(pdf, CHORD_SIZE) { pdf.font.ascender }
      text_ascent = font_metric(pdf, TEXT_SIZE) { pdf.font.ascender }
      text_descent = font_metric(pdf, TEXT_SIZE) { pdf.font.descender }

      rows = items.select { |i| i.type == :row }.map { |i| i.data.map { |name| resolve_block(lyr_blocks, name) } }
      col1_w, col2_w, h_gutter = row_column_widths(pdf, rows, text_w)

      row_idx = 0
      elements = []
      shrink_jobs = [] # {index:, svg_path:, align:, title:} — tablas à réduire si besoin
      items.each do |item|
        case item.type
        when :row
          elements.concat(build_row_or_split(pdf, rows[row_idx], text_x, text_w, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent))
          row_idx += 1
        when :tabla
          name = item.data[:tabla]
          svg_path = ensure_tabla_svg(folder, name)
          next unless svg_path

          align = item.data[:align]
          title = item.data[:title]
          elements << build_tabla_element_v2(pdf, svg_path, text_x, text_w, align: align, title: title)
          if item.data[:shrink] == "true"
            shrink_jobs << { index: elements.size - 1, svg_path: svg_path, align: align, title: title }
          end
        end
      end

      # `shrink` : RESPECTE la position choisie par l'auteur du .gab — jamais déplacée par
      # la pagination (épinglée), seulement réduite si besoin. L'espace qui lui revient
      # est calculé avec sa hauteur NATURELLE (pas simulée à 0 : sinon la pagination des
      # AUTRES éléments se trompe aussi, en pensant qu'il y a plus de place libre qu'il
      # n'y en aura réellement — vu en pratique, ça faisait remonter la page suivante sur
      # celle-ci). Ainsi la page d'à côté ne peut jamais déborder sur celle-ci
      # (Phil, 2026-08-16).
      pinned = shrink_jobs.map { |j| j[:index] }
      shrink_jobs.each do |job|
        pages = paginate(elements, first_avail_h, pdf.bounds.height, pinned: pinned)
        page = pages.find { |p| (p[:start]...p[:finish]).cover?(job[:index]) }
        others_h = (page[:start]...page[:finish]).sum { |j| j == job[:index] ? 0 : elements[j].height }
        max_h = page[:avail_h] - others_h
        next if elements[job[:index]].height <= max_h

        elements[job[:index]] = build_tabla_element_v2(
          pdf, job[:svg_path], text_x, text_w, align: job[:align], title: job[:title], max_height: max_h
        )
      end

      paginate_and_draw(pdf, elements, first_avail_h, kdp: kdp, page_w_pt: page_w_pt, page_h_pt: page_h_pt, first_page_no: first_page_no, pinned: pinned, side_col: side_col)
    end
  end

  # Écart RÉEL (en unités SVG) entre les lignes de la portée tab, mesuré directement dans
  # le SVG produit par Tablator (groupes `<g transform="translate(x, y)">` portant chacun
  # une ligne pleine largeur) — pas une valeur supposée. `nil` si la structure attendue
  # n'est pas trouvée (SVG d'une autre origine, par exemple).
  def self.tab_line_spacing(svg_data)
    viewbox_w = svg_data[/viewBox="[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+[\d.]+"/, 1].to_f
    return nil if viewbox_w.zero?

    ys = svg_data.scan(/<g transform="translate\([-\d.]+,\s*([-\d.]+)\)">\s*<line[^>]*x1="[\d.]+"\s*y1="0"\s*x2="([\d.]+)"/)
                 .filter_map { |y, x2| y.to_f if x2.to_f > viewbox_w * 0.5 }
                 .uniq.sort
    return nil if ys.size < 2

    diffs = ys.each_cons(2).map { |a, b| b - a }
    diffs.sum / diffs.size
  end

  # Largeur d'intégration (pt) donnant, une fois le SVG mis à l'échelle, l'écart de lignes
  # `target_spacing_pt` — calculée sur l'écart réel mesuré, pas une largeur de page fixe.
  def self.tab_embed_width(svg_data, target_spacing_pt)
    viewbox_w = svg_data[/viewBox="[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+[\d.]+"/, 1].to_f
    spacing = tab_line_spacing(svg_data)
    return viewbox_w if spacing.nil? || spacing.zero?

    target_spacing_pt * viewbox_w / spacing
  end

  def self.block_width(pdf, block, text_size: TEXT_SIZE)
    block.lines.map { |l| pdf.width_of(l.segments.map(&:text).join, size: text_size) }.max || 0
  end

  # Paires [chord, fret] uniques (fret nil = pas précisé dans la source). Un même accord
  # avec/sans case explicite, ou à deux cases différentes, compte comme deux entrées —
  # chacune sélectionne un diagramme différent (voir `diag_path`).
  def self.collect_chord_frets(blocks)
    blocks.flat_map { |b| b.lines.flat_map { |l| l.segments.select(&:chord).map { |s| [s.chord, s.fret] } } }.uniq
  end

  # "(interprète, année)" — entre parenthèses, jamais de label (Phil, 2026-08-16).
  def self.format_interprete(meta)
    parts = [meta["interprete"], meta["date"]].compact
    parts.empty? ? "" : "(#{parts.join(', ')})"
  end

  # Titre à gauche ; interprète/date juste à droite du titre (plus petit que le titre,
  # mais plus gros que parolier/compositeur) ; parolier/compositeur fer à droite (le plus
  # petit des trois) — les trois SUR LA MÊME LIGNE DE BASE que le titre, `y` (Phil,
  # 2026-08-16). Identique pour :inline et :band — le bandeau ne doit RIEN changer à la
  # position du titre, seulement ajouter un fond derrière.
  def self.draw_header_row(pdf, meta, y, title_color:, info_color:)
    title = meta["titre"].to_s
    draw_text_colored(pdf, title, at: [HEADER_PAD_X, y], size: TITLE_SIZE, style: :bold, color: title_color)
    title_w = pdf.width_of(title, size: TITLE_SIZE, style: :bold)
    left_edge = HEADER_PAD_X + title_w

    interprete = format_interprete(meta)
    unless interprete.empty?
      draw_text_colored(pdf, interprete, at: [HEADER_PAD_X + title_w + INFO_GAP, y], size: INTERPRETE_SIZE, color: info_color)
      left_edge += INFO_GAP + pdf.width_of(interprete, size: INTERPRETE_SIZE)
    end

    pc = [meta["parolier"], meta["compositeur"]].compact.join(" / ")
    unless pc.empty?
      w = pdf.width_of(pc, size: PC_SIZE)
      right_edge = pdf.bounds.width - HEADER_PAD_X - w
      if left_edge > right_edge
        conflict!("en-tête : titre/interprète (#{left_edge.round(1)}pt) chevauche parolier/compositeur (#{right_edge.round(1)}pt) — titre trop long",
          solution: "dessiné quand même, en chevauchant")
      end
      draw_text_colored(pdf, pc, at: [right_edge, y], size: PC_SIZE, color: info_color)
    end
  end

  # `draw_text` ignore silencieusement l'option `:color` (vérifié dans le source Prawn/
  # pdf-core — jamais lue) : seul `fill_color`, posé AVANT le dessin, fixe la couleur
  # réelle. Restaure le noir après, pour ne pas laisser fuiter la couleur sur la suite.
  def self.draw_text_colored(pdf, text, at:, size:, color:, style: nil)
    pdf.fill_color color
    opts = { at: at, size: size }
    opts[:style] = style if style
    pdf.draw_text text, **opts
    pdf.fill_color "000000"
  end

  def self.title_baseline_y(pdf)
    title_ascent = font_metric(pdf, TITLE_SIZE) { pdf.font.ascender }
    pdf.bounds.height - title_ascent
  end

  def self.draw_header_inline(pdf, meta)
    y = title_baseline_y(pdf)
    title_descent = font_metric(pdf, TITLE_SIZE) { pdf.font.descender }

    draw_header_row(pdf, meta, y, title_color: "000000", info_color: "666666")

    y - title_descent
  end

  # Fond plein derrière le titre (aspect v13/14 repris), texte clair dessus — dimensionné
  # pour NE PAS toucher à la marge haute : bandeau à 8px de l'encre RÉELLE du titre (voir
  # `ink_extent`, pas l'ascender/descender approximatifs) des deux côtés, donc réellement
  # centré quel que soit le titre/police/taille — pas une valeur mesurée à la main une
  # fois puis figée (Phil, 2026-08-16). Le TOP du titre (sa position, `y`) ne bouge jamais
  # (= pdf.bounds.height − ascender, identique à :inline).
  # Bandeau CONTENU dans la zone sûre KDP (jamais bord à bord sans bleed — limite établie
  # ce jour avec les essais KDP réels, à respecter partout, pas seulement pour le texte).
  def self.draw_header_band(pdf, meta)
    y = title_baseline_y(pdf)
    ink_top, ink_bottom = ink_extent(pdf, meta["titre"].to_s, TITLE_SIZE, style: :bold)

    band_top = y + ink_top + BAND_GAP
    band_bottom = y - ink_bottom - BAND_GAP
    band_h = band_top - band_bottom

    pdf.fill_color BAND_COLOR
    pdf.fill_rectangle [0, band_top], pdf.bounds.width, band_h
    pdf.fill_color "000000"

    draw_header_row(pdf, meta, y, title_color: "FFFFFF", info_color: "FFFFFF")

    band_bottom
  end

  # Option `cote_a_cote` (frontmatter, défaut true) : ON = pairage 2 par 2 par défaut dans
  # l'ordre d'apparition (comme si `//` était déjà posé entre chaque paire) ; OFF = aucun
  # pairage par défaut, `//` (`paired_with_previous`, posé par le parseur) devient le SEUL
  # moyen de pairer deux blocs. `block_align: center` fait toujours row à part, centrée,
  # dans les deux cas.
  # Cascade de config (carnet / collection / fichier / frontmatter) pas encore implémentée
  # dans ce sandbox — seul le frontmatter est lu pour l'instant.
  def self.build_rows(blocks, cote_a_cote)
    cote_a_cote ? build_rows_positional(blocks) : build_rows_explicit(blocks)
  end

  def self.build_rows_positional(blocks)
    rows = []
    i = 0
    while i < blocks.length
      block = blocks[i]
      if block.directives[:block_align] == "center"
        rows << [block]
        i += 1
      elsif blocks[i + 1] && blocks[i + 1].directives[:block_align] != "center"
        rows << [block, blocks[i + 1]]
        i += 2
      else
        rows << [block]
        i += 1
      end
    end
    rows
  end

  def self.build_rows_explicit(blocks)
    rows = []
    blocks.each do |block|
      prev = rows.last
      if block.directives[:block_align] != "center" &&
         block.paired_with_previous &&
         prev && prev.size == 1 && prev[0].directives[:block_align] != "center"
        prev << block
      else
        rows << [block]
      end
    end
    rows
  end

  # Gouttière HORIZONTALE (gauche/droite, pas de biais optique haut/bas) : l'espace en
  # trop réparti en (n+1) parts égales, avant/entre/après les éléments — jamais une
  # valeur fixe. Avec un seul élément ou un espace nul, la gouttière vaut 0.
  # Bornée par [MIN_H_DIST, MAX_H_DIST] : jamais trop proches (moche), jamais trop
  # écartés non plus (moche aussi) même si beaucoup de place libre — l'excès de place
  # au-delà du plafond n'est PAS redistribué, il reste en marge inutilisée.
  def self.distribute_gutter(avail, sizes, type: :default)
    return 0.0 if sizes.empty?

    slack = [avail - sizes.sum, 0].max
    raw = slack / (sizes.size + 1).to_f
    raw.clamp(min_h_dist(type), max_h_dist(type))
  end

  # Gouttières VERTICALES d'un bloc centré (page, colonne de diags) : mêmes parts pour
  # les gouttières internes, mais la première (haut) et la dernière (bas) sont pondérées
  # (TOP_GUTTER_WEIGHT / BOTTOM_GUTTER_WEIGHT) pour l'équilibre optique. Retourne un
  # tableau de n+1 valeurs (avant le 1er élément, entre chaque paire, après le dernier).
  # Chaque valeur bornée par [min_v_dist(type), max_v_dist(type)] — SAUF la gouttière du
  # haut (indice 0) qui utilise `top_type` (ex. `:band_diag`/`:band_strophe` : distance
  # bandeau-titre → 1er élément, plage INDÉPENDANTE de celle entre deux éléments — Phil,
  # 2026-08-19). `top_type` vaut `type` par défaut (pages sans bandeau au-dessus).
  def self.distribute_v_gutters(avail, sizes, type: :default, top_type: type)
    return [] if sizes.empty?

    slack = [avail - sizes.sum, 0].max
    weights = Array.new(sizes.size + 1, 1.0)
    weights[0] = TOP_GUTTER_WEIGHT
    weights[-1] = BOTTOM_GUTTER_WEIGHT
    types = Array.new(sizes.size + 1, type)
    types[0] = top_type
    unit = slack / weights.sum
    gutters = weights.each_index.map { |i| (weights[i] * unit).clamp(min_v_dist(types[i]), max_v_dist(types[i])) }

    # Remonter une gouttière au plancher (poids < 1, slack serré) ne compense JAMAIS en
    # réduisant les autres tout seul — sans ce rééquilibrage, la somme dépasse parfois
    # `avail` (débordement dans la marge constaté en pratique, 2026-08-17). On réduit les
    # gouttières AU-DESSUS du plancher, proportionnellement à leur marge de manœuvre.
    excess = gutters.sum - slack
    if excess > 0
      above_floor = gutters.each_index.select { |i| gutters[i] > min_v_dist(types[i]) }
      reducible = above_floor.sum { |i| gutters[i] - min_v_dist(types[i]) }
      if reducible > 0
        above_floor.each { |i| gutters[i] -= excess * (gutters[i] - min_v_dist(types[i])) / reducible }
      end
    end

    gutters
  end

  # Une ligne sans accord (aucun segment avec chord) n'a pas de ligne d'accord au-dessus :
  # son texte est sa seule ligne, pas la peine de réserver CHORD_SIZE+LINE_GAP pour rien.
  # `line` peut être nil (bloc sans corps, ex. `{riff intro}` sans ligne dessous, ou
  # `{nom}` répété qui écrase le bloc précédent dans le hash — voir `parse_lyr`).
  def self.line_has_chord?(line)
    line && line.segments.any?(&:chord)
  end

  def self.line_step(line, chord_size: CHORD_SIZE, text_size: TEXT_SIZE)
    line_has_chord?(line) ? chord_size + LINE_GAP + text_size + LINE_GAP : text_size + LINE_GAP
  end

  # Hauteur RÉELLE (visuelle) d'un bloc : hampe du premier élément (accord si la 1re ligne
  # en a un, sinon celle du texte) + l'enchaînement des lignes selon qu'elles ont un accord
  # ou non + descente du dernier texte. Condition pour qu'aucun chevauchement ne soit
  # possible : toute distance donnée à une row (gouttière, marge de page) est mesurée sur
  # CETTE hauteur, jamais sur une approximation en tailles de police fixes.
  def self.block_visual_height(chord_ascent, text_ascent, text_descent, lines, chord_size: CHORD_SIZE, text_size: TEXT_SIZE)
    return 0 if lines.empty?

    baseline = line_has_chord?(lines.first) ? chord_ascent : text_ascent
    last_text_offset = 0
    lines.each_with_index do |line, i|
      last_text_offset = baseline + (line_has_chord?(line) ? chord_size + LINE_GAP : 0)
      baseline += line_step(line, chord_size: chord_size, text_size: text_size) if i < lines.length - 1
    end
    last_text_offset + text_descent
  end

  # Texte TOUJOURS aligné à gauche (sauf demande expresse) : `block_align: center`
  # centre le paragraphe entier dans la page, jamais chaque ligne dans sa colonne.
  # Construit un PageElement par row (couplet seul ou paire côte à côte), prêt à être
  # paginé/équilibré par `paginate_and_draw` aux côtés d'autres éléments (ex. la tabla).
  def self.build_row_elements(pdf, blocks, x0, width, chord_ascent, text_ascent, text_descent, cote_a_cote)
    rows = build_rows(blocks, cote_a_cote)
    col1_w, col2_w, h_gutter = row_column_widths(pdf, rows, width)

    rows.flat_map { |row| build_row_or_split(pdf, row, x0, width, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent) }
  end

  # Largeurs de colonnes calculées globalement (une seule fois) pour que tous les
  # couplets s'alignent entre eux, plutôt que chaque paire ne s'ajuste à son propre contenu.
  def self.row_column_widths(pdf, rows, width)
    col1_w = rows.filter_map { |r| block_width(pdf, r[0]) if r.size == 2 }.max || 0
    col2_w = rows.filter_map { |r| block_width(pdf, r[1]) if r.size == 2 }.max || 0
    [col1_w, col2_w, distribute_gutter(width, [col1_w, col2_w])]
  end

  # Row côte à côte trop large pour tenir dans `width` (remarques.txt Carnet-1,
  # 2026-08-18) : 1) rétrécit le texte (et les accords, même proportion) jusqu'à
  # `MIN_TEXT_SIZE` si ça suffit à faire tenir la row ; 2) sinon abandonne le côte à
  # côte, empile les deux blocs (une row par bloc, taille normale). Renvoie TOUJOURS un
  # tableau (1 ou 2 éléments) — `flat_map` côté appelant.
  # Détection sur la géométrie RÉELLEMENT dessinée : `col2` démarre à `col1_w` (largeur
  # GLOBALE, alignée sur tous les couplets), pas la largeur propre du bloc 1 de CETTE
  # row — un bloc 1 étroit sur une row donnée n'empêche pas un débordement si `col1_w`
  # global est large (bug trouvé, 2026-08-18 : la vérification comparait par erreur la
  # somme des largeurs PROPRES des 2 blocs, jamais la position réelle de col2).
  def self.build_row_or_split(pdf, row, x0, width, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent)
    return [row_to_element(pdf, row, x0, width, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent)] unless row.size == 2

    avail = width - h_gutter * 3
    fits_aligned = col1_w + block_width(pdf, row[1]) <= avail
    return [row_to_element(pdf, row, x0, width, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent)] if fits_aligned

    # Abandon de l'alignement global pour CETTE row : rétrécie sur sa propre largeur
    # naturelle (col1_w global ne s'applique plus dès qu'on rétrécit ou empile).
    natural_w = block_width(pdf, row[0]) + block_width(pdf, row[1])
    scale = avail / natural_w.to_f
    text_size = (TEXT_SIZE * scale).floor
    return [shrunk_row_element(pdf, row, x0, h_gutter, text_size)] if text_size >= MIN_TEXT_SIZE

    row.map { |block| row_to_element(pdf, [block], x0, width, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent) }
  end

  def self.shrunk_row_element(pdf, row, x0, h_gutter, text_size)
    chord_size = [(CHORD_SIZE * text_size / TEXT_SIZE.to_f).floor, 1].max
    chord_ascent = font_metric(pdf, chord_size) { pdf.font.ascender }
    text_ascent = font_metric(pdf, text_size) { pdf.font.ascender }
    text_descent = font_metric(pdf, text_size) { pdf.font.descender }
    col1_w = block_width(pdf, row[0], text_size: text_size)

    height = row.map { |b| block_visual_height(chord_ascent, text_ascent, text_descent, b.lines, chord_size: chord_size, text_size: text_size) }.max
    draw = lambda do |pdf_, y|
      draw_block(pdf_, row[0], x0 + h_gutter, y, chord_ascent, text_ascent, chord_size: chord_size, text_size: text_size)
      draw_block(pdf_, row[1], x0 + h_gutter + col1_w + h_gutter, y, chord_ascent, text_ascent, chord_size: chord_size, text_size: text_size)
    end
    PageElement.new(height, draw)
  end

  def self.row_to_element(pdf, row, x0, width, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent)
    height = row.map { |b| block_visual_height(chord_ascent, text_ascent, text_descent, b.lines) }.max
    draw = lambda do |pdf_, y|
      if row.size == 2
        block, nxt = row
        draw_block(pdf_, block, x0 + h_gutter, y, chord_ascent, text_ascent)
        draw_block(pdf_, nxt, x0 + h_gutter + col1_w + h_gutter, y, chord_ascent, text_ascent)
      else
        block = row[0]
        centered = block.directives[:block_align] != "left"
        bx = if centered
               x0 + [(width - block_width(pdf_, block)) / 2.0, 0].max
             else
               x0 + h_gutter # même retrait que la colonne 1, pour rester aligné avec elle
             end
        draw_block(pdf_, block, bx, y, chord_ascent, text_ascent)
      end
    end
    PageElement.new(height, draw)
  end

  # Pagination générique : chaque page reçoit autant d'éléments (rows de couplets, tabla...)
  # que sa hauteur disponible permet, puis le reste (air en haut/bas + gouttière entre
  # éléments) est réparti sur CE QUI TIENT RÉELLEMENT sur la page — jamais sur le total.
  # RÈGLE ABSOLUE : un élément ne passe à la page suivante que s'il ne rentre vraiment pas,
  # jamais sans raison de place (Phil, 2026-08-16).
  # Groupement en pages SEUL (ni dessin, ni dépendance à `pdf` au-delà de sa hauteur de
  # page) — réutilisé par `paginate_and_draw` et par la simulation de `shrink` (voir
  # `render_gab`) pour savoir, SANS dessiner, où un élément atterrirait et combien
  # d'espace lui reste sur sa page.
  # pinned : indices d'éléments qui ne doivent JAMAIS être repoussés à la page suivante
  # (ex. une tabla en `shrink` : sa page est fixée par sa position dans le .gab, jamais
  # déplacée — voir `render_gab`).
  def self.paginate(elements, first_avail_h, page_height, pinned: [], type: :default)
    heights = elements.map(&:height)
    avail_h = first_avail_h
    idx = 0
    pages = []
    while idx < elements.length
      start = idx
      page_sum = 0
      # La place réservée pour MIN_V_DIST est comptée PENDANT l'accumulation (pas après
      # coup) : sinon, si le dernier élément inclus est épinglé (pinned), impossible de le
      # repousser pour faire de la place au plancher — la marge basse se retrouvait nulle.
      while idx < elements.length && page_sum + heights[idx] + min_v_dist(type) * (idx - start + 2) <= avail_h
        page_sum += heights[idx]
        idx += 1
      end
      idx += 1 if idx == start # un seul élément déborde déjà la page : le poser quand même

      # Anti-page-clairsemée : repousser le dernier élément à la page suivante tant que
      # ce qui resterait sur CETTE page-ci en aurait encore plus d'un ET que la suite
      # (elle-même) ne remplirait qu'une fraction dérisoire de la prochaine page. Jamais
      # un élément épinglé (pinned). `idx - start > 2` (pas `> 1`) : ne descend jamais à
      # une page d'un seul élément par ce mécanisme — bug trouvé (remarques.txt Carnet-1,
      # 2026-08-18) où 2 couplets pleins étaient repoussés à 1 seul pour "corriger" une
      # page suivante elle-même peu remplie, résultat pire que le problème visé.
      while type != :diags && idx - start > 2 && idx < elements.length && !pinned.include?(idx - 1) &&
            heights[idx...elements.length].sum < REBALANCE_MIN_FILL * page_height
        idx -= 1
        page_sum -= heights[idx]
      end

      pages << { start: start, finish: idx, avail_h: avail_h }
      avail_h = page_height
    end

    # RAD5 : un diag seul ne doit jamais rester seul sur une page — le ramener sur la
    # page précédente SEULEMENT s'il y tient réellement (sinon on ferait pire : ça
    # déborderait la zone sûre, RAO3). Bug trouvé (2026-08-19) : la 1re version fusionnait
    # sans vérifier la place, provoquant justement ce débordement. Cas "ça ne tient pas" :
    # RAD6 (regroupement en excès), pas encore implémenté — le diag reste seul pour l'instant.
    if type == :diags && pages.size > 1 && pages.last[:finish] - pages.last[:start] == 1
      prev = pages[-2]
      prev_count = prev[:finish] - prev[:start]
      prev_sum = heights[prev[:start]...prev[:finish]].sum
      extra_h = heights[pages.last[:start]]
      fits = prev_sum + extra_h + min_v_dist(type) * (prev_count + 3) <= prev[:avail_h]
      if fits
        last = pages.pop
        pages.last[:finish] = last[:finish]
      end
    end

    pages
  end

  # `side_col` (Hash x:/width:/paths:/heights:, ou nil) : colonne de diags left/right (voir
  # `layout_diags`), paginée EN PARALLÈLE du texte — mêmes numéros de page, mais chaque
  # colonne avance à son propre rythme (une page peut avoir du texte sans diag ou l'inverse,
  # "colonne vide mais réservée" reste la règle).
  # RAD6 : la colonne de diags n'a JAMAIS le droit de forcer des pages au-delà de celles du
  # texte (bug AIGLE, 2026-08-19 — 2 pages entières sans une seule parole, rien que des
  # diags). Elle est bornée au nombre de pages du texte ; les diags en trop ("excès") sont
  # regroupés horizontalement, plusieurs par ligne, sur une ou des pages dédiées après la
  # chanson (`draw_diags_grid`) — seulement si RAD5 (jamais un diag seul) ne suffit plus.
  def self.paginate_and_draw(pdf, elements, first_avail_h, kdp:, page_w_pt:, page_h_pt:, first_page_no: 1, pinned: [], side_col: nil)
    heights = elements.map(&:height)
    pages = paginate(elements, first_avail_h, pdf.bounds.height, pinned: pinned)

    side_elements = []
    side_pages = []
    excess_paths = []
    excess_heights = []
    if side_col
      side_elements = side_col[:paths].each_with_index.map do |path, i|
        h = side_col[:heights][i]
        x = side_col[:x]
        w = side_col[:width]
        PageElement.new(h, lambda { |pdf_, y| pdf_.svg(IO.read(path), at: [x, y], width: w, position: :left, enable_web_requests: false) })
      end
      side_pages_all = paginate(side_elements, first_avail_h, pdf.bounds.height, type: :diags)
      if side_pages_all.size > pages.size
        side_pages = side_pages_all.first(pages.size)
        excess_start = side_pages.empty? ? 0 : side_pages.last[:finish]
        excess_paths = side_col[:paths][excess_start..] || []
        excess_heights = side_col[:heights][excess_start..] || []
      else
        side_pages = side_pages_all
      end
    end

    page_count = [pages.size, side_pages.size, 1].max
    page_count.times do |i|
      page_no = first_page_no + i
      self.current_page = page_no
      if i.positive?
        pdf.start_new_page
        apply_kdp_margins(pdf, kdp, page_no, page_w_pt, page_h_pt)
      end
      draw_page_number(pdf, kdp, page_no, page_w_pt)

      page = pages[i]
      if page
        page_els = elements[page[:start]...page[:finish]]
        page_heights = heights[page[:start]...page[:finish]]
        gutters = distribute_v_gutters(page[:avail_h], page_heights, top_type: i.zero? ? :band_strophe : :default)

        y = page[:avail_h] - gutters[0]
        page_els.each_with_index do |el, j|
          el.draw.call(pdf, y)
          y -= page_heights[j] + gutters[j + 1]
        end
        conflict!("contenu dépasse la zone sûre de #{-y.round(2)}pt", solution: "dessiné quand même, hors zone sûre") if y < -0.01
      end

      side_page = side_pages[i]
      next unless side_page

      side_page_els = side_elements[side_page[:start]...side_page[:finish]]
      side_page_heights = side_page_els.map(&:height)
      side_gutters = distribute_v_gutters(side_page[:avail_h], side_page_heights, type: :diags, top_type: i.zero? ? :band_diag : :diags)

      y = side_page[:avail_h] - side_gutters[0]
      side_page_els.each_with_index do |el, j|
        el.draw.call(pdf, y)
        y -= side_page_heights[j] + side_gutters[j + 1]
      end
      if y < -0.01
        conflict!("diagrammes dépassent la zone sûre de #{-y.round(2)}pt", solution: "dessinés quand même, hors zone sûre")
      end
    end

    return if excess_paths.empty?

    draw_diags_grid(pdf, excess_paths, excess_heights, kdp: kdp, page_w_pt: page_w_pt, page_h_pt: page_h_pt,
      first_page_no: first_page_no + page_count)
  end

  # RAD6 : diags en excès — regroupés horizontalement, plusieurs par ligne, sur une ou
  # plusieurs pages dédiées après la chanson (dernier recours, RAD5 ne suffit plus).
  def self.draw_diags_grid(pdf, paths, heights, kdp:, page_w_pt:, page_h_pt:, first_page_no:)
    diag_h = heights.max
    gap_h = min_h_dist(:diags)
    gap_v = min_v_dist(:diags)
    cols = [((pdf.bounds.width + gap_h) / (DIAG_W + gap_h)).floor, 1].max
    rows_per_page = [((pdf.bounds.height + gap_v) / (diag_h + gap_v)).floor, 1].max
    per_page = cols * rows_per_page
    row_w = cols * DIAG_W + (cols - 1) * gap_h
    x0 = [(pdf.bounds.width - row_w) / 2.0, 0].max

    paths.each_slice(per_page).with_index do |slice, gi|
      pdf.start_new_page
      page_no = first_page_no + gi
      self.current_page = page_no
      apply_kdp_margins(pdf, kdp, page_no, page_w_pt, page_h_pt)
      draw_page_number(pdf, kdp, page_no, page_w_pt)

      slice.each_slice(cols).with_index do |row, ri|
        y = pdf.bounds.height - gap_v - ri * (diag_h + gap_v)
        row.each_with_index do |path, ci|
          x = x0 + ci * (DIAG_W + gap_h)
          pdf.svg(IO.read(path), at: [x, y], width: DIAG_W, position: :left, enable_web_requests: false)
        end
      end
    end
  end

  # Dessine le bloc : y0 = haut visuel réel (sommet de la hampe du 1er élément).
  def self.draw_block(pdf, block, x, y0, chord_ascent, text_ascent, chord_size: CHORD_SIZE, text_size: TEXT_SIZE)
    y = y0 - (line_has_chord?(block.lines.first) ? chord_ascent : text_ascent)
    block.lines.each do |line|
      draw_line(pdf, line, x, y, chord_size: chord_size, text_size: text_size)
      y -= line_step(line, chord_size: chord_size, text_size: text_size)
    end
  end

  # "d"/"b" en 2e position d'un nom d'accord = dièse/bémol (convention interne, cf. noms
  # de fichiers de diags) → symbole réel ♯/♭ à l'affichage, jamais la lettre brute.
  def self.display_chord(chord)
    chord.split("/").map do |part|
      case part[1]
      when "d" then part[0] + "♯" + part[2..]
      when "b" then part[0] + "♭" + part[2..]
      else part
      end
    end.join("/")
  end

  # Racine (1ère lettre + éventuel ♯/♭) affichée pleine taille, tout le reste de l'accord
  # (qualité : "m", "7", "7M", "sus4", "dim"...) plus petit — généralisé (Phil, 2026-08-19)
  # à partir du cas "sus" seul (Phil, 2026-08-18). Accord avec basse (slash, ex. "D/F♯") :
  # pas encore désambiguïsé, affiché en un seul bloc pleine taille pour l'instant.
  def self.chord_label_parts(chord)
    text = display_chord(chord)
    return [text, ""] if text.include?("/")

    root_end = text[1] == "♯" || text[1] == "♭" ? 2 : 1
    [text[0...root_end], text[root_end..] || ""]
  end

  def self.chord_label_width(pdf, chord, size)
    main, suffix = chord_label_parts(chord)
    w = pdf.width_of(main, size: size, style: :bold)
    w += pdf.width_of(suffix, size: size - 2, style: :bold) unless suffix.empty?
    w
  end

  def self.draw_chord_label(pdf, chord, x, y, size: CHORD_SIZE)
    main, suffix = chord_label_parts(chord)
    pdf.draw_text main, at: [x, y], size: size, style: :bold
    return if suffix.empty?

    pdf.draw_text suffix, at: [x + pdf.width_of(main, size: size, style: :bold), y], size: size - 2, style: :bold
  end

  # L'avancée horizontale ne doit JAMAIS être inférieure à la largeur du label d'accord
  # tout juste dessiné (RAA1 : deux accords ne doivent jamais se superposer) — une "avancée
  # à texte vide" fixe (ex. 3 espaces) s'est avérée insuffisante en pratique (mesuré :
  # espaces 9.17pt < largeur label "C9" 11.67pt, chevauchement constaté malgré le fix —
  # AYNL puis À bicyclette, 2026-08-19). On avance donc du MAX(largeur du texte, largeur
  # du label d'accord) : garantie mathématique, jamais un réglage à ajuster à la main.
  def self.draw_line(pdf, line, x, y, chord_size: CHORD_SIZE, text_size: TEXT_SIZE)
    has_chord = line_has_chord?(line)
    cx = x
    line.segments.each do |seg|
      draw_chord_label(pdf, seg.chord, cx, y, size: chord_size) if seg.chord
      text_y = has_chord ? y - chord_size - LINE_GAP : y
      pdf.draw_text seg.text, at: [cx, text_y], size: text_size
      text_w = pdf.width_of(seg.text, size: text_size)
      chord_w = seg.chord ? chord_label_width(pdf, seg.chord, chord_size) : 0
      cx += [text_w, chord_w].max
    end
  end

  def self.draw_diags(pdf, diag_paths, heights, x:, avail_h:, width:)
    gutters = distribute_v_gutters(avail_h, heights, type: :diags, top_type: :band_diag)
    y = avail_h - gutters[0]
    diag_paths.each_with_index do |path, i|
      svg_data = IO.read(path)
      pdf.svg(svg_data, at: [x, y], width: width, position: :left, enable_web_requests: false)
      y -= heights[i] + gutters[i + 1]
    end
    # Garde-fou (règle absolue, 2026-08-17) : rien ne doit jamais empiéter sur la marge.
    if y < -0.01
      conflict!("diagrammes dépassent la zone sûre de #{-y.round(2)}pt (avail_h=#{avail_h})", solution: "dessinés quand même, hors zone sûre")
    end
  end

  # Largeur de CHAQUE diagramme si on les pose tous en rangée horizontale (Top/Bot),
  # réduite uniformément si la rangée entière ne tient pas dans `avail_w`. Réserve les
  # gouttières minimales AVANT de calculer le facteur de réduction.
  def self.fit_diag_row_width(count, natural_w, avail_w)
    return natural_w if count.zero? || avail_w <= 0

    reserved = min_h_dist(:diags) * (count + 1)
    budget_w = [avail_w - reserved, 0].max
    natural_total = natural_w * count
    natural_total > budget_w ? natural_w * (budget_w / natural_total) : natural_w
  end

  # [largeur, hauteur] d'un diagramme pour que la rangée entière (tous les diagrammes,
  # gouttières comprises) tienne dans `avail_w` — mesure seule, ne dessine rien.
  def self.diags_row_fit(diag_paths, avail_w)
    return [0, 0] if diag_paths.empty?

    w = fit_diag_row_width(diag_paths.size, DIAG_W, avail_w)
    h = diag_paths.map { |p| svg_height_for(File.read(p), w) }.max
    [w, h]
  end

  def self.draw_diags_row(pdf, diag_paths, x0, y_top, avail_w, w)
    return if diag_paths.empty?

    gutter = distribute_gutter(avail_w, Array.new(diag_paths.size, w), type: :diags)
    x = x0 + gutter
    diag_paths.each do |path|
      pdf.svg(IO.read(path), at: [x, y_top], width: w, position: :left, enable_web_requests: false)
      x += w + gutter
    end
  end

  # Place les diags selon leur position (left/right/top/bottom — les 4 indépendantes de
  # la parité recto/verso, Ext/Int/OP pas encore implémentées) et renvoie [text_x, text_w,
  # first_avail_h, side_col] pour le reste de la mise en page.
  # Left/Right : colonne verticale — PAS dessinée ici. `side_col` (Hash x:/width:/paths:/
  # heights:, ou nil) est repris par `paginate_and_draw`, qui la pagine EN PARALLÈLE du
  # texte, comme n'importe quel autre contenu — un diag qui ne tient pas sur la page 1
  # continue sur la page suivante (bug AIGLE corrigé, 2026-08-19 : avant, tout était forcé
  # sur la page 1, débordait silencieusement sur la marge basse au-delà d'un simple log).
  # Top/Bot : rangée horizontale pleine largeur, dessinée ici, toujours page 1 seulement
  # (pas concerné par ce bug — pas retouché). Top réduit l'espace disponible par le HAUT
  # (le contenu commence plus bas), Bot le réduit par le BAS de la page 1 SEULEMENT.
  # RAD3 : si une pleine page de diags (hauteur `page_height`) ne peut en accueillir qu'un
  # de plus en réduisant la largeur — jamais sous `MIN_SIZE[:diags][:width]` — on prend le
  # plus PETIT écart qui gagne CETTE unique place (pas une réduction plus grande que
  # nécessaire : à 0.37% près, un diag de plus peut tenir — Phil, 2026-08-19). Mesuré sur
  # une pleine page (`page_height`/`page_height`), pas la 1re page (bandeau) : capacité
  # "normale" d'une page, celle que Phil compare page à page.
  def self.diag_column_width(paths, first_avail_h, page_height)
    return DIAG_W if paths.empty?

    capacity_at = lambda do |w|
      height = svg_height_for(File.read(paths.first), w)
      elements = Array.new(paths.size) { PageElement.new(height, nil) }
      page = paginate(elements, page_height, page_height, type: :diags).first
      page[:finish] - page[:start]
    end

    baseline = capacity_at.call(DIAG_W)
    floor_w = MIN_SIZE[:diags][:width]
    w = DIAG_W
    while w > floor_w
      w = [w - 0.1, floor_w].max
      return w if capacity_at.call(w) > baseline
    end
    DIAG_W
  end

  def self.layout_diags(pdf, diag_paths, position, header_bottom)
    case position
    when :right
      diag_w = diag_column_width(diag_paths, header_bottom, pdf.bounds.height)
      diag_heights = diag_paths.map { |p| svg_height_for(File.read(p), diag_w) }
      diag_col_w = diag_w + DIAG_TEXT_GAP
      side_col = { x: pdf.bounds.width - diag_w, width: diag_w, paths: diag_paths, heights: diag_heights }
      [0, pdf.bounds.width - diag_col_w, header_bottom, side_col]
    when :top
      w, h = diags_row_fit(diag_paths, pdf.bounds.width)
      row_h = diag_paths.empty? ? 0 : h + DIAG_TEXT_GAP
      draw_diags_row(pdf, diag_paths, 0, header_bottom, pdf.bounds.width, w)
      [0, pdf.bounds.width, header_bottom - row_h, nil]
    when :bottom
      w, h = diags_row_fit(diag_paths, pdf.bounds.width)
      row_h = diag_paths.empty? ? 0 : h + DIAG_TEXT_GAP
      draw_diags_row(pdf, diag_paths, 0, row_h, pdf.bounds.width, w)
      [0, pdf.bounds.width, header_bottom - row_h, nil]
    else # :left, défaut
      diag_w = diag_column_width(diag_paths, header_bottom, pdf.bounds.height)
      diag_heights = diag_paths.map { |p| svg_height_for(File.read(p), diag_w) }
      diag_col_w = diag_w + DIAG_TEXT_GAP
      side_col = { x: 0, width: diag_w, paths: diag_paths, heights: diag_heights }
      [diag_col_w, pdf.bounds.width - diag_col_w, header_bottom, side_col]
    end
  end

  # `fret` (case) explicite dans la source (ex. "/Bb-6:") → diagramme à CETTE case
  # exactement. Sans lui → case la plus basse disponible ("le plus en haut du manche",
  # Phil, 2026-08-18 — plusieurs cases existeront à terme pour un même accord). Accord ou
  # case introuvable : signalé via `conflict!` (l'user peut se tromper d'accord), jamais
  # une erreur silencieuse ni un crash.
  def self.diag_path(chord, fret: nil)
    letter = chord[0].upcase
    dir = File.join(ASSETS, letter)
    unless Dir.exist?(dir)
      conflict!("accord inconnu: #{chord}#{fret ? "-#{fret}" : ""}", solution: "diagramme omis")
      return nil
    end

    entries = Dir.glob(File.join(dir, "#{Regexp.escape(chord)}-*.svg")).filter_map do |f|
      m = File.basename(f).match(/\A#{Regexp.escape(chord)}-(\d+)\.svg\z/)
      [f, m[1].to_i] if m
    end
    entries.select! { |_, kase| kase == fret.to_i } if fret

    if entries.empty?
      conflict!("accord inconnu ou case absente: #{chord}#{fret ? "-#{fret}" : ""}", solution: "diagramme omis")
      return nil
    end

    target_case = fret ? fret.to_i : entries.map { |_, kase| kase }.min
    entries.find { |_, kase| kase == target_case }.first
  end

  def self.svg_viewbox(svg_data)
    m = svg_data.match(/viewBox="[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)"/)
    [m[1].to_f, m[2].to_f]
  end

  def self.svg_height_for(svg_data, target_w)
    w, h = svg_viewbox(svg_data)
    target_w * (h / w)
  end
end
