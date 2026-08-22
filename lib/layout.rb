require "prawn"
require "prawn-svg"
require_relative "app_options"

# Moteur de mise en page : primitives de dessin (police, en-tête, couplets/accords,
# diagrammes, tabla) et pagination générique — indépendant du format source d'une
# chanson (`.lyr`/`.gab`/`.infos` vs `.dsl`, voir `PageBuilder`) et de la résolution des
# diagrammes d'accords (voir `ChordDiagrams`). Porte aussi le système de conflits
# (`conflict!`), utilisé par les deux.
module Layout
  # Garde-fou GÉNÉRAL (règle absolue, 2026-08-17) : tout conflit qui relève d'un choix de
  # l'utilisateur (contenu trop long, élément qui empiète sur la marge ou sur un autre
  # élément, etc — PAS limité aux marges) passe par `conflict!`. Niveau de SENSIBILITÉ :
  #   1 = stoppe la construction (erreur bloquante — l'erreur doit être corrigée).
  #   2 = demande à l'utilisateur quoi faire (continuer ou stopper).
  #   3 = mémorise le conflit, continue, rapporte tout à la fin (`report_conflicts!`).
  #   4 = (DÉFAUT) continue silencieusement, log cachée seulement, rien dit à l'utilisateur.
  SENSITIVITY = 4
  # Chemin par défaut (essais isolés) — un script de production (ex.
  # `CarnetBuilder.build`) le redirige vers SON propre fichier `<production>-conflicts.log`,
  # à côté du PDF produit (remarques.txt Carnet-1, 2026-08-18 : un log par production, pas
  # un fichier global partagé).
  @conflict_log_path = File.expand_path("../_dev/conflicts.log", __dir__)
  # Trace des décisions de construction (Phil, 2026-08-20) — PAS le log de conflits :
  # aucun problème ici, juste ce que l'algo a choisi et pourquoi, pour comprendre son
  # comportement sans avoir à relire le code. Même redirection par production que
  # `conflict_log_path` (voir `CarnetBuilder.build`).
  @building_log_path = File.expand_path("../_dev/building.log", __dir__)
  # EXPÉRIMENTAL (Phil, 2026-08-21) : espacement des caractères du texte des paroles,
  # `pdf.character_spacing` — pour chercher jusqu'où RAL2.1 (réduction d'espace avant
  # d'abandonner au raccourcissement RAL2.2) peut aller. 0 = comportement normal, jamais
  # touché par défaut. PAS encore une règle appliquée automatiquement.
  @char_spacing = 0.0
  # EXPÉRIMENTAL (Phil, 2026-08-21) : espacement des ESPACES seulement (entre les mots),
  # jamais les lettres à l'intérieur d'un mot — RAL2.1 : "réduire l'espace entre les mots".
  # Prawn n'expose pas Tw (word spacing PDF natif) publiquement, donc chaque mot est
  # dessiné séparément avec un espace ajusté (voir `draw_words_with_spacing`).
  @word_spacing = 0.0
  class << self
    attr_accessor :conflict_log_path, :building_log_path, :current_song, :current_page, :char_spacing, :word_spacing
  end
  CONFLICTS = []
  @missing_chords = Hash.new { |h, k| h[k] = [] }

  def self.log_build(message)
    line = "#{current_song || "?"} p.#{current_page || "?"} : #{message}"
    File.open(building_log_path, "a") { |f| f.puts line }
  end

  # Accord introuvable (`ChordDiagrams.diag_path`) — consigné à part du log de conflits
  # ligne par ligne, pour un récapitulatif dédupliqué en fin de production (Phil,
  # 2026-08-20) : `accord (chanson 1, chanson 2, ...)`.
  def self.track_missing_chord(chord)
    song = current_song || "?"
    @missing_chords[chord] << song unless @missing_chords[chord].include?(song)
  end

  # "ACCORDS MANQUANTS : Am9 (À bicyclette), G7M (À bicyclette, Belle île en mer)" — ou
  # `nil` si aucun accord manquant sur toute la production.
  def self.missing_chords_summary
    return nil if @missing_chords.empty?

    "ACCORDS MANQUANTS : #{@missing_chords.map { |chord, songs| "#{chord} (#{songs.join(', ')})" }.join(', ')}"
  end

  # Point de passage OBLIGATOIRE avant toute gravure dans le PDF (Phil, 2026-08-20) :
  # AUCUN autre endroit du code n'appelle `pdf.svg`/`draw_text`/`text_box`/`fill_rectangle`
  # directement — tout passe par ici. Vérifie AVANT de graver que l'élément rentre dans le
  # cadre (jamais après-coup, contrairement à l'ancien système) : `bottom` = le point le
  # plus bas (coordonnées `pdf.bounds`, 0 = bord bas de la zone de contenu) que l'élément
  # atteindra une fois dessiné — calculé par l'appelant, seul à connaître la convention
  # d'ancrage (haut/bas/ligne de base) de ce qu'il dessine. Hors cadre -> signalé, RIEN
  # gravé, renvoie `false` (l'appelant peut alors reconstruire/rétrécir et retenter) ;
  # dans le cadre -> le bloc s'exécute, renvoie `true`.
  # Exception documentée : `draw_page_number` dessine via `pdf.canvas` (page ENTIÈRE),
  # hors du système de coordonnées `pdf.bounds` — donc hors périmètre de ce garde-fou par
  # nature. Sa position reste néanmoins DANS la zone sûre KDP (recalculée depuis
  # `kdp.bottom_margin`), pas dans la marge — corrigé 2026-08-22 après rejet KDP réel.
  def self.engrave(bottom:, context: nil)
    if bottom < -0.01
      conflict!("gravure refusée#{context ? " (#{context})" : ""} — déborderait de #{-bottom.round(2)}pt", solution: "rien dessiné")
      return false
    end
    yield
    true
  end

  # Format de ligne imposé (remarques-v4.txt Carnet-1, point 1) : ni horodatage par ligne
  # (un seul temps début/fin pour tout le run, écrit par le script de production autour de
  # l'appel), ni juste le problème — chanson, page, problème ET solution adoptée.
  # `current_song`/`current_page` : contexte fixé par l'appelant (`PageBuilder.build`,
  # `paginate_and_draw`) — "?" si inconnu à ce stade (ex. accord vérifié avant la mise en
  # page, page pas encore déterminée).
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
  # RAA1 (Manuel/regles_esthetiques.adoc) : deux accords ne doivent JAMAIS être en
  # contact — un pas d'avancée strictement égal à la largeur du label précédent les
  # laissait TOUCHER (constaté sur l'intro d'À bicyclette, accords collés sans séparation
  # quand le texte entre eux est vide/un simple séparateur "/", Phil 2026-08-20). Valeur
  # provisoire, jamais validée par Phil.
  CHORD_GAP = 2.0
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

  GEORGIA_DIR = File.expand_path("../assets/fonts/Georgia", __dir__)
  HELVETICA_NEUE_DIR = File.expand_path("../assets/fonts/HelveticaNeue", __dir__)
  FONTS_DIR = File.expand_path("../assets/fonts", __dir__)
  # Taille de départ, standard éditorial courant pour un numéro de page — à ajuster
  # visuellement sur le livre-test (Phil, 2026-08-17).
  PAGE_NUMBER_SIZE = 10
  # Air entre le numéro et la limite haute de la marge basse (le numéro reste DANS la
  # zone sûre KDP, pas dans la marge — un essai KDP réel, 2026-08-22, a rejeté un numéro
  # posé dans la marge malgré la décision précédente de l'y mettre volontairement ; le
  # vérificateur KDP ne fait aucune exception pour un numéro de page).
  PAGE_NUMBER_TOP_INSET_PT = 2

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
  # livre), DANS la zone sûre KDP (jamais dans la marge — un essai KDP réel a rejeté la
  # version précédente qui le posait volontairement dans la marge basse, 2026-08-22).
  # `pdf.canvas` bascule sur la page ENTIÈRE (pas `pdf.bounds`), donc `y` est recalculé
  # ici depuis `kdp.bottom_margin` plutôt que d'hériter de `apply_kdp_margins`.
  def self.draw_page_number(pdf, kdp, page_no, page_w_pt)
    pdf.font_families.update("Georgia" => {
      normal: File.join(GEORGIA_DIR, "Georgia-Regular.ttf"),
      bold: File.join(GEORGIA_DIR, "Georgia-Bold.ttf"),
      italic: File.join(GEORGIA_DIR, "Georgia-Italic.ttf"),
      bold_italic: File.join(GEORGIA_DIR, "Georgia-BoldItalic.ttf"),
    })
    recto = kdp.recto?(page_no)
    y = in_pt(kdp.bottom_margin) + PAGE_NUMBER_TOP_INSET_PT
    pdf.canvas do
      pdf.font("Georgia") do
        text_w = pdf.width_of(page_no.to_s, size: PAGE_NUMBER_SIZE, style: :bold)
        x = recto ? page_w_pt - in_pt(kdp.right_margin(page_no)) - text_w : in_pt(kdp.left_margin(page_no))
        pdf.draw_text page_no.to_s, at: [x, y], size: PAGE_NUMBER_SIZE, style: :bold
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

    text_font_name = AppOptions.get("text_font")
    pdf.font_families.update(text_font_name => resolve_font_files(text_font_name))

    pdf.font "HelveticaNeue"
  end

  # `text_font` (options.yaml) est, par convention, le nom du DOSSIER sous
  # `assets/fonts/` — jamais un nom de fichier en dur (Phil, 2026-08-20 : la convention de
  # nommage des .ttf varie d'une police à l'autre, ex. Cormorant_Garamond utilise
  # "-Regular"/"-Bold", Garamond utilise "Book"/pas de suffixe). Résolution par motif
  # (gras/italique dans le nom de fichier) plutôt qu'un nom de fichier attendu.
  def self.resolve_font_files(font_name)
    files = Dir.glob(File.join(FONTS_DIR, font_name, "*.ttf"))
    raise "aucune police .ttf dans assets/fonts/#{font_name}/" if files.empty?

    bold_italic = files.find { |f| File.basename(f) =~ /bold.*italic|italic.*bold/i }
    bold = files.find { |f| File.basename(f) =~ /bold/i && f != bold_italic }
    italic = files.find { |f| File.basename(f) =~ /italic/i && f != bold_italic }
    claimed = [bold, italic, bold_italic].compact
    regular = files.find { |f| !claimed.include?(f) && File.basename(f) =~ /regular|book|roman/i } || (files - claimed).first || files.first

    { normal: regular, bold: bold || regular, italic: italic || regular, bold_italic: bold_italic || bold || italic || regular }
  end

  # "(interprète, année)" — entre parenthèses, jamais de label (Phil, 2026-08-16).
  def self.format_interprete(meta)
    parts = [meta["performer"], meta["year"]].compact
    parts.empty? ? "" : "(#{parts.join(', ')})"
  end

  # Titre à gauche ; interprète/date juste à droite du titre (plus petit que le titre,
  # mais plus gros que parolier/compositeur) ; parolier/compositeur fer à droite (le plus
  # petit des trois) — les trois SUR LA MÊME LIGNE DE BASE que le titre, `y` (Phil,
  # 2026-08-16). Identique pour :inline et :band — le bandeau ne doit RIEN changer à la
  # position du titre, seulement ajouter un fond derrière.
  def self.draw_header_row(pdf, meta, y, title_color:, info_color:)
    title = meta["title"].to_s
    draw_text_colored(pdf, title, at: [HEADER_PAD_X, y], size: TITLE_SIZE, style: :bold, color: title_color)
    title_w = pdf.width_of(title, size: TITLE_SIZE, style: :bold)
    left_edge = HEADER_PAD_X + title_w

    interprete = format_interprete(meta)
    unless interprete.empty?
      draw_text_colored(pdf, interprete, at: [HEADER_PAD_X + title_w + INFO_GAP, y], size: INTERPRETE_SIZE, color: info_color)
      left_edge += INFO_GAP + pdf.width_of(interprete, size: INTERPRETE_SIZE)
    end

    # RAT1 (Manuel/regles_esthetiques.adoc) : même personne aux deux -> le nom une seule
    # fois, jamais "X / X".
    if meta["lyrics"] && meta["lyrics"] == meta["composer"]
      log_build("parolier=compositeur (\"#{meta["lyrics"]}\") : nom affiché une seule fois (RAT1)")
    end
    pc = [meta["lyrics"], meta["composer"]].compact.uniq.join(" / ")
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
    _, y = at
    descent = font_metric(pdf, size) { pdf.font.descender }
    engrave(bottom: y - descent, context: "texte \"#{text[0, 20]}\"") do
      pdf.fill_color color
      opts = { at: at, size: size }
      opts[:style] = style if style
      pdf.draw_text text, **opts
      pdf.fill_color "000000"
    end
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
  # Bandeau CONTENU dans la zone sûre KDP : `band_top` plafonné à `pdf.bounds.height` —
  # sans ce plafond, `y + ink_top + BAND_GAP` dépasse systématiquement `bounds.height` dès
  # que l'encre réelle du titre (majuscules accentuées notamment) approche l'ascender
  # nominal, plus BAND_GAP en trop (bug réel constaté à l'upload KDP, ~2pt, 2026-08-22 —
  # le commentaire précédent affirmait le bandeau "contenu" sans que le calcul le
  # garantisse réellement).
  def self.draw_header_band(pdf, meta)
    y = title_baseline_y(pdf)
    ink_top, ink_bottom = ink_extent(pdf, meta["title"].to_s, TITLE_SIZE, style: :bold)

    band_top = [y + ink_top + BAND_GAP, pdf.bounds.height].min
    band_bottom = y - ink_bottom - BAND_GAP
    band_h = band_top - band_bottom

    engrave(bottom: band_bottom, context: "bandeau de titre") do
      pdf.fill_color BAND_COLOR
      pdf.fill_rectangle [0, band_top], pdf.bounds.width, band_h
      pdf.fill_color "000000"
    end

    draw_header_row(pdf, meta, y, title_color: "FFFFFF", info_color: "FFFFFF")

    band_bottom
  end

  # Option `cote_a_cote` (frontmatter, défaut true) : ON = pairage 2 par 2 par défaut dans
  # l'ordre d'apparition (comme si `//` était déjà posé entre chaque paire) ; OFF = aucun
  # pairage par défaut, `//` (`paired_with_previous`, posé par le parseur) devient le SEUL
  # moyen de pairer deux blocs. `block_align: center` fait toujours row à part, centrée,
  # dans les deux cas.
  # Cascade de config (carnet / collection / fichier / frontmatter) pas encore implémentée
  # — seul le frontmatter est lu pour l'instant.
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
  # `{nom}` répété qui écrase le bloc précédent dans le hash — voir `PageBuilder.parse_lyr`).
  def self.line_has_chord?(line)
    line && line.segments.any?(&:chord)
  end

  # Ligne sans AUCUN mot réel (que des accords + séparateurs "/" espaces...) — intro/outro
  # instrumentale, voir `draw_chords_only_line`.
  def self.line_has_words?(line)
    line.segments.any? { |seg| seg.text =~ /[[:alpha:]]/ }
  end

  def self.chords_only_line?(line)
    line_has_chord?(line) && !line_has_words?(line)
  end

  # `width` : largeur de colonne dispo (`nil` = jamais de RAL2, pas de ligne
  # supplémentaire ajoutée). RAL2 (Manuel/regles_esthetiques.adoc) : vers trop long ->
  # ligne d'excédent en plus SOUS ce vers, donc un pas de ligne de plus. Ligne sans mot
  # (accords seuls) : jamais de ligne de texte réservée en dessous (`draw_chords_only_line`
  # tient tout sur la ligne d'accords), donc jamais de RAL2 non plus.
  def self.line_step(pdf, line, width, chord_size: CHORD_SIZE, text_size: TEXT_SIZE)
    return chord_size + LINE_GAP if chords_only_line?(line)

    step = line_has_chord?(line) ? chord_size + LINE_GAP + text_size + LINE_GAP : text_size + LINE_GAP
    step += text_size + LINE_GAP if line_overflows?(pdf, line, width, chord_size, text_size)
    step
  end

  # Hauteur RÉELLE (visuelle) d'un bloc : hampe du premier élément (accord si la 1re ligne
  # en a un, sinon celle du texte) + l'enchaînement des lignes selon qu'elles ont un accord
  # ou non + descente du dernier texte. Condition pour qu'aucun chevauchement ne soit
  # possible : toute distance donnée à une row (gouttière, marge de page) est mesurée sur
  # CETTE hauteur, jamais sur une approximation en tailles de police fixes. `width` :
  # largeur de colonne dispo pour ce bloc, sert au RAL2 (une ligne qui déborde compte pour
  # deux, voir `line_step`).
  # RAL3 (Manuel/regles_esthetiques.adoc, "aucune exception") : une strophe SANS accord
  # posée à côté d'une strophe AVEC accord aligne sa 1re ligne sur celle de l'autre —
  # `force_chord_baseline` (posé par `row_to_element` selon le voisin de row) impose
  # l'ancrage "1re ligne avec accord" même si CE bloc-ci n'en a pas lui-même.
  def self.block_visual_height(pdf, chord_ascent, text_ascent, text_descent, lines, width, chord_size: CHORD_SIZE, text_size: TEXT_SIZE, force_chord_baseline: false)
    return 0 if lines.empty?

    baseline = force_chord_baseline || line_has_chord?(lines.first) ? chord_ascent : text_ascent
    last_text_offset = 0
    lines.each_with_index do |line, i|
      last_text_offset = if chords_only_line?(line)
                            baseline
                          else
                            baseline + (line_has_chord?(line) ? chord_size + LINE_GAP : 0)
                          end
      last_text_offset += text_size + LINE_GAP if !chords_only_line?(line) && line_overflows?(pdf, line, width, chord_size, text_size)
      baseline += line_step(pdf, line, width, chord_size: chord_size, text_size: text_size) if i < lines.length - 1
    end
    last_text_offset + text_descent
  end

  # Même formule que `draw_line`/`line_width` (MAX texte/accord + CHORD_GAP par segment) —
  # sinon la largeur MESURÉE ici (pour aligner col1_w/col2_w globalement) sous-estime une
  # ligne où le label d'accord est plus large que le mot ("Dm7" vs "LOVE,"), et le rendu
  # RÉEL déborde de la colonne qui lui a été allouée, empiétant sur la colonne suivante
  # (chevauchement constaté 2026-08-21, "All You Need Is Love" p.6, intro/couplet pairés).
  def self.block_width(pdf, block, chord_size: CHORD_SIZE, text_size: TEXT_SIZE)
    block.lines.map { |l| line_width(pdf, l.segments, chord_size, text_size) }.max || 0
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
    col1_w = block_width(pdf, row[0], chord_size: chord_size, text_size: text_size)
    col2_w = block_width(pdf, row[1], chord_size: chord_size, text_size: text_size)
    # RAL3 : voir `row_to_element`.
    force_chord = row.any? { |b| line_has_chord?(b.lines.first) }

    height = [
      block_visual_height(pdf, chord_ascent, text_ascent, text_descent, row[0].lines, col1_w, chord_size: chord_size, text_size: text_size, force_chord_baseline: force_chord),
      block_visual_height(pdf, chord_ascent, text_ascent, text_descent, row[1].lines, col2_w, chord_size: chord_size, text_size: text_size, force_chord_baseline: force_chord),
    ].max
    draw = lambda do |pdf_, y|
      draw_block(pdf_, row[0], x0 + h_gutter, y, col1_w, chord_ascent, text_ascent, chord_size: chord_size, text_size: text_size, force_chord_baseline: force_chord)
      draw_block(pdf_, row[1], x0 + h_gutter + col1_w + h_gutter, y, col2_w, chord_ascent, text_ascent, chord_size: chord_size, text_size: text_size, force_chord_baseline: force_chord)
    end
    PageElement.new(height, draw)
  end

  # RAL3 (Manuel/regles_esthetiques.adoc, "aucune exception") : dans une row côte à côte,
  # si UN des deux blocs a un accord sur sa 1re ligne, les DEUX alignent leur 1re ligne de
  # texte sur cet ancrage — un bloc sans accord ne "remonte" jamais au-dessus de son voisin.
  def self.row_to_element(pdf, row, x0, width, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent)
    widths = row.size == 2 ? [col1_w, col2_w] : [width]
    force_chord = row.size == 2 && row.any? { |b| line_has_chord?(b.lines.first) }
    log_build("bloc sans accord aligné sur son voisin avec accord (RAL3)") if force_chord && row.any? { |b| !line_has_chord?(b.lines.first) }
    height = row.each_with_index.map { |b, i| block_visual_height(pdf, chord_ascent, text_ascent, text_descent, b.lines, widths[i], force_chord_baseline: force_chord) }.max
    draw = lambda do |pdf_, y|
      if row.size == 2
        block, nxt = row
        draw_block(pdf_, block, x0 + h_gutter, y, col1_w, chord_ascent, text_ascent, force_chord_baseline: force_chord)
        draw_block(pdf_, nxt, x0 + h_gutter + col1_w + h_gutter, y, col2_w, chord_ascent, text_ascent, force_chord_baseline: force_chord)
      else
        block = row[0]
        centered = block.directives[:block_align] != "left"
        bx = if centered
               x0 + [(width - block_width(pdf_, block)) / 2.0, 0].max
             else
               x0 + h_gutter # même retrait que la colonne 1, pour rester aligné avec elle
             end
        draw_block(pdf_, block, bx, y, width, chord_ascent, text_ascent)
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
  # `PageBuilder.build`) pour savoir, SANS dessiner, où un élément atterrirait et combien
  # d'espace lui reste sur sa page.
  # pinned : indices d'éléments qui ne doivent JAMAIS être repoussés à la page suivante
  # (ex. une tabla en `shrink` : sa page est fixée par sa position dans le .gab, jamais
  # déplacée — voir `PageBuilder.build`).
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
        log_build("diag seul en fin de pagination ramené sur la page précédente (RAD5)")
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
  def self.paginate_and_draw(pdf, elements, first_avail_h, kdp:, page_w_pt:, page_h_pt:, first_page_no: 1, pinned: [], side_col: nil, text_x: 0, text_w: nil)
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
        PageElement.new(h, lambda do |pdf_, y|
          engrave(bottom: y - h, context: "diagramme") { pdf_.svg(IO.read(path), at: [x, y], width: w, position: :left, enable_web_requests: false) }
        end)
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

    # Passe VIRTUELLE (aucun dessin) : les diags en trop, réagencés en grille à la largeur
    # de la colonne TEXTE (`text_w`, PAS la colonne de diags), tiennent-ils avec le reste
    # de la DERNIÈRE page de texte (E1, E2...) ? Décidé AVANT tout dessin : impossible de
    # supprimer une page déjà construite avec Prawn (Phil, 2026-08-20). Règles Manuel/
    # regles_esthetiques.adoc :
    #   RAD7 : le bloc de lignes de diags reste TOUT EN BAS de la page — le reste (E1, E2)
    #          s'équilibre normalement dans l'espace qui reste AU-DESSUS, jamais mélangé.
    #   RAD8 : écartement FIXE entre les lignes de diags (jamais équilibré/étiré).
    #   RAD9 : une ligne plus courte (moins de diags) s'aligne vers la reliure — ici
    #          toujours à gauche (`text_x`), la position des diags n'étant pas encore
    #          sensible à la parité recto/verso (voir `layout_diags`).
    #   RAD10 : > 5 diags en trop -> taille réduite (70% provisoire, jamais validé par
    #          Phil, comme `MIN_SIZE[:diags][:width]`).
    merged_last_page = nil
    unless excess_paths.empty? || text_w.nil? || pages.empty?
      gap_h = min_h_dist(:diags)
      gap_v = min_v_dist(:diags)
      grid_diag_w = excess_paths.size > 5 ? [DIAG_W * 0.7, MIN_SIZE[:diags][:width]].max : DIAG_W
      grid_diag_h = svg_height_for(File.read(excess_paths.first), grid_diag_w)
      cols = [((text_w + gap_h) / (grid_diag_w + gap_h)).floor, 1].max
      rows = excess_paths.each_slice(cols).to_a
      block_h = rows.size * grid_diag_h + [rows.size - 1, 0].max * gap_v

      last_page = pages.last
      page_els = elements[last_page[:start]...last_page[:finish]]
      page_heights = page_els.map(&:height)
      remaining_h = last_page[:avail_h] - block_h - gap_v
      fits = remaining_h.positive? && (paginate(page_els, remaining_h, remaining_h).size == 1)

      if fits
        merged_last_page = { rows: rows, diag_w: grid_diag_w, diag_h: grid_diag_h, remaining_h: remaining_h }
        log_build("#{excess_paths.size} diags en trop réagencés en #{rows.size} ligne(s) fixes, calés en bas de la dernière page (RAD7/8/9/10)")
        excess_paths = []
        excess_heights = []
      else
        log_build("#{excess_paths.size} diags en trop -> page dédiée (dépasse la place disponible en bas de la dernière page)")
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
        merging_here = merged_last_page && i == pages.size - 1
        avail_for_text = merging_here ? merged_last_page[:remaining_h] : page[:avail_h]
        page_heights = page_els.map(&:height)
        gutters = distribute_v_gutters(avail_for_text, page_heights, top_type: i.zero? ? :band_strophe : :default)

        # Les gouttières sont calculées sur le budget RÉDUIT (`avail_for_text`, pour
        # laisser la place à la grille fusionnée en dessous), mais le texte part TOUJOURS
        # du HAUT réel de la page (`page[:avail_h]`) — sinon il démarre plus bas que prévu
        # et vient chevaucher la grille au lieu de s'arrêter juste au-dessus (bug constaté
        # v22, "Ad libitum" recouvert par la 1re ligne de diags).
        y = page[:avail_h] - gutters[0]
        page_els.each_with_index do |el, j|
          el.draw.call(pdf, y)
          y -= page_heights[j] + gutters[j + 1]
        end
        conflict!("contenu dépasse la zone sûre de #{-y.round(2)}pt", solution: "dessiné quand même, hors zone sûre") if y < -0.01

        if merging_here
          gap_h = min_h_dist(:diags)
          gap_v = min_v_dist(:diags)
          rows = merged_last_page[:rows]
          diag_w = merged_last_page[:diag_w]
          diag_h = merged_last_page[:diag_h]
          rows.each_with_index do |row, ri|
            # `at:[x,y]` de `pdf.svg` ancre le HAUT de l'image (elle descend de `y` vers
            # `y - diag_h`) — bug corrigé ici (2026-08-20) : `row_y` doit inclure `diag_h`,
            # sinon le bas de la dernière ligne tombe sous 0, dans la marge.
            row_y = gap_v + diag_h + (rows.size - 1 - ri) * (diag_h + gap_v)
            row.each_with_index do |path, ci|
              cx = text_x + ci * (diag_w + gap_h) # RAD9 : jamais centré, toujours vers la reliure (text_x)
              engrave(bottom: row_y - diag_h, context: "diagramme fusionné") do
                pdf.svg(IO.read(path), at: [cx, row_y], width: diag_w, position: :left, enable_web_requests: false)
              end
            end
          end
        end
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
          engrave(bottom: y - diag_h, context: "diagramme (page dédiée)") do
            pdf.svg(IO.read(path), at: [x, y], width: DIAG_W, position: :left, enable_web_requests: false)
          end
        end
      end
    end
  end

  # Dessine le bloc : y0 = haut visuel réel (sommet de la hampe du 1er élément). `width` :
  # largeur de colonne dispo pour ce bloc, sert au RAL2 (`nil` = jamais de RAL2).
  def self.draw_block(pdf, block, x, y0, width, chord_ascent, text_ascent, chord_size: CHORD_SIZE, text_size: TEXT_SIZE, force_chord_baseline: false)
    y = y0 - (force_chord_baseline || line_has_chord?(block.lines.first) ? chord_ascent : text_ascent)
    block.lines.each do |line|
      draw_line(pdf, line, x, y, width, chord_size: chord_size, text_size: text_size)
      y -= line_step(pdf, line, width, chord_size: chord_size, text_size: text_size)
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
    descent = font_metric(pdf, size) { pdf.font.descender }
    engrave(bottom: y - descent, context: "accord #{chord}") { pdf.draw_text main, at: [x, y], size: size, style: :bold }
    return if suffix.empty?

    suffix_descent = font_metric(pdf, size - 2) { pdf.font.descender }
    engrave(bottom: y - suffix_descent, context: "accord #{chord} (suffixe)") do
      pdf.draw_text suffix, at: [x + pdf.width_of(main, size: size, style: :bold), y], size: size - 2, style: :bold
    end
  end

  # Positions x de chaque segment d'une ligne NORMALE (texte + accords éventuels) — avance
  # de MAX(largeur texte, largeur label d'accord) + CHORD_GAP si accord (RAA1). UNE SEULE
  # formule pour le dessin (`draw_line`) ET la mesure (`line_width`) : jamais deux formules
  # à tenir synchronisées à la main (bug récurrent — `block_width` mesurait le texte SEUL,
  # `draw_line` avançait sur MAX(texte, accord) : le rendu réel débordait de la largeur
  # mesurée, chevauchement constaté 2026-08-21, "All You Need Is Love" p.6 — Phil : "quelque
  # chose qui mesure VRAIMENT la taille d'un bloc").
  def self.text_line_steps(pdf, segments, chord_size, text_size)
    cx = 0
    steps = segments.map do |seg|
      text_w = pdf.width_of(seg.text, size: text_size)
      chord_w = seg.chord ? chord_label_width(pdf, seg.chord, chord_size) : 0
      step = { x: cx, seg: seg, text_w: text_w }
      cx += [text_w, chord_w].max + (seg.chord ? CHORD_GAP : 0)
      step
    end
    [steps, cx]
  end

  # Positions x d'une ligne "chords-only" (voir `draw_chords_only_line`) — accord et texte
  # d'un même segment avancent l'un APRÈS l'autre (jamais un MAX), formule différente de
  # `text_line_steps` par nature de ce type de ligne, mais même principe : dessin et mesure
  # partagent le même générateur de positions.
  def self.chords_only_steps(pdf, segments, chord_size)
    cx = 0
    steps = []
    segments.each do |seg|
      if seg.chord
        steps << { x: cx, chord: seg.chord }
        cx += chord_label_width(pdf, seg.chord, chord_size) + CHORD_GAP
      end
      sep = seg.text.strip
      next if sep.empty?

      steps << { x: cx, sep: sep }
      cx += pdf.width_of(sep, size: chord_size) + CHORD_GAP
    end
    [steps, cx]
  end

  # Largeur totale qu'occuperait `segments` s'ils étaient dessinés — dispatch IDENTIQUE à
  # `draw_line` (chords-only vs ligne normale), sinon la mesure et le dessin peuvent à
  # nouveau diverger pour ce type de ligne précisément.
  def self.line_width(pdf, segments, chord_size, text_size)
    line = Line.new(segments: segments)
    if line_has_chord?(line) && !line_has_words?(line)
      chords_only_steps(pdf, segments, chord_size).last
    else
      text_line_steps(pdf, segments, chord_size, text_size).last
    end
  end

  def self.line_overflows?(pdf, line, width, chord_size, text_size)
    return false unless width

    line_width(pdf, line.segments, chord_size, text_size) > width
  end

  # RAL2.2 (Manuel/regles_esthetiques.adoc) : SEULEMENT si RAL2.1 (resserrement mots puis
  # lettres, `resolve_line_spacing`) ne suffit toujours pas -> vers raccourci par la FIN,
  # mots entiers, jusqu'à tenir dans `width` ; les mots retirés forment l'excédent (affiché
  # ensuite SOUS le vers, aligné à droite). Mesure au resserrement DÉJÀ choisi (`ws`/`cs`),
  # jamais à 0 (sinon on retrimme un texte qui, resserré, tenait peut-être déjà). Ne trimme
  # que le DERNIER segment — cas courant (l'accord du dernier segment porte sur les
  # derniers mots) ; un débordement qui mangerait plusieurs segments n'est pas géré pour
  # l'instant.
  def self.split_overflow(pdf, segments, width, text_size, ws, cs)
    return [segments, nil] if segments.empty? || !width

    fits = -> { line_tokens_x(pdf, segments.map(&:text).join, text_size, word_spacing: ws, char_spacing: cs).last <= width }
    return [segments, nil] if fits.call

    segs = segments.map(&:dup)
    last = segs.last
    words = last.text.split(" ")
    overflow_words = []

    fits_segs = -> { line_tokens_x(pdf, segs.map(&:text).join, text_size, word_spacing: ws, char_spacing: cs).last <= width }
    while words.size > 1 && !fits_segs.call
      overflow_words.unshift(words.pop)
      last.text = "#{words.join(' ')} "
    end

    overflow_text = overflow_words.join(" ")
    return [segs, nil] if overflow_text.empty?

    log_build("vers trop long malgré le resserrement RAL2.1 (word_spacing=#{ws}, char_spacing=#{cs}), excédent \"#{overflow_text}\" renvoyé sous la ligne, aligné à droite (RAL2.2)")
    [segs, overflow_text]
  end

  # RAL2.1 (Phil 2026-08-21) : le VERS ENTIER est mesuré/dessiné EN CONTINU (mots +
  # espaces), jamais segment par segment — un segment par segment laissait des trous
  # béants dans le texte à chaque frontière d'accord (bug constaté 2026-08-21, essais
  # word-spacing sur "L'Aigle noir" : l'avancée d'un segment était mesurée SANS resserrement
  # alors que le texte suivant démarrait, lui, décalé par le resserrement). Découpe en
  # tokens mot/espace ; seule l'espace change de largeur (`word_spacing`), jamais les
  # lettres à l'intérieur d'un mot.
  def self.word_tokens(text)
    text.scan(/[^ ]+| +/)
  end

  # Position x (et offset caractère dans `text`) de chaque token — sert à la fois à
  # dessiner les mots UNE SEULE FOIS pour tout le vers, et à replacer chaque accord à la
  # bonne position après coup (`chord_x_at_offset`), y compris un accord tombé EN PLEIN
  # MILIEU d'un mot (ex. "cre/c:ver").
  def self.line_tokens_x(pdf, text, size, word_spacing: self.word_spacing, char_spacing: self.char_spacing)
    cx = 0
    co = 0
    tokens = word_tokens(text).map do |tok|
      token = { co: co, x: cx, text: tok }
      # Un mot dessiné passe par `pdf.character_spacing` (Tc, ajouté après CHAQUE
      # caractère affiché) — sa largeur RÉELLE inclut donc `char_spacing * tok.length`,
      # sinon la mesure sous-estime le mot dès que `char_spacing` != 0 (bug de la même
      # famille que `word_spacing`, constaté 2026-08-21 : trous grandissants entre les
      # mots). Un token espace n'est JAMAIS dessiné (voir `draw_line`) donc jamais
      # concerné par `char_spacing`, seulement par `word_spacing` (mécanisme manuel, pas Tc).
      cx += tok.start_with?(" ") ? pdf.width_of(tok, size: size) + word_spacing * tok.length : pdf.width_of(tok, size: size) + char_spacing * tok.length
      co += tok.length
      token
    end
    [tokens, cx]
  end

  def self.chord_x_at_offset(pdf, tokens, offset, size, char_spacing: self.char_spacing)
    return 0 if tokens.empty?

    tok = tokens.reverse_each.find { |t| t[:co] <= offset } || tokens.first
    prefix = tok[:text][0...(offset - tok[:co])]
    tok[:x] + pdf.width_of(prefix, size: size) + char_spacing * prefix.length
  end

  # RAL2.1 (Manuel/regles_esthetiques.adoc) : valeurs limites décidées par Phil,
  # 2026-08-21, sur "L'Aigle noir" — jamais dépassées. Mots resserrés en PREMIER (jusqu'à
  # `RAL2_1_WORD_SPACING_MAX`) ; lettres resserrées SEULEMENT si ça ne suffit toujours pas
  # (jusqu'à `RAL2_1_CHAR_SPACING_MAX`, en PLUS du resserrement des mots déjà au max).
  RAL2_1_WORD_SPACING_MAX = -1.0
  RAL2_1_CHAR_SPACING_MAX = -0.2
  RAL2_1_STEP = -0.2

  # Cherche le MINIMUM de resserrement qui fait tenir `full_text` dans `width` — [0, 0] si
  # la ligne tient déjà nature, ou si même le maximum autorisé ne suffit pas (RAL2.2
  # prend alors le relais, voir `split_overflow`).
  def self.resolve_line_spacing(pdf, full_text, width, text_size)
    return [0.0, 0.0] unless width

    fits = ->(ws, cs) { line_tokens_x(pdf, full_text, text_size, word_spacing: ws, char_spacing: cs).last <= width }
    return [0.0, 0.0] if fits.call(0.0, 0.0)

    ws = 0.0
    until fits.call(ws, 0.0) || ws <= RAL2_1_WORD_SPACING_MAX
      ws = [ws + RAL2_1_STEP, RAL2_1_WORD_SPACING_MAX].max
    end
    return [ws, 0.0] if fits.call(ws, 0.0)

    cs = 0.0
    until fits.call(ws, cs) || cs <= RAL2_1_CHAR_SPACING_MAX
      cs = [cs + RAL2_1_STEP, RAL2_1_CHAR_SPACING_MAX].max
    end
    [ws, cs]
  end

  # RAA1 : deux labels d'accord ne doivent JAMAIS se toucher — plus question de distordre
  # l'avancée du TEXTE pour ça (RAL2.1 : le texte reste sa propre mesure, continue, intacte)
  # ; c'est le LABEL d'accord qui est repoussé à droite si besoin, jamais le texte déplacé.
  def self.spread_chord_positions(pdf, chord_steps, chord_size)
    min_x = nil
    chord_steps.each do |step|
      step[:x] = min_x if min_x && step[:x] < min_x
      min_x = step[:x] + chord_label_width(pdf, step[:chord], chord_size) + CHORD_GAP
    end
  end

  # L'avancée horizontale ne doit JAMAIS être inférieure à la largeur du label d'accord
  # tout juste dessiné (RAA1 : deux accords ne doivent jamais se superposer) — une "avancée
  # à texte vide" fixe (ex. 3 espaces) s'est avérée insuffisante en pratique (mesuré :
  # espaces 9.17pt < largeur label "C9" 11.67pt, chevauchement constaté malgré le fix —
  # AYNL puis À bicyclette, 2026-08-19). On avance donc du MAX(largeur du texte, largeur
  # du label d'accord) : garantie mathématique, jamais un réglage à ajuster à la main.
  # `width` : largeur de colonne disponible, sert au RAL2 (`nil` = jamais de RAL2, ex.
  # appelants qui ne connaissent pas encore leur largeur).
  def self.draw_line(pdf, line, x, y, width, chord_size: CHORD_SIZE, text_size: TEXT_SIZE)
    return draw_chords_only_line(pdf, line, x, y, chord_size: chord_size) if line_has_chord?(line) && !line_has_words?(line)

    has_chord = line_has_chord?(line)
    text_y = has_chord ? y - chord_size - LINE_GAP : y
    text_descent = font_metric(pdf, text_size) { pdf.font.descender }

    # `word_spacing`/`char_spacing` (accesseurs globaux) : forcés SI Phil les a réglés
    # explicitement (essais manuels, `songbook.rb song`) — sinon RAL2.1 décide seul, par
    # ligne, le minimum de resserrement nécessaire.
    natural_text = line.segments.map(&:text).join
    if word_spacing.zero? && char_spacing.zero?
      ws, cs = resolve_line_spacing(pdf, natural_text, width, text_size)
      log_build("vers resserré pour tenir dans sa colonne : word_spacing=#{ws}, char_spacing=#{cs} (RAL2.1)") if ws.nonzero? || cs.nonzero?
    else
      ws, cs = word_spacing, char_spacing
    end

    segs, overflow_text = split_overflow(pdf, line.segments, width, text_size, ws, cs)
    full_text = segs.map(&:text).join
    tokens, = line_tokens_x(pdf, full_text, text_size, word_spacing: ws, char_spacing: cs)

    seg_offset = 0
    chord_steps = segs.filter_map do |seg|
      step = { x: chord_x_at_offset(pdf, tokens, seg_offset, text_size, char_spacing: cs), chord: seg.chord } if seg.chord
      seg_offset += seg.text.length
      step
    end
    spread_chord_positions(pdf, chord_steps, chord_size)
    chord_steps.each { |step| draw_chord_label(pdf, step[:chord], x + step[:x], y, size: chord_size) }

    pdf.character_spacing(cs) do
      tokens.each do |tok|
        next if tok[:text].start_with?(" ")

        engrave(bottom: text_y - text_descent, context: "texte \"#{tok[:text][0, 20]}\"") { pdf.draw_text tok[:text], at: [x + tok[:x], text_y], size: text_size }
      end
    end

    return unless overflow_text

    text_y = has_chord ? y - chord_size - LINE_GAP : y
    overflow_y = text_y - text_size - LINE_GAP
    overflow_w = pdf.width_of(overflow_text, size: text_size)
    overflow_descent = font_metric(pdf, text_size) { pdf.font.descender }
    engrave(bottom: overflow_y - overflow_descent, context: "excédent de vers \"#{overflow_text[0, 20]}\"") do
      pdf.draw_text overflow_text, at: [x + width - overflow_w, overflow_y], size: text_size
    end
  end

  # Ligne SANS aucun mot réel — juste des accords séparés par de la ponctuation ("/",
  # espaces), typique d'une intro/outro instrumentale (ex. À bicyclette, `/Em://Em9:`) —
  # tout tenu sur la ligne d'accords elle-même (jamais de ligne de texte vide en dessous,
  # jamais le séparateur affiché sous l'accord — Phil, 2026-08-20). Espacement RAA1
  # (`CHORD_GAP`) partout, y compris entre accord et séparateur.
  def self.draw_chords_only_line(pdf, line, x, y, chord_size: CHORD_SIZE)
    descent = font_metric(pdf, chord_size) { pdf.font.descender }
    steps, = chords_only_steps(pdf, line.segments, chord_size)
    steps.each do |step|
      if step[:chord]
        draw_chord_label(pdf, step[:chord], x + step[:x], y, size: chord_size)
        next
      end

      engrave(bottom: y - descent, context: "séparateur accords \"#{step[:sep]}\"") { pdf.draw_text step[:sep], at: [x + step[:x], y], size: chord_size }
    end
  end

  def self.draw_diags(pdf, diag_paths, heights, x:, avail_h:, width:)
    gutters = distribute_v_gutters(avail_h, heights, type: :diags, top_type: :band_diag)
    y = avail_h - gutters[0]
    diag_paths.each_with_index do |path, i|
      svg_data = IO.read(path)
      engrave(bottom: y - heights[i], context: "diagramme") { pdf.svg(svg_data, at: [x, y], width: width, position: :left, enable_web_requests: false) }
      y -= heights[i] + gutters[i + 1]
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
      svg_data = IO.read(path)
      h = svg_height_for(svg_data, w)
      engrave(bottom: y_top - h, context: "diagramme (rangée)") { pdf.svg(svg_data, at: [x, y_top], width: w, position: :left, enable_web_requests: false) }
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
    when :both
      raise "position de diagrammes :both (layouts Column/Column-B, Manuel/song/layout.adoc) pas encore implémentée"
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

  def self.svg_viewbox(svg_data)
    m = svg_data.match(/viewBox="[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)"/)
    [m[1].to_f, m[2].to_f]
  end

  def self.svg_height_for(svg_data, target_w)
    w, h = svg_viewbox(svg_data)
    target_w * (h / w)
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
      engrave(bottom: y - title_h - svg_h, context: "tabla") { pdf_.svg(svg_data, at: [x0, y - title_h], width: embed_w, position: :left, enable_web_requests: false) }
    end

    PageElement.new(title_h + svg_h, draw)
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
      engrave(bottom: y - title_h - svg_h, context: "tabla") { pdf_.svg(svg_data, at: [svg_x, y - title_h], width: embed_w, position: :left, enable_web_requests: false) }
    end
    PageElement.new(title_h + svg_h, draw)
  end
end
